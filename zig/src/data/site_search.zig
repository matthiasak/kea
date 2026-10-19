//! Searching a site from the address field (`SiteSearch` in
//! SiteSearch.swift): built-in popular sites, matched by the start of their
//! name, address or another name, and sites learned from their OpenSearch
//! description, matched by address only, kept in `search-sites.json`
//! (learned ones only, forty at most, the oldest going first).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("json.zig");
const url = @import("url.zig");
const keywords = @import("keywords.zig");
const registrable = @import("registrable.zig").registrable;
const Store = @import("store.zig").Store;
const learning = @import("site_search_learn.zig");

pub const SearchSite = struct {
    name: []const u8,
    /// The site, without its www.
    host: []const u8,
    /// Where the words go: http or https, %s once (see `keywords.accepts`).
    template: []const u8,
    /// Other beginnings that name it: "yt" for YouTube.
    aliases: []const []const u8 = &.{},
};

pub const SiteSearch = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    /// Owns the locale-made strings of `built_in` and every site learned,
    /// so a match stays good for the life of the store.
    // ponytail: a forgotten or dropped site's bytes stay until quit; a few
    // hundred bytes per site learned, a freeing scheme if that ever matters.
    arena: std.heap.ArenaAllocator,
    built_in: [15]SearchSite = undefined,
    learned: []const SearchSite = &.{},
    /// Descriptions being fetched (see `learn`).
    inflight: std.ArrayList(*learning.Job) = .empty,

    pub const file = "search-sites.json";
    /// Never more than this many learned: the oldest go first.
    pub const most = 40;

    pub const learn = learning.learn;

    pub fn init(gpa: std.mem.Allocator, store: *Store) SiteSearch {
        var self: SiteSearch = .{ .gpa = gpa, .store = store, .arena = .init(gpa) };
        const a = self.arena.allocator();
        // Checked by hand in Swift on 28 Sep 2026.
        const lang = language(a);
        const amazon = amazonHost();
        self.built_in = .{
            .{ .name = "Reddit", .host = "reddit.com", .template = "https://www.reddit.com/search/?q=%s" },
            .{ .name = "YouTube", .host = "youtube.com", .template = "https://www.youtube.com/results?search_query=%s", .aliases = &.{"yt"} },
            .{ .name = "X", .host = "x.com", .template = "https://x.com/search?q=%s", .aliases = &.{"twitter"} },
            .{ .name = "ChatGPT", .host = "chatgpt.com", .template = "https://chatgpt.com/?q=%s", .aliases = &.{ "gpt", "openai" } },
            .{ .name = "Claude", .host = "claude.ai", .template = "https://claude.ai/new?q=%s" },
            .{ .name = "Perplexity", .host = "perplexity.ai", .template = "https://www.perplexity.ai/search?q=%s" },
            .{ .name = "Wikipedia", .host = "wikipedia.org", .template = std.fmt.allocPrint(a, "https://{s}.wikipedia.org/w/index.php?search=%s", .{lang}) catch "https://en.wikipedia.org/w/index.php?search=%s", .aliases = &.{"wiki"} },
            .{ .name = "GitHub", .host = "github.com", .template = "https://github.com/search?q=%s", .aliases = &.{"gh"} },
            .{ .name = "Stack Overflow", .host = "stackoverflow.com", .template = "https://stackoverflow.com/search?q=%s", .aliases = &.{"so"} },
            .{ .name = "MDN", .host = "developer.mozilla.org", .template = "https://developer.mozilla.org/search?q=%s" },
            .{ .name = "Amazon", .host = amazon, .template = std.fmt.allocPrint(a, "https://www.{s}/s?k=%s", .{amazon}) catch "https://www.amazon.com/s?k=%s" },
            .{ .name = "Google Maps", .host = "google.com/maps", .template = "https://www.google.com/maps/search/%s", .aliases = &.{"maps"} },
            .{ .name = "IMDb", .host = "imdb.com", .template = "https://www.imdb.com/find/?q=%s" },
            .{ .name = "Spotify", .host = "open.spotify.com", .template = "https://open.spotify.com/search/%s" },
            .{ .name = "Figma Community", .host = "figma.com/community", .template = "https://www.figma.com/community/search?resource_type=mixed&sort_by=relevancy&query=%s" },
        };
        self.load();
        return self;
    }

    pub fn deinit(self: *SiteSearch) void {
        // A fetch that lands after this finds no store.
        for (self.inflight.items) |job| job.ss = null;
        self.inflight.deinit(self.gpa);
        self.arena.deinit();
    }

    /// The site the words typed so far begin the name of: two characters at
    /// least, no space or slash. A built-in one by its name, address or
    /// another name; a learned one by its address only, never the name it
    /// gives itself. The shortest name wins.
    pub fn match(self: *const SiteSearch, typed: []const u8) ?SearchSite {
        const lowered = url.lower(self.gpa, std.mem.trim(u8, typed, " \t")) catch return null;
        defer self.gpa.free(lowered);
        const word = lowered;
        const chars = std.unicode.utf8CountCodepoints(word) catch word.len;
        if (chars < 2 or std.mem.indexOfAny(u8, word, " /") != null) return null;
        var best: ?SearchSite = null;
        for (self.built_in) |site| {
            const named = squashedPrefix(site.name, word) or std.mem.startsWith(u8, withoutWWW(site.host), word) or
                for (site.aliases) |alias| {
                    if (std.mem.startsWith(u8, alias, word)) break true;
                } else false;
            if (named and (best == null or site.name.len < best.?.name.len)) best = site;
        }
        if (best != null) return best;
        for (self.learned) |site| {
            if (std.mem.startsWith(u8, site.host, word) and (best == null or site.host.len < best.?.host.len)) best = site;
        }
        return best;
    }

    /// A learned site kept, named by its address (the only name it can't
    /// choose for itself), then saved.
    pub fn adopt(self: *SiteSearch, host: []const u8, template: []const u8) void {
        if (!keywords.accepts(template) or !sameSite(self.gpa, template, host)) return;
        for (self.learned) |s| if (std.mem.eql(u8, s.host, host)) return;
        const a = self.arena.allocator();
        const site = json.clone(a, SearchSite{ .name = host, .host = host, .template = template }) catch return;
        const kept = self.learned[(self.learned.len + 1) -| most ..];
        const next = a.alloc(SearchSite, kept.len + 1) catch return;
        @memcpy(next[0..kept.len], kept);
        next[kept.len] = site;
        self.learned = next;
        self.store.save(file, self.learned, false);
    }

    /// Forgotten, all of them: with the history.
    pub fn forget(self: *SiteSearch) void {
        self.learned = &.{};
        const path = self.store.file(file) catch return;
        defer self.gpa.free(path);
        self.store.disk.remove(path);
    }

    /// Named by their address, whatever an earlier build wrote; ones that
    /// would not be kept today are passed over (not written back until the
    /// next `adopt`).
    fn load(self: *SiteSearch) void {
        const p = self.store.load([]const SearchSite, file) orelse return;
        defer p.deinit();
        var list: std.ArrayList(SearchSite) = .empty;
        defer list.deinit(self.gpa);
        for (p.value) |s| {
            if (!keywords.accepts(s.template) or !sameSite(self.gpa, s.template, s.host)) continue;
            list.append(self.gpa, .{ .name = s.host, .host = s.host, .template = s.template }) catch return;
        }
        self.learned = json.clone(self.arena.allocator(), list.items) catch &.{};
    }
};

