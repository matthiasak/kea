//! P14.3/P14.4: what a long session costs. Twenty real pages opened and
//! closed leave nothing behind (run under `leaks --atExit`), and a blank tab
//! left alone asks for no more than the Breath's 30 frames a second and
//! keeps the process under 2 % of a core.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const main = @import("main.zig");
const Case = main.Case;
const Harness = main.Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "open and close 20 tabs", .run = openClose20 },
    .{ .name = "idle blank tab stays under 30 fps and 2% CPU", .run = idleBlank },
};

fn openClose20(h: *Harness) !void {
    const b = try h.start();
    var buf: [64]u8 = undefined;
    for (0..20) |i| _ = try web.open(h, b, try std.fmt.bufPrint(&buf, "kea-test://site/page?title=T{d}", .{i}));
    try h.expect(b.tabs.items.len >= 20, "{d} tabs after 20 opens", .{b.tabs.items.len});
    while (b.tabs.items.len > 1) b.close(b.tabs.items[b.tabs.items.len - 1]);
    // The closed pages' web views go once WebKit lets go of them.
    h.pump(0.5);
    try h.expect(b.tabs.items.len == 1, "{d} tabs left", .{b.tabs.items.len});
}

fn cpuSeconds() f64 {
    const r = std.posix.getrusage(0);
    const s = r.utime.sec + r.stime.sec;
    const us = r.utime.usec + r.stime.usec;
    return @as(f64, @floatFromInt(s)) + @as(f64, @floatFromInt(us)) / 1e6;
}

extern "c" fn clock_gettime_nsec_np(clock: u32) u64;
/// CLOCK_THREAD_CPUTIME_ID: this thread's CPU time, for the frames' share.
fn threadNs() u64 {
    return clock_gettime_nsec_np(16);
}

fn idleBlank(h: *Harness) !void {
    const b = try h.start();
    try h.expect(b.activeTab().?.isBlank(), "the first tab isn't blank", .{});
    const s = b.window.?.surface.?;
    // Past the opening: the field's appearance, the first layouts.
    h.pump(1);
    // A hidden window's display link never fires, so its pace is kept here
    // as the link keeps it (`Surface.frame`): every refresh while something
    // moves, else after `frame_in`, else not until something asks.
    const wall: f64 = 3;
    const frames0 = s.ctx.frame;
    const cpu0 = cpuSeconds();
    const t0 = ui.clock.now();
    var next = t0;
    var in_frames: u64 = 0;
    var allocs: usize = 0;
    while (true) {
        const now = ui.clock.now();
        if (now - t0 >= wall) break;
        if (now >= next) {
            const f0 = threadNs();
            const a0 = @atomicLoad(usize, &main.allocations, .monotonic);
            s.frame();
            allocs += @atomicLoad(usize, &main.allocations, .monotonic) - a0;
            in_frames += threadNs() - f0;
            const c = &s.ctx;
            next = if (c.animating) now + 1.0 / 60.0 else if (c.frame_in) |f| now + @max(f, 1.0 / 60.0) else t0 + wall;
        }
        const pool = objc.Pool.push();
        nanoui.runFor(@max(0.001, @min(next, t0 + wall) - ui.clock.now()));
        pool.pop();
    }
    const spent = ui.clock.now() - t0;
    const cpu = cpuSeconds() - cpu0;
    const frames = s.ctx.frame - frames0;
    const fps = @as(f64, @floatFromInt(frames)) / spent;
    std.debug.print("     idle: {d} frames in {d:.2} s ({d:.1} fps), cpu {d:.1} ms ({d:.2}% of wall), {d:.1} ms of it in frames, {d} allocations in frames\n", .{ frames, spent, fps, cpu * 1000, cpu / spent * 100, @as(f64, @floatFromInt(in_frames)) / 1e6, allocs });
    try h.expect(fps <= 31, "{d:.1} frames a second while idle", .{fps});
    try h.expect(cpu < 0.02 * spent, "{d:.1} ms of CPU in {d:.2} s idle", .{ cpu * 1000, spent });
    // An idle frame reuses what it had (tab_bar's pill lists were made and
    // freed every frame).
    try h.expect(allocs == 0, "{d} allocations in {d} idle frames", .{ allocs, frames });
    // The other layout, the same: once its slide is over, nothing is made.
    b.prefs.set("sidebar", !b.prefs.sidebar);
    b.syncStageHost();
    // Its first frames make what it needs and slide in: driven at the
    // display's pace until still, then a few more.
    var settled: usize = 0;
    const until = ui.clock.now() + 3;
    while (settled < 5 and ui.clock.now() < until) {
        s.frame();
        settled = if (s.ctx.animating) 0 else settled + 1;
        nanoui.runFor(1.0 / 60.0);
    }
    const a0 = @atomicLoad(usize, &main.allocations, .monotonic);
    for (0..30) |_| s.frame();
    const other = @atomicLoad(usize, &main.allocations, .monotonic) - a0;
    try h.expect(other == 0, "{d} allocations in 30 idle frames with sidebar {}", .{ other, b.prefs.sidebar });
}
