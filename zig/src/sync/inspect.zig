//! Before a place is used: what it holds — nothing, a Kea store (v2 or
//! v1), a damaged one, or someone else's files — so nothing is written
//! over blindly. And replacing a store: the new keyring staged and read
//! back, the old one's keys and heads archived under `kea/quarantine/<ts>/`,
//! everything put back if any step fails.
const std = @import("std");
const json = @import("../data/json.zig");
const keyring = @import("keyring.zig");
const dag = @import("dag.zig");
const Drop = @import("drop.zig").Drop;
const DropError = @import("drop.zig").Error;

const Allocator = std.mem.Allocator;

pub const keyring_path = "kea/v2/keyring.json";
pub const keyring_bak_path = "kea/v2/keyring.bak.json";
pub const quarantine_prefix = "kea/quarantine/";

pub const Source = enum { primary, backup, head };

pub const LocationState = union(enum) {
    unknown,
    empty,
    existing_v2: struct {
        keyring: keyring.Keyring,
        /// Where it was found: not `primary` means keyring.json wants writing again.
        source: Source = .primary,
        device_count: usize,
        has_matching_account_key: bool,
        quarantine_count: usize,
    },
    existing_v1: struct { device_count: usize },
    corrupted_store: struct { reason: []const u8, commit_count: usize, pack_count: usize, quarantine_count: usize },
    non_empty_unrelated: struct { count: usize, sample: []const u8 },
    inaccessible: []const u8,
};

pub const Found = struct { ring: keyring.Keyring, source: Source };

/// The store's keyring, unchecked: keyring.json, its backup, else the copy
/// any head carries.
pub fn findKeyring(a: Allocator, d: *Drop) DropError!?Found {
    for ([_]struct { []const u8, Source }{ .{ keyring_path, .primary }, .{ keyring_bak_path, .backup } }) |p| {
        if (try d.get(a, p[0])) |bytes| if (json.decode(keyring.Keyring, a, bytes)) |r| return .{ .ring = r.value, .source = p[1] } else |_| {};
    }
    const heads = try d.list(a, dag.heads_prefix);
    for (heads.keys()) |name| {
        const bytes = (try d.get(a, name)) orelse continue;
        if (dag.headKeyring(a, bytes)) |r| return .{ .ring = r, .source = .head };
    }
    return null;
}

