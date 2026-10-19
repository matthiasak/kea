//! What the renderers draw, whichever draws it: instanced quads that are
//! rounded rectangles with borders, glyphs and icons from the atlas,
//! shadows, pictures from the image atlas, or panes of glass, each clipped. Metal draws them on macOS (`metal.zig`, with
//! `shader.metal`); `raster.zig` draws the same pixels on the CPU.
const types = @import("types.zig");
const std = @import("std");

/// One quad, as the shader reads it.
pub const Instance = extern struct {
    rect: [4]f32,
    color: [4]f32,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    clip: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 },
    radius: f32 = 0,
    border_width: f32 = 0,
    kind: f32 = 0,
    /// The clip's rounded corners (`clipRound`): 0 for a plain rectangle.
    clip_round: f32 = 0,
};

/// The clip rectangle's corners rounded by `radius`: those in `corners`
/// (1 top left, 2 top right, 4 bottom right, 8 bottom left), packed in one
/// float as the shader reads it.
pub fn clipRound(radius: f32, corners: u4) f32 {
    if (corners == 0 or radius <= 0) return 0;
    return @as(f32, @floatFromInt(corners)) * 4096 + @min(radius, 4095);
}

/// `clipRound` unpacked: the radius and the corners.
pub fn clipCorners(v: f32) struct { radius: f32, corners: u4 } {
    if (v <= 0) return .{ .radius = 0, .corners = 0 };
    const m = @floor(v / 4096);
    return .{ .radius = v - m * 4096, .corners = @intFromFloat(m) };
}

pub const Kind = struct {
    pub const quad: f32 = 0;
    pub const text: f32 = 1;
    pub const shadow: f32 = 2;
    /// A picture from the image atlas (`images.zig`), its corners rounded.
    pub const image: f32 = 3;
    /// A pane of Liquid Glass over what was drawn before it (`glass.zig`):
    /// `color` its tint, `uv` its bezel, refraction, opacity and rim width,
    /// `border_color` its tone (low, high, curve, saturation), and
    /// `border_width` the blur of what shows through, all in points.
    pub const glass: f32 = 4;
};

pub fn color4(c: types.Color) [4]f32 {
    return .{ c.r, c.g, c.b, c.a };
}

pub fn clip4(r: types.Rect) [4]f32 {
    return .{ r.x, r.y, r.x + r.w, r.y + r.h };
}

/// A rendered frame: BGRA, premultiplied, `width * 4` bytes per row.
pub const Pixels = struct {
    bytes: []u8,
    width: usize,
    height: usize,

    pub fn deinit(p: Pixels, gpa: std.mem.Allocator) void {
        gpa.free(p.bytes);
    }
};
