//! `AssistantPanel` (AIAssist.swift:560-1323): Ubi Chat's panel, in its
//! column, let out over the page, or in its own window (chrome/popped.zig).
//! The header and the layout are here; the transcript is
//! `chat_view_turns.zig`, the chat list `chat_view_list.zig`, the composer
//! `composer.zig`. What a click asks for is done once the panel is built
//! (`Do`, `apply`): the chat's strings it changes are what the frame drew.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const Palette = @import("../design/palette.zig").Palette;
const side_panels = @import("../chrome/side_panels.zig");
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const when = @import("../chrome/when.zig");
const PanelWindow = @import("../chrome/popped.zig").PanelWindow;
const appkit = @import("../sys/appkit.zig");
const Uuid = @import("../data/json.zig").Uuid;
const cs = @import("../data/chats_store.zig");
const Chat = cs.Chat;
const Turn = cs.Turn;
const Entry = cs.Entry;
const markdown_view = @import("markdown_view.zig");
const Assistant = @import("assistant.zig").Assistant;
const folded = @import("assistant_more.zig").folded;
const ubi = @import("ubi_chat.zig");
const turns = @import("chat_view_turns.zig");
const chat_list = @import("chat_view_list.zig");
const chat_sections = @import("chat_sections.zig");
const composer = @import("composer.zig");

fn px(n: f32) ui.Length {
    return .{ .px = n };
}

/// What the panel keeps between frames, per window (`@State`); begun
/// afresh when the chat closes.
pub const State = struct {
    /// Ubi Chat's own window, while the chat is open and popped out.
    window: ?*PanelWindow = null,
    /// The answers' code blocks and diagrams.
    answers: markdown_view.State = .{},
    /// The composer's text, kept the same as `Assistant.draft`.
    draft: ui.TextBuffer = .{},
    /// The chat list's search (`SessionList.query`).
    search: ui.TextBuffer = .{},
    show_earlier: bool = false,
    pins_folded: bool = false,
    all_starred: bool = false,
    /// The chat list's row under the pointer.
    hovered: ?Uuid = null,
    /// The composer takes the keys in the next frame (`typing = true`).
    typing: bool = false,
    appeared: bool = false,
    /// The chat shown, to fold its earlier turns again when it changes.
    chat_id: ?Uuid = null,
    /// What the transcript showed: its end is followed when it changes.
    seen_turns: usize = 0,
    seen_live: ?usize = null,
    heights: std.AutoHashMapUnmanaged(Uuid, f32) = .empty,
    heights_width: f32 = 0,
    heights_zoom: f32 = 1,
    rendered_turns: std.ArrayList(RenderedTurn) = .empty,
    list_arena: ?std.heap.ArenaAllocator = null,
    list_hash: u64 = std.math.maxInt(u64),
    list_rows: []const ListItem = &.{},

    pub const RenderedTurn = struct { id: Uuid, box_id: u64 };
    pub const ListItem = union(enum) {
        header: []const u8,
        entry: Entry,
        more: usize,
        fewer,
    };

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.answers.deinit(gpa);
        s.heights.deinit(gpa);
        s.rendered_turns.deinit(gpa);
        if (s.list_arena) |*la| la.deinit();
        s.draft.deinit();
        s.search.deinit();
    }

    /// The chat closed: what the panel held begins afresh; its window stays
    /// with `followChatWindow`.
    pub fn reset(s: *State, gpa: std.mem.Allocator) void {
        const w = s.window;
        s.deinit(gpa);
        s.* = .{ .window = w };
    }
};

/// A click's work, done after the panel is built.
pub const Do = union(enum) {
    none,
    close,
    new,
    open: Uuid,
    /// "Mark Done" on a task in the list.
    done: Uuid,
    agree,
    decline,
    ask: []const u8,
    toggle_pin: Uuid,
    unpin: Uuid,
    toggle_page,
    pin_page,
    add_pins,
    /// Its strings on the frame's arena.
    pick: ubi.Suggestion,
    submit,
    stop,
};

