//! `Ring` (TabBar.swift): a turning arc for what is still coming, and the
//! download door's progress arc (Fetching.swift). nanoui strokes no arcs,
//! so each is a picture drawn once with CoreGraphics and kept: 24 turns
//! of the ring per size and appearance, 100 steps of progress.
const std = @import("std");
const ui = @import("nanoui").ui;
const cg = @import("../sys/cg.zig");
const palette = @import("../design/palette.zig");
const motion = @import("../design/motion.zig");

const turn_seconds: f32 = 0.85;
const turns: u32 = 48;

const Picture = struct {
    size: f32,
    scale: f32,
    dark: bool,
    /// A turn of the ring (`turn`), or a step of progress (out of 100).
    kind: enum(u8) { turn, progress, wind },
    step: u32,
};

/// Pictures by `Picture`'s hash, for the life of the app (main thread).
// ponytail: never evicted; a handful of sizes × 124 tiny PNGs.
var pictures: std.AutoHashMapUnmanaged(u64, []u8) = .empty;
var warmed_scale: f32 = 0;
var warmed_mask: u8 = 0;

fn warm(scale: f32, dark: bool) void {
    const bit: u8 = if (dark) 2 else 1;
    if (warmed_scale != scale) {
        warmed_scale = scale;
        warmed_mask = 0;
    }
    if (warmed_mask & bit != 0) return;
    warmed_mask |= bit;
    for ([_]f32{ 10, 11 }) |sz| {
        for (0..turns) |step| {
            _ = png(.{ .size = sz, .scale = scale, .dark = dark, .kind = .turn, .step = @intCast(step) });
        }
    }
}

fn png(p: Picture) ?[]const u8 {
    var h = std.hash.Wyhash.init(0x7269_6e67);
    inline for (.{ p.size, p.scale, @as(u8, @intFromBool(p.dark)), @backingInt(p.kind), p.step }) |v| h.update(std.mem.asBytes(&v));
    const k = h.final();
    const gop = pictures.getOrPut(std.heap.c_allocator, k) catch return null;
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = draw(p) catch {
        _ = pictures.remove(k);
        return null;
    };
    return gop.value_ptr.*;
}

fn draw(p: Picture) ![]u8 {
    const gpa = std.heap.c_allocator;
    const b = try cg.Bitmap.init(gpa, p.size, p.size, p.scale);
    defer b.deinit(gpa);
    paint(b, p);
    return b.png(gpa);
}

fn paint(b: cg.Bitmap, p: Picture) void {
    const pal = palette.get(p.dark);
    const mid: f64 = p.size / 2;
    const tau = 2 * std.math.pi;
    cg.CGContextSetLineCap(b.ctx, cg.line_cap_round);
    switch (p.kind) {
        .turn => {
            // A circle inset by half its line, stroked to 0.78 and turned
            // clockwise (y is up here, so the angle falls).
            const lw: f64 = 1.4;
            const start = -tau * @as(f64, @floatFromInt(p.step)) / turns;
            cg.CGContextSetLineWidth(b.ctx, lw);
            b.stroke(pal.muted.alpha(0.7));
            cg.CGContextAddArc(b.ctx, mid, mid, mid - lw / 2, start, start + 0.78 * tau, 0);
            cg.CGContextStrokePath(b.ctx);
        },
        .progress => {
            // The track, then the part done from twelve o'clock clockwise.
            const lw: f64 = 1.5;
            const r = mid - lw / 2;
            cg.CGContextSetLineWidth(b.ctx, lw);
            b.stroke(pal.muted.alpha(0.3));
            cg.CGContextAddArc(b.ctx, mid, mid, r, 0, tau, 0);
            cg.CGContextStrokePath(b.ctx);
            const done = @max(0.02, @as(f64, @floatFromInt(p.step)) / 100);
            b.stroke(pal.ink.alpha(0.7));
            cg.CGContextAddArc(b.ctx, mid, mid, r, std.math.pi / 2.0, std.math.pi / 2.0 - tau * done, 1);
            cg.CGContextStrokePath(b.ctx);
        },
        .wind => {
            // The swipe disc's line (Stage.swift `Disc`): ink, 1.5 wide,
            // inset 0.75, wound from twelve o'clock clockwise.
            const lw: f64 = 1.5;
            if (p.step == 0) return;
            cg.CGContextSetLineWidth(b.ctx, lw);
            b.stroke(pal.ink);
            const r = mid - 0.75 - lw / 2;
            const done = @as(f64, @floatFromInt(p.step)) / 100;
            cg.CGContextAddArc(b.ctx, mid, mid, r, std.math.pi / 2.0, std.math.pi / 2.0 - tau * done, 1);
            cg.CGContextStrokePath(b.ctx);
        },
    }
}

