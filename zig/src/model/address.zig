//! What you type has to be a place (`Address.swift`): this either hands back
//! a URL or hands back nothing. Every returned address is on `gpa`.
const std = @import("std");
const url_mod = @import("../data/url.zig");
const Parts = url_mod.Parts;

/// Schemes the window can show itself.
const ours = [_][]const u8{ "http", "https", "file", "about", "data" };

/// `URL(string: prefix + text)?.absoluteString`, on `gpa`.
fn made(gpa: std.mem.Allocator, prefix: []const u8, text: []const u8) !?[]u8 {
    const whole = try std.mem.concat(gpa, u8, &.{ prefix, text });
    defer gpa.free(whole);
    if (Parts.parse(whole) == null) return null;
    return try url_mod.encoded(gpa, whole);
}

pub fn url(gpa: std.mem.Allocator, typed: []const u8) !?[]u8 {
    const text = std.mem.trim(u8, typed, " \t\r\n\x0b\x0c");
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, ' ') != null) return null;

    // Written with a scheme, it is taken at its word.
    if (std.mem.indexOf(u8, text, "://")) |split| {
        for (ours) |s| if (std.ascii.eqlIgnoreCase(text[0..split], s)) return made(gpa, "", text);
        return null;
    }
    if (std.ascii.startsWithIgnoreCase(text, "about:") or std.ascii.startsWithIgnoreCase(text, "data:")) return made(gpa, "", text);

    // Everything else has to look like a host before it gets a scheme.
    const head = text[0 .. std.mem.indexOfAny(u8, text, "/?#") orelse text.len];
    if (std.mem.indexOfScalar(u8, head, '@') != null) return null; // an email address
    if (std.mem.startsWith(u8, head, "[::1]")) return made(gpa, "http://", text);
    var colons = std.mem.tokenizeScalar(u8, head, ':');
    const host = colons.next() orelse head;
    if (!looksLikeHost(host)) return null;

    // A local server almost never has a certificate.
    const local = std.mem.eql(u8, host, "localhost") or
        std.mem.endsWith(u8, host, ".localhost") or
        std.mem.endsWith(u8, host, ".local") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "0.0.0.0") or
        std.mem.startsWith(u8, host, "192.168.") or
        std.mem.startsWith(u8, host, "10.") or
        privateRange(host);
    return made(gpa, if (local) "http://" else "https://", text);
}

/// 172.16.0.0 to 172.31.255.255.
fn privateRange(host: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, host, '.');
    var parts: [5][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n == 5) return false;
        parts[n] = p;
    }
    if (n != 4 or !std.mem.eql(u8, parts[0], "172")) return false;
    const second = std.fmt.parseInt(i64, parts[1], 10) catch return false;
    return second >= 16 and second <= 31;
}

/// 0.0.0.0 opened as localhost, the same server; null for anything else.
pub fn reachable(gpa: std.mem.Allocator, page: []const u8) !?[]u8 {
    var p = Parts.parse(page) orelse return null;
    if (!std.mem.eql(u8, p.hostName() orelse "", "0.0.0.0") or !p.isWeb()) return null;
    p.host = "localhost";
    return try p.string(gpa);
}

// ponytail: bytes past ASCII count as letters (Swift's isLetter/isNumber);
// a Unicode category table if a host ever turns on it.
fn isLetter(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch >= 0x80;
}

