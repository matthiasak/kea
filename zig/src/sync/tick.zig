//! One round with the store (`tick` in Sync.swift): note what changed here,
//! find every Mac's newest commit that reads (past a damaged head or
//! commit), take in the trees that changed (tick_merge.zig), write this
//! Mac's commit when anything did, empty the inbox. On Sync's queue (tests:
//! the caller's thread); the app's stores only through `onMain`.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const core = @import("core.zig");
const kinds = @import("kinds.zig");
const keyring = @import("keyring.zig");
const dag = @import("dag.zig");
const dw = @import("dag_write.zig");
const inspect = @import("inspect.zig");
const merge = @import("tick_merge.zig");
const Drop = @import("drop.zig").Drop;
const sync_mod = @import("sync.zig");
const ops = @import("sync_ops.zig");
const drive = @import("sync_drive.zig");
const Sync = sync_mod.Sync;
const onMain = sync_mod.onMain;

const Allocator = std.mem.Allocator;
const SwiftDate = json.SwiftDate;
const Kind = kinds.Kind;

pub const importLegacyV1 = merge.importLegacyV1;

/// `DecodingError`'s words.
const unreadable = "The data couldn't be read because it isn't in the correct format.";
const replaced = "This sync store was replaced on another Mac — unlock it again";

pub const Snap = struct {
    place: sync_mod.Place,
    kinds: sync_mod.Kinds,
    subkeys: ?keyring.Subkeys,
    ring: ?[]const u8,
    drop: ?Drop,
    device: json.Uuid,
    name: []const u8,
};

pub fn snapshot(s: *Sync, a: Allocator) Snap {
    return .{
        .place = s.place,
        .kinds = s.kinds,
        .subkeys = s.subkeys,
        .ring = if (s.ring_json) |r| a.dupe(u8, r) catch null else null,
        .drop = if (s.place != .off and s.subkeys != null) s.drop() else null,
        .device = s.device,
        .name = a.dupe(u8, s.name) catch "Mac",
    };
}

fn say(s: *Sync, text: []const u8) void {
    onMain(void, Sync.setStatus, .{ s, text });
}

/// One round. `verify`: this Mac's packs read back; `repair`: every
/// record written again besides.
pub fn tick(s: *Sync, verify: bool, repair: bool) void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const snap = onMain(Snap, snapshot, .{ s, a });
    if (snap.place == .off) return say(s, "Off");
    const sk = snap.subkeys orelse return say(s, "Type the passphrase");
    var d = snap.drop orelse return say(s, switch (snap.place) {
        .drive => if (onMain(bool, signedIn, .{s})) "Choose a Google Drive folder" else "Sign in to Google Drive",
        .bucket => "Set up the bucket",
        else => "Choose a folder",
    });
    defer d.deinit();
    defer drive.keepTokens(s, &d);
    round(s, a, &d, &sk, &snap, verify, repair) catch |e| switch (e) {
        error.Replaced => onMain(void, lost, .{ s, replaced }),
        error.NoKeyring => onMain(void, lost, .{ s, ops.store_damaged }),
        else => say(s, switch (e) {
            error.SyncFailed => d.why,
            error.Damaged => core.damaged,
            error.OutOfMemory => "Out of memory",
            else => unreadable,
        }),
    };
}

fn signedIn(s: *Sync) bool {
    return s.drive_refresh != null;
}

/// The store isn't this key's any more, or has no keyring: looked at again
/// for Settings, which says what can be done.
fn lost(s: *Sync, why: []const u8) void {
    if (std.mem.eql(u8, why, replaced)) s.forgetKey() else s.ready = false;
    s.setStatus(why);
    if (s.drop()) |d| s.post(.{ .inspect = d });
}

