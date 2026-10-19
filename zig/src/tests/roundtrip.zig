//! `<file> fixture round-trips`: decode, encode, decode, and the two decoded
//! values are the same.
const std = @import("std");
const json = @import("../data/json.zig");

pub fn check(comptime T: type, bytes: []const u8, sorted: bool) !void {
    const gpa = std.testing.allocator;
    const a = try json.decode(T, gpa, bytes);
    defer a.deinit();
    const out = if (sorted) try json.encodeSorted(gpa, a.value) else try json.encode(gpa, a.value);
    defer gpa.free(out);
    const b = try json.decode(T, gpa, out);
    defer b.deinit();
    try std.testing.expectEqualDeep(a.value, b.value);
}
