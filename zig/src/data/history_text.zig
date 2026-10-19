//! `History.swift`'s pure parts: a visit, URL identity, the text a visit is
//! searched by, how a match ranks, and the well-known addresses.
const std = @import("std");
const json = @import("json.zig");
const url_mod = @import("url.zig");
const address = @import("../model/address.zig");
const Parts = url_mod.Parts;

pub const Visit = struct {
    url: []const u8,
    key: []const u8,
    title: []const u8,
    count: i64,
    last: json.SwiftDate,
};

/// Visits counted at most: far more than anyone makes, and room to add.
pub const most_visits: i64 = 1_000_000_000;

/// Derived once when a visit enters memory; every string on the history's gpa.
pub const PageText = struct {
    address: []u8,
    searchable: []u8,
    host: []u8,
    homepage: bool,
    title: []u8,

    pub fn deinit(t: PageText, gpa: std.mem.Allocator) void {
        gpa.free(t.address);
        gpa.free(t.searchable);
        gpa.free(t.host);
        gpa.free(t.title);
    }
};

pub const Suggestion = struct {
    /// What you could type to get here, kept reversible for completion.
    key: []const u8,
    title: []const u8,
    url: []const u8,
    kind: Kind,
    /// Set when this is a page you already have open somewhere.
    tab: ?json.Uuid = null,

    pub const Kind = enum { open, visited, known, search };
};

/// Everywhere you have been, newest first, for the window that shows it.
pub const Trace = struct {
    key: []const u8,
    /// A reversible address for display; `key` is the stable URL identity.
    address: []const u8,
    title: []const u8,
    url: []const u8,
    last: json.SwiftDate,
    count: i64,
};

/// Fragments ignored, scheme and host lowercased, user and password gone,
/// an absent path a lone slash; path and query kept as spelled. On `gpa`.
pub fn identity(gpa: std.mem.Allocator, page: []const u8) ![]u8 {
    var p = Parts.parse(page) orelse return gpa.dupe(u8, page);
    var buf: [2][]const u8 = .{ "", "" };
    defer for (buf) |b| gpa.free(b);
    if (p.scheme) |s| {
        buf[0] = try std.ascii.allocLowerString(gpa, s);
        p.scheme = buf[0];
    }
    if (p.host) |h| {
        buf[1] = try url_mod.lower(gpa, h);
        p.host = buf[1];
    }
    p.user = null;
    p.password = null;
    p.fragment = null;
    if (p.path.len == 0) p.path = "/";
    return p.string(gpa);
}

/// A page without a name and password written into its address; on `gpa`,
/// null when it won't parse.
pub fn kept(gpa: std.mem.Allocator, page: []const u8) !?[]u8 {
    var p = Parts.parse(page) orelse return null;
    if (p.user == null and p.password == null) return try gpa.dupe(u8, page);
    p.user = null;
    p.password = null;
    return try p.string(gpa);
}

pub fn isWeb(page: []const u8) bool {
    const p = Parts.parse(page) orelse return false;
    return p.isWeb();
}

/// The site's front door: the same origin at "/"; on `gpa`.
pub fn homepage(gpa: std.mem.Allocator, page: []const u8) !?[]u8 {
    var p = Parts.parse(page) orelse return null;
    p.user = null;
    p.password = null;
    p.path = "/";
    p.query = null;
    p.fragment = null;
    return try p.string(gpa);
}

pub fn isHomePath(path: []const u8) bool {
    return path.len == 0 or std.mem.eql(u8, path, "/");
}

/// The text a page is searched by (title left empty); null when it won't parse.
pub fn pageText(gpa: std.mem.Allocator, page: []const u8) !?PageText {
    var p = Parts.parse(page) orelse return null;
    p.fragment = null;
    const shown = try p.string(gpa);
    defer gpa.free(shown);
    const addr = try address.editable(gpa, shown);
    errdefer gpa.free(addr);
    const searchable = try stripped(gpa, addr);
    errdefer gpa.free(searchable);
    const lowered = try url_mod.lower(gpa, p.hostName() orelse "");
    defer gpa.free(lowered);
    const host = try gpa.dupe(u8, if (std.mem.startsWith(u8, lowered, "www.")) lowered[4..] else lowered);
    errdefer gpa.free(host);
    return .{ .address = addr, .searchable = searchable, .host = host, .homepage = isHomePath(p.path), .title = try gpa.dupe(u8, "") };
}

