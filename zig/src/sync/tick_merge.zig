//! Another Mac's commit, taken in (tick.zig): each tree that changed since
//! last round, only the records that could win fetched, weighed against
//! this Mac's ledger and put in place. A record that can't be had is
//! counted and the rest go on. Also: a v1 store's files, taken in once
//! when it is upgraded.
const std = @import("std");
const json = @import("../data/json.zig");
const core = @import("core.zig");
const kinds = @import("kinds.zig");
const keyring = @import("keyring.zig");
const dag = @import("dag.zig");
const Drop = @import("drop.zig").Drop;
const sync_mod = @import("sync.zig");
const tick = @import("tick.zig");
const Sync = sync_mod.Sync;
const onMain = sync_mod.onMain;

const Allocator = std.mem.Allocator;
const SwiftDate = json.SwiftDate;
const Kind = kinds.Kind;

pub const Peer = struct { id: json.Uuid, r: dag.Resolved };

/// The kind's ledger in `state`, made when missing. Valid until the next one is made.
pub fn ledgerFor(s: *Sync, kind: Kind) !*core.SyncLedger {
    const sa = s.state.arena.allocator();
    const gop = try s.state.value.ledgers.map.getOrPut(sa, @tagName(kind));
    if (!gop.found_existing) {
        gop.key_ptr.* = try sa.dupe(u8, @tagName(kind));
        gop.value_ptr.* = .{};
    }
    return gop.value_ptr;
}

fn records(s: *Sync, kind: Kind, a: Allocator) !core.Records {
    return onMain(anyerror!core.Records, kinds.records, .{ s, kind, a });
}

pub fn stampAll(s: *Sync, a: Allocator, snap: *const tick.Snap, now: SwiftDate) !void {
    for (kinds.record_kinds) |kind| if (snap.kinds.contains(kind)) {
        const current = try records(s, kind, a);
        try core.stamp(s.state.arena.allocator(), &current, try ledgerFor(s, kind), now);
    };
}

/// Another Mac's records put in place, its removals made (`Sync.applying`);
/// the keys whose records didn't decode.
fn applyTaken(s: *Sync, kind: Kind, taken: *const core.Taken, joining: bool, ledger: *core.SyncLedger, a: Allocator) !std.StringHashMapUnmanaged(void) {
    s.applying = true;
    defer s.applying = false;
    var skipped: std.StringHashMapUnmanaged(void) = .empty;
    for (try tick.sortedKeys(a, taken.put.map.keys())) |k|
        if (!try kinds.apply(s, kind, k, taken.put.map.get(k).?.data.bytes, joining, a)) try skipped.put(a, k, {});
    for (try tick.sortedKeys(a, taken.remove.map.keys())) |k| {
        kinds.removeRecord(s, kind, k);
        try core.removed(s.state.arena.allocator(), k, taken.remove.map.get(k).?, ledger);
    }
    return skipped;
}

/// What of `doc` wins here, put in place and settled in the ledger; how
/// many of its records didn't decode.
fn takeDoc(s: *Sync, a: Allocator, kind: Kind, doc: *const core.SyncDoc, now: SwiftDate) !usize {
    const ledger = try ledgerFor(s, kind);
    const taken = try core.take(a, doc, ledger);
    const skipped = try onMain(anyerror!std.StringHashMapUnmanaged(void), applyTaken, .{ s, kind, &taken, !s.state.value.joined, ledger, a });
    const after = try records(s, kind, a);
    var it = taken.put.map.iterator();
    while (it.next()) |e| if (!skipped.contains(e.key_ptr.*))
        try core.settle(s.state.arena.allocator(), e.key_ptr.*, after.get(e.key_ptr.*), e.value_ptr.*, ledger, now);
    return skipped.count();
}

fn applyHistory(s: *Sync, doc: kinds.HistoryDoc, a: Allocator) !void {
    return kinds.applyHistory(s, doc, a);
}

/// Another Mac's history or tabs doc taken in; false when it doesn't decode.
fn takePlain(s: *Sync, a: Allocator, kind: Kind, from: json.Uuid, plain: []const u8) !bool {
    switch (kind) {
        .history => {
            const doc = json.decode(kinds.HistoryDoc, a, plain) catch return false;
            try onMain(anyerror!void, applyHistory, .{ s, doc.value, a });
        },
        .tabs => {
            const doc = json.decode(kinds.TabsDoc, s.gpa, plain) catch return false;
            const gop = s.others.getOrPut(s.gpa, from) catch |e| {
                doc.deinit();
                return e;
            };
            if (gop.found_existing) gop.value_ptr.deinit();
            gop.value_ptr.* = doc;
        },
        else => unreachable,
    }
    return true;
}