fn show(c: *ui.Context, p: Picture) void {
    if (p.kind == .turn and (p.size == 10 or p.size == 11)) warm(p.scale, p.dark);
    const bytes = png(p) orelse {
        _ = c.leaf(.{ .width = .{ .px = p.size }, .height = .{ .px = p.size } }, .none, null);
        return;
    };
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "kea.ring.{d}.{d}.{d}.{d}.{d}", .{ p.size, p.scale, @intFromBool(p.dark), @backingInt(p.kind), p.step }) catch "kea.ring";
    _ = ui.image(c, .{ .key = key, .bytes = bytes, .max_width = p.size, .max_height = p.size, .radius = 0, .scale = p.scale });
}

/// Which of the 64 turns shows at `time` seconds.
pub fn turnAt(time: f64) u32 {
    const f = time / turn_seconds;
    return @as(u32, @intFromFloat(@floor((f - @floor(f)) * turns))) % turns;
}

/// `Ring(size:)`: turning once every 0.75 s, a frame asked for each turn.
pub fn ring(c: *ui.Context, size: f32) void {
    show(c, .{ .size = size, .scale = c.scale, .dark = c.theme.dark, .kind = .turn, .step = turnAt(c.time) });
    c.frameIn(turn_seconds / @as(f32, @floatFromInt(turns)));
}

/// The download door's progress: `fraction` done, easing over 0.2 s.
pub fn progressArc(c: *ui.Context, size: f32, fraction: f32) void {
    const f = ui.tween(c, c.peekId(null), 0x6172_63, std.math.clamp(fraction, 0, 1), 0.2, motion.quick_curve);
    show(c, .{ .size = size, .scale = c.scale, .dark = c.theme.dark, .kind = .progress, .step = @intFromFloat(@round(f * 100)) });
}

/// The swipe disc's wound line, `fraction` of the way round.
pub fn windArc(c: *ui.Context, size: f32, fraction: f32) void {
    show(c, .{ .size = size, .scale = c.scale, .dark = c.theme.dark, .kind = .wind, .step = @intFromFloat(@round(std.math.clamp(fraction, 0, 1) * 100)) });
}

test "ring pictures are PNGs and the turn follows the clock" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 0), turnAt(0));
    try t.expectEqual(@as(u32, 5), turnAt(turn_seconds / turns * 5.5));
    try t.expectEqual(@as(u32, 0), turnAt(turn_seconds * 3 + 0.001));
    for ([_]Picture{
        .{ .size = 10, .scale = 2, .dark = false, .kind = .turn, .step = 3 },
        .{ .size = 12, .scale = 2, .dark = true, .kind = .progress, .step = 40 },
    }) |p| {
        const bytes = png(p) orelse return error.NoPicture;
        try t.expect(std.mem.startsWith(u8, bytes, "\x89PNG"));
        try t.expectEqual(bytes.ptr, (png(p) orelse return error.NoPicture).ptr);
    }
    // Turn 0 at 2× (20 px): the arc runs through the top; its gap is the
    // lower right (y is up in CoreGraphics, rows run down in memory).
    const b = try cg.Bitmap.init(t.allocator, 10, 10, 2);
    defer b.deinit(t.allocator);
    paint(b, .{ .size = 10, .scale = 2, .dark = false, .kind = .turn, .step = 0 });
    const alpha = struct {
        fn at(bm: cg.Bitmap, row: usize, col: usize) u8 {
            return bm.bytes[(row * bm.width + col) * 4 + 3];
        }
    }.at;
    try t.expect(alpha(b, 1, 10) > 0);
    try t.expectEqual(@as(u8, 0), alpha(b, 15, 16));
    try t.expectEqual(@as(u8, 0), alpha(b, 10, 10));
}
