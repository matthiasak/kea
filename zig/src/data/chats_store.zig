//! Ubi Chat's chats on disk (`Chats` in Chats.swift, the storage half):
//! `chats/index.json`, one row per chat, and `chats/<UUID>.json` per chat,
//! read when opened; at most eight chats are held in memory. Every file is
//! written with sorted keys, as Swift's `Chats.encoded` does. A private
//! tab's chat is never handed to this store (P9).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("json.zig");
const disk = @import("disk.zig");
const Store = @import("store.zig").Store;
const Uuid = json.Uuid;

pub const ChatPin = struct {
    id: Uuid,
    title: []const u8,
    url: []const u8,
    /// Kept on the chat, left out of what is sent (its eye).
    hidden: bool = false,
};

pub const Turn = struct {
    id: Uuid,
    question: []const u8,
    answer: []const u8 = "",
    done: bool = false,
    failed: ?[]const u8 = null,
    /// Addresses, emails and numbers in the answer the shared pages don't have.
    strays: []const []const u8 = &.{},
    /// Where it ran, as the assistant's place said when it was sent.
    place: []const u8 = "",
};

pub const Chat = struct {
    id: Uuid,
    title: []const u8 = "",
    touched: json.SwiftDate,
    starred: bool = false,
    task: bool = false,
    /// The page in front left out (the eye).
    pageHidden: bool = false,
    pins: []const ChatPin = &.{},
    turns: []const Turn = &.{},
    /// The model's summary of `turns[0..compacted]`; those turns stay, folded.
    summary: ?[]const u8 = null,
    compacted: ?i64 = null,

    /// The name, or the first question until the model names the chat.
    pub fn label(self: Chat) []const u8 {
        if (self.title.len > 0) return self.title;
        const first = if (self.turns.len > 0) prefix60(self.turns[0].question) else "";
        return if (first.len == 0) "Ubi Chat" else first;
    }
};

/// The first 60 characters, as `String.prefix(60)`.
// ponytail: counts code points, not grapheme clusters; a combined emoji near
// the 60th character can split differently from Swift.
fn prefix60(s: []const u8) []const u8 {
    var it = (std.unicode.Utf8View.init(s) catch return s[0..@min(s.len, 60)]).iterator();
    var n: usize = 0;
    while (n < 60) : (n += 1) _ = it.nextCodepointSlice() orelse break;
    return s[0..it.i];
}

/// A row of the index.
pub const Entry = struct {
    id: Uuid,
    title: []const u8,
    touched: json.SwiftDate,
    starred: bool,
    task: bool,
    turns: i64,

    /// Borrows the chat's strings.
    pub fn of(chat: Chat) Entry {
        return .{ .id = chat.id, .title = chat.label(), .touched = chat.touched, .starred = chat.starred, .task = chat.task, .turns = @intCast(chat.turns.len) };
    }

    fn eql(a: Entry, b: Entry) bool {
        return a.id.eql(b.id) and std.mem.eql(u8, a.title, b.title) and a.touched == b.touched and
            a.starred == b.starred and a.task == b.task and a.turns == b.turns;
    }
};

