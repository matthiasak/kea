//! The panel's transcript (`AssistantPanel.conversation`, `caution`,
//! `noticeCard`, `TurnView`; AIAssist.swift:910-1081): its text sizes
//! times the chat's zoom.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const Turn = @import("../data/chats_store.zig").Turn;
const Assistant = @import("assistant.zig").Assistant;
const folded = @import("assistant_more.zig").folded;
const ubi = @import("ubi_chat.zig");
const markdown_view = @import("markdown_view.zig");
const chat_view = @import("chat_view.zig");
const State = chat_view.State;
const Do = chat_view.Do;

fn px(n: f32) ui.Length {
    return .{ .px = n };
}

/// Text as wide as it is, wrapping only at the width it is given.
fn hug(c: *ui.Context, str: []const u8, style: ui.TextStyle) void {
    var s = style;
    s.wrap = true;
    _ = c.leaf(.{}, .{ .text = .{ .str = str, .style = s, .color = style.color orelse c.theme.text } }, null);
}

pub fn conversation(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do, z: f32) void {
    ui.column(c, .{ .gap = 18, .width = .fill, .padding = .xy(16, 12) });
    defer ui.end(c);
    if (a.notice) |n| noticeCard(c, p, a, n, todo, z);
    if (a.shy) ui.text(c, "A private tab's chat: only an AI on this Mac, and nothing is kept.", .{ .size = 12 * z, .color = p.muted, .wrap = true });
    if (a.help_shown) help(c, p, a, z);
    const none = a.chat.turns.len == 0 and a.live == null;
    if (none and a.notice == null) {
        ui.column(c, .{ .gap = 10, .width = .fill, .padding = .all(16), .radius = 14, .background = p.wash.alpha(0.45), .border = p.hairline });
        ui.row(c, .{ .gap = 6, .align_items = .center });
        ui.icon(c, "sparkles", .{ .size = 12 * z, .weight = .semibold, .color = p.muted });
        ui.text(c, "Ask anything.", .{ .size = 13 * z, .weight = .semibold, .color = p.ink });
        ui.end(c);
        ui.text(c, "The page in front goes with your question unless you close its eye below. Type tabs/, bookmarks/, history/ or @ to pin more pages, and / for commands.", .{ .size = 12 * z, .color = p.muted, .wrap = true });
        if (a.sharesPage()) {
            ui.row(c, .{ .gap = 6 });
            for (ubi.starters) |s| {
                if (controls.pill(c, p, c.print("✦ {s}", .{s.label}), .{}).clicked) todo.* = .{ .ask = s.prompt };
            }
            ui.end(c);
        }
        ui.end(c);
    }
    if (a.addressed and a.notice == null) caution(c, p, "This page has text written for an AI to follow. The answer may have been steered by it.", z);
    const fold = folded(a.chat);
    if (fold > 0) {
        earlier(c, p, st, fold, z);
        if (st.show_earlier) {
            if (a.chat.summary) |summary| if (summary.len > 0) {
                ui.column(c, .{ .gap = 6, .width = .fill, .padding = .all(10), .radius = 10, .background = p.wash });
                ui.text(c, "Summary", .{ .size = 11.5 * z, .weight = .semibold, .color = p.muted });
                markdown_view.answer(b, c, p, &st.answers, summary, .{ .zoom = z });
                ui.end(c);
            };
            for (a.chat.turns[0..fold]) |t| turnView(b, c, p, st, t, z, 0.75);
        }
    }
    for (a.chat.turns[fold..]) |t| turnView(b, c, p, st, t, z, 1);
    if (a.liveTurn()) |t| _ = turnViewBox(b, c, p, st, t, z, 1, false);
}

