//! Additional on-screen smoothness scenarios (S14+).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const main = @import("main.zig");
const Harness = main.Harness;
const web = @import("web.zig");
const smooth = @import("smooth.zig");
const ScenarioDef = smooth.ScenarioDef;
const SpanMark = smooth.SpanMark;

extern "c" fn CGEventCreateScrollWheelEvent2(
    source: ?*anyopaque,
    units: u32,
    wheel_count: u32,
    wheel1: i32,
    wheel2: i32,
    wheel3: i32,
) ?*anyopaque;
extern "c" fn CGEventSetLocation(event: *anyopaque, location: objc.CGPoint) void;
extern "c" fn CFRelease(cf: *anyopaque) void;

pub const all = [_]ScenarioDef{
    .{ .id = "S14", .name = "Scroll a long page (surface must stay idle)", .run = s14PageScroll },
};

fn sendWebScroll(wv: objc.Object, dy: i32) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const window = objc.msg(?objc.Object, wv, "window", .{}) orelse return;
    const bounds = objc.msg(objc.CGRect, wv, "bounds", .{});
    const center = objc.CGPoint{ .x = bounds.size.width * 0.5, .y = bounds.size.height * 0.5 };
    const at = objc.msg(objc.CGPoint, wv, "convertPoint:toView:", .{ center, @as(?objc.Object, null) });
    const screen_pt = objc.msg(objc.CGPoint, window, "convertPointToScreen:", .{at});
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const ph: f64 = if (objc.msg(objc.NSUInteger, screens, "count", .{}) > 0)
        objc.msg(objc.CGRect, objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)}), "frame", .{}).size.height
    else
        900;
    const cg = CGEventCreateScrollWheelEvent2(null, 0, 1, dy, 0, 0) orelse return;
    defer CFRelease(cg);
    CGEventSetLocation(cg, .{ .x = screen_pt.x, .y = ph - screen_pt.y });
    if (objc.msg(?objc.Object, objc.class("NSEvent"), "eventWithCGEvent:", .{@as(objc.Object, @ptrCast(cg))})) |ev| {
        objc.msg(void, wv, "scrollWheel:", .{ev});
    }
}

fn s14PageScroll(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    b.prefs.set("shows_reading", true);
    const tab = try web.open(h, b, "kea-test://site/f/long.html");
    smooth.waitUntilSettled(s, 0.5);
    const wv = tab.web orelse return h.fail("no web view on long.html tab", .{});

    const m0 = fl.mark();
    const cpu0 = smooth.cpuSeconds();
    const t0 = ui.clock.now();
    for (0..120) |_| {
        sendWebScroll(wv, -8);
        smooth.waitLoop(0.0083);
    }
    for (0..120) |_| {
        sendWebScroll(wv, 8);
        smooth.waitLoop(0.0083);
    }
    const spent = @max(0.001, ui.clock.now() - t0);
    const cpu_pct = ((smooth.cpuSeconds() - cpu0) / spent) * 100.0;
    const m1 = fl.mark();
    const fps = @as(f64, @floatFromInt(m1 - m0)) / spent;
    const extra: smooth.ExtraMetrics = .{ .fps = fps, .cpu_pct = cpu_pct };
    return .{
        .{ .start = m0, .end = m1, .extra = extra },
        .{ .start = m1, .end = m1, .extra = extra },
        .{ .start = m1, .end = m1, .extra = extra },
    };
}
