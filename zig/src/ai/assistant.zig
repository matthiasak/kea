//! Ubi Chat in one window (`Assistant` in AIAssist.swift): the chat on
//! screen, the answer coming in, what is typed. The chats themselves are
//! `Ai.chats`'. A question goes with the page in front unless its eye is
//! closed and with the pages pinned to the chat, fenced as the websites'
//! words to read and never as orders; anything in the answer the shared
//! pages didn't have is pointed out. A private tab's chat uses only what runs
//! on this Mac, and is never written.
const std = @import("std");
const json = @import("../data/json.zig");
const cs = @import("../data/chats_store.zig");
const url = @import("../data/url.zig");
const Tab = @import("../web/tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;
const ai = @import("ai.zig");
const ubi = @import("ubi_chat.zig");
const page = @import("page_text.zig");
const sse = @import("client_sse.zig");
const runs = @import("assistant_runs.zig");
const more = @import("assistant_more.zig");
const Uuid = json.Uuid;
const Chat = cs.Chat;
const Turn = cs.Turn;
const ChatPin = cs.ChatPin;
const A = std.mem.Allocator;

/// The answer coming in, until it is done and joins the chat's turns.
pub const Live = struct {
    id: Uuid,
    question: []u8,
    answer: std.ArrayList(u8) = .empty,
    place: []u8,
};

/// What a provider off this Mac is sent, shown before the first question goes.
pub const Notice = struct { provider_id: []u8, text: []u8 };

pub const Assistant = struct {
    gpa: A,
    m: *ai.Ai,
    browser: ?*Browser,
    /// Opened on a private tab: only an AI on this Mac, and never written.
    shy: bool,
    serial: u64,
    /// Owns `chat`.
    chat_arena: std.heap.ArenaAllocator,
    chat: Chat,
    live: ?Live = null,
    draft: std.ArrayList(u8) = .empty,
    notice: ?Notice = null,
    /// A shared page has words addressed to an AI (see page_text.addressesAI).
    addressed: bool = false,
    listing: bool = false,
    help_shown: bool = false,
    compacting: bool = false,
    waiting: ?[]u8 = null,
    task: ?*runs.Send = null,
    compactor: ?*runs.Compact = null,
    compact_run: u64 = 0,
    naming: std.ArrayList(Uuid) = .empty,

    pub const longest = 32_000;

    // In assistant_more.zig: the composer's suggestions and commands, compacting, cleaning up.
    pub const suggestions = more.suggestions;
    pub const pick = more.pick;
    pub const run = more.run;
    pub const compact = more.compact;
    pub const compactWith = more.compactWith;
    pub const cleanUp = more.cleanUp;
    pub const stop = more.stop;

    pub fn create(m: *ai.Ai, browser: ?*Browser, shy: bool) !*Assistant {
        const self = try m.gpa.create(Assistant);
        errdefer m.gpa.destroy(self);
        try m.assistants.append(m.gpa, self);
        self.* = .{ .gpa = m.gpa, .m = m, .browser = browser, .shy = shy, .serial = m.next_serial, .chat_arena = .init(m.gpa), .chat = fresh(false, &.{}) };
        m.next_serial += 1;
        return self;
    }

    pub fn destroy(self: *Assistant) void {
        self.stop();
        for (self.m.assistants.items, 0..) |x, i| if (x == self) {
            _ = self.m.assistants.swapRemove(i);
            break;
        };
        self.clearLive();
        self.clearNotice();
        if (self.waiting) |w| self.gpa.free(w);
        self.draft.deinit(self.gpa);
        self.naming.deinit(self.gpa);
        self.chat_arena.deinit();
        self.gpa.destroy(self);
    }

    fn fresh(page_hidden: bool, pins: []const ChatPin) Chat {
        return .{ .id = Uuid.random(), .touched = json.now(), .pageHidden = page_hidden, .pins = pins };
    }

    pub fn busy(self: *const Assistant) bool {
        return self.live != null;
    }

    pub fn canCompact(self: *const Assistant) bool {
        const done = @min(@as(usize, @intCast(@max(0, self.chat.compacted orelse 0))), self.chat.turns.len);
        return !self.busy() and !self.compacting and self.chat.turns.len - done > 2;
    }

    /// The answer coming in, as a turn (borrowed).
    pub fn liveTurn(self: *const Assistant) ?Turn {
        const l = self.live orelse return null;
        return .{ .id = l.id, .question = l.question, .answer = l.answer.items, .place = l.place };
    }

    fn clearLive(self: *Assistant) void {
        const l = &(self.live orelse return);
        self.gpa.free(l.question);
        self.gpa.free(l.place);
        l.answer.deinit(self.gpa);
        self.live = null;
    }

    fn clearNotice(self: *Assistant) void {
        const n = self.notice orelse return;
        self.gpa.free(n.provider_id);
        self.gpa.free(n.text);
        self.notice = null;
    }

    pub fn announce(self: *Assistant, text: []const u8) void {
        if (self.browser) |b| b.announce(text);
    }

    /// The window drawn again, as a `@Published` change does: the
    /// browser's, and the chat's own when it is popped out.
    pub fn changed(self: *Assistant) void {
        const b = self.browser orelse return;
        b.redraw();
        if (b.chat.window) |w| w.redraw();
    }

    fn active(self: *Assistant) ?*Tab {
        const b = self.browser orelse return null;
        return b.activeTab();
    }

    pub fn shareable(self: *const Assistant, tab: ?*Tab) bool {
        const t = tab orelse return false;
        if (t.isBlank()) return false;
        const p = url.Parts.parse(t.url()) orelse return false;
        if (!p.isWeb()) return false;
        return self.shy or !ubi.isPrivatePage(t);
    }

    pub fn sharesPage(self: *Assistant) bool {
        return !self.chat.pageHidden and self.shareable(self.active());
    }

    pub fn setDraft(self: *Assistant, text: []const u8) void {
        self.draft.clearRetainingCapacity();
        self.draft.appendSlice(self.gpa, text) catch {};
    }

    // MARK: the chat, changed

    /// The chat replaced by a copy changed by `f` (its new strings on the
    /// allocator it is given), not yet kept.
    pub fn mutate(self: *Assistant, ctx: anytype, comptime f: fn (@TypeOf(ctx), A, *Chat) error{OutOfMemory}!void) void {
        var next: std.heap.ArenaAllocator = .init(self.gpa);
        var c = json.clone(next.allocator(), self.chat) catch return next.deinit();
        f(ctx, next.allocator(), &c) catch return next.deinit();
        self.chat_arena.deinit();
        self.chat_arena = next;
        self.chat = c;
        self.changed();
    }

    fn setChat(self: *Assistant, c: Chat) void {
        var next: std.heap.ArenaAllocator = .init(self.gpa);
        const copy = json.clone(next.allocator(), c) catch return next.deinit();
        self.chat_arena.deinit();
        self.chat_arena = next;
        self.chat = copy;
        self.changed();
    }

    /// Kept, unless private or empty.
    pub fn keep(self: *Assistant) void {
        if (!self.shy and self.chat.turns.len > 0) self.m.chats.put(self.chat);
    }

    /// The chat with `id` changed: this one, kept, or one in the store.
    pub fn edit(self: *Assistant, id: Uuid, ctx: anytype, comptime f: fn (@TypeOf(ctx), A, *Chat) error{OutOfMemory}!void) void {
        if (id.eql(self.chat.id)) {
            self.mutate(ctx, f);
            self.keep();
        } else editStored(self.m, id, ctx, f);
    }

    // MARK: asking

    /// The composer's Return: the first suggestion taken, a command run, or the question asked.
    pub fn submit(self: *Assistant) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const found = self.suggestions(arena.allocator()) catch &.{};
        if (found.len > 0) return self.pick(found[0]);
        const text = std.mem.trim(u8, self.draft.items, " \t\r\n");
        if (text.len == 0) return;
        const own = arena.allocator().dupe(u8, text) catch return;
        if (own[0] == '/') return self.run(own);
        if (self.ask(sse.prefix(own, 2000))) self.draft.clearRetainingCapacity();
    }

    pub fn ask(self: *Assistant, question: []const u8) bool {
        if (self.live != null or self.compacting or self.notice != null) return false;
        const b = self.browser orelse return false;
        const r = ubi.ready(self.m, b) orelse return false;
        if (self.shy and !self.m.staysOnThisMac(r.provider)) {
            self.announce("In a private tab, only an AI on this Mac");
            return false;
        }
        if (!r.provider.isLocal() and !self.told(r.provider.id)) {
            const q = self.gpa.dupe(u8, question) catch return false;
            const id = self.gpa.dupe(u8, r.provider.id) catch {
                self.gpa.free(q);
                return false;
            };
            const text = ubi.notice(self.gpa, self.m, r.provider) catch {
                self.gpa.free(q);
                self.gpa.free(id);
                return false;
            };
            if (self.waiting) |w| self.gpa.free(w);
            self.waiting = q;
            self.notice = .{ .provider_id = id, .text = text };
            return true;
        }
        self.send(question, r.provider, r.model);
        return true;
    }

    fn toldKey(buf: *[96]u8, id: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "chat.told.{s}", .{id}) catch "chat.told.";
    }

    fn told(self: *Assistant, id: []const u8) bool {
        var buf: [96]u8 = undefined;
        return self.m.store.@"bool"(toldKey(&buf, id)) orelse false;
    }

    pub fn agree(self: *Assistant) void {
        const n = self.notice orelse return;
        var buf: [96]u8 = undefined;
        self.m.store.setBool(toldKey(&buf, n.provider_id), true);
        self.clearNotice();
        if (self.waiting) |q| {
            self.waiting = null;
            defer self.gpa.free(q);
            _ = self.ask(q);
        }
    }

    pub fn decline(self: *Assistant) void {
        self.clearNotice();
        if (self.waiting) |w| {
            self.setDraft(w);
            self.gpa.free(w);
        }
        self.waiting = null;
    }

    pub fn summarize(self: *Assistant) void {
        self.mutate({}, struct {
            fn f(_: void, _: A, c: *Chat) !void {
                c.pageHidden = false;
            }
        }.f);
        if (!self.shareable(self.active())) return self.announce("AI works on web pages");
        self.listing = false;
        _ = self.ask(ubi.summary);
    }

    /// The question sent (Swift's `send`, past the checks `ask` makes).
    pub fn send(self: *Assistant, question: []const u8, p: ai.Provider, model: []const u8) void {
        self.help_shown = false;
        const place = ubi.place(self.gpa, self.m, p, model) catch return;
        const q = self.gpa.dupe(u8, question) catch return self.gpa.free(place);
        self.clearLive();
        self.live = .{ .id = Uuid.random(), .question = q, .place = place };
        const tab: ?*Tab = if (self.sharesPage()) self.active() else null;
        runs.Send.start(self, p, model, tab);
    }

    /// The answer `id` done: it joins the chat, which is kept; then the
    /// answer is checked against the pages it was given.
    pub fn finish(self: *Assistant, id: Uuid, failed: ?[]const u8, reads: []const page.Read) void {
        const l = self.live orelse return;
        if (!l.id.eql(id)) return;
        const turn: Turn = .{ .id = l.id, .question = l.question, .answer = l.answer.items, .done = true, .failed = failed, .place = l.place };
        self.mutate(turn, struct {
            fn f(t: Turn, a: A, c: *Chat) !void {
                const list = try a.alloc(Turn, c.turns.len + 1);
                @memcpy(list[0..c.turns.len], c.turns);
                list[c.turns.len] = try json.clone(a, t);
                c.turns = list;
                c.touched = json.now();
            }
        }.f);
        self.clearLive();
        self.keep();
        if (failed != null or reads.len == 0) return;
        runs.checkStrays(self, id, self.chat.turns[self.chat.turns.len - 1].answer, reads);
    }

    /// The chat named by the model, once, from its first good answer.
    pub fn name(self: *Assistant, p: ai.Provider, model: []const u8) void {
        if (self.shy or self.chat.title.len > 0) return;
        for (self.naming.items) |n| if (n.eql(self.chat.id)) return;
        const first = for (self.chat.turns) |t| {
            if (t.done and t.failed == null and t.answer.len > 0) break t;
        } else return;
        self.naming.append(self.gpa, self.chat.id) catch return;
        runs.Name.start(self, p, model, first.question, first.answer);
    }

    pub fn named(self: *Assistant, id: Uuid) void {
        for (self.naming.items, 0..) |n, i| if (n.eql(id)) {
            _ = self.naming.swapRemove(i);
            return;
        };
    }

    // MARK: chats

    pub fn open(self: *Assistant, id: Uuid) void {
        const found = self.m.chats.chat(id) orelse return;
        self.stop();
        self.clearLive();
        self.setChat(found);
        const r = ubi.quiet(self.m) orelse return;
        const first = for (self.chat.turns) |t| {
            if (t.done and t.failed == null and t.answer.len > 0) break t;
        } else return;
        var buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const place = ubi.place(fba.allocator(), self.m, r.provider, r.model) catch return;
        if (std.mem.eql(u8, first.place, place)) self.name(r.provider, r.model);
    }

    pub fn new(self: *Assistant, keeping_pins: bool) void {
        self.stop();
        self.clearLive();
        const c = fresh(if (keeping_pins) self.chat.pageHidden else false, if (keeping_pins) self.chat.pins else &.{});
        self.setChat(c);
    }

    pub fn rename(self: *Assistant, id: Uuid, to: []const u8) void {
        self.edit(id, sse.prefix(std.mem.trim(u8, to, " \t\r\n"), 80), setTitle);
    }

    fn setTitle(t: []const u8, a: A, c: *Chat) !void {
        c.title = try a.dupe(u8, t);
    }

    pub fn clone(self: *Assistant, id: Uuid) void {
        if (self.shy) return;
        const source = if (id.eql(self.chat.id)) self.chat else self.m.chats.chat(id) orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var copy = json.clone(a, source) catch return;
        copy.id = Uuid.random();
        copy.title = std.mem.concat(a, u8, &.{ source.label(), " (copy)" }) catch return;
        copy.touched = json.now();
        copy.starred = false;
        copy.task = false;
        self.m.chats.put(copy);
        self.open(copy.id);
    }

    pub fn delete(self: *Assistant, id: Uuid) void {
        self.m.chats.remove(id);
        if (id.eql(self.chat.id)) self.new(false);
    }

    pub fn togglePage(self: *Assistant) void {
        self.mutate({}, struct {
            fn f(_: void, _: A, c: *Chat) !void {
                c.pageHidden = !c.pageHidden;
            }
        }.f);
        self.keep();
    }

    pub fn pinPage(self: *Assistant) void {
        const t = self.active() orelse return;
        if (!self.shareable(t) or ubi.isPrivatePage(t)) return;
        for (self.chat.pins) |p| if (std.mem.eql(u8, p.url, t.url())) return;
        self.addPin(t.label(), t.url());
        self.keep();
    }

    fn addPin(self: *Assistant, title: []const u8, address: []const u8) void {
        self.mutate(ChatPin{ .id = Uuid.random(), .title = title, .url = address }, struct {
            fn f(p: ChatPin, a: A, c: *Chat) !void {
                const list = try a.alloc(ChatPin, c.pins.len + 1);
                @memcpy(list[0..c.pins.len], c.pins);
                list[c.pins.len] = try json.clone(a, p);
                c.pins = list;
            }
        }.f);
    }

    pub fn togglePin(self: *Assistant, id: Uuid) void {
        for (self.chat.pins) |p| {
            if (!p.id.eql(id)) continue;
            self.mutate(id, struct {
                fn f(want: Uuid, a: A, c: *Chat) !void {
                    const list = try a.dupe(ChatPin, c.pins);
                    for (list) |*x| if (x.id.eql(want)) {
                        x.hidden = !x.hidden;
                    };
                    c.pins = list;
                }
            }.f);
            return self.keep();
        }
    }

    pub fn unpin(self: *Assistant, id: Uuid) void {
        self.mutate(id, struct {
            fn f(gone: Uuid, a: A, c: *Chat) !void {
                var list: std.ArrayList(ChatPin) = .empty;
                for (c.pins) |x| if (!x.id.eql(gone)) try list.append(a, x);
                c.pins = list.items;
            }
        }.f);
        self.keep();
    }

    pub fn clearPins(self: *Assistant) void {
        self.mutate({}, struct {
            fn f(_: void, _: A, c: *Chat) !void {
                c.pins = &.{};
            }
        }.f);
        self.keep();
    }

};

test {
    _ = more;
    _ = @import("assistant_tests.zig");
}

/// A chat in the store changed by `f` and put back (`Chats.update`).
pub fn editStored(m: *ai.Ai, id: Uuid, ctx: anytype, comptime f: fn (@TypeOf(ctx), A, *Chat) error{OutOfMemory}!void) void {
    const found = m.chats.chat(id) orelse return;
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    var c = json.clone(arena.allocator(), found) catch return;
    f(ctx, arena.allocator(), &c) catch return;
    m.chats.put(c);
}
