//! Kea's colours (`Palette.NS`, Design.swift:45-64): a light and a dark
//! value for each. The greys are `NSColor(white:)`, converted to sRGB by
//! AppKit itself so they match Kea to the bit; the tints are sRGB as given.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const objc = nanoui.objc;

pub const Palette = struct {
    ground: ui.Color,
    ink: ui.Color,
    muted: ui.Color,
    faint: ui.Color,
    hairline: ui.Color,
    wash: ui.Color,
    pin_live: ui.Color,
    hover: ui.Color,
    frame: ui.Color,
    side_wash: ui.Color,
    side_hover: ui.Color,
    side_tile: ui.Color,
    side_pin_live: ui.Color,
    resting: ui.Color,
    safe: ui.Color,
    unsafe: ui.Color,
    sunset: ui.Color,
    feather: ui.Color,
};

/// `[light, dark]`, made on first use (main thread).
var made: ?[2]Palette = null;

/// The palette for a dark or a light window.
pub fn get(dark: bool) *const Palette {
    if (made == null) made = .{ make(false), make(true) };
    return &made.?[@intFromBool(dark)];
}

fn make(dark: bool) Palette {
    const pool = objc.Pool.push();
    defer pool.pop();
    const d = dark;
    return .{
        .ground = white(if (d) 0.11 else 1.0),
        .ink = white(if (d) 0.93 else 0.09),
        .muted = white(if (d) 0.58 else 0.55),
        .faint = white(if (d) 0.32 else 0.83),
        .hairline = white(if (d) 0.20 else 0.91),
        .wash = white(if (d) 0.175 else 0.937),
        .pin_live = white(if (d) 0.21 else 0.90),
        .hover = white(if (d) 0.15 else 0.965),
        .frame = white(if (d) 0.075 else 0.955),
        .side_wash = white(if (d) 0.155 else 0.895),
        .side_hover = white(if (d) 0.13 else 0.915),
        .side_tile = white(if (d) 0.115 else 0.925),
        .side_pin_live = white(if (d) 0.19 else 0.86),
        .resting = white(if (d) 0.30 else 0.80),
        .safe = if (d) rgb(0.29, 0.87, 0.50) else rgb(0.08, 0.50, 0.24),
        .unsafe = if (d) rgb(0.98, 0.75, 0.14) else rgb(0.71, 0.33, 0.04),
        .sunset = if (d) rgb(1.0, 0.604, 0.522) else rgb(0.788, 0.271, 0.184),
        .feather = if (d) rgb(0.522, 0.725, 0.318) else rgb(0.369, 0.604, 0.227),
    };
}

fn rgb(r: f32, g: f32, b: f32) ui.Color {
    return .{ .r = r, .g = g, .b = b };
}

/// `NSColor(white: v, alpha: 1)` in sRGB, as AppKit converts it.
pub fn white(v: f64) ui.Color {
    const gray = objc.msg(objc.Object, objc.class("NSColor"), "colorWithWhite:alpha:", .{ v, @as(f64, 1) });
    const srgb = objc.msg(objc.Object, objc.class("NSColorSpace"), "sRGBColorSpace", .{});
    const c = objc.msg(?objc.Object, gray, "colorUsingColorSpace:", .{srgb}) orelse
        return rgb(@floatCast(v), @floatCast(v), @floatCast(v));
    return rgb(
        @floatCast(objc.msg(f64, c, "redComponent", .{})),
        @floatCast(objc.msg(f64, c, "greenComponent", .{})),
        @floatCast(objc.msg(f64, c, "blueComponent", .{})),
    );
}

test "palette white 1.0 is 1.0 and 0.0 is 0.0" {
    const t = @import("std").testing;
    const one = white(1.0);
    const zero = white(0.0);
    try t.expectApproxEqAbs(@as(f32, 1), one.r, 1e-4);
    try t.expectApproxEqAbs(@as(f32, 1), one.b, 1e-4);
    try t.expectApproxEqAbs(@as(f32, 0), zero.r, 1e-4);
    try t.expectApproxEqAbs(@as(f32, 0), zero.g, 1e-4);
    // A grey stays grey, and light and dark differ.
    const p = get(false);
    try t.expectApproxEqAbs(p.muted.r, p.muted.b, 1e-3);
    try t.expect(get(true).ground.r < p.ground.r);
}
