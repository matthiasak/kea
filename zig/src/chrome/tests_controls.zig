//! Kea's controls, presence and overlays, driven through `ui.Tester`.
const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const palette = @import("../design/palette.zig");
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const presence = @import("presence.zig");
const overlays = @import("overlays.zig");
const plate = @import("controls_plate.zig");
const mark = @import("mark.zig");
const ring = @import("ring.zig");
const card = @import("../design/card.zig");

const Which = enum { close, toggle, segmented, steps, shake, presence, overlay };

const S = struct {
    which: Which,
    closes: u32 = 0,
    on: bool = false,
    picked: usize = 0,
    value: f64 = 1,
    gen: u32 = 0,
    offset: f32 = 0,
    shown: bool = true,
    progress: ?f32 = null,
    never: ?f32 = 0,
    open: ?overlays.Overlay = null,
    anchor: ui.Rect = .{},

    fn pct(c: *ui.Context, v: f64) []const u8 {
        return c.print("{d}%", .{@round(v * 100)});
    }

    fn view(s: *S, c: *ui.Context) void {
        const p = palette.get(c.theme.dark);
        ui.column(c, .{ .padding = .all(20), .gap = 10 });
        switch (s.which) {
            .close => {
                // A tab: its cross armed while the pointer is on it.
                const i = c.open(.{ .direction = .row, .width = .{ .px = 120 }, .height = .{ .px = 28 }, .padding = .{ .right = 7 }, .align_items = .center, .justify = .end }, null);
                const it = c.interact(i, .{});
                if (controls.closeDisc(c, p, it.hovered, controls.close_zone).clicked) s.closes += 1;
                c.end();
            },
            .toggle => _ = controls.switch_(c, p, &s.on, "Switch"),
            .segmented => _ = controls.segmented(c, p, &.{ "One", "Two", "Three" }, &s.picked, false),
            .steps => _ = controls.steps(c, p, &.{ 0.5, 0.75, 1, 1.25, 1.5 }, &s.value, 1, pct),
            .shake => s.offset = controls.shake(c, 42, s.gen),
            .presence => {
                s.progress = presence.presence(c, 7, s.shown, motion.settle, null);
                s.never = presence.presence(c, 8, false, motion.settle, null);
            },
            .overlay => {
                const i = c.open(.{ .width = .{ .px = 60 }, .height = .{ .px = 30 } }, null);
                const it = c.interact(i, .{});
                c.end();
                if (it.clicked) {
                    s.open = if (s.open == null) .bookmarks_dropdown else null;
                    s.anchor = it.rect orelse .{};
                }
            },
        }
        ui.end(c);
        if (overlays.begin(c, &s.open, s.anchor, .{ .width = .{ .px = 100 }, .height = .{ .px = 80 }, .background = p.ground }, .{})) ui.end(c);
    }
};

fn start(t: *ui.Tester, s: *S) !void {
    try t.init(testing.allocator, .init(s, S.view), .{});
}

/// The first painted fill of `w`×`h` points.
fn fill(t: *ui.Tester, w: f32, h: f32) ?[8]f32 {
    for (t.instances.items) |in| {
        if (in.kind != 0 or @abs(in.rect[2] - w) > 0.01 or @abs(in.rect[3] - h) > 0.01) continue;
        return in.rect ++ in.color;
    }
    return null;
}

