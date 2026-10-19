//! The window (`ContentView`, App.swift:404-776): the ground, one stage for
//! the page beside the column or under the strip, the bookmarks bar, and
//! what goes over them in Swift's order — Fold, bars, Peek, the field,
//! panels and sheets, the tab switcher, the import's progress — then the
//! one open overlay. Every hole box is left unpainted, its ancestors too:
//! the strip, column, bars and panels paint themselves beside the stage.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const palette = @import("../design/palette.zig");
const Palette = palette.Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");
const Room = @import("room.zig").Room;
const panels = @import("panels.zig");
const side_bar = @import("side_bar.zig");
const fold = @import("fold.zig");
const space_swipe = @import("space_swipe.zig");
const spaces_view = @import("spaces_view.zig");
const groups_view = @import("groups_view.zig");
const tab_bar = @import("tab_bar.zig");
const overlays = @import("overlays.zig");
const controls = @import("controls.zig");
const browsers = @import("../app/browsers.zig");
const page_layers = @import("page_layers.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

const slide_id: u64 = std.hash.Wyhash.hash(0, "kea.room.slide");

pub fn view(b: *Browser, c: *ui.Context) void {
    const p = palette.get(c.theme.dark);
    // The strip and the column say where the window is dragged from.
    c.title_bar_height = 0;
    handleShortcuts(b, c);
    space_swipe.frame(b, c);
    groups_view.beginFrame(b);

    const r = room(b, c);
    applyGround(b, p, r);
    const chrome = r.chrome();
    const roomed = b.room.roomed(chrome, c.time, c.reduce_motion);
    if (b.room.due) |d| c.frameIn(@floatCast(@max(0, d - c.time)));
    // The chrome slides on Motion.glide; the page's room does not.
    const still = b.room.still *% 2;
    const slide: ui.Size = .{ .w = motion.glideTo(c, slide_id, still, chrome.w), .h = motion.glideTo(c, slide_id, still + 1, chrome.h) };

    drawStageRow(b, c, p, r, roomed, slide);

    // The column, from the window's top: the lights sit in its own corner.
    // Placed by its own side, so a column leaving the right goes out on the right.
    const right = r.sideOnRight();
    if (r.sidebar() or slide.w > chrome.w + 0.5) {
        const on_right = b.prefs.side_position == .right;
        const x = if (on_right) c.size.w - slide.w else slide.w - b.prefs.side_width;
        side_bar.sideBar(b, c, p, r.cards(), x);
    }
    if (!b.prefs.sidebar and !r.folded and !r.fullscreen) tab_bar.tabBar(b, c, p);
    if (r.barShown()) drawBookmarksBar(b, c, p, r);
    if (!r.fullscreen) fold.view(b, c, p);

    // Over everything, in App.swift's order. Fold, bars, Peek, panels and
    // sheets, the tab switcher and the import's card come with their phases.
    if (b.omni_open) {
        const lead: f32 = if (r.sidebar() and !right) b.prefs.side_width else 0;
        const trail: f32 = if (r.sidebar() and right) b.prefs.side_width else 0;
        panels.omnibox(b, c, p, .{ .x = lead, .y = 0, .w = c.size.w - lead - trail, .h = c.size.h });
    }
    drawOverlay(b, c, p);
}

/// This frame's window, as ContentView reads it.
fn room(b: *Browser, c: *ui.Context) Room {
    const prefs = b.prefs;
    return .{
        .sidebar_pref = prefs.sidebar,
        .folded = b.folded,
        .side_right = prefs.side_position == .right,
        .side_width = prefs.side_width,
        .bar_pref = prefs.bookmarks_bar,
        .has_bookmarks = b.bookmarks.roots.len > 0,
        .marks_asked = b.marks_open,
        .marks_popped = prefs.marks_popped,
        .marks_expanded = b.marks_expanded,
        .chat_popped = prefs.chat_popped,
        .chat_width_pref = prefs.chat_width,
        .marks_width_pref = prefs.marks_width,
        .window_width = c.size.w,
    };
}

/// The window's ground (`ContentView.window_`'s first layer): black under
/// a page filling the screen, the card's ground beside the column, the
/// page's own otherwise. Given to the NSWindow only when it changes.
fn applyGround(b: *Browser, p: *const Palette, r: Room) void {
    const g = if (r.fullscreen) ui.Color.black else if (r.cards()) p.frame else p.ground;
    if (b.applied_ground) |a| if (std.meta.eql(a, g)) return;
    b.applied_ground = g;
    const w = b.window orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const color = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, g.r), @as(f64, g.g), @as(f64, g.b), @as(f64, g.a),
    });
    objc.msg(void, w.nswindow, "setBackgroundColor:", .{color});
}

