//! P4.3: strip tab close width lock and resize jump tests.
const std = @import("std");
const ui = @import("nanoui").ui;
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;

fn pillRect(f: *Fixture, id: u64) !ui.Rect {
    for (f.browser.strip.seen.items) |s| if (s.id == id) {
        return f.tester.ctx.rects.get(s.node) orelse error.NotLaidOut;
    };
    return error.NotDrawn;
}

test "closing a tab inside the strip locks pill width until pointer leaves" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = false, .tabs = 11 });
    defer f.deinit();
    f.tester.settle(2);

    const Victim = f.browser.tabs.items[1];
    const Keeper = f.browser.tabs.items[0];
    const r0 = try pillRect(&f, Keeper.id);
    const rv = try pillRect(&f, Victim.id);
    try t.expect(r0.w < 186);

    // Move inside the strip onto Victim and close it via its close disc.
    const cy = rv.y + rv.h / 2;
    f.tester.moveTo(rv.x + rv.w / 2, cy);
    f.tester.settle(0.5);
    f.tester.click(rv.x + rv.w - 7 - 7.5, cy);
    f.tester.settle(1.5);

    // Pointer is still inside the strip: remaining pills keep the locked width.
    const r1 = try pillRect(&f, Keeper.id);
    try t.expectApproxEqAbs(r0.w, r1.w, 0.5);

    // Move pointer out of the strip: pills unlock and widen to their natural width.
    f.tester.moveTo(400, 300);
    f.tester.settle(1.5);
    const r2 = try pillRect(&f, Keeper.id);
    try t.expect(r2.w > r0.w + 2);
}

test "window resize jumps strip pills to their layout targets every frame" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = false, .tabs = 11 });
    defer f.deinit();
    f.tester.settle(2);

    for (0..10) |step| {
        f.tester.size.w = 1440 - @as(f32, @floatFromInt((step + 1) * 30));
        f.tester.frame();
        const each = f.browser.strip.seen.items[0].w;
        var want_x: f32 = 0;
        for (f.browser.strip.seen.items) |s| {
            try t.expectApproxEqAbs(want_x, s.x, 0.01);
            try t.expectApproxEqAbs(each, s.w, 0.01);
            want_x += s.w + 2;
        }
    }
}
