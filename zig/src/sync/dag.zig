//! The v2 store as a Merkle DAG, every object sealed and path-bound by
//! keyring.zig: immutable packs of records (`kea/v2/packs/<oid>.pack`),
//! immutable commits naming which pack holds each record
//! (`kea/v2/commits/<oid>.commit`), and one mutable head per Mac
//! (`kea/v2/heads/<uuid>.head`) carrying the keyring and its newest commit.
//! A damaged head falls back to the commits it lists, then to a scan; a
//! damaged pack to another copy of the record, then to an older version —
//! never the whole round. Writing: dag_write.zig.
const std = @import("std");
const json = @import("../data/json.zig");
const core = @import("core.zig");
const keyring = @import("keyring.zig");
const Drop = @import("drop.zig").Drop;

const Allocator = std.mem.Allocator;
const SwiftDate = json.SwiftDate;
const Subkeys = keyring.Subkeys;

pub const heads_prefix = "kea/v2/heads/";
pub const commits_prefix = "kea/v2/commits/";
pub const packs_prefix = "kea/v2/packs/";

pub const PackRecord = struct { oid: []const u8, data: core.Bytes };
pub const PackDoc = struct { version: u8 = 2, records: []const PackRecord };
pub const EntryRef = struct { oid: []const u8, pack: []const u8, at: SwiftDate, size: u32 };
pub const KindTree = struct {
    entries: json.Map(EntryRef) = .{},
    gone: json.Map(SwiftDate) = .{},
    tree_hash: []const u8 = "",
};
pub const Commit = struct {
    version: u8 = 2,
    device: json.Uuid,
    device_name: []const u8,
    seq: u64,
    at: SwiftDate,
    /// This Mac's previous commit, then the other Macs' heads it took in; 8 at most.
    parents: []const []const u8 = &.{},
    /// Each record kind, "history" and "tabs" (their one record: "doc").
    trees: json.Map(KindTree) = .{},
    root_hash: []const u8 = "",
};
pub const HeadDoc = struct {
    head: []const u8,
    /// Recent commits before it, newest first; 8 at most.
    prev: []const []const u8 = &.{},
    seq: u64,
    at: SwiftDate,
    root_hash: []const u8,
};
/// A head file: the keyring in the clear (a copy survives with every
/// head), the head itself sealed.
pub const HeadFile = struct { keyring: keyring.Keyring, sealed_head: core.Bytes };

pub fn isOid(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return false;
    return true;
}

pub fn packPath(a: Allocator, oid: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}.pack", .{ packs_prefix, oid });
}

pub fn commitPath(a: Allocator, oid: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}.commit", .{ commits_prefix, oid });
}

pub fn headPath(a: Allocator, id: json.Uuid) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{f}.head", .{ heads_prefix, id });
}

pub fn inboxPrefix(a: Allocator, to: json.Uuid) ![]u8 {
    return std.fmt.allocPrint(a, "kea/v2/inbox/{f}/", .{to});
}

/// `<prefix><oid><ext>` → oid, when it is one.
pub fn oidIn(name: []const u8, prefix: []const u8, ext: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, ext)) return null;
    const oid = name[prefix.len .. name.len - ext.len];
    return if (isOid(oid)) oid else null;
}

fn sortedKeys(a: Allocator, keys: []const []const u8) ![]const []const u8 {
    const out = try a.dupe([]const u8, keys);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out;
}

/// BLAKE3 over the sorted (key, oid, at) and (gone key, at).
pub fn treeHash(a: Allocator, tree: *const KindTree) ![64]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    for (try sortedKeys(a, tree.entries.map.keys())) |k| {
        const e = tree.entries.map.get(k).?;
        for ([_][]const u8{ k, "\x00", e.oid, "\x00", std.mem.asBytes(&e.at) }) |part| h.update(part);
    }
    h.update("\x01");
    for (try sortedKeys(a, tree.gone.map.keys())) |k| {
        for ([_][]const u8{ k, "\x00", std.mem.asBytes(&tree.gone.map.get(k).?) }) |part| h.update(part);
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d, .lower);
}

/// BLAKE3 over the sorted (kind, tree hash).
pub fn rootHash(a: Allocator, trees: *const json.Map(KindTree)) ![64]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    for (try sortedKeys(a, trees.map.keys())) |k| {
        for ([_][]const u8{ k, "\x00", trees.map.get(k).?.tree_hash, "\x00" }) |part| h.update(part);
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.fmt.bytesToHex(d, .lower);
}