/// The keyring every head carries: the one in hand, else the store's
/// (checked against this key, and written again where it went missing).
fn ensureRing(s: *Sync, a: Allocator, d: *Drop, sk: *const keyring.Subkeys, have: ?[]const u8, recheck: bool) !keyring.Keyring {
    if (have) |bytes| if (!recheck) if (json.decode(keyring.Keyring, a, bytes)) |r| return r.value else |_| {};
    const found = (try inspect.findKeyring(a, d)) orelse return error.NoKeyring;
    if (!std.mem.eql(u8, found.ring.key_id, &sk.key_id)) return error.Replaced;
    keyring.verifyWithSubkeys(a, &found.ring, sk) catch return error.NoKeyring;
    const bytes = try json.encodeSorted(a, found.ring);
    if (found.source != .primary) {
        try d.put(a, inspect.keyring_path, bytes);
        try d.put(a, inspect.keyring_bak_path, bytes);
    }
    onMain(void, ops.setRing, .{ s, bytes });
    return found.ring;
}

pub fn sortedKeys(a: Allocator, keys: []const []const u8) ![]const []const u8 {
    const out = try a.dupe([]const u8, keys);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out;
}

/// A Mac's newest commit: as last round when its head hasn't changed.
fn resolve(s: *Sync, a: Allocator, d: *Drop, sk: *const keyring.Subkeys, id: json.Uuid, self: json.Uuid, at: SwiftDate, health: *dag.Health) !?dag.Resolved {
    if (s.peer_heads.get(id)) |ph| if (ph.at == at) if (s.cache.commits.getPtr(&ph.oid)) |p|
        return .{ .oid = try a.dupe(u8, &ph.oid), .commit = &p.value, .head = null };
    const hint = if (id.eql(self)) s.state.value.head else "";
    const r = dag.resolve(a, d, sk, &s.cache, id, self, true, hint, health) catch |e| switch (e) {
        // A head left from another store.
        error.WrongKey => {
            health.damaged_objects += 1;
            return null;
        },
        else => |x| return x,
    };
    _ = s.peer_heads.swapRemove(id);
    if (r) |got| if (got.head) |h| if (std.mem.eql(u8, h.head, got.oid)) {
        try s.peer_heads.put(s.gpa, id, .{ .at = at, .oid = got.oid[0..64].* });
    };
    return r;
}

fn round(s: *Sync, a: Allocator, d: *Drop, sk: *const keyring.Subkeys, snap: *const Snap, verify_asked: bool, repair: bool) !void {
    const now = json.now();
    _ = s.takePending();
    s.rounds +%= 1;
    const verify = verify_asked or s.rounds % 10 == 0;
    if (s.state.value.joined) try merge.stampAll(s, a, snap, now);
    var health: dag.Health = .{};

    const heads = try d.list(a, dag.heads_prefix);
    const own_listed = heads.contains(try dag.headPath(a, snap.device));
    // This Mac's head gone though it wrote one: is this still its store?
    const ring = try ensureRing(s, a, d, sk, snap.ring, !own_listed and s.state.value.head.len > 0);

    var own: ?dag.Resolved = null;
    var peers: std.ArrayList(merge.Peer) = .empty;
    for (try sortedKeys(a, heads.keys())) |name| {
        if (!std.mem.endsWith(u8, name, ".head")) continue;
        const id = json.Uuid.parse(name[dag.heads_prefix.len .. name.len - ".head".len]) catch continue;
        const r = (try resolve(s, a, d, sk, id, snap.device, heads.get(name).?, &health)) orelse continue;
        if (id.eql(snap.device)) own = r else try peers.append(a, .{ .id = id, .r = r });
    }
    if (!own_listed and s.state.value.head.len > 0)
        own = try dag.resolve(a, d, sk, &s.cache, snap.device, snap.device, false, s.state.value.head, &health);

    var all: std.ArrayList(*const dag.Commit) = .empty;
    if (own) |o| try all.append(a, o.commit);
    for (peers.items) |p| try all.append(a, p.r.commit);

    var taken: std.ArrayList([]const u8) = .empty;
    for (peers.items) |p| {
        try merge.peer(s, a, d, sk, snap, p, all.items, &health, now);
        try taken.append(a, p.r.oid);
    }

    if (!s.state.value.joined) {
        try merge.stampAll(s, a, snap, now);
        s.state.value.joined = true;
    }

    if (own) |o| if (verify) try dw.verifyOwn(a, d, sk, &s.cache, o.commit, &health);
    const known = if (repair) dw.Known.empty else try dw.known(a, all.items, &health);
    var draft: dw.Draft = .{};
    try fill(s, a, sk, snap, &known, &draft, own, &health, now);
    const force = repair or health.heal_head or own == null;
    const published = try dw.publish(a, d, sk, &s.cache, &draft, .{ .device = snap.device, .name = snap.name, .ring = ring, .prev = own, .merged = taken.items, .now = now }, force);
    if (published) |oid| s.state.value.head = try s.state.arena.allocator().dupe(u8, oid);
    if (verify) s.cache.trim(a, dag.most_objects);

    if (verify and health.damaged() == 0) prune: {
        // Every Mac's newest, this one's as just written: what they reach stays.
        var tips: std.ArrayList(dag.Link) = .empty;
        if (published) |oid| {
            const c = dag.loadCommit(a, d, sk, &s.cache, oid) catch break :prune;
            try tips.append(a, .{ .oid = oid, .commit = c });
        } else if (own) |o| try tips.append(a, o.link());
        for (peers.items) |p| try tips.append(a, p.r.link());
        _ = dw.prune(a, d, sk, &s.cache, tips.items, now) catch |e| if (e != error.SyncFailed) return e;
    }

    try drainInbox(s, a, d, sk, snap.device);

    var da: std.heap.ArenaAllocator = .init(s.gpa);
    const devices = devicesSeen(s, da.allocator(), now) catch |e| {
        da.deinit();
        return e;
    };
    onMain(void, publish, .{ s, da, devices });

    const note: []const u8 = if (health.damaged() > 0 or health.recovered_from_ancestor)
        try std.fmt.allocPrint(a, "Recovered using ancestor DAG — {d} damaged remote object(s) skipped/repaired", .{@max(health.damaged(), 1)})
    else
        "";
    onMain(void, Sync.setDamagedNote, .{ s, note });
    say(s, try std.fmt.allocPrint(a, "Synced {s}", .{try relative(a, now)}));
    s.saveState(s.inline_jobs);
    if (s.inline_jobs) s.kea.store.disk.drain();
}

