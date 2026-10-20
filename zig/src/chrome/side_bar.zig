//! The tabs down either side instead of across the top (`SideBar`,
//! Side.swift:1-535): the lights' band with back, forward and reload
//! beside them, the spaces side by side as pages (two fingers sideways
//! bring the next), each page's pinned squares and rows, the foot, and the
//! column's edge. The rows are `side_rows.zig`, the squares `pin_grid.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const lights = @import("lights.zig");
const side_panels = @import("side_panels.zig");
const tab_bar = @import("tab_bar.zig");
const pin_grid = @import("pin_grid.zig");
const side_rows = @import("side_rows.zig");
const groups_view = @import("groups_view.zig");
const spaces_view = @import("spaces_view.zig");
const window_view = @import("window_view.zig");
const tab_leaving = @import("tab_leaving.zig");
const presence = @import("presence.zig");
const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// The foot's door and its margin beneath (`SideBar.footHeight`).
pub const foot_height: f32 = 26 + 10;

/// What the column keeps between frames (on `Browser.column`).
pub const State = struct {
    /// The grey under the live tab, sliding between rows and squares
    /// (`matchedGeometryEffect(id: "live")`): last frame's item, and this one's.
    pill: ?Pill = null,
    pill_next: ?Pill = null,
    /// Drawn this frame: the live item leaves its ground to it.
    pill_drawn: bool = false,
    /// The live row last scrolled into view.
    revealed: u64 = 0,
    reveal_to: ?f32 = null,
    // A group's name being typed, a heading carried, where headings were.
    group_draft: ui.TextBuffer = .{},
    group_claimed: ?Uuid = null,
    group_held: ?groups_view.Held = null,
    heading_rects: std.ArrayList(groups_view.HeadingRect) = .empty,
    heading_next: std.ArrayList(groups_view.HeadingRect) = .empty,
    // A pin's letter being typed, a square carried.
    pin_draft: ui.TextBuffer = .{},
    pin_claimed: u64 = 0,
    pin_focused: bool = false,
    pin_held: ?pin_grid.Held = null,
    /// What the column's layout was drawn from last frame (`signature`).
    shape: u64 = 0,
    /// Rows and pins drawn last frame and this frame, and leaving ghosts.
    seen: std.ArrayList(SeenRow) = .empty,
    last: std.ArrayList(SeenRow) = .empty,
    leaving: std.ArrayList(tab_leaving.Leaving) = .empty,
    snaps: std.AutoHashMapUnmanaged(u64, tab_leaving.Snap) = .empty,
    pin_seen: std.ArrayList(SeenPin) = .empty,
    pin_last: std.ArrayList(SeenPin) = .empty,
    pin_leaving: std.ArrayList(tab_leaving.Leaving) = .empty,
    pin_snaps: std.AutoHashMapUnmanaged(u64, tab_leaving.Snap) = .empty,
    drawn: bool = false,
    space: Uuid = Uuid.first,
    last_size: ui.Size = .{},
    last_width: f32 = 0,
    rows_node: u64 = 0,
    panel_win_w: f32 = 0,
    pub const SeenRow = struct { id: u64, x: f32, y: f32, w: f32 };
    pub const SeenPin = struct { id: u64, x: f32, y: f32, w: f32, h: f32 };
    pub const Pill = struct { item: u64, colour: ui.Color, radius: f32 };

    /// The live item (a row or a square) says where it is this frame.
    pub fn live(st: *State, item: u64, colour: ui.Color, radius: f32) void {
        st.pill_next = .{ .item = item, .colour = colour, .radius = radius };
    }

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        st.group_draft.deinit();
        st.pin_draft.deinit();
        st.heading_rects.deinit(gpa);
        st.heading_next.deinit(gpa);
        st.seen.deinit(gpa);
        st.last.deinit(gpa);
        for (st.leaving.items) |*l| l.snap.deinit(gpa);
        st.leaving.deinit(gpa);
        var it = st.snaps.valueIterator();
        while (it.next()) |s| s.deinit(gpa);
        st.snaps.deinit(gpa);
        st.pin_seen.deinit(gpa);
        st.pin_last.deinit(gpa);
        for (st.pin_leaving.items) |*l| l.snap.deinit(gpa);
        st.pin_leaving.deinit(gpa);
        var pit = st.pin_snaps.valueIterator();
        while (pit.next()) |s| s.deinit(gpa);
        st.pin_snaps.deinit(gpa);
    }
};

