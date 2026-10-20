//! Settings › Extensions (ExtensionsUI.swift 6-228): what is installed, and
//! the ways in — a Chrome Web Store link, another browser's, a folder — the
//! private-tabs switch and the extensions you let record your screen. And
//! the `StoreOffer` bar (240-280): on an extension's page in the Chrome Web
//! Store, the offer to add it where the store's own button isn't in place.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const app_name = @import("../app/kea.zig").app_name;
const card = @import("../design/card.zig");
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const ring = @import("../chrome/ring.zig");
const sheet = @import("../chrome/sheet.zig");
const tab_menu = @import("../chrome/tab_menu.zig");
const frame = @import("../chrome/settings/frame.zig");
const import_panel = @import("../import/panel.zig");
const controller = @import("controller.zig");
const Extensions = controller.Extensions;
const Installed = controller.Installed;
const ext = @import("ext.zig");
const crx = @import("crx.zig");
const capture = @import("capture.zig");
const store_relay = @import("store_relay.zig");
const slot_view = @import("slot_view.zig");

pub const State = struct {
    link: ui.TextBuffer = .{},

    pub fn deinit(s: *State) void {
        s.link.deinit();
    }
};

fn px(v: f32) ui.Length {
    return .{ .px = v };
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const e = b.kea.ext orelse {
        plate.cardBox(c, p);
        plate.line(c, p, "Chrome extensions", "Need macOS 15.4 or later — the version whose WebKit can run them.");
        ui.end(c);
        ui.end(c);
        return;
    };
    const s = &b.settings.extensions;
    ui.column(c, .{ .gap = 18, .width = .fill });
    defer ui.end(c);
    installer(b, c, p, e, s);

    plate.cardBox(c, p);
    plate.line(c, p, "From another browser", "What Chrome, Arc, Brave and the others added from the Chrome Web Store — installed fresh from the store, you say yes to each one");
    if (controls.pill(c, p, "Bring them over…", .{}).clicked) {
        b.importing.extensions = true;
        sheet.show(b, .bringing);
    }
    ui.end(c);
    ui.end(c);

    plate.cardBox(c, p);
    _ = frame.prefLine(b, c, p, "extensions_in_private", "Allow on private tabs", "Off by default - a private tab keeps nothing, extensions included");
    ui.end(c);

    plate.cardBox(c, p);
    if (e.installed.items.len == 0) {
        plate.nothing(c, p, "No extensions yet — plenty of room on the perch.");
    } else for (e.installed.items, 0..) |item, i| {
        if (i > 0) plate.rule(c, p, 14);
        ui.key(c, item.id);
        row(b, c, p, e, item, i);
    }
    ui.end(c);

    recorders(c, p, e);

    plate.cardBox(c, p);
    plate.line(c, p, "Load an unpacked extension", "A folder with a manifest.json — your own, or one exported from another browser. Reload picks up what you've changed in it since.");
    // A modal panel: after this frame.
    if (controls.pill(c, p, "Choose…", .{}).clicked) objc.dispatchMain(@ptrFromInt(e.serial), choose);
    ui.end(c);
    ui.end(c);
}

fn choose(ctx: ?*anyopaque) callconv(.c) void {
    if (controller.alive(@intFromPtr(ctx))) |e| e.installFolder();
}

fn installer(b: *Browser, c: *ui.Context, p: *const Palette, e: *Extensions, s: *State) void {
    plate.cardBox(c, p);
    defer ui.end(c);
    ui.column(c, .{ .gap = 10, .width = .fill, .padding = .all(14) });
    defer ui.end(c);
    ui.row(c, .{ .gap = 8, .width = .fill, .align_items = .center });
    ui.text(c, "Add from the Chrome Web Store", .{ .size = 13, .color = p.ink });
    _ = c.leaf(.{ .grow = 1, .min_width = 8 }, .none, null);
    if (controls.pill(c, p, "Open the Store", .{}).clicked) {
        sheet.close(b, .tuning);
        _ = b.open(store_relay.web_store, .{ .foreground = true });
    }
    ui.end(c);
    ui.row(c, .{ .gap = 8, .width = .fill, .align_items = .center });
    ui.column(c, .{ .grow = 1, .padding = .xy(10, 7), .radius = 9, .background = p.wash });
    ui.key(c, "ext.link");
    const r = ui.textField(c, &s.link, .{ .bare = true, .size = 12.5, .width = .fill, .caret_color = p.ink, .selection_color = p.ink.alpha(0.12) });
    if (s.link.text().len == 0)
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 10, .y = 7 } }, .{ .text = .{ .str = "Paste a link to an extension, or its id", .style = .{ .size = 12.5, .truncate = true }, .color = p.muted.alpha(0.8) } }, null);
    ui.end(c);
    const valid = crx.id(s.link.text()) != null;
    var add = r.submitted;
    if (e.busy != null) ring.ring(c, 12) else if (import_panel.pill(c, p, "Add", true, valid)) add = true;
    ui.end(c);
    if (add and valid) {
        e.installFrom(s.link.text(), true);
        s.link.clear();
        c.changed = true;
    }
    ui.text(c, "Or find it in the store and press Add to " ++ app_name ++ " on its page.", .{ .size = 11.5, .color = p.muted, .wrap = true });
}

