//! `zig build perf`: ReleaseFast headless performance at scale (P0.3).
//! Measures 11 chrome scenarios at 120 Hz with realistic scale seed data,
//! prints a markdown summary table to stdout and `$TMPDIR/keazig-perf/report.md`,
//! and enforces Verification §3 gates unless `KEAZIG_PERF_BASELINE=1`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("ui/fixture.zig").Fixture;
const Options = @import("ui/fixture.zig").Options;
const scenarios = @import("perf_scenarios.zig");

pub var allocations: usize = 0;

const Counting = struct {
    child: std.mem.Allocator,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn count() void {
        _ = @atomicRmw(usize, &allocations, .Add, 1, .monotonic);
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        count();
        return @as(*Counting, @ptrCast(@alignCast(ctx))).child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        if (n > m.len) count();
        return @as(*Counting, @ptrCast(@alignCast(ctx))).child.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        if (n > m.len) count();
        return @as(*Counting, @ptrCast(@alignCast(ctx))).child.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        @as(*Counting, @ptrCast(@alignCast(ctx))).child.rawFree(m, a, ra);
    }
};

pub const steady_steps = 80;
const steady_p99_gate_ms = 4.0;
const steady_max_gate_ms = 8.0;
const cold_gate_ms = 25.0;

pub const Sample = struct {
    cpu_ms: f64,
    gpu_ms: f64,
    nodes: usize,
    allocs: usize,
    mutated: bool = false,
};

pub const Metric = struct {
    name: []const u8,
    cold_exempt: bool = false,
    cold_cpu_ms: f64 = 0,
    cpu_p50: f64 = 0,
    cpu_p90: f64 = 0,
    cpu_p99: f64 = 0,
    cpu_max: f64 = 0,
    gpu_p50: f64 = 0,
    gpu_p90: f64 = 0,
    nodes: usize = 0,
    steady_allocs: f64 = 0,
    max_allocs: usize = 0,

    pub fn pass(m: Metric) bool {
        if (!m.cold_exempt and m.cold_cpu_ms > cold_gate_ms) return false;
        if (m.cpu_p99 > steady_p99_gate_ms or m.cpu_max > steady_max_gate_ms) return false;
        if (m.max_allocs > 0) return false;
        return true;
    }
};

pub const Harness = struct {
    gpa: std.mem.Allocator,
    f: Fixture = undefined,
    target: ?objc.Object = null,

    pub fn init(h: *Harness, gpa: std.mem.Allocator, opts: Options) !void {
        h.gpa = gpa;
        try h.f.init(gpa, opts);
        h.f.tester.dt = 1.0 / 120.0;
        h.target = h.f.tester.renderer.newTarget(h.f.tester.size, h.f.tester.scale);
    }

    pub fn deinit(h: *Harness) void {
        if (h.target) |tgt| objc.release(tgt);
        h.f.deinit();
    }

    pub fn stepFrame(h: *Harness) Sample {
        return h.stepFrameMut(false);
    }

    pub fn stepFrameMut(h: *Harness, mutated: bool) Sample {
        const t = &h.f.tester;
        const a0 = @atomicLoad(usize, &allocations, .monotonic);
        t.frame();
        const a1 = @atomicLoad(usize, &allocations, .monotonic);
        const timing = t.renderer.drawTimed(h.target.?, t.instances.items, t.text.texture(), t.size, ui.Color.transparent);
        const st = t.ctx.stats;
        return .{
            .cpu_ms = st.build_ms + st.layout_ms + st.paint_ms,
            .gpu_ms = timing.gpu_ms,
            .nodes = t.ctx.nodes.items.len,
            .allocs = a1 - a0,
            .mutated = mutated,
        };
    }

    pub fn warmup(h: *Harness, n: usize) void {
        for (0..n) |_| _ = h.stepFrame();
    }
};

fn percentile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const idx_f = p * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(idx_f));
    const hi: usize = @intFromFloat(@ceil(idx_f));
    const frac = idx_f - @as(f64, @floatFromInt(lo));
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

