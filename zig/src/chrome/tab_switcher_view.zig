//! `TabSwitcherOverlay` (TabSwitcher.swift:208-347): over the whole
//! window, a faint dim and the panel of cards, five to a row, the pick
//! under a highlight that glides. Its keys and clicks are the key
//! monitor's (app/keys.zig), from where it last drew its panel and cards.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const mark = @import("mark.zig");
const sw = @import("tab_switcher.zig");
const controls = @import("controls.zig");
const is_ios = @import("builtin").os.tag == .ios;

fn px(n: f32) ui.Length {
    return .{ .px = n };
}

/// The cards' size for `count` tabs in a window `window_w` wide.
pub const Layout = struct { columns: usize, width: f32, preview: f32, height: f32 };

fn maxCols(window_w: f32) usize {
    if (!is_ios) return 5;
    if (window_w > 0 and window_w < 600) return 2;
    if (window_w > 0 and window_w < 900) return 3;
    return 5;
}

pub fn layout(window_w: f32, count: usize) Layout {
    const cols = maxCols(window_w);
    const columns = @min(cols, count);
    const n: f32 = @floatFromInt(@max(columns, 1));
    const margin: f32 = if (is_ios and window_w > 0 and window_w < 600) 40 else 64;
    const raw_w = (window_w - margin - (n - 1) * 8) / n;
    const width = @min(176, if (is_ios) @max(110, raw_w) else raw_w);
    const preview = (width - 16) * 0.62;
    return .{ .columns = columns, .width = width, .preview = preview, .height = preview + 39 };
}

/// When the switcher became visible on each browser (by `Browser` pointer),
/// so cards stagger in from `opened_at`.
var opened_at_map: std.AutoHashMapUnmanaged(usize, f64) = .empty;

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.switcher;
    if (s.reveal_asked) {
        s.reveal_asked = false;
        s.reveal_at = c.time + 0.15;
    }
    if (s.reveal_at) |at| {
        if (c.time >= at) sw.show(b) else c.frameIn(@floatCast(at - c.time));
    }
    if (!s.visible) {
        _ = opened_at_map.remove(@intFromPtr(b));
        return;
    }
    const opened_gop = opened_at_map.getOrPut(std.heap.c_allocator, @intFromPtr(b)) catch null;
    if (opened_gop) |gop| if (!gop.found_existing) {
        gop.value_ptr.* = c.time;
    };
    const opened_at = if (opened_gop) |gop| gop.value_ptr.* else c.time;
    // 120 ms after the pick settles, the pictures, one every 0.04 s.
    if (s.waited_for != s.selected) {
        s.waited_for = s.selected;
        s.capture_at = c.time + 0.12;
    }
    if (!s.previews_requested) {
        if (c.time >= s.capture_at) sw.capture(b, c.time) else c.frameIn(@floatCast(s.capture_at - c.time));
    }
    if (sw.pump(b, c.time)) |next| c.frameIn(@floatCast(next - c.time));

    const l = layout(c.size.w, s.candidates.items.len);
    var picked: ?u64 = null;
    var dismissed = false;
    ui.key(c, "kea.switcher");
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .align_items = .center, .justify = .center });
    const scrim = c.open(.{ .absolute = true, .width = .fill, .height = .fill, .background = ui.Color.black.alpha(0.12) }, "scrim");
    c.end();
    const out = c.interact(scrim, .{});
    // `.onTapGesture` / `Button`: on the mouse coming up, not going down.
    if (out.clicked) dismissed = true;

    const panel = c.open(.{ .direction = .column, .gap = 10, .padding = .all(12), .max_width = @max(260, c.size.w - 16), .max_height = @max(220, c.size.h - 32), .background = p.ground, .radius = 12, .border = p.hairline, .control = true }, "panel");
    // The pointer picks the card under it once it has moved: the panel
    // comes up wherever the pointer happens to be.
    const m = c.input.mouse;
    const stirred = m.x != s.pointer.x or m.y != s.pointer.y;
    s.pointer = m;
    const held = c.interact(panel, .{});
    s.panel_frame = held.rect;
    s.card_count = 0;
    if (held.hovered and stirred and !s.moved) {
        if (s.rest) |r| {
            if (@abs(m.x - r.x) + @abs(m.y - r.y) > 2) s.moved = true;
        } else s.rest = m;
    }
    const pointing = stirred and s.moved;

    const cols = maxCols(c.size.w);
    var closed_tab: ?u64 = null;
    _ = c.open(.{ .direction = .column, .gap = 8, .scroll = true, .max_height = @max(160, c.size.h - (if (is_ios) @as(f32, 120) else @as(f32, 64))) }, "grid");
    if (s.selected) |sel| if (std.mem.indexOfScalar(u64, s.candidates.items, sel)) |index| {
        const id = c.peekId("highlight");
        const x = motion.liveTo(c, id, 0, @as(f32, @floatFromInt(index % cols)) * (l.width + 8));
        const y = motion.liveTo(c, id, 1, @as(f32, @floatFromInt(index / cols)) * (l.height + 8));
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = px(l.width), .height = px(l.height), .radius = 8, .background = p.faint, .motion_blur = true }, .none, "highlight");
    };
    var row: usize = 0;
    while (row * cols < s.candidates.items.len) : (row += 1) {
        ui.key(c, c.print("row-{d}", .{row}));
        ui.row(c, .{ .gap = 8 });
        const end = @min(row * cols + cols, s.candidates.items.len);
        for (s.candidates.items[row * cols .. end], row * cols..) |id, card_idx| if (b.tabById(id)) |t| {
            ui.row(c, .{});
            const it = card(b, c, p, t, l, card_idx, opened_at);
            if (is_ios) {
                const x_btn = c.open(.{ .absolute = true, .offset = .{ .x = l.width - 30, .y = 2 }, .width = px(28), .height = px(28), .radius = 14, .background = p.ground.alpha(0.85), .align_items = .center, .justify = .center, .control = true }, null);
                const x_it = c.interact(x_btn, .{});
                c.addA11y(x_btn, .button, "Close tab", "", false, true);
                ui.icon(c, "xmark", .{ .size = 10, .weight = .semibold, .color = p.muted });
                c.end();
                if (x_it.clicked) closed_tab = t.id;
            }
            ui.end(c);
            if (it.rect) |r| if (s.card_count < s.cards.len) {
                s.cards[s.card_count] = .{ .id = t.id, .rect = r };
                s.card_count += 1;
            };
            if (it.clicked and closed_tab != t.id) picked = t.id;
            if (it.hovered and pointing) s.selected = t.id;
        };
        ui.end(c);
    }
    c.end();
    var new_tab = false;
    var new_private = false;
    if (is_ios) {
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        if (controls.pill(c, p, "+ New Tab", .{ .filled = true }).clicked) new_tab = true;
        if (controls.pill(c, p, "Private", .{}).clicked) new_private = true;
        ui.spacer(c);
        if (controls.pill(c, p, "Done", .{}).clicked) dismissed = true;
        ui.end(c);
    }
    c.end();
    ui.end(c);
    if (closed_tab) |cid| {
        s.selected = cid;
        return sw.closeSelected(b);
    }
    if (new_tab) {
        sw.cancel(b);
        return b.newTab();
    }
    if (new_private) {
        sw.cancel(b);
        return b.newShyTab();
    }
    if (picked) |id| return sw.commitTabSwitch(b, id);
    if (dismissed) sw.cancel(b);
}