/// The panel, `width` wide in its column (null: let out or popped).
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, on_left: bool, width: ?f32, expanded: bool, is_popped: bool) void {
    const a = b.assisting orelse return;
    const st = &b.chat;
    const z: f32 = @floatCast(b.prefs.chat_zoom);
    var todo: Do = .none;
    // `.onAppear { typing = true }`, `.onChange(of: chat.id) { showEarlier = false }`.
    if (!st.appeared) {
        st.appeared = true;
        st.typing = true;
    }
    if (st.chat_id == null or !st.chat_id.?.eql(a.chat.id)) {
        st.chat_id = a.chat.id;
        st.show_earlier = false;
        st.heights.clearRetainingCapacity();
        st.rendered_turns.clearRetainingCapacity();
        st.answers.clearCache();
    }
    if (!a.listing) {
        if (st.search.text().len > 0) st.search.clear();
        st.all_starred = false;
        st.hovered = null;
    }
    // ponytail: pieces redraw through `Assistant.changed`; this also catches a frame they miss.
    if (a.busy() or a.compacting) c.frameIn(0.1);

    side_panels.begin(c, p, .chat, width, expanded);
    const body = c.open(.{ .width = .fill, .height = .fill }, "kea.chat.body");
    const roomy = if (c.rects.get(c.node(body).id)) |r| r.w >= 600 else false;
    header(b, c, p, a, &todo, roomy, expanded, is_popped);
    if (roomy) {
        ui.row(c, .{ .width = .fill, .grow = 1 });
        if (a.listing and !a.shy) {
            ui.column(c, .{ .width = px(220), .height = .fill });
            if (a.m.chats.index.len > 40) virtualChatList(b, c, p, a, st, &todo) else chat_list.view(b, c, p, a, st, &todo);
            ui.end(c);
            _ = c.leaf(.{ .width = px(1), .height = .fill, .background = p.hairline }, .none, null);
        }
        chatColumn(b, c, p, a, st, &todo, z, true);
        ui.end(c);
    } else if (a.listing) {
        ui.column(c, .{ .width = .fill, .grow = 1 });
        if (a.m.chats.index.len > 40) virtualChatList(b, c, p, a, st, &todo) else chat_list.view(b, c, p, a, st, &todo);
        ui.end(c);
    } else chatColumn(b, c, p, a, st, &todo, z, false);
    c.end();
    side_panels.end(b, c, p, .chat, on_left, width);
    if (todo != .none) {
        apply(b, a, todo, roomy);
        c.changed = true;
    }
}

