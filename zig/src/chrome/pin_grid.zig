//! The pinned squares at the top of the column (Side.swift `pinRows`,
//! `pinCells`, `PinGrid`, `PinSquare`, `PinCarried`) and the letter typed
//! into a pin (`PinField`, TabBar.swift), which the strip's pins use too.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");
const mark = @import("mark.zig");
const ring = @import("ring.zig");
const tab_menu = @import("tab_menu.zig");
const side_bar = @import("side_bar.zig");
const tab_leaving = @import("tab_leaving.zig");
const presence = @import("presence.zig");
const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// The classic square, and the air between squares (`SideBar.square`, `pinGap`).
pub const square: f32 = 34;
pub const pin_gap: f32 = 4;

/// How many squares go in each row: at most `most`, as even as they go,
/// the fuller rows first. Five are three and two, seven four and three,
/// nine three, three and three, ten four, three and three.
pub fn pinRows(gpa: std.mem.Allocator, count: usize, most_in: usize) ![]usize {
    if (count == 0) return &.{};
    const most = @max(1, most_in);
    const rows = (count + most - 1) / most;
    const base = count / rows;
    const extra = count % rows;
    const out = try gpa.alloc(usize, rows);
    for (out, 0..) |*n, i| n.* = if (i < extra) base + 1 else base;
    return out;
}

/// Where each square goes, in the order of the row, in a column
/// `side_width` wide: each row splits the width between its squares, and
/// every row is as tall as its narrowest cell, never taller than the
/// square. A single row of fewer than three keeps three places.
pub fn pinCells(gpa: std.mem.Allocator, count: usize, side_width: f32) ![]ui.Rect {
    const room = side_width - 20;
    const fits_f = @floor((room + pin_gap) / (square + pin_gap));
    const fits: usize = if (fits_f < 1) 0 else @intFromFloat(fits_f);
    const rows = try pinRows(gpa, count, @min(4, @max(1, fits)));
    defer gpa.free(rows);
    const widths = try gpa.alloc(f32, rows.len);
    defer gpa.free(widths);
    var height: f32 = square;
    for (rows, widths) |n, *w| {
        const slots: f32 = @floatFromInt(if (rows.len == 1) @max(n, @min(3, fits)) else n);
        w.* = @max(20, (room - (slots - 1) * pin_gap) / slots);
        height = @min(height, w.*);
    }
    const cells = try gpa.alloc(ui.Rect, count);
    var i: usize = 0;
    for (rows, widths, 0..) |n, w, r| {
        for (0..n) |col| {
            cells[i] = .{ .x = @as(f32, @floatFromInt(col)) * (w + pin_gap), .y = @as(f32, @floatFromInt(r)) * (height + pin_gap), .w = w, .h = height };
            i += 1;
        }
    }
    return cells;
}

/// The grid's own size: to its furthest cell.
pub fn extent(cells: []const ui.Rect) ui.Size {
    var s: ui.Size = .{};
    for (cells) |r| {
        s.w = @max(s.w, r.x + r.w);
        s.h = @max(s.h, r.y + r.h);
    }
    return s;
}