fn looksLikeHost(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost")) return true;

    // Four numbers is an address on the local network as often as not.
    var count: usize = 0;
    var numbers = true;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |label| : (count += 1) {
        _ = std.fmt.parseInt(u8, label, 10) catch {
            numbers = false;
        };
    }
    if (count == 4 and numbers) return true;
    if (count < 2) return false;

    var last: []const u8 = "";
    it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |ch| if (!isLetter(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
        last = label;
    }
    // A dotted thing ending in letters is a domain; in digits, a version.
    const tld_len = std.unicode.utf8CountCodepoints(last) catch last.len;
    if (tld_len < 2) return false;
    for (last) |ch| if (!isLetter(ch)) return false;
    return true;
}

/// A page's address as the field shows it for editing: something that,
/// sent as it is, goes back to the same page.
pub fn editable(gpa: std.mem.Allocator, page: []const u8) ![]u8 {
    const p = Parts.parse(page) orelse return gpa.dupe(u8, page);
    const scheme = p.scheme orelse return gpa.dupe(u8, page);
    if (page.len < scheme.len + 3 or !std.mem.eql(u8, page[scheme.len .. scheme.len + 3], "://")) return gpa.dupe(u8, page);
    const short = page[scheme.len + 3 ..];
    var candidates: [2][]const u8 = .{ short, short };
    var n: usize = 1;
    if (std.mem.eql(u8, p.path, "/") and p.query == null and p.fragment == null and std.mem.endsWith(u8, short, "/")) {
        candidates[0] = short[0 .. short.len - 1];
        n = 2;
    }
    for (candidates[0..n]) |candidate| {
        const back = try url(gpa, candidate) orelse continue;
        defer gpa.free(back);
        if (std.mem.eql(u8, back, page) or (back.len + 1 == page.len and std.mem.startsWith(u8, page, back) and page[back.len] == '/'))
            return gpa.dupe(u8, candidate);
    }
    return gpa.dupe(u8, page);
}

/// An address as a row shows it: without a leading www.
pub fn withoutWWW(address: []const u8) []const u8 {
    return if (std.ascii.startsWithIgnoreCase(address, "www.")) address[4..] else address;
}

/// What the tab says before the page has told us its title.
pub fn pretty(gpa: std.mem.Allocator, page: []const u8) ![]u8 {
    const p = Parts.parse(page) orelse return gpa.dupe(u8, page);
    const host = p.hostName() orelse return gpa.dupe(u8, page);
    const bare = if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
    if (p.path.len == 0 or std.mem.eql(u8, p.path, "/")) return gpa.dupe(u8, bare);
    return std.mem.concat(gpa, u8, &.{ bare, p.path });
}

test "address url(from:) table" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "example.com", "https://example.com" },
        .{ "  example.com/a?b#c ", "https://example.com/a?b#c" },
        .{ "localhost:3000", "http://localhost:3000" },
        .{ "printer.local", "http://printer.local" },
        .{ "192.168.1.4:8080/x", "http://192.168.1.4:8080/x" },
        .{ "172.20.0.2", "http://172.20.0.2" },
        .{ "8.8.8.8", "https://8.8.8.8" },
        .{ "[::1]:3000", "http://[::1]:3000" },
        .{ "HTTP://Example.com", "HTTP://Example.com" },
        .{ "about:blank", "about:blank" },
        .{ "data:text/plain,hi", "data:text/plain,hi" },
        .{ "mailto://x", null },
        .{ "me@example.com", null },
        .{ "3.14", null },
        .{ "a b", null },
        .{ "todo", null },
        .{ "-a.com", null },
        .{ "x.com/a|b", "https://x.com/a%7Cb" },
    };
    for (cases) |c| {
        const got = try url(gpa, c[0]);
        defer if (got) |g| gpa.free(g);
        if (c[1]) |want| try std.testing.expectEqualStrings(want, got.?) else try std.testing.expect(got == null);
    }
}

test "address editable and pretty" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "https://example.com/", "example.com" },
        .{ "https://example.com/a", "example.com/a" },
        .{ "http://example.com/", "http://example.com/" },
        .{ "http://localhost:3000/", "localhost:3000" },
        .{ "https://example.com/?q=1", "example.com/?q=1" },
    };
    for (cases) |c| {
        const got = try editable(gpa, c[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
    const p = try pretty(gpa, "https://www.example.com/a/b?x");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("example.com/a/b", p);
    const r = (try reachable(gpa, "http://0.0.0.0:5173/")).?;
    defer gpa.free(r);
    try std.testing.expectEqualStrings("http://localhost:5173/", r);
}

test {
    std.testing.refAllDecls(@This());
}
