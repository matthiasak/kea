//! Bookmark categories: the top level kept flat, each site carrying the topic it is filed
//! under (`Bookmark.category`), a topic's sites together in one run and the unsorted ones last.
//! A site joins a run by its name ASCII case-insensitively, the run's own spelling winning.
const std = @import("std");
const json = @import("json.zig");
const address = @import("../model/address.zig");
const bm = @import("bookmarks.zig");
const Bookmarks = bm.Bookmarks;
const Bookmark = bm.Bookmark;
const Uuid = json.Uuid;

/// A bookmark just added and where it was put before the AI had a say. `expected_category`
/// points into the tree as it stood: dupe it to keep it past the next change.
pub const OptimisticAdd = struct {
    id: Uuid,
    /// Filed by its site alone, a site of one topic: nothing left to ask.
    matched_host: bool,
    expected_category: ?[]const u8,
    expected_index: usize,
};

pub const GroupSummary = struct {
    category: []const u8,
    count: usize,
    sample_title: []const u8,
    sample_host: []const u8,
    second_host: []const u8 = "",
};

/// Where the AI wants a new bookmark: in `category`, before `before_id` when that is one of its
/// own; a category not here yet goes after `after_category`, else before `before_category`.
pub const PlaceSpec = struct {
    category: ?[]const u8,
    after_category: ?[]const u8 = null,
    before_category: ?[]const u8 = null,
    before_id: ?Uuid = null,
};

/// Sites that span topics: one bookmark there says little about the next, so the AI is still asked.
const multi_topic_hosts = [_][]const u8{
    "github.com", "gist.github.com",      "youtube.com",     "youtu.be",
    "reddit.com", "old.reddit.com",       "x.com",           "twitter.com",
    "medium.com", "substack.com",         "wikipedia.org",   "en.wikipedia.org",
    "arxiv.org",  "news.ycombinator.com", "docs.google.com", "notion.so",
};

/// A category as it is kept: trimmed, at most 80 bytes cut on a code point; null for none.
pub fn norm(raw: ?[]const u8) ?[]const u8 {
    const s = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    var end = @min(s.len, 80);
    while (end > 0 and end < s.len and (s[end] & 0xC0) == 0x80) end -= 1;
    const cut = std.mem.trim(u8, s[0..end], " \t\r\n");
    return if (cut.len == 0) null else cut;
}

pub fn optEq(a: ?[]const u8, b: ?[]const u8) bool {
    const x = norm(a) orelse return norm(b) == null;
    return std.mem.eql(u8, x, norm(b) orelse return false);
}

/// A site's category; none for a folder.
fn catOf(b: Bookmark) ?[]const u8 {
    return if (b.isFolder()) null else norm(b.category);
}

fn inCat(b: Bookmark, normed: []const u8) bool {
    return std.ascii.eqlIgnoreCase(catOf(b) orelse return false, normed);
}

/// How many categories the sites of `nodes` are filed under. No allocation.
// ponytail: a run's first site rescans what is above it, O(n·runs); memoize on `revision` if a frame needs it.
pub fn countCategories(nodes: []const Bookmark) usize {
    var n: usize = 0;
    var last: []const u8 = "";
    for (nodes, 0..) |b, i| {
        const c = catOf(b) orelse continue;
        if (std.mem.eql(u8, c, last)) continue;
        last = c;
        n += @intFromBool(for (nodes[0..i]) |p| {
            if (std.mem.eql(u8, catOf(p) orelse continue, c)) break false;
        } else true);
    }
    return n;
}

/// Every top-level category in the order it first appears, with what tells it apart. All copied onto `a`.
pub fn orderedGroups(a: std.mem.Allocator, roots: []const Bookmark) ![]GroupSummary {
    var out: std.ArrayList(GroupSummary) = .empty;
    for (roots) |b| {
        const c = catOf(b) orelse continue;
        const host = bm.siteOf(b);
        const g = for (out.items) |*x| {
            if (std.mem.eql(u8, x.category, c)) break x;
        } else {
            const title = if (b.unnamed()) try b.label(a) else try a.dupe(u8, b.title);
            try out.append(a, .{ .category = try a.dupe(u8, c), .count = 1, .sample_title = title, .sample_host = try a.dupe(u8, host) });
            continue;
        };
        g.count += 1;
        if (g.sample_host.len == 0) {
            g.sample_host = try a.dupe(u8, host);
        } else if (g.second_host.len == 0 and host.len > 0 and !std.ascii.eqlIgnoreCase(host, g.sample_host)) {
            g.second_host = try a.dupe(u8, host);
        }
    }
    return out.items;
}

