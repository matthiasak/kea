//! Kea's small controls, as Swift draws them: `Door`, `Quiet`, `Speaker`
//! (Side.swift), `Pill`, `Switch`, `Segmented`, `Steps` (Settings.swift),
//! the site offer's `KeyCap` (Omnibox.swift), the tab's close disc
//! (TabBar.swift) and `Shake` (Design.swift). Each takes the palette and
//! returns what the pointer did; colours come from the palette only.
const std = @import("std");
const ui = @import("nanoui").ui;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// A capsule's radius: nanoui clamps it to half the shorter side.
pub const capsule: f32 = 999;

/// The pointer resting on `it`, eased in and out with `Motion.quick`.
fn hover(c: *ui.Context, it: ui.Interaction, salt: u32) f32 {
    return motion.quickTo(c, it.id, salt, if (it.hovered) 1 else 0);
}

pub const DoorOptions = struct {
    /// Lit: what it opens is open.
    on: bool = false,
    /// The tooltip; its part before three spaces is the spoken label.
    help: []const u8 = "",
};

/// `Door`: a 26-point square holding one symbol, lit when what it opens is.
pub fn door(c: *ui.Context, p: *const Palette, icon: []const u8, opts: DoorOptions) ui.Interaction {
    const i = c.open(.{ .width = px(26), .height = px(26), .radius = 8, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    if (opts.help.len > 0) c.help(i, opts.help);
    const said = if (std.mem.indexOf(u8, opts.help, "   ")) |at| opts.help[0..at] else opts.help;
    c.addA11y(i, .button, said, "", opts.on, true);
    const h = hover(c, it, 0);
    const o = motion.quickTo(c, it.id, 1, if (opts.on) 1 else 0);
    c.node(i).style.background = p.side_hover.alpha(h).mix(p.side_wash, o);
    ui.icon(c, icon, .{ .size = 11, .weight = .medium, .color = p.muted.mix(p.ink.alpha(0.7), h).mix(p.ink, o) });
    return it;
}

/// `Quiet`: a row that says what it does softly (the column's New Tab).
pub fn quiet(c: *ui.Context, p: *const Palette, icon: []const u8, title: []const u8, height: f32) ui.Interaction {
    const i = c.open(.{ .direction = .row, .gap = 8, .padding = .{ .left = 10 }, .width = .fill, .height = px(height), .align_items = .center, .radius = 9, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, title, "", false, true);
    const h = hover(c, it, 0);
    c.node(i).style.background = p.side_hover.alpha(h);
    const ink = p.faint.mix(p.ink.alpha(0.7), h);
    ui.icon(c, icon, .{ .size = 10, .weight = .medium, .frame = 15, .color = ink });
    ui.text(c, title, .{ .size = 12.5, .color = ink, .truncate = true });
    return it;
}

/// `Speaker`: the sound of a tab, pressed to mute it or let it be heard.
pub fn speaker(c: *ui.Context, p: *const Palette, muted: bool) ui.Interaction {
    const i = c.open(.{ .width = px(15), .height = px(15), .radius = 7.5, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const say = if (muted) "Unmute Tab" else "Mute Tab";
    c.help(i, say);
    c.addA11y(i, .button, say, "", false, true);
    c.node(i).style.background = p.ink.alpha(0.07 * hover(c, it, 0));
    ui.icon(c, if (muted) "speaker.slash.fill" else "speaker.wave.2.fill", .{ .size = 8, .color = p.muted });
    return it;
}

pub const PillOptions = struct {
    /// The thing you came here to press: sunset, with ground text.
    filled: bool = false,
    /// The title's colour when outlined (ink when null).
    tint: ?ui.Color = null,
};

/// `Pill`: a small capsule that does one thing.
pub fn pill(c: *ui.Context, p: *const Palette, title: []const u8, opts: PillOptions) ui.Interaction {
    const i = c.open(.{ .padding = .xy(10, 5), .radius = capsule, .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, title, "", false, true);
    const h = hover(c, it, 0);
    const s = &c.node(i).style;
    s.background = if (opts.filled) p.sunset else p.ground.mix(p.hover, h);
    s.border = if (opts.filled) null else p.hairline;
    ui.text(c, title, .{ .size = 11.5, .color = if (opts.filled) p.ground else opts.tint orelse p.ink });
    return it;
}

/// `Switch`: on or off, in feather rather than blue; true when flipped.
pub fn switch_(c: *ui.Context, p: *const Palette, on: *bool, label: []const u8) bool {
    const i = c.open(.{ .width = px(30), .height = px(18), .radius = capsule, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .switch_toggle, label, "", on.*, true);
    if (it.clicked) {
        on.* = !on.*;
        c.changed = true;
    }
    const t = motion.settleTo(c, it.id, 0, if (on.*) 1 else 0);
    c.node(i).style.background = p.faint.mix(p.feather, std.math.clamp(t, 0, 1));
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = 2 + 12 * t, .y = 2 },
        .width = px(14),
        .height = px(14),
        .radius = 7,
        .background = p.ground,
        .shadow = card.swiftShadow(0.18, 1.5, 1),
    }, .none, null);
    return it.clicked;
}

/// `Segmented`: one choice of `options`, the chosen one on a ground chip
/// that settles across to it; `wide` shares the width evenly. True when
/// the choice changes.
pub fn segmented(c: *ui.Context, p: *const Palette, options: []const []const u8, selected: *usize, wide: bool) bool {
    const outer = c.open(.{ .direction = .row, .gap = 2, .padding = .all(2), .radius = 9, .background = p.wash, .width = if (wide) .fill else .auto }, null);
    defer c.end();
    const outer_id = c.node(outer).id;
    // The chip, under the choices, placed once they are.
    const chip = c.leaf(.{ .absolute = true, .radius = 7, .background = p.ground, .shadow = card.swiftShadow(0.08, 3, 1), .opacity = 0 }, .none, null);
    var chosen_id: u64 = 0;
    var chosen_index: u32 = 0;
    var changed = false;
    for (options, 0..) |title, n| {
        const i = c.open(.{ .padding = .xy(if (wide) 4 else 10, 5), .grow = if (wide) 1 else 0, .radius = 7, .align_items = .center, .control = true }, null);
        defer c.end();
        const it = c.interact(i, .{});
        if (it.clicked and selected.* != n) {
            selected.* = n;
            changed = true;
            c.changed = true;
        }
        const on = selected.* == n;
        c.addA11y(i, .radio_button, title, "", on, true);
        if (on) {
            chosen_id = it.id;
            chosen_index = i;
        }
        ui.text(c, title, .{ .size = 11.5, .weight = if (on) .medium else .regular, .color = if (on) p.ink else p.muted, .truncate = wide });
    }
    if (chosen_id == 0) return changed;
    const box = c.rects.get(outer_id);
    const at = c.rects.get(chosen_id);
    if (box == null or at == null) {
        // Not laid out yet: the choice wears the chip itself.
        const s = &c.node(chosen_index).style;
        s.background = p.ground;
        s.shadow = card.swiftShadow(0.08, 3, 1);
        return changed;
    }
    const s = &c.node(chip).style;
    s.opacity = 1;
    s.offset = .{ .x = motion.settleTo(c, outer_id, 0, at.?.x - box.?.x - 2), .y = at.?.y - box.?.y - 2 };
    s.width = px(motion.settleTo(c, outer_id, 1, at.?.w));
    s.height = px(at.?.h);
    return changed;
}

/// `Steps`: a value moved one stop at a time, − and + either side of it;
/// pressing the value takes it home. True when the value changes.
pub fn steps(c: *ui.Context, p: *const Palette, stops: []const f64, value: *f64, home: f64, label: *const fn (*ui.Context, f64) []const u8) bool {
    var below: ?f64 = null;
    var above: ?f64 = null;
    for (stops) |s| {
        if (s < value.* - 0.001) below = s;
        if (above == null and s > value.* + 0.001) above = s;
    }
    _ = c.open(.{ .direction = .row, .padding = .{ .left = 2, .right = 2 }, .height = px(24), .align_items = .center, .radius = capsule, .background = p.ground, .border = p.hairline }, null);
    defer c.end();
    var changed = step(c, p, "minus", "Remove", below, value);
    const i = c.open(.{ .min_width = 36, .height = .fill, .align_items = .center, .justify = .center, .control = true }, null);
    const it = c.interact(i, .{});
    c.help(i, c.print("Back to {s}", .{label(c, home)}));
    const now = label(c, value.*);
    c.addA11y(i, .button, now, "", false, true);
    if (it.clicked and value.* != home) {
        value.* = home;
        changed = true;
        c.changed = true;
    }
    ui.text(c, now, .{ .size = 11.5, .color = p.ink });
    c.end();
    if (step(c, p, "plus", "Add", above, value)) changed = true;
    return changed;
}

fn step(c: *ui.Context, p: *const Palette, icon: []const u8, say: []const u8, to: ?f64, value: *f64) bool {
    const i = c.open(.{ .width = px(20), .height = px(20), .radius = 10, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    c.addA11y(i, .button, say, "", false, to != null);
    var h: f32 = 0;
    var moved = false;
    if (to) |v| {
        const it = c.interact(i, .{});
        h = hover(c, it, 0);
        if (it.clicked) {
            value.* = v;
            moved = true;
            c.changed = true;
        }
    }
    c.node(i).style.background = p.hover.alpha(h);
    ui.icon(c, icon, .{ .size = 9, .weight = .semibold, .color = if (to == null) p.faint else p.ink });
    return moved;
}

/// The site offer's key: "Tab" in a hairline outline.
pub fn keyCap(c: *ui.Context, p: *const Palette, label: []const u8) void {
    _ = c.open(.{ .padding = .{ .left = 6, .right = 6 }, .height = px(18), .radius = 5, .border = p.hairline, .align_items = .center, .justify = .center }, null);
    defer c.end();
    ui.text(c, label, .{ .size = 11, .weight = .medium, .color = p.muted });
}

const no_press: ui.Interaction = .{ .id = 0, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };

/// A tab's cross: a 15-point disc shown while `armed` (the tab hovered),
/// fading with `Motion.quick`. What is hit is `zone` around it (30×28 in
/// a titled tab, 22×22 in a compact one), and only while armed, by a
/// plain left click released over it (`CloseClick`).
pub const close_zone: ui.Size = .{ .w = 30, .h = 28 };
pub const close_zone_compact: ui.Size = .{ .w = 22, .h = 22 };

pub fn closeDisc(c: *ui.Context, p: *const Palette, armed: bool, zone_size: ui.Size) ui.Interaction {
    return closeDiscIcon(c, p, armed, zone_size, "xmark");
}

/// The same disc wearing `icon` (a pinned row's "minus": put down, not closed).
pub fn closeDiscIcon(c: *ui.Context, p: *const Palette, armed: bool, zone_size: ui.Size, icon: []const u8) ui.Interaction {
    const slot = c.open(.{ .width = px(15), .height = px(15) }, null);
    defer c.end();
    const o = motion.quickTo(c, c.node(slot).id, 0, if (armed) 1 else 0);
    _ = c.open(.{ .width = .fill, .height = .fill, .radius = 7.5, .background = p.ink.alpha(0.07), .opacity = o, .align_items = .center, .justify = .center }, null);
    ui.icon(c, icon, .{ .size = 8, .weight = .semibold, .color = p.muted });
    c.end();
    if (!armed) return no_press;
    const zone = c.open(.{ .absolute = true, .offset = .{ .x = (15 - zone_size.w) / 2, .y = (15 - zone_size.h) / 2 }, .width = px(zone_size.w), .height = px(zone_size.h), .control = true }, null);
    defer c.end();
    var it = c.interact(zone, .{});
    c.addA11y(zone, .button, "Close tab", "", false, true);
    const in = c.input;
    if (in.cmd or in.ctrl or in.alt or in.shift) it.clicked = false;
    return it;
}

/// `Shake`'s sideways travel at `t` (0…1): three there-and-backs, tapering.
pub fn shakeAt(t: f32) f32 {
    return @sin(t * std.math.pi * 6) * 7 * (1 - t);
}

/// The offset of `id` shaking: each new `generation` (a refusal) shakes
/// it once over 0.5 s, ease-out; nothing under Reduce Motion.
// ponytail: a refusal mid-shake carries on from where it is rather than restarting.
pub fn shake(c: *ui.Context, id: u64, generation: u32) f32 {
    const g: f32 = @floatFromInt(generation);
    const v = ui.tween(c, id, 0x5ea4e, g, 0.5, .ease_out);
    if (c.reduce_motion) return 0;
    return shakeAt(std.math.clamp(1 - (g - v), 0, 1));
}