/// Every name in it an object id, every hash what it says.
fn sound(a: Allocator, c: *const Commit) !bool {
    for (c.parents) |p| if (!isOid(p)) return false;
    for (c.trees.map.values()) |*t| {
        for (t.entries.map.values()) |e| if (!isOid(e.oid) or !isOid(e.pack)) return false;
        if (!std.mem.eql(u8, &try treeHash(a, t), t.tree_hash)) return false;
    }
    return std.mem.eql(u8, &try rootHash(a, &c.trees), c.root_hash);
}

/// What the round learned about damage, on its arena.
pub const Health = struct {
    damaged_records: usize = 0,
    damaged_objects: usize = 0,
    recovered_from_ancestor: bool = false,
    /// This Mac's head was missing or damaged: write it again.
    heal_head: bool = false,
    bad_packs: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn badPack(h: *Health, a: Allocator, name: []const u8) !void {
        const gop = try h.bad_packs.getOrPut(a, name);
        if (gop.found_existing) return;
        gop.key_ptr.* = try a.dupe(u8, name);
        h.damaged_objects += 1;
    }

    pub fn damaged(h: *const Health) usize {
        return h.damaged_objects + h.damaged_records;
    }
};

/// Kept between rounds (Sync's queue): commits never change, and records
/// on this Mac's disk by oid.
pub const Cache = struct {
    gpa: Allocator,
    commits: std.StringHashMapUnmanaged(std.json.Parsed(Commit)) = .empty,
    /// Packs this Mac read back intact, by name, at the time listed then.
    checked: std.StringHashMapUnmanaged(SwiftDate) = .empty,
    /// `<oid[0..2]>/<oid>` → the record's bytes; null keeps none.
    objects: ?Drop = null,

    pub fn reset(self: *Cache) void {
        var it = self.commits.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.commits.clearRetainingCapacity();
        var ck = self.checked.keyIterator();
        while (ck.next()) |k| self.gpa.free(k.*);
        self.checked.clearRetainingCapacity();
    }

    pub fn deinit(self: *Cache) void {
        self.reset();
        self.commits.deinit(self.gpa);
        self.checked.deinit(self.gpa);
        if (self.objects) |*o| o.deinit();
    }

    pub fn markChecked(self: *Cache, name: []const u8, at: SwiftDate) !void {
        const gop = try self.checked.getOrPut(self.gpa, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.gpa.dupe(u8, name);
        gop.value_ptr.* = at;
    }

    /// A record kept here, read back only when it still hashes to `oid`.
    pub fn object(self: *Cache, a: Allocator, sk: *const Subkeys, oid: []const u8) ?[]const u8 {
        const o = if (self.objects) |*o| o else return null;
        const name = std.fmt.allocPrint(a, "{s}/{s}", .{ oid[0..2], oid }) catch return null;
        const bytes = (o.get(a, name) catch return null) orelse return null;
        return if (std.mem.eql(u8, &keyring.oidOf(sk, bytes), oid)) bytes else null;
    }

    pub fn keep(self: *Cache, a: Allocator, oid: []const u8, bytes: []const u8) void {
        const o = if (self.objects) |*o| o else return;
        const name = std.fmt.allocPrint(a, "{s}/{s}", .{ oid[0..2], oid }) catch return;
        o.put(a, name, bytes) catch {};
    }

    /// The records kept here longest let go, past `most`.
    pub fn trim(self: *Cache, a: Allocator, most: usize) void {
        const o = if (self.objects) |*o| o else return;
        const names = o.list(a, "") catch return;
        if (names.count() <= most) return;
        const Ctx = struct {
            at: []const SwiftDate,
            pub fn lessThan(c: @This(), x: usize, y: usize) bool {
                return c.at[x] < c.at[y];
            }
        };
        const order = a.alloc(usize, names.count()) catch return;
        for (order, 0..) |*i, n| i.* = n;
        std.mem.sort(usize, order, Ctx{ .at = names.values() }, Ctx.lessThan);
        for (order[0 .. names.count() - most]) |i| o.delete(a, names.keys()[i]) catch {};
    }
};

/// Records kept on this Mac at most (`Cache.objects`).
pub const most_objects = 2000;

pub const ReadError = error{ WrongKey, Damaged, SyncFailed, OutOfMemory };

/// The object at `path`, opened; `Damaged` when missing.
pub fn fetch(a: Allocator, d: *Drop, sk: *const Subkeys, path: []const u8) ReadError![]u8 {
    const wire = (try d.get(a, path)) orelse return error.Damaged;
    return keyring.openObject(a, wire, sk.*, path);
}

/// A commit by oid: from the cache, or read, checked and kept there.
pub fn loadCommit(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *Cache, oid: []const u8) ReadError!*const Commit {
    if (cache.commits.getPtr(oid)) |p| return &p.value;
    if (!isOid(oid)) return error.Damaged;
    const plain = try fetch(a, d, sk, try commitPath(a, oid));
    if (!std.mem.eql(u8, &keyring.oidOf(sk, plain), oid)) return error.Damaged;
    var parsed = json.decode(Commit, cache.gpa, plain) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Damaged;
    if (!(sound(a, &parsed.value) catch false)) {
        parsed.deinit();
        return error.Damaged;
    }
    const key = cache.gpa.dupe(u8, oid) catch {
        parsed.deinit();
        return error.OutOfMemory;
    };
    cache.commits.put(cache.gpa, key, parsed) catch {
        cache.gpa.free(key);
        parsed.deinit();
        return error.OutOfMemory;
    };
    return &cache.commits.getPtr(oid).?.value;
}

/// A Mac's head file, its head opened; null when it has none.
pub fn readHead(a: Allocator, d: *Drop, sk: *const Subkeys, id: json.Uuid) ReadError!?HeadDoc {
    const path = try headPath(a, id);
    const bytes = (try d.get(a, path)) orelse return null;
    const file = json.decode(HeadFile, a, bytes) catch return error.Damaged;
    const plain = try keyring.openObject(a, file.value.sealed_head.bytes, sk.*, path);
    const head = json.decode(HeadDoc, a, plain) catch return error.Damaged;
    if (!isOid(head.value.head)) return error.Damaged;
    return head.value;
}

/// The keyring a head file carries, unchecked; null when it isn't one.
pub fn headKeyring(a: Allocator, bytes: []const u8) ?keyring.Keyring {
    const file = json.decode(HeadFile, a, bytes) catch return null;
    return file.value.keyring;
}

pub const Resolved = struct {
    oid: []const u8,
    commit: *const Commit,
    head: ?HeadDoc,

    pub fn link(r: Resolved) Link {
        return .{ .oid = r.oid, .commit = r.commit, .also = if (r.head) |h| h.prev else &.{} };
    }
};

fn usable(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *Cache, oid: []const u8, peer: json.Uuid, health: *Health) ReadError!?*const Commit {
    const c = loadCommit(a, d, sk, cache, oid) catch |e| switch (e) {
        error.Damaged => {
            health.damaged_objects += 1;
            return null;
        },
        else => return e,
    };
    return if (c.device.eql(peer)) c else null;
}

/// A Mac's newest commit that reads intact: its head's, else one its head
/// lists, else `hint` (this Mac's last), else the highest of its commits
/// found by a scan. `listed`: it has a head file.
pub fn resolve(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *Cache, peer: json.Uuid, self: json.Uuid, listed: bool, hint: []const u8, health: *Health) ReadError!?Resolved {
    var head: ?HeadDoc = null;
    if (listed) head = readHead(a, d, sk, peer) catch |e| switch (e) {
        error.Damaged => blk: {
            health.damaged_objects += 1;
            break :blk null;
        },
        else => return e,
    };
    if (head) |h| {
        if (try usable(a, d, sk, cache, h.head, peer, health)) |c| return .{ .oid = h.head, .commit = c, .head = h };
        for (h.prev) |p| if (isOid(p)) if (try usable(a, d, sk, cache, p, peer, health)) |c| {
            health.recovered_from_ancestor = true;
            if (peer.eql(self)) health.heal_head = true;
            return .{ .oid = p, .commit = c, .head = null };
        };
    }
    if (!listed and hint.len == 0) return null;
    const found = try recover(a, d, sk, cache, peer, hint, health);
    if (found != null) {
        health.recovered_from_ancestor = listed or health.recovered_from_ancestor;
        if (peer.eql(self)) health.heal_head = true;
    }
    return found;
}

fn recover(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *Cache, peer: json.Uuid, hint: []const u8, health: *Health) ReadError!?Resolved {
    if (isOid(hint)) if (try usable(a, d, sk, cache, hint, peer, health)) |c| return .{ .oid = hint, .commit = c, .head = null };
    var best: ?Resolved = null;
    const names = try d.list(a, commits_prefix);
    for (names.keys()) |name| {
        const oid = oidIn(name, commits_prefix, ".commit") orelse continue;
        const c = loadCommit(a, d, sk, cache, oid) catch |e| switch (e) {
            error.Damaged, error.WrongKey => continue,
            else => return e,
        };
        if (!c.device.eql(peer)) continue;
        if (best == null or c.seq > best.?.commit.seq) best = .{ .oid = try a.dupe(u8, oid), .commit = c, .head = null };
    }
    return best;
}

/// One record wanted from a tree.
pub const Want = struct { kind: []const u8, key: []const u8, ref: EntryRef };
pub const Got = struct { bytes: []const u8, at: SwiftDate };
pub const Loaded = std.StringArrayHashMapUnmanaged(Got);

/// Where else a record may be: the other commits read this round, and the
/// commit `want`s came from (its older versions).
pub const Fallback = struct { commits: []const *const Commit = &.{}, from: ?Link = null };

/// A pack's records, each checked against its oid and kept here; null —
/// and the pack noted bad — when it is missing or damaged.
pub fn openPack(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *Cache, pack: []const u8, health: *Health) error{ SyncFailed, OutOfMemory }!?std.StringHashMapUnmanaged([]const u8) {
    const path = try packPath(a, pack);
    if (health.bad_packs.contains(path)) return null;
    const plain = fetch(a, d, sk, path) catch |e| switch (e) {
        error.SyncFailed, error.OutOfMemory => |x| return x,
        error.WrongKey, error.Damaged => {
            try health.badPack(a, path);
            return null;
        },
    };
    const doc = json.decode(PackDoc, a, plain) catch {
        try health.badPack(a, path);
        return null;
    };
    var out: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (!std.mem.eql(u8, &keyring.oidOf(sk, plain), pack)) {
        try health.badPack(a, path);
        return null;
    }
    for (doc.value.records) |r| {
        if (!isOid(r.oid) or !std.mem.eql(u8, &keyring.oidOf(sk, r.data.bytes), r.oid)) {
            try health.badPack(a, path);
            return null;
        }
        try out.put(a, r.oid, r.data.bytes);
        cache.keep(a, r.oid, r.data.bytes);
    }
    return out;
}

fn fromPack(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *Cache, ref: EntryRef, health: *Health) !?[]const u8 {
    if (cache.object(a, sk, ref.oid)) |b| return b;
    const records = (try openPack(a, d, sk, cache, ref.pack, health)) orelse return null;
    return records.get(ref.oid);
}

/// Each want's bytes: kept here, else from its pack, else another pack
/// with the same record, else the newest older version that reads. What
/// can't be had is counted in `health` and left out.
pub fn loadEntries(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *Cache, wants: []const Want, fb: Fallback, health: *Health) !Loaded {
    var out: Loaded = .empty;
    var missing: std.ArrayList(Want) = .empty;
    for (wants) |w| {
        if (try fromPack(a, d, sk, cache, w.ref, health)) |b| try out.put(a, w.key, .{ .bytes = b, .at = w.ref.at }) else try missing.append(a, w);
    }
    var ancestors: ?[]const Link = null;
    next: for (missing.items) |w| {
        for (fb.commits) |c| for (c.trees.map.values()) |t| for (t.entries.map.values()) |e| {
            if (!std.mem.eql(u8, e.oid, w.ref.oid) or std.mem.eql(u8, e.pack, w.ref.pack)) continue;
            if (try fromPack(a, d, sk, cache, e, health)) |b| {
                try out.put(a, w.key, .{ .bytes = b, .at = w.ref.at });
                continue :next;
            }
        };
        const from = fb.from orelse {
            health.damaged_records += 1;
            continue;
        };
        if (ancestors == null) ancestors = try lineage(a, d, sk, cache, from, 16);
        for (ancestors.?[1..]) |l| {
            const t = l.commit.trees.map.getPtr(w.kind) orelse continue;
            const e = t.entries.map.get(w.key) orelse continue;
            if (try fromPack(a, d, sk, cache, e, health)) |b| {
                try out.put(a, w.key, .{ .bytes = b, .at = e.at });
                health.recovered_from_ancestor = true;
                continue :next;
            }
        }
        health.damaged_records += 1;
    }
    return out;
}

/// A commit and its oid; `also`: more of its Mac's commits to look
/// through when its parents don't read (its head's `prev`).
pub const Link = struct { oid: []const u8, commit: *const Commit, also: []const []const u8 = &.{} };

/// `from` and its own Mac's commits before it, through parents and
/// `from.also`, newest first, `most` at most.
pub fn lineage(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *Cache, from: Link, most: usize) ![]const Link {
    var out: std.ArrayList(Link) = .empty;
    try out.append(a, from);
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.appendSlice(a, from.commit.parents);
    try queue.appendSlice(a, from.also);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    try seen.put(a, from.oid, {});
    var i: usize = 0;
    while (i < queue.items.len and out.items.len < most) : (i += 1) {
        const p = queue.items[i];
        if ((try seen.getOrPut(a, p)).found_existing) continue;
        const c = loadCommit(a, d, sk, cache, p) catch |e| switch (e) {
            error.Damaged, error.WrongKey => continue,
            else => |x| return x,
        };
        if (!c.device.eql(from.commit.device)) continue;
        try out.append(a, .{ .oid = p, .commit = c });
        try queue.appendSlice(a, c.parents);
    }
    std.mem.sort(Link, out.items, {}, struct {
        fn newer(_: void, x: Link, y: Link) bool {
            return x.commit.seq > y.commit.seq;
        }
    }.newer);
    return out.items;
}
