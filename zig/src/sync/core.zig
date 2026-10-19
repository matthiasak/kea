//! Sync's parts that need nothing of the app's (SyncCore.swift): how each
//! file is sealed and how two Macs' records are weighed. Where the files go:
//! drop.zig; the bucket's signatures: sigv4.zig.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const cc = @import("../sys/commoncrypto.zig");

const SwiftDate = json.SwiftDate;
const Map = json.Map;
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;

/// `Date.distantPast`.
pub const distant_past: SwiftDate = -63114076800;

/// `SyncError.wrongPassphrase` and `.damaged`; the others name a path, a
/// code or a host and are made where they happen (drop.zig).
pub const wrong_passphrase = "That passphrase doesn't open this sync folder";
pub const damaged = "A file in the sync store couldn't be read";

/// Swift `Data` as `JSONEncoder` writes it: a base64 string.
pub const Bytes = struct {
    bytes: []const u8,

    pub fn jsonStringify(self: Bytes, jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeByte('"');
        try std.base64.standard.Encoder.encodeWriter(jws.writer, self.bytes);
        try jws.writer.writeByte('"');
        jws.endWriteRaw();
    }

    pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Bytes {
        const s = switch (try source.nextAllocMax(a, .alloc_if_needed, options.max_value_len.?)) {
            inline .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        const d = std.base64.standard.Decoder;
        const out = try a.alloc(u8, d.calcSizeForSlice(s) catch return error.UnexpectedToken);
        d.decode(out, s) catch return error.UnexpectedToken;
        return .{ .bytes = out };
    }
};

/// Swift `[String: Data]`: one kind's records, by key.
pub const Records = std.StringArrayHashMapUnmanaged([]const u8);

pub const SyncMark = struct { hash: []const u8, at: SwiftDate };
pub const SyncRecord = struct { data: Bytes, at: SwiftDate };
pub const SyncDoc = struct { records: Map(SyncRecord) = .{}, gone: Map(SwiftDate) = .{} };
pub const SyncLedger = struct { marks: Map(SyncMark) = .{}, gone: Map(SwiftDate) = .{} };

// MARK: SyncSeal

pub const Key = [32]u8;
pub const iterations: u32 = 600_000;
/// `NSDataCompressionAlgorithmZlib` (NSData.h: LZFSE 0, LZ4 1, LZMA 2, Zlib 3).
const zlib: objc.NSInteger = 3;

/// PBKDF2-HMAC-SHA256, `iterations` rounds, 32 bytes.
pub fn key(passphrase: []const u8, salt: []const u8) Key {
    var out: Key = undefined;
    _ = cc.CCKeyDerivationPBKDF(cc.kCCPBKDF2, passphrase.ptr, passphrase.len, salt.ptr, salt.len, cc.kCCPRFHmacAlgSHA256, iterations, &out, out.len);
    return out;
}

/// zlib (raw deflate, as NSData does it), then AES-GCM combined:
/// nonce 12 ‖ ciphertext ‖ tag 16. On `gpa`.
pub fn seal(gpa: std.mem.Allocator, data: []const u8, k: Key) error{ Damaged, OutOfMemory }![]u8 {
    const packed_ = try zlibData(gpa, data, "compressedDataUsingAlgorithm:error:");
    defer gpa.free(packed_);
    const out = try gpa.alloc(u8, Aes.nonce_length + packed_.len + Aes.tag_length);
    std.c.arc4random_buf(out.ptr, Aes.nonce_length);
    const nonce = out[0..Aes.nonce_length].*;
    const body = out[Aes.nonce_length..][0..packed_.len];
    Aes.encrypt(body, out[Aes.nonce_length + packed_.len ..][0..Aes.tag_length], packed_, "", nonce, k);
    return out;
}

pub fn open(gpa: std.mem.Allocator, data: []const u8, k: Key) error{ Damaged, OutOfMemory }![]u8 {
    if (data.len < Aes.nonce_length + Aes.tag_length) return error.Damaged;
    const body = data[Aes.nonce_length .. data.len - Aes.tag_length];
    const plain = try gpa.alloc(u8, body.len);
    defer gpa.free(plain);
    Aes.decrypt(plain, body, data[data.len - Aes.tag_length ..][0..Aes.tag_length].*, "", data[0..Aes.nonce_length].*, k) catch return error.Damaged;
    return zlibData(gpa, plain, "decompressedDataUsingAlgorithm:error:");
}

fn zlibData(gpa: std.mem.Allocator, bytes: []const u8, comptime selector: [:0]const u8) error{ Damaged, OutOfMemory }![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) });
    const done = objc.msg(?objc.Object, d, selector, .{ zlib, @as(?*anyopaque, null) }) orelse return error.Damaged;
    const len = objc.msg(objc.NSUInteger, done, "length", .{});
    const out = try gpa.alloc(u8, len);
    if (len > 0) objc.msg(void, done, "getBytes:length:", .{ out.ptr, len });
    return out;
}

