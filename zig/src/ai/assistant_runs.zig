//! What an assistant waits for (the `Task`s of AIAssist.swift and Chats.swift's
//! `UbiChat.compact`/`name`): a question's pages read, its key found and its
//! answer streamed in; a chat named; a long chat compacted; an answer
//! checked. Each run finds its assistant again by serial when a wait ends,
//! as Swift's `[weak self]` does, and a stopped run hears nothing more.
const std = @import("std");
const json = @import("../data/json.zig");
const cs = @import("../data/chats_store.zig");
const dispatch = @import("../sys/dispatch.zig");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Tab = @import("../web/tab.zig").Tab;
const Kea = @import("../app/kea.zig").Kea;
const ai = @import("ai.zig");
const client = @import("client.zig");
const page = @import("page_text.zig");
const strays_mod = @import("page_strays.zig");
const sse = @import("client_sse.zig");
const ubi = @import("ubi_chat.zig");
const assistant_mod = @import("assistant.zig");
const Assistant = assistant_mod.Assistant;
const Uuid = json.Uuid;
const A = std.mem.Allocator;

/// One answer asked for and read in, up to `most` characters; `on_end`
/// once it finished, failed, was cut at `most`, or was dropped by
/// `on_piece` — never after `cancel`.
pub const Asking = struct {
    gpa: A,
    owner: *anyopaque,
    /// False: the owner has no use for it any more (dropped).
    on_piece: ?*const fn (*anyopaque, []const u8) bool = null,
    on_tool: ?*const fn (*anyopaque, sse.ToolEvent) void = null,
    on_end: *const fn (*anyopaque) void,
    most: usize,
    /// `most` counts UTF-8 bytes rather than characters.
    count_bytes: bool = false,
    handle: ?client.Handle = null,
    starting: bool = false,
    over: bool = false,
    dropped: bool = false,
    /// Why it failed, on `gpa`; null when it finished.
    failure: ?[]u8 = null,
    http_status: ?i64 = null,
    text: std.ArrayList(u8) = .empty,
    chars: usize = 0,

    pub fn deinit(s: *Asking) void {
        if (s.failure) |f| s.gpa.free(f);
        s.text.deinit(s.gpa);
    }

    /// The tail call of whoever starts it: `on_end` may free the owner.
    pub fn begin(s: *Asking, m: *ai.Ai, q: client.Ask) void {
        s.starting = true;
        const h = client.stream(m, q, .{ .ctx = s, .piece = piece, .tool = if (s.on_tool != null) tool else null, .done = done });
        s.starting = false;
        if (s.over) {
            if (h) |x| x.cancel();
            return s.on_end(s.owner);
        }
        s.handle = h;
    }

    pub fn cancel(s: *Asking) void {
        if (s.over) return;
        s.over = true;
        if (s.handle) |h| h.cancel();
        s.handle = null;
    }

    fn piece(raw: *anyopaque, text: []const u8) void {
        const s: *Asking = @ptrCast(@alignCast(raw));
        if (s.over) return;
        s.text.appendSlice(s.gpa, text) catch {};
        s.chars += if (s.count_bytes) text.len else std.unicode.utf8CountCodepoints(text) catch text.len;
        if (s.on_piece) |f| if (!f(s.owner, text)) {
            s.dropped = true;
            return s.cut();
        };
        if (s.chars > s.most) s.cut();
    }

    fn tool(raw: *anyopaque, ev: sse.ToolEvent) void {
        const s: *Asking = @ptrCast(@alignCast(raw));
        if (s.over) return;
        if (s.on_tool) |f| f(s.owner, ev);
    }

    /// Read as far as it went: the stream stopped, the answer kept.
    fn cut(s: *Asking) void {
        s.over = true;
        if (s.handle) |h| h.cancel();
        s.handle = null;
        if (!s.starting) s.on_end(s.owner);
    }

    fn done(raw: *anyopaque, f: ?client.Failure) void {
        const s: *Asking = @ptrCast(@alignCast(raw));
        if (s.over) return;
        s.over = true;
        s.handle = null;
        if (f) |x| {
            if (x == .http) s.http_status = x.http.status;
            s.failure = x.describe(s.gpa) catch s.gpa.dupe(u8, "") catch null;
        }
        if (!s.starting) s.on_end(s.owner);
    }
};