fn fullScreen(b: *const Browser) bool {
    const w = b.window orelse return false;
    return w.isFullScreen();
}

/// What the rows' places depend on: the row and its order, the tab in
/// front, pins, groups, the column's size, the space and its card.
fn signature(b: *Browser, c: *ui.Context) u64 {
    var h = std.hash.Wyhash.init(0);
    for (b.tabs.items) |t| {
        h.update(std.mem.asBytes(&t.id));
        h.update(&.{ @intFromBool(t.pin != null), @intFromBool(t.listed) });
        if (t.group_id) |g| h.update(&g.bytes);
    }
    for (b.tab_groups.items) |g| {
        h.update(&g.id.bytes);
        h.update(&.{@intFromBool(g.collapsed)});
    }
    h.update(std.mem.asBytes(&b.active_id));
    h.update(&b.space_id.bytes);
    h.update(&.{ @intFromBool(b.making_space), @intFromBool(b.prefs.uses_tab_groups), @intFromBool(b.prefs.showsPinRows()) });
    h.update(std.mem.asBytes(&b.prefs.side_width));
    h.update(std.mem.asBytes(&c.size));
    return h.final();
}

/// The column, `x` from the window's left. `on_frame`: beside the page's
/// card, on the window's ground, the card's edge being the line.
pub fn sideBar(b: *Browser, c: *ui.Context, p: *const Palette, on_frame: bool, x: f32) void {
    const st = &b.column;
    st.pill = st.pill_next;
    st.pill_next = null;
    st.pill_drawn = false;
    b.kea.swipe.start(b);
    // What sits where comes from the last layout: when the rows changed,
    // one more frame lets the grey and the scroll find them again.
    const shape = signature(b, c);
    if (shape != st.shape) {
        st.shape = shape;
        c.animating = true;
    }

    const w = b.prefs.side_width;
    const on_right = b.prefs.side_position == .right;
    const reserve: f32 = if (fullScreen(b)) 0 else metrics.side_lights;
    const root = c.open(.{ .absolute = true, .offset = .{ .x = x }, .width = px(w), .height = .fill, .clip = true, .motion_blur = true }, "side-bar");
    defer c.end();
    // A link let go of over the column becomes a tab.
    c.acceptDrop(root);
    const over = if (c.input.drag_over) |at| if (c.rects.get(c.node(root).id)) |r| r.contains(at) else false else false;
    ground(c, root, p, on_frame, over);
    if (c.dropAt(root)) |d| _ = b.take(d);

    // Under the rows, the window's own: dragged by, a double click a new tab.
    if (!b.making_space) {
        const end = rowsEnd(b, c);
        if (end < c.size.h) lights.dragStrip(b, c, .{ .absolute = true, .offset = .{ .y = end }, .width = .fill, .height = px(c.size.h - end) }, .new_tab);
    }
    // The band the lights sit in is this mode's title bar.
    _ = c.open(.{ .absolute = true, .direction = .row, .width = .fill, .height = px(metrics.strip) }, null);
    lights.dragStrip(b, c, .{ .width = px(10 + reserve), .height = .fill }, .zoom);
    _ = c.leaf(.{ .width = px(metrics.helm) }, .none, null);
    lights.dragStrip(b, c, .{ .grow = 1, .height = .fill }, .zoom);
    c.end();

    _ = c.open(.{ .direction = .column, .width = .fill, .height = .fill, .padding = .{ .bottom = foot_height } }, null);
    _ = c.open(.{ .direction = .row, .height = px(metrics.strip), .align_items = .center, .padding = .{ .left = 10 + reserve } }, null);
    tab_bar.helm(b, c, p);
    c.end();
    pages(b, c, p);
    c.end();

    foot(b, c, p);

    const inner_x: f32 = if (on_right) 0 else w - 1;
    if (!on_frame) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = inner_x }, .width = px(1), .height = .fill, .background = p.hairline }, .none, null);
    side_panels.edgeHandle(b, c, p, "side_width", metrics.side_min, metrics.side_max, metrics.side, !on_right, if (on_right) 0 else w - 9);
}

/// The column's ground: the window's beside the card, the page's otherwise,
/// the hover's grey while a link is held over it.
fn ground(c: *ui.Context, root: u32, p: *const Palette, on_frame: bool, landing: bool) void {
    const l = motion.quickTo(c, c.node(root).id, 0, if (landing) 1 else 0);
    c.node(root).style.background = (if (on_frame) p.frame else p.ground).mix(p.side_hover, l);
}

