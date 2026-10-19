//! A shortcut typed before the words (`Keyword.swift`): "yt cats" goes
//! straight to YouTube's search. Kept in defaults `search.keywords` as the
//! JSON of `[Keyword]`, the way `Prefs.keywords` writes it.
const std = @import("std");
const json = @import("json.zig");
const Store = @import("store.zig").Store;
const engine = @import("../model/engine.zig");
const Parts = @import("url.zig").Parts;

pub const key = "search.keywords";

pub const Keyword = struct {
    id: json.Uuid,
    keyword: []const u8,
    template: []const u8,

    /// What a row calls this: the site's bare host, else the template; on `gpa`.
    pub fn name(self: Keyword, gpa: std.mem.Allocator) ![]u8 {
        return try engine.bareHost(gpa, self.template) orelse gpa.dupe(u8, self.template);
    }

    /// The words after "<keyword> ", trimmed; null when they aren't there.
    // ponytail: ASCII case folding for the keyword; Unicode if one needs it.
    fn matches(self: Keyword, typed: []const u8) ?[]const u8 {
        const word = trim(self.keyword);
        if (word.len == 0) return null;
        const space = std.mem.indexOfScalar(u8, typed, ' ') orelse return null;
        if (!std.ascii.eqlIgnoreCase(typed[0..space], word)) return null;
        const rest = trim(typed[space + 1 ..]);
        return if (rest.len == 0) null else rest;
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
}

pub const Match = struct { keyword: Keyword, words: []const u8 };

/// The first keyword `typed` names, with the words to search it with.
pub fn match(typed: []const u8, keywords: []const Keyword) ?Match {
    for (keywords) |k| {
        if (!accepts(k.template)) continue;
        if (k.matches(typed)) |rest| return .{ .keyword = k, .words = rest };
    }
    return null;
}

/// http or https, one site whatever is searched for, and a single %s in the
/// path, query or fragment. "%s" holds no delimiter, so the template parses
/// where Swift's stand-in mark would.
pub fn accepts(template: []const u8) bool {
    const trimmed = trim(template);
    if (!engine.accepts(trimmed) or std.mem.count(u8, trimmed, "%s") != 1) return false;
    const p = Parts.parse(trimmed) orelse return false;
    for ([_]?[]const u8{ p.path, p.query, p.fragment }) |part|
        if (part != null and std.mem.indexOf(u8, part.?, "%s") != null) return true;
    return false;
}

/// Why `word` and `template` can't be saved alongside `keywords` yet, on
/// `gpa`, or null when they can.
pub fn problem(gpa: std.mem.Allocator, word_in: []const u8, template: []const u8, keywords: []const Keyword) !?[]u8 {
    const word = trim(word_in);
    if (word.len == 0) return try gpa.dupe(u8, "A word to type first, like yt");
    if (std.mem.indexOfAny(u8, word, " \t\r\n\x0b\x0c") != null) return try gpa.dupe(u8, "One word, with no spaces in it");
    for (keywords) |k| if (std.ascii.eqlIgnoreCase(k.keyword, word)) {
        const n = try k.name(gpa);
        defer gpa.free(n);
        return try std.fmt.allocPrint(gpa, "{s} already goes to {s}", .{ k.keyword, n });
    };
    if (!accepts(template)) return try gpa.dupe(u8, "An http or https address with %s once, where the words go");
    return null;
}

/// The saved list, every string on `gpa` (free with `freeList`); empty when
/// none is saved or it won't decode, as Swift's `?? []`.
pub fn load(gpa: std.mem.Allocator, store: *const Store) ![]Keyword {
    const bytes = store.data(key) orelse return &.{};
    defer store.gpa.free(bytes);
    const parsed = json.decode([]Keyword, gpa, bytes) catch return &.{};
    defer parsed.deinit();
    const out = try gpa.alloc(Keyword, parsed.value.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |k| {
            gpa.free(k.keyword);
            gpa.free(k.template);
        }
        gpa.free(out);
    }
    for (parsed.value) |k| {
        const kw = try gpa.dupe(u8, k.keyword);
        errdefer gpa.free(kw);
        out[n] = .{ .id = k.id, .keyword = kw, .template = try gpa.dupe(u8, k.template) };
        n += 1;
    }
    return out;
}

pub fn freeList(gpa: std.mem.Allocator, list: []const Keyword) void {
    for (list) |k| {
        gpa.free(k.keyword);
        gpa.free(k.template);
    }
    gpa.free(list);
}

/// Written through, as `Prefs.keywords`' `didSet`.
pub fn save(gpa: std.mem.Allocator, store: *const Store, list: []const Keyword) void {
    const bytes = json.encode(gpa, list) catch return;
    defer gpa.free(bytes);
    store.setData(key, bytes);
}

const testing = std.testing;

test "keywords fixture round-trips" {
    const gpa = testing.allocator;
    const fixture = @embedFile("../tests/fixtures/kea/keywords.json");
    const a = try json.decode([]Keyword, gpa, fixture);
    defer a.deinit();
    const out = try json.encode(gpa, a.value);
    defer gpa.free(out);
    const b = try json.decode([]Keyword, gpa, out);
    defer b.deinit();
    try testing.expectEqual(a.value.len, b.value.len);
    for (a.value, b.value) |x, y| {
        try testing.expect(x.id.eql(y.id));
        try testing.expectEqualStrings(x.keyword, y.keyword);
        try testing.expectEqualStrings(x.template, y.template);
    }
    try testing.expectEqualStrings("yt", a.value[0].keyword);
    // Every field is required, as synthesized Codable has it.
    try testing.expectError(error.MissingField, json.decode([]Keyword, gpa, "[{\"keyword\":\"yt\",\"template\":\"x\"}]"));
}

test "keywords match, accept and explain" {
    const gpa = testing.allocator;
    const list = [_]Keyword{
        .{ .id = json.Uuid.first, .keyword = "bad", .template = "https://%s.example.com/" },
        .{ .id = json.Uuid.first, .keyword = " YT ", .template = "https://www.youtube.com/results?search_query=%s" },
    };
    const m = match("yt   cats and dogs ", &list).?;
    try testing.expectEqualStrings("cats and dogs", m.words);
    try testing.expectEqualStrings(" YT ", m.keyword.keyword);
    try testing.expect(match("yt", &list) == null);
    try testing.expect(match("yt   ", &list) == null);
    try testing.expect(match("bad cats", &list) == null);
    try testing.expect(accepts("https://x.com/#q=%s"));
    try testing.expect(!accepts("https://x.com/?q=%s&r=%s"));
    try testing.expect(!accepts("https://%s@x.com/"));
    try testing.expect(!accepts("ftp://x.com/?q=%s"));
    const cases = [_][3][]const u8{
        .{ "", "https://a.com/?q=%s", "A word to type first, like yt" },
        .{ "a b", "https://a.com/?q=%s", "One word, with no spaces in it" },
        .{ "bad", "https://a.com/?q=%s", "bad already goes to https://%s.example.com/" },
        .{ "w", "https://a.com/", "An http or https address with %s once, where the words go" },
    };
    for (cases) |c| {
        const p = (try problem(gpa, c[0], c[1], &list)).?;
        defer gpa.free(p);
        try testing.expectEqualStrings(c[2], p);
    }
    try testing.expect(try problem(gpa, "w", "https://a.com/?q=%s", &list) == null);
}

test "keywords save and load through defaults" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    const none = try load(gpa, &store);
    try testing.expectEqual(@as(usize, 0), none.len);
    const list = [_]Keyword{.{ .id = json.Uuid.random(), .keyword = "w", .template = "https://en.wikipedia.org/w/index.php?search=%s" }};
    save(gpa, &store, &list);
    const back = try load(gpa, &store);
    defer freeList(gpa, back);
    try testing.expectEqual(@as(usize, 1), back.len);
    try testing.expect(back[0].id.eql(list[0].id));
    try testing.expectEqualStrings(list[0].template, back[0].template);
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(Keyword);
    // Foundation encodes a space in a template rather than refusing it.
    try testing.expect(accepts("https://x.com/?q=%s a"));
}
