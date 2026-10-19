//! A peek at a link (Peek.swift): shift-click it and its page opens in a
//! panel over the one you are reading. Escape, a click beside the panel or
//! its cross puts it away; its other button keeps it, as a tab beside this
//! one, loaded as it is. The page is a tab of its own, only not in the row.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");

fn px(n: f32) ui.Length {
    return .{ .px = n };
}

/// The layer's own state across frames: shown last frame, and which
/// arrival this is (each springs in afresh).
pub const State = struct { shown: bool = false, gen: u32 = 0 };

/// Shift-click on a link, from a tab in the row.
pub fn peek(b: *Browser, url: []const u8, from: *Tab) void {
    if (b.peek_tab != null) return;
    b.peek_tab = b.make(url, from.shy);
    b.redraw();
}

/// Put away: the page goes with the panel.
pub fn closePeek(b: *Browser) void {
    const page = b.peek_tab orelse return;
    b.peek_tab = null;
    b.letGo(page);
    b.redraw();
}

/// Kept: a tab beside the one it was opened from, and in front. With
/// Split View on, `beside` keeps it in a pair with that page instead.
pub fn keepPeek(b: *Browser, beside: bool) void {
    const page = b.peek_tab orelse return;
    const from = b.tabById(b.active_id);
    const place = b.placeForNew();
    // Kept from a grouped tab, it joins that group, as a link opened from there does.
    if (b.prefs.uses_tab_groups and !page.shy) if (from) |f| {
        page.group_id = f.group_id;
    };
    b.peek_tab = null;
    // Off the peek's place before a pane takes it.
    if (b.stage_host) |sh| sh.setPeek(null);
    b.insert(page, place);
    if (beside and b.prefs.split_view) if (from) |f| if (b.canSplit(page, f)) return b.pair(page, f, false);
    b.select(page);
}

/// `PeekLayer` over `area`, the page's room (the column, strip and bar
/// stay uncovered): the page dimmed around the panel, and the panel —
/// 82 % by 86 % of it, centred, 21 points right, its knobs beside it.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, area: ui.Rect) void {
    const page = b.peek_tab;
    if (b.stage_host) |sh| sh.setPeek(if (page) |t| if (t.floating) null else t.web else null);
    const st = &b.peek_ui;
    const arrived = arrival(c, st, page != null);
    st.shown = page != null;
    const v = arrived orelse return;
    const fw = area.w * 0.82;
    const fh = area.h * 0.86;
    const fx = area.x + (area.w - fw) / 2 + 21;
    const fy = area.y + (area.h - fh) / 2;
    const hole: ui.Rect = .{ .x = fx, .y = fy, .w = @max(0, fw - 10 - 28), .h = fh };
    const opacity = std.math.clamp(v, 0, 1);

    ui.key(c, "kea.peek");
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .opacity = opacity });
    defer ui.end(c);
    // The dimming, around the page so none of it falls on the page: a
    // click on it puts the peek away.
    const dim = ui.Color.black.alpha(0.22);
    const pieces = [_]ui.Rect{
        .{ .x = area.x, .y = area.y, .w = area.w, .h = hole.y - area.y },
        .{ .x = area.x, .y = hole.y + hole.h, .w = area.w, .h = area.y + area.h - hole.y - hole.h },
        .{ .x = area.x, .y = hole.y, .w = hole.x - area.x, .h = hole.h },
        .{ .x = hole.x + hole.w, .y = hole.y, .w = area.x + area.w - hole.x - hole.w, .h = hole.h },
    };
    var close = false;
    for (pieces, 0..) |r, n| {
        ui.key(c, c.print("dim-{d}", .{n}));
        const i = c.leaf(.{ .absolute = true, .offset = .{ .x = r.x, .y = r.y }, .width = px(@max(0, r.w)), .height = px(@max(0, r.h)), .background = dim }, .none, null);
        const it = c.interact(i, .{});
        if (it.clicked) close = true;
    }
    // The panel arrives at .98 and grows to size.
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .scale = 0.98 + 0.02 * v, .scale_anchor = .{ .x = (fx + fw / 2) / @max(1, c.size.w), .y = (fy + fh / 2) / @max(1, c.size.h) } });
    defer ui.end(c);
    var shadow = card.swiftShadow(0.25, 30, 10);
    shadow.knockout = true;
    const box = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = hole.x, .y = hole.y },
        .width = px(hole.w),
        .height = px(hole.h),
        .radius = 12,
        .border = p.hairline,
        .shadow = shadow,
        // Leaving, the page is gone already: its ground goes with the panel.
        .background = if (page == null) p.ground else null,
    }, .none, "page");
    if (page != null) c.addStageHoleNode(box);
    ui.column(c, .{ .absolute = true, .offset = .{ .x = fx + fw - 28, .y = fy }, .gap = 8 });
    defer ui.end(c);
    if (knob(c, p, "xmark", "Close (esc)")) close = true;
    // ⌥ on it keeps the page beside this one, with Split View on, as the button under it does.
    if (knob(c, p, "arrow.up.left.and.arrow.down.right", "Open as a tab (⌘↩)")) return keepPeek(b, c.input.alt);
    if (b.prefs.split_view and knob(c, p, "rectangle.split.2x1", "Keep beside this page (⌥⌘↩)")) return keepPeek(b, true);
    if (close) closePeek(b);
}

/// Springing in on `settle`, easing out on `quick`; null once gone.
fn arrival(c: *ui.Context, st: *State, showing: bool) ?f32 {
    const id = c.peekId("kea.peek");
    if (showing and !st.shown) st.gen +%= 1;
    const salt = st.gen *% 2;
    if (showing) {
        _ = ui.tween(c, id, salt +% 1, 1, 0, .linear);
        return ui.springFrom(c, id, salt, 0, 1, motion.settle);
    }
    const v = ui.tween(c, id, salt +% 1, 0, motion.quick_duration, motion.quick_curve);
    return if (v <= 0) null else v;
}

/// `Knob`: a 28-point disc holding one symbol.
fn knob(c: *ui.Context, p: *const Palette, symbol: []const u8, help: []const u8) bool {
    const i = c.open(.{ .width = px(28), .height = px(28), .radius = 14, .border = p.hairline, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, help);
    c.addA11y(i, .button, help, "", false, true);
    c.node(i).style.background = if (it.hovered) p.hover else p.ground;
    ui.icon(c, symbol, .{ .size = 11, .weight = .semibold, .color = p.ink });
    return it.clicked;
}
