//! Foundation's `URL`/`URLComponents` for what Kea reads of an address:
//! its scheme, user, password, host, port, path, query and fragment, each
//! kept as written (percent-encoded), and put back together by `string`.
const std = @import("std");
const objc = @import("nanoui").objc;

pub const Parts = struct {
    scheme: ?[]const u8 = null,
    user: ?[]const u8 = null,
    password: ?[]const u8 = null,
    /// As written: an IPv6 host keeps its brackets.
    host: ?[]const u8 = null,
    port: ?[]const u8 = null,
    path: []const u8 = "",
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,

    /// `URLComponents(string:)`: null where Foundation gives nil. Like
    /// Foundation since macOS 14 it takes characters a URL can't hold (they
    /// are percent-encoded by `encoded`), so only empty text and a
    /// non-numeric port are refused here.
    pub fn parse(s: []const u8) ?Parts {
        if (s.len == 0) return null;
        var p: Parts = .{};
        var rest = s;
        if (schemeEnd(s)) |i| {
            p.scheme = s[0..i];
            rest = s[i + 1 ..];
        }
        if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
            p.fragment = rest[i + 1 ..];
            rest = rest[0..i];
        }
        if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
            p.query = rest[i + 1 ..];
            rest = rest[0..i];
        }
        if (std.mem.startsWith(u8, rest, "//")) {
            rest = rest[2..];
            const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            var auth = rest[0..end];
            rest = rest[end..];
            if (std.mem.lastIndexOfScalar(u8, auth, '@')) |at| {
                const info = auth[0..at];
                auth = auth[at + 1 ..];
                if (std.mem.indexOfScalar(u8, info, ':')) |c| {
                    p.user = info[0..c];
                    p.password = info[c + 1 ..];
                } else p.user = info;
            }
            var port_from: ?usize = null;
            if (auth.len > 0 and auth[0] == '[') {
                const close = std.mem.indexOfScalar(u8, auth, ']') orelse return null;
                if (close + 1 < auth.len) {
                    if (auth[close + 1] != ':') return null;
                    port_from = close + 1;
                }
            } else port_from = std.mem.indexOfScalar(u8, auth, ':');
            if (port_from) |c| {
                const port = auth[c + 1 ..];
                for (port) |ch| if (!std.ascii.isDigit(ch)) return null;
                if (port.len > 0) p.port = port;
                auth = auth[0..c];
            }
            p.host = auth;
        }
        p.path = rest;
        return p;
    }

    /// `URLComponents.string`, on `gpa`.
    pub fn string(p: Parts, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        if (p.scheme) |s| try out.print(gpa, "{s}:", .{s});
        if (p.host != null or p.user != null or p.password != null) {
            try out.appendSlice(gpa, "//");
            if (p.user) |u| try out.appendSlice(gpa, u);
            if (p.password) |pw| try out.print(gpa, ":{s}", .{pw});
            if (p.user != null or p.password != null) try out.append(gpa, '@');
            try out.appendSlice(gpa, p.host orelse "");
            if (p.port) |port| try out.print(gpa, ":{s}", .{port});
        }
        try out.appendSlice(gpa, p.path);
        if (p.query) |q| try out.print(gpa, "?{s}", .{q});
        if (p.fragment) |f| try out.print(gpa, "#{s}", .{f});
        return out.toOwnedSlice(gpa);
    }

    /// `url.host()`: without an IPv6 address's brackets; null when empty.
    pub fn hostName(p: Parts) ?[]const u8 {
        const h = p.host orelse return null;
        if (h.len == 0) return null;
        if (h.len >= 2 and h[0] == '[' and h[h.len - 1] == ']') return h[1 .. h.len - 1];
        return h;
    }

    pub fn schemeIs(p: Parts, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(p.scheme orelse return false, name);
    }

    pub fn isWeb(p: Parts) bool {
        return p.schemeIs("http") or p.schemeIs("https");
    }
};

/// RFC 3986: a letter, then letters, digits, `+`, `-` or `.`, before a `:`
/// that comes ahead of any `/`, `?` or `#`.
fn schemeEnd(s: []const u8) ?usize {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return null;
    for (s[1..], 1..) |ch, i| {
        if (ch == ':') return i;
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return null;
    }
    return null;
}