/// Typed or shown text as matched: trimmed, lowercased, no scheme, no www.
pub fn stripped(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const low = try url_mod.lower(gpa, std.mem.trim(u8, text, " \t"));
    defer gpa.free(low);
    var t: []const u8 = low;
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        if (std.mem.startsWith(u8, t, scheme)) t = t[scheme.len..];
    }
    if (std.mem.startsWith(u8, t, "www.")) t = t[4..];
    return gpa.dupe(u8, t);
}

/// Swift's `String.count`, near enough: code points.
pub fn chars(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Often, and lately: a month-old visit counts about a third of a fresh one.
pub fn score(v: Visit, now: json.SwiftDate) f64 {
    const days = @max(0, (now - v.last) / 86_400);
    return @as(f64, @floatFromInt(v.count)) * @exp(-days / 30);
}

/// Where the match falls decides most of the ordering: the start of the
/// host is what people mean, the middle of a path almost never is.
pub fn rank(key: []const u8, needle: []const u8) ?f64 {
    if (std.mem.startsWith(u8, key, needle)) return 6;
    const host = key[0 .. std.mem.indexOfAny(u8, key, "/?#") orelse key.len];
    // "google" finding mail.google.com without the subdomain.
    if (std.mem.indexOfScalar(u8, host, '.')) |dot| {
        const after = host[dot + 1 ..];
        if (std.mem.indexOfScalar(u8, after, '.') != null and std.mem.startsWith(u8, after, needle)) return 3;
    }
    // From two letters up, and never into the last label.
    if (chars(needle) >= 2) {
        const searched = if (std.mem.indexOfScalar(u8, needle, '.') != null) host else host[0 .. std.mem.lastIndexOfScalar(u8, host, '.') orelse host.len];
        if (std.mem.indexOf(u8, searched, needle) != null) return 2;
    }
    return null;
}

pub const Known = struct { host: []const u8, title: []const u8, url: []const u8 };

fn k(comptime host: []const u8, comptime title: []const u8) Known {
    return .{ .host = host, .title = title, .url = "https://" ++ host };
}

/// Somewhere to start on the first day, before there is any history.
pub const known = [_]Known{
    k("google.com", "Google"),                 k("mail.google.com", "Gmail"),
    k("drive.google.com", "Google Drive"),     k("calendar.google.com", "Google Calendar"),
    k("maps.google.com", "Google Maps"),       k("youtube.com", "YouTube"),
    k("github.com", "GitHub"),                 k("figma.com", "Figma"),
    k("vercel.com", "Vercel"),                 k("notion.so", "Notion"),
    k("linear.app", "Linear"),                 k("slack.com", "Slack"),
    k("discord.com", "Discord"),               k("x.com", "X"),
    k("linkedin.com", "LinkedIn"),             k("instagram.com", "Instagram"),
    k("reddit.com", "Reddit"),                 k("news.ycombinator.com", "Hacker News"),
    k("stackoverflow.com", "Stack Overflow"),  k("claude.ai", "Claude"),
    k("chatgpt.com", "ChatGPT"),               k("dribbble.com", "Dribbble"),
    k("behance.net", "Behance"),               k("awwwards.com", "Awwwards"),
    k("mobbin.com", "Mobbin"),                 k("siteinspire.com", "SiteInspire"),
    k("are.na", "Are.na"),                     k("pinterest.com", "Pinterest"),
    k("framer.com", "Framer"),                 k("webflow.com", "Webflow"),
    k("developer.apple.com", "Apple Developer"), k("swift.org", "Swift"),
    k("npmjs.com", "npm"),                     k("supabase.com", "Supabase"),
    k("stripe.com", "Stripe"),                 k("shopify.com", "Shopify"),
    k("cloudflare.com", "Cloudflare"),         k("netlify.com", "Netlify"),
    k("apple.com", "Apple"),                   k("spotify.com", "Spotify"),
    k("netflix.com", "Netflix"),               k("wikipedia.org", "Wikipedia"),
    k("deepl.com", "DeepL"),                   k("loom.com", "Loom"),
    k("amazon.fr", "Amazon"),                  k("leboncoin.fr", "leboncoin"),
    k("lemonde.fr", "Le Monde"),
};

/// What `typed` completes to among `options`: the rest of the best match's
/// address, or null when it doesn't carry on from what was typed. The rest
/// is a slice of an option's key.
pub fn completion(gpa: std.mem.Allocator, typed: []const u8, options: []const Suggestion) !?[]const u8 {
    const n = chars(typed);
    if (n < 2) return null;
    for (options) |option| {
        // Its address as shown, and for a www site the name without the www.
        var keys: [2][]const u8 = .{ option.key, "" };
        var targets: [2][]const u8 = .{ try identity(gpa, option.url), "" };
        defer for (targets) |t| gpa.free(t);
        var count: usize = 1;
        if (std.ascii.startsWithIgnoreCase(option.key, "www.")) {
            if (Parts.parse(option.url)) |parsed| {
                var p = parsed;
                const h = p.host orelse "";
                if (std.ascii.startsWithIgnoreCase(h, "www.")) {
                    p.host = h[4..];
                    const bare = try p.string(gpa);
                    defer gpa.free(bare);
                    keys[1] = option.key[4..];
                    targets[1] = try identity(gpa, bare);
                    count = 2;
                }
            }
        }
        for (keys[0..count], targets[0..count]) |key, target| {
            if (chars(key) < n) continue;
            const cut = prefixBytes(key, n);
            // ponytail: ASCII case folding; Unicode folding if a host needs it.
            if (!std.ascii.eqlIgnoreCase(key[0..cut], typed)) continue;
            const rest = key[cut..];
            const joined = try std.mem.concat(gpa, u8, &.{ typed, rest });
            defer gpa.free(joined);
            const completed = try address.url(gpa, joined) orelse continue;
            defer gpa.free(completed);
            const id = try identity(gpa, completed);
            defer gpa.free(id);
            if (!std.mem.eql(u8, id, target)) continue;
            return if (rest.len == 0) null else rest;
        }
    }
    return null;
}

/// Bytes in the first `n` code points of `s`.
fn prefixBytes(s: []const u8, n: usize) usize {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var i: usize = 0;
    while (i < n) : (i += 1) _ = it.nextCodepointSlice() orelse break;
    return it.i;
}

const testing = std.testing;

test "history identity, kept and homepage" {
    const gpa = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "HTTPS://User:pw@WWW.Example.com:8080/Path?a=1#frag", "https://www.example.com:8080/Path?a=1" },
        .{ "https://example.com", "https://example.com/" },
        .{ "https://example.com/A%20b?Q", "https://example.com/A%20b?Q" },
        .{ "not a url", "not a url" },
    };
    for (cases) |c| {
        const got = try identity(gpa, c[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
    const clean = (try kept(gpa, "https://me:secret@example.com/x")).?;
    defer gpa.free(clean);
    try testing.expectEqualStrings("https://example.com/x", clean);
    const home = (try homepage(gpa, "https://me@example.com:81/x?y#z")).?;
    defer gpa.free(home);
    try testing.expectEqualStrings("https://example.com:81/", home);
    try testing.expect(isWeb("HTTP://x.com") and !isWeb("file:///tmp") and !isWeb("about:blank"));
}

test "history page text and rank" {
    const gpa = testing.allocator;
    const t = (try pageText(gpa, "https://www.Example.com/#top")).?;
    defer t.deinit(gpa);
    try testing.expectEqualStrings("www.Example.com", t.address);
    try testing.expectEqualStrings("example.com", t.searchable);
    try testing.expectEqualStrings("example.com", t.host);
    try testing.expect(t.homepage);
    try testing.expectEqual(@as(?f64, 6), rank("github.com", "git"));
    try testing.expectEqual(@as(?f64, 3), rank("mail.google.com/x", "google"));
    try testing.expectEqual(@as(?f64, 2), rank("netflix.com", "fli"));
    try testing.expectEqual(@as(?f64, null), rank("netflix.com", "x"));
    try testing.expectEqual(@as(?f64, null), rank("other.com", "co"));
    try testing.expectEqual(@as(?f64, 2), rank("other.com", "r.co"));
    try testing.expectEqual(@as(?f64, null), rank("example.com/blog", "blog"));
}