/// The top-level sites under `cat_name`, in order. The list is on `a`; their strings are the tree's own.
pub fn itemsInCategory(a: std.mem.Allocator, roots: []const Bookmark, cat_name: []const u8) ![]Bookmark {
    var out: std.ArrayList(Bookmark) = .empty;
    const c = norm(cat_name) orelse return out.items;
    for (roots) |b| if (inCat(b, c)) try out.append(a, b);
    return out.items;
}

const Run = struct { start: usize, end: usize };

/// The last unbroken run of top-level sites under `raw`, `end` past its last.
fn lastRun(roots: []const Bookmark, raw: ?[]const u8) ?Run {
    const c = norm(raw) orelse return null;
    var end = roots.len;
    while (end > 0 and !inCat(roots[end - 1], c)) end -= 1;
    if (end == 0) return null;
    var start = end - 1;
    while (start > 0 and inCat(roots[start - 1], c)) start -= 1;
    return .{ .start = start, .end = end };
}

/// Where the unsorted sites at the end begin.
fn tailStart(roots: []const Bookmark) usize {
    var at = roots.len;
    while (at > 0 and !roots[at - 1].isFolder() and norm(roots[at - 1].category) == null) at -= 1;
    return at;
}

/// Where `title` goes in a run kept by name; the run's end when it isn't.
fn titleSlot(roots: []const Bookmark, run: Run, title: []const u8) usize {
    var at = run.end;
    for (run.start..run.end) |k| {
        if (k > run.start and json.keyOrder(roots[k - 1].title, roots[k].title) == .gt) return run.end;
        if (at == run.end and json.keyOrder(title, roots[k].title) == .lt) at = k;
    }
    return at;
}

/// The one category every filed top-level site on `host` shares; null when none is filed or they disagree.
fn hostCategory(roots: []const Bookmark, host: []const u8) ?[]const u8 {
    if (host.len == 0) return null;
    var found: ?[]const u8 = null;
    for (roots) |r| {
        const c = catOf(r) orelse continue;
        if (!std.ascii.eqlIgnoreCase(bm.siteOf(r), host)) continue;
        if (found) |f| if (!std.ascii.eqlIgnoreCase(f, c)) return null;
        found = found orelse c;
    }
    return found;
}

/// The page kept at once, unless already kept: beside its own site's bookmarks in the category they
/// share, else at the end unsorted, for `applyAutoPlacement` to file when the AI answers.
pub fn addOptimistic(self: *Bookmarks, address_: []const u8, title: []const u8) ?OptimisticAdd {
    if (self.contains(address_)) return null;
    const host = bm.siteOf(.{ .id = undefined, .title = "", .url = address_ });
    if (hostCategory(self.roots, host)) |c| return inherit(self, address_, title, host, c) catch null;
    const id = self.add(address_, title) orelse return null;
    return .{ .id = id, .matched_host = false, .expected_category = null, .expected_index = self.roots.len - 1 };
}

fn inherit(self: *Bookmarks, address_: []const u8, title: []const u8, host: []const u8, c: []const u8) !OptimisticAdd {
    var w = self.begin() orelse return error.OutOfMemory;
    errdefer w.drop();
    const a = w.allocator();
    const named = if (title.len == 0) try address.pretty(a, address_) else title;
    const made = try json.clone(a, Bookmark{ .id = Uuid.random(), .title = named, .url = address_, .category = c });
    // Next to its own site, by name among them: a run in the AI's order stays in it.
    const run = lastRun(w.roots, c).?;
    var at = run.end;
    for (run.start..run.end) |k| {
        if (!std.ascii.eqlIgnoreCase(bm.siteOf(w.roots[k]), host)) continue;
        if (at == run.end) at = k;
        if (json.keyOrder(w.roots[k].title, made.title) != .gt) at = k + 1;
    }
    _ = try bm.place(a, made, null, at, &w.roots);
    self.commit(&w);
    const multi = for (multi_topic_hosts) |h| {
        if (std.ascii.eqlIgnoreCase(h, host)) break true;
    } else false;
    return .{ .id = made.id, .matched_host = !multi, .expected_category = made.category, .expected_index = at };
}

