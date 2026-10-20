//! `FetchDoor` (Fetching.swift 607-674): the circle in the chrome, beside
//! the other doors — filling while files come, an arrow a moment once they
//! are in, an arrow in a circle at rest when Settings › Downloads keeps it
//! shown. A click opens Downloads.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const presence = @import("presence.zig");
const ring = @import("ring.zig");
const sheet = @import("sheet.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// Whether it is in the row (`FetchDoor.shows`).
pub fn shows(b: *Browser) bool {
    const f = &b.kea.fetches;
    return f.isShowing() or f.entries.items.len > 0 or b.prefs.always_shows_downloads;
}

/// The door, arriving at .6 scale and fading in, and going the same way.
/// `salt` keeps the strip's and the column's apart.
pub fn door(b: *Browser, c: *ui.Context, p: *const Palette, comptime salt: []const u8) void {
    const f = &b.kea.fetches;
    const shown = shows(b);
    const t = presence.presence(c, std.hash.Wyhash.hash(0, "kea.fetch-door." ++ salt), shown, motion.settle, null) orelse return;
    const showing = f.isShowing();
    const done = f.isDone();
    if (f.lingerLeft()) |left| c.frameIn(@floatCast(left + 0.01));
    const i = c.open(.{
        .width = px(26),
        .height = px(26),
        .radius = 8,
        .align_items = .center,
        .justify = .center,
        .control = true,
        .opacity = std.math.clamp(t, 0, 1),
        .scale = 0.6 + 0.4 * t,
    }, "fetch-door-" ++ salt);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, "Downloads (⇧⌘J)");
    c.addA11y(i, .button, "Downloads", "", false, true);
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = p.hover.alpha(h);
    ui.column(c, .{ .width = px(12), .height = px(12), .align_items = .center, .justify = .center });
    const a0 = motion.quickTo(c, it.id, 1, if (!showing) 1 else 0);
    const a1 = motion.quickTo(c, it.id, 2, if (showing and done) 1 else 0);
    const a2 = motion.quickTo(c, it.id, 3, if (showing and !done and f.fraction != null) 1 else 0);
    const a3 = motion.quickTo(c, it.id, 4, if (showing and !done and f.fraction == null) 1 else 0);
    if (a0 > 0.001) {
        ui.column(c, .{ .absolute = true, .width = px(12), .height = px(12), .align_items = .center, .justify = .center, .opacity = a0 });
        ui.icon(c, "arrow.down.circle", .{ .size = 12, .weight = .medium, .color = p.muted.mix(p.ink.alpha(0.7), h) });
        ui.end(c);
    }
    if (a1 > 0.001) {
        ui.column(c, .{ .absolute = true, .width = px(12), .height = px(12), .align_items = .center, .justify = .center, .opacity = a1 });
        ui.icon(c, "arrow.down", .{ .size = 10, .weight = .semibold, .color = p.ink.alpha(0.75) });
        ui.end(c);
    }
    if (a2 > 0.001) {
        ui.column(c, .{ .absolute = true, .width = px(12), .height = px(12), .align_items = .center, .justify = .center, .opacity = a2 });
        ring.progressArc(c, 12, @floatCast(f.fraction orelse 1));
        ui.end(c);
    }
    if (a3 > 0.001) {
        ui.column(c, .{ .absolute = true, .width = px(12), .height = px(12), .align_items = .center, .justify = .center, .opacity = a3 });
        ring.ring(c, 12);
        ui.end(c);
    }
    ui.end(c);
    if (it.clicked and shown) sheet.show(b, .hoarding);
}