/// The cell nearest the held square's centre (`PinCarried.target`).
pub fn nearest(cells: []const ui.Rect, from: usize, travel: ui.Point) usize {
    if (from >= cells.len) return 0;
    const s = cells[from];
    const at: ui.Point = .{ .x = s.x + s.w / 2 + travel.x, .y = s.y + s.h / 2 + travel.y };
    var best = from;
    var best_d = std.math.inf(f32);
    for (cells, 0..) |r, i| {
        const d = std.math.hypot(r.x + r.w / 2 - at.x, r.y + r.h / 2 - at.y);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

/// A square picked up out of the grid (`PinCarried`), by tab id.
pub const Held = struct { id: u64, from: usize, origin: ui.Point, moved: bool = false };

/// The grid of `pins` (`PinGrid`): fixed cells, left-aligned. `live` is
/// the tab in front; `interactive` false for another space's preview.
pub fn pinId(id: u64) u64 {
    return std.hash.Wyhash.hash(0x7069_6e73, std.mem.asBytes(&id));
}

pub fn grid(b: *Browser, c: *ui.Context, p: *const Palette, pins: []const *Tab, live: u64, interactive: bool) void {
    const cells = pinCells(c.alloc(), pins.len, b.prefs.side_width) catch return;
    const size = extent(cells);
    _ = c.open(.{ .width = px(size.w), .height = px(size.h) }, "pins");
    defer c.end();
    const st = &b.column;
    const fresh = !st.drawn or !st.space.eql(b.space_id);
    if (interactive) {
        std.mem.swap(std.ArrayList(side_bar.State.SeenPin), &st.pin_last, &st.pin_seen);
        st.pin_seen.clearRetainingCapacity();
    }
    var held_at: ?usize = null;
    for (pins, cells, 0..) |t, cell, index| {
        if (interactive) tab_leaving.keepIn(&st.pin_snaps, b.gpa, b, t);
        if (st.pin_held) |h| if (h.id == t.id and h.moved) {
            held_at = index;
            continue;
        };
        ui.key(c, c.print("pin-{d}", .{t.id}));
        _ = pinSquare(b, c, p, t, t.id == live, cell, index, cells, interactive, false, fresh);
    }
    if (interactive) {
        if (fresh) {
            tab_leaving.clearIn(&st.pin_leaving, &st.pin_snaps, st.pin_seen.items, b.gpa);
        } else {
            leavePins(b, c, p);
        }
    }
    // Carried: drawn last, so on top, under the hand.
    if (held_at) |index| {
        const t = pins[index];
        ui.key(c, c.print("pin-{d}", .{t.id}));
        _ = pinSquare(b, c, p, t, t.id == live, cells[index], index, cells, interactive, true, fresh);
    }
}

fn leavePins(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.column;
    for (st.pin_last.items) |s| {
        const kept = for (st.pin_seen.items) |cur| {
            if (cur.id == s.id) break true;
        } else false;
        if (kept) continue;
        const kv = st.pin_snaps.fetchRemove(s.id) orelse continue;
        st.pin_leaving.append(b.gpa, .{ .id = s.id, .x = s.x, .y = s.y, .w = s.w, .h = s.h, .snap = kv.value }) catch {
            var gone = kv.value;
            gone.deinit(b.gpa);
        };
    }
    tab_leaving.pruneIn(&st.pin_snaps, st.pin_seen.items, b.gpa);
    var k: usize = 0;
    for (st.pin_leaving.items) |*l| {
        const v = motion.quickTo(c, pinId(l.id), 0x6c65_6176, 0);
        if (v <= 0.001) {
            l.snap.deinit(b.gpa);
            continue;
        }
        st.pin_leaving.items[k] = l.*;
        k += 1;
        const item = &st.pin_leaving.items[k - 1];
        tab_leaving.drawPin(b, c, p, &item.snap, item.x, item.y, item.w, item.h, v);
    }
    st.pin_leaving.shrinkRetainingCapacity(k);
}

fn pinSquare(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, live: bool, cell: ui.Rect, index: usize, cells: []const ui.Rect, interactive: bool, held: bool, fresh: bool) ui.Interaction {
    const st = &b.column;
    const scale = @min(cell.w, cell.h);
    const radius = scale * 9 / 34;
    // Every other square glides into its cell when one moves.
    const id = c.peekId(null);
    if (b.edge_drag != null) {
        ui.jump(c, id, 0, cell.x);
        ui.jump(c, id, 1, cell.y);
    }
    var x = motion.glideTo(c, id, 0, cell.x);
    var y = motion.glideTo(c, id, 1, cell.y);
    var shadow: ?ui.Shadow = null;
    var ground: ?ui.Color = null;
    if (held) if (st.pin_held) |h| {
        const start = cells[h.from];
        const travel: ui.Point = .{ .x = c.input.mouse.x - h.origin.x, .y = c.input.mouse.y - h.origin.y };
        // Under the hand exactly: the springs are told where it is.
        x = start.x + travel.x;
        y = start.y + travel.y;
        ui.jump(c, id, 0, x);
        ui.jump(c, id, 1, y);
        ground = p.ground;
        shadow = card.swiftShadow(0.16, 10, 3);
    };
    var v: f32 = 1;
    if (interactive) {
        _ = ui.tween(c, pinId(t.id), 0x6c65_6176, 1, 0, .linear);
        const known = for (st.pin_last.items) |s| {
            if (s.id == t.id) break true;
        } else false;
        v = presence.presenceFrom(c, pinId(t.id), if (!fresh and !known) 0 else 1, true, motion.settle, null) orelse 1;
        st.pin_seen.append(b.gpa, .{ .id = t.id, .x = x, .y = y, .w = cell.w, .h = cell.h }) catch {};
    }
    const i = c.open(.{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = px(cell.w),
        .height = px(cell.h),
        .radius = radius,
        .align_items = .center,
        .justify = .center,
        .shadow = shadow,
        .opacity = std.math.clamp(v, 0, 1),
        .scale = 0.8 + 0.2 * v,
        .control = true,
    }, null);
    defer c.end();
    const it = c.interact(i, .{});
    // Salts 0 and 1 are the square's place.
    const hover = motion.quickTo(c, it.id, 2, if (it.hovered) 1 else 0);
    if (live and interactive) st.live(it.id, p.side_pin_live, radius);
    // The live square's ground is the sliding one (`matchedGeometryEffect`),
    // unless none was drawn this frame.
    c.node(i).style.background = ground orelse if (live)
        (if (interactive and st.pill_drawn) null else p.side_pin_live)
    else
        p.side_tile.mix(p.side_hover, hover);
    c.help(i, t.label());
    c.addA11y(i, .button, if (t.label().len == 0) "New Tab" else t.label(), if (live) "Selected" else "", live, true);

    const glyph = scale * 16 / 34;
    _ = c.open(.{ .width = px(glyph), .height = px(glyph), .align_items = .center, .justify = .center }, null);
    if (b.editing_pin == t.id and interactive) {
        pinField(b, c, p, t);
    } else if (t.loading) {
        ring.ring(c, scale * 11 / 34);
    } else if (b.prefs.glyph == .icons and iconOf(b, t) != null) {
        mark.mark(c, p, iconOf(b, t), t.pin orelse "", scale * 16 / 34, t.asleep());
    } else {
        const ink = if (live) p.ink else p.muted;
        ui.text(c, t.pin orelse "", .{ .size = scale * 12 / 34, .weight = .medium, .color = ink.alpha(if (t.asleep()) 0.45 else 1) });
    }
    c.end();

    if (!interactive) return it;
    if (carry(b, c, t, it, index, cells)) return it;
    if (it.middle_clicked) {
        b.close(t);
    } else if (it.right_clicked) {
        tab_menu.popup(b, c, t);
    } else if (live and it.double_clicked) {
        b.goHome(t);
    } else if (!live and it.clicked) {
        b.select(t);
    }
    return it;
}

/// `PinCarried`: a drag of 5 points picks the square up; it moves to the
/// cell nearest the hand as it goes, and settles into place when let go.
/// True while carried and on the release that ends a carry: no click.
fn carry(b: *Browser, c: *ui.Context, t: *Tab, it: ui.Interaction, index: usize, cells: []const ui.Rect) bool {
    const st = &b.column;
    if (it.pressed and st.pin_held == null) st.pin_held = .{ .id = t.id, .from = index, .origin = c.input.mouse };
    const h = if (st.pin_held) |*held| held else return false;
    if (h.id != t.id) return false;
    if (!c.input.down) {
        const was = h.moved;
        st.pin_held = null;
        if (was) c.changed = true;
        return was;
    }
    const travel: ui.Point = .{ .x = c.input.mouse.x - h.origin.x, .y = c.input.mouse.y - h.origin.y };
    if (!h.moved and std.math.hypot(travel.x, travel.y) < 5) return false;
    if (!h.moved) c.changed = true;
    h.moved = true;
    const target = nearest(cells, h.from, travel);
    if (target != index) {
        // The squares are the head of the row: a cell's index is the row's.
        b.move(t, target);
        c.changed = true;
    }
    return true;
}

fn iconOf(b: *Browser, t: *Tab) ?mark.Icon {
    if (t.isBlank()) return null;
    const ic = b.kea.favicons.icon(t.url()) orelse return null;
    return .{ .key = ic.key, .png = ic.png };
}

/// `PinField`: the letter typed in the square itself, one character worn
/// as it will be; Return, Tab or Esc keep it, as does leaving the field.
pub fn pinField(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab) void {
    const st = &b.column;
    const buf = &st.pin_draft;
    if (st.pin_claimed != t.id) {
        st.pin_claimed = t.id;
        buf.set(t.pin orelse "");
        // The guessed letter arrives selected: one keystroke replaces it.
        ui.focusNext(c, true);
    }
    const res = ui.textField(c, buf, .{ .bare = true, .size = 12, .width = .fill, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
    if (res.changed) {
        b.letter(buf.text(), t);
        buf.set(t.pin orelse "");
    }
    // Return, Tab or Esc keep it; so does the field losing the keys.
    const left = st.pin_focused and !res.focused;
    st.pin_focused = res.focused;
    if (res.submitted or left or c.shortcut(.{ .key = ui.Shortcut.escape }) or c.shortcut(.{ .key = ui.Shortcut.tab })) {
        st.pin_claimed = 0;
        st.pin_focused = false;
        b.endPinEdit();
    }
}

// MARK: tests

const testing = std.testing;

fn expectRows(count: usize, most: usize, want: []const usize) !void {
    const got = try pinRows(testing.allocator, count, most);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(usize, want, got);
}

test "pinRows table" {
    try expectRows(5, 4, &.{ 3, 2 });
    try expectRows(7, 4, &.{ 4, 3 });
    try expectRows(9, 4, &.{ 3, 3, 3 });
    try expectRows(10, 4, &.{ 4, 3, 3 });
    try expectRows(4, 4, &.{4});
    try expectRows(0, 4, &.{});
    try expectRows(3, 1, &.{ 1, 1, 1 });
}

test "a single row of fewer than three keeps three slots" {
    // 232 wide: room 212, four fit; one pin is a third of the room.
    const one = try pinCells(testing.allocator, 1, 232);
    defer testing.allocator.free(one);
    try testing.expectApproxEqAbs((212.0 - 2 * 4) / 3.0, one[0].w, 0.001);
    try testing.expectEqual(square, one[0].h);
    const five = try pinCells(testing.allocator, 5, 232);
    defer testing.allocator.free(five);
    // Three then two, each row filling the width; rows as tall as a square.
    try testing.expectApproxEqAbs((212.0 - 2 * 4) / 3.0, five[0].w, 0.001);
    try testing.expectApproxEqAbs((212.0 - 4) / 2.0, five[3].w, 0.001);
    try testing.expectEqual(@as(f32, square + pin_gap), five[3].y);
    try testing.expectEqual(@as(usize, 4), nearest(five, 0, .{ .x = 120, .y = 38 }));
}