/// The panels on their sides and the stage between them, inside the room
/// the chrome leaves, slid as the chrome slides.
fn drawStageRow(b: *Browser, c: *ui.Context, p: *const Palette, r: Room, roomed: ui.Size, slide: ui.Size) void {
    const right = r.sideOnRight();
    const far = r.farGap();
    const pad: ui.Edges = .{
        .left = if (right) far else roomed.w,
        .right = if (right) roomed.w else far,
        .top = roomed.h,
        .bottom = far,
    };
    ui.row(c, .{
        .absolute = true,
        .width = .fill,
        .height = .fill,
        .padding = pad,
        .offset = .{ .x = if (right) 0 else slide.w - roomed.w, .y = slide.h - roomed.h },
    });
    defer ui.end(c);
    const marks_left = b.prefs.effectiveMarksSide() == .left;
    const marks_w = r.marksWidth();
    if (r.marksShown() and marks_left) panels.marksPanel(b, c, p, true, marks_w);
    const stage_w = c.size.w - pad.left - pad.right - if (r.marksShown()) marks_w else 0;
    drawStage(b, c, p, r, stage_w, marks_left);
    if (r.marksShown() and !marks_left) panels.marksPanel(b, c, p, false, marks_w);
}

/// The stage: one page, or two side by side with Split View, a card in
/// the card's mode; and the panel let out over it.
fn drawStage(b: *Browser, c: *ui.Context, p: *const Palette, r: Room, stage_w: f32, marks_left: bool) void {
    const split_tab = if (b.prefs.split_view and b.split_right_id != null) b.tabById(b.split_right_id.?) else null;
    _ = c.open(.{ .direction = .row, .grow = 1, .height = .fill }, "kea.stage");
    defer c.end();
    const left = drawPane(b, c, p, b.tabById(b.active_id), "stage-left", if (split_tab != null) b.split_fraction else 1.0, b.focused_pane == .left or split_tab == null);
    if (r.cards() and !b.prefs.split_view) card.cardEdge(c, left);
    if (split_tab) |rt| {
        drawDivider(b, c, p);
        _ = drawPane(b, c, p, rt, "stage-right", 1.0 - b.split_fraction, b.focused_pane == .right);
    }
    // Let out over the page (`letOut`), on the panel's side.
    if (b.marks_expanded and r.marksColumn() and !r.marks_popped) {
        const w = @min(760, stage_w);
        ui.column(c, .{ .absolute = true, .offset = .{ .x = if (marks_left) 0 else stage_w - w }, .width = px(w), .height = .fill });
        panels.marksPanel(b, c, p, marks_left, null);
        ui.end(c);
    }
}

/// The 7-point gutter between two pages; dragged, it moves their boundary.
fn drawDivider(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const i = c.open(.{ .width = px(7), .height = .fill, .align_items = .center, .justify = .center }, "split-divider");
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .splitter, "Split View divider", "", false, true);
    if (it.hovered or it.pressed) c.cursor = .resize_left_right;
    if (it.double_clicked) {
        b.evenSplit();
    } else if (it.pressed) {
        const total_w = @max(100, b.left_pane_frame.w + b.right_pane_frame.w);
        const rel_x = c.input.mouse.x - b.left_pane_frame.x;
        b.split_fraction = std.math.clamp(rel_x / total_w, 0.2, 0.8);
        c.changed = true;
    }
    _ = c.leaf(.{ .width = px(1), .height = .fill, .background = p.faint }, .none, null);
}

