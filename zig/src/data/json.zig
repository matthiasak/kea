//! The one way KeaZig reads and writes JSON, shaped like Swift's `Codable`
//! with Foundation's default `JSONEncoder`/`JSONDecoder`: nil optionals are
//! left out, dates are `SwiftDate` seconds since 2001, UUIDs are uppercase
//! strings, and `[String: V]` is `Map(V)`.
const std = @import("std");
const dispatch = @import("../sys/dispatch.zig");

/// Swift's `UUID`: `uuidString` is uppercase and hyphenated; decoding takes any case.
pub const Uuid = struct {
    bytes: [16]u8,

    /// `Space.firstID`.
    pub const first: Uuid = parse("00000000-0000-0000-0000-000000000001") catch unreachable;

    /// Version 4, variant 1, as `UUID()` makes.
    pub fn random() Uuid {
        var u: Uuid = .{ .bytes = undefined };
        std.c.arc4random_buf(&u.bytes, u.bytes.len);
        u.bytes[6] = (u.bytes[6] & 0x0f) | 0x40;
        u.bytes[8] = (u.bytes[8] & 0x3f) | 0x80;
        return u;
    }

    /// `UUID(uuidString:)`: 8-4-4-4-12 hex digits, any case.
    pub fn parse(s: []const u8) !Uuid {
        if (s.len != 36) return error.InvalidUuid;
        var u: Uuid = .{ .bytes = undefined };
        var i: usize = 0;
        for (&u.bytes) |*b| {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (s[i] != '-') return error.InvalidUuid;
                i += 1;
            }
            const hi = std.fmt.charToDigit(s[i], 16) catch return error.InvalidUuid;
            const lo = std.fmt.charToDigit(s[i + 1], 16) catch return error.InvalidUuid;
            b.* = hi << 4 | lo;
            i += 2;
        }
        return u;
    }

    pub fn string(self: Uuid) [36]u8 {
        const hex = std.fmt.bytesToHex(self.bytes, .upper);
        var out: [36]u8 = undefined;
        var o: usize = 0;
        for (hex, 0..) |ch, i| {
            if (i == 8 or i == 12 or i == 16 or i == 20) {
                out[o] = '-';
                o += 1;
            }
            out[o] = ch;
            o += 1;
        }
        return out;
    }

    pub fn eql(a: Uuid, b: Uuid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn format(self: Uuid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&self.string());
    }

    pub fn jsonStringify(self: Uuid, jws: anytype) !void {
        const s = self.string();
        try jws.write(@as([]const u8, &s));
    }

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Uuid {
        return switch (try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?)) {
            inline .string, .allocated_string => |s| parse(s) catch error.UnexpectedToken,
            else => error.UnexpectedToken,
        };
    }

    pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !Uuid {
        if (source != .string) return error.UnexpectedToken;
        return parse(source.string) catch error.UnexpectedToken;
    }
};

/// Foundation's `Date` as the default `JSONEncoder` writes it.
pub const SwiftDate = f64;
const unix_to_swift: f64 = 978307200;

pub fn now() SwiftDate {
    return dispatch.CFAbsoluteTimeGetCurrent();
}

pub fn fromUnix(t: f64) SwiftDate {
    return t - unix_to_swift;
}

pub fn toUnix(d: SwiftDate) f64 {
    return d + unix_to_swift;
}

/// Swift `[String: V]`.
pub fn Map(comptime V: type) type {
    return std.json.ArrayHashMap(V);
}

/// Compact JSON with nil optionals omitted, as synthesized `Codable` writes it.
pub fn encode(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}

/// `encode` with every object's keys sorted, as `outputFormatting = [.sortedKeys]`.
pub fn encodeSorted(gpa: std.mem.Allocator, value: anytype) ![]u8 {
    const plain = try encode(gpa, value);
    defer gpa.free(plain);
    // Numbers stay as written; only the key order changes.
    var tree = try std.json.parseFromSlice(std.json.Value, gpa, plain, .{ .parse_numbers = false });
    defer tree.deinit();
    sortKeys(&tree.value);
    return std.json.Stringify.valueAlloc(gpa, tree.value, .{});
}

fn sortKeys(v: *std.json.Value) void {
    switch (v.*) {
        .array => |*a| for (a.items) |*item| sortKeys(item),
        .object => |*obj| {
            const Ctx = struct {
                keys: [][]const u8,
                pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    return keyOrder(ctx.keys[a], ctx.keys[b]) == .lt;
                }
            };
            obj.sort(Ctx{ .keys = obj.keys() });
            for (obj.values()) |*item| sortKeys(item);
        },
        else => {},
    }
}