pub const Phase = enum { reading, keying, streaming, tooling };

fn copyProvider(a: A, p: ai.Provider) !ai.Provider {
    return json.clone(a, p);
}

// MARK: - a question

pub const Send = struct {
    gpa: A,
    m: *ai.Ai,
    kea: ?*Kea,
    serial: u64,
    id: Uuid,
    arena: std.heap.ArenaAllocator,
    provider: ai.Provider,
    model: []const u8,
    question: []const u8,
    recap: ?[]const u8,
    earlier: []const cs.Turn,
    pins: []const cs.ChatPin,
    next_pin: usize = 0,
    reads: std.ArrayList(page.Read) = .empty,
    seen: std.ArrayList([]const u8) = .empty,
    active_url: ?[]const u8 = null,
    key: ?[]u8 = null,
    shot_b64: ?[]const u8 = null,
    phase: Phase = .reading,
    dead: bool = false,
    fence: [21]u8 = undefined,
    round: @import("assistant_tools.zig").Round = .{},
    asking: Asking,

    /// The question already live on `self`; `tab` the page shared with it.
    pub fn start(self: *Assistant, p: ai.Provider, model: []const u8, tab: ?*Tab) void {
        const r = self.gpa.create(Send) catch return self.finish(self.live.?.id, "", &.{});
        r.* = .{ .gpa = self.gpa, .m = self.m, .kea = if (self.browser) |b| b.kea else null, .serial = self.serial, .id = self.live.?.id, .arena = .init(self.gpa), .provider = undefined, .model = undefined, .question = undefined, .recap = null, .earlier = &.{}, .pins = &.{}, .asking = .{ .gpa = self.gpa, .owner = r, .on_piece = arrived, .on_tool = @import("assistant_tools.zig").onTool, .on_end = ended, .most = Assistant.longest } };
        const a = r.arena.allocator();
        r.setUp(self, a, p, model) catch {
            r.free();
            return self.finish(self.live.?.id, "", &.{});
        };
        if (self.task) |old| old.cancel();
        self.task = r;
        if (tab) |t| {
            r.active_url = a.dupe(u8, t.url()) catch null;
            return page.read(t, a, r, readActive);
        }
        r.nextPin();
    }

    fn setUp(r: *Send, self: *Assistant, a: A, p: ai.Provider, model: []const u8) !void {
        r.provider = try copyProvider(a, p);
        r.model = try a.dupe(u8, model);
        r.question = try a.dupe(u8, self.live.?.question);
        const from = @import("assistant_more.zig").folded(self.chat);
        r.recap = if (from > 0) if (self.chat.summary) |s| try a.dupe(u8, s) else null else null;
        var good: std.ArrayList(cs.Turn) = .empty;
        for (self.chat.turns[from..]) |t| if (t.done and t.failed == null and t.answer.len > 0) try good.append(a, t);
        const keep = ubi.remembered(p);
        const tail = good.items[good.items.len -| keep..];
        r.earlier = try json.clone(a, @as([]const cs.Turn, tail));
        r.pins = try json.clone(a, self.chat.pins);
        if (self.shot) |jpeg| {
            defer {
                self.gpa.free(jpeg);
                self.shot = null;
            }
            const enc = std.base64.standard.Encoder;
            const dst = try a.alloc(u8, enc.calcSize(jpeg.len));
            r.shot_b64 = enc.encode(dst, jpeg);
        }
    }

    pub fn free(r: *Send) void {
        if (r.key) |k| r.gpa.free(k);
        r.asking.deinit();
        r.arena.deinit();
        r.gpa.destroy(r);
    }

    /// Stopped (`stop()`): let go now, or when what it waits for comes back.
    pub fn cancel(r: *Send) void {
        r.dead = true;
        if (r.phase == .streaming) {
            r.asking.cancel();
            r.free();
        }
    }

    pub fn owner(r: *Send) ?*Assistant {
        const self = r.m.assistant(r.serial) orelse return null;
        const l = self.live orelse return null;
        return if (l.id.eql(r.id)) self else null;
    }

    pub fn release(r: *Send) void {
        if (r.m.assistant(r.serial)) |self| if (self.task == r) {
            self.task = null;
        };
        r.free();
    }

    fn readActive(raw: *anyopaque, got: ?page.Read) void {
        const r: *Send = @ptrCast(@alignCast(raw));
        if (r.dead) return r.free();
        if (got) |read| {
            r.reads.append(r.arena.allocator(), read) catch {};
            if (r.active_url) |u| r.seen.append(r.arena.allocator(), u) catch {};
        }
        r.nextPin();
    }

    fn wasSeen(r: *Send, u: []const u8) bool {
        for (r.seen.items) |s| if (std.mem.eql(u8, s, u)) return true;
        return false;
    }

    /// The next pin read, or the reading over.
    fn nextPin(r: *Send) void {
        const a = r.arena.allocator();
        while (r.next_pin < r.pins.len) {
            const pin = r.pins[r.next_pin];
            r.next_pin += 1;
            if (pin.hidden or r.wasSeen(pin.url)) continue;
            r.seen.append(a, pin.url) catch {};
            if (r.kea) |k| if (ubi.openTab(k, pin.url)) |t| return page.read(t, a, r, readPin);
            r.placeholder(pin);
        }
        r.gathered();
    }

    // ponytail: a pin not open in a tab goes as its title and address; read it in a hidden web view if that proves too thin
    fn placeholder(r: *Send, pin: cs.ChatPin) void {
        r.reads.append(r.arena.allocator(), .{ .title = pin.title, .url = pin.url, .text = "(This page isn't open in a tab: only its title and address are known.)", .links = &.{}, .cut = false }) catch {};
    }

    fn readPin(raw: *anyopaque, got: ?page.Read) void {
        const r: *Send = @ptrCast(@alignCast(raw));
        if (r.dead) return r.free();
        if (got) |read| r.reads.append(r.arena.allocator(), read) catch {} else r.placeholder(r.pins[r.next_pin - 1]);
        r.nextPin();
    }

    fn gathered(r: *Send) void {
        const a = r.arena.allocator();
        const share = ubi.budget(r.provider) / @max(r.reads.items.len, 1);
        for (r.reads.items) |*read| {
            if ((std.unicode.utf8CountCodepoints(read.text) catch read.text.len) > share)
                read.* = page.shaped(a, read.title, read.url, read.text, read.links, share) catch read.*;
        }
        const self = r.owner() orelse return r.release();
        self.addressed = false;
        for (r.reads.items) |read| if (read.addressed) {
            self.addressed = true;
        };
        r.phase = .keying;
        if (r.provider.takesKey()) return r.m.keys.key(r.m, r.provider, r, keyed);
        keyed(r, null);
    }

    fn keyed(raw: *anyopaque, key: ?[]u8) void {
        const r: *Send = @ptrCast(@alignCast(raw));
        r.key = key;
        @import("assistant_tools.zig").ask(r);
    }

    pub fn messages(r: *Send, a: A, fence: []const u8) ![]client.Message {
        var out: std.ArrayList(client.Message) = .empty;
        if (r.recap) |s| {
            try out.append(a, .{ .role = .user, .text = try std.mem.concat(a, u8, &.{ ubi.recap, s }) });
            try out.append(a, .{ .role = .assistant, .text = "Understood." });
        }
        for (r.earlier) |t| {
            try out.append(a, .{ .role = .user, .text = t.question });
            try out.append(a, .{ .role = .assistant, .text = t.answer });
        }
        const imgs: []const client.Image = if (r.shot_b64) |b64| blk: {
            const one = try a.alloc(client.Image, 1);
            one[0] = .{ .media_type = "image/jpeg", .b64 = b64 };
            break :blk one;
        } else &.{};
        try out.append(a, .{ .role = .user, .text = try ubi.opening(a, r.reads.items, r.question, fence), .images = imgs });
        return out.items;
    }

    pub fn fail(r: *Send) void {
        if (r.owner()) |self| self.finish(r.id, "The provider's answer couldn't be read.", r.reads.items);
        r.release();
    }

    fn arrived(raw: *anyopaque, text: []const u8) bool {
        const r: *Send = @ptrCast(@alignCast(raw));
        const self = r.owner() orelse return false;
        const l = &self.live.?;
        l.answer.appendSlice(self.gpa, text) catch {};
        self.changed();
        return true;
    }

    fn ended(raw: *anyopaque) void {
        const r: *Send = @ptrCast(@alignCast(raw));
        if (@import("assistant_tools.zig").ended(r)) return;
        if (r.asking.dropped) return r.release();
        const self = r.owner() orelse return r.release();
        self.finish(r.id, r.asking.failure, r.reads.items);
        if (r.asking.failure == null and self.chat.turns.len > 0 and self.chat.turns[self.chat.turns.len - 1].id.eql(r.id))
            self.name(r.provider, r.model);
        r.release();
    }
};

