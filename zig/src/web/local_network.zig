//! Addresses on this Mac or on the network it's on (LocalNetwork.swift):
//! where Settings › AI › Custom server, and a sync server over plain http,
//! may point. Anything else is the internet, and refused.
const std = @import("std");

/// Lowercased into `buf`, the brackets of an IPv6 address off.
fn bare(buf: []u8, host: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, host, "[]");
    const n = @min(trimmed.len, buf.len);
    return std.ascii.lowerString(buf[0..n], trimmed[0..n]);
}

pub fn onThisMac(host: []const u8) bool {
    var buf: [256]u8 = undefined;
    const h = bare(&buf, host);
    for ([_][]const u8{ "127.0.0.1", "::1", "localhost" }) |known| if (std.mem.eql(u8, h, known)) return true;
    return false;
}

/// Loopback, private and link-local IPv4, and .local / .home.arpa names.
pub fn contains(host: []const u8) bool {
    var buf: [256]u8 = undefined;
    const h = bare(&buf, host);
    if (onThisMac(h) or std.mem.endsWith(u8, h, ".local") or std.mem.endsWith(u8, h, ".home.arpa")) return true;
    var bytes: [4]u8 = undefined;
    var parts = std.mem.splitScalar(u8, h, '.');
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (n == 4) return false;
        bytes[n] = std.fmt.parseInt(u8, part, 10) catch return false;
        // `UInt8("+1")` refuses a sign that parseInt takes.
        if (part[0] == '+' or part[0] == '-') return false;
    }
    if (n != 4) return false;
    return switch (bytes[0]) {
        10, 127 => true,
        192 => bytes[1] == 168,
        169 => bytes[1] == 254,
        172 => bytes[1] >= 16 and bytes[1] <= 31,
        else => false,
    };
}

/// What was typed in Settings as a server's base address, ending in "/",
/// on `gpa`; null when it isn't http(s) on this Mac or your network.
pub fn server(gpa: std.mem.Allocator, typed: []const u8) !?[]u8 {
    const text = std.mem.trim(u8, typed, " \t\r\n");
    const url = if (std.mem.endsWith(u8, text, "/")) try gpa.dupe(u8, text) else try std.mem.concat(gpa, u8, &.{ text, "/" });
    errdefer gpa.free(url);
    const ok = blk: {
        const uri = std.Uri.parse(url) catch break :blk false;
        if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https"))) break :blk false;
        if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) break :blk false;
        const host = uri.host orelse break :blk false;
        var hb: [256]u8 = undefined;
        const raw = host.toRaw(&hb) catch break :blk false;
        break :blk raw.len > 0 and contains(raw);
    };
    if (!ok) {
        gpa.free(url);
        return null;
    }
    return url;
}

test "local network is this Mac, private ranges and local names" {
    for ([_][]const u8{ "localhost", "127.0.0.1", "[::1]", "10.0.0.2", "172.16.0.1", "172.31.9.9", "192.168.1.4", "169.254.3.3", "printer.local", "nas.home.arpa", "LOCALHOST" }) |h|
        try std.testing.expect(contains(h));
    for ([_][]const u8{ "example.com", "172.32.0.1", "192.169.0.1", "8.8.8.8", "10.0.0", "10.0.0.1.2", "256.0.0.1", "local" }) |h|
        try std.testing.expect(!contains(h));
    try std.testing.expect(onThisMac("[::1]") and !onThisMac("10.0.0.1"));
}

test "a server is http(s) on this network, ending in a slash" {
    const gpa = std.testing.allocator;
    const a = (try server(gpa, " http://localhost:11434 ")).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("http://localhost:11434/", a);
    const b = (try server(gpa, "https://192.168.1.5/v1/")).?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("https://192.168.1.5/v1/", b);
    for ([_][]const u8{ "https://api.openai.com/v1", "ftp://localhost/", "http://me:pw@localhost/", "http://localhost/?q=1", "localhost:8080" }) |t|
        try std.testing.expect((try server(gpa, t)) == null);
}