fn records(s: *Sync, kind: Kind, a: Allocator) !core.Records {
    return onMain(anyerror!core.Records, kinds.records, .{ s, kind, a });
}

/// This Mac's history doc, encoded while the visits it borrows hold.
fn historyDoc(s: *Sync, a: Allocator) ![]u8 {
    const st = &s.state.value;
    return json.encodeSorted(a, kinds.HistoryDoc{ .visits = try s.kea.history.exported(a), .cleared = st.cleared, .forgot = st.forgot });
}

/// `own`'s entry for a kind's "doc", when its pack still reads.
fn ownDoc(own: ?dag.Resolved, kind: []const u8, health: *const dag.Health, a: Allocator) !?dag.EntryRef {
    const o = own orelse return null;
    const t = o.commit.trees.map.get(kind) orelse return null;
    const e = t.entries.map.get("doc") orelse return null;
    return if (health.bad_packs.contains(try dag.packPath(a, e.pack))) null else e;
}

/// Everything this Mac holds, into the draft: each record at its mark's
/// time, history (when it changed: now), and its tabs (rewritten when they
/// change, or every ten minutes so other Macs see it's there).
fn fill(s: *Sync, a: Allocator, sk: *const keyring.Subkeys, snap: *const Snap, known: *const dw.Known, draft: *dw.Draft, own: ?dag.Resolved, health: *const dag.Health, now: SwiftDate) !void {
    for (kinds.record_kinds) |kind| if (snap.kinds.contains(kind)) {
        const current = try records(s, kind, a);
        const doc = try core.doc(a, &current, try merge.ledgerFor(s, kind), now);
        var it = doc.records.map.iterator();
        while (it.next()) |e| try draft.put(a, sk, known, @tagName(kind), e.key_ptr.*, e.value_ptr.data.bytes, e.value_ptr.at);
        (try draft.tree(a, @tagName(kind))).gone = doc.gone;
    };

    if (snap.kinds.contains(.history)) {
        const forgot = &s.state.value.forgot.map;
        var i: usize = 0;
        while (i < forgot.count()) {
            if (forgot.values()[i] < now - core.keep_gone) forgot.swapRemoveAt(i) else i += 1;
        }
        const plain = try onMain(anyerror![]u8, historyDoc, .{ s, a });
        const was = try ownDoc(own, "history", health, a);
        const same = if (was) |w| std.mem.eql(u8, w.oid, &keyring.oidOf(sk, plain)) else false;
        try draft.put(a, sk, known, "history", "doc", plain, if (same) was.?.at else now);
    }

    const windows: []const []const kinds.SyncTab = if (snap.kinds.contains(.tabs))
        try onMain(anyerror![]const []const kinds.SyncTab, kinds.windows, .{ s, a })
    else
        &.{};
    var check: std.ArrayList(u8) = .empty;
    try check.appendSlice(a, try json.encodeSorted(a, windows));
    try check.appendSlice(a, snap.name);
    const tabs_hash = core.hash(check.items);
    const same = if (s.tabs_hash) |h| std.mem.eql(u8, &h, &tabs_hash) else false;
    if (same and now - s.last_tabs_write < 600) if (try ownDoc(own, "tabs", health, a)) |e| if (known.contains(e.oid)) {
        return (try draft.tree(a, "tabs")).entries.map.put(a, "doc", e);
    };
    const plain = try json.encodeSorted(a, kinds.TabsDoc{ .name = snap.name, .at = now, .windows = windows });
    try draft.put(a, sk, known, "tabs", "doc", plain, now);
    s.tabs_hash = tabs_hash;
    s.last_tabs_write = now;
}

