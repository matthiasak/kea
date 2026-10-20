//! `SplitTabItem` (SplitTabItem.swift): a pair's one place in the row.
//! Across the top its pages sit side by side with a single cross at the
//! end for the half under the pointer; in the column they are two lines,
//! one under the other, each with its own cross. The page with the keys
//! wears the column's grey; the whole item a hairline outline.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const mark = @import("mark.zig");
const ring = @import("ring.zig");
const tab_address = @import("tab_address.zig");
const tab_pill = @import("tab_pill.zig");
const tab_width = @import("tab_width.zig");
const split_drop = @import("split_drop.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

const no_press: ui.Interaction = .{ .id = 0, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };

/// What a half was asked: the tab, its own interaction, its cross.
pub const Hit = struct { tab: *Tab, it: ui.Interaction, close: bool = false };

pub const Drawn = struct {
    /// The item's box.
    index: u32,
    /// The half under the hand (for carrying the item), and the half a
    /// click, a cross or a menu was for.
    it: ui.Interaction,
    hit: ?Hit = null,
};

/// The pair whose first page is `tab`, its other page; null for any other
/// tab, or with Split View off.
pub fn partner(b: *Browser, tab: *const Tab) ?*Tab {
    const s = b.splitFor(tab) orelse return null;
    if (s.left() != tab.id) return null;
    return b.tabById(s.right());
}

/// Across the top: the item's width — the edited pair's field as wide as
/// the strip allows, up to 340.
pub fn span(b: *const Browser, left: *const Tab, right: *const Tab, each: f32) f32 {
    if (b.editing_tab == left.id or b.editing_tab == right.id) return @min(340, b.strip.room);
    return tab_width.pairWidth(each);
}

/// Across the top, `width` wide, placed as the strip says.
pub fn strip(b: *Browser, c: *ui.Context, p: *const Palette, left: *Tab, right: *Tab, width: f32, place: tab_pill.Place, interactive: bool) Drawn {
    const i = c.open(.{
        .direction = .row,
        .width = px(width),
        .height = px(40),
        .radius = 9,
        .border = p.hairline,
        .align_items = .center,
        .absolute = place.absolute,
        // Carried, it is drawn where a 28-high pill would be.
        .offset = .{ .x = place.offset.x, .y = place.offset.y - if (place.absolute) @as(f32, 6) else 0 },
        .opacity = place.opacity,
        .scale = place.scale,
        .scale_anchor = .{ .x = 0, .y = 0.5 },
        .background = if (place.chip) |chip| chip.background else null,
        .shadow = if (place.chip) |chip| chip.shadow else null,
    }, null);
    defer c.end();
    if (interactive) c.addA11y(i, .group, "Split tabs", "", false, true);
    const narrow = (width - 1) / 2 < 64;
    var d: Drawn = .{ .index = i, .it = no_press };
    var hovered: ?*Tab = null;
    for ([_]*Tab{ left, right }, 0..) |t, k| {
        if (k == 1) _ = c.leaf(.{ .width = px(1), .height = px(16), .background = p.hairline }, .none, null);
        const h = half(b, c, p, t, .{ .stacked = false, .narrow = narrow, .interactive = interactive, .height = 28 });
        if (h.hovering) hovered = t;
        take(&d, t, h);
    }
    // One cross, at the end, for whichever half the pointer is over.
    if (!interactive or b.editing_tab != null) return d;
    _ = c.open(.{ .absolute = true, .width = .fill, .height = .fill, .direction = .row, .justify = .end, .align_items = .center, .padding = .{ .right = 7 } }, null);
    defer c.end();
    // ponytail: no "Close the left/right page" tooltip; closeDisc keeps its zone's box to itself.
    const close = controls.closeDisc(c, p, hovered != null, controls.close_zone);
    if (close.clicked) if (hovered) |over| {
        d.hit = .{ .tab = over, .it = close, .close = true };
    };
    return d;
}

/// In the column: two lines, `height` each.
pub fn stacked(b: *Browser, c: *ui.Context, p: *const Palette, left: *Tab, right: *Tab, height: f32, interactive: bool) Drawn {
    const i = c.open(.{ .direction = .column, .width = .fill, .radius = 9, .border = p.hairline }, null);
    defer c.end();
    if (interactive) c.addA11y(i, .group, "Split tabs", "", false, true);
    var d: Drawn = .{ .index = i, .it = no_press };
    for ([_]*Tab{ left, right }) |t| take(&d, t, half(b, c, p, t, .{ .stacked = true, .narrow = false, .interactive = interactive, .height = height }));
    return d;
}

fn take(d: *Drawn, t: *Tab, h: HalfDrawn) void {
    if (h.it.hovered or h.it.pressed or d.it.id == 0) d.it = h.it;
    const asked = h.it.clicked or h.it.middle_clicked or h.it.right_clicked or h.close;
    if (asked) d.hit = .{ .tab = t, .it = h.it, .close = h.close };
}

const HalfOptions = struct { stacked: bool, narrow: bool, interactive: bool, height: f32 };
const HalfDrawn = struct { it: ui.Interaction, hovering: bool = false, close: bool = false };

/// `SplitTabHalf`: one page of the pair.
fn half(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, o: HalfOptions) HalfDrawn {
    const focused = t.id == b.active_id;
    const editing = o.interactive and b.editing_tab == t.id;
    const i = c.open(.{
        .direction = .row,
        .grow = 1,
        .width = if (o.stacked) .fill else .auto,
        .height = px(if (o.stacked) o.height else 28),
        .gap = if (o.stacked) 8 else 5,
        .padding = .{ .left = if (o.stacked) 10 else 9, .right = if (o.stacked) 7 else 4 },
        .radius = 9,
        .align_items = .center,
        .clip = true,
        .control = o.interactive,
    }, null);
    defer c.end();
    const it = if (o.interactive) c.interact(i, .{}) else no_press;
    // By where the pointer is: the item's one cross over a half is still that half's.
    const hovering = o.interactive and (if (it.rect) |r| r.contains(c.input.mouse) else false);
    const h = motion.quickTo(c, c.node(i).id, 0, if (hovering) 1 else 0);
    const title = if (t.label().len == 0) "New Tab" else t.label();
    if (o.interactive) {
        c.help(i, title);
        c.addA11y(i, .tab, title, if (focused) "Focused page" else "", focused, true);
        split_drop.mark(b, t.id, it.rect);
    }
    // The ground: the page with the keys wears the column's grey (in the
    // column, the sliding one); the pointer's, a lighter one.
    if (focused and o.stacked and o.interactive) b.column.live(it.id, p.side_wash, 9);
    const sliding = focused and o.stacked and o.interactive and b.column.pill_drawn;
    c.node(i).style.background = if (focused) (if (sliding) null else p.side_wash) else p.side_hover.alpha(h);
    if (focused and !o.narrow and b.prefs.shows_reading) {
        const fill = std.math.clamp(t.reading, 0, 1);
        const w = if (it.rect) |r| r.w else 0;
        _ = c.leaf(.{ .absolute = true, .width = px(w * fill), .height = .fill, .background = p.ink.alpha(0.055) }, .none, null);
    }
    if (editing) {
        tab_address.field(b, c, p, t);
        return .{ .it = it, .hovering = hovering };
    }
    const size: f32 = if (o.stacked) 15 else 13;
    if (b.prefs.glyph == .icons or o.narrow) {
        var buf: [4]u8 = undefined;
        const icon = if (b.kea.favicons.icon(t.url())) |ic| mark.Icon{ .key = ic.key, .png = ic.png } else null;
        mark.mark(c, p, icon, t.monogram(&buf), size, t.asleep());
    }
    if (t.shy) ui.icon(c, "eye.slash", .{ .size = 9, .color = p.muted });
    // The page is asking something, over its half of the stage.
    if (t.question() != null) _ = c.leaf(.{ .width = px(5), .height = px(5), .radius = 2.5, .background = p.muted }, .none, null);
    if (!o.narrow) ui.text(c, title, .{ .size = if (o.stacked) 12.5 else 12, .color = if (focused) p.ink else p.muted.mix(p.ink, h), .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
    const playing = !t.loading and (t.noisy or t.muted);
    if (playing) {
        ui.row(c, .{ .padding = .{ .right = if (o.stacked and hovering) 3 else 0 } });
        if (controls.speaker(c, p, t.muted).clicked and o.interactive) t.toggleMute();
        ui.end(c);
    } else if (t.loading and !(o.stacked and hovering)) {
        ui.row(c, .{ .padding = .{ .right = 3 } });
        ring.ring(c, 10);
        ui.end(c);
    }
    // In the column each line has its own cross at its own end.
    if (!(o.interactive and o.stacked)) return .{ .it = it, .hovering = hovering };
    const close = controls.closeDisc(c, p, hovering, .{ .w = 26, .h = o.height });
    return .{ .it = it, .hovering = hovering, .close = close.clicked };
}

// MARK: the strip's item, a pill or a pair

/// The width the strip gives `t`'s place: its pair's, or its pill's.
pub fn stripSpan(b: *Browser, t: *const Tab, each: f32) f32 {
    if (partner(b, t)) |right| return span(b, t, right, each);
    return tab_pill.span(b, t, each);
}

/// `t`'s place in the strip: its pill, or its pair's item. `drawn` is
/// the place (carried as one); `asked` the tab a click or a cross was for,
/// with what it was asked.
pub const Item = struct { drawn: tab_pill.Drawn, asked: *Tab, asked_drawn: tab_pill.Drawn };

pub fn stripItem(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, o: tab_pill.Options) Item {
    const right = partner(b, t) orelse {
        const d = tab_pill.pill(b, c, p, t, o);
        if (o.interactive) split_drop.mark(b, t.id, d.it.rect);
        return .{ .drawn = d, .asked = t, .asked_drawn = d };
    };
    const d = strip(b, c, p, t, right, o.width orelse stripSpan(b, t, o.each), o.place, o.interactive);
    const drawn: tab_pill.Drawn = .{ .it = d.it, .index = d.index };
    const hit = d.hit orelse return .{ .drawn = drawn, .asked = t, .asked_drawn = .{ .it = no_press, .index = d.index } };
    return .{ .drawn = drawn, .asked = hit.tab, .asked_drawn = .{ .it = hit.it, .index = d.index, .close = hit.close } };
}