fn header(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, todo: *Do, roomy: bool, expanded: bool, is_popped: bool) void {
    const head = c.open(.{ .direction = .row, .width = .fill, .gap = 6, .align_items = .center, .padding = .{ .left = 14, .right = 6, .top = 6, .bottom = 6 } }, "kea.chat.head");
    defer c.end();
    side_panels.headerGesture(b, c, head, .chat, !is_popped);
    ui.icon(c, "sparkles", .{ .size = 11, .weight = .medium, .color = p.muted });
    ui.text(c, if (a.listing and !roomy) "Chats" else a.chat.label(), .{ .size = 13, .weight = .semibold, .color = p.ink, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
    if (!a.shy and controls.door(c, p, "sidebar.left", .{ .on = a.listing, .help = "Chats" }).clicked) {
        a.listing = !a.listing;
        c.changed = true;
    }
    if (controls.door(c, p, "square.and.pencil", .{ .help = "New Chat" }).clicked) todo.* = .new;
    if (!is_popped) {
        const icon = if (expanded) "arrow.down.right.and.arrow.up.left" else "arrow.up.left.and.arrow.down.right";
        if (controls.door(c, p, icon, .{ .help = if (expanded) "Back to Sidebar Width" else "Expand" }).clicked) side_panels.toggleExpanded(b, .chat);
    }
    side_panels.panelMenu(b, c, p, .chat, is_popped);
    if (controls.door(c, p, "xmark", .{ .help = "Close   esc" }).clicked) todo.* = .close;
}

fn chatColumn(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do, z: f32, in_row: bool) void {
    // Keyed: the composer keeps the focus as the chat list comes and goes beside it.
    _ = c.open(if (in_row) .{ .grow = 1, .min_width = 0, .height = .fill } else .{ .width = .fill, .grow = 1 }, "kea.chat.column");
    defer ui.end(c);
    const sc = c.open(.{ .scroll = true, .scroll_bar = false, .width = .fill, .grow = 1 }, "kea.chat.transcript");
    // `scrollTo(last, anchor: .bottom)` as the answer grows or a turn joins.
    const live: ?usize = if (a.live) |l| l.answer.items.len else null;
    if (a.chat.turns.len != st.seen_turns or !std.meta.eql(live, st.seen_live)) {
        st.seen_turns = a.chat.turns.len;
        st.seen_live = live;
        c.setScroll(c.node(sc).id, .y, std.math.floatMax(f32));
    }
    if (a.chat.turns.len > 8) virtualConversation(b, c, p, a, st, todo, z, c.node(sc).id) else turns.conversation(b, c, p, a, st, todo, z);
    c.end();
    composer.view(b, c, p, a, st, todo);
}

fn estimateTurnHeight(t: Turn, z: f32) f32 {
    const lines: f32 = @floatFromInt(t.answer.len / 48 + 2);
    return (52.0 + lines * 18.0) * z;
}

fn virtualConversation(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, _: *Do, z: f32, scroll_id: u64) void {
    const sc_rect = c.rects.get(scroll_id);
    const vw: f32 = if (sc_rect) |r| r.w else 0;
    if ((vw > 0 and @abs(vw - st.heights_width) > 0.5) or st.heights_zoom != z) {
        st.heights.clearRetainingCapacity();
        st.rendered_turns.clearRetainingCapacity();
        if (vw > 0) st.heights_width = vw;
        st.heights_zoom = z;
    }
    for (st.rendered_turns.items) |rt| {
        if (c.rects.get(rt.box_id)) |r| if (r.h > 0) {
            st.heights.put(b.gpa, rt.id, r.h) catch {};
        };
    }
    st.rendered_turns.clearRetainingCapacity();

    ui.column(c, .{ .gap = 18, .width = .fill, .padding = .xy(16, 12) });
    defer ui.end(c);
    if (a.shy) ui.text(c, "A private tab's chat: only an AI on this Mac, and nothing is kept.", .{ .size = 12 * z, .color = p.muted, .wrap = true });
    const fold = folded(a.chat);
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
        if (measured != null and (y + h < lo or y > hi)) {
            _ = c.leaf(.{ .width = .fill, .height = px(h) }, .none, null);
        } else {
            const box_id = virtualTurnView(b, c, p, st, t, z, if (abs_idx < fold) 0.75 else 1.0, true);
            st.rendered_turns.append(b.gpa, .{ .id = t.id, .box_id = box_id }) catch {};
        }
        y += h + 18;
    }
    if (a.liveTurn()) |lt| {
        _ = virtualTurnView(b, c, p, st, lt, z, 1.0, false);
    }
}

fn virtualTurnView(b: *Browser, c: *ui.Context, p: *const Palette, st: *State, t: Turn, z: f32, opacity: f32, cache_ast: bool) u64 {
    c.next_key_int = std.mem.readInt(u64, t.id.bytes[0..8], .little);
    const box = c.open(.{ .direction = .column, .gap = 8, .width = .fill, .opacity = opacity }, null);
    defer c.end();
    const box_id = c.node(box).id;
    ui.row(c, .{ .width = .fill, .padding = .{ .left = 40 } });
    _ = c.leaf(.{ .grow = 1 }, .none, null);
    _ = c.open(.{ .padding = .xy(12, 8), .radius = 14, .background = p.wash, .selectable = true }, null);
    _ = c.leaf(.{}, .{ .text = .{ .str = t.question, .style = .{ .size = 12.5 * z, .color = p.ink, .wrap = true }, .color = p.ink } }, null);
    c.end();
    ui.end(c);
    if (t.answer.len == 0 and !t.done) ui.text(c, "…", .{ .size = 13 * z, .color = p.faint });
    if (t.answer.len > 0) markdown_view.answer(b, c, p, &st.answers, t.answer, .{ .zoom = z, .cache = cache_ast });
    if (t.failed) |failed| ui.text(c, failed, .{ .size = 12 * z, .color = p.muted, .wrap = true });
    ui.row(c, .{ .width = .fill, .align_items = .center });
    ui.text(c, c.print("AI — may be wrong · {s}", .{t.place}), .{ .size = 10.5 * z, .color = p.muted, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
    if (t.done and t.answer.len > 0 and plate.quick(c, p, "Copy", null).clicked) ubi.copy(b.gpa, t.answer);
    ui.end(c);
    return box_id;
}

fn virtualChatList(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do) void {
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

    const index = a.m.chats.index;
    var h = std.hash.Wyhash.init(index.len);
    h.update(std.mem.asBytes(&a.m.chats.revision));
    const index_ptr: usize = @intFromPtr(index.ptr);
    h.update(std.mem.asBytes(&index_ptr));
    h.update(st.search.text());
    h.update(&.{@intFromBool(st.all_starred)});
    if (index.len > 0) h.update(std.mem.asBytes(&index[0].touched));
    const digest = h.final();
    if (st.list_hash != digest or st.list_arena == null) {
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
                items.append(la, .{ .entry = owned }) catch {};
            }
            if (std.mem.eql(u8, sec.title, "Starred")) {
                if (sec.more > 0) items.append(la, .{ .more = sec.more + sec.items.len }) catch {} else if (st.all_starred and sec.items.len > 5) items.append(la, .fewer) catch {};
            }
        }
        st.list_rows = items.items;
    }

    ui.key(c, "kea.chat.list");
    var rows = ui.list(c, .{ .count = st.list_rows.len, .row_height = 26, .padding = .{ .left = 6, .right = 6 } });
    while (rows.next()) |idx| {
        switch (st.list_rows[idx]) {
            .header => |title| {
                ui.column(c, .{ .height = px(26), .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 2 } });
                ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = p.muted });
                ui.end(c);
            },
            .entry => |e| virtualChatRow(b, c, p, a, st, todo, e),
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

fn virtualChatRow(_: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do, e: Entry) void {
    const current = e.id.eql(a.chat.id);
    const i = c.open(.{ .direction = .row, .gap = 6, .width = .fill, .height = px(26), .padding = .xy(10, 4), .radius = 7, .align_items = .center, .background = if (current) p.wash else null, .control = true }, null);
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
        _ = c.interact(m, .{});
        c.addA11y(m, .menu_button, "More", "", false, true);
        ui.icon(c, "ellipsis", .{ .size = 10, .color = p.muted });
        c.end();
    } else ui.text(c, when.clock(c.alloc(), e.touched), .{ .size = 10.5, .color = p.muted });
    if (it.clicked) todo.* = .{ .open = e.id };
}