// MARK: SyncMerge

pub const keep_gone: f64 = 90 * 86_400;
pub const Hash = [64]u8;

/// SHA-256, lowercase hex.
pub fn hash(data: []const u8) Hash {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// `map[key] = v`, the key copied onto `a` when new.
pub fn putKey(a: std.mem.Allocator, map: anytype, k: []const u8, v: anytype) !void {
    const gop = try map.getOrPut(a, k);
    if (!gop.found_existing) gop.key_ptr.* = try a.dupe(u8, k);
    gop.value_ptr.* = v;
}

fn prune(gone: *Map(SwiftDate), now: SwiftDate) void {
    const cutoff = now - keep_gone;
    var i: usize = 0;
    while (i < gone.map.count()) {
        if (gone.map.values()[i] < cutoff) gone.map.swapRemoveAt(i) else i += 1;
    }
}

/// This Mac's records against what it last knew: a changed one is marked
/// now, a missing one gone now.
pub fn stamp(a: std.mem.Allocator, current: *const Records, ledger: *SyncLedger, now: SwiftDate) !void {
    var it = current.iterator();
    while (it.next()) |e| {
        const h = hash(e.value_ptr.*);
        const same = if (ledger.marks.map.get(e.key_ptr.*)) |m| std.mem.eql(u8, m.hash, &h) else false;
        if (!same) try putKey(a, &ledger.marks.map, e.key_ptr.*, SyncMark{ .hash = try a.dupe(u8, &h), .at = now });
        _ = ledger.gone.map.swapRemove(e.key_ptr.*);
    }
    var i: usize = 0;
    while (i < ledger.marks.map.count()) {
        const k = ledger.marks.map.keys()[i];
        if (current.contains(k)) {
            i += 1;
            continue;
        }
        try putKey(a, &ledger.gone.map, k, now);
        ledger.marks.map.swapRemoveAt(i);
    }
    prune(&ledger.gone, now);
}

pub const Taken = struct { put: Map(SyncRecord) = .{}, remove: Map(SwiftDate) = .{} };

/// What of another Mac's doc wins here: a record newer than ours (or, at the
/// same moment, the larger hash), and a removal newer than our record.
/// Keys borrow from `theirs`.
pub fn take(a: std.mem.Allocator, theirs: *const SyncDoc, ledger: *const SyncLedger) !Taken {
    var out: Taken = .{};
    var it = theirs.records.map.iterator();
    while (it.next()) |e| {
        const remote = e.value_ptr.*;
        const mark = ledger.marks.map.get(e.key_ptr.*);
        const mark_at = if (mark) |m| m.at else distant_past;
        const gone_at = ledger.gone.map.get(e.key_ptr.*) orelse distant_past;
        if (remote.at > mark_at and remote.at > gone_at) {
            try out.put.map.put(a, e.key_ptr.*, remote);
        } else if (mark) |m| if (remote.at == m.at and std.mem.order(u8, &hash(remote.data.bytes), m.hash) == .gt) {
            try out.put.map.put(a, e.key_ptr.*, remote);
        };
    }
    var g = theirs.gone.map.iterator();
    while (g.next()) |e| {
        if (ledger.marks.map.get(e.key_ptr.*)) |m| if (e.value_ptr.* > m.at) try out.remove.map.put(a, e.key_ptr.*, e.value_ptr.*);
    }
    return out;
}

/// After a remote record is put in place: marked at its time when ours now
/// reads the same, else at `now` (ours changed it on the way in).
pub fn settle(a: std.mem.Allocator, k: []const u8, local: ?[]const u8, remote: SyncRecord, ledger: *SyncLedger, now: SwiftDate) !void {
    _ = ledger.gone.map.swapRemove(k);
    const l = local orelse {
        _ = ledger.marks.map.swapRemove(k);
        return;
    };
    const h = hash(l);
    const at = if (std.mem.eql(u8, &h, &hash(remote.data.bytes))) remote.at else now;
    try putKey(a, &ledger.marks.map, k, SyncMark{ .hash = try a.dupe(u8, &h), .at = at });
}

pub fn removed(a: std.mem.Allocator, k: []const u8, at: SwiftDate, ledger: *SyncLedger) !void {
    _ = ledger.marks.map.swapRemove(k);
    try putKey(a, &ledger.gone.map, k, at);
}

/// What this Mac writes for a kind: each marked record at its mark's time,
/// and what went within `keep_gone`. On `a`, borrowing.
pub fn doc(a: std.mem.Allocator, current: *const Records, ledger: *const SyncLedger, now: SwiftDate) !SyncDoc {
    var out: SyncDoc = .{};
    var it = current.iterator();
    while (it.next()) |e| if (ledger.marks.map.get(e.key_ptr.*)) |m|
        try out.records.map.put(a, e.key_ptr.*, .{ .data = .{ .bytes = e.value_ptr.* }, .at = m.at });
    out.gone.map = try ledger.gone.map.clone(a);
    prune(&out.gone, now);
    return out;
}

test "seal then open round-trips" {
    const gpa = std.testing.allocator;
    var k: Key = undefined;
    std.c.arc4random_buf(&k, k.len);
    const plain = "{\"hello\":\"kea\"} and something longer to squeeze squeeze squeeze";
    const sealed = try seal(gpa, plain, k);
    defer gpa.free(sealed);
    const back = try open(gpa, sealed, k);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(plain, back);
    sealed[sealed.len - 1] ^= 1;
    try std.testing.expectError(error.Damaged, open(gpa, sealed, k));
}

test "sealed fixture from Swift opens" {
    const gpa = std.testing.allocator;
    const k = key("correct horse battery staple", "kea-fixture-salt");
    const back = try open(gpa, @embedFile("../tests/fixtures/sync/sealed.bin"), k);
    defer gpa.free(back);
    try std.testing.expectEqualStrings("{\"hello\":\"kea\"}", back);
}

test "merge keeps newest per id" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var current: Records = .empty;
    try current.put(a, "a", "one");
    try current.put(a, "b", "two");
    try current.put(a, "c", "three");
    var ledger: SyncLedger = .{};
    try stamp(a, &current, &ledger, 10);
    try std.testing.expectEqual(@as(f64, 10), ledger.marks.map.get("a").?.at);
    // Unchanged keeps its time; a vanished record is gone now.
    _ = current.swapRemove("c");
    try stamp(a, &current, &ledger, 12);
    try std.testing.expectEqual(@as(f64, 10), ledger.marks.map.get("a").?.at);
    try std.testing.expectEqual(@as(f64, 12), ledger.gone.map.get("c").?);

    var remote: SyncDoc = .{};
    try remote.records.map.put(a, "a", .{ .data = .{ .bytes = "newer" }, .at = 20 });
    try remote.records.map.put(a, "b", .{ .data = .{ .bytes = "older" }, .at = 5 });
    try remote.records.map.put(a, "c", .{ .data = .{ .bytes = "before it went" }, .at = 11 });
    try remote.gone.map.put(a, "b", 30);
    const t = try take(a, &remote, &ledger);
    try std.testing.expectEqualStrings("newer", t.put.map.get("a").?.data.bytes);
    try std.testing.expect(!t.put.map.contains("b"));
    try std.testing.expect(!t.put.map.contains("c"));
    try std.testing.expectEqual(@as(f64, 30), t.remove.map.get("b").?);

    // The same moment: the larger hash wins on both Macs.
    var tie: SyncDoc = .{};
    const mine = ledger.marks.map.get("a").?;
    const other = if (std.mem.order(u8, &hash("x"), mine.hash) == .gt) "x" else "y";
    try tie.records.map.put(a, "a", .{ .data = .{ .bytes = other }, .at = mine.at });
    const wins = std.mem.order(u8, &hash(other), mine.hash) == .gt;
    try std.testing.expectEqual(wins, (try take(a, &tie, &ledger)).put.map.contains("a"));

    try settle(a, "a", "newer", t.put.map.get("a").?, &ledger, 40);
    try std.testing.expectEqual(@as(f64, 20), ledger.marks.map.get("a").?.at);
    try removed(a, "b", 30, &ledger);
    const d = try doc(a, &current, &ledger, 40);
    try std.testing.expect(d.records.map.contains("a") and !d.records.map.contains("b"));
    try std.testing.expectEqual(@as(f64, 30), d.gone.map.get("b").?);
    // Encoded the way Swift's JSONEncoder writes it, and back.
    const bytes = try json.encode(a, d);
    const back = try json.decode(SyncDoc, a, bytes);
    try std.testing.expectEqualStrings("one", back.value.records.map.get("a").?.data.bytes);
}
