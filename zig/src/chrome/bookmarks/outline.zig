//! `BookmarkOutline` (Bookmarks.swift 777-1224): the list itself, folders
//! opening in place, each row carried above or below another or into a
//! folder, each good for a right-click. The same in the button's dropdown,
//! the sidebar and the manager; in the manager a click picks and a double
//! click opens.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../../model/browser.zig").Browser;
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const Bookmarks = bm.Bookmarks;
const Uuid = @import("../../data/json.zig").Uuid;
const Parts = @import("../../data/url.zig").Parts;
const Palette = @import("../../design/palette.zig").Palette;
const motion = @import("../../design/motion.zig");
const mark = @import("../mark.zig");
const state = @import("state.zig");
const actions = @import("actions.zig");
const row_menu = @import("outline_menu.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

pub const Use = struct {
    list: state.List,
    /// The manager's: a click picks rather than opens.
    picks: bool = false,
    /// A row washed a moment, after a search showed where it is.
    shown: ?Uuid = null,
};

/// The row's box key in `list`, for finding it again (`c.peekId`).
pub fn rowKey(c: *ui.Context, list: state.List, id: Uuid) []const u8 {
    const s = id.string();
    return c.print("bm.{s}.{s}", .{ @tagName(list), &s });
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, use: Use) void {
    const d = &b.marks_ui.drag;
    const mine = d.list == use.list;
    // Pressed and moved 5 points: the row, or the whole selection it is in, is carried.
    if (mine and d.pressed != null and d.carrying.items.items.len == 0 and c.input.down) {
        const m = c.input.mouse;
        if (@abs(m.x - d.origin.x) + @abs(m.y - d.origin.y) >= 5) carry(b, c, use, d.pressed.?);
    }
    const carrying = mine and d.carrying.items.items.len > 0;
    const before = d.aimed;
    if (carrying) d.aimed = null;

    ui.column(c, .{ .width = .fill, .gap = 1 });
    const fc = b.marks_ui.flat(b.gpa, use.list, b.bookmarks);
    const all = fc.rows.items;
    const sid = enclosingScroll(c);
    if (use.shown) |want| if (b.marks_ui.picks.reveal) if (sid) |id| {
        for (all, 0..) |r, idx| if (!r.empty_placeholder and r.node.id.eql(want)) {
            const sr_h = if (c.rects.get(id)) |sr| sr.h else 440;
            c.setScroll(id, .y, @max(0, @as(f32, @floatFromInt(idx)) * 28.0 + 13.5 - sr_h / 2));
            break;
        };
    };
    const pitch: f32 = 28;
    const offset = if (sid) |id| @max(0, (c.scroll.get(id) orelse 0) - 6) else 0;
    const view_h = if (sid) |id| (if (c.rects.get(id)) |r| r.h else c.size.h) else c.size.h;
    const first_vis: usize = @intFromFloat(@floor(offset / pitch));
    const vis_n: usize = @intFromFloat(@ceil(view_h / pitch) + 1);
    const first = if (all.len <= 40) 0 else first_vis -| 6;
    const last = if (all.len <= 40) all.len else @min(all.len, first_vis + vis_n + 6);
    if (first > 0) _ = c.leaf(.{ .width = .fill, .height = px(@as(f32, @floatFromInt(first)) * pitch - 1) }, .none, "bm.before");
    for (all[first..last]) |item| {
        if (item.empty_placeholder) {
            const i = c.open(.{ .width = .fill, .height = px(27), .padding = .{ .left = indent(item.depth) + 26, .top = 5, .bottom = 5 } }, null);
            const it = c.interact(i, .{});
            ui.text(c, "Empty", .{ .size = 12, .color = p.muted });
            c.end();
            if (carrying and allows(b, c, item.node.id)) if (it.rect) |r| if (r.contains(c.input.mouse)) {
                b.marks_ui.drag.aimed = .{ .id = item.node.id, .zone = .after, .depth = item.depth, .into = item.node.id, .at = null };
            };
        } else {
            row(b, c, p, use, item.node, item.depth, item.parent, item.index, fc.arrows, item.is_open, carrying);
        }
    }
    if (last < all.len) _ = c.leaf(.{ .width = .fill, .height = px(@as(f32, @floatFromInt(all.len - last)) * pitch - 1) }, .none, "bm.after");
    // Past the last row: the end of the top level, only while carrying.
    if (carrying) {
        const i = c.open(.{ .width = .fill, .height = px(10) }, "bm.end");
        const it = c.interact(i, .{});
        if (it.rect) |r| if (r.contains(c.input.mouse)) {
            d.aimed = .{ .id = null, .zone = .after, .into = null, .at = null };
        };
        if (d.aimed) |a| if (a.id == null) line(c, p, 0, .before, it.rect);
        c.end();
    }
    ui.end(c);

    if (!mine) return;
    if (carrying) settle(b, c, use, before);
    if (!c.input.down) {
        if (carrying) if (d.aimed) |a| b.bookmarks.move(d.carrying.items.items, a.into, a.at);
        d.pressed = null;
        d.carrying.clear();
        d.aimed = null;
    }
}

fn carry(b: *Browser, c: *ui.Context, use: Use, pressed: Uuid) void {
    const d = &b.marks_ui.drag;
    const picks = &b.marks_ui.picks;
    if (use.picks and picks.ids.has(pressed)) {
        const tops = b.bookmarks.topmost(c.alloc(), picks.ids.items.items) catch return;
        d.carrying.set(b.gpa, tops);
    } else d.carrying.set(b.gpa, &.{pressed});
    d.aimed = null;
    d.spring_since = c.time;
}

/// The aim held: a closed folder held over 0.7 s opens, so a row can go
/// deep without being let go on the way.
fn settle(b: *Browser, c: *ui.Context, use: Use, before: ?state.Aim) void {
    const d = &b.marks_ui.drag;
    if (!sameAim(before, d.aimed)) {
        d.spring_since = c.time;
        // The rows drawn before the aim moved show it next frame.
        c.animationFrame();
    }
    const a = d.aimed orelse return;
    if (a.zone != .into) return;
    const id = a.id orelse return;
    const open = b.marks_ui.expanded(use.list);
    if (open.has(id)) return;
    const wait: f32 = 0.7 - @as(f32, @floatCast(c.time - d.spring_since));
    if (wait <= 0) {
        open.put(b.gpa, id);
        c.changed = true;
    } else c.frameIn(wait);
}

fn sameAim(x: ?state.Aim, y: ?state.Aim) bool {
    if (x == null or y == null) return x == null and y == null;
    const ix = x.?.id;
    const iy = y.?.id;
    if ((ix == null) != (iy == null)) return false;
    if (ix != null and !ix.?.eql(iy.?)) return false;
    return x.?.zone == y.?.zone;
}

fn enclosingScroll(c: *ui.Context) ?u64 {
    var k = c.stack.items.len;
    while (k > 0) {
        k -= 1;
        const n = c.node(c.stack.items[k]);
        if (n.style.scroll) return n.id;
    }
    return null;
}

fn indent(depth: usize) f32 {
    return @as(f32, @floatFromInt(depth)) * 18;
}

/// A folder can't go above, below or into anything inside itself, nor can
/// the rows carried with it.
fn allows(b: *Browser, c: *ui.Context, target: Uuid) bool {
    const carried = &b.marks_ui.drag.carrying;
    if (carried.has(target)) return false;
    const path = (b.bookmarks.pathTo(c.alloc(), target) catch null) orelse return true;
    for (path) |n| if (carried.has(n.id)) return false;
    return true;
}

fn row(b: *Browser, c: *ui.Context, p: *const Palette, use: Use, node: *const Bookmark, depth: usize, parent: ?Uuid, index: usize, arrows: bool, is_open: bool, carrying: bool) void {
    const s = &b.marks_ui;
    const d = &s.drag;
    const label = node.label(c.alloc()) catch node.title;
    const selected = use.picks and s.picks.ids.has(node.id);
    const shown = if (use.shown) |id| id.eql(node.id) else false;
    const i = c.open(.{
        .direction = .row,
        .gap = 8,
        .padding = .{ .left = indent(depth) + 10, .right = 10, .top = 6, .bottom = 6 },
        .width = .fill,
        .height = px(27),
        .radius = 8,
        .align_items = .center,
        .control = true,
    }, rowKey(c, use.list, node.id));
    const it = c.interact(i, .{});
    c.addA11y(i, .row, label, "", selected, true);

    if (shown) s.picks.shown_rect = it.rect;
    // Where a carried row would land on this one: the top means above, the
    // bottom below, and the middle of a folder into it.
    var aim: ?state.Zone = null;
    if (carrying and allows(b, c, node.id)) if (it.rect) |r| if (r.contains(c.input.mouse)) {
        const part = (c.input.mouse.y - r.y) / @max(r.h, 1);
        const zone: state.Zone = if (!node.isFolder()) (if (part < 0.5) .before else .after) else if (part < 0.25) .before else if (part > 0.75) .after else .into;
        d.aimed = switch (zone) {
            .before => .{ .id = node.id, .zone = zone, .depth = depth, .into = parent, .at = index },
            .after => if (is_open)
                .{ .id = node.id, .zone = zone, .depth = depth + 1, .into = node.id, .at = 0 }
            else
                .{ .id = node.id, .zone = zone, .depth = depth, .into = parent, .at = index + 1 },
            .into => .{ .id = node.id, .zone = zone, .depth = depth, .into = node.id, .at = null },
        };
    };
    if (d.aimed) |a| if (a.id) |id| if (id.eql(node.id)) {
        aim = a.zone;
    };

    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    // Aimed into on quick, shown (found) on settle, picked at once.
    const into = motion.quickTo(c, it.id, 1, if (aim == .into) 1 else 0);
    const lit = motion.settleTo(c, it.id, 3, if (shown) 1 else 0);
    const strong: f32 = if (selected) 1 else std.math.clamp(@max(into, lit), 0, 1);
    c.node(i).style.background = p.wash.alpha(h).mix(p.hover, strong);
    const dragging = carrying and d.carrying.has(node.id);
    c.node(i).style.opacity = 1 - 0.65 * motion.quickTo(c, it.id, 2, if (dragging) 1 else 0);

    var chevron = false;
    if (node.isFolder()) {
        const ci = c.open(.{ .width = px(16), .height = px(15), .align_items = .center, .justify = .center, .control = true }, null);
        chevron = c.interact(ci, .{}).clicked;
        // nanoui can't turn a glyph: the open folder's arrow points down.
        ui.icon(c, if (is_open) "chevron.down" else "chevron.right", .{ .size = 9, .weight = .semibold, .color = p.faint });
        c.end();
        folderMark(c, p, 15, 9);
    } else {
        if (arrows) _ = c.leaf(.{ .width = px(16) }, .none, null);
        siteMark(b, c, p, node, 15);
    }
    ui.text(c, label, .{ .size = 12.5, .color = if (node.unnamed()) p.muted else p.ink, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 8 }, .none, null);
    if (node.isFolder()) if (node.children) |kids| if (kids.len > 0)
        ui.text(c, c.print("{d}", .{b.bookmarks.folderCount(node.id, kids)}), .{ .size = 11, .color = p.muted });
    if (aim == .before or aim == .after) line(c, p, d.aimed.?.depth, aim.?, it.rect);
    c.end();

    if (it.hovered and c.input.pressed) {
        d.pressed = node.id;
        d.origin = c.input.mouse;
        d.list = use.list;
    }
    if (carrying) return;
    const held: actions.Held = .{ .shift = c.input.shift, .cmd = c.input.cmd };
    if (it.middle_clicked) if (node.url) |u| actions.pickBookmark(b, u, true, held);
    if (it.right_clicked) row_menu.popup(b, c, use, node.id);
    if (chevron) {
        s.expanded(use.list).toggle(b.gpa, node.id);
        c.changed = true;
    } else if (it.clicked) tapped(b, c, use, node, it.double_clicked);
}

/// A click on a row. Where a click only opens, it opens a bookmark and
/// toggles a folder. In the manager it picks, and a double click opens.
fn tapped(b: *Browser, c: *ui.Context, use: Use, node: *const Bookmark, double: bool) void {
    const s = &b.marks_ui;
    if (use.picks and !double) {
        const order = s.flat(b.gpa, use.list, b.bookmarks).ids.items;
        s.picks.click(b.gpa, node.id, c.input.shift, c.input.cmd, order);
    } else if (node.isFolder()) {
        s.expanded(use.list).toggle(b.gpa, node.id);
    } else if (node.url) |u| actions.pickBookmark(b, u, false, .{ .shift = c.input.shift, .cmd = c.input.cmd });
    c.changed = true;
}

/// The line where a carried row would go: a 2-point capsule of ink, at the
/// row's top edge for above, its bottom for below.
fn line(c: *ui.Context, p: *const Palette, depth: usize, zone: state.Zone, rect: ?ui.Rect) void {
    const r = rect orelse return;
    const lead = indent(depth) + 10;
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = lead, .y = if (zone == .before) -1.5 else r.h - 0.5 },
        .width = px(@max(0, r.w - lead - 10)),
        .height = px(2),
        .radius = 1,
        .background = p.ink.alpha(0.55),
    }, .none, null);
}

/// A folder's `Mark`: the faint square with the folder in it.
pub fn folderMark(c: *ui.Context, p: *const Palette, size: f32, symbol: f32) void {
    _ = c.open(.{ .width = px(size), .height = px(size), .radius = size * 0.22, .background = p.ink.alpha(0.06), .align_items = .center, .justify = .center }, null);
    ui.icon(c, "folder.fill", .{ .size = symbol, .color = p.muted });
    c.end();
}

/// A site's `Mark`: its icon, or its host's first letter.
pub fn siteMark(b: *Browser, c: *ui.Context, p: *const Palette, node: *const Bookmark, size: f32) void {
    const u = node.url orelse "";
    mark.mark(c, p, b.kea.favicons.icon(u), letter(c, u), size, false);
}

/// `String((node.host ?? "•").prefix(1)).uppercased()`.
pub fn letter(c: *ui.Context, u: []const u8) []const u8 {
    const host = if (Parts.parse(u)) |parts| parts.hostName() orelse "" else "";
    return mark.initial(c, host);
}