/// Where the rows stop and the window's own drag area starts, added up
/// from what is drawn rather than measured (`SideBar.rowsEnd`).
fn rowsEnd(b: *Browser, c: *ui.Context) f32 {
    const arena = c.alloc();
    const row = side_rows.row_height;
    const gap = side_rows.gap;
    const squares = b.squarePins(arena) catch @panic("OOM");
    var pin_block: f32 = 0;
    if (squares.len > 0) {
        const cells = pin_grid.pinCells(arena, squares.len, b.prefs.side_width) catch @panic("OOM");
        pin_block = pin_grid.extent(cells).h + 10;
    }
    const listed: f32 = @floatFromInt((b.listedPins(arena) catch @panic("OOM")).len);
    const loose_tabs = side_rows.looseTabs(b, arena);
    var list_block = listed * (row + gap) + (if (listed > 0) gap else 0);
    if (side_rows.showsLine(b, @intFromFloat(listed), loose_tabs.len)) list_block += side_rows.keep_line + gap;
    var rows: usize = loose_tabs.len;
    var headings: f32 = 0;
    if (b.prefs.uses_tab_groups) {
        for (b.tab_groups.items) |g| rows += (b.visibleTabsIn(arena, g) catch @panic("OOM")).len;
        headings = @as(f32, @floatFromInt(b.tab_groups.items.len)) * (groups_view.height + gap);
    }
    // A pair is two lines (SplitTabItem): a second row in its one place.
    var pairs: usize = 0;
    if (b.prefs.split_view) for (b.splits.items) |pair| {
        if (b.tabById(pair.left())) |t| pairs += @intFromBool(t.pin == null);
    };
    const loose_h = @as(f32, @floatFromInt(rows)) * (row + gap) + @as(f32, @floatFromInt(pairs)) * row + headings;
    return metrics.strip + pin_block + list_block + loose_h + row + 8;
}

// MARK: the spaces, as pages

fn spaceAt(b: *Browser) usize {
    return if (b.making_space) b.kea.spaces.value.len else b.kea.spaceIndex(b.space_id) orelse 0;
}

/// The page on screen, and while the fingers bring one in, the one they
/// bring, a page's width away.
fn pages(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const w = b.prefs.side_width;
    const shift = if (b.prefs.uses_spaces) b.swipe else 0;
    const at = spaceAt(b);
    _ = c.open(.{ .width = .fill, .grow = 1 }, "pages");
    defer c.end();
    page(b, c, p, at, shift, true);
    if (shift > 0 and at > 0) page(b, c, p, at - 1, shift - w, false);
    if (shift < 0 and at < b.kea.spaces.value.len) page(b, c, p, at + 1, shift + w, false);
}

fn page(b: *Browser, c: *ui.Context, p: *const Palette, index: usize, shift: f32, main: bool) void {
    const spaces = b.kea.spaces.value;
    const id = c.open(.{
        .absolute = true,
        .offset = .{ .x = shift },
        .width = px(b.prefs.side_width),
        .height = .fill,
        .padding = .xy(10, 0),
        .direction = .column,
    }, c.print("page-{d}", .{index}));
    defer c.end();
    if (index == spaces.len) {
        // Past the last space: the card for a new one, a third of the way down.
        ui.spacer(c);
        spaces_view.newSpaceCard(b, c, p, false);
        _ = c.leaf(.{ .grow = 2 }, .none, null);
    } else if (spaces[index].id.eql(b.space_id) and main) {
        current(b, c, p, id);
    } else if (b.parked.get(spaces[index].id)) |row| {
        preview(b, c, p, row.tabs.items, row.active);
    } else preview(b, c, p, &.{}, 0);
}

