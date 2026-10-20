//! Springs and tweens (`motion.zig`): SwiftUI's spring settles in time
//! without overshooting much, tweens follow their curves, and Reduce
//! Motion jumps to the target.
const std = @import("std");
const testing = std.testing;
const motion = @import("motion.zig");
const Context = @import("context.zig").Context;
const TextSystem = @import("text.zig").TextSystem;

const glide: motion.Spring = .{ .response = 0.34, .damping = 0.82 };

/// A context whose frames are stepped by hand (motion never draws text).
fn context(ts: *TextSystem) Context {
    return Context.init(testing.allocator, ts);
}

fn nextFrame(c: *Context) void {
    c.frame += 1;
    c.animating = false;
}

test "spring (0.34,0.82) settles within 0.8 s and overshoots < 2 %" {
    var ts: TextSystem = undefined;
    var c = context(&ts);
    defer c.deinit();
    try testing.expectEqual(@as(f32, 0), motion.spring(&c, 1, 0, 0, glide));
    var peak: f32 = 0;
    var settled: ?u32 = null;
    var frames: u32 = 0;
    while (frames < 120) {
        nextFrame(&c);
        frames += 1;
        const v = motion.spring(&c, 1, 0, 1, glide);
        peak = @max(peak, v);
        if (!c.animating and settled == null) settled = frames;
    }
    try testing.expect(peak > 1); // underdamped: it does overshoot
    try testing.expect(peak < 1.02);
    try testing.expect(@as(f32, @floatFromInt(settled.?)) * c.dt <= 0.8);
    try testing.expectEqual(@as(f32, 1), motion.spring(&c, 1, 0, 1, glide));
}

test "springFrom starts at from" {
    var ts: TextSystem = undefined;
    var c = context(&ts);
    defer c.deinit();
    try testing.expectEqual(@as(f32, 0.97), motion.springFrom(&c, 2, 0, 0.97, 1, glide));
    try testing.expect(c.animating);
    nextFrame(&c);
    const v = motion.springFrom(&c, 2, 0, 0.97, 1, glide);
    try testing.expect(v > 0.97 and v < 1);
    // Asked again in the same frame (a view built twice): no step.
    try testing.expectEqual(v, motion.springFrom(&c, 2, 0, 0.97, 1, glide));
}

/// Runs a tween from 0 toward 1 over 1 s for `seconds`; its value then.
fn tweenFor(c: *Context, curve: motion.Curve, seconds: f32) f32 {
    _ = motion.tween(c, 3, 0, 0, 1, curve);
    var v: f32 = 0;
    const frames: u32 = @intFromFloat(@round(seconds / c.dt));
    for (0..frames) |_| {
        nextFrame(c);
        v = motion.tween(c, 3, 0, 1, 1, curve);
    }
    return v;
}

test "tween ease_out at half time is > 0.5 of the way" {
    var ts: TextSystem = undefined;
    var c = context(&ts);
    defer c.deinit();
    const v = tweenFor(&c, .ease_out, 0.5);
    try testing.expect(v > 0.5 and v < 1);
    try testing.expect(c.animating);
}

test "tween bezier (0.22,1,0.36,1) at quarter time is > 0.6 of the way" {
    var ts: TextSystem = undefined;
    var c = context(&ts);
    defer c.deinit();
    const v = tweenFor(&c, .{ .bezier = .{ 0.22, 1, 0.36, 1 } }, 0.25);
    try testing.expect(v > 0.6 and v < 1);
    // The curve's ends are its ends.
    try testing.expectEqual(@as(f32, 0), motion.ease(.{ .bezier = .{ 0.22, 1, 0.36, 1 } }, 0));
    try testing.expectApproxEqAbs(@as(f32, 1), motion.ease(.ease_in_out, 1), 1e-4);
}

test "reduce_motion returns target immediately" {
    var ts: TextSystem = undefined;
    var c = context(&ts);
    defer c.deinit();
    _ = motion.tween(&c, 4, 0, 0, 1, .linear);
    _ = motion.spring(&c, 5, 0, 0, glide);
    nextFrame(&c);
    c.reduce_motion = true;
    try testing.expectEqual(@as(f32, 1), motion.tween(&c, 4, 0, 1, 1, .linear));
    try testing.expectEqual(@as(f32, 1), motion.spring(&c, 5, 0, 1, glide));
    try testing.expectEqual(@as(f32, 1), motion.springFrom(&c, 6, 0, 0, 1, glide));
    try testing.expect(!c.animating);
    // Their state is dropped.
    try testing.expectEqual(@as(u32, 0), c.motion.entries.count());
}

fn analyticSpring(t: f32, s: motion.Spring) f32 {
    const w: f64 = 2.0 * std.math.pi / @as(f64, s.response);
    const z: f64 = s.damping;
    const s1 = @sqrt(1.0 - z * z);
    const wd = w * s1;
    const tf: f64 = t;
    const v = 1.0 - @exp(-z * w * tf) * (@cos(wd * tf) + (z / s1) * @sin(wd * tf));
    return @floatCast(v);
}

test "spring matches analytic damped oscillator within 0.5% under jittered dt and hitch" {
    if (!@hasDecl(motion, "jump")) return;
    var ts: TextSystem = undefined;
    var c = context(&ts);
    defer c.deinit();
    try testing.expectEqual(@as(f32, 0), motion.spring(&c, 7, 0, 0, glide));
    var t: f32 = 0;
    for (0..60) |step| {
        const dt: f32 = if (step == 20) 0.140 else if (step % 2 == 0) 0.0074 else 0.0093;
        c.dt = dt;
        t += dt;
        nextFrame(&c);
        const v = motion.spring(&c, 7, 0, 1, glide);
        const expected = analyticSpring(t, glide);
        try testing.expectApproxEqAbs(expected, v, 0.005);
    }
}
