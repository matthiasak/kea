//! P5.6: the link bubble (StatusLine.swift `LinkBubble`) — 26 high, 10 in
//! from the page's bottom corner, never wider than `min(0.6·page, 640)`,
//! cut in the middle, and at the other corner when the pointer is in its own.
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const long = "https://kea.example/" ++ @as([300]u8, @splat('a')) ++ "/end";

/// The capsule: the box around the address's text.
fn bubble(f: *Fixture) ?ui.Rect {
    const c = &f.tester.ctx;
    for (c.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.startsWith(u8, tx.str, "https://kea.example/")) return c.nodes.items[n.parent].rect,
        else => {},
    };
    return null;
}

fn bubbleText(f: *Fixture) []const u8 {
    for (f.tester.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.startsWith(u8, tx.str, "https://kea.example/")) return tx.str,
        else => {},
    };
    return "";
}

fn expectAt(f: *Fixture, right: bool) !ui.Rect {
    const hole = f.holes()[0];
    const r = bubble(f) orelse return error.NoBubble;
    const widest = @min(hole.w * 0.6, 640);
    try std.testing.expectApproxEqAbs(@as(f32, 26), r.h, 0.01);
    try std.testing.expect(r.w <= widest + 0.5);
    // Cut close to the widest it may be, the start and the end kept.
    try std.testing.expect(r.w >= widest - 12);
    const text = bubbleText(f);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null and std.mem.endsWith(u8, text, "/end"));
    try std.testing.expectApproxEqAbs(hole.y + hole.h - 10, r.y + r.h, 0.5);
    if (right)
        try std.testing.expectApproxEqAbs(hole.x + hole.w - 10, r.x + r.w, 0.5)
    else
        try std.testing.expectApproxEqAbs(hole.x + 10, r.x, 0.5);
    return r;
}

test "link bubble keeps to its widest and jumps from the pointer's corner" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const b = f.browser;
    const t = b.activeTab().?;
    b.link_status.set(b.gpa, long, t.serial, false);
    f.tester.settle(1);
    const at = try expectAt(&f, false);
    try std.testing.expectApproxEqAbs(@as(f32, 640), at.w, 12);

    // The pointer over the bubble's own corner: it goes to the other one.
    const hole = f.holes()[0];
    const x = at.x + at.w / 2 - hole.x;
    const from_bottom = hole.y + hole.h - (at.y + at.h / 2);
    const jumps = app.link_bubble.cornerJump(x, from_bottom, hole.w);
    try std.testing.expect(jumps);
    b.link_status.set(b.gpa, long, t.serial, jumps);
    f.tester.settle(1);
    _ = try expectAt(&f, true);

    // A narrower page: 0.6 of it.
    f.tester.resize(800, 600);
    f.tester.settle(1);
    const narrow = try expectAt(&f, true);
    try std.testing.expectApproxEqAbs(@as(f32, 480), narrow.w, 12);

    // Dismissed: it fades and is gone.
    b.link_status.dismiss();
    f.tester.settle(1);
    try std.testing.expect(bubble(&f) == null);
}

test "link bubble stands only over the page the link is on" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false, .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    const other = b.tabs.items[1];
    b.link_status.set(b.gpa, long, other.serial, false);
    f.tester.settle(1);
    try std.testing.expect(bubble(&f) == null);
}
