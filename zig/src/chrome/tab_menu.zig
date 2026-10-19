//! `TabMenu` (TabBar.swift 980-1123): what a right-click on any tab offers,
//! wherever the tab is drawn — `items` builds it, `popup` shows it once
//! the frame is drawn. `later` shows any such menu (the column's group
//! headings and space dot use it too).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const samePage = @import("../model/pins.zig").samePage;

pub const Build = *const fn (arena: std.mem.Allocator, b: *Browser, id: u64) anyerror![]const MenuItem;

/// A menu asked for during a frame, shown on the next turn of the run
/// loop: `popUpMenu` runs a loop of its own, which must not run inside
/// the frame that asked. By the window's record id, so a window closed
/// in between shows nothing.
const Later = struct {
    kea: *Kea,
    window: Uuid,
    at: ui.Point,
    id: u64,
    build: Build,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Later = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(l);
        for (l.kea.browsers.items) |b| if (b.record_id.eql(l.window)) return show(b, l.at, l.id, l.build);
    }
};

/// `build(arena, b, id)`'s menu at `at` (window points), after this frame.
/// Nothing in a window that isn't on screen (headless).
pub fn later(b: *Browser, at: ui.Point, id: u64, build: Build) void {
    if (b.window == null) return;
    const l = std.heap.c_allocator.create(Later) catch return;
    l.* = .{ .kea = b.kea, .window = b.record_id, .at = at, .id = id, .build = build };
    objc.dispatchMain(l, Later.fire);
}

fn show(b: *Browser, at: ui.Point, id: u64, build: Build) void {
    const w = b.window orelse return;
    const s = w.surface orelse return;
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const template = build(arena.allocator(), b, id) catch return;
    if (template.len == 0) return;
    const m = nanoui.Menu.create(b.gpa, @import("../app/kea.zig").app_name, template) catch return;
    defer m.destroy();
    m.popup(s.nsview, at.x, at.y);
}

/// The tab's menu where the pointer is.
pub fn popup(b: *Browser, c: *ui.Context, tab: *Tab) void {
    b.strip.menu_tab = tab.id;
    later(b, c.input.mouse, tab.id, built);
}

fn built(arena: std.mem.Allocator, b: *Browser, id: u64) anyerror![]const MenuItem {
    const tab = b.tabById(id) orelse return &.{};
    return items(arena, b, tab);
}

/// One item's work: the window, the tab, and what to do to it.
const Pick = struct {
    b: *Browser,
    tab: u64,
    what: What,
    /// The group, space or window (`record_id`) it names.
    to: Uuid = Uuid.first,

    const What = enum {
        new_group,
        to_group,
        out_of_group,
        pin,
        pin_row,
        listed,
        home,
        letter,
        unpin,
        to_space,
        new_space,
        swap,
        separate,
        close_both,
        open_split,
        new_window,
        to_window,
        rename,
        duplicate,
        site_info,
        copy_address,
        copy_link,
        mute,
        sleep,
        close,
        close_others,
        reopen,
    };

    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const b = self.b;
        const t = b.tabById(self.tab) orelse return;
        switch (self.what) {
            .new_group => _ = b.addTabGroup(t),
            .to_group => b.moveToGroup(t, self.to),
            .out_of_group => b.moveToGroup(t, null),
            .pin => b.pin(t, false),
            .pin_row => b.pin(t, true),
            .listed => b.setListed(t, !t.listed),
            .home => b.goHome(t),
            .letter => b.editLetter(t),
            .unpin => b.unpin(t),
            .to_space => b.moveToSpace(t, self.to),
            .new_space => {
                // The new space's card, in place; made, the tab goes into it.
                b.after_space_created = t.id;
                b.making_space = true;
            },
            .swap => if (comptime split) {
                b.focusPane(t);
                b.swapSplit();
            },
            .separate => if (comptime split) b.detachSplit(t),
            .close_both => if (comptime split) {
                b.focusPane(t);
                b.closeSplit();
            },
            .open_split => if (comptime split) b.openInSplit(t),
            .new_window => b.moveToWindow(t, null, null),
            .to_window => {
                for (b.kea.browsers.items) |other| if (other.record_id.eql(self.to)) {
                    b.moveToWindow(t, other, null);
                    break;
                };
            },
            .rename => if (comptime editing) b.beginTabRename(t),
            .duplicate => {
                b.select(t);
                b.duplicate();
            },
            .site_info => if (comptime editing) {
                if (b.active_id != t.id) b.select(t);
                b.beginTabEdit(t);
            },
            .copy_address => {
                b.select(t);
                b.copyAddress();
            },
            .copy_link => {
                b.select(t);
                b.copyMarkdownLink();
            },
            .mute => t.toggleMute(),
            .sleep => if (comptime sleeps) b.sleep(t, slept),
            .close => b.close(t),
            .close_others => b.closeOthers(t),
            .reopen => b.reopen(),
        }
        b.redraw();
    }

    fn slept(b: *Browser, outcome: []const u8) void {
        if (std.mem.eql(u8, outcome, "asleep")) return;
        const said = std.fmt.allocPrint(b.gpa, "Stays awake: {s}", .{outcome}) catch return;
        defer b.gpa.free(said);
        b.announce(said);
    }
};