fn card(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, l: Layout, card_idx: usize, opened_at: f64) ui.Interaction {
    const s = &b.switcher;
    const partner = if (s.partnerOf(t.id)) |id| b.tabById(id) else null;
    const caption = if (partner) |q| c.print("{s} · {s}", .{ t.label(), q.label() }) else t.label();
    const side = if (partner == null) l.width - 16 else (l.width - 18) / 2;
    ui.key(c, c.print("card-{d}", .{t.id}));
    const delay = 0.022 * @as(f64, @floatFromInt(card_idx));
    const due = c.reduce_motion or (c.time - opened_at >= delay);
    if (!due) c.frameIn(@floatCast(delay - (c.time - opened_at)));
    const cid = c.peekId(null);
    const v = ui.springFrom(c, cid, 0, if (c.reduce_motion) 1 else 0, if (due) 1 else 0, motion.bounce);
    const i = c.open(.{
        .width = px(l.width),
        .height = px(l.height),
        .radius = 8,
        .control = true,
    }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const selected = s.selected == t.id;
    c.addA11y(i, .button, c.print("Switch to {s}", .{t.label()}), if (selected) "Selected" else "", selected, true);
    _ = c.open(.{
        .width = .fill,
        .height = .fill,
        .padding = .all(8),
        .gap = 7,
        .scale = 0.86 + 0.14 * v,
        .offset = .{ .y = 10 * (1 - v) },
        .opacity = std.math.clamp(v, 0, 1),
    }, null);
    defer c.end();
    // A pair: its two pages side by side, as on screen.
    ui.row(c, .{ .width = px(l.width - 16), .height = px(l.preview), .gap = 2, .radius = 5, .clip = true });
    picture(b, c, p, t, side, l.preview);
    if (partner) |q| picture(b, c, p, q, side, l.preview);
    ui.end(c);
    ui.row(c, .{ .gap = 6, .width = .fill, .align_items = .center });
    if (b.prefs.glyph != .letters and !t.isBlank()) {
        var buf: [4]u8 = undefined;
        mark.mark(c, p, b.kea.favicons.icon(t.url()), t.monogram(&buf), 13, false);
    }
    ui.text(c, caption, .{ .size = 11.5, .color = p.ink, .truncate = .ellipsis });
    ui.end(c);
    return it;
}

/// The page's picture, filling its place; its mark until there is one.
fn picture(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, w: f32, h: f32) void {
    _ = c.open(.{ .width = px(w), .height = px(h), .background = p.hover, .clip = true, .align_items = .center, .justify = .center }, null);
    defer c.end();
    if (b.switcher.preview(t.id, t.address)) |pv| {
        // Points a pixel, as `scaledToFill`.
        const k = @max(w / pv.w, h / pv.h);
        ui.column(c, .{ .absolute = true, .offset = .{ .x = (w - pv.w * k) / 2, .y = (h - pv.h * k) / 2 } });
        defer ui.end(c);
        _ = ui.image(c, .{ .key = c.print("kea.switcher.{d}.{d}", .{ t.id, pv.serial }), .bytes = pv.png, .max_width = 1e5, .max_height = 1e5, .radius = 0, .scale = 1 / k });
        return;
    }
    var buf: [4]u8 = undefined;
    mark.mark(c, p, if (b.prefs.glyph != .letters) b.kea.favicons.icon(t.url()) else null, t.monogram(&buf), 26, false);
}