// MARK: - a name

pub const Name = struct {
    gpa: A,
    m: *ai.Ai,
    serial: u64,
    chat_id: Uuid,
    arena: std.heap.ArenaAllocator,
    provider: ai.Provider,
    model: []const u8,
    prompt: []const u8,
    key: ?[]u8 = null,
    asking: Asking,

    pub fn start(self: *Assistant, p: ai.Provider, model: []const u8, question: []const u8, answer: []const u8) void {
        const r = self.gpa.create(Name) catch return self.named(self.chat.id);
        r.* = .{ .gpa = self.gpa, .m = self.m, .serial = self.serial, .chat_id = self.chat.id, .arena = .init(self.gpa), .provider = undefined, .model = undefined, .prompt = undefined, .asking = .{ .gpa = self.gpa, .owner = r, .on_end = ended, .most = 400 } };
        const a = r.arena.allocator();
        r.provider = copyProvider(a, p) catch return r.giveUp();
        r.model = a.dupe(u8, model) catch return r.giveUp();
        r.prompt = std.fmt.allocPrint(a, "Question:\n{s}\n\nAnswer:\n{s}", .{ sse.prefix(question, 1500), sse.prefix(answer, 3000) }) catch return r.giveUp();
        if (r.provider.takesKey()) return r.m.keys.key(r.m, r.provider, r, keyed);
        keyed(r, null);
    }

    fn keyed(raw: *anyopaque, key: ?[]u8) void {
        const r: *Name = @ptrCast(@alignCast(raw));
        r.key = key;
        const one = r.arena.allocator().alloc(client.Message, 1) catch return r.giveUp();
        one[0] = .{ .role = .user, .text = r.prompt };
        r.asking.begin(r.m, .{ .provider = r.provider, .model = r.model, .system = ubi.naming, .messages = one, .key = r.key, .max_tokens = 2048, .thinking = 1024 });
    }

    fn giveUp(r: *Name) void {
        if (r.m.assistant(r.serial)) |self| self.named(r.chat_id);
        if (r.key) |k| r.gpa.free(k);
        r.asking.deinit();
        r.arena.deinit();
        r.gpa.destroy(r);
    }

    fn ended(raw: *anyopaque) void {
        const r: *Name = @ptrCast(@alignCast(raw));
        defer r.giveUp();
        if (r.asking.failure != null) return;
        const n = ubi.title(r.asking.text.items) orelse return;
        const f = struct {
            fn f(name: []const u8, a: A, c: *cs.Chat) !void {
                if (c.title.len == 0) c.title = try a.dupe(u8, name);
            }
        }.f;
        if (r.m.assistant(r.serial)) |self| self.edit(r.chat_id, n, f) else assistant_mod.editStored(r.m, r.chat_id, n, f);
    }
};

