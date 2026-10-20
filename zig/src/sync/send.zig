//! Pages between your Macs, as menus: Tabs › Send to Device and a tab's own
//! menu (`SendToDevice`, Sharing.swift:40-59), and History › Tabs from Other
//! Macs (`OtherMacs`, App.swift:301-319), each Mac's pages made as its
//! submenu opens.
const std = @import("std");
const nanoui = @import("nanoui");
const MenuItem = nanoui.MenuItem;
const Item = nanoui.menu.Item;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const handoff = @import("../app/handoff.zig");
const settings = @import("../chrome/settings/frame.zig");

/// "Send to Device", for `tab`, on `a`: your other Macs once Sync is set
/// up, then the Mac's share picker. Not for a blank or private page.
pub fn menu(a: std.mem.Allocator, b: *Browser, tab: *Tab) !MenuItem {
    const sync = &b.kea.sync;
    var out: std.ArrayList(MenuItem) = .empty;
    if (!sync.ready) {
        try out.append(a, try pick(a, b, tab.id, "Set Up Sync…", .set_up));
    } else if (sync.devices.len == 0) {
        try out.append(a, .{ .label = "No Other Macs Yet", .disabled = true });
    } else for (sync.devices) |d| try out.append(a, try pick(a, b, tab.id, try a.dupe(u8, d.name), .{ .to = d.id }));
    try out.append(a, .separator);
    try out.append(a, try pick(a, b, tab.id, "Share…", .share));
    return .{ .label = "Send to Device", .submenu = out.items, .disabled = tab.isBlank() or handoff.isPrivatePage(tab) };
}

fn pick(a: std.mem.Allocator, b: *Browser, tab: u64, label: []const u8, what: Pick.What) !MenuItem {
    const p = try a.create(Pick);
    p.* = .{ .b = b, .tab = tab, .what = what };
    return .{ .label = label, .click = .of(p, Pick.fire) };
}

const Pick = struct {
    b: *Browser,
    tab: u64,
    what: What,

    const What = union(enum) { set_up, to: Uuid, share };

    fn fire(self: *Pick, _: *Item) void {
        const b = self.b;
        const t = b.tabById(self.tab) orelse return;
        switch (self.what) {
            .set_up => settings.open(b, .sync),
            .to => |id| {
                // The list may have changed since the menu was made.
                const sync = &b.kea.sync;
                for (sync.devices) |*d| if (d.id.eql(id)) return sync.send(t.url(), t.page_title, d, b);
            },
            .share => {
                b.select(t);
                b.share();
            },
        }
        b.redraw();
    }
};

/// History › Tabs from Other Macs onto `out`: a submenu for each Mac with
/// pages open, while open tabs are synced. Nothing when there are none.
pub fn otherMacs(a: std.mem.Allocator, b: *Browser, out: *std.ArrayList(MenuItem)) !void {
    const sync = &b.kea.sync;
    if (!sync.kinds.contains(.tabs)) return;
    var any = false;
    for (sync.devices) |d| if (d.pages.len > 0) {
        if (!any) {
            any = true;
            try out.append(a, .separator);
            try out.append(a, .{ .label = "Tabs from Other Macs", .disabled = true });
        }
        const lazy = try a.create(Lazy);
        lazy.* = .{ .a = a, .b = b, .id = d.id };
        try out.append(a, .{ .label = try a.dupe(u8, d.name), .submenu = &.{}, .on_open = .of(lazy, Lazy.fill) });
    };
}

/// One Mac's pages, made as its submenu opens: each a line with its icon,
/// then Open All.
pub fn pages(a: std.mem.Allocator, b: *Browser, id: Uuid) ![]const MenuItem {
    const sync = &b.kea.sync;
    for (sync.devices) |d| if (d.id.eql(id)) {
        var out: std.ArrayList(MenuItem) = .empty;
        for (d.pages) |pg| {
            const go = try a.create(Open);
            go.* = .{ .b = b, .urls = try a.dupe([]const u8, &.{try a.dupe(u8, pg.url)}), .front = true };
            const png = if (b.kea.favicons.icon(pg.url)) |ic| try a.dupe(u8, ic.png) else "";
            const label = if (pg.title.len > 0) pg.title else pg.url;
            try out.append(a, .{ .label = try a.dupe(u8, label), .image_png = png, .click = .of(go, Open.fire) });
        }
        try out.append(a, .separator);
        const all = try a.create(Open);
        const urls = try a.alloc([]const u8, d.pages.len);
        for (d.pages, urls) |pg, *u| u.* = try a.dupe(u8, pg.url);
        all.* = .{ .b = b, .urls = urls, .front = false };
        try out.append(a, .{ .label = "Open All", .click = .of(all, Open.fire) });
        return out.items;
    };
    return &.{};
}

const Lazy = struct {
    a: std.mem.Allocator,
    b: *Browser,
    id: Uuid,

    fn fill(self: *Lazy, item: *Item) void {
        item.setSubmenu(pages(self.a, self.b, self.id) catch return) catch {};
    }
};

const Open = struct {
    b: *Browser,
    urls: []const []const u8,
    /// One page, in front; or all of them behind at the end, waiting to load.
    front: bool,

    fn fire(self: *Open, _: *Item) void {
        for (self.urls) |u| _ = self.b.open(u, if (self.front) .{ .foreground = true } else .{ .foreground = false, .at_end = true, .may_wait = true });
        self.b.redraw();
    }
};