/// Pages sent here from another Mac, opened, and the inbox emptied; one
/// that doesn't open is let go.
fn drainInbox(s: *Sync, a: Allocator, d: *Drop, sk: *const keyring.Subkeys, device: json.Uuid) !void {
    const inbox = try d.list(a, try dag.inboxPrefix(a, device));
    for (try sortedKeys(a, inbox.keys())) |item| {
        if (try d.get(a, item)) |sealed| if (keyring.openObject(a, sealed, sk.*, item)) |plain| {
            if (json.decode(kinds.SentTab, a, plain)) |sent| {
                if (kinds.webAddress(sent.value.url)) onMain(void, kinds.openSent, .{ s, sent.value });
            } else |_| {}
        } else |_| {};
        d.delete(a, item) catch {};
    }
}

/// Other Macs heard from within 30 days, newest first; on `da`.
fn devicesSeen(s: *Sync, da: Allocator, now: SwiftDate) ![]const sync_mod.Device {
    var list: std.ArrayList(sync_mod.Device) = .empty;
    for (s.others.keys(), s.others.values()) |id, p| {
        const doc = p.value;
        if (doc.at < now - 30 * 86_400) continue;
        var pages: std.ArrayList(sync_mod.Device.Page) = .empty;
        for (doc.windows) |w| for (w) |t| if (kinds.webAddress(t.url))
            try pages.append(da, .{ .title = try da.dupe(u8, t.title), .url = try da.dupe(u8, t.url) });
        try list.append(da, .{ .id = id, .name = try da.dupe(u8, doc.name), .seen = doc.at, .pages = pages.items });
    }
    std.mem.sort(sync_mod.Device, list.items, {}, struct {
        fn newer(_: void, x: sync_mod.Device, y: sync_mod.Device) bool {
            return x.seen > y.seen;
        }
    }.newer);
    return list.items;
}

fn publish(s: *Sync, da: std.heap.ArenaAllocator, devices: []const sync_mod.Device) void {
    s.devices_arena.deinit();
    s.devices_arena = da;
    s.devices = devices;
    for (s.kea.browsers.items) |b| b.redraw();
}

/// `RelativeDateTimeFormatter().localizedString(for:relativeTo: Date())`.
pub fn relative(a: Allocator, date: SwiftDate) ![]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const f = objc.msg(objc.Object, objc.class("NSRelativeDateTimeFormatter"), "new", .{});
    defer objc.release(f);
    const when = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceReferenceDate:", .{date});
    const now = objc.msg(objc.Object, objc.class("NSDate"), "date", .{});
    return a.dupe(u8, objc.fromNSString(objc.msg(objc.Object, f, "localizedStringForDate:relativeToDate:", .{ when, now })));
}
