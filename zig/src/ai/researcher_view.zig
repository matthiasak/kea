//! Automatic Researcher Mode over a page (researcher.zig): a card at the
//! page's top right with each section explained — its heading a link back
//! into the page — or, minimized, a pill. Only the card takes the pointer
//! and the wheel; the page around it stays the page's.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const controls = @import("../chrome/controls.zig");
const presence = @import("../chrome/presence.zig");
const disclose = @import("../chrome/disclose.zig");
const motion = @import("../design/motion.zig");
const markdown_view = @import("markdown_view.zig");
const researcher = @import("researcher.zig");
const Entry = researcher.Entry;
const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// Over pane `at` showing `t`; below the find bar when it is open there.
/// It springs in and out at the top right, and its card and pill morph into each other there.
pub fn draw(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, at: ui.Rect, focused: bool) void {
    const e = researcher.entryFor(t) orelse return;
    if (e.restart) {
        e.restart = false;
        return researcher.runOn(b, t, true);
    }
    const id = std.hash.Wyhash.hash(t.serial, "kea.researcher");
    const shown = !e.dismissed and e.status != .checking;
    const v = std.math.clamp(presence.presence(c, id, shown, motion.settle, motion.settle) orelse return, 0, 1);
    const top = motion.glideTo(c, id, 0x746f70, if (focused and b.finder.finding) 54 else 12);
    const mc = std.math.clamp(motion.settleTo(c, id, 0x6d696e, if (e.minimized) 1 else 0), 0, 1);
    if (mc < 0.999) {
        layer(c, top, v, 1 - mc);
        defer ui.end(c);
        expanded(b, c, p, t, e, at, top, shown and !e.minimized);
    }
    if (mc > 0.001) {
        layer(c, top, v, mc);
        defer ui.end(c);
        pill(c, p, e, shown and e.minimized);
    }
}

/// The card's or the pill's box over the page, `v` of the way in and `k` of the morph toward it.
fn layer(c: *ui.Context, top: f32, v: f32, k: f32) void {
    ui.column(c, .{
        .absolute = true,
        .width = .fill,
        .align_items = .end,
        .padding = .{ .top = top, .right = 14 },
        .opacity = (0.02 + 0.98 * v) * k,
        .scale = (0.94 + 0.06 * v) * (0.9 + 0.1 * k),
        .scale_anchor = .{ .x = 1, .y = 0 },
        .offset = .{ .y = -(1 - v) * 10 },
        .group = true,
    });
}

/// `on`: the one shown, not leaving, takes the pointer.
fn pill(c: *ui.Context, p: *const Palette, e: *Entry, on: bool) void {
    const i = c.open(.{ .direction = .row, .gap = 4, .padding = .{ .left = 10, .right = 3, .top = 3, .bottom = 3 }, .radius = controls.capsule, .background = p.ground, .border = p.hairline, .shadow = card.swiftShadow(0.10, 14, 4), .align_items = .center }, "kea.researcher.pill");
    defer c.end();
    if (on) _ = c.interact(i, .{});
    ui.icon(c, "graduationcap", .{ .size = 11, .weight = .medium, .color = p.muted });
    const n = e.sections.items.len;
    const said = if (e.status == .streaming) "Explaining…" else c.print("Feynman · {d} section{s}", .{ n, if (n == 1) "" else "s" });
    ui.text(c, said, .{ .size = 11.5, .color = p.ink });
    if (controls.door(c, p, "arrow.up.left.and.arrow.down.right", .{ .help = "Expand" }).clicked and on) set(c, &e.minimized, false);
    if (controls.door(c, p, "xmark", .{ .help = "Dismiss" }).clicked and on) set(c, &e.dismissed, true);
}

fn set(c: *ui.Context, field: *bool, v: bool) void {
    field.* = v;
    c.changed = true;
}

fn expanded(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, e: *Entry, at: ui.Rect, top: f32, on: bool) void {
    const w = @min(380, @max(260, at.w * 0.36));
    const h = @min(520, @max(200, at.h - top - 16));
    const i = c.open(.{ .direction = .column, .width = px(w), .radius = 14, .background = p.ground.alpha(0.96), .border = p.hairline, .shadow = card.swiftShadow(0.12, 20, 6), .clip = true }, "kea.researcher.card");
    defer c.end();
    if (on) _ = c.interact(i, .{});
    header(b, c, p, e, on);
    ui.column(c, .{ .scroll = true, .gap = 8, .width = .fill, .max_height = h - 44, .padding = .{ .left = 12, .right = 12, .bottom = 12 } });
    defer ui.end(c);
    if (e.status == .failed) ui.text(c, e.error_msg orelse "Couldn't explain this page", .{ .size = 12, .color = p.muted, .wrap = true });
    if (e.status == .streaming and e.sections.items.len == 0) ui.text(c, "Reading the sections…", .{ .size = 12, .color = p.muted, .wrap = true });
    for (e.sections.items, 0..) |*s, n| section(b, c, p, t, e, s, n, on);
}