/// `todo` done, once the panel is built.
fn apply(b: *Browser, a: *Assistant, todo: Do, roomy: bool) void {
    switch (todo) {
        .none => {},
        .close => return b.closeAssistant(),
        .new => {
            a.new(false);
            if (!roomy) a.listing = false;
        },
        .open => |id| {
            a.open(id);
            if (!roomy) a.listing = false;
        },
        .done => |id| a.edit(id, {}, setDone),
        .agree => a.agree(),
        .decline => a.decline(),
        .ask => |q| _ = a.ask(q),
        .toggle_pin => |id| a.togglePin(id),
        .unpin => |id| a.unpin(id),
        .toggle_page => a.togglePage(),
        .pin_page => a.pinPage(),
        .add_pins => {
            // `draft += draft.isEmpty || draft.hasSuffix(" ") ? "@" : " @"`
            const d = a.draft.items;
            a.draft.appendSlice(a.gpa, if (d.len == 0 or d[d.len - 1] == ' ') "@" else " @") catch {};
            b.chat.typing = true;
        },
        .pick => |s| a.pick(s),
        .submit => a.submit(),
        .stop => a.stop(),
    }
    redraw(b);
}

/// The browser's window and the chat's own, drawn again.
pub fn redraw(b: *Browser) void {
    b.redraw();
    if (b.chat.window) |w| w.redraw();
}