pub const Chats = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    /// Owns `index`.
    index_arena: std.heap.ArenaAllocator,
    /// Newest first for chats made here.
    index: []const Entry = &.{},
    revision: u64 = 0,
    /// The chats held in memory, least recently used first; at most `held`.
    recent: std.ArrayList(std.json.Parsed(Chat)) = .empty,

    pub const folder = "chats";
    pub const index_file = "chats/index.json";
    pub const legacy = "chats.json";
    pub const held = 8;

    pub fn init(gpa: std.mem.Allocator, store: *Store) Chats {
        var self: Chats = .{ .gpa = gpa, .store = store, .index_arena = .init(gpa) };
        self.load();
        return self;
    }

    pub fn deinit(self: *Chats) void {
        for (self.recent.items) |p| p.deinit();
        self.recent.deinit(self.gpa);
        self.index_arena.deinit();
    }

    /// `chats/<UUID>.json`, on `buf`.
    pub fn fileName(buf: *[64]u8, id: Uuid) []const u8 {
        return std.fmt.bufPrint(buf, "chats/{f}.json", .{id}) catch unreachable;
    }

    /// The chat, read when it isn't held. Its strings stay valid until the
    /// next call that changes this store or reads another chat; `json.clone`
    /// it to keep it longer.
    pub fn chat(self: *Chats, id: Uuid) ?Chat {
        if (self.touch(id)) |hit| return hit;
        if (self.find(id) == null) return null;
        self.store.disk.drain();
        var buf: [64]u8 = undefined;
        const name = fileName(&buf, id);
        const bytes = self.store.readFile(name) orelse {
            self.drop(id);
            return null;
        };
        defer self.gpa.free(bytes);
        const parsed = json.decode(Chat, self.gpa, bytes) catch {
            self.store.quarantine(name);
            self.drop(id);
            return null;
        };
        return self.hold(parsed);
    }

    /// In its place, or first when new; `chat` may be one read from here.
    pub fn put(self: *Chats, chat_in: Chat) void {
        const parsed = own(self.gpa, chat_in) catch return;
        const c = self.hold(parsed);
        var buf: [64]u8 = undefined;
        if (json.encodeSorted(self.gpa, c)) |bytes| self.store.write(fileName(&buf, c.id), bytes, false) else |_| {}
        const entry = Entry.of(c);
        if (self.find(c.id)) |pos| {
            if (self.index[pos].eql(entry)) return;
            var list = self.gpa.dupe(Entry, self.index) catch return;
            defer self.gpa.free(list);
            list[pos] = entry;
            self.setIndex(list);
        } else {
            var list: std.ArrayList(Entry) = .empty;
            defer list.deinit(self.gpa);
            list.append(self.gpa, entry) catch return;
            list.appendSlice(self.gpa, self.index) catch return;
            self.setIndex(list.items);
        }
    }

    pub fn remove(self: *Chats, id: Uuid) void {
        self.forget(id);
        self.drop(id);
    }

    /// Every chat with no turns, gone; how many.
    pub fn sweepEmpty(self: *Chats) usize {
        var left: std.ArrayList(Entry) = .empty;
        defer left.deinit(self.gpa);
        var gone: usize = 0;
        for (self.index) |e| {
            if (e.turns == 0) {
                self.forget(e.id);
                gone += 1;
            } else left.append(self.gpa, e) catch return 0;
        }
        if (gone > 0) self.setIndex(left.items);
        return gone;
    }

    // MARK: inside

    fn find(self: *const Chats, id: Uuid) ?usize {
        for (self.index, 0..) |e, i| if (e.id.eql(id)) return i;
        return null;
    }

    /// The held chat moved to most recent, or null.
    fn touch(self: *Chats, id: Uuid) ?Chat {
        for (self.recent.items, 0..) |p, i| if (p.value.id.eql(id)) {
            const moved = self.recent.orderedRemove(i);
            self.recent.appendAssumeCapacity(moved);
            return moved.value;
        };
        return null;
    }

    /// `parsed` held as most recent, replacing any older copy and letting
    /// the least recent go past `held`.
    fn hold(self: *Chats, parsed: std.json.Parsed(Chat)) Chat {
        self.unhold(parsed.value.id);
        self.recent.append(self.gpa, parsed) catch {
            parsed.deinit();
            return .{ .id = parsed.value.id, .touched = 0 };
        };
        while (self.recent.items.len > held) self.recent.orderedRemove(0).deinit();
        return parsed.value;
    }

    fn unhold(self: *Chats, id: Uuid) void {
        for (self.recent.items, 0..) |p, i| if (p.value.id.eql(id)) {
            self.recent.orderedRemove(i).deinit();
            return;
        };
    }

    /// Out of memory and off disk, the index left for the caller.
    fn forget(self: *Chats, id: Uuid) void {
        self.unhold(id);
        var buf: [64]u8 = undefined;
        const path = self.store.file(fileName(&buf, id)) catch return;
        defer self.gpa.free(path);
        self.store.disk.remove(path);
    }

    /// The index without `id`, saved.
    fn drop(self: *Chats, id: Uuid) void {
        var left: std.ArrayList(Entry) = .empty;
        defer left.deinit(self.gpa);
        for (self.index) |e| if (!e.id.eql(id)) left.append(self.gpa, e) catch return;
        self.setIndex(left.items);
    }

    /// `list` (which may point into the old index) kept and saved.
    fn setIndex(self: *Chats, list: []const Entry) void {
        var next: std.heap.ArenaAllocator = .init(self.gpa);
        const copy = json.clone(next.allocator(), list) catch return next.deinit();
        self.index_arena.deinit();
        self.index_arena = next;
        self.index = copy;
        self.revision +%= 1;
        const bytes = json.encodeSorted(self.gpa, self.index) catch return;
        self.store.write(index_file, bytes, false);
    }

    fn load(self: *Chats) void {
        if (self.store.readFile(index_file)) |bytes| {
            defer self.gpa.free(bytes);
            if (json.decode([]const Entry, self.gpa, bytes)) |p| {
                defer p.deinit();
                self.index = json.clone(self.index_arena.allocator(), p.value) catch &.{};
                self.revision +%= 1;
                return;
            } else |_| {}
            self.store.quarantine(index_file);
            return self.rebuild();
        }
        if (self.store.readFile(legacy)) |bytes| {
            defer self.gpa.free(bytes);
            return self.migrate(bytes);
        }
        self.rebuild();
    }

    /// The old single `chats.json`, split into a file per chat and an index.
    fn migrate(self: *Chats, bytes: []const u8) void {
        const p = json.decode([]Chat, self.gpa, bytes) catch return self.store.quarantine(legacy);
        defer p.deinit();
        for (p.value) |*c| {
            if (c.turns.len > 0 and std.mem.eql(u8, c.title, prefix60(c.turns[0].question))) c.title = "";
        }
        const entries = self.gpa.alloc(Entry, p.value.len) catch return;
        defer self.gpa.free(entries);
        for (entries, p.value) |*e, c| e.* = Entry.of(c);
        self.index = json.clone(self.index_arena.allocator(), entries) catch return;
        self.revision +%= 1;
        var buf: [64]u8 = undefined;
        // A file that didn't land stops it here: chats.json stays for the
        // next launch, as when Swift's write throws.
        for (p.value) |c| {
            const out = json.encodeSorted(self.gpa, c) catch return;
            const name = fileName(&buf, c.id);
            self.store.write(name, out, true);
            self.gpa.free(self.store.readFile(name) orelse return);
        }
        const out = json.encodeSorted(self.gpa, entries) catch return;
        self.store.write(index_file, out, true);
        self.gpa.free(self.store.readFile(index_file) orelse return);
        const path = self.store.file(legacy) catch return;
        defer self.gpa.free(path);
        self.store.disk.remove(path);
    }

    /// The index again from the chat files, newest first.
    fn rebuild(self: *Chats) void {
        const dir = self.store.file(folder) catch return;
        defer self.gpa.free(dir);
        const a = self.index_arena.allocator();
        var built: std.ArrayList(Entry) = .empty;
        const pool = objc.Pool.push();
        defer pool.pop();
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        const names = objc.msg(?objc.Object, fm, "contentsOfDirectoryAtPath:error:", .{ objc.nsString(dir), @as(?*anyopaque, null) }) orelse return;
        const n = objc.msg(objc.NSUInteger, names, "count", .{});
        for (0..n) |i| {
            const name = objc.fromNSString(objc.msg(objc.Object, names, "objectAtIndex:", .{i}));
            if (!std.mem.endsWith(u8, name, ".json") or std.mem.eql(u8, name, "index.json")) continue;
            const path = std.fs.path.join(self.gpa, &.{ dir, name }) catch continue;
            defer self.gpa.free(path);
            const bytes = disk.read(self.gpa, path) orelse continue;
            defer self.gpa.free(bytes);
            const p = json.decode(Chat, self.gpa, bytes) catch {
                disk.quarantine(self.gpa, path);
                continue;
            };
            defer p.deinit();
            built.append(a, json.clone(a, Entry.of(p.value)) catch continue) catch continue;
        }
        std.mem.sort(Entry, built.items, {}, newestFirst);
        self.index = built.items;
        self.revision +%= 1;
        if (built.items.len > 0) {
            const out = json.encodeSorted(self.gpa, self.index) catch return;
            self.store.write(index_file, out, false);
        }
    }

    fn newestFirst(_: void, a: Entry, b: Entry) bool {
        if (a.touched != b.touched) return a.touched > b.touched;
        return std.mem.order(u8, &a.id.string(), &b.id.string()) == .lt;
    }
};

/// `c` deep-copied into a `Parsed` of its own.
fn own(gpa: std.mem.Allocator, c: Chat) !std.json.Parsed(Chat) {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    return .{ .arena = arena, .value = try json.clone(arena.allocator(), c) };
}

test {
    _ = @import("chats_store_tests.zig");
}
