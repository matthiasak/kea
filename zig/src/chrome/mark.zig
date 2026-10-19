//! `Mark` (Icons.swift): what stands for a page when there is no room for
//! its title: the site's icon, or its letter in a faint square until then.
const ui = @import("nanoui").ui;
const Palette = @import("../design/palette.zig").Palette;

/// A site's icon: `key` names it (its host) so it is decoded once.
pub const Icon = struct { key: []const u8, png: []const u8 };

pub fn mark(c: *ui.Context, p: *const Palette, icon: ?Icon, letter: []const u8, size: f32, dim: bool) void {
    const opacity: f32 = if (dim) 0.45 else 1;
    const radius = size * 0.22;
    if (icon) |ic| {
        // Scale ½: any icon of at least half the size's pixels fills it.
        if (ui.image(c, .{ .key = ic.key, .bytes = ic.png, .max_width = size, .max_height = size, .radius = radius, .opacity = opacity, .scale = 0.5 })) return;
    }
    _ = c.open(.{
        .width = .{ .px = size },
        .height = .{ .px = size },
        .radius = radius,
        .background = p.ink.alpha(0.06),
        .opacity = opacity,
        .align_items = .center,
        .justify = .center,
    }, null);
    defer c.end();
    ui.text(c, letter, .{ .size = size * 0.56, .weight = .medium, .color = p.muted });
}
