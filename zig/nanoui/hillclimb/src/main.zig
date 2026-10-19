//! nanoui's hill-climb: a terminal app that renders benchmark scenes
//! offscreen with nanoui and with mygo, frame after frame, and compares
//! their CPU and GPU costs with each other and with earlier runs. No
//! window opens, nothing takes focus.
//!
//!   zig build run                          all scenes, nanoui and mygo
//!   zig build run -- --label "glyph atlas" name this run in the history
//!   zig build run -- --scene text --frames 600 --only nanoui
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const scenes = @import("scenes.zig");
const report = @import("report.zig");
const mygo = @import("mygo.zig");

extern "c" fn CACurrentMediaTime() f64;

pub const width = 900;
pub const height = 640;
pub const scale = 2;
const warmup = 30;

pub const Result = struct {
    fw: []const u8,
    scene: []const u8,
    frames: usize,
    /// Median CPU time of building, laying out and painting a frame.
    frame_ms: f64,
    frame_p95: f64,
    /// Median CPU time of encoding it for the GPU.
    encode_ms: f64,
    /// Median GPU time of drawing it.
    gpu_ms: f64,
    /// The process's CPU time (user + system) per frame, all included.
    cpu_ms: f64,
    /// What the GPU draws: nanoui's instances, mygo's scene operations.
    ops: usize,
    /// nanoui's phases of a frame (medians); mygo reports none.
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
};

const Options = struct {
    frames: usize = 300,
    /// Runs of each scene; the one with the lowest median frame is kept,
    /// the others being the same work disturbed by the rest of the system.
    repeat: usize = 3,
    only: ?[]const u8 = null,
    scenes: []const scenes.Scene = std.enums.values(scenes.Scene),
    label: []const u8 = "",
};

fn cpuSeconds() f64 {
    const ru = std.posix.getrusage(0);
    const tv = struct {
        fn s(t: anytype) f64 {
            return @as(f64, @floatFromInt(t.sec)) + @as(f64, @floatFromInt(t.usec)) / 1e6;
        }
    }.s;
    return tv(ru.utime) + tv(ru.stime);
}

fn medianOf(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

fn p95Of(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len * 95 / 100];
}

/// Runs `scene` with nanoui: the view, layout and paint of a frame as a
/// window runs them, then the Metal renderer drawing it into a texture.
fn runNanoui(gpa: std.mem.Allocator, scene: scenes.Scene, frames: usize) !Result {
    var state: scenes.State = .{ .scene = scene };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, scenes.State.view), .{ .width = width, .height = height, .scale = scale });
    defer t.deinit();
    t.dt = 1.0 / 120.0;
    const target = t.renderer.newTarget(t.size, t.scale);
    defer nanoui.objc.release(target);

    const frame_ms = try gpa.alloc(f64, frames);
    defer gpa.free(frame_ms);
    const encode_ms = try gpa.alloc(f64, frames);
    defer gpa.free(encode_ms);
    const gpu_ms = try gpa.alloc(f64, frames);
    defer gpa.free(gpu_ms);
    var phases: [3][]f64 = undefined;
    for (&phases) |*ph| ph.* = try gpa.alloc(f64, frames);
    defer for (phases) |ph| gpa.free(ph);
    var cpu0: f64 = 0;
    for (0..warmup + frames) |i| {
        if (i == warmup) cpu0 = cpuSeconds();
        state.frame = i;
        state.time = @as(f32, @floatFromInt(i)) / 120;
        t.time = state.time;
        const t0 = CACurrentMediaTime();
        t.frame();
        const ft = (CACurrentMediaTime() - t0) * 1000;
        const timing = t.renderer.drawTimed(target, t.instances.items, t.text.texture(), t.size, t.theme.background);
        if (i >= warmup) {
            frame_ms[i - warmup] = ft;
            encode_ms[i - warmup] = timing.encode_ms;
            gpu_ms[i - warmup] = timing.gpu_ms;
            phases[0][i - warmup] = t.ctx.stats.build_ms;
            phases[1][i - warmup] = t.ctx.stats.layout_ms;
            phases[2][i - warmup] = t.ctx.stats.paint_ms;
        }
    }
    const cpu = (cpuSeconds() - cpu0) * 1000 / @as(f64, @floatFromInt(frames));
    return .{
        .fw = "nanoui",
        .scene = @tagName(scene),
        .frames = frames,
        .frame_ms = medianOf(frame_ms),
        .frame_p95 = p95Of(frame_ms),
        .encode_ms = medianOf(encode_ms),
        .gpu_ms = medianOf(gpu_ms),
        .cpu_ms = cpu,
        .ops = t.instances.items.len,
        .build_ms = medianOf(phases[0]),
        .layout_ms = medianOf(phases[1]),
        .paint_ms = medianOf(phases[2]),
    };
}

