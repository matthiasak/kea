//! Compact touch chrome for iPhone (`< 600pt`) and touch toolbar doors for
//! iPadOS (`>= 600pt`): thumb-reachable bottom navigation + address pill +
//! `[N]` visual tab switcher + `✦` Ubi Chat + `⋯` Tools & Settings sheet.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const platform = @import("../sys/platform.zig");
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("controls.zig");
const site_card = @import("site_card.zig");
const tab_menu = @import("tab_menu.zig");
const tab_switcher = @import("tab_switcher.zig");
const sheet = @import("sheet.zig");
const history_panel = @import("history_panel.zig");
const downloads_panel = @import("downloads_panel.zig");
const page_find = @import("../web/page_find.zig");
const reader = @import("../web/reader.zig");

pub const height: f32 = 56;

fn px(n: f32) ui.Length {
    return .{ .px = n };
}

/// Compact single-hand phone layout (`< 600pt` on iOS/iPadOS Slide Over).
pub fn isCompactPhone(window_w: f32) bool {
    return platform.is_ios and window_w > 0 and window_w < 600;
}

/// Narrow touch viewport (`< 900pt` on iOS/iPadOS Split View): panels &
/// sidebars present as overlays instead of squeezing the webpage column.
pub fn isNarrowOverlay(window_w: f32) bool {
    return platform.is_ios and window_w > 0 and window_w < 900;
}

/// Extra touch doors on iPadOS top `TabBar` (`>= 600pt` where macOS uses the menu bar).
pub fn iosStripDoors(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (comptime !platform.is_ios) return;
    const side_on = b.prefs.sidebar and !b.folded;
    if (controls.door(c, p, "sidebar.left", .{ .on = side_on, .help = "Toggle Sidebar" }).clicked) toggleTouchSidebar(b, c.size.w);
    if (controls.door(c, p, "sparkles", .{ .on = b.assisting != null, .help = "Ubi Chat" }).clicked) b.toggleChat();
    toolsDoor(b, c, p);
}

/// Extra touch doors in iPadOS `SideBar` foot (`sparkles` + `⋯` + collapse).
pub fn iosSidebarFootDoors(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (comptime !platform.is_ios) return;
    if (controls.door(c, p, "sidebar.left", .{ .on = true, .help = "Hide Sidebar" }).clicked) toggleTouchSidebar(b, c.size.w);
    if (controls.door(c, p, "sparkles", .{ .on = b.assisting != null, .help = "Ubi Chat" }).clicked) b.toggleChat();
    toolsDoor(b, c, p);
}

fn toggleTouchSidebar(b: *Browser, window_w: f32) void {
    if (isNarrowOverlay(window_w)) {
        if (!b.prefs.sidebar) {
            b.prefs.set("sidebar", true);
            b.folded = false;
        } else {
            b.folded = !b.folded;
        }
    } else {
        b.prefs.set("sidebar", !b.prefs.sidebar);
        b.folded = false;
    }
    b.syncStageHost();
    b.redraw();
}

fn toolsDoor(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const it = controls.door(c, p, "ellipsis.circle", .{ .help = "Tools & Settings" });
    if (it.clicked) {
        const at: ui.Point = if (it.rect) |r| .{ .x = r.x + r.w / 2, .y = r.y + r.h } else c.input.mouse;
        tab_menu.later(b, at, 0, buildToolsMenu);
    }
}

