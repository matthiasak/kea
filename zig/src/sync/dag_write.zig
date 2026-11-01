//! This Mac's part of the DAG (dag.zig): a commit naming every record it
//! holds, the records no readable pack holds yet in one new pack, and its
//! head moved on — nothing at all when nothing changed. Also: checking its
//! own packs are still there and intact, and letting go of what nobody
//! points at any more.
const std = @import("std");
const json = @import("../data/json.zig");
const keyring = @import("keyring.zig");
const dag = @import("dag.zig");
const Drop = @import("drop.zig").Drop;

const Allocator = std.mem.Allocator;
const SwiftDate = json.SwiftDate;
const Subkeys = keyring.Subkeys;

/// oid → the pack that holds it.
pub const Known = std.StringHashMapUnmanaged([]const u8);

/// Which pack holds each record the commits name, bad packs left out.
pub fn known(a: Allocator, commits: []const *const dag.Commit, health: *const dag.Health) !Known {
    var out: Known = .empty;
    for (commits) |c| for (c.trees.map.values()) |t| for (t.entries.map.values()) |e| {
        if (out.contains(e.oid) or health.bad_packs.contains(try dag.packPath(a, e.pack))) continue;
        try out.put(a, e.oid, e.pack);
    };
    return out;
}

pub const Draft = struct {
    trees: json.Map(dag.KindTree) = .{},
    /// Records no readable pack holds yet: oid → bytes.
    fresh: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    pub fn tree(self: *Draft, a: Allocator, kind: []const u8) !*dag.KindTree {
        const gop = try self.trees.map.getOrPut(a, kind);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// `key`'s record in `kind`, in the pack that holds it or a new one.
    pub fn put(self: *Draft, a: Allocator, sk: *const Subkeys, k: *const Known, kind: []const u8, key: []const u8, bytes: []const u8, at: SwiftDate) !void {
        const oid = try a.dupe(u8, &keyring.oidOf(sk, bytes));
        const pack = k.get(oid) orelse blk: {
            try self.fresh.put(a, oid, bytes);
            break :blk "";
        };
        try (try self.tree(a, kind)).entries.map.put(a, key, .{ .oid = oid, .pack = pack, .at = at, .size = @intCast(@min(bytes.len, std.math.maxInt(u32))) });
    }
};

pub const Publish = struct {
    device: json.Uuid,
    name: []const u8,
    ring: keyring.Keyring,
    prev: ?dag.Resolved,
    /// Other Macs' heads taken in this round.
    merged: []const []const u8 = &.{},
    now: SwiftDate,
};

fn seal(a: Allocator, d: *Drop, sk: *const Subkeys, path: []const u8, plain: []const u8) !void {
    try d.put(a, path, try keyring.sealObject(a, plain, sk.*, path));
}

/// The draft's hashes made, then — when they differ from `prev`'s, or
/// `force` — the pack, the commit and the head written, in that order. The
/// new commit's oid, or null when nothing was written.
pub fn publish(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *dag.Cache, draft: *Draft, p: Publish, force: bool) !?[]const u8 {
    for (draft.trees.map.values()) |*t| t.tree_hash = try a.dupe(u8, &try dag.treeHash(a, t));
    const root = try dag.rootHash(a, &draft.trees);
    if (!force and draft.fresh.count() == 0) if (p.prev) |prev| if (std.mem.eql(u8, prev.commit.root_hash, &root)) return null;

    if (draft.fresh.count() > 0) {
        var records: std.ArrayList(dag.PackRecord) = .empty;
        var it = draft.fresh.iterator();
        while (it.next()) |e| try records.append(a, .{ .oid = e.key_ptr.*, .data = .{ .bytes = e.value_ptr.* } });
        std.mem.sort(dag.PackRecord, records.items, {}, struct {
            fn lt(_: void, x: dag.PackRecord, y: dag.PackRecord) bool {
                return std.mem.lessThan(u8, x.oid, y.oid);
            }
        }.lt);
        const plain = try json.encodeSorted(a, dag.PackDoc{ .records = records.items });
        const pack = try a.dupe(u8, &keyring.oidOf(sk, plain));
        try seal(a, d, sk, try dag.packPath(a, pack), plain);
        for (draft.trees.map.values()) |*t| for (t.entries.map.values()) |*e| if (e.pack.len == 0) {
            e.pack = pack;
        };
        for (records.items) |r| cache.keep(a, r.oid, r.data.bytes);
    }

    var parents: std.ArrayList([]const u8) = .empty;
    if (p.prev) |prev| try parents.append(a, prev.oid);
    for (p.merged) |m| if (parents.items.len < 8) try parents.append(a, m);
    const commit: dag.Commit = .{
        .device = p.device,
        .device_name = p.name,
        .seq = if (p.prev) |prev| prev.commit.seq + 1 else 1,
        .at = p.now,
        .parents = parents.items,
        .trees = draft.trees,
        .root_hash = &root,
    };
    const plain = try json.encodeSorted(a, commit);
    const oid = try a.dupe(u8, &keyring.oidOf(sk, plain));
    try seal(a, d, sk, try dag.commitPath(a, oid), plain);

    var prev_list: std.ArrayList([]const u8) = .empty;
    if (p.prev) |prev| {
        try prev_list.append(a, prev.oid);
        const older: []const []const u8 = if (prev.head) |h| h.prev else prev.commit.parents[0..@min(1, prev.commit.parents.len)];
        for (older) |o| if (prev_list.items.len < 8) try prev_list.append(a, o);
    }
    const head_path = try dag.headPath(a, p.device);
    const head = try json.encodeSorted(a, dag.HeadDoc{ .head = oid, .prev = prev_list.items, .seq = commit.seq, .at = p.now, .root_hash = &root });
    const file: dag.HeadFile = .{ .keyring = p.ring, .sealed_head = .{ .bytes = try keyring.sealObject(a, head, sk.*, head_path) } };
    try d.put(a, head_path, try json.encodeSorted(a, file));
    return oid;
}

/// The packs `own` names, each still listed and — when new or changed
/// since last read back — intact; the rest noted bad in `health`.
pub fn verifyOwn(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *dag.Cache, own: *const dag.Commit, health: *dag.Health) !void {
    const listed = try d.list(a, dag.packs_prefix);
    var done: std.StringHashMapUnmanaged(void) = .empty;
    for (own.trees.map.values()) |t| for (t.entries.map.values()) |e| {
        const path = try dag.packPath(a, e.pack);
        if ((try done.getOrPut(a, path)).found_existing) continue;
        const at = listed.get(path) orelse {
            try health.badPack(a, path);
            continue;
        };
        if (cache.checked.get(path)) |was| if (was == at) continue;
        if (try dag.openPack(a, d, sk, cache, e.pack, health) != null) try cache.markChecked(path, at);
    };
}

pub const keep_days = 14;
pub const keep_commits = 16;
pub const most_deleted = 16;

/// Commits and packs no Mac's recent commits reach, older than two weeks,
/// gone — 16 at most a round. `tips`: every Mac's newest commit. How many went.
pub fn prune(a: Allocator, d: *Drop, sk: *const Subkeys, cache: *dag.Cache, tips: []const dag.Link, now: SwiftDate) !usize {
    if (tips.len == 0) return 0;
    var commits: std.StringHashMapUnmanaged(void) = .empty;
    var packs: std.StringHashMapUnmanaged(void) = .empty;
    for (tips) |tip| for (try dag.lineage(a, d, sk, cache, tip, keep_commits)) |l| {
        try commits.put(a, l.oid, {});
        for (l.commit.trees.map.values()) |t| for (t.entries.map.values()) |e| try packs.put(a, e.pack, {});
    };
    const cutoff = now - keep_days * 86_400;
    var gone: usize = 0;
    for ([_]struct { []const u8, []const u8, *const std.StringHashMapUnmanaged(void) }{
        .{ dag.commits_prefix, ".commit", &commits },
        .{ dag.packs_prefix, ".pack", &packs },
    }) |set| {
        const names = try d.list(a, set[0]);
        for (names.keys(), names.values()) |name, at| {
            const oid = dag.oidIn(name, set[0], set[1]) orelse continue;
            if (set[2].contains(oid) or at >= cutoff) continue;
            if (gone >= most_deleted) return gone;
            try d.delete(a, name);
            gone += 1;
        }
    }
    return gone;
}