fn find(kea: *Kea, record: Uuid) ?*Browser {
    for (kea.browsers.items) |x| if (x.record_id.eql(record)) return x;
    return null;
}

// MARK: menus

fn flip(comptime field: []const u8) fn (void, std.mem.Allocator, *Chat) error{OutOfMemory}!void {
    return struct {
        fn f(_: void, _: std.mem.Allocator, ch: *Chat) error{OutOfMemory}!void {
            @field(ch, field) = !@field(ch, field);
        }
    }.f;
}

fn setDone(_: void, _: std.mem.Allocator, ch: *Chat) error{OutOfMemory}!void {
    ch.task = false;
}

/// One menu item's work on a window's chat.
pub const Act = struct {
    kea: *Kea,
    window: Uuid,
    chat: Uuid,
    what: What,
    /// A model's name (`.model`), or the name Rename… starts with.
    text: []const u8 = "",

    pub const What = enum { rename, star, task, clone, compact, clean_up, copy, delete, zoom_in, zoom_out, zoom_reset, model, settings };

    fn fire(self: *Act, _: *nanoui.menu.Item) void {
        const b = find(self.kea, self.window) orelse return;
        run(b, self.*);
    }
};

/// A menu item's work, as picked.
pub fn run(b: *Browser, act: Act) void {
    defer redraw(b);
    switch (act.what) {
        .zoom_in, .zoom_out, .zoom_reset => {
            const z = b.prefs.chat_zoom;
            b.prefs.setChatZoom(switch (act.what) {
                .zoom_in => z + 0.1,
                .zoom_out => z - 0.1,
                else => 1,
            });
            for (b.kea.browsers.items) |x| redraw(x);
            return;
        },
        .model => {
            const m = b.kea.ai;
            if (m.chosen()) |provider| b.prefs.setAIModel(act.text, provider.id);
            return;
        },
        .settings => if (b.kea.ai.open_settings) |open| return open(b),
        else => {},
    }
    const a = b.assisting orelse return;
    switch (act.what) {
        .rename => rename(b, act),
        .star => a.edit(act.chat, {}, flip("starred")),
        .task => a.edit(act.chat, {}, flip("task")),
        .clone => a.clone(act.chat),
        .compact => a.compact(),
        .clean_up => a.cleanUp(),
        .copy => {
            var arena = std.heap.ArenaAllocator.init(b.gpa);
            defer arena.deinit();
            ubi.copy(b.gpa, ubi.markdown(arena.allocator(), a.chat) catch return);
        },
        .delete => a.delete(act.chat),
        else => {},
    }
}