/// One page's hole, and what stands over that page alone (`page_layers`)
/// and the find pill. Returns the hole's box.
fn drawPane(b: *Browser, c: *ui.Context, p: *const Palette, tab_opt: ?*Tab, key_name: []const u8, weight: f32, focused: bool) u32 {
    const idx = c.open(.{ .grow = @max(0.1, weight), .height = .fill, .align_items = .center, .justify = .center }, key_name);
    defer c.end();
    c.addStageHoleNode(idx);
    if (tab_opt) |t| page_layers.draw(c, p, t);
    if (focused and b.find_open) panels.findBar(b, c, p);
    return idx;
}

/// `BookmarksBar`: under the strip, or beside the column's top on the
/// card's ground, no wider than the card.
fn drawBookmarksBar(b: *Browser, c: *ui.Context, p: *const Palette, r: Room) void {
    const right = r.sideOnRight();
    const lead = if (right) r.farGap() else r.chrome().w;
    const trail = if (right) r.chrome().w else r.farGap();
    const on_frame = r.cards();
    ui.row(c, .{
        .absolute = true,
        .offset = .{ .x = lead, .y = r.band() },
        .width = px(c.size.w - lead - trail),
        .height = px(@import("room.zig").bar_height),
        .padding = .xy(10, 0),
        .gap = 2,
        .align_items = .center,
        .background = if (on_frame) p.frame else p.ground,
        .scroll_x = true,
        .scroll_bar = false,
    });
    defer ui.end(c);
    if (!on_frame) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = -10, .y = @import("room.zig").bar_height - 1 }, .width = px(c.size.w - lead - trail), .height = px(1), .background = p.hairline }, .none, null);
    for (b.bookmarks.roots, 0..) |bm, idx| {
        ui.key(c, c.print("bm-bar-{d}", .{idx}));
        const folder = bm.children != null;
        const i = c.open(.{ .direction = .row, .gap = 6, .padding = .xy(8, 0), .height = px(22), .radius = 6, .align_items = .center, .control = true }, null);
        const it = c.interact(i, .{});
        c.help(i, bm.url orelse bm.title);
        c.addA11y(i, .button, bm.title, "", false, true);
        if (it.hovered) c.node(i).style.background = p.hover;
        ui.icon(c, if (folder) "folder" else "globe", .{ .size = 10.5, .color = p.muted });
        ui.column(c, .{ .max_width = 150 });
        ui.text(c, bm.title, .{ .size = 12, .color = p.ink, .truncate = true });
        ui.end(c);
        if (folder) ui.icon(c, "chevron.down", .{ .size = 7.5, .weight = .semibold, .color = p.faint });
        c.end();
        if (bm.url) |u| {
            if (it.clicked) b.goUrl(u);
            if (it.middle_clicked) _ = b.open(u, .{ .foreground = false, .from = b.activeTab(), .may_wait = true });
        }
    }
}

/// The one overlay open over the window, last so it takes the clicks
/// over it (`chrome/overlays.zig`). What each shows comes with the phase
/// that opens it.
fn drawOverlay(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (!overlays.begin(c, &b.overlay, b.overlay_anchor, .{ .background = p.ground, .radius = 14, .border = p.hairline, .clip = true }, .{})) return;
    switch (b.overlay.?) {
        .space_icons => spaces_view.iconsPopover(b, c, p),
        else => {},
    }
    ui.end(c);
}

/// A new tab in front, the field up over it (`Browser.newTab`).
pub fn newTab(b: *Browser) void {
    b.newTab();
    b.omni_open = true;
    b.omni_buf.clear();
}

/// The field up over the page, holding its address (⌘L).
pub fn editAddress(b: *Browser) void {
    b.omni_open = true;
    if (b.activeTab()) |t| b.omni_buf.set(t.url());
}