/// `URL(string:)!.absoluteString`: what can't stand in a path, query or
/// fragment percent-encoded (UTF-8 bytes, spaces, `[]{}"<>^` and the like,
/// a `%` not followed by two hex digits, a second `#`); scheme and
/// authority as written. On `gpa`.
// ponytail: hosts kept as written; Foundation's IDNA (punycode) if one needs it.
pub fn encoded(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var start: usize = 0;
    if (schemeEnd(s)) |i| start = i + 1;
    if (std.mem.startsWith(u8, s[start..], "//"))
        start += 2 + (std.mem.indexOfAny(u8, s[start + 2 ..], "/?#") orelse s.len - start - 2);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, s[0..start]);
    var in_fragment = false;
    for (s[start..], start..) |ch, i| {
        const keep = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@', '/', '?' => true,
            '#' => !in_fragment,
            '%' => i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2]),
            else => false,
        };
        if (ch == '#') in_fragment = true;
        if (keep) try out.append(gpa, ch) else try out.print(gpa, "%{X:0>2}", .{ch});
    }
    return out.toOwnedSlice(gpa);
}

/// Swift's `lowercased()`, on `gpa`: bytes for ASCII, `NSString` otherwise.
pub fn lower(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    for (s) |ch| if (ch >= 0x80) {
        const pool = objc.Pool.push();
        defer pool.pop();
        const l = objc.msg(objc.Object, objc.nsString(s), "lowercaseString", .{});
        return gpa.dupe(u8, objc.fromNSString(l));
    };
    return std.ascii.allocLowerString(gpa, s);
}

pub const CleanMode = enum { all_trackers, click_ids_only };

const signed_url_keys = [_][]const u8{
    "x-amz-signature", "x-goog-signature", "signature", "sig", "se", "sv",
    "expires",         "googleaccessid",   "policy",    "token", "hmac",
};

const click_tracker_keys = [_][]const u8{
    "fbclid",     "gclid",      "dclid",   "gbraid",   "wbraid",  "msclkid",
    "twclid",     "ttclid",     "yclid",   "wickedid", "rb_clickid", "s_kwcid",
    "mc_eid",     "igshid",     "igsh",    "_hsenc",   "_hsmi",   "mkt_tok",
    "vero_id",    "oly_enc_id", "oly_anon_id",
};

fn isTrackerParam(key: []const u8, val: []const u8, host: []const u8, mode: CleanMode) bool {
    for (click_tracker_keys) |k| if (std.ascii.eqlIgnoreCase(key, k)) return true;
    if (mode != .all_trackers) return false;
    if (std.ascii.startsWithIgnoreCase(key, "utm_")) return true;
    if (std.ascii.eqlIgnoreCase(key, "ref_src") or std.ascii.eqlIgnoreCase(key, "ref_url")) return true;
    const media_host = std.ascii.endsWithIgnoreCase(host, "youtube.com") or
        std.ascii.endsWithIgnoreCase(host, "youtu.be") or
        std.ascii.endsWithIgnoreCase(host, "spotify.com");
    if (media_host) {
        if (std.ascii.eqlIgnoreCase(key, "si")) return true;
        if (std.ascii.eqlIgnoreCase(key, "feature") and
            (std.ascii.eqlIgnoreCase(val, "shared") or std.ascii.eqlIgnoreCase(val, "share"))) return true;
    }
    return false;
}

/// Strips tracking parameters according to `mode`, returning null when nothing
/// changed or when the URL contains a signed query parameter.
pub fn clean(gpa: std.mem.Allocator, raw: []const u8, mode: CleanMode) !?[]u8 {
    var p = Parts.parse(raw) orelse return null;
    if (!p.isWeb()) return null;
    const query = p.query orelse return null;
    if (query.len == 0) return null;

    var scan = std.mem.splitScalar(u8, query, '&');
    while (scan.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const key = if (eq) |i| pair[0..i] else pair;
        for (signed_url_keys) |sk| if (std.ascii.eqlIgnoreCase(key, sk)) return null;
    }

    const host = p.hostName() orelse "";
    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(gpa);
    var stripped = false;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const key = if (eq) |i| pair[0..i] else pair;
        const val = if (eq) |i| pair[i + 1 ..] else "";
        if (isTrackerParam(key, val, host, mode)) {
            stripped = true;
            continue;
        }
        if (kept.items.len > 0) try kept.append(gpa, '&');
        try kept.appendSlice(gpa, pair);
    }
    if (!stripped) return null;
    p.query = if (kept.items.len > 0) kept.items else null;
    return try p.string(gpa);
}