fn better(a: ?Result, b: Result) Result {
    return if (a) |x| (if (x.frame_ms <= b.frame_ms) x else b) else b;
}

fn parseArgs(init: std.process.Init) !Options {
    const arena = init.arena.allocator();
    var o: Options = .{};
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--repeat")) {
            o.repeat = @max(1, try std.fmt.parseInt(usize, next, 10));
            i += 1;
        } else if (std.mem.eql(u8, a, "--frames")) {
            o.frames = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--only")) {
            o.only = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--label")) {
            o.label = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--scene")) {
            var list: std.ArrayList(scenes.Scene) = .empty;
            var it = std.mem.splitScalar(u8, next, ',');
            while (it.next()) |name| try list.append(arena, std.meta.stringToEnum(scenes.Scene, name) orelse return error.UnknownScene);
            o.scenes = list.items;
            i += 1;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("usage: hillclimb [--scene boxes,text,scroll,dashboard] [--frames N] [--only nanoui|mygo] [--label NAME]\n", .{});
            std.process.exit(0);
        } else return error.UnknownArgument;
    }
    return o;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const opts = try parseArgs(init);
    const want = struct {
        fn f(o: Options, fw: []const u8) bool {
            return o.only == null or std.mem.eql(u8, o.only.?, fw);
        }
    }.f;

    report.header(opts.frames);
    var results: std.ArrayList(Result) = .empty;
    var mygo_error: ?anyerror = null;
    if (want(opts, "mygo")) {
        report.status("building mygo's twin (go test -c)…");
        mygo.build(init) catch |err| {
            report.status("");
            mygo_error = err;
            std.debug.print("mygo skipped: {s}\n", .{@errorName(err)});
        };
    }
    for (opts.scenes) |scene| {
        var n_best: ?Result = null;
        var m_best: ?Result = null;
        for (0..opts.repeat) |rep| {
            if (want(opts, "nanoui")) {
                report.status(try std.fmt.allocPrint(arena, "nanoui · {s} · run {d}/{d}…", .{ @tagName(scene), rep + 1, opts.repeat }));
                n_best = better(n_best, try runNanoui(gpa, scene, opts.frames));
            }
            if (want(opts, "mygo") and mygo.ready) {
                report.status(try std.fmt.allocPrint(arena, "mygo · {s} · run {d}/{d}…", .{ @tagName(scene), rep + 1, opts.repeat }));
                if (mygo.run(init, scene, opts.frames)) |r| {
                    m_best = better(m_best, r);
                } else |err| std.debug.print("mygo {s}: {s}\n", .{ @tagName(scene), @errorName(err) });
            }
        }
        if (n_best) |r| try results.append(arena, r);
        if (m_best) |r| try results.append(arena, r);
    }
    report.status("");
    const history = report.loadHistory(init) catch &.{};
    report.table(results.items, history);
    if (mygo_error) |err| std.debug.print("\x1b[31mmygo's twin did not build ({s}): its columns are empty.\x1b[0m\n", .{@errorName(err)});
    try report.appendHistory(init, opts.label, results.items);
}
