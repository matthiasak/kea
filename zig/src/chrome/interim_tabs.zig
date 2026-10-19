//! The tabs across the top and down the side, in Kea's colours and sizes,
//! with the drag strips, lights corners and doors of TabBar.swift and
//! Side.swift: what the window shows until P4 ports `TabBar` and `SideBar`
//! (`tab_bar.zig`, `side_bar.zig`), which replace this file.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const controls = @import("controls.zig");
const panels = @import("panels.zig");
const window_view = @import("window_view.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// `DragStrip`: empty chrome that moves the window. A double click opens
/// a new tab where the strip is an empty tab row (`onDoubleClick`), and
/// otherwise does what a title bar's does: fills the screen.
// ponytail: zooms whatever `AppleActionOnDoubleClick` says; read it when someone sets Minimize.
fn dragStrip(b: *Browser, c: *ui.Context, style: ui.Style, new_tab: bool) void {
    var s = style;
    s.window_drag = true;
    const i = c.open(s, null);
    c.end();
    const it = c.interact(i, .{});
    // The window's background, not a control: no hand over it.
    if (c.hot == it.id) c.cursor_hand = false;
    if (!it.double_clicked) return;
    if (new_tab) window_view.newTab(b) else if (b.window) |w| w.zoom();
}

/// `Helm`: back, forward, and reload or stop, greyed where there's nowhere to go.
fn helm(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.row(c, .{ .gap = 4, .align_items = .center });
    defer ui.end(c);
    const tab = b.activeTab();
    const blank = if (tab) |t| t.url().len == 0 else true;
    const back = !blank and tab.?.can_go_back;
    const forward = !blank and tab.?.can_go_forward;
    const loading = tab != null and tab.?.loading;
    if (door(c, p, "chevron.left", "Back   ⌘[", back)) tab.?.goBack();
    if (door(c, p, "chevron.right", "Forward   ⌘]", forward)) tab.?.goForward();
    if (door(c, p, if (loading) "xmark" else "arrow.clockwise", if (loading) "Stop   ⌘." else "Reload   ⌘R", !blank)) {
        if (loading) tab.?.stopLoading() else tab.?.reload();
    }
}

/// A door that can't be used is dimmed to .3 and takes no clicks.
fn door(c: *ui.Context, p: *const Palette, icon: []const u8, help: []const u8, enabled: bool) bool {
    ui.row(c, .{ .opacity = if (enabled) 1 else 0.3 });
    defer ui.end(c);
    return controls.door(c, p, icon, .{ .help = help }).clicked and enabled;
}

fn marksDoor(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (controls.door(c, p, "book", .{ .on = b.marks_open, .help = "Bookmarks   ⌃⌘B" }).clicked) {
        b.marks_open = !b.marks_open;
        b.syncStageHost();
    }
}

/// The strip: the lights' corner, the tabs, the plus, the empty run
/// that moves the window, and the doors at the far end.
pub fn topBar(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.row(c, .{ .absolute = true, .width = .fill, .height = px(metrics.strip), .align_items = .center, .padding = .{ .right = 12 } });
    defer ui.end(c);
    dragStrip(b, c, .{ .width = px(metrics.lights), .height = .fill }, false);

    // Their share of the row between the lights and the doors, 36 to 186.
    const doors: f32 = 4 * 26 + 3 * 4 + 8;
    const room = c.size.w - metrics.lights - 12 - doors - metrics.plus_width - 2 * metrics.tab_gap;
    const n: f32 = @floatFromInt(@max(1, b.tabs.items.len));
    const each = std.math.clamp(room / n - metrics.tab_gap, metrics.tab_min_width, metrics.tab_width);
    ui.row(c, .{ .height = .fill, .align_items = .center, .gap = metrics.tab_gap, .clip = true, .min_width = 0 });
    for (b.tabs.items) |t| topTab(b, c, p, t, each);
    ui.end(c);
    ui.row(c, .{ .padding = .{ .left = metrics.tab_gap } });
    if (controls.door(c, p, "plus", .{ .help = "New Tab   ⌘T" }).clicked) window_view.newTab(b);
    ui.end(c);

    dragStrip(b, c, .{ .grow = 1, .height = .fill }, true);
    ui.row(c, .{ .gap = 4, .align_items = .center });
    helm(b, c, p);
    ui.row(c, .{ .padding = .{ .left = 8 } });
    marksDoor(b, c, p);
    ui.end(c);
    ui.end(c);
}

fn live(b: *Browser, t: *const Tab) bool {
    return t.id == b.active_id or (b.split_right_id != null and t.id == b.split_right_id.?);
}

fn topTab(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, width: f32) void {
    ui.key(c, c.print("top-tab-{d}", .{t.id}));
    const on = live(b, t);
    const i = c.open(.{ .direction = .row, .width = px(width), .height = px(30), .padding = .xy(10, 0), .radius = 9, .align_items = .center, .gap = 6, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, t.title());
    c.addA11y(i, .tab, t.title(), "", on, true);
    c.node(i).style.background = if (on) p.pin_live else if (it.hovered) p.hover else null;
    ui.text(c, if (t.title().len > 0) t.title() else "New Tab", .{ .size = 12.5, .color = if (on) p.ink else p.muted, .truncate = true });
    ui.spacer(c);
    const close = controls.closeDisc(c, p, it.hovered, controls.close_zone);
    if (close.clicked or it.middle_clicked) return b.closeTab(t.id);
    if (it.clicked) b.selectTab(t.id);
}

/// The column, `x` from the window's left: the lights' band with the
/// helm beside the lights, the rows, New Tab, the foot, and the edge.
pub fn sideBar(b: *Browser, c: *ui.Context, p: *const Palette, on_left: bool, on_frame: bool, x: f32) void {
    const w = b.prefs.side_width;
    _ = c.open(.{ .absolute = true, .offset = .{ .x = x }, .width = px(w), .height = .fill, .clip = true, .background = if (on_frame) p.frame else p.ground }, "side-bar");
    defer c.end();
    // Below the rows: an empty tab row, which opens a new tab on a double click.
    dragStrip(b, c, .{ .absolute = true, .width = .fill, .height = .fill }, true);
    // The band the lights sit in is this mode's title bar.
    ui.row(c, .{ .absolute = true, .width = .fill, .height = px(metrics.strip) });
    dragStrip(b, c, .{ .width = px(10 + metrics.side_lights), .height = .fill }, false);
    _ = c.leaf(.{ .width = px(metrics.helm) }, .none, null);
    dragStrip(b, c, .{ .grow = 1, .height = .fill }, false);
    ui.end(c);

    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .{ .left = 10, .right = 10 } });
    ui.row(c, .{ .width = .fill, .height = px(metrics.strip), .align_items = .center, .padding = .{ .left = metrics.side_lights } });
    helm(b, c, p);
    ui.end(c);

    const active = b.activeTab();
    const addr = if (active) |t| (if (t.url().len > 0) t.url() else "Search or enter address") else "Search or enter address";
    if (controls.quiet(c, p, "magnifyingglass", addr, 28).clicked) window_view.editAddress(b);
    ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 2, .scroll_bar = false });
    for (b.tabs.items) |t| sideRow(b, c, p, t);
    if (controls.quiet(c, p, "plus", "New Tab", 28).clicked) window_view.newTab(b);
    ui.end(c);

    ui.row(c, .{ .width = .fill, .height = px(40), .align_items = .center });
    marksDoor(b, c, p);
    ui.end(c);
    ui.end(c);

    if (!on_frame) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = if (on_left) w - 1 else 0 }, .width = px(1), .height = .fill, .background = p.hairline }, .none, null);
    panels.edgeHandle(b, c, p, "side_width", metrics.side_min, metrics.side_max, metrics.side, on_left, if (on_left) w - 9 else 0);
}

fn sideRow(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab) void {
    ui.key(c, c.print("side-tab-{d}", .{t.id}));
    const on = live(b, t);
    const i = c.open(.{ .direction = .row, .width = .fill, .height = px(28), .padding = .xy(10, 0), .radius = 9, .align_items = .center, .gap = 8, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .tab, t.title(), "", on, true);
    c.node(i).style.background = if (on) p.side_wash else if (it.hovered) p.side_hover else null;
    ui.text(c, if (t.title().len > 0) t.title() else "New Tab", .{ .size = 12.5, .color = p.ink, .truncate = true });
    ui.spacer(c);
    const close = controls.closeDisc(c, p, it.hovered, controls.close_zone);
    if (close.clicked or it.middle_clicked) return b.closeTab(t.id);
    if (it.clicked) b.selectTab(t.id);
}
