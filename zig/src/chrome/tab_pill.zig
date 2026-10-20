//! `TabPill` (TabBar.swift 486-749): one tab in the strip — a pinned
//! square, a mark alone when too narrow for a title (compact), or its
//! title with the speaker and the cross. The live tab's grey is not the
//! pill's: the strip draws it once, sliding between tabs (tab_bar.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const ring = @import("ring.zig");
const mark = @import("mark.zig");
const tab_width = @import("tab_width.zig");
const pin_grid = @import("pin_grid.zig");
const tab_address = @import("tab_address.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// Its address (or name) being typed into it (`editing`).
pub fn editing(b: *const Browser, tab: *const Tab) bool {
    return b.editing_tab == tab.id;
}

/// Pinned and not being edited (`pinned`).
pub fn pinned(b: *const Browser, tab: *const Tab) bool {
    return tab.pin != null and !editing(b, tab);
}

/// Too narrow for a title: the mark alone, the title in the tooltip.
pub fn compact(b: *const Browser, tab: *const Tab, each: f32) bool {
    return !editing(b, tab) and !pinned(b, tab) and !tab_width.titled(each);
}

/// `span`: an edited tab is a field as wide as the strip allows, up to
/// 340; a pin a square; anything else its share.
pub fn span(b: *const Browser, tab: *const Tab, each: f32) f32 {
    if (editing(b, tab)) return @min(340, b.strip.room);
    return if (pinned(b, tab)) metrics.pin_width else each;
}

/// What the edited tab adds to the run (`total += min(340, room) − oldWidth`);
/// a pair's page grows from the pair's width.
pub fn growth(b: *Browser, each: f32) f32 {
    const t = b.tabById(b.editing_tab orelse return 0) orelse return 0;
    const was = if (b.splitFor(t) != null) tab_width.pairWidth(each) else if (t.pin != null) metrics.pin_width else each;
    return @min(340, b.strip.room) - was;
}

/// Where the strip puts the pill this frame.
pub const Place = struct {
    /// Drawn over the row rather than in it (a carried tab, a leaving one).
    absolute: bool = false,
    offset: ui.Point = .{},
    opacity: f32 = 1,
    scale: f32 = 1,
    arrived: bool = true,
    motion_blur: bool = false,
    /// Carried: the drop chip under it.
    chip: ?ui.Style = null,
};

pub const Options = struct {
    live: bool,
    each: f32,
    /// A neighbouring space's row passing by: drawn, never pressed.
    interactive: bool = true,
    place: Place = .{},
    /// Its width springing toward `span` (the strip's settle); `span` when null.
    width: ?f32 = null,
};

pub const Drawn = struct {
    it: ui.Interaction,
    /// The pill's box.
    index: u32,
    /// The cross was clicked.
    close: bool = false,
};

const no_press: ui.Interaction = .{ .id = 0, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };

/// The site's icon when the window wears icons (`prefs.glyph == .icons`).
fn icon(b: *Browser, tab: *const Tab) ?mark.Icon {
    if (b.prefs.glyph != .icons) return null;
    return b.kea.favicons.icon(tab.url());
}

pub fn pill(b: *Browser, c: *ui.Context, p: *const Palette, tab: *Tab, o: Options) Drawn {
    const is_pin = pinned(b, tab);
    const small = compact(b, tab, o.each);
    const edit = o.interactive and editing(b, tab);
    const w = o.width orelse span(b, tab, o.each);
    var style: ui.Style = .{
        .direction = .row,
        .width = px(w),
        .radius = 9,
        .align_items = .center,
        .absolute = o.place.absolute,
        .offset = o.place.offset,
        .opacity = o.place.opacity,
        .scale = o.place.scale,
        .scale_anchor = if (o.place.arrived) .{ .x = 0.5, .y = 0.5 } else .{ .x = 0, .y = 0.5 },
        .motion_blur = o.place.motion_blur,
        .control = o.interactive,
    };
    if (o.place.chip) |chip| {
        style.background = chip.background;
        style.shadow = chip.shadow;
    }
    if (is_pin) {
        style.padding = .xy(7, 6);
    } else if (small) {
        style.padding = .{ .top = 6, .bottom = 6 };
        style.justify = .center;
    } else {
        style.padding = .{ .left = 11, .right = if (edit) 11 else 7, .top = 6, .bottom = 6 };
        style.gap = 6;
    }
    const i = c.open(style, null);
    defer c.end();
    const it = if (o.interactive) c.interact(i, .{}) else no_press;
    const hovered = it.hovered and o.interactive;
    const id = c.node(i).id;
    const h = motion.quickTo(c, id, 0, if (hovered) 1 else 0);
    const lift = if (c.reduce_motion or !o.interactive) 0 else motion.liftTo(c, id, 6, if (hovered) 1 else 0);
    const press = if (c.reduce_motion or !o.interactive) 0 else motion.liftTo(c, id, 7, if (it.pressed) 1 else 0);
    c.node(i).style.scale *= 1 + 0.03 * lift - 0.05 * press;
    if (!o.live and o.place.chip == null and lift > 0.01) {
        c.node(i).style.shadow = .{ .color = p.ink.alpha(0.10 * lift), .blur = 10, .y = 2 };
    }
    if (o.interactive) {
        c.help(i, tab.label());
        c.addA11y(i, .tab, if (tab.label().len == 0) "New Tab" else tab.label(), if (o.live) "Selected" else "", o.live, true);
    }
    // The ground: hover's grey, a pin's faint one; the live grey is the strip's.
    if (!o.live and o.place.chip == null) {
        const rest: ?ui.Color = if (is_pin) p.wash.alpha(0.55) else null;
        c.node(i).style.background = if (rest) |r| r.mix(p.hover, h) else p.hover.alpha(h);
    }
    const base = p.muted.mix(p.ink.alpha(0.7), h);
    const lv = std.math.clamp(motion.liveTo(c, id, 2, if (o.live) 1 else 0), 0, 1);
    const colour = base.mix(p.ink, lv);
    var d: Drawn = .{ .it = it, .index = i };
    if (edit) {
        tab_address.field(b, c, p, tab);
        c.node(i).style.offset.x += tab_address.shake(b, c);
    } else if (is_pin) {
        squareContent(b, c, p, tab, colour);
    } else if (small) {
        d.close = compactContent(b, c, p, tab, o.live, it.hovered and o.interactive);
    } else {
        d.close = titledContent(b, c, p, tab, colour, it.id, it.hovered and o.interactive, o.interactive);
    }
    return d;
}

/// A pinned square: the letter being typed, the ring, the icon, or the letter.
fn squareContent(b: *Browser, c: *ui.Context, p: *const Palette, tab: *Tab, colour: ui.Color) void {
    _ = c.open(.{ .width = px(16), .height = px(16), .align_items = .center, .justify = .center }, null);
    defer c.end();
    if (b.editing_pin == tab.id) {
        pin_grid.pinField(b, c, p, tab);
    } else if (tab.loading) {
        ring.ring(c, 11);
    } else if (icon(b, tab)) |ic| {
        mark.mark(c, p, ic, tab.pin orelse "", 16, tab.asleep());
    } else {
        // A pin holding no page is still there and still yours.
        ui.text(c, tab.pin orelse "", .{ .size = 12, .weight = .medium, .color = colour.alpha(if (tab.asleep()) 0.45 else 1) });
    }
}

/// The mark alone; on the live tab under the pointer, the cross in its place.
fn compactContent(b: *Browser, c: *ui.Context, p: *const Palette, tab: *Tab, live: bool, hovered: bool) bool {
    _ = c.open(.{ .width = px(16), .height = px(16), .align_items = .center, .justify = .center }, null);
    defer c.end();
    const crossed = live and hovered;
    if (!crossed) {
        if (tab.loading) {
            ring.ring(c, 10);
        } else {
            var buf: [4]u8 = undefined;
            mark.mark(c, p, icon(b, tab), tab.monogram(&buf), 15, tab.asleep());
        }
    }
    if (!live) return false;
    // A cross on something this small would be what a click to pick the
    // tab lands on: only the live tab, already picked, wears one.
    _ = c.open(.{ .absolute = true, .offset = .{ .x = 0.5, .y = 0.5 } }, null);
    defer c.end();
    return controls.closeDisc(c, p, crossed, controls.close_zone_compact).clicked;
}

/// The title between its marks, the speaker, and the cross or the ring.
fn titledContent(b: *Browser, c: *ui.Context, p: *const Palette, tab: *Tab, colour: ui.Color, pill_id: u64, hovered: bool, interactive: bool) bool {
    if (b.prefs.glyph == .icons and !tab.isBlank()) {
        var buf: [4]u8 = undefined;
        mark.mark(c, p, icon(b, tab), tab.monogram(&buf), 15, false);
    }
    // Quiet, and only on the tabs that keep nothing.
    if (tab.shy) ui.icon(c, "eye.slash", .{ .size = 9, .color = colour.alpha(0.7) });
    // An extension recording from this page (RecordingIndicator), saying so.
    if (tab.recording) {
        const dot = c.open(.{}, null);
        c.help(dot, "Recording");
        ui.icon(c, "record.circle", .{ .size = 10, .color = colour.alpha(0.8) });
        c.end();
    }
    const speaker = !tab.loading and (tab.noisy or tab.muted);
    const f_t = motion.quickTo(c, pill_id, 5, if (hovered and !speaker and !tab.loading) 1 else 0);
    ui.text(c, tab.label(), .{ .size = 12.5, .color = colour, .truncate = true, .fade = if (f_t > 0.001) .{ .clear = 22 * f_t, .ramp = 14 * f_t } else null });
    _ = c.leaf(.{ .grow = 1, .min_width = 2 }, .none, null);

    // The speaker at the end on its own, one place in under the pointer.
    ui.row(c, .{ .align_items = .center });
    defer ui.end(c);
    if (speaker) {
        ui.row(c, .{ .offset = .{ .x = -18 * motion.quickTo(c, pill_id, 2, if (hovered and speaker) 1 else 0) } });
        if (controls.speaker(c, p, tab.muted).clicked and interactive) tab.toggleMute();
        ui.end(c);
    }
    // One slot doing two jobs: the cross under the pointer, the ring while
    // the page is still coming, never both.
    const slot = c.open(.{ .width = px(15), .height = px(15) }, null);
    defer c.end();
    const ring_o = motion.quickTo(c, pill_id, 4, if (tab.loading and !hovered) 1 else 0);
    if (ring_o > 0.001) {
        _ = c.open(.{ .absolute = true, .width = px(15), .height = px(15), .align_items = .center, .justify = .center, .opacity = ring_o }, null);
        ring.ring(c, 10);
        c.end();
    }
    _ = slot;
    return controls.closeDisc(c, p, hovered, controls.close_zone).clicked;
}
