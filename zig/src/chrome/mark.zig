//! `Mark` (Icons.swift): what stands for a page when there is no room for
//! its title: the site's icon, or its letter in a faint square until then.
const ui = @import("nanoui").ui;
const objc = @import("nanoui").objc;
const Palette = @import("../design/palette.zig").Palette;

/// A site's icon (`Favicons.icon`): `key` names this picture of it (its
/// site and a serial), so it is decoded once and again when it changes.
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

/// `text.first.map { String($0).uppercased() } ?? "•"`: the first
/// character (a grapheme, as Swift's `Character`), capitalised as
/// `uppercased()` does it, on the frame's arena.
pub fn initial(c: *ui.Context, text: []const u8) []const u8 {
    if (text.len == 0) return "•";
    const pool = objc.Pool.push();
    defer pool.pop();
    const Range = extern struct { location: usize, length: usize };
    const s = objc.nsString(text);
    const r = objc.msg(Range, s, "rangeOfComposedCharacterSequenceAtIndex:", .{@as(usize, 0)});
    const first = objc.msg(objc.Object, s, "substringWithRange:", .{r});
    return c.print("{s}", .{objc.fromNSString(objc.msg(objc.Object, first, "uppercaseString", .{}))});
}