/// `address` is on the same site as `host`: the same host, or the same
/// registrable domain (so foo.github.io can't name github.io).
pub fn sameSite(gpa: std.mem.Allocator, address: []const u8, host: []const u8) bool {
    const other = siteHost(gpa, address) orelse return false;
    defer gpa.free(other);
    const mine = bare(host);
    if (std.mem.eql(u8, other, mine)) return true;
    const a = registrable(gpa, other) catch return false;
    defer gpa.free(a);
    const b = registrable(gpa, mine) catch return false;
    defer gpa.free(b);
    return std.mem.eql(u8, a, b);
}

/// An address's host, lowercased and without its www (a template's with
/// its %s filled), on `gpa`.
pub fn siteHost(gpa: std.mem.Allocator, address: []const u8) ?[]u8 {
    const filled = std.mem.replaceOwned(u8, gpa, address, "%s", "x") catch return null;
    defer gpa.free(filled);
    const p = url.Parts.parse(filled) orelse return null;
    if (!p.isWeb()) return null;
    const h = url.lower(gpa, p.hostName() orelse return null) catch return null;
    if (!std.mem.startsWith(u8, h, "www.")) return h;
    defer gpa.free(h);
    return gpa.dupe(u8, h[4..]) catch null;
}

/// The host part of a built-in's "host/path", without its www.
pub fn bare(host: []const u8) []const u8 {
    return withoutWWW(host[0 .. std.mem.indexOfScalar(u8, host, '/') orelse host.len]);
}

fn withoutWWW(host: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
}

/// `name.lowercased()` with its spaces removed begins with `word`.
fn squashedPrefix(name: []const u8, word: []const u8) bool {
    var i: usize = 0;
    for (name) |ch| {
        if (ch == ' ') continue;
        if (i == word.len) return true;
        if (std.ascii.toLower(ch) != word[i]) return false;
        i += 1;
    }
    return i == word.len;
}