/// Foundation's sorted-keys order: `compare(_:options: [.numeric,
/// .caseInsensitive, .forcedOrdering])`.
// ponytail: ASCII case folding only; Unicode folding if a key ever needs it.
pub fn keyOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const si = i;
            const sj = j;
            while (i < a.len and std.ascii.isDigit(a[i])) i += 1;
            while (j < b.len and std.ascii.isDigit(b[j])) j += 1;
            const na = std.mem.trimStart(u8, a[si..i], "0");
            const nb = std.mem.trimStart(u8, b[sj..j], "0");
            if (na.len != nb.len) return std.math.order(na.len, nb.len);
            const o = std.mem.order(u8, na, nb);
            if (o != .eq) return o;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return std.math.order(ca, cb);
        i += 1;
        j += 1;
    }
    const rest = std.math.order(a.len - i, b.len - j);
    return if (rest != .eq) rest else std.mem.order(u8, a, b);
}

/// Unknown keys are skipped, as `JSONDecoder` does; the result owns its memory.
pub fn decode(comptime T: type, gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// A deep copy of a decoded value (strings, slices, optionals, structs) on
/// `a`, usually an arena that owns a store's whole snapshot.
pub fn clone(a: std.mem.Allocator, v: anytype) error{OutOfMemory}!@TypeOf(v) {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) @compileError("json.clone: slices only, not " ++ @typeName(T));
            if (p.child == u8) return a.dupe(u8, v);
            const out = try a.alloc(p.child, v.len);
            for (out, v) |*o, x| o.* = try clone(a, x);
            return out;
        },
        .optional => return if (v) |x| try clone(a, x) else null,
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.field_names) |name| @field(out, name) = try clone(a, @field(v, name));
            return out;
        },
        else => return v,
    }
}

test "uuid parses lowercase and prints uppercase" {
    const u = try Uuid.parse("5e4c0000-abcd-4000-8000-00000000002a");
    try std.testing.expectEqualStrings("5E4C0000-ABCD-4000-8000-00000000002A", &u.string());
    try std.testing.expect(u.eql(try Uuid.parse(&u.string())));
    try std.testing.expectEqual(@as(u8, 1), Uuid.first.bytes[15]);
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("5e4c0000abcd-4000-8000-00000000002a0"));
    const r = Uuid.random();
    try std.testing.expectEqual(@as(u8, 4), r.bytes[6] >> 4);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(&Uuid.first.string(), try std.fmt.bufPrint(&buf, "{f}", .{Uuid.first}));
    const T = struct { id: Uuid };
    const out = try encode(std.testing.allocator, T{ .id = u });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"id\":\"5E4C0000-ABCD-4000-8000-00000000002A\"}", out);
    const back = try decode(T, std.testing.allocator, "{\"id\":\"5e4c0000-abcd-4000-8000-00000000002a\"}");
    defer back.deinit();
    try std.testing.expect(back.value.id.eql(u));
}

test "SwiftDate now is within 2 s of unix now − 978307200" {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    const unix: f64 = @as(f64, @floatFromInt(tv.sec)) + @as(f64, @floatFromInt(tv.usec)) / 1e6;
    try std.testing.expect(@abs(now() - (unix - 978307200)) < 2);
    try std.testing.expectEqual(@as(f64, 0), fromUnix(978307200));
    try std.testing.expectEqual(@as(f64, 978307200), toUnix(0));
}

test "nil optionals are omitted" {
    const Bookmark = struct { id: Uuid, title: []const u8, url: ?[]const u8 = null, children: ?[]const u8 = null };
    const out = try encode(std.testing.allocator, Bookmark{ .id = Uuid.first, .title = "Folder" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"Folder\"}", out);
    const back = try decode(Bookmark, std.testing.allocator, "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"Folder\",\"extra\":[1]}");
    defer back.deinit();
    try std.testing.expect(back.value.url == null);
}

test "a title He said \"hi\" round-trips" {
    const Visit = struct { title: []const u8, last: SwiftDate };
    const out = try encode(std.testing.allocator, Visit{ .title = "He said \"hi\"", .last = 1.5 });
    defer std.testing.allocator.free(out);
    const back = try decode(Visit, std.testing.allocator, out);
    defer back.deinit();
    try std.testing.expectEqualStrings("He said \"hi\"", back.value.title);
    try std.testing.expectEqual(@as(f64, 1.5), back.value.last);
}

test "encodeSorted sorts keys" {
    const gpa = std.testing.allocator;
    const Turn = struct { zeta: u32 = 1, Beta: u32 = 2, alpha: ?u32 = null, item10: u32 = 10, item9: u32 = 9 };
    const a = try encodeSorted(gpa, Turn{});
    defer gpa.free(a);
    try std.testing.expectEqualStrings("{\"Beta\":2,\"item9\":9,\"item10\":10,\"zeta\":1}", a);
    var m: Map(Turn) = .{};
    defer m.deinit(gpa);
    try m.map.put(gpa, "b", .{});
    try m.map.put(gpa, "a", .{ .alpha = 3 });
    const b = try encodeSorted(gpa, m);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(
        "{\"a\":{\"alpha\":3,\"Beta\":2,\"item9\":9,\"item10\":10,\"zeta\":1},\"b\":{\"Beta\":2,\"item9\":9,\"item10\":10,\"zeta\":1}}",
        b,
    );
}