/// The rows on screen: the squares, then the rows, which scroll between
/// the squares and the foot only when they don't fit (`FitsOrScrolls`).
fn current(b: *Browser, c: *ui.Context, p: *const Palette, page_index: u32) void {
    const st = &b.column;
    const fresh = !st.drawn or !st.space.eql(b.space_id);
    st.space = b.space_id;
    std.mem.swap(std.ArrayList(State.SeenRow), &st.last, &st.seen);
    st.seen.clearRetainingCapacity();
    const arena = c.alloc();
    livePill(b, c, page_index);
    const squares = b.squarePins(arena) catch @panic("OOM");
    var pin_block: f32 = 0;
    if (b.pinnedCount() > 0 or st.pin_leaving.items.len > 0) {
        _ = c.open(.{ .padding = .{ .bottom = 10 } }, null);
        pin_grid.grid(b, c, p, squares, b.active_id, true);
        c.end();
        const cells = pin_grid.pinCells(arena, squares.len, b.prefs.side_width) catch @panic("OOM");
        pin_block = if (squares.len > 0) pin_grid.extent(cells).h + 10 else 0;
    }
    const room = @max(0, c.size.h - metrics.strip - foot_height - pin_block);
    const scroller = c.open(.{ .scroll = true, .direction = .column, .width = .fill, .max_height = room, .scroll_bar = false }, "rows-scroll");
    const rows_box = c.open(.{ .direction = .column, .width = .fill }, "rows");
    st.rows_node = c.node(rows_box).id;
    const listed = b.listedPins(arena) catch @panic("OOM");
    if (listed.len > 0) {
        _ = c.open(.{ .direction = .column, .width = .fill, .gap = side_rows.gap, .padding = .{ .bottom = side_rows.gap } }, "listed");
        side_rows.section(b, c, p, listed, .{ .listed = squares.len }, true, b.active_id);
        c.end();
    }
    _ = c.open(.{ .direction = .column, .width = .fill, .gap = side_rows.gap }, "loose");
    side_rows.loose(b, c, p, listed.len);
    c.end();
    if (fresh) {
        tab_leaving.clearIn(&st.leaving, &st.snaps, st.seen.items, b.gpa);
    } else {
        leaveRows(b, c, p);
    }
    newTabRow(b, c, p, true);
    c.end();
    c.end();
    st.drawn = true;
    reveal(b, c, c.node(scroller).id);
}

pub fn rowId(id: u64) u64 {
    return std.hash.Wyhash.hash(0x7372_6f77, std.mem.asBytes(&id));
}

fn leaveRows(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.column;
    for (st.last.items) |s| {
        const kept = for (st.seen.items) |cur| {
            if (cur.id == s.id) break true;
        } else false;
        if (kept) continue;
        const kv = st.snaps.fetchRemove(s.id) orelse continue;
        st.leaving.append(b.gpa, .{ .id = s.id, .x = s.x, .y = s.y, .w = s.w, .snap = kv.value }) catch {
            var gone = kv.value;
            gone.deinit(b.gpa);
        };
    }
    tab_leaving.pruneIn(&st.snaps, st.seen.items, b.gpa);
    var k: usize = 0;
    for (st.leaving.items) |*l| {
        const v = presence.presence(c, rowId(l.id), false, motion.settle, null) orelse {
            l.snap.deinit(b.gpa);
            continue;
        };
        st.leaving.items[k] = l.*;
        k += 1;
        const item = &st.leaving.items[k - 1];
        tab_leaving.drawSideRow(b, c, p, &item.snap, item.x, item.y, item.w, v);
    }
    st.leaving.shrinkRetainingCapacity(k);
}

/// The grey under the live tab, where last frame put the live item, sliding
/// there on `Motion.glide`.
fn livePill(b: *Browser, c: *ui.Context, page_index: u32) void {
    const st = &b.column;
    const resized = st.drawn and (st.last_size.w != c.size.w or st.last_size.h != c.size.h or st.last_width != b.prefs.side_width or b.edge_drag != null);
    st.last_size = c.size;
    st.last_width = b.prefs.side_width;
    const pill = st.pill orelse return;
    const page_id = c.node(page_index).id;
    const at = c.rects.get(pill.item) orelse return;
    const box = c.rects.get(page_id) orelse return;
    // Absolute boxes are placed from the page's padded corner.
    const pad = c.node(page_index).style.padding;
    const tx = at.x - box.x - pad.left;
    const ty = at.y - box.y - pad.top;
    if (resized) {
        ui.jump(c, page_id, 10, tx);
        ui.jump(c, page_id, 11, ty);
        ui.jump(c, page_id, 12, at.w);
        ui.jump(c, page_id, 13, at.h);
    }
    const x = motion.liveTo(c, page_id, 10, tx);
    const y = motion.liveTo(c, page_id, 11, ty);
    const w = motion.liveTo(c, page_id, 12, at.w);
    const h = motion.liveTo(c, page_id, 13, at.h);
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = px(w), .height = px(h), .radius = pill.radius, .background = pill.colour, .motion_blur = true }, .none, "live-pill");
    st.pill_drawn = true;
}

