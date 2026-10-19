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

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// Pinned and not being edited (`pinned`).
pub fn pinned(tab: *const Tab) bool {
    return tab.pin != null;
}

/// Too narrow for a title: the mark alone, the title in the tooltip.
pub fn compact(tab: *const Tab, each: f32) bool {
    return !pinned(tab) and !tab_width.titled(each);
}

/// `span`: a square for a pin, its share for anything else.
pub fn span(tab: *const Tab, each: f32) f32 {
    return if (pinned(tab)) metrics.pin_width else each;
}

/// Where the strip puts the pill this frame.
pub const Place = struct {
    /// Drawn over the row rather than in it (a carried tab, a leaving one).
    absolute: bool = false,
    offset: ui.Point = .{},
    opacity: f32 = 1,
    scale: f32 = 1,
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
    const is_pin = pinned(tab);
    const small = compact(tab, o.each);
    const w = o.width orelse span(tab, o.each);
    var style: ui.Style = .{
        .direction = .row,
        .width = px(w),
        .radius = 9,
        .align_items = .center,
        .absolute = o.place.absolute,
        .offset = o.place.offset,
        .opacity = o.place.opacity,
        .scale = o.place.scale,
        .scale_anchor = .{ .x = 0, .y = 0.5 },
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
        style.padding = .{ .left = 11, .right = 7, .top = 6, .bottom = 6 };
        style.gap = 6;
    }
    const i = c.open(style, null);
    defer c.end();
    const it = if (o.interactive) c.interact(i, .{}) else no_press;
    const h = motion.quickTo(c, c.node(i).id, 0, if (it.hovered) 1 else 0);
    if (o.interactive) {
        c.help(i, tab.label());
        c.addA11y(i, .tab, if (tab.label().len == 0) "New Tab" else tab.label(), if (o.live) "Selected" else "", o.live, true);
    }
    // The ground: hover's grey, a pin's faint one; the live grey is the strip's.
    if (!o.live and o.place.chip == null) {
        const rest: ?ui.Color = if (is_pin) p.wash.alpha(0.55) else null;
        c.node(i).style.background = if (rest) |r| r.mix(p.hover, h) else p.hover.alpha(h);
    }
    const colour = if (o.live) p.ink else p.muted.mix(p.ink.alpha(0.7), h);
    var d: Drawn = .{ .it = it, .index = i };
    if (is_pin) {
        squareContent(b, c, p, tab, colour);
    } else if (small) {
        d.close = compactContent(b, c, p, tab, o.live, it.hovered and o.interactive);
    } else {
        d.close = titledContent(b, c, p, tab, colour, it.hovered and o.interactive, o.interactive);
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
fn titledContent(b: *Browser, c: *ui.Context, p: *const Palette, tab: *Tab, colour: ui.Color, hovered: bool, interactive: bool) bool {
    if (b.prefs.glyph == .icons and !tab.isBlank()) {
        var buf: [4]u8 = undefined;
        mark.mark(c, p, icon(b, tab), tab.monogram(&buf), 15, false);
    }
    // Quiet, and only on the tabs that keep nothing.
    if (tab.shy) ui.icon(c, "eye.slash", .{ .size = 9, .color = colour.alpha(0.7) });
    // An extension recording from this page (RecordingIndicator).
    if (tab.recording) ui.icon(c, "record.circle", .{ .size = 10, .color = colour.alpha(0.8) });
    ui.text(c, tab.label(), .{ .size = 12.5, .color = colour, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 2 }, .none, null);

    // The speaker at the end on its own, one place in under the pointer.
    const speaker = !tab.loading and (tab.noisy or tab.muted);
    ui.row(c, .{ .align_items = .center });
    defer ui.end(c);
    if (speaker) {
        ui.row(c, .{ .padding = .{ .right = if (hovered) 8 else 0 } });
        if (controls.speaker(c, p, tab.muted).clicked and interactive) tab.toggleMute();
        ui.end(c);
    }
    // One slot doing two jobs: the cross under the pointer, the ring while
    // the page is still coming, never both.
    const slot = c.open(.{ .width = px(if (speaker and !hovered) 0 else 15), .height = px(15) }, null);
    defer c.end();
    if (tab.loading and !hovered) {
        _ = c.open(.{ .absolute = true, .width = px(15), .height = px(15), .align_items = .center, .justify = .center }, null);
        ring.ring(c, 10);
        c.end();
    }
    _ = slot;
    return controls.closeDisc(c, p, hovered, controls.close_zone).clicked;
}