/// Files `id` where the AI said, unless it was touched while the answer was on its way: removed, put in a
/// folder, given another category, or moved out of the unsorted tail. Its title and address stay as they
/// now read. True when it was filed.
pub fn applyAutoPlacement(self: *Bookmarks, id: Uuid, expected_cat: ?[]const u8, expected_index: usize, spec: PlaceSpec) bool {
    const want = norm(spec.category) orelse return false;
    const cur = for (self.roots, 0..) |r, i| {
        if (r.id.eql(id)) break i;
    } else return false;
    const here = self.roots[cur];
    if (here.isFolder() or !optEq(here.category, expected_cat)) return false;
    // Other bookmarks filed meanwhile shift it: still unsorted at the end, it is still the AI's to file.
    if (norm(expected_cat) == null and cur != expected_index and tailStart(self.roots) > cur) return false;
    // Already in that category, beside its own site: left there.
    if (spec.before_id == null and inCat(here, want)) return false;
    var w = self.begin() orelse return false;
    const a = w.allocator();
    var node = bm.detach(id, &w.roots).?;
    var name = want;
    var at: usize = undefined;
    if (lastRun(w.roots, want)) |run| {
        name = norm(w.roots[run.start].category).?;
        at = titleSlot(w.roots, run, node.title);
        if (spec.before_id) |b| for (run.start..run.end) |k| {
            if (w.roots[k].id.eql(b)) at = k;
        };
    } else if (lastRun(w.roots, spec.after_category)) |after| {
        at = after.end;
    } else {
        // ponytail: "before" is before the category's last run; its first site if runs ever split.
        at = if (lastRun(w.roots, spec.before_category)) |before| before.start else tailStart(w.roots);
    }
    node.category = a.dupe(u8, name) catch null;
    const ok = node.category != null and (bm.place(a, node, null, at, &w.roots) catch false);
    if (ok) self.commit(&w) else w.drop();
    return ok;
}

/// A site's category set by hand, or cleared. At the top level it joins the end of that category's
/// run unless it already touches it.
pub fn setCategory(self: *Bookmarks, id: Uuid, category: ?[]const u8) void {
    var w = self.begin() orelse return;
    const a = w.allocator();
    const b = bm.findMut(w.roots, id) orelse return w.drop();
    if (b.isFolder()) return w.drop();
    const c = norm(category);
    const top = for (w.roots, 0..) |*r, i| {
        if (r == b) break i;
    } else null;
    if (c == null or top == null) {
        b.category = if (c) |s| (a.dupe(u8, s) catch return w.drop()) else null;
        return self.commit(&w);
    }
    var node = bm.detach(id, &w.roots).?;
    const run = lastRun(w.roots, c);
    node.category = a.dupe(u8, if (run) |r| norm(w.roots[r.start].category).? else c.?) catch return w.drop();
    const at = if (run) |r| (if (top.? >= r.start and top.? <= r.end) top.? else r.end) else top.?;
    _ = bm.place(a, node, null, at, &w.roots) catch return w.drop();
    self.commit(&w);
}

/// Sites just dropped at `roots[start..][0..count_moved]` take the category they landed in: the one
/// above, else the one below. Among unsorted neighbours they keep their own.
pub fn adoptNeighborCategory(a: std.mem.Allocator, roots: []Bookmark, start: usize, count_moved: usize) void {
    if (count_moved == 0 or start >= roots.len) return;
    const end = @min(roots.len, start + count_moved);
    const prev = if (start > 0) catOf(roots[start - 1]) else null;
    const next = if (end < roots.len) catOf(roots[end]) else null;
    const c = prev orelse next orelse return;
    for (roots[start..end]) |*n| if (!n.isFolder()) {
        n.category = a.dupe(u8, c) catch n.category;
    };
}