test "url parts split and join" {
    const gpa = std.testing.allocator;
    const p = Parts.parse("HTTPS://me:pw@Example.com:8080/a/b?x=1#top").?;
    try std.testing.expectEqualStrings("HTTPS", p.scheme.?);
    try std.testing.expectEqualStrings("me", p.user.?);
    try std.testing.expectEqualStrings("pw", p.password.?);
    try std.testing.expectEqualStrings("Example.com", p.host.?);
    try std.testing.expectEqualStrings("8080", p.port.?);
    try std.testing.expectEqualStrings("/a/b", p.path);
    try std.testing.expectEqualStrings("x=1", p.query.?);
    try std.testing.expectEqualStrings("top", p.fragment.?);
    const s = try p.string(gpa);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("HTTPS://me:pw@Example.com:8080/a/b?x=1#top", s);
    const v6 = Parts.parse("http://[::1]:3000/").?;
    try std.testing.expectEqualStrings("::1", v6.hostName().?);
    try std.testing.expectEqualStrings("3000", v6.port.?);
    try std.testing.expectEqualStrings("blank", Parts.parse("about:blank").?.path);
    try std.testing.expect(Parts.parse("http://host:x/") == null);
    try std.testing.expect(Parts.parse("") == null);
    const l = try lower(gpa, "ÉLAN Ok");
    defer gpa.free(l);
    try std.testing.expectEqualStrings("élan ok", l);
}

test "url encoded matches Foundation's absoluteString" {
    // Expected values printed by `URL(string:)!.absoluteString` on macOS 26.
    const cases = [_][2][]const u8{
        .{ "https://x.com/a b#c d", "https://x.com/a%20b#c%20d" },
        .{ "https://x.com/100%", "https://x.com/100%25" },
        .{ "https://x.com/%7e", "https://x.com/%7e" },
        .{ "https://x.com/é?q=ü", "https://x.com/%C3%A9?q=%C3%BC" },
        .{ "https://x.com/[a]{b}\"<>^`\\", "https://x.com/%5Ba%5D%7Bb%7D%22%3C%3E%5E%60%5C" },
        .{ "https://x.com/?q=SEARCH a&r=%s", "https://x.com/?q=SEARCH%20a&r=%25s" },
        .{ "https://x.com/a|b", "https://x.com/a%7Cb" },
        .{ "a b", "a%20b" },
        .{ "http://[::1]:3000/x", "http://[::1]:3000/x" },
    };
    for (cases) |c| {
        const got = try encoded(std.testing.allocator, c[0]);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}


test "url clean strips trackers and preserves signed URLs" {
    const gpa = std.testing.allocator;
    const yt = (try clean(gpa, "https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc123&utm_source=share&t=42s", .all_trackers)).?;
    defer gpa.free(yt);
    try std.testing.expectEqualStrings("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", yt);

    const click_only = (try clean(gpa, "https://example.com/page?utm_source=news&fbclid=IwAR123&gclid=abc", .click_ids_only)).?;
    defer gpa.free(click_only);
    try std.testing.expectEqualStrings("https://example.com/page?utm_source=news", click_only);

    const all_gone = (try clean(gpa, "https://example.com/page?utm_medium=email&fbclid=123", .all_trackers)).?;
    defer gpa.free(all_gone);
    try std.testing.expectEqualStrings("https://example.com/page", all_gone);

    const signed = try clean(gpa, "https://s3.amazonaws.com/bucket/file.pdf?X-Amz-Signature=deadbeef&utm_source=test&fbclid=123", .all_trackers);
    try std.testing.expect(signed == null);
}
test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Parts);
}