// MARK: - compacting

pub const Compact = struct {
    gpa: A,
    m: *ai.Ai,
    serial: u64,
    run: u64,
    chat_id: Uuid,
    arena: std.heap.ArenaAllocator,
    provider: ai.Provider,
    model: []const u8,
    turns: []const cs.Turn,
    summary: ?[]const u8,
    idx: usize,
    end: usize,
    step: usize,
    next: usize = 0,
    key: ?[]u8 = null,
    phase: Phase = .keying,
    dead: bool = false,
    asking: Asking,

    pub fn start(self: *Assistant, p: ai.Provider, model: []const u8, from: usize, end: usize) void {
        const r = self.gpa.create(Compact) catch return self.announce("Couldn't compact");
        r.* = .{ .gpa = self.gpa, .m = self.m, .serial = self.serial, .run = self.compact_run, .chat_id = self.chat.id, .arena = .init(self.gpa), .provider = undefined, .model = undefined, .turns = &.{}, .summary = null, .idx = from, .end = end, .step = @max(1, ubi.remembered(p)), .asking = undefined };
        const a = r.arena.allocator();
        r.setUp(self, a, p, model, from) catch {
            r.free();
            self.compacting = false;
            return;
        };
        self.compactor = r;
        r.batch();
    }

    fn setUp(r: *Compact, self: *Assistant, a: A, p: ai.Provider, model: []const u8, from: usize) !void {
        r.provider = try copyProvider(a, p);
        r.model = try a.dupe(u8, model);
        r.turns = try json.clone(a, self.chat.turns);
        r.summary = if (from > 0) if (self.chat.summary) |s| try a.dupe(u8, s) else null else null;
    }

    fn free(r: *Compact) void {
        if (r.key) |k| r.gpa.free(k);
        if (r.phase == .streaming) r.asking.deinit();
        r.arena.deinit();
        r.gpa.destroy(r);
    }

    pub fn cancel(r: *Compact) void {
        r.dead = true;
        if (r.phase == .streaming) {
            r.asking.cancel();
            r.free();
        }
    }

    /// Done, failed or stopped: the assistant is no longer compacting.
    fn finish(r: *Compact) void {
        if (r.m.assistant(r.serial)) |self| {
            if (self.compact_run == r.run) self.compacting = false;
            if (self.compactor == r) self.compactor = null;
            self.changed();
        }
        r.free();
    }

    fn batch(r: *Compact) void {
        if (r.idx >= r.end) return r.finish();
        r.next = @min(r.idx + r.step, r.end);
        r.phase = .keying;
        if (r.provider.takesKey()) return r.m.keys.key(r.m, r.provider, r, keyed);
        keyed(r, null);
    }

    fn keyed(raw: *anyopaque, key: ?[]u8) void {
        const r: *Compact = @ptrCast(@alignCast(raw));
        if (r.key) |k| r.gpa.free(k);
        r.key = key;
        if (r.dead) return r.free();
        const msgs = compactMessages(r.arena.allocator(), r.summary, r.turns[r.idx..r.next]) catch return r.failed("The provider's answer couldn't be read.");
        r.asking = .{ .gpa = r.gpa, .owner = r, .on_end = ended, .most = 12_000 };
        r.phase = .streaming;
        r.asking.begin(r.m, .{ .provider = r.provider, .model = r.model, .system = ubi.compacting, .messages = msgs, .key = r.key, .max_tokens = 2048, .thinking = 1024 });
    }

    fn failed(r: *Compact, why: []const u8) void {
        if (r.m.assistant(r.serial)) |self| {
            var buf: [512]u8 = undefined;
            self.announce(std.fmt.bufPrint(&buf, "Couldn't compact: {s}", .{why}) catch "Couldn't compact");
        }
        r.finish();
    }

    fn ended(raw: *anyopaque) void {
        const r: *Compact = @ptrCast(@alignCast(raw));
        if (r.asking.failure) |f| {
            var buf: [512]u8 = undefined;
            const why = buf[0..@min(f.len, buf.len)];
            @memcpy(why, f[0..why.len]);
            r.asking.deinit();
            r.phase = .keying;
            return r.failed(why);
        }
        const text = std.mem.trim(u8, r.asking.text.items, " \t\r\n");
        if (text.len == 0) {
            r.asking.deinit();
            r.phase = .keying;
            return r.failed("The provider's answer couldn't be read.");
        }
        r.summary = r.arena.allocator().dupe(u8, text) catch null;
        r.asking.deinit();
        r.phase = .keying;
        const Fold = struct { summary: []const u8, upto: usize };
        const fold: Fold = .{ .summary = r.summary orelse "", .upto = r.next };
        const f = struct {
            fn f(x: Fold, a: A, c: *cs.Chat) !void {
                c.summary = try a.dupe(u8, x.summary);
                c.compacted = @intCast(x.upto);
            }
        }.f;
        const self = r.m.assistant(r.serial);
        if (self != null and self.?.chat.id.eql(r.chat_id)) {
            self.?.mutate(fold, f);
            self.?.keep();
        } else assistant_mod.editStored(r.m, r.chat_id, fold, f);
        r.idx = r.next;
        r.batch();
    }
};

