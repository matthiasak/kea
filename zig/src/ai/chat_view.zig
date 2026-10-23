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
const PanelWindow = @import("../chrome/popped.zig").PanelWindow;
const appkit = @import("../sys/appkit.zig");
const Uuid = @import("../data/json.zig").Uuid;
const cs = @import("../data/chats_store.zig");
const Chat = cs.Chat;
const Entry = cs.Entry;
const markdown_view = @import("markdown_view.zig");
const Assistant = @import("assistant.zig").Assistant;
const ubi = @import("ubi_chat.zig");
const turns = @import("chat_view_turns.zig");
const chat_list = @import("chat_view_list.zig");
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
    last_transcript_h: f32 = 0,
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
        entry: struct { item: Entry, clock: []const u8 },
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
    attach_shot,
    remove_attachment: u64,
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
        st.answers.clearCache(b.gpa);
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
    _ = c.leaf(.{ .width = .fill, .height = px(1), .background = p.hairline }, .none, null);
    if (roomy) {
        ui.row(c, .{ .width = .fill, .grow = 1 });
        if (a.listing and !a.shy) {
            ui.column(c, .{ .width = px(220), .height = .fill });
            if (a.m.chats.index.len > 40) chat_list.virtualView(b, c, p, a, st, &todo) else chat_list.view(b, c, p, a, st, &todo);
            ui.end(c);
            _ = c.leaf(.{ .width = px(1), .height = .fill, .background = p.hairline }, .none, null);
        }
        chatColumn(b, c, p, a, st, &todo, z, true);
        ui.end(c);
    } else if (a.listing) {
        ui.column(c, .{ .width = .fill, .grow = 1 });
        if (a.m.chats.index.len > 40) chat_list.virtualView(b, c, p, a, st, &todo) else chat_list.view(b, c, p, a, st, &todo);
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
    const head = c.open(.{ .direction = .row, .width = .fill, .gap = 6, .align_items = .center, .padding = .{ .left = if (is_popped) 76 else 14, .right = 6, .top = 6, .bottom = 6 } }, "kea.chat.head");
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
    if (!is_popped and controls.door(c, p, "xmark", .{ .help = "Close" }).clicked) todo.* = .close;
}

fn chatColumn(b: *Browser, c: *ui.Context, p: *const Palette, a: *Assistant, st: *State, todo: *Do, z: f32, in_row: bool) void {
    // Keyed: the composer keeps the focus as the chat list comes and goes beside it.
    _ = c.open(if (in_row) .{ .grow = 1, .min_width = 0, .height = .fill } else .{ .width = .fill, .grow = 1 }, "kea.chat.column");
    defer ui.end(c);
    const sc = c.open(.{ .scroll = true, .scroll_bar = false, .width = .fill, .grow = 1 }, "kea.chat.transcript");
    const sc_id = c.node(sc).id;
    if (c.rects.get(sc_id)) |r| {
        if (st.last_transcript_h > r.h and r.h > 0) {
            if (c.scroll.getPtr(sc_id)) |off| off.* += st.last_transcript_h - r.h;
        }
        st.last_transcript_h = r.h;
    }
    // `scrollTo(last, anchor: .bottom)` as the answer grows or a turn joins.
    const live: ?usize = if (a.live) |l| l.answer.items.len else null;
    if (a.chat.turns.len != st.seen_turns or !std.meta.eql(live, st.seen_live)) {
        st.seen_turns = a.chat.turns.len;
        st.seen_live = live;
        c.setScroll(sc_id, .y, std.math.floatMax(f32));
    }
    if (a.chat.turns.len > 8) turns.virtualConversation(b, c, p, a, st, todo, z, sc_id) else turns.conversation(b, c, p, a, st, todo, z);
    c.end();
    composer.view(b, c, p, a, st, todo);
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
        .attach_shot => a.toggleShot(b),
        .remove_attachment => |id| a.removeAttachment(id),
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

    pub const What = enum { rename, star, task, clone, compact, clean_up, copy, delete, zoom_in, zoom_out, zoom_reset, model, thinking_toggle, effort_low, effort_medium, effort_high, effort_max, web_search_toggle, tools_toggle, settings };

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
        .thinking_toggle => return b.prefs.set("ai_thinking", !b.prefs.ai_thinking),
        .effort_low => {
            b.prefs.set("ai_thinking", true);
            return b.prefs.set("ai_effort", .low);
        },
        .effort_medium => {
            b.prefs.set("ai_thinking", true);
            return b.prefs.set("ai_effort", .medium);
        },
        .effort_high => {
            b.prefs.set("ai_thinking", true);
            return b.prefs.set("ai_effort", .high);
        },
        .effort_max => {
            b.prefs.set("ai_thinking", true);
            return b.prefs.set("ai_effort", .max);
        },
        .web_search_toggle => return b.prefs.set("ai_web_search", !b.prefs.ai_web_search),
        .tools_toggle => return b.prefs.set("ubi_tools", !b.prefs.ubi_tools),
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
pub fn checkedItem(arena: std.mem.Allocator, b: *Browser, label: []const u8, what: Act.What, id: Uuid, text: []const u8, checked: bool) !MenuItem {
    const s = try arena.create(Act);
    s.* = .{ .kea = b.kea, .window = b.record_id, .chat = id, .what = what, .text = text };
    return .{ .label = label, .checked = checked, .click = .of(s, Act.fire) };
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
