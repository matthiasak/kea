//! Just enough CBOR to read an attestation object (Passkeys.swift `CBOR`,
//! `authenticatorData(inAttestation:)`, `publicKey(inAuthenticatorData:)`).
const std = @import("std");

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn major(r: Reader) ?u8 {
        return if (r.at < r.bytes.len) r.bytes[r.at] >> 5 else null;
    }

    fn head(r: *Reader) ?struct { major: u8, value: u64 } {
        if (r.at >= r.bytes.len) return null;
        const first = r.bytes[r.at];
        r.at += 1;
        const info = first & 0x1F;
        if (info < 24) return .{ .major = first >> 5, .value = info };
        if (info > 27) return null;
        const size = @as(usize, 1) << @intCast(info - 24);
        if (r.at + size > r.bytes.len) return null;
        var value: u64 = 0;
        for (r.bytes[r.at..][0..size]) |b| value = value << 8 | b;
        r.at += size;
        return .{ .major = first >> 5, .value = value };
    }

    fn mapCount(r: *Reader) ?usize {
        const h = r.head() orelse return null;
        if (h.major != 5 or h.value >= 1024) return null;
        return @intCast(h.value);
    }

    fn int(r: *Reader) ?i64 {
        const h = r.head() orelse return null;
        if (h.value >= std.math.maxInt(i64)) return null;
        const v: i64 = @intCast(h.value);
        return switch (h.major) {
            0 => v,
            1 => -1 - v,
            else => null,
        };
    }

    fn string(r: *Reader, kind: u8) ?[]const u8 {
        const h = r.head() orelse return null;
        if (h.major != kind or h.value > r.bytes.len - r.at) return null;
        const n: usize = @intCast(h.value);
        defer r.at += n;
        return r.bytes[r.at..][0..n];
    }

    fn text(r: *Reader) ?[]const u8 {
        const s = r.string(3) orelse return null;
        return if (std.unicode.utf8ValidateSlice(s)) s else null;
    }

    fn blob(r: *Reader) ?[]const u8 {
        return r.string(2);
    }

    fn skip(r: *Reader, depth: usize) bool {
        if (depth >= 16) return false;
        const h = r.head() orelse return false;
        switch (h.major) {
            0, 1, 7 => return true,
            2, 3 => {
                if (h.value > r.bytes.len - r.at) return false;
                r.at += @intCast(h.value);
                return true;
            },
            4, 5 => {
                if (h.value >= 1024) return false;
                const items = h.value * @as(u64, if (h.major == 5) 2 else 1);
                for (0..@intCast(items)) |_| if (!r.skip(depth + 1)) return false;
                return true;
            },
            6 => return r.skip(depth + 1),
            else => return false,
        }
    }
};

/// The authenticator data inside an attestation object, under "authData".
pub fn authenticatorData(object: []const u8) ?[]const u8 {
    var r: Reader = .{ .bytes = object };
    const pairs = r.mapCount() orelse return null;
    for (0..pairs) |_| {
        const key = r.text() orelse return null;
        if (std.mem.eql(u8, key, "authData")) return r.blob();
        if (!r.skip(0)) return null;
    }
    return null;
}

pub const PublicKey = struct {
    algorithm: i64,
    /// DER, as getPublicKey() hands it over; null for other kinds. Owned by
    /// the caller's allocator when set.
    der: ?[]u8,
};

const p256_head = [_]u8{
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    0x04,
};
const ed25519_head = [_]u8{ 0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00 };

const Field = union(enum) { int: i64, blob: []const u8 };

/// The new credential's public key, from its authenticator data: the
/// algorithm, and DER for P-256 and Ed25519.
pub fn publicKey(gpa: std.mem.Allocator, data: []const u8) !?PublicKey {
    if (data.len <= 55 or data[32] & 0x40 == 0) return null;
    const start = 55 + (@as(usize, data[53]) << 8 | data[54]);
    if (start >= data.len) return null;
    var r: Reader = .{ .bytes = data[start..] };
    const pairs = r.mapCount() orelse return null;
    var keys: [16]i64 = undefined;
    var values: [16]Field = undefined;
    var n: usize = 0;
    for (0..pairs) |_| {
        const key = r.int() orelse return null;
        const value: ?Field = switch (r.major() orelse 255) {
            0, 1 => if (r.int()) |v| .{ .int = v } else null,
            2 => if (r.blob()) |b| .{ .blob = b } else null,
            else => {
                if (!r.skip(0)) return null;
                continue;
            },
        };
        // Swift's `fields[key] = value`: the last one wins, nil removes.
        const at = for (keys[0..n], 0..) |k, i| {
            if (k == key) break i;
        } else n;
        if (value) |v| {
            if (at == n) {
                if (n == keys.len) continue;
                n += 1;
            }
            keys[at] = key;
            values[at] = v;
        } else if (at < n) {
            n -= 1;
            keys[at] = keys[n];
            values[at] = values[n];
        }
    }
    const look = struct {
        fn get(ks: []const i64, vs: []const Field, k: i64) ?Field {
            for (ks, vs) |kk, v| if (kk == k) return v;
            return null;
        }
    }.get;
    const algorithm = switch (look(keys[0..n], values[0..n], 3) orelse return null) {
        .int => |v| v,
        .blob => return null,
    };
    const kty: ?i64 = if (look(keys[0..n], values[0..n], 1)) |f| switch (f) {
        .int => |v| v,
        else => null,
    } else null;
    const crv: ?i64 = if (look(keys[0..n], values[0..n], -1)) |f| switch (f) {
        .int => |v| v,
        else => null,
    } else null;
    const x: ?[]const u8 = if (look(keys[0..n], values[0..n], -2)) |f| switch (f) {
        .blob => |b| b,
        else => null,
    } else null;
    const y: ?[]const u8 = if (look(keys[0..n], values[0..n], -3)) |f| switch (f) {
        .blob => |b| b,
        else => null,
    } else null;
    if (kty == 2 and crv == 1) {
        if (x == null or x.?.len != 32 or y == null or y.?.len != 32) return .{ .algorithm = algorithm, .der = null };
        return .{ .algorithm = algorithm, .der = try std.mem.concat(gpa, u8, &.{ &p256_head, x.?, y.? }) };
    }
    if (kty == 1 and crv == 6) {
        if (x == null or x.?.len != 32) return .{ .algorithm = algorithm, .der = null };
        return .{ .algorithm = algorithm, .der = try std.mem.concat(gpa, u8, &.{ &ed25519_head, x.? }) };
    }
    return .{ .algorithm = algorithm, .der = null };
}
