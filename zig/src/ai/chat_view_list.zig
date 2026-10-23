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
    rebuildList(b, a, st);
    for (st.list_rows) |it| switch (it) {
        .header => |title| {
            ui.column(c, .{ .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 2 } });
            ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = p.muted });
            ui.end(c);
        },
        .entry => |e| row(b, c, p, a, st, todo, e.item, e.clock),
        .more => |total| if (more(c, p, c.print("Show all ({d})", .{total}))) {
            st.all_starred = true;
        },
        .fewer => if (more(c, p, "Show fewer")) {
            st.all_starred = false;
        },
    };
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

fn row(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do, e: Entry, clock: []const u8) void {
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
        _ = c.text.width(clock, .{ .size = 10.5 });
        const m = c.open(.{ .width = px(20), .height = px(18), .align_items = .center, .justify = .center, .control = true }, null);
        const mt = c.interact(m, .{});
        c.addA11y(m, .menu_button, "More", "", false, true);
        ui.icon(c, "ellipsis", .{ .size = 10, .color = p.muted });
        c.end();
        if (mt.clicked) if (mt.rect) |r| chat_view.menuLater(b, .{ .x = r.x, .y = r.y + r.h }, e.id, rowItems);
    } else ui.text(c, clock, .{ .size = 10.5, .color = p.muted });
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

pub fn virtualView(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do) void {
    ui.column(c, .{ .gap = 6, .width = .fill, .grow = 1 });
    defer ui.end(c);
    ui.column(c, .{ .width = .fill, .padding = .{ .left = 10, .right = 10, .top = 6 } });
    ui.row(c, .{ .gap = 6, .width = .fill, .padding = .xy(8, 5), .radius = 8, .background = p.wash, .align_items = .center });
    ui.icon(c, "magnifyingglass", .{ .size = 11, .color = p.muted });
    _ = ui.textField(c, &st.search, .{ .bare = true, .size = 12, .width = .fill, .placeholder = "Search chats" });
    ui.end(c);
    ui.end(c);

    ui.column(c, .{ .width = .fill, .padding = .{ .left = 6, .right = 6 } });
    const nb = c.open(.{ .direction = .row, .gap = 6, .width = .fill, .padding = .xy(10, 4), .align_items = .center, .control = true }, null);
    if (c.interact(nb, .{}).clicked) todo.* = .new;
    c.addA11y(nb, .button, "New Chat", "", false, true);
    ui.icon(c, "square.and.pencil", .{ .size = 11, .color = p.muted });
    ui.text(c, "New Chat", .{ .size = 12.5, .color = p.ink });
    c.end();
    ui.end(c);

    rebuildList(b, a, st);
    ui.key(c, "kea.chat.list");
    var rows = ui.list(c, .{ .count = st.list_rows.len, .row_height = 26, .padding = .{ .left = 6, .right = 6 } });
    while (rows.next()) |idx| {
        switch (st.list_rows[idx]) {
            .header => |title| {
                ui.column(c, .{ .height = px(26), .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 2 } });
                ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = p.muted });
                ui.end(c);
            },
            .entry => |e| row(b, c, p, a, st, todo, e.item, e.clock),
            .more => |total| {
                const m = c.open(.{ .height = px(26), .padding = .xy(10, 4), .control = true }, null);
                if (c.interact(m, .{}).clicked) {
                    st.all_starred = true;
                    c.changed = true;
                }
                ui.text(c, c.print("Show all ({d})", .{total}), .{ .size = 11.5, .color = p.muted });
                c.end();
            },
            .fewer => {
                const m = c.open(.{ .height = px(26), .padding = .xy(10, 4), .control = true }, null);
                if (c.interact(m, .{}).clicked) {
                    st.all_starred = false;
                    c.changed = true;
                }
                ui.text(c, "Show fewer", .{ .size = 11.5, .color = p.muted });
                c.end();
            },
        }
    }
    rows.end();
}

fn rebuildList(b: *Browser, a: *Assistant, st: *State) void {
    const index = a.m.chats.index;
    var h = std.hash.Wyhash.init(index.len);
    h.update(std.mem.asBytes(&a.m.chats.revision));
    const index_ptr: usize = @intFromPtr(index.ptr);
    h.update(std.mem.asBytes(&index_ptr));
    h.update(st.search.text());
    h.update(&.{@intFromBool(st.all_starred)});
    if (index.len > 0) h.update(std.mem.asBytes(&index[0].touched));
    const digest = h.final();
    if (st.list_hash == digest and st.list_arena != null) return;
    if (st.list_arena == null) st.list_arena = std.heap.ArenaAllocator.init(b.gpa) else _ = st.list_arena.?.reset(.retain_capacity);
    const la = st.list_arena.?.allocator();
    st.list_hash = digest;
    const secs = chat_sections.sections(la, index, st.search.text(), st.all_starred) catch &.{};
    var items: std.ArrayList(State.ListItem) = .empty;
    for (secs) |sec| {
        items.append(la, .{ .header = sec.title }) catch {};
        for (sec.items) |e| {
            var owned = e;
            owned.title = la.dupe(u8, e.title) catch e.title;
            items.append(la, .{ .entry = .{ .item = owned, .clock = when.clock(la, e.touched) } }) catch {};
        }
        if (std.mem.eql(u8, sec.title, "Starred")) {
            if (sec.more > 0) items.append(la, .{ .more = sec.more + sec.items.len }) catch {} else if (st.all_starred and sec.items.len > 5) items.append(la, .fewer) catch {};
        }
    }
    st.list_rows = items.items;
}