/// What one batch sends (`UbiChat.compact`): the summary so far, the good
/// turns of the batch, and the ask. On `a`.
pub fn compactMessages(a: A, summary: ?[]const u8, turns: []const cs.Turn) ![]client.Message {
    var out: std.ArrayList(client.Message) = .empty;
    if (summary) |s| if (s.len > 0) {
        try out.append(a, .{ .role = .user, .text = try std.mem.concat(a, u8, &.{ ubi.recap, s }) });
        try out.append(a, .{ .role = .assistant, .text = "Understood." });
    };
    for (turns) |t| if (t.done and t.failed == null and t.answer.len > 0) {
        try out.append(a, .{ .role = .user, .text = sse.prefix(t.question, 2000) });
        try out.append(a, .{ .role = .assistant, .text = sse.prefix(t.answer, 6000) });
    };
    try out.append(a, .{ .role = .user, .text = "Summarize the conversation above, as asked." });
    return out.items;
}

// MARK: - the check on an answer

const Check = struct {
    arena: std.heap.ArenaAllocator,
    m: *ai.Ai,
    serial: u64,
    chat_id: Uuid,
    turn_id: Uuid,
    answer: []const u8,
    shared: page.Read,
    found: []const []const u8 = &.{},
};

/// The answer checked against every page it was given, off the main
/// thread; what it has that they don't is noted on its turn.
pub fn checkStrays(self: *Assistant, turn_id: Uuid, answer: []const u8, reads: []const page.Read) void {
    // Crosses threads: the C allocator.
    const c = std.heap.c_allocator.create(Check) catch return;
    c.* = .{ .arena = .init(std.heap.c_allocator), .m = self.m, .serial = self.serial, .chat_id = self.chat.id, .turn_id = turn_id, .answer = undefined, .shared = undefined };
    const a = c.arena.allocator();
    c.shared = joined(a, reads) catch return drop(c);
    c.answer = a.dupe(u8, answer) catch return drop(c);
    dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), c, checking);
}