/// Dedicated thumb-reachable bottom bar for compact `< 600pt` iOS viewports.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (comptime !platform.is_ios) return;
    const tab = b.activeTab();
    const can_back = if (tab) |t| (!t.isBlank() and t.can_go_back) else false;
    const can_fwd = if (tab) |t| (!t.isBlank() and t.can_go_forward) else false;
    const loading = if (tab) |t| t.loading else false;
    const blank = if (tab) |t| t.isBlank() else true;

    const root = c.open(.{
        .absolute = true,
        .offset = .{ .x = 0, .y = @max(0, c.size.h - height) },
        .width = .fill,
        .height = px(height),
        .direction = .column,
        .background = p.ground,
    }, "kea.compact_bar");
    defer c.end();
    _ = c.interact(root, .{});
    _ = c.leaf(.{ .width = .fill, .height = px(1), .background = p.hairline }, .none, null);

    ui.row(c, .{ .width = .fill, .grow = 1, .padding = .{ .left = 6, .right = 6 }, .gap = 4, .align_items = .center });
    defer ui.end(c);

    ui.row(c, .{ .opacity = if (can_back) 1 else 0.3 });
    const back_it = controls.door(c, p, "chevron.left", .{ .help = "Back" });
    ui.end(c);
    if (can_back and back_it.clicked) if (tab) |t| t.goBack();

    if (can_fwd or c.size.w >= 380) {
        ui.row(c, .{ .opacity = if (can_fwd) 1 else 0.3 });
        const fwd_it = controls.door(c, p, "chevron.right", .{ .help = "Forward" });
        ui.end(c);
        if (can_fwd and fwd_it.clicked) if (tab) |t| t.goForward();
    }

    // Center address / search pill (40pt high, full remaining width).
    const pill = c.open(.{
        .grow = 1,
        .min_width = 80,
        .height = px(40),
        .radius = controls.capsule,
        .background = p.wash,
        .border = p.hairline,
        .direction = .row,
        .align_items = .center,
        .padding = .{ .left = 12, .right = 6 },
        .gap = 6,
        .control = true,
    }, "kea.compact.address");
    const pill_it = c.interact(pill, .{});
    const host = if (tab) |t| (if (blank) "Search or enter address" else site_card.site(t.url())) else "Search or enter address";
    c.addA11y(pill, .button, "Address and Search", host, false, true);
    const secure = if (tab) |t| std.ascii.startsWithIgnoreCase(t.url(), "https://") else false;
    ui.icon(c, if (blank) "magnifyingglass" else if (secure) "lock.fill" else "globe", .{
        .size = 11,
        .weight = .medium,
        .color = p.muted,
    });
    ui.row(c, .{ .grow = 1, .min_width = 0, .justify = .center });
    ui.text(c, host, .{ .size = 13.5, .weight = if (blank) .regular else .medium, .color = if (blank) p.muted else p.ink, .truncate = .ellipsis });
    ui.end(c);

    var reload_clicked = false;
    if (!blank) {
        const rel = c.open(.{ .width = px(32), .height = px(32), .radius = 16, .align_items = .center, .justify = .center, .control = true }, null);
        const rel_it = c.interact(rel, .{});
        c.addA11y(rel, .button, if (loading) "Stop" else "Reload", "", false, true);
        ui.icon(c, if (loading) "xmark" else "arrow.clockwise", .{ .size = 12, .weight = .medium, .color = p.muted });
        c.end();
        if (rel_it.clicked) {
            reload_clicked = true;
            if (tab) |t| if (loading) t.stopLoading() else t.reload(false);
        }
    }
    c.end();
    if (pill_it.clicked and !reload_clicked) b.edit();

    // [N] Visual Tab Switcher button (44x44pt).
    const count = b.displayedTabs().len;
    const tabs_btn = c.open(.{ .width = px(44), .height = px(44), .radius = 10, .align_items = .center, .justify = .center, .control = true }, "kea.compact.tabs");
    const tabs_it = c.interact(tabs_btn, .{});
    const count_str = c.print("{d}", .{@max(@as(usize, 1), count)});
    c.addA11y(tabs_btn, .button, "Show Tabs", count_str, b.switcher.visible, true);
    if (tabs_it.pressed) c.node(tabs_btn).style.background = p.side_hover;
    _ = c.open(.{ .min_width = 21, .height = px(21), .padding = .xy(4, 0), .radius = 6, .border = if (b.switcher.visible) p.ink else p.muted, .border_width = 1.5, .align_items = .center, .justify = .center }, null);
    ui.text(c, count_str, .{ .size = 11, .weight = .semibold, .color = if (b.switcher.visible) p.ink else p.muted, .tabular = true });
    c.end();
    c.end();
    if (tabs_it.clicked) tab_switcher.toggleGrid(b);

    // Ubi Chat + Tools & Settings doors (44x44pt each).
    if (controls.door(c, p, "sparkles", .{ .on = b.assisting != null, .help = "Ubi Chat" }).clicked) b.toggleChat();
    toolsDoor(b, c, p);
}