/// Each unbroken run of top-level sites under one category, the unsorted ones too, sorted on its own:
/// the categories keep the order they read in. A folder ends a run and stays where it is.
pub fn sortWithinRuns(roots: []Bookmark, key: bm.SortKey, comptime lessThan: fn (bm.SortKey, Bookmark, Bookmark) bool) void {
    var start: usize = 0;
    while (start < roots.len) {
        var end = start + 1;
        if (!roots[start].isFolder()) {
            const c = catOf(roots[start]);
            while (end < roots.len and !roots[end].isFolder() and (if (c) |n| inCat(roots[end], n) else catOf(roots[end]) == null)) end += 1;
            std.mem.sort(Bookmark, roots[start..end], key, lessThan);
        }
        start = end;
    }
}

test "categories: a new bookmark is filed by site, then by the AI, then by hand" {
    const gpa = std.testing.allocator;
    const expect = std.testing.expect;
    var temp = try @import("../tests/temp.zig").Temp.init(gpa);
    defer temp.deinit(gpa);
    var store = try @import("store.zig").Store.init(gpa, temp.root, temp.suite);
    defer store.deinit();
    var m = Bookmarks.init(gpa, &store);
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // 81 bytes, the 80th splitting an "é": cut before it.
    var long: [81]u8 = undefined;
    long[0] = 'a';
    for (0..40) |i| @memcpy(long[1 + 2 * i ..][0..2], "é");
    try expect(norm(" \t") == null and norm(&long).?.len == 79);
    try expect(optEq(" Dev ", "Dev") and !optEq("Dev", "dev") and optEq(null, ""));
    const a_id = m.add("https://a.example/", "A").?;
    _ = m.add("https://b.example/", "B");
    // Nothing filed yet: it waits at the end, then leads the unsorted ones.
    const caps = addOptimistic(&m, "https://mouser.com/caps", "Caps").?;
    try expect(!caps.matched_host and caps.expected_category == null and caps.expected_index == 2);
    try expect(applyAutoPlacement(&m, caps.id, null, 2, .{ .category = " Electronics " }) and m.roots[0].id.eql(caps.id));
    // A site of one topic: filed at once, by name beside its own, and not the AI's to move as unsorted.
    const amps = addOptimistic(&m, "https://www.mouser.com/amps", "Amps").?;
    try expect(amps.matched_host and amps.expected_index == 0 and optEq(amps.expected_category, "Electronics"));
    try expect(!applyAutoPlacement(&m, amps.id, null, 0, .{ .category = "Dev" }));
    // A new category goes after the one the AI named; a site of many topics is still asked.
    const zig = addOptimistic(&m, "https://github.com/ziglang/zig", "Zig").?;
    try expect(applyAutoPlacement(&m, zig.id, null, zig.expected_index, .{ .category = "Dev", .after_category = "electronics" }));
    const yak = addOptimistic(&m, "https://github.com/x/yak", "Yak").?;
    try expect(!yak.matched_host and yak.expected_index == 2 and m.roots[3].id.eql(zig.id) and m.roots[4].id.eql(a_id));
    const groups = try orderedGroups(arena.allocator(), m.roots);
    try expect(countCategories(m.roots) == 2 and groups.len == 2 and groups[1].count == 2);
    try std.testing.expectEqualStrings("github.com", groups[1].sample_host);
    try expect((try itemsInCategory(arena.allocator(), m.roots, "ELECTRONICS")).len == 2);
    // Dropped between two of a category it joins them; set by hand it joins that run's end, in its spelling.
    m.move(&.{a_id}, null, 1);
    try expect(optEq(m.bookmark(a_id).?.category, "Electronics"));
    setCategory(&m, a_id, "dev");
    try expect(m.roots[4].id.eql(a_id) and optEq(m.roots[4].category, "Dev"));
    // Filed by hand while the AI was thinking: left alone. And no nulls reach the file.
    try expect(!applyAutoPlacement(&m, a_id, null, 4, .{ .category = "News" }));
    store.disk.drain();
    const saved = store.readFile(Bookmarks.file).?;
    defer gpa.free(saved);
    try expect(std.mem.indexOf(u8, saved, "null") == null and std.mem.indexOf(u8, saved, "\"category\":\"Dev\"") != null);
}