fn joined(a: A, reads: []const page.Read) !page.Read {
    var titles: std.ArrayList([]const u8) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;
    var links: std.ArrayList([]const u8) = .empty;
    for (reads) |r| {
        try titles.append(a, r.title);
        try texts.append(a, r.text);
        for (r.links) |l| try links.append(a, try a.dupe(u8, l));
    }
    for (reads) |r| if (r.url) |u| try links.append(a, try a.dupe(u8, u));
    return .{ .title = try std.mem.join(a, "\n", titles.items), .url = null, .text = try std.mem.join(a, "\n", texts.items), .links = links.items, .cut = false };
}

fn drop(c: *Check) void {
    c.arena.deinit();
    std.heap.c_allocator.destroy(c);
}

fn checking(raw: ?*anyopaque) callconv(.c) void {
    const c: *Check = @ptrCast(@alignCast(raw.?));
    c.found = strays_mod.strays(c.arena.allocator(), c.answer, c.shared) catch &.{};
    if (c.found.len == 0) return drop(c);
    objc.dispatchMain(c, checked);
}

fn checked(raw: ?*anyopaque) callconv(.c) void {
    const c: *Check = @ptrCast(@alignCast(raw.?));
    defer drop(c);
    const self = c.m.assistant(c.serial) orelse return;
    self.edit(c.chat_id, c, noteStrays);
}

fn noteStrays(c: *Check, a: A, chat: *cs.Chat) !void {
    const list = try a.dupe(cs.Turn, chat.turns);
    for (list) |*t| if (t.id.eql(c.turn_id)) {
        t.strays = try json.clone(a, c.found);
    };
    chat.turns = list;
}