/// `Ask.name("Rename Chat", …)` as a sheet on the window the chat is in.
fn rename(b: *Browser, act: Act) void {
    if (b.kea.opts.headless) return;
    const Renaming = struct {
        kea: *Kea,
        window: Uuid,
        chat: Uuid,

        fn done(self: *@This(), answer: appkit.Answer) void {
            defer std.heap.c_allocator.destroy(self);
            if (!answer.ok or answer.text.len == 0) return;
            const bb = find(self.kea, self.window) orelse return;
            const a = bb.assisting orelse return;
            a.rename(self.chat, answer.text);
            redraw(bb);
        }
    };
    const r = std.heap.c_allocator.create(Renaming) catch return;
    r.* = .{ .kea = act.kea, .window = act.window, .chat = act.chat };
    const win: ?objc.Object = if (b.chat.window) |w| (if (w.window) |nw| nw.nswindow else null) else if (b.window) |w| w.nswindow else null;
    appkit.ask(win, .{ .title = "Rename Chat", .field = .{ .placeholder = "Name", .initial = act.text }, .confirm = "Rename" }, r, Renaming.done);
}
pub fn item(arena: std.mem.Allocator, b: *Browser, label: []const u8, what: Act.What, id: Uuid, text: []const u8, disabled: bool) !MenuItem {
    const s = try arena.create(Act);
    s.* = .{ .kea = b.kea, .window = b.record_id, .chat = id, .what = what, .text = text };
    return .{ .label = label, .click = .of(s, Act.fire), .disabled = disabled };
}
pub fn menuExtra(arena: std.mem.Allocator, b: *Browser) ![]MenuItem {
    const a = b.assisting orelse return &.{};
    const ch = a.chat;
    var out: std.ArrayList(MenuItem) = .empty;
    if (!a.shy) {
        try out.append(arena, try item(arena, b, "Rename\u{2026}", .rename, ch.id, try arena.dupe(u8, ch.label()), false));
        try out.append(arena, try item(arena, b, if (ch.starred) "Unstar" else "Star", .star, ch.id, "", false));
        try out.append(arena, try item(arena, b, if (ch.task) "Mark Done" else "Make It a Task", .task, ch.id, "", false));
        try out.append(arena, try item(arena, b, "Clone", .clone, ch.id, "", false));
        try out.append(arena, try item(arena, b, "Compact Earlier Turns", .compact, ch.id, "", !a.canCompact()));
        try out.append(arena, try item(arena, b, "Clean Up", .clean_up, ch.id, "", false));
    }
    try out.append(arena, try item(arena, b, "Copy Chat", .copy, ch.id, "", false));
    if (!a.shy) {
        try out.append(arena, .separator);
        try out.append(arena, try item(arena, b, "Delete Chat", .delete, ch.id, "", false));
    }
    try out.append(arena, .separator);
    const z = b.prefs.chat_zoom;
    try out.append(arena, .{ .label = try std.fmt.allocPrint(arena, "Zoom: {d}%", .{@as(i64, @intFromFloat(@round(z * 100)))}), .disabled = true });
    try out.append(arena, try item(arena, b, "Zoom In", .zoom_in, ch.id, "", z >= 2));
    try out.append(arena, try item(arena, b, "Zoom Out", .zoom_out, ch.id, "", z <= 0.5));
    try out.append(arena, try item(arena, b, "Actual Size", .zoom_reset, ch.id, "", false));
    try out.append(arena, .separator);
    return out.items;
}
pub const Build = *const fn (arena: std.mem.Allocator, b: *Browser, id: Uuid) anyerror![]const MenuItem;
const Later = struct {
    kea: *Kea,
    window: Uuid,
    at: ui.Point,
    id: Uuid,
    build: Build,
    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Later = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(l);
        const b = find(l.kea, l.window) orelse return;
        const win = (if (b.chat.window) |w| w.window else b.window) orelse return;
        const s = win.surface orelse return;
        var arena = std.heap.ArenaAllocator.init(b.gpa);
        defer arena.deinit();
        const template = l.build(arena.allocator(), b, l.id) catch return;
        if (template.len == 0) return;
        const m = nanoui.Menu.create(b.gpa, @import("../app/kea.zig").app_name, template) catch return;
        defer m.destroy();
        m.popup(s.nsview, l.at.x, l.at.y);
    }
};
pub fn menuLater(b: *Browser, at: ui.Point, id: Uuid, build: Build) void {
    if (b.kea.ui_app == null) return;
    const l = std.heap.c_allocator.create(Later) catch return;
    l.* = .{ .kea = b.kea, .window = b.record_id, .at = at, .id = id, .build = build };
    objc.dispatchMain(l, Later.fire);
}