/// "Earlier, compacted · N turns" between two hairlines, folding them open.
fn earlier(c: *ui.Context, p: *const Palette, st: *State, fold: usize, z: f32) void {
    const i = c.open(.{ .direction = .row, .gap = 8, .width = .fill, .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const said = c.print("Earlier, compacted · {d} turns", .{fold});
    c.addA11y(i, .button, said, "", st.show_earlier, true);
    if (it.clicked) {
        st.show_earlier = !st.show_earlier;
        c.changed = true;
    }
    _ = c.leaf(.{ .grow = 1, .height = px(1), .background = p.hairline }, .none, null);
    ui.text(c, said, .{ .size = 11.5 * z, .color = p.muted });
    ui.icon(c, if (st.show_earlier) "chevron.up" else "chevron.down", .{ .size = 9 * z, .weight = .semibold, .color = p.muted });
    _ = c.leaf(.{ .grow = 1, .height = px(1), .background = p.hairline }, .none, null);
}

fn help(c: *ui.Context, p: *const Palette, a: *Assistant, z: f32) void {
    ui.row(c, .{ .gap = 6, .width = .fill, .padding = .all(8), .radius = 8, .background = p.wash });
    defer ui.end(c);
    ui.column(c, .{ .gap = 4, .grow = 1, .min_width = 0 });
    for (ubi.commands) |cmd| ui.text(c, c.print("{s} — {s}", .{ cmd.name, cmd.hint }), .{ .size = 11.5 * z, .color = p.ink, .wrap = true });
    ui.text(c, "tabs/  bookmarks/  history/  @ — pin a page", .{ .size = 11.5 * z, .color = p.ink, .wrap = true });
    ui.end(c);
    if (controls.door(c, p, "xmark", .{ .help = "Hide" }).clicked) {
        a.help_shown = false;
        c.changed = true;
    }
}

/// `caution`: a warning on the wash, the triangle before it.
fn caution(c: *ui.Context, p: *const Palette, text: []const u8, z: f32) void {
    ui.row(c, .{ .gap = 6, .padding = .all(8), .radius = 8, .background = p.wash, .align_items = .start });
    defer ui.end(c);
    ui.icon(c, "exclamationmark.triangle", .{ .size = 10 * z, .weight = .medium, .color = p.muted });
    hug(c, text, .{ .size = 11.5 * z, .color = p.muted });
}

fn noticeCard(c: *ui.Context, p: *const Palette, a: *Assistant, n: @import("assistant.zig").Notice, todo: *Do, z: f32) void {
    ui.column(c, .{ .gap = 10, .padding = .all(12), .radius = 10, .background = p.wash.alpha(0.6) });
    defer ui.end(c);
    const name = if (a.m.named(n.provider_id)) |provider| provider.name else n.provider_id;
    ui.text(c, c.print("Answers from {s}", .{name}), .{ .size = 12.5 * z, .weight = .medium, .color = p.ink });
    ui.text(c, n.text, .{ .size = 12 * z, .color = p.muted, .wrap = true });
    ui.row(c, .{ .gap = 8 });
    if (controls.pill(c, p, "Continue", .{ .filled = true }).clicked) todo.* = .agree;
    if (controls.pill(c, p, "Cancel", .{}).clicked) todo.* = .decline;
    ui.end(c);
}

/// `TurnView`: the question on the right, the answer under it.
fn turnView(b: *Browser, c: *ui.Context, p: *const Palette, st: *State, t: Turn, z: f32, opacity: f32) void {
    _ = turnViewBox(b, c, p, st, t, z, opacity, true);
}

fn estimateTurnHeight(t: Turn, z: f32) f32 {
    const lines: f32 = @floatFromInt(t.answer.len / 48 + 2);
    return (52.0 + lines * 18.0) * z;
}

pub fn virtualConversation(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do, z: f32, scroll_id: u64) void {
    const sc_rect = c.rects.get(scroll_id);
    const vw: f32 = if (sc_rect) |r| r.w else 0;
    if ((vw > 0 and @abs(vw - st.heights_width) > 0.5) or st.heights_zoom != z) {
        st.heights.clearRetainingCapacity();
        st.rendered_turns.clearRetainingCapacity();
        if (vw > 0) st.heights_width = vw;
        st.heights_zoom = z;
    }
    if (st.heights.capacity() < a.chat.turns.len) st.heights.ensureTotalCapacity(b.gpa, @intCast(a.chat.turns.len + 16)) catch {};
    if (st.rendered_turns.capacity < 32) st.rendered_turns.ensureTotalCapacity(b.gpa, 32) catch {};
    for (st.rendered_turns.items) |rt| {
        if (c.rects.get(rt.box_id)) |r| if (r.h > 0) {
            st.heights.put(b.gpa, rt.id, r.h) catch {};
        };
    }
    st.rendered_turns.clearRetainingCapacity();

    ui.column(c, .{ .gap = 18, .width = .fill, .padding = .xy(16, 12) });
    defer ui.end(c);
    if (a.notice) |n| noticeCard(c, p, a, n, todo, z);
    if (a.shy) ui.text(c, "A private tab's chat: only an AI on this Mac, and nothing is kept.", .{ .size = 12 * z, .color = p.muted, .wrap = true });
    if (a.help_shown) help(c, p, a, z);
    if (a.addressed and a.notice == null) caution(c, p, "This page has text written for an AI to follow. The answer may have been steered by it.", z);
    const fold = folded(a.chat);
    if (fold > 0) {
        earlier(c, p, st, fold, z);
        if (st.show_earlier) {
            if (a.chat.summary) |summary| if (summary.len > 0) {
                ui.column(c, .{ .gap = 6, .width = .fill, .padding = .all(10), .radius = 10, .background = p.wash });
                ui.text(c, "Summary", .{ .size = 11.5 * z, .weight = .semibold, .color = p.muted });
                markdown_view.answer(b, c, p, &st.answers, summary, .{ .zoom = z });
                ui.end(c);
            };
        }
    }
    const start_idx: usize = if (fold > 0 and !st.show_earlier) fold else 0;
    const shown_turns = a.chat.turns[start_idx..];

    var total_h: f32 = 24;
    for (shown_turns, 0..) |t, idx| {
        if (idx > 0) total_h += 18;
        total_h += st.heights.get(t.id) orelse estimateTurnHeight(t, z);
    }
    if (a.liveTurn()) |lt| total_h += 18 + estimateTurnHeight(lt, z);

    const vh = if (sc_rect) |r| r.h else c.size.h;
    const raw_scroll = c.scroll.get(scroll_id) orelse 0;
    const eff_scroll = @min(raw_scroll, @max(0, total_h - vh));
    const lo = eff_scroll - 400;
    const hi = eff_scroll + vh + 400;

    var y: f32 = 12;
    for (shown_turns, start_idx..) |t, abs_idx| {
        const measured = st.heights.get(t.id);
        const h = measured orelse estimateTurnHeight(t, z);
        if (y + h < lo or y > hi) {
            _ = c.leaf(.{ .width = .fill, .height = px(h) }, .none, null);
        } else {
            const box_id = turnViewBox(b, c, p, st, t, z, if (abs_idx < fold) 0.75 else 1.0, true);
            st.rendered_turns.append(b.gpa, .{ .id = t.id, .box_id = box_id }) catch {};
        }
        y += h + 18;
    }
    if (a.liveTurn()) |lt| {
        _ = turnViewBox(b, c, p, st, lt, z, 1.0, false);
    }
}

fn turnViewBox(b: *Browser, c: *ui.Context, p: *const Palette, st: *State, t: Turn, z: f32, opacity: f32, cache_ast: bool) u64 {
    c.next_key_int = std.mem.readInt(u64, t.id.bytes[0..8], .little);
    const box = c.open(.{ .direction = .column, .gap = 8, .width = .fill, .opacity = opacity }, null);
    defer c.end();
    const box_id = c.node(box).id;
    ui.row(c, .{ .width = .fill, .padding = .{ .left = 40 } });
    _ = c.leaf(.{ .grow = 1 }, .none, null);
    _ = c.open(.{ .padding = .xy(12, 8), .radius = 14, .background = p.wash, .border = p.hairline, .selectable = true }, null);
    hug(c, t.question, .{ .size = 12.5 * z, .color = p.ink });
    c.end();
    ui.end(c);
    if (t.shot) {
        ui.row(c, .{ .width = .fill, .gap = 4, .align_items = .center, .justify = .end });
        ui.icon(c, "camera", .{ .size = 10 * z, .weight = .medium, .color = p.muted });
        ui.text(c, "Screenshot", .{ .size = 11 * z, .color = p.muted });
        ui.end(c);
    }
    for (t.tools) |u| {
        ui.row(c, .{ .width = .fill, .gap = 6, .align_items = .center });
        ui.icon(c, "magnifyingglass", .{ .size = 10 * z, .weight = .medium, .color = p.muted });
        ui.text(c, u.said, .{ .size = 11.5 * z, .color = p.muted, .truncate = true });
        ui.end(c);
    }
    if (t.answer.len == 0 and !t.done) ui.text(c, "…", .{ .size = 13 * z, .color = p.faint });
    if (t.answer.len > 0) markdown_view.answer(b, c, p, &st.answers, t.answer, .{ .zoom = z, .cache = cache_ast });
    if (t.failed) |failed| ui.text(c, failed, .{ .size = 12 * z, .color = p.muted, .wrap = true });
    if (t.strays.len > 0) {
        const joined = std.mem.join(c.alloc(), ", ", t.strays) catch "";
        caution(c, p, c.print("Not in the pages shared: {s}", .{joined}), z);
    }
    ui.row(c, .{ .width = .fill, .align_items = .center });
    ui.text(c, c.print("AI — may be wrong · {s}", .{t.place}), .{ .size = 10.5 * z, .color = p.muted, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
    if (t.done and t.answer.len > 0 and plate.quick(c, p, "Copy", null).clicked) ubi.copy(b.gpa, t.answer);
    ui.end(c);
    return box_id;
}