fn remember(s: *Sync, key: []const u8, tree_hash: []const u8) !void {
    if (tree_hash.len != 64) return;
    const gop = try s.merged.getOrPut(s.gpa, key);
    if (!gop.found_existing) gop.key_ptr.* = try s.names.allocator().dupe(u8, key);
    gop.value_ptr.* = tree_hash[0..64].*;
}

/// Each of `p`'s trees that changed since last taken in. A tree read only
/// in part (damage, an older version) is tried again next round.
pub fn peer(s: *Sync, a: Allocator, d: *Drop, sk: *const keyring.Subkeys, snap: *const tick.Snap, p: Peer, all: []const *const dag.Commit, health: *dag.Health, now: SwiftDate) !void {
    var it = p.r.commit.trees.map.iterator();
    while (it.next()) |e| {
        const kind = std.meta.stringToEnum(Kind, e.key_ptr.*) orelse continue;
        if (kind != .tabs and !snap.kinds.contains(kind)) continue;
        const tree = e.value_ptr;
        const key = try std.fmt.allocPrint(a, "{f}/{s}", .{ p.id, e.key_ptr.* });
        if (s.merged.get(key)) |h| if (std.mem.eql(u8, &h, tree.tree_hash)) continue;

        var wants: std.ArrayList(dag.Want) = .empty;
        const record_kind = kind != .history and kind != .tabs;
        const ledger = if (record_kind) try ledgerFor(s, kind) else null;
        var ev = tree.entries.map.iterator();
        while (ev.next()) |entry| {
            const ref = entry.value_ptr.*;
            if (ledger) |l| {
                // Only what could win here: newer than ours, or as new.
                const mark = l.marks.map.get(entry.key_ptr.*);
                const mark_at = if (mark) |m| m.at else core.distant_past;
                const gone_at = l.gone.map.get(entry.key_ptr.*) orelse core.distant_past;
                if (!(ref.at > mark_at and ref.at > gone_at) and !(mark != null and ref.at == mark_at)) continue;
            }
            try wants.append(a, .{ .kind = e.key_ptr.*, .key = entry.key_ptr.*, .ref = ref });
        }
        const got = try dag.loadEntries(a, d, sk, &s.cache, wants.items, .{ .commits = all, .from = p.r.link() }, health);
        var whole = got.count() == wants.items.len;
        for (wants.items) |w| if (got.get(w.key)) |g| if (g.at != w.ref.at) {
            whole = false;
        };

        if (record_kind) {
            var doc: core.SyncDoc = .{ .gone = tree.gone };
            for (got.keys(), got.values()) |k, g| try doc.records.map.put(a, k, .{ .data = .{ .bytes = g.bytes }, .at = g.at });
            const bad = try takeDoc(s, a, kind, &doc, now);
            health.damaged_records += bad;
            if (bad > 0) whole = false;
        } else if (got.get("doc")) |g| {
            if (!try takePlain(s, a, kind, p.id, g.bytes)) {
                health.damaged_records += 1;
                whole = false;
            }
        }
        if (whole) try remember(s, key, tree.tree_hash);
    }
}

/// A v1 store's files (`kea/v1/devices/<uuid>/<kind>.kea`, sealed under
/// `k`), every other Mac's taken in as a joining Mac would; a file that
/// doesn't open is passed over.
pub fn importLegacyV1(s: *Sync, a: Allocator, d: *Drop, k: core.Key) !void {
    const prefix = "kea/v1/devices/";
    const snap = onMain(tick.Snap, tick.snapshot, .{ s, a });
    var dd = snap.drop;
    defer if (dd) |*x| x.deinit();
    const now = json.now();
    const names = try d.list(a, prefix);
    for (try tick.sortedKeys(a, names.keys())) |name| {
        var parts = std.mem.splitScalar(u8, name[prefix.len..], '/');
        const id_part = parts.next() orelse continue;
        const file = parts.next() orelse continue;
        if (parts.next() != null or !std.mem.endsWith(u8, file, ".kea")) continue;
        const other = json.Uuid.parse(id_part) catch continue;
        if (other.eql(snap.device)) continue;
        const kind = std.meta.stringToEnum(Kind, file[0 .. file.len - 4]) orelse continue;
        if (kind != .tabs and !snap.kinds.contains(kind)) continue;
        const sealed = (try d.get(a, name)) orelse continue;
        const plain = core.open(a, sealed, k) catch continue;
        switch (kind) {
            .history, .tabs => _ = try takePlain(s, a, kind, other, plain),
            else => {
                const doc = json.decode(core.SyncDoc, a, plain) catch continue;
                _ = try takeDoc(s, a, kind, &doc.value, now);
            },
        }
    }
}
