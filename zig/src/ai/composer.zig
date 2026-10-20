//! The panel's composer (`AssistantPanel.composer`, `pageLine`,
//! `ModelPicker`; AIAssist.swift:731-908, 1272-1322): the pins, the page
//! in front, what a "/" or "@" word suggests, the question being typed,
//! the model, and Send or Stop.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("../chrome/controls.zig");
const Uuid = @import("../data/json.zig").Uuid;
const Assistant = @import("assistant.zig").Assistant;
const ubi = @import("ubi_chat.zig");
const chat_view = @import("chat_view.zig");
const State = chat_view.State;
const Do = chat_view.Do;

const prompt = "Ask, or type / or @…";

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do) void {
    // The composer's text follows the draft wherever it changed (a pick, a
    // command, Cancel on the notice); what is typed goes back below.
    if (!std.mem.eql(u8, st.draft.text(), a.draft.items)) st.draft.set(a.draft.items);
    const suggestions = a.suggestions(c.alloc()) catch &.{};
    const pins = a.chat.pins;
    const has_text = std.mem.trim(u8, a.draft.items, " \t\r\n").len > 0;

    ui.column(c, .{ .width = .fill, .padding = .all(10) });
    defer ui.end(c);
    ui.column(c, .{ .gap = 8, .width = .fill, .padding = .all(12), .radius = 16, .background = p.wash.alpha(0.5), .border = p.hairline });
    defer ui.end(c);

    if (pins.len > 0) {
        if (st.pins_folded) {
            if (plain(c, "Pins")) {
                st.pins_folded = false;
                c.changed = true;
            }
            ui.row(c, .{ .gap = 4, .align_items = .center });
            ui.icon(c, "chevron.right", .{ .size = 9, .weight = .semibold, .color = p.muted });
            ui.text(c, c.print("Pins: {d}", .{pins.len}), .{ .size = 11, .color = p.muted });
            ui.end(c);
            c.end();
        } else pinList(c, p, st, todo, pins);
    }

    ui.row(c, .{ .gap = 4, .width = .fill, .align_items = .center });
    if (controls.door(c, p, if (a.chat.pageHidden) "eye.slash" else "eye", .{ .on = !a.chat.pageHidden, .help = "Share the page in front" }).clicked) todo.* = .toggle_page;
    ui.text(c, pageLine(c, b, a), .{ .size = 11.5, .color = p.muted, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
    if (pins.len == 0 and controls.door(c, p, "plus", .{ .help = "Add Pins\u{2026}" }).clicked) todo.* = .add_pins;
    if (controls.door(c, p, "pin", .{ .help = "Pin This Page" }).clicked) todo.* = .pin_page;
    ui.end(c);

    if (suggestions.len > 0) {
        ui.column(c, .{ .width = .fill, .radius = 8, .background = p.wash.alpha(0.6) });
        for (suggestions) |s| {
            const i = c.open(.{ .direction = .row, .gap = 8, .width = .fill, .padding = .xy(10, 5), .align_items = .center, .control = true }, null);
            if (c.interact(i, .{}).clicked) todo.* = .{ .pick = s };
            c.addA11y(i, .button, s.title, s.detail, false, true);
            ui.icon(c, icon(s.source), .{ .size = 10, .frame = 14, .color = p.muted });
            ui.text(c, s.title, .{ .size = 12, .color = p.ink, .truncate = true });
            _ = c.leaf(.{ .grow = 1, .min_width = 4 }, .none, null);
            ui.text(c, s.detail, .{ .size = 11, .color = p.muted, .truncate = true });
            c.end();
        }
        ui.end(c);
    }

    if (a.notice != null) {
        // `.disabled(assistant.notice != nil)`.
        ui.text(c, if (a.draft.items.len == 0) prompt else a.draft.items, .{ .size = 13, .color = p.faint, .wrap = true });
    } else {
        // Keyed: its id (and the focus) stays as pins and suggestions come and go.
        _ = c.open(.{ .width = .fill }, "kea.chat.composer");
        if (st.typing) {
            st.typing = false;
            ui.focusNext(c, false);
        }
        const r = ui.textArea(c, &st.draft, .{ .size = 13, .min_lines = 1, .max_lines = 8, .submit_on_return = true, .bare = true });
        // The prompt is VoiceOver's name for it, as the TextField's is; drawn
        // here in faint (the area's own would be muted), after the area so it
        // keeps its place (and its id, which the focus is).
        const ax = c.a11y_items.items;
        if (ax.len > 0 and ax[ax.len - 1].role == .text_field) ax[ax.len - 1].label = prompt;
        if (st.draft.text().len == 0)
            _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = prompt, .style = .{ .size = 13 }, .color = p.faint } }, null);
        ui.end(c);
        if (r.changed) a.setDraft(st.draft.text());
        if (r.submitted) todo.* = .submit;
    }

    ui.row(c, .{ .gap = 8, .width = .fill, .align_items = .center });
    defer ui.end(c);
    modelPicker(b, c, p);
    _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
    if (a.busy()) {
        if (controls.door(c, p, "stop.fill", .{ .help = "Stop" }).clicked) todo.* = .stop;
    } else {
        const live = has_text and a.notice == null;
        const i = c.open(.{ .control = live }, null);
        defer c.end();
        c.help(i, "Send   \u{21A9}");
        c.addA11y(i, .button, "Send", "", false, live);
        if (live and c.interact(i, .{}).clicked) todo.* = .submit;
        ui.icon(c, "arrow.up.circle.fill", .{ .size = 20, .color = if (has_text) p.ink else p.faint });
    }
}