// The items whose work lands with a later phase show once it has: Split
// View's with P7 (`TabSplit`), Rename and Site Information with the tab's
// own address field (P6), Put to Sleep with Sleep.swift (P5), Send to
// Device with Sync (P12).
const split = @hasDecl(Browser, "openInSplit");
const editing = @hasDecl(Browser, "beginTabEdit");
const sleeps = @hasDecl(Browser, "sleep");
const syncs = @hasField(Kea, "sync");

fn extensionPage(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "chrome-extension:");
}

/// The tab's menu, in TabMenu's order, on `arena` (titles included).
pub fn items(arena: std.mem.Allocator, b: *Browser, tab: *Tab) ![]MenuItem {
    var out: std.ArrayList(MenuItem) = .empty;
    const Add = struct {
        a: std.mem.Allocator,
        b: *Browser,
        tab: u64,
        fn item(s: @This(), label: []const u8, what: Pick.What, to: Uuid, disabled: bool) !MenuItem {
            const pick = try s.a.create(Pick);
            pick.* = .{ .b = s.b, .tab = s.tab, .what = what, .to = to };
            return .{ .label = label, .disabled = disabled, .click = .of(pick, Pick.fire) };
        }
        fn plain(s: @This(), label: []const u8, what: Pick.What, disabled: bool) !MenuItem {
            return s.item(label, what, Uuid.first, disabled);
        }
    };
    const add: Add = .{ .a = arena, .b = b, .tab = tab.id };
    const prefs = b.prefs;

    if (prefs.uses_tab_groups and tab.pin == null and !tab.shy) {
        var sub: std.ArrayList(MenuItem) = .empty;
        try sub.append(arena, try add.plain("New Group", .new_group, false));
        if (b.tab_groups.items.len > 0) try sub.append(arena, .separator);
        for (b.tab_groups.items) |g| {
            const in = if (tab.group_id) |id| id.eql(g.id) else false;
            try sub.append(arena, try add.item(try arena.dupe(u8, g.name), .to_group, g.id, in));
        }
        if (tab.group_id != null) {
            try sub.append(arena, .separator);
            try sub.append(arena, try add.plain("Remove from Group", .out_of_group, false));
        }
        try out.append(arena, .{ .label = "Move to Group", .submenu = sub.items });
    }
    const rows = prefs.showsPinRows();
    if (tab.pin == null) {
        try out.append(arena, try add.plain("Pin", .pin, tab.isBlank() or tab.shy));
        if (rows) try out.append(arena, try add.plain("Pin as Row", .pin_row, tab.isBlank() or tab.shy));
    } else {
        if (rows) try out.append(arena, try add.plain(if (tab.listed) "Show as Square" else "Show as Row", .listed, false));
        // A row wears its title, not its letter: the way home a square's
        // double-click is, is here instead, while it has wandered.
        if (rows and tab.listed) {
            const home_already = if (tab.home) |h| samePage(h, tab.url()) else true;
            try out.append(arena, try add.plain("Back to Pinned Page", .home, home_already));
        } else try out.append(arena, try add.plain("Change Letter", .letter, false));
        try out.append(arena, try add.plain("Unpin", .unpin, false));
    }
    if (prefs.uses_spaces and !extensionPage(tab.url())) {
        var sub: std.ArrayList(MenuItem) = .empty;
        const spaces = b.kea.spaces.value;
        for (spaces) |s| if (!s.id.eql(b.space_id)) {
            var it = try add.item(try arena.dupe(u8, s.name), .to_space, s.id, false);
            it.image_symbol = s.symbol();
            try sub.append(arena, it);
        };
        if (spaces.len > 1) try sub.append(arena, .separator);
        try sub.append(arena, try add.plain("New Space…", .new_space, false));
        try out.append(arena, .{ .label = "Move to Space", .submenu = sub.items, .tooltip = "Pages moved to a Space with different sign-ins reopen there." });
    }
    if (comptime split) if (prefs.split_view) {
        if (b.splitFor(tab) != null) {
            try out.append(arena, try add.plain("Swap Pages", .swap, false));
            try out.append(arena, try add.plain("Separate Split Tabs", .separate, false));
            try out.append(arena, try add.plain("Close Both Pages", .close_both, false));
        } else try out.append(arena, try add.plain("Open in Split View", .open_split, false));
    };
    if (tab.pin == null) {
        // Another window, or a new one (Browser.moveToWindow).
        var others: std.ArrayList(*Browser) = .empty;
        for (b.kea.browsers.items) |o| if (o != b and o.window != null) try others.append(arena, o);
        const lone = b.tabs.items.len < 2;
        if (others.items.len == 0) {
            try out.append(arena, try add.plain("Move to New Window", .new_window, lone));
        } else {
            var sub: std.ArrayList(MenuItem) = .empty;
            try sub.append(arena, try add.plain("New Window", .new_window, lone));
            try sub.append(arena, .separator);
            for (others.items) |o| try sub.append(arena, try add.item(try windowName(arena, o), .to_window, o.record_id, false));
            try out.append(arena, .{ .label = "Move to Window", .submenu = sub.items });
        }
    }
    try out.append(arena, .separator);
    try out.append(arena, try add.plain("Rename", .rename, !editing));
    try out.append(arena, try add.plain("Duplicate", .duplicate, tab.isBlank()));
    // The card a click on the tab you are on shows under its address.
    try out.append(arena, try add.plain("Site Information…", .site_info, !editing or tab.isBlank() or tab.pin != null));
    try out.append(arena, try add.plain("Copy Address", .copy_address, tab.isBlank()));
    try out.append(arena, try add.plain("Copy as Markdown Link", .copy_link, tab.isBlank()));
    if (comptime syncs) try out.append(arena, try b.kea.sync.sendMenu(arena, b, tab));
    try out.append(arena, try add.plain(if (tab.muted) "Unmute Tab" else "Mute Tab", .mute, false));
    // Let go of now, as after ten minutes unseen; not the tab on screen,
    // nor one that has to stay awake.
    const awake = if (comptime sleeps) b.awake(tab) != null else true;
    try out.append(arena, try add.plain("Put to Sleep", .sleep, awake));
    try out.append(arena, .separator);
    try out.append(arena, try add.plain("Close Tab", .close, false));
    try out.append(arena, try add.plain("Close Other Tabs", .close_others, b.tabs.items.len < 2));
    // ⇧⌘T, and History › Recently Closed: here too, where tabs are closed.
    var buf: [64]u8 = undefined;
    try out.append(arena, try add.plain(try arena.dupe(u8, b.reopenTitle(&buf)), .reopen, b.ghosts.items.len == 0));
    return out.items;
}

/// `windowName`: how a menu names a window — its page in front, and its
/// space when there are spaces.
fn windowName(arena: std.mem.Allocator, b: *Browser) ![]const u8 {
    const page = if (b.tabById(b.active_id)) |t| (if (t.isBlank()) "New Tab" else t.label()) else "Window";
    if (!b.prefs.uses_spaces) return arena.dupe(u8, page);
    return std.fmt.allocPrint(arena, "{s} — {s}", .{ page, b.space().name });
}