fn countQuarantines(a: Allocator, d: *Drop) DropError!usize {
    const names = try d.list(a, quarantine_prefix);
    var stamps: std.StringHashMapUnmanaged(void) = .empty;
    for (names.keys()) |n| {
        const rest = n[quarantine_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        if (!std.mem.startsWith(u8, rest, "pre-restore-")) try stamps.put(a, rest[0..slash], {});
    }
    return stamps.count();
}

/// What `d` holds, on `a`. `local_ak`: this Mac's account key, if any.
pub fn inspect(a: Allocator, d: *Drop, local_ak: ?keyring.AccountKey) LocationState {
    return look(a, d, local_ak) catch |e| .{ .inaccessible = if (e == error.SyncFailed) d.why else "Out of memory" };
}

fn look(a: Allocator, d: *Drop, local_ak: ?keyring.AccountKey) DropError!LocationState {
    const root = try d.inspectRoot(a);
    if (try findKeyring(a, d)) |found| return .{ .existing_v2 = .{
        .keyring = found.ring,
        .source = found.source,
        .device_count = (try d.list(a, dag.heads_prefix)).count(),
        .has_matching_account_key = if (local_ak) |ak| keyring.hasAccountSlot(&found.ring, ak) else false,
        .quarantine_count = try countQuarantines(a, d),
    } };
    if ((try d.get(a, "kea/v1/salt")) != null and (try d.get(a, "kea/v1/check")) != null) {
        const devices = try d.list(a, "kea/v1/devices/");
        var ids: std.StringHashMapUnmanaged(void) = .empty;
        for (devices.keys()) |n| {
            const rest = n["kea/v1/devices/".len..];
            if (std.mem.indexOfScalar(u8, rest, '/')) |slash| try ids.put(a, rest[0..slash], {});
        }
        return .{ .existing_v1 = .{ .device_count = ids.count() } };
    }
    const v2 = try d.list(a, "kea/v2/");
    const v1 = try d.list(a, "kea/v1/");
    if (v2.count() + v1.count() > 0) {
        var commits: usize = 0;
        var packs: usize = 0;
        for (v2.keys()) |n| {
            if (std.mem.startsWith(u8, n, dag.commits_prefix)) commits += 1;
            if (std.mem.startsWith(u8, n, dag.packs_prefix)) packs += 1;
        }
        return .{ .corrupted_store = .{
            .reason = "Sync store metadata is missing or damaged while encrypted sync objects are present",
            .commit_count = commits,
            .pack_count = packs,
            .quarantine_count = try countQuarantines(a, d),
        } };
    }
    if (root.non_kea_count > 0) return .{ .non_empty_unrelated = .{ .count = root.non_kea_count, .sample = root.sample_name } };
    return .empty;
}

pub const Outcome = union(enum) { ok, failed: []const u8 };

const Saved = struct { name: []const u8, bytes: []const u8 };

/// The live store's keys and heads, as they are now.
fn actives(a: Allocator, d: *Drop) DropError![]Saved {
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(a, &.{ keyring_path, keyring_bak_path, "kea/v1/salt", "kea/v1/check" });
    try names.appendSlice(a, (try d.list(a, dag.heads_prefix)).keys());
    var out: std.ArrayList(Saved) = .empty;
    for (names.items) |n| if (try d.get(a, n)) |bytes| try out.append(a, .{ .name = n, .bytes = bytes });
    return out.items;
}

/// Each saved file written back where it was; best effort.
fn putBack(a: Allocator, d: *Drop, saved: []const Saved) void {
    for (saved) |s| d.put(a, s.name, s.bytes) catch {};
}

/// Unix seconds, past every archive already there.
fn stamp(a: Allocator, d: *Drop) DropError![]u8 {
    var at: i64 = @intFromFloat(json.toUnix(json.now()));
    const names = try d.list(a, quarantine_prefix);
    for (names.keys()) |n| {
        const rest = n[quarantine_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const was = std.fmt.parseInt(i64, rest[0..slash], 10) catch continue;
        at = @max(at, was + 1);
    }
    return std.fmt.allocPrint(a, "{d}", .{at});
}

/// `ring` (the new store's, sorted JSON) in place of whatever store is
/// there: staged and read back first, the old keys and heads archived,
/// all put back on any failure. The new store's first commit is the
/// caller's next tick.
pub fn overwriteStore(a: Allocator, d: *Drop, ring_json: []const u8) Outcome {
    var tx: [8]u8 = undefined;
    std.c.arc4random_buf(&tx, tx.len);
    const staging = std.fmt.allocPrint(a, "kea/v2-staging-{s}/", .{&std.fmt.bytesToHex(tx, .lower)}) catch return .{ .failed = "Out of memory" };
    const staged = [_][]const u8{
        std.mem.concat(a, u8, &.{ staging, "keyring.json" }) catch return .{ .failed = "Out of memory" },
        std.mem.concat(a, u8, &.{ staging, "keyring.bak.json" }) catch return .{ .failed = "Out of memory" },
    };
    defer for (staged) |s| d.delete(a, s) catch {};
    const readable = for (staged) |s| {
        d.put(a, s, ring_json) catch break false;
        const back = (d.get(a, s) catch break false) orelse break false;
        if (!std.mem.eql(u8, back, ring_json)) break false;
    } else true;
    if (!readable) return .{ .failed = std.fmt.allocPrint(a, "Couldn't write to sync folder: {s}. Existing files were not modified.", .{if (d.why.len > 0) d.why else "it didn't read back"}) catch "Couldn't write to sync folder. Existing files were not modified." };

    const saved = actives(a, d) catch return .{ .failed = std.fmt.allocPrint(a, "Couldn't read the existing sync store: {s}. Existing files were not modified.", .{d.why}) catch "Couldn't read the existing sync store" };
    const ts = stamp(a, d) catch return .{ .failed = std.fmt.allocPrint(a, "Couldn't read the existing sync store: {s}. Existing files were not modified.", .{d.why}) catch "Couldn't read the existing sync store" };
    const archived = blk: {
        for (saved) |s| {
            const to = std.fmt.allocPrint(a, "{s}{s}/{s}", .{ quarantine_prefix, ts, s.name["kea/".len..] }) catch break :blk false;
            d.put(a, to, s.bytes) catch break :blk false;
        }
        for (saved) |s| d.delete(a, s.name) catch break :blk false;
        d.put(a, keyring_path, ring_json) catch break :blk false;
        d.put(a, keyring_bak_path, ring_json) catch break :blk false;
        break :blk true;
    };
    if (archived) return .ok;
    const why = a.dupe(u8, d.why) catch "";
    for ([_][]const u8{ keyring_path, keyring_bak_path }) |p| {
        const was_there = for (saved) |s| {
            if (std.mem.eql(u8, s.name, p)) break true;
        } else false;
        if (!was_there) d.delete(a, p) catch {};
    }
    putBack(a, d, saved);
    return .{ .failed = std.fmt.allocPrint(a, "Failed to archive/overwrite existing sync store ({s}); previous store was restored.", .{why}) catch "Failed to archive/overwrite existing sync store; previous store was restored." };
}

/// The newest archive's keys and heads back in place, what was live kept
/// under `pre-restore-<now>/`. Which archive, on `a`.
pub fn restoreLatestQuarantine(a: Allocator, d: *Drop) DropError![]const u8 {
    const names = try d.list(a, quarantine_prefix);
    var newest: ?[]const u8 = null;
    var newest_at: i64 = 0;
    for (names.keys()) |n| {
        const rest = n[quarantine_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const at = std.fmt.parseInt(i64, rest[0..slash], 10) catch continue;
        if (newest == null or at > newest_at) {
            newest = rest[0..slash];
            newest_at = at;
        }
    }
    const ts = newest orelse return error.SyncFailed;
    const live = try actives(a, d);
    const pre = try std.fmt.allocPrint(a, "{s}pre-restore-{s}/", .{ quarantine_prefix, try stamp(a, d) });
    for (live) |s| try d.put(a, try std.mem.concat(a, u8, &.{ pre, s.name["kea/".len..] }), s.bytes);
    for (live) |s| try d.delete(a, s.name);
    const from = try std.fmt.allocPrint(a, "{s}{s}/", .{ quarantine_prefix, ts });
    for (names.keys()) |n| if (std.mem.startsWith(u8, n, from)) {
        const bytes = (try d.get(a, n)) orelse continue;
        try d.put(a, try std.mem.concat(a, u8, &.{ "kea/", n[from.len..] }), bytes);
    };
    return ts;
}