/// The extensions you let record your screen, each one to take back.
fn recorders(c: *ui.Context, p: *const Palette, e: *Extensions) void {
    const ids = capture.allowedIDs(c.alloc(), &e.kea.store) catch return;
    if (ids.len == 0) return;
    plate.cardBox(c, p);
    defer ui.end(c);
    for (ids, 0..) |id, i| {
        if (i > 0) plate.rule(c, p, 14);
        ui.key(c, id);
        plate.line(c, p, controller.extensionName(e.kea, id), "Can record your screen — macOS asks what to share each time");
        if (controls.pill(c, p, "Remove", .{}).clicked) {
            capture.forget(e, id);
            c.changed = true;
        }
        ui.end(c);
    }
}

fn newTabKey(c: *ui.Context, id: []const u8) []const u8 {
    return c.print("extensions.newtab.{s}", .{id});
}

/// Where it was loaded from, by the folder's name — the whole path is in the tooltip.
fn detail(c: *ui.Context, e: *Extensions, item: Installed, context: ?objc.Object) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const a = c.alloc();
    parts.append(a, c.print("Version {s}", .{item.version})) catch {};
    parts.append(a, if (item.fromStore) "Chrome Web Store" else if (item.source) |src| c.print("From “{s}”", .{std.fs.path.basename(src)}) else "From a folder") catch {};
    if (item.enabled and context == null) parts.append(a, "couldn't start") catch {};
    if (context) |ctx| {
        if (objc.msg(?objc.Object, ctx, "overrideNewTabPageURL", .{}) != null and (e.kea.store.bool(newTabKey(c, item.id)) orelse false))
            parts.append(a, "shows in new tabs") catch {};
        const n = objc.msg(objc.NSUInteger, objc.msg(objc.Object, ctx, "errors", .{}), "count", .{});
        if (n > 0) parts.append(a, c.print("{d} warning{s}", .{ n, if (n == 1) "" else "s" })) catch {};
    }
    return std.mem.join(a, " · ", parts.items) catch "";
}

