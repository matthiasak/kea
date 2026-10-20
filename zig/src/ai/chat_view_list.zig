//! The panel's chat list (`AssistantPanel.SessionList`, AIAssist.swift:
//! 1083-1270): its search, New Chat, and the chats by section, each with
//! its menu.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("../chrome/controls.zig");
const when = @import("../chrome/when.zig");
const Uuid = @import("../data/json.zig").Uuid;
const Entry = @import("../data/chats_store.zig").Entry;
const Assistant = @import("assistant.zig").Assistant;
const chat_sections = @import("chat_sections.zig");
const chat_view = @import("chat_view.zig");
const State = chat_view.State;
const Do = chat_view.Do;

fn px(n: f32) ui.Length {
    return .{ .px = n };
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do) void {
    ui.column(c, .{ .gap = 6, .width = .fill, .grow = 1 });
    defer ui.end(c);
    ui.column(c, .{ .width = .fill, .padding = .{ .left = 10, .right = 10, .top = 6 } });
    ui.row(c, .{ .gap = 6, .width = .fill, .padding = .xy(8, 5), .radius = 8, .background = p.wash, .align_items = .center });
    ui.icon(c, "magnifyingglass", .{ .size = 11, .color = p.muted });
    _ = ui.textField(c, &st.search, .{ .bare = true, .size = 12, .width = .fill, .placeholder = "Search chats" });
    ui.end(c);
    ui.end(c);

    ui.column(c, .{ .width = .fill, .padding = .{ .left = 6, .right = 6 } });
    const i = c.open(.{ .direction = .row, .gap = 6, .width = .fill, .padding = .xy(10, 4), .align_items = .center, .control = true }, null);
    if (c.interact(i, .{}).clicked) todo.* = .new;
    c.addA11y(i, .button, "New Chat", "", false, true);
    ui.icon(c, "square.and.pencil", .{ .size = 11, .color = p.muted });
    ui.text(c, "New Chat", .{ .size = 12.5, .color = p.ink });
    c.end();
    ui.end(c);

    const index = a.m.chats.index;
    if (index.len == 0) {
        ui.column(c, .{ .width = .fill, .padding = .all(12) });
        ui.text(c, "No chats yet. They stay in the nest — on your own Macs only.", .{ .size = 12, .color = p.muted, .wrap = true });
        ui.end(c);
        return;
    }
    _ = c.open(.{ .scroll = true, .scroll_bar = false, .width = .fill, .grow = 1, .padding = .{ .left = 6, .right = 6 } }, "kea.chat.list");
    defer c.end();
    const sections = chat_sections.sections(c.alloc(), index, st.search.text(), st.all_starred) catch return;
    for (sections) |s| {
        ui.column(c, .{ .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 2 } });
        ui.text(c, s.title, .{ .size = 11, .weight = .semibold, .color = p.muted });
        ui.end(c);
        for (s.items) |e| row(b, c, p, a, st, todo, e);
        if (!std.mem.eql(u8, s.title, "Starred")) continue;
        if (s.more > 0) {
            if (more(c, p, c.print("Show all ({d})", .{s.more + s.items.len}))) st.all_starred = true;
        } else if (st.all_starred and s.items.len > 5) {
            if (more(c, p, "Show fewer")) st.all_starred = false;
        }
    }
}

fn more(c: *ui.Context, p: *const Palette, title: []const u8) bool {
    const i = c.open(.{ .padding = .xy(10, 4), .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, title, "", false, true);
    ui.text(c, title, .{ .size = 11.5, .color = p.muted });
    if (it.clicked) c.changed = true;
    return it.clicked;
}

fn row(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do, e: Entry) void {
    const current = e.id.eql(a.chat.id);
    const i = c.open(.{ .direction = .row, .gap = 6, .width = .fill, .padding = .xy(10, 4), .radius = 7, .align_items = .center, .background = if (current) p.wash else null, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const title = if (e.title.len == 0) "Untitled" else e.title;
    c.addA11y(i, .button, title, "", current, true);
    if (it.hovered) {
        st.hovered = e.id;
    } else if (st.hovered) |h| if (h.eql(e.id)) {
        st.hovered = null;
    };
    if (e.task) {
        ui.icon(c, "list.clipboard", .{ .size = 10, .color = p.muted });
    } else if (e.starred) ui.icon(c, "star.fill", .{ .size = 9, .color = p.muted });
    ui.text(c, title, .{ .size = 12.5, .color = p.ink, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
    if (e.task) {
        if (controls.door(c, p, "checkmark", .{ .help = "Mark Done" }).clicked) todo.* = .{ .done = e.id };
    } else if (st.hovered != null and st.hovered.?.eql(e.id)) {
        const m = c.open(.{ .width = px(20), .height = px(18), .align_items = .center, .justify = .center, .control = true }, null);
        const mt = c.interact(m, .{});
        c.addA11y(m, .menu_button, "More", "", false, true);
        ui.icon(c, "ellipsis", .{ .size = 10, .color = p.muted });
        c.end();
        if (mt.clicked) if (mt.rect) |r| chat_view.menuLater(b, .{ .x = r.x, .y = r.y + r.h }, e.id, rowItems);
    } else ui.text(c, when.clock(c.alloc(), e.touched), .{ .size = 10.5, .color = p.muted });
    if (it.right_clicked) return chat_view.menuLater(b, c.input.mouse, e.id, rowItems);
    // A click on the door or the ⋯ in it is theirs, not the row's.
    if (it.clicked) todo.* = .{ .open = e.id };
}

/// `rowActions`: what a chat in the list offers.
fn rowItems(arena: std.mem.Allocator, b: *Browser, id: Uuid) anyerror![]const MenuItem {
    const a = b.assisting orelse return &.{};
    const e = for (a.m.chats.index) |x| {
        if (x.id.eql(id)) break x;
    } else return &.{};
    const item = chat_view.item;
    const out = try arena.alloc(MenuItem, 6);
    out[0] = try item(arena, b, "Rename\u{2026}", .rename, id, try arena.dupe(u8, e.title), false);
    out[1] = try item(arena, b, if (e.starred) "Unstar" else "Star", .star, id, "", false);
    out[2] = try item(arena, b, if (e.task) "Mark Done" else "Make It a Task", .task, id, "", false);
    out[3] = try item(arena, b, "Clone", .clone, id, "", false);
    out[4] = .separator;
    out[5] = try item(arena, b, "Delete Chat", .delete, id, "", false);
    return out;
}