test "close disc shows under the pointer and closes on its zone" {
    var s: S = .{ .which = .close };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    try testing.expect(fill(&t, 15, 15) == null);
    t.moveTo(40, 34);
    t.settle(1);
    const ink = palette.get(false).ink;
    const disc = fill(&t, 15, 15) orelse return error.NoDisc;
    try testing.expectApproxEqAbs(@as(f32, 118), disc[0], 0.01);
    try testing.expectApproxEqAbs(ink.r, disc[4], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.07), disc[7], 1e-3);
    // Pressed, it stays as it was; the release on the zone, off the disc, closes.
    t.ctx.input.mouse = .{ .x = 138, .y = 34 };
    t.ctx.updateHot();
    t.ctx.input.click_count = 1;
    t.ctx.pointerDown();
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 0.07), (fill(&t, 15, 15) orelse return error.NoDisc)[7], 1e-3);
    t.ctx.pointerUp();
    t.frame();
    try testing.expectEqual(@as(u32, 1), s.closes);
    // With a modifier held it is not the cross's click.
    t.ctx.input.cmd = true;
    t.click(138, 34);
    t.ctx.input.cmd = false;
    try testing.expectEqual(@as(u32, 1), s.closes);
    // Pressed, then let go off the zone: a press taken back closes nothing.
    t.ctx.input.mouse = .{ .x = 138, .y = 34 };
    t.ctx.updateHot();
    t.ctx.pointerDown();
    t.frame();
    t.moveTo(100, 34);
    t.ctx.pointerUp();
    t.frame();
    try testing.expectEqual(@as(u32, 1), s.closes);
    // Away from the tab the cross fades and takes nothing.
    t.moveTo(300, 300);
    t.settle(1);
    try testing.expect(fill(&t, 15, 15) == null);
}

test "switch toggles and settles across" {
    var s: S = .{ .which = .toggle };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    try testing.expectApproxEqAbs(@as(f32, 22), (fill(&t, 14, 14) orelse return error.NoKnob)[0], 0.01);
    t.click(35, 29);
    try testing.expect(s.on);
    t.frame();
    const mid = (fill(&t, 14, 14) orelse return error.NoKnob)[0];
    try testing.expect(mid > 22 and mid < 34);
    t.settle(2);
    try testing.expectApproxEqAbs(@as(f32, 34), (fill(&t, 14, 14) orelse return error.NoKnob)[0], 0.01);
    const track = fill(&t, 30, 18) orelse return error.NoTrack;
    try testing.expectApproxEqAbs(palette.get(false).feather.g, track[5], 1e-3);
    t.click(35, 29);
    try testing.expect(!s.on);
}

test "segmented picks and its chip settles on the choice" {
    var s: S = .{ .which = .segmented };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.frame();
    try t.clickText("Three");
    try testing.expectEqual(@as(usize, 2), s.picked);
    t.settle(2);
    const r = t.findText("Three") orelse return error.NoText;
    const ground = palette.get(false).ground;
    var found = false;
    for (t.instances.items) |in| {
        if (in.kind != 0 or in.radius != 7 or in.color[3] < 0.99 or @abs(in.color[0] - ground.r) > 1e-3) continue;
        found = in.rect[0] <= r.x and in.rect[0] + in.rect[2] >= r.x + r.w;
    }
    try testing.expect(found);
}

test "steps move one stop at a time and the value goes home" {
    var s: S = .{ .which = .steps };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    const r = t.findText("100%") orelse return error.NoText;
    const plus = r.x + r.w / 2 + @max(36, r.w) / 2 + 10;
    const y = r.y + r.h / 2;
    t.click(plus, y);
    try testing.expectEqual(@as(f64, 1.25), s.value);
    const r2 = t.findText("125%") orelse return error.NoText;
    const plus2 = r2.x + r2.w / 2 + @max(36, r2.w) / 2 + 10;
    t.click(plus2, y);
    try testing.expectEqual(@as(f64, 1.5), s.value);
    // The last stop: + is spent.
    const r3 = t.findText("150%") orelse return error.NoText;
    t.click(r3.x + r3.w / 2 + @max(36, r3.w) / 2 + 10, y);
    try testing.expectEqual(@as(f64, 1.5), s.value);
    t.click(32, y);
    try testing.expectEqual(@as(f64, 1.25), s.value);
    try t.clickText("125%");
    try testing.expectEqual(@as(f64, 1), s.value);
}

test "shake offset is 0 at t=0 and t=1" {
    try testing.expectApproxEqAbs(@as(f32, 0), controls.shakeAt(0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), controls.shakeAt(1), 1e-5);
    try testing.expect(controls.shakeAt(1.0 / 12.0) > 6);
    var s: S = .{ .which = .shake };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    try testing.expectEqual(@as(f32, 0), s.offset);
    s.gen = 1;
    var moved: f32 = 0;
    for (0..10) |_| {
        t.frame();
        moved = @max(moved, @abs(s.offset));
    }
    try testing.expect(moved > 3);
    t.advance(0.6);
    try testing.expectApproxEqAbs(@as(f32, 0), s.offset, 1e-4);
}