/// Wikipedia in the Mac's first language: its code if all letters and at
/// most three long, else "en".
fn language(a: std.mem.Allocator) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const langs = objc.msg(objc.Object, objc.class("NSLocale"), "preferredLanguages", .{});
    if (objc.msg(objc.NSUInteger, langs, "count", .{}) == 0) return "en";
    const first = objc.msg(objc.Object, langs, "firstObject", .{});
    const parts = objc.msg(objc.Object, objc.class("NSLocale"), "componentsFromLocaleIdentifier:", .{first});
    const code = objc.msg(?objc.Object, parts, "objectForKey:", .{objc.nsString("kCFLocaleLanguageCodeKey")}) orelse return "en";
    const s = objc.fromNSString(code);
    if (s.len == 0 or s.len > 3) return "en";
    for (s) |ch| if (!std.ascii.isAlphabetic(ch)) return "en";
    return a.dupe(u8, s) catch "en";
}

/// Amazon's own shop for the Mac's region.
fn amazonHost() []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const locale = objc.msg(objc.Object, objc.class("NSLocale"), "currentLocale", .{});
    const region = objc.msg(?objc.Object, locale, "objectForKey:", .{objc.nsString("kCFLocaleCountryCodeKey")}) orelse return "amazon.com";
    const r = objc.fromNSString(region);
    const table = [_]struct { []const u8, []const u8 }{
        .{ "FR", "amazon.fr" },     .{ "DE", "amazon.de" },     .{ "AT", "amazon.de" },
        .{ "GB", "amazon.co.uk" },  .{ "IE", "amazon.co.uk" },  .{ "IT", "amazon.it" },
        .{ "ES", "amazon.es" },     .{ "NL", "amazon.nl" },     .{ "BE", "amazon.com.be" },
        .{ "JP", "amazon.co.jp" },  .{ "CA", "amazon.ca" },     .{ "AU", "amazon.com.au" },
        .{ "IN", "amazon.in" },     .{ "BR", "amazon.com.br" }, .{ "MX", "amazon.com.mx" },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], r)) return row[1];
    return "amazon.com";
}

test "search-sites fixture round-trips" {
    try @import("../tests/roundtrip.zig").check([]const SearchSite, @embedFile("../tests/fixtures/kea/search-sites.json"), false);
}

test "site search matches built-ins and learned sites, and learns forty at most" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    store.write(SiteSearch.file, try gpa.dupe(u8, @embedFile("../tests/fixtures/kea/search-sites.json")), true);
    var ss = SiteSearch.init(gpa, &store);
    defer ss.deinit();
    // Renamed to their host; a %s in the host and another site's template are dropped.
    try std.testing.expectEqual(@as(usize, 2), ss.learned.len);
    try std.testing.expectEqualStrings("docs.rs", ss.learned[1].name);
    try std.testing.expectEqual(@as(usize, 0), ss.learned[1].aliases.len);
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "gi", "GitHub" },       .{ "GitHub ", "GitHub" }, .{ "yt", "YouTube" },  .{ "tw", "X" },
        .{ "so", "Stack Overflow" }, .{ "stackov", "Stack Overflow" }, .{ "googlem", "Google Maps" },
        .{ "ma", "Google Maps" },  .{ "re", "Reddit" },      .{ "ex", "example.com" }, .{ "do", "docs.rs" },
        .{ "g", null },            .{ "gi hub", null },      .{ "github.com/x", null }, .{ "zz", null },
    };
    for (cases) |c| {
        const got = ss.match(c[0]);
        if (c[1]) |want| try std.testing.expectEqualStrings(want, got.?.name) else try std.testing.expect(got == null);
    }
    // A learned site needs a template on its own site.
    ss.adopt("mine.com", "https://other.com/?q=%s");
    try std.testing.expectEqual(@as(usize, 2), ss.learned.len);
    var buf: [64]u8 = undefined;
    var tbuf: [96]u8 = undefined;
    for (0..45) |i| {
        const host = try std.fmt.bufPrint(&buf, "site{d}.com", .{i});
        ss.adopt(host, try std.fmt.bufPrint(&tbuf, "https://www.{s}/search?q=%s", .{host}));
    }
    try std.testing.expectEqual(@as(usize, SiteSearch.most), ss.learned.len);
    try std.testing.expectEqualStrings("site5.com", ss.learned[0].host);
    try std.testing.expectEqualStrings("site44.com", ss.learned[39].host);
    store.disk.drain();
    var again = SiteSearch.init(gpa, &store);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, SiteSearch.most), again.learned.len);
    ss.forget();
    try std.testing.expectEqual(@as(usize, 0), ss.learned.len);
    store.disk.drain();
    try std.testing.expect(store.readFile(SiteSearch.file) == null);
}

test "sameSite takes the same host or registrable domain" {
    const gpa = std.testing.allocator;
    try std.testing.expect(sameSite(gpa, "https://www.Example.com/s?q=%s", "example.com"));
    try std.testing.expect(sameSite(gpa, "https://search.example.com/?q=%s", "example.com"));
    try std.testing.expect(!sameSite(gpa, "https://other.com/?q=%s", "example.com"));
    try std.testing.expect(!sameSite(gpa, "ftp://example.com/%s", "example.com"));
    try std.testing.expect(sameSite(gpa, "https://www.google.com/maps/search/%s", "google.com/maps"));
}

test {
    _ = learning;
}