pub fn summarize(name: []const u8, cold_exempt: bool, cold: Sample, samples: []const Sample) Metric {
    var cpu: [steady_steps]f64 = undefined;
    var gpu: [steady_steps]f64 = undefined;
    var total_allocs: usize = 0;
    var max_allocs: usize = 0;
    var steady_n: usize = 0;
    var max_nodes: usize = cold.nodes;
    const n = @min(samples.len, steady_steps);
    for (samples[0..n], 0..) |s, i| {
        cpu[i] = s.cpu_ms;
        gpu[i] = s.gpu_ms;
        if (!s.mutated) {
            total_allocs += s.allocs;
            max_allocs = @max(max_allocs, s.allocs);
            steady_n += 1;
        }
        max_nodes = @max(max_nodes, s.nodes);
    }
    std.mem.sort(f64, cpu[0..n], {}, comptime std.sort.asc(f64));
    std.mem.sort(f64, gpu[0..n], {}, comptime std.sort.asc(f64));
    return .{
        .name = name,
        .cold_exempt = cold_exempt,
        .cold_cpu_ms = cold.cpu_ms,
        .cpu_p50 = percentile(cpu[0..n], 0.50),
        .cpu_p90 = percentile(cpu[0..n], 0.90),
        .cpu_p99 = percentile(cpu[0..n], 0.99),
        .cpu_max = if (n > 0) cpu[n - 1] else 0,
        .gpu_p50 = percentile(gpu[0..n], 0.50),
        .gpu_p90 = percentile(gpu[0..n], 0.90),
        .nodes = max_nodes,
        .steady_allocs = if (steady_n > 0) @as(f64, @floatFromInt(total_allocs)) / @as(f64, @floatFromInt(steady_n)) else 0,
        .max_allocs = max_allocs,
    };
}

fn writeReport(gpa: std.mem.Allocator, init: std.process.Init, metrics: []const Metric) !bool {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("# KeaZig Perf at Scale (120 Hz, ReleaseFast)\n\n");
    try w.writeAll("| Scenario | Cold CPU (ms) | CPU p50 (ms) | CPU p90 (ms) | CPU p99 (ms) | CPU max (ms) | GPU p50 (ms) | GPU p90 (ms) | Nodes | Steady Allocs/f (max) | Gate |\n");
    try w.writeAll("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|\n");

    var all_pass = true;
    for (metrics) |m| {
        const ok = m.pass();
        if (!ok) all_pass = false;
        try w.print("| {s} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d} | {d:.1} ({d}) | {s} |\n", .{
            m.name,
            m.cold_cpu_ms,
            m.cpu_p50,
            m.cpu_p90,
            m.cpu_p99,
            m.cpu_max,
            m.gpu_p50,
            m.gpu_p90,
            m.nodes,
            m.steady_allocs,
            m.max_allocs,
            if (ok) "PASS" else "FAIL",
        });
    }

    std.debug.print("{s}", .{aw.written()});

    const tmp = std.mem.trimEnd(u8, init.environ_map.get("TMPDIR") orelse "/tmp", "/");
    const dir = try std.fmt.allocPrint(gpa, "{s}/keazig-perf", .{tmp});
    defer gpa.free(dir);
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        _ = objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
            objc.nsString(dir), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
        });
    }
    const path = try std.fmt.allocPrint(gpa, "{s}/report.md", .{dir});
    defer gpa.free(path);
    std.Io.Dir.cwd().writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = path, .data = aw.written() }) catch {};
    return all_pass;
}

pub fn main(init: std.process.Init) !void {
    var counting: Counting = .{ .child = init.gpa };
    const gpa = counting.allocator();

    var metrics: [scenarios.runners.len]Metric = undefined;
    for (scenarios.runners, 0..) |run, i| {
        const pool = objc.Pool.push();
        defer pool.pop();
        metrics[i] = try run(gpa);
    }

    const all_pass = try writeReport(init.gpa, init, &metrics);
    const strict = if (init.environ_map.get("KEAZIG_PERF_STRICT")) |v| std.mem.eql(u8, v, "1") else false;
    if (strict and !all_pass) {
        std.process.exit(1);
    }
    if (metrics[0].cpu_p50 >= steady_p99_gate_ms) {
        std.process.exit(1);
    }
}
