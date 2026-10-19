//! P3: the window's layout at 1440×900, as App.swift's `chrome`, `farGap`
//! and `band` place the page (App.swift:532-576).
const std = @import("std");
const ui = @import("nanoui").ui;
const Fixture = @import("fixture.zig").Fixture;
const Options = @import("fixture.zig").Options;

const gpa = std.testing.allocator;

fn expectHole(f: *Fixture, want: ui.Rect) !void {
    const h = f.holes();
    try std.testing.expectEqual(@as(usize, 1), h.len);
    try std.testing.expectApproxEqAbs(want.x, h[0].x, 0.01);
    try std.testing.expectApproxEqAbs(want.y, h[0].y, 0.01);
    try std.testing.expectApproxEqAbs(want.w, h[0].w, 0.01);
    try std.testing.expectApproxEqAbs(want.h, h[0].h, 0.01);
}

test "layout cards sidebar left" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    try expectHole(&f, .{ .x = 232, .y = 8, .w = 1200, .h = 884 });
}

test "layout cards sidebar right" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    f.kea.prefs.set("side_position", .right);
    f.tester.frame();
    try expectHole(&f, .{ .x = 8, .y = 8, .w = 1200, .h = 884 });
}

test "layout strip" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    try expectHole(&f, .{ .x = 0, .y = 52, .w = 1440, .h = 848 });
}

test "layout strip with bookmarks bar" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    _ = f.browser.bookmarks.add("https://kea.app/", "Kea");
    f.kea.prefs.set("bookmarks_bar", true);
    f.tester.frame();
    try expectHole(&f, .{ .x = 0, .y = 82, .w = 1440, .h = 818 });
}

/// The hole's edge: its colour, none when it has no edge.
fn holeBorder(f: *Fixture) ?ui.Color {
    const n = f.tester.ctx.stage_nodes[0];
    return f.tester.ctx.nodes.items[n].style.border;
}

test "card edge only in cards mode" {
    var cards: Fixture = undefined;
    try cards.init(gpa, .{ .sidebar = true });
    defer cards.deinit();
    try std.testing.expect(holeBorder(&cards) != null);
    var strip: Fixture = undefined;
    try strip.init(gpa, .{ .sidebar = false });
    defer strip.deinit();
    try std.testing.expect(holeBorder(&strip) == null);
}

test "column edge follows the press, is remembered, and double-click puts it back" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    // Pressed 3.5 pt inside the edge: the width follows the travel, not the press point.
    f.tester.drag(228.5, 450, 328.5, 450);
    try std.testing.expectEqual(@as(f32, 332), f.kea.prefs.side_width);
    try std.testing.expectEqual(@as(?f64, 332), f.kea.store.double("sidebar.width"));
    try expectHole(&f, .{ .x = 332, .y = 8, .w = 1100, .h = 884 });
    f.tester.doubleClick(328, 450);
    try std.testing.expectEqual(@as(f32, 232), f.kea.prefs.side_width);
}

fn overlaps(a: ui.Rect, b: ui.Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// Nothing Kea draws covers the page: no fill but the card's knock-out
/// shadow, and no edge but the card's own, reaches inside the hole.
fn expectPageClear(opts: Options) !void {
    var f: Fixture = undefined;
    try f.init(gpa, opts);
    defer f.deinit();
    _ = f.browser.open("kea-test://site/page", .{ .foreground = true });
    f.tester.settle(1);
    try std.testing.expect(!f.browser.omni_open);
    const hole = f.holes()[0];
    const inner: ui.Rect = .{ .x = hole.x + 1, .y = hole.y + 1, .w = hole.w - 2, .h = hole.h - 2 };
    for (f.tester.instances.items) |in| {
        const r: ui.Rect = .{ .x = in.rect[0], .y = in.rect[1], .w = in.rect[2], .h = in.rect[3] };
        if (!overlaps(r, inner)) continue;
        const own = @abs(r.x - hole.x) < 0.01 and @abs(r.y - hole.y) < 0.01 and @abs(r.w - hole.w) < 0.01 and @abs(r.h - hole.h) < 0.01;
        if (in.color[3] > 0 and in.kind != 5) {
            std.debug.print("fill over the page: kind {d} rect {any} color {any}\n", .{ in.kind, in.rect, in.color });
            return error.PaintedOverPage;
        }
        if (in.border_width > 0 and in.border_color[3] > 0 and !own) {
            std.debug.print("edge over the page: rect {any}\n", .{in.rect});
            return error.PaintedOverPage;
        }
    }
}

test "nothing paints over the page" {
    try expectPageClear(.{ .sidebar = true });
    try expectPageClear(.{ .sidebar = false });
}