/// The tab you go to is the tab you see: the live row scrolled into view,
/// on `Motion.glide`; centred the first time.
fn reveal(b: *Browser, c: *ui.Context, scroller: u64) void {
    const st = &b.column;
    const cur = c.scroll.get(scroller) orelse 0;
    if (st.pill) |pill| if (pill.radius == 9 and pill.item != st.revealed) {
        if (c.rects.get(pill.item)) |row| if (c.rects.get(scroller)) |view| {
            const first = st.revealed == 0;
            st.revealed = pill.item;
            if (first) {
                st.reveal_to = @max(0, cur + (row.y + row.h / 2) - (view.y + view.h / 2));
            } else if (row.y < view.y) {
                st.reveal_to = cur - (view.y - row.y);
            } else if (row.y + row.h > view.y + view.h) {
                st.reveal_to = cur + (row.y + row.h - view.y - view.h);
            }
        };
    };
    const to = st.reveal_to orelse {
        _ = ui.tween(c, scroller, 20, cur, 0, .linear);
        return;
    };
    const v = motion.glideTo(c, scroller, 20, to);
    c.setScroll(scroller, .y, @max(0, v));
    if (v == to) st.reveal_to = null;
}

/// Another space's rows as they were left, drawn with the same pieces so
/// the two read as one column while they pass; nothing to press.
fn preview(b: *Browser, c: *ui.Context, p: *const Palette, tabs: []const *Tab, active: u64) void {
    const arena = c.alloc();
    const rows = b.prefs.showsPinRows();
    var squares: std.ArrayList(*Tab) = .empty;
    var listed: std.ArrayList(*Tab) = .empty;
    var rest: std.ArrayList(*Tab) = .empty;
    for (tabs) |t| {
        const list = if (t.pin == null) &rest else if (t.listed and rows) &listed else &squares;
        list.append(arena, t) catch return;
    }
    if (squares.items.len > 0) {
        _ = c.open(.{ .padding = .{ .bottom = 10 } }, null);
        pin_grid.grid(b, c, p, squares.items, active, false);
        c.end();
    }
    _ = c.open(.{ .direction = .column, .width = .fill, .gap = side_rows.gap }, null);
    side_rows.section(b, c, p, listed.items, .{ .listed = squares.items.len }, false, active);
    // Groups aren't drawn here, so the line goes over all the rest.
    if (side_rows.showsLine(b, listed.items.len, rest.items.len)) side_rows.keepLine(b, c, p, false, false);
    side_rows.section(b, c, p, rest.items, .loose, false, active);
    c.end();
    newTabRow(b, c, p, false);
}

/// `Quiet(icon: "plus", title: "New tab")`.
fn newTabRow(b: *Browser, c: *ui.Context, p: *const Palette, interactive: bool) void {
    _ = c.open(.{ .width = .fill, .padding = .{ .top = side_rows.gap } }, "new-tab");
    const it = controls.quiet(c, p, "plus", "New tab", side_rows.row_height);
    c.end();
    if (interactive and it.clicked) b.newTab();
}

/// `SideFoot`: the space's door, the extensions, bookmarks, downloads;
/// never wider than the column — the pinned extensions that don't fit give
/// way, from the last, and are still in the puzzle's list.
fn foot(b: *Browser, c: *ui.Context, p: *const Palette) void {
    _ = c.open(.{ .absolute = true, .offset = .{ .y = c.size.h - foot_height }, .direction = .row, .gap = 2, .width = .fill, .height = px(26), .padding = .xy(10, 0), .align_items = .center }, "side-foot");
    defer c.end();
    if (b.prefs.uses_spaces) spaces_view.spaceDot(b, c, p);
    const fetching = @import("fetch_door.zig");
    // Every door is 26 points, with 2 between them: the puzzle and bookmarks stay.
    const door: f32 = 26 + 2;
    const kept: f32 = 2 + @as(f32, if (b.prefs.uses_spaces) 1 else 0) + @as(f32, if (fetching.shows(b)) 1 else 0);
    const free = b.prefs.side_width - 2 * 10 + 2 - kept * door;
    @import("../ext/slot_view.zig").slot(b, c, p, @as(usize, @intFromFloat(@max(0, @floor(free / door)))));
    @import("bookmarks/door.zig").door(b, c, p, .trailing);
    // Only while a download is running, and a moment after.
    fetching.door(b, c, p, "foot");
}