fn handleShortcuts(b: *Browser, c: *ui.Context) void {
    if (c.shortcut(.{ .key = 'n', .cmd = true })) {
        // ponytail: here until P8's command registry takes ⌘N.
        _ = browsers.newWindow(b.kea) catch {};
    } else if (c.shortcut(.{ .key = 't', .cmd = true, .shift = true })) {
        b.reopen();
    } else if (c.shortcut(.{ .key = 't', .cmd = true })) {
        newTab(b);
    } else if (c.shortcut(.{ .key = 'w', .cmd = true })) {
        b.closeFront();
    } else if (c.shortcut(.{ .key = 'l', .cmd = true })) {
        editAddress(b);
    } else if (c.shortcut(.{ .key = 'r', .cmd = true })) {
        if (b.activeTab()) |t| t.reload();
    } else if (c.shortcut(.{ .key = '.', .cmd = true })) {
        if (b.activeTab()) |t| t.stopLoading();
    } else if (c.shortcut(.{ .key = 'f', .cmd = true })) {
        b.find_open = !b.find_open;
    } else if (c.shortcut(.{ .key = 's', .cmd = true, .ctrl = true })) {
        b.prefs.set("sidebar", !b.prefs.sidebar);
        b.syncStageHost();
    } else if (c.shortcut(.{ .key = 's', .cmd = true })) {
        // ponytail: here until P8's command registry takes `view.fold`.
        fold.toggleFold(b);
    } else if (if (b.prefs.uses_spaces) spaceDigit(c) else null) |n| {
        // ⌃1…⌃9, the spaces in their order, only with spaces on (`ContentView.take`).
        b.switchSpaceIndex(n);
    } else if (c.shortcut(.{ .key = 'b', .cmd = true, .ctrl = true })) {
        b.marks_open = !b.marks_open;
        b.syncStageHost();
    } else if (c.shortcut(.{ .key = 'b', .cmd = true, .shift = true })) {
        b.prefs.set("bookmarks_bar", !b.prefs.bookmarks_bar);
    } else if (c.shortcut(.{ .key = 'd', .cmd = true })) {
        if (b.activeTab()) |t| {
            if (b.bookmarks.bookmarkFor(t.url())) |kept| {
                b.bookmarks.remove(&.{kept.id});
                b.announce("Bookmark removed");
            } else if (b.bookmarks.add(t.url(), t.title()) != null) b.announce("Bookmark added");
        }
    } else if (c.shortcut(.{ .key = '+', .cmd = true }) or c.shortcut(.{ .key = '=', .cmd = true })) {
        // ponytail: here until P8's command registry takes `view.zoomIn` and its kin.
        if (b.activeTab()) |t| t.magnifyBy(1.1);
    } else if (c.shortcut(.{ .key = '-', .cmd = true })) {
        if (b.activeTab()) |t| t.magnifyBy(1.0 / 1.1);
    } else if (c.shortcut(.{ .key = '0', .cmd = true })) {
        if (b.activeTab()) |t| t.resetZoom();
    } else if (c.shortcut(.{ .key = '[', .cmd = true })) {
        if (b.activeTab()) |t| t.goBack();
    } else if (c.shortcut(.{ .key = ']', .cmd = true })) {
        if (b.activeTab()) |t| t.goForward();
    } else if (c.shortcut(.{ .key = '\t', .ctrl = true, .shift = true })) {
        b.step(-1);
    } else if (c.shortcut(.{ .key = '\t', .ctrl = true })) {
        b.step(1);
    } else if (b.overlay == null and c.shortcut(.{ .key = 0x1b })) {
        if (b.omni_open) {
            b.omni_open = false;
            b.omni_chip = null;
        } else if (b.find_open) {
            b.find_open = false;
        } else if (b.activeTab()) |t| {
            if (t.loading) t.stopLoading();
        }
    }
}

fn spaceDigit(c: *ui.Context) ?usize {
    for (0..9) |n| if (c.shortcut(.{ .key = @intCast('1' + n), .ctrl = true })) return n;
    return null;
}