test "presence returns null after a hidden item fully leaves" {
    var s: S = .{ .which = .presence };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    // Never shown: nothing to draw.
    try testing.expect(s.never == null);
    try testing.expect(s.progress.? < 1);
    t.settle(2);
    try testing.expectEqual(@as(f32, 1), s.progress.?);
    s.shown = false;
    t.frame();
    try testing.expect(s.progress != null and s.progress.? < 1);
    t.settle(2);
    try testing.expect(s.progress == null);
}

// Esc closing it is the key monitor's (app/keys.zig `escape`, ui-test site card).
test "overlay closes on outside press" {
    var s: S = .{ .which = .overlay };
    var t: ui.Tester = undefined;
    try start(&t, &s);
    defer t.deinit();
    t.click(50, 35);
    try testing.expect(s.open != null);
    t.settle(1);
    // Under the opener, 6 below it.
    const box = fill(&t, 100, 80) orelse return error.NoOverlay;
    try testing.expectEqual(@as(f32, 20), box[0]);
    try testing.expectEqual(@as(f32, 56), box[1]);
    t.click(60, 90);
    try testing.expect(s.open != null);
    t.click(300, 300);
    try testing.expect(s.open == null);
}

/// Every other piece, built once in light and dark: plate, card, lines,
/// hunt, quick, door, quiet, speaker, pill, key cap, mark, ring, card edge.
const All = struct {
    buf: ui.TextBuffer = .{},
    closed: bool = false,

    fn view(a: *All, c: *ui.Context) void {
        const p = palette.get(c.theme.dark);
        var pl = plate.plate(c, p, "History", 560);
        if (pl.closed) a.closed = true;
        _ = plate.hunt(c, p, &a.buf, "Search everywhere you have been");
        plate.caption(c, p, "Today");
        plate.cardBox(c, p);
        plate.line(c, p, "Sidebar", "Tabs down the side");
        _ = controls.pill(c, p, "Clear…", .{});
        ui.end(c);
        plate.rule(c, p, 14);
        plate.line(c, p, "Save", null);
        _ = controls.pill(c, p, "Save", .{ .filled = true });
        ui.end(c);
        ui.end(c);
        plate.nothing(c, p, "Nothing yet — not a single footprint in the snow.");
        ui.row(c, .{ .gap = 6, .align_items = .center });
        _ = plate.quick(c, p, "Show", null);
        _ = controls.door(c, p, "sidebar.left", .{ .on = true, .help = "Hide Sidebar   ⌘S" });
        _ = controls.speaker(c, p, true);
        controls.keyCap(c, p, "Tab");
        mark.mark(c, p, null, "K", 16, true);
        ring.ring(c, 10);
        ring.progressArc(c, 12, 0.4);
        const hole = c.open(.{ .width = .{ .px = 40 }, .height = .{ .px = 30 } }, null);
        card.cardEdge(c, hole);
        c.end();
        ui.end(c);
        _ = controls.quiet(c, p, "plus", "New Tab", 28);
        pl.foot(c, p);
        ui.text(c, "12 pages", .{ .size = 12, .color = p.muted });
        pl.end(c);
    }
};

test "every control builds in light and dark" {
    for ([_]bool{ false, true }) |dark| {
        var a: All = .{};
        defer a.buf.deinit();
        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&a, All.view), .{ .width = 700, .height = 600, .dark = dark });
        defer t.deinit();
        t.frame();
        try testing.expect(t.hasText("History"));
        try testing.expect(t.hasText("Search everywhere you have been"));
        try testing.expect(t.hasText("12 pages"));
        // The page's card: a hairline edge, and a shadow outside it only.
        var edge = false;
        var knockout = false;
        for (t.instances.items) |in| {
            if (in.rect[2] == 40 and in.rect[3] == 30 and in.border_width == 1) edge = @abs(in.border_color[3] - 0.08) < 1e-3;
            if (in.kind == 5) knockout = true;
        }
        try testing.expect(edge and knockout);
        // The cross, 22 in from the plate's right and 18 down, is "Done   esc".
        try testing.expect(!a.closed);
        t.click(560 - 22 - 13, 18 + 13);
        try testing.expect(a.closed);
    }
}