fn row(b: *Browser, c: *ui.Context, p: *const Palette, e: *Extensions, item: Installed, index: usize) void {
    const context = e.context(item.id);
    const i = c.open(.{ .direction = .row, .gap = 12, .width = .fill, .padding = .xy(14, 10), .align_items = .center }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const hovering = if (it.rect) |r| r.contains(c.input.mouse) else false;
    if (hovering) c.node(i).style.background = p.hover;
    _ = c.open(.{ .width = px(22), .height = px(22), .align_items = .center, .justify = .center }, null);
    const image: ?objc.Object = if (context) |ctx| objc.msg(?objc.Object, objc.msg(objc.Object, ctx, "webExtension", .{}), "iconForSize:", .{objc.CGSize{ .width = 32, .height = 32 }}) else null;
    if (image) |img| slot_view.picture(c, p, e, item.id, item.name, img, 22) else ui.icon(c, "puzzlepiece.extension", .{ .size = 14, .color = p.muted });
    c.end();
    ui.column(c, .{ .gap = 2, .grow = 1, .min_width = 0 });
    ui.text(c, item.name, .{ .size = 13, .color = p.ink, .truncate = true });
    const d = c.open(.{ .width = .fill }, null);
    if (item.source) |src| c.help(d, src);
    ui.text(c, detail(c, e, item, context), .{ .size = 11.5, .color = p.muted, .truncate = true });
    c.end();
    ui.end(c);
    _ = c.leaf(.{ .min_width = 8, .width = px(8) }, .none, null);
    // Five pills don't fit beside the name: one menu holds them all.
    const more = c.open(.{ .width = px(26), .height = px(26), .align_items = .center, .justify = .center, .control = true }, null);
    const more_it = c.interact(more, .{});
    const say = c.print("More for {s}", .{item.name});
    c.help(more, say);
    c.addA11y(more, .menu_button, say, "", false, true);
    ui.icon(c, "ellipsis", .{ .size = 11, .weight = .semibold, .color = if (hovering) p.ink else p.muted });
    c.end();
    var on = item.enabled;
    if (controls.switch_(c, p, &on, item.name)) e.setEnabled(item.id, on);
    if (more_it.clicked or it.right_clicked) tab_menu.later(b, c.input.mouse, index, actions);
}

const Act = struct {
    b: *Browser,
    id: []const u8,
    what: enum { pin, new_tab, options, reload, remove },

    fn fire(self: *Act, _: *nanoui.menu.Item) void {
        const e = self.b.kea.ext orelse return;
        const item = e.row(self.id) orelse return;
        switch (self.what) {
            .pin => e.setPinned(self.id, !(item.pinned orelse false)),
            .new_tab => {
                var buf: [160]u8 = undefined;
                const k = std.fmt.bufPrint(&buf, "extensions.newtab.{s}", .{self.id}) catch return;
                e.setNewTab(self.id, !(e.kea.store.bool(k) orelse false));
                e.changed();
            },
            .options => e.openOptions(self.id),
            .reload => e.reload(self.id),
            .remove => e.remove(self.id),
        }
    }
};

/// The row's menu: pin, new tabs, options, reload, remove.
fn actions(arena: std.mem.Allocator, b: *Browser, at: u64) anyerror![]const MenuItem {
    const e = b.kea.ext orelse return &.{};
    if (at >= e.installed.items.len) return &.{};
    const item = e.installed.items[@intCast(at)];
    const id = try arena.dupe(u8, item.id);
    var out: std.ArrayList(MenuItem) = .empty;
    const Make = struct {
        fn act(a: std.mem.Allocator, bb: *Browser, i: []const u8, what: @FieldType(Act, "what")) !*Act {
            const x = try a.create(Act);
            x.* = .{ .b = bb, .id = i, .what = what };
            return x;
        }
    };
    try out.append(arena, .{ .label = if (item.pinned orelse false) "Unpin" else "Pin to Toolbar", .click = .of(try Make.act(arena, b, id, .pin), Act.fire) });
    const pool = objc.Pool.push();
    defer pool.pop();
    if (e.context(id)) |ctx| {
        if (objc.msg(?objc.Object, ctx, "overrideNewTabPageURL", .{}) != null) {
            const k = try std.fmt.allocPrint(arena, "extensions.newtab.{s}", .{id});
            const on = e.kea.store.bool(k) orelse false;
            try out.append(arena, .{ .label = if (on) "Stop Showing in New Tabs" else "Show in New Tabs", .click = .of(try Make.act(arena, b, id, .new_tab), Act.fire) });
        }
        if (objc.msg(?objc.Object, ctx, "optionsPageURL", .{}) != null)
            try out.append(arena, .{ .label = "Options", .click = .of(try Make.act(arena, b, id, .options), Act.fire) });
    }
    if (item.source != null or !item.fromStore)
        try out.append(arena, .{ .label = "Reload", .click = .of(try Make.act(arena, b, id, .reload), Act.fire) });
    try out.append(arena, .separator);
    try out.append(arena, .{ .label = "Remove", .click = .of(try Make.act(arena, b, id, .remove), Act.fire) });
    return out.items;
}

// MARK: StoreOffer

/// The store page's extension in the tab in front, when it is to be offered:
/// not where the page's own "Add to KeaZig" is in place, not once installed.
pub fn offered(b: *Browser) ?crx.Id {
    const e = b.kea.ext orelse return null;
    const tab = b.activeTab() orelse return null;
    const id = crx.storeID(tab.address orelse return null) orelse return null;
    if (tab.store_placed) |placed| if (std.mem.eql(u8, placed, &id)) return null;
    if (e.row(&id) != null) return null;
    return id;
}

/// The bar: "Add this extension to KeaZig" and Add, or Adding… while it comes.
pub fn storeOffer(b: *Browser, c: *ui.Context, p: *const Palette, id: crx.Id, t: f32) void {
    const e = b.kea.ext orelse return;
    const busy = if (e.busy) |x| std.mem.eql(u8, x, &id) else false;
    var shadow = card.swiftShadow(0.12, 20, 6);
    shadow.knockout = true;
    _ = c.open(.{
        .direction = .row,
        .gap = 12,
        .align_items = .center,
        .padding = .{ .left = 16, .right = 10, .top = 9, .bottom = 9 },
        .radius = controls.capsule,
        .background = p.ground,
        .border = p.hairline,
        .shadow = shadow,
        .offset = .{ .y = (1 - t) * 60 },
        .opacity = std.math.clamp(t, 0, 1),
    }, "kea.store-offer");
    defer c.end();
    ui.icon(c, "puzzlepiece.extension", .{ .size = 11, .weight = .medium, .color = p.muted });
    ui.text(c, if (busy) "Adding…" else "Add this extension to " ++ app_name, .{ .size = 12.5, .color = p.ink });
    if (busy) return ring.ring(c, 10);
    const add = c.open(.{ .padding = .xy(11, 5), .radius = controls.capsule, .background = p.ink, .control = true }, "kea.store-add");
    const it = c.interact(add, .{});
    c.addA11y(add, .button, "Add", "", false, true);
    ui.text(c, "Add", .{ .size = 12, .color = p.ground });
    c.end();
    if (it.clicked) {
        var copy = id;
        e.installFrom(&copy, true);
    }
}
