//! `PaneDivider` (PaneStage.swift 366-418, 506-640): the line between two
//! pages. A 1-point `faint` hairline in a 7-point gutter that grows to a
//! 3-point `muted` one after a moment's rest under the pointer, or while
//! held; dragged, the pages follow it (snapping to even), and the pair is
//! told once, when it is let go; double-clicked, even; its menu, and
//! VoiceOver's steps of 5 %.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const TabSplit = @import("../model/split.zig").TabSplit;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const tab_menu = @import("tab_menu.zig");

/// Between the pages: room for the divider, and to keep it off the left
/// page's scroll bar.
pub const gutter: f32 = 7;
/// Narrower than this a page is no use: the pair shows the focused page
/// alone until there is room again, and stays a pair.
pub const narrowest: f32 = 250;
/// How close to even the divider has to come to settle there, and how far
/// past it the pointer goes before it lets go.
pub const snap: f32 = 15;
pub const unsnap: f32 = 20;

pub const State = struct {
    /// The first page's share while the divider is held; null otherwise.
    live: ?f64 = null,
    snapped: bool = false,
    /// The press: the pointer's x, and the left page's width then.
    origin_x: f32 = 0,
    /// Left the press point since the press: from then on every x counts.
    moved: bool = false,
    origin_left: f32 = 0,
    /// When the pointer came to rest over it (`c.time`).
    over_since: ?f64 = null,
    /// Just let go of: the pair then told of it is no move to show.
    dragged: bool = false,
};

/// Neither page narrower than `narrowest` while both are on screen.
pub fn clampLeft(left: f32, room: f32) f32 {
    return @min(@max(left, narrowest), room - narrowest);
}

/// The left page's width for the held divider asked to `want`, in a stage
/// `room` wide less the gutter: even within `snap`, held there until the
/// pointer is `unsnap` past it (`dividerMoved`).
pub fn follow(st: *State, want: f32, room: f32) f32 {
    var left = clampLeft(want, room);
    const even = room / 2;
    if (st.snapped) {
        if (@abs(left - even) > unsnap) st.snapped = false else left = even;
    } else if (@abs(left - even) <= snap) {
        st.snapped = true;
        left = even;
    }
    return left;
}

/// The divider for pair `s`, at `left` (the left page's width) in a stage
/// `room` wide less the gutter; `shown` its opacity (a page arriving).
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, s: TabSplit, left: f32, room: f32, shown: f32) void {
    const st = &b.stage.divider;
    const i = c.open(.{ .absolute = true, .offset = .{ .x = left }, .width = .{ .px = gutter }, .height = .fill, .align_items = .center, .justify = .center, .opacity = shown }, "kea.split.divider");
    defer c.end();
    const it = c.interact(i, .{});
    const share = st.live orelse s.fraction();
    c.adjustable(i, .{ .role = .splitter, .label = "Divider between the pages", .value = c.print("{d}", .{@round(share * 100)}) });
    if (it.a11y_step != 0) b.setSplitFraction(s.id, share + 0.05 * @as(f64, @floatFromInt(it.a11y_step)));

    // A moment's rest first, so passing over it doesn't flicker.
    if (it.hovered) {
        if (st.over_since == null) st.over_since = c.time;
    } else st.over_since = null;
    const rested = if (st.over_since) |t0| c.time - t0 >= 0.1 else false;
    if (st.over_since) |t0| if (!rested) c.frameIn(@floatCast(0.1 - (c.time - t0)));
    const lit = rested or st.live != null;
    const w = ui.tween(c, it.id, 0, if (lit) 3 else 1, motion.quick_duration, .linear);
    if (it.hovered or st.live != null) c.cursor = .resize_left_right;
    _ = c.leaf(.{ .width = .{ .px = w }, .height = .fill, .radius = w / 2, .background = p.faint.mix(p.muted, (w - 1) / 2) }, .none, null);

    if (it.right_clicked) tab_menu.later(b, c.input.mouse, 0, menu);
    if (it.double_clicked) {
        st.live = null;
        return b.setSplitFraction(s.id, 0.5);
    }
    // Held: the pages follow the hand from where it pressed.
    if (it.hovered and c.input.pressed and c.input.button == .left) {
        st.live = s.fraction();
        st.snapped = @abs(s.fraction() - 0.5) < 0.0001;
        st.origin_x = c.input.mouse.x;
        st.moved = false;
        st.origin_left = left;
    }
    const held = st.live orelse return;
    if (c.input.down) {
        if (!st.moved and c.input.mouse.x == st.origin_x) return;
        st.moved = true;
        const at = follow(st, st.origin_left + (c.input.mouse.x - st.origin_x), room);
        if (room > 0) st.live = at / room;
        if (st.live.? != held) c.changed = true;
        return;
    }
    // Let go: the pair is told once.
    st.live = null;
    st.dragged = true;
    b.setSplitFraction(s.id, held);
}

const Pick = struct {
    b: *Browser,
    what: enum { swap, even, separate, close_both },

    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const b = self.b;
        switch (self.what) {
            .swap => b.swapSplit(),
            .even => b.evenSplit(),
            .separate => if (b.activeTab()) |t| b.detachSplit(t),
            .close_both => b.closeSplit(),
        }
        b.redraw();
    }
};

/// What can be done with the pair from the page area itself.
fn menu(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const titles = [_][]const u8{ "Swap Pages", "Even Out", "Separate", "Close Both" };
    const whats = [_]@FieldType(Pick, "what"){ .swap, .even, .separate, .close_both };
    var out: std.ArrayList(MenuItem) = .empty;
    for (titles, whats) |title, what| {
        const pick = try arena.create(Pick);
        pick.* = .{ .b = b, .what = what };
        try out.append(arena, .{ .label = title, .click = .of(pick, Pick.fire) });
        if (what == .even) try out.append(arena, .separator);
    }
    return out.items;
}

test "the held divider snaps to even within 15 and lets go past 20" {
    var st: State = .{};
    const room: f32 = 1000;
    try std.testing.expectEqual(@as(f32, 300), follow(&st, 300, room));
    try std.testing.expectEqual(@as(f32, 500), follow(&st, 486, room));
    try std.testing.expect(st.snapped);
    try std.testing.expectEqual(@as(f32, 500), follow(&st, 519, room));
    try std.testing.expectEqual(@as(f32, 521), follow(&st, 521, room));
    try std.testing.expectEqual(@as(f32, 250), follow(&st, 10, room));
    try std.testing.expectEqual(@as(f32, 750), follow(&st, 990, room));
}