const Action = enum {
    new_tab,
    private_tab,
    bookmark_add,
    bookmarks,
    history,
    downloads,
    passwords,
    find_page,
    reader_mode,
    summarize,
    share_page,
    print_page,
    settings,
};

const ToolPick = struct {
    b: *Browser,
    act: Action,

    fn run(tp: *ToolPick, _: *nanoui.menu.Item) void {
        const b = tp.b;
        switch (tp.act) {
            .new_tab => b.newTab(),
            .private_tab => b.newShyTab(),
            .bookmark_add => b.bookmarkCurrent(),
            .bookmarks => sheet.show(b, .bookmarking),
            .history => history_panel.toggle(b),
            .downloads => downloads_panel.toggle(b),
            .passwords => sheet.show(b, .managing),
            .find_page => page_find.openFind(b),
            .reader_mode => reader.toggleReader(b),
            .summarize => b.summarizePage(),
            .share_page => b.share(),
            .print_page => b.printPage(),
            .settings => sheet.toggle(b, .tuning),
        }
    }
};

fn item(arena: std.mem.Allocator, b: *Browser, label: []const u8, act: Action, disabled: bool) !MenuItem {
    const tp = try arena.create(ToolPick);
    tp.* = .{ .b = b, .act = act };
    return .{ .label = label, .disabled = disabled, .click = .of(tp, ToolPick.run) };
}

fn buildToolsMenu(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const blank = if (b.activeTab()) |t| t.isBlank() else true;
    var list: std.ArrayList(MenuItem) = .empty;
    try list.append(arena, try item(arena, b, "New Tab", .new_tab, false));
    try list.append(arena, try item(arena, b, "New Private Tab", .private_tab, false));
    try list.append(arena, try item(arena, b, "Bookmark This Page", .bookmark_add, blank));
    try list.append(arena, try item(arena, b, "Bookmarks\u{2026}", .bookmarks, false));
    try list.append(arena, try item(arena, b, "History\u{2026}", .history, false));
    try list.append(arena, try item(arena, b, "Downloads\u{2026}", .downloads, false));
    try list.append(arena, try item(arena, b, "Passwords\u{2026}", .passwords, false));
    try list.append(arena, try item(arena, b, "Find on Page\u{2026}", .find_page, blank));
    try list.append(arena, try item(arena, b, "Reading Mode", .reader_mode, blank));
    try list.append(arena, try item(arena, b, "Summarize Page", .summarize, blank));
    try list.append(arena, try item(arena, b, "Share\u{2026}", .share_page, blank));
    try list.append(arena, try item(arena, b, "Print\u{2026}", .print_page, blank));
    try list.append(arena, try item(arena, b, "Settings\u{2026}", .settings, false));
    return list.items;
}

test "compact bar viewport thresholds follow platform" {
    if (comptime platform.is_ios) {
        try std.testing.expect(isCompactPhone(393));
        try std.testing.expect(!isCompactPhone(678));
        try std.testing.expect(isNarrowOverlay(678));
        try std.testing.expect(!isNarrowOverlay(1024));
    } else {
        try std.testing.expect(!isCompactPhone(393));
        try std.testing.expect(!isNarrowOverlay(678));
    }
}