fn header(b: *Browser, c: *ui.Context, p: *const Palette, e: *Entry, on: bool) void {
    ui.row(c, .{ .gap = 2, .width = .fill, .align_items = .center, .padding = .{ .left = 12, .right = 6, .top = 8, .bottom = 8 } });
    defer ui.end(c);
    _ = c.open(.{ .pulse = if (e.status == .streaming) .{ .period = 1.4, .scale_amp = 0.06, .alpha_low = 0.45 } else null }, null);
    ui.icon(c, "graduationcap", .{ .size = 12, .weight = .semibold, .color = p.muted });
    c.end();
    {
        ui.column(c, .{ .grow = 1, .padding = .{ .left = 6 } });
        defer ui.end(c);
        ui.text(c, "Feynman Researcher", .{ .size = 12.5, .weight = .semibold, .color = p.ink, .truncate = .ellipsis });
        const status = switch (e.status) {
            .checking, .streaming => "Explaining…",
            .done => e.title,
            .failed => "Stopped",
        };
        ui.text(c, status, .{ .size = 10.5, .color = p.muted, .truncate = .ellipsis });
    }
    if (controls.door(c, p, "text.bubble", .{ .help = "Open in Chat" }).clicked and on) {
        _ = researcher.openInChat(b, e);
        c.changed = true;
    }
    // Next frame, before anything drawn holds the entry's words.
    if (controls.door(c, p, "arrow.clockwise", .{ .help = "Refresh" }).clicked and on) set(c, &e.restart, true);
    if (controls.door(c, p, "minus", .{ .help = "Minimize" }).clicked and on) set(c, &e.minimized, true);
    if (controls.door(c, p, "xmark", .{ .help = "Dismiss" }).clicked and on) set(c, &e.dismissed, true);
}

/// A section's card: arriving while the page is explained it fades up into place, and its body folds away.
fn section(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, e: *Entry, s: *researcher.Section, n: usize, on: bool) void {
    const box = c.open(.{ .direction = .column, .gap = 6, .width = .fill, .padding = .xy(10, 8), .radius = 10, .background = p.wash.alpha(0.5), .settle_y = motion.settle }, c.print("kea.researcher.sec.{d}", .{n}));
    defer c.end();
    const sec_id = c.node(box).id;
    const v = std.math.clamp(presence.presenceFrom(c, sec_id, if (e.status == .done) 1 else 0, true, motion.settle, null) orelse 1, 0, 1);
    c.node(box).style.opacity = v;
    c.node(box).style.offset = .{ .y = (1 - v) * 6 };
    const heading = e.heading(s.*);
    {
        ui.row(c, .{ .gap = 4, .width = .fill, .align_items = .center });
        defer ui.end(c);
        if (controls.door(c, p, if (s.folded) "chevron.right" else "chevron.down", .{ .help = if (s.folded) "Unfold" else "Fold" }).clicked and on) set(c, &s.folded, !s.folded);
        const hi = c.open(.{ .grow = 1, .control = true }, null);
        const it = c.interact(hi, .{});
        c.help(hi, "Show this section on the page");
        c.addA11y(hi, .button, heading, "", false, true);
        ui.text(c, heading, .{ .size = 12.5, .weight = .semibold, .color = if (it.hovered) p.sunset else p.ink, .wrap = true });
        c.end();
        if (it.clicked and on) researcher.jumpToSection(t, e, s.*);
        const pg = e.pageOf(s.*);
        if (pg > 0) ui.text(c, c.print("p. {d}", .{pg}), .{ .size = 10.5, .color = p.muted });
        if (controls.pill(c, p, "Ask", .{ .help = "Ask Ubi Chat about this section" }).clicked and on) {
            researcher.askSection(b, e, s.*);
            c.changed = true;
        }
    }
    if (!disclose.begin(c, sec_id ^ 0x666f6c64, !s.folded, motion.settle)) return;
    defer disclose.end(c);
    const text = e.body(s.*);
    if (text.len > 0) markdown_view.answer(b, c, p, &b.chat.answers, text, .{ .zoom = 0.92, .cache = e.status == .done, .stream_id = if (e.status == .streaming) sec_id else null });
}