/// A plain button's box, opened (close with `c.end`); true when clicked.
fn plain(c: *ui.Context, said: []const u8) bool {
    const i = c.open(.{ .control = true }, null);
    c.addA11y(i, .button, said, "", false, true);
    return c.interact(i, .{}).clicked;
}

/// PINS: each pinned page with its eye and its cross, then Add Pins… and Collapse.
fn pinList(c: *ui.Context, p: *const Palette, st: *State, todo: *Do, pins: []const @import("../data/chats_store.zig").ChatPin) void {
    ui.column(c, .{ .gap = 4, .width = .fill });
    defer ui.end(c);
    ui.text(c, "PINS", .{ .size = 10, .weight = .semibold, .color = p.muted });
    _ = c.open(.{ .scroll = true, .scroll_bar = false, .gap = 4, .width = .fill, .max_height = @min(@as(f32, @floatFromInt(pins.len)) * 24, 108) }, "kea.chat.pins");
    for (pins) |pin| {
        ui.row(c, .{ .gap = 6, .width = .fill, .align_items = .center });
        if (plain(c, if (pin.hidden) "Share Pin" else "Hide Pin")) todo.* = .{ .toggle_pin = pin.id };
        ui.icon(c, if (pin.hidden) "eye.slash" else "eye", .{ .size = 10, .color = if (pin.hidden) p.faint else p.muted });
        c.end();
        ui.text(c, pin.title, .{ .size = 12, .color = if (pin.hidden) p.faint else p.ink, .truncate = true });
        _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
        if (plain(c, "Unpin")) todo.* = .{ .unpin = pin.id };
        ui.icon(c, "xmark", .{ .size = 8, .weight = .semibold, .color = p.muted });
        c.end();
        ui.end(c);
    }
    c.end();
    ui.row(c, .{ .gap = 12, .padding = .{ .top = 2 }, .align_items = .center });
    if (plain(c, "+ Add Pins\u{2026}")) todo.* = .add_pins;
    ui.text(c, "+ Add Pins\u{2026}", .{ .size = 11, .color = p.muted });
    c.end();
    if (plain(c, "Collapse")) {
        st.pins_folded = true;
        c.changed = true;
    }
    ui.row(c, .{ .gap = 3, .align_items = .center });
    ui.icon(c, "chevron.up", .{ .size = 8, .weight = .semibold, .color = p.muted });
    ui.text(c, "Collapse", .{ .size = 11, .color = p.muted });
    ui.end(c);
    c.end();
    ui.end(c);
}

/// `pageLine`: what goes with the question from the page in front.
fn pageLine(c: *ui.Context, b: *Browser, a: *Assistant) []const u8 {
    const t = b.activeTab() orelse return "No page in front";
    if (t.isBlank()) return "No page in front";
    if (ubi.isPrivatePage(t) and !a.shy) return "Private tab — not shared";
    if (!a.shareable(t)) return "Not a web page — not shared";
    if (a.chat.pageHidden) return c.print("Not shared: {s}", .{t.label()});
    return t.label();
}

fn icon(source: ubi.Source) []const u8 {
    return switch (source) {
        .command => "slash.circle",
        .tab => "square.on.square",
        .bookmark => "bookmark",
        .history => "clock",
    };
}

/// `ModelPicker`: the model in use; its menu picks another, or the provider.
fn modelPicker(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const m = b.kea.ai;
    const provider = m.chosen();
    const model = if (provider) |pr| m.model(pr) else "";
    const label = if (model.len == 0) "Choose an AI" else model;
    const i = c.open(.{ .direction = .row, .gap = 4, .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    if (provider) |pr| c.help(i, pr.name);
    c.addA11y(i, .menu_button, label, "", false, true);
    ui.text(c, label, .{ .size = 11, .color = p.muted, .truncate = true });
    ui.icon(c, "chevron.up.chevron.down", .{ .size = 7.5, .color = p.muted });
    if (it.clicked) if (it.rect) |r| chat_view.menuLater(b, .{ .x = r.x, .y = r.y + r.h }, b.assisting.?.chat.id, modelItems);
}

fn modelItems(arena: std.mem.Allocator, b: *Browser, id: Uuid) anyerror![]const MenuItem {
    const m = b.kea.ai;
    var out: std.ArrayList(MenuItem) = .empty;
    if (m.chosen()) |provider| {
        for (try ubi.models(arena, m, provider, m.model(provider))) |name|
            try out.append(arena, try chat_view.item(arena, b, name, .model, id, try arena.dupe(u8, name), false));
        try out.append(arena, .separator);
    }
    try out.append(arena, try chat_view.item(arena, b, "Choose Provider\u{2026}", .settings, id, "", false));
    return out.items;
}
