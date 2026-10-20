//! A symbol turned about its centre (`IconOptions.rotation`), as SwiftUI's
//! `rotationEffect`: its coverage resampled into a square the turned
//! picture fits, at one of `steps` angles so a turning icon reuses sprites.
const std = @import("std");

/// 3° apart.
pub const steps: u32 = 120;

/// The step nearest `radians` (clockwise), 0 for none.
pub fn quantize(radians: f32) u8 {
    if (radians == 0) return 0;
    const turns = @mod(radians / (2 * std.math.pi), 1);
    return @intCast(@as(u32, @intFromFloat(@round(turns * @as(f32, steps)))) % steps);
}

/// The side of the square a w×h picture turns within.
pub fn side(w: u32, h: u32) u32 {
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    return @intFromFloat(@ceil(@sqrt(fw * fw + fh * fh)));
}

/// `src` (w×h, rows top down) turned clockwise by `step` into `dst`
/// (s×s), sampled bilinearly; outside the picture is clear.
pub fn turned(src: []const u8, w: u32, h: u32, step: u8, dst: []u8, s: u32) void {
    const a = 2 * std.math.pi * @as(f32, @floatFromInt(step)) / @as(f32, steps);
    const cos = @cos(a);
    const sin = @sin(a);
    const cx = @as(f32, @floatFromInt(w)) / 2;
    const cy = @as(f32, @floatFromInt(h)) / 2;
    const d = @as(f32, @floatFromInt(s)) / 2;
    for (0..s) |y| for (0..s) |x| {
        const px = @as(f32, @floatFromInt(x)) + 0.5 - d;
        const py = @as(f32, @floatFromInt(y)) + 0.5 - d;
        // Back through the turn to where it came from.
        const sx = cos * px + sin * py + cx - 0.5;
        const sy = -sin * px + cos * py + cy - 0.5;
        dst[y * s + x] = sample(src, w, h, sx, sy);
    };
}

fn sample(src: []const u8, w: u32, h: u32, x: f32, y: f32) u8 {
    const x0 = @floor(x);
    const y0 = @floor(y);
    const fx = x - x0;
    const fy = y - y0;
    const at = struct {
        fn f(s: []const u8, sw: u32, sh: u32, ix: f32, iy: f32) f32 {
            if (ix < 0 or iy < 0 or ix >= @as(f32, @floatFromInt(sw)) or iy >= @as(f32, @floatFromInt(sh))) return 0;
            return @floatFromInt(s[@as(usize, @intFromFloat(iy)) * sw + @as(usize, @intFromFloat(ix))]);
        }
    }.f;
    const top = at(src, w, h, x0, y0) * (1 - fx) + at(src, w, h, x0 + 1, y0) * fx;
    const bottom = at(src, w, h, x0, y0 + 1) * (1 - fx) + at(src, w, h, x0 + 1, y0 + 1) * fx;
    return @intFromFloat(@round(std.math.clamp(top * (1 - fy) + bottom * fy, 0, 255)));
}

test "a quarter turn moves the top right corner to the bottom right" {
    // 2×2, only the top right lit.
    const src = [_]u8{ 0, 255, 0, 0 };
    var dst: [4]u8 = undefined;
    turned(&src, 2, 2, steps / 4, &dst, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &dst);
    try std.testing.expectEqual(@as(u8, 30), quantize(std.math.pi / 2.0));
}
