//! `Mark` (Icons.swift): what stands for a page when there is no room for
//! its title: the site's icon, or its letter in a faint square until then.
const std = @import("std");
const ui = @import("nanoui").ui;
const objc = @import("nanoui").objc;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");

pub const Mono = enum { none, dark, light };

/// A site's icon (`Favicons.icon`): `key` names this picture of it (its
/// site and a serial), so it is decoded once and again when it changes.
pub const Icon = struct { key: []const u8, png: []const u8, mono: Mono = .none };

const LastIcon = struct {
    id: u64 = 0,
    key_buf: [64]u8 = undefined,
    key_len: u8 = 0,
    mono: Mono = .none,
};
var last_icons: [64]LastIcon = @splat(.{});

fn resolveMono(ic: Icon) Mono {
    if (ic.mono != .none) return ic.mono;
    if (std.mem.endsWith(u8, ic.key, "@d")) return .dark;
    if (std.mem.endsWith(u8, ic.key, "@l")) return .light;
    return .none;
}

fn tintFor(p: *const Palette, dark: bool, mono: Mono) ?ui.Color {
    if ((mono == .dark and dark) or (mono == .light and !dark)) return p.ink;
    return null;
}

pub fn mark(c: *ui.Context, p: *const Palette, icon: ?Icon, letter: []const u8, size: f32, dim: bool) void {
    const opacity: f32 = if (dim) 0.45 else 1;
    const radius = size * 0.22;
    const id = c.peekId(null);
    const t = motion.quickTo(c, id, 0x6d61_726b, if (icon != null) 1 else 0);
    const bounce_v = motion.bounceTo(c, id, 0x6d61_7262, if (icon != null) 1 else 0);
    const slot = &last_icons[@intCast(id % last_icons.len)];
    if (icon) |ic| {
        const mono = resolveMono(ic);
        const tint = tintFor(p, c.theme.dark, mono);
        var key_buf: [64]u8 = undefined;
        const key = if (ic.key.len <= key_buf.len) blk: {
            @memcpy(key_buf[0..ic.key.len], ic.key);
            slot.* = .{ .id = id, .key_buf = key_buf, .key_len = @intCast(ic.key.len), .mono = mono };
            break :blk key_buf[0..ic.key.len];
        } else ic.key;
        if (t >= 0.999 and @abs(bounce_v - 1) <= 0.001) {
            // Scale ½: any icon of at least half the size's pixels fills it.
            if (ui.image(c, .{ .key = key, .bytes = ic.png, .max_width = size, .max_height = size, .radius = radius, .opacity = opacity, .scale = 0.5, .tint = tint })) return;
        } else {
            _ = c.open(.{ .width = .{ .px = size }, .height = .{ .px = size } }, null);
            defer c.end();
            if (t < 0.999) drawMonogram(c, p, letter, size, radius, opacity * (1 - t));
            _ = c.open(.{ .absolute = true, .width = .{ .px = size }, .height = .{ .px = size }, .scale = 0.6 + 0.4 * bounce_v }, null);
            _ = ui.image(c, .{ .key = key, .bytes = ic.png, .max_width = size, .max_height = size, .radius = radius, .opacity = opacity * t, .scale = 0.5, .tint = tint });
            c.end();
            return;
        }
    } else if (t > 0.001) {
        _ = c.open(.{ .width = .{ .px = size }, .height = .{ .px = size } }, null);
        defer c.end();
        drawMonogram(c, p, letter, size, radius, opacity * (1 - t));
        if (slot.id == id and slot.key_len > 0) {
            const tint = tintFor(p, c.theme.dark, slot.mono);
            _ = c.open(.{ .absolute = true, .width = .{ .px = size }, .height = .{ .px = size }, .scale = 0.6 + 0.4 * bounce_v }, null);
            _ = ui.image(c, .{ .key = slot.key_buf[0..slot.key_len], .bytes = "", .max_width = size, .max_height = size, .radius = radius, .opacity = opacity * t, .scale = 0.5, .tint = tint });
            c.end();
        }
        return;
    }
    drawMonogram(c, p, letter, size, radius, opacity);
}

fn drawMonogram(c: *ui.Context, p: *const Palette, letter: []const u8, size: f32, radius: f32, opacity: f32) void {
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
    if (text[0] < 0x80) {
        const ch = std.ascii.toUpper(text[0]);
        const out = c.alloc().alloc(u8, 1) catch return "•";
        out[0] = ch;
        return out;
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const Range = extern struct { location: usize, length: usize };
    const s = objc.nsString(text);
    const r = objc.msg(Range, s, "rangeOfComposedCharacterSequenceAtIndex:", .{@as(usize, 0)});
    const first = objc.msg(objc.Object, s, "substringWithRange:", .{r});
    return c.print("{s}", .{objc.fromNSString(objc.msg(objc.Object, first, "uppercaseString", .{}))});
}

pub fn initialBuf(buf: *[4]u8, text: []const u8) []const u8 {
    if (text.len == 0) return "•";
    if (text[0] < 0x80) {
        buf[0] = std.ascii.toUpper(text[0]);
        return buf[0..1];
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const Range = extern struct { location: usize, length: usize };
    const s = objc.nsString(text);
    const r = objc.msg(Range, s, "rangeOfComposedCharacterSequenceAtIndex:", .{@as(usize, 0)});
    const first = objc.msg(objc.Object, s, "substringWithRange:", .{r});
    const upper = objc.fromNSString(objc.msg(objc.Object, first, "uppercaseString", .{}));
    if (upper.len == 0 or upper.len > buf.len) return "•";
    @memcpy(buf[0..upper.len], upper);
    return buf[0..upper.len];
}
