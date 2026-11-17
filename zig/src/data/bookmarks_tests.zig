//! Tests for `bookmarks.zig` and `bookmarks_merge.zig`.
const std = @import("std");
const json = @import("json.zig");
const Store = @import("store.zig").Store;
const Temp = @import("../tests/temp.zig").Temp;
const bm = @import("bookmarks.zig");
const Bookmarks = bm.Bookmarks;
const Bookmark = bm.Bookmark;
const Uuid = json.Uuid;
const gpa = std.testing.allocator;
const fixture = @embedFile("../tests/fixtures/kea/bookmarks.json");

fn id(n: u8) Uuid {
    var buf: [36]u8 = "A0B1C2D3-0000-4000-8000-000000000000".*;
    _ = std.fmt.bufPrint(buf[34..], "{d:0>2}", .{n}) catch unreachable;
    return Uuid.parse(&buf) catch unreachable;
}
const news = Uuid.parse("6F1D7E1A-3E5B-4A55-9B77-0C1E0A9A1A01") catch unreachable;

fn titles(a: std.mem.Allocator, nodes: []const Bookmark) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (nodes, 0..) |b, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, b.title);
    }
    return out.items;
}

/// Each run's category as the list reads: "-" for the unsorted, "/" for a folder.
fn runs(a: std.mem.Allocator, nodes: []const Bookmark) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var last: []const u8 = "";
    for (nodes) |b| {
        const c: []const u8 = if (b.isFolder()) "/" else b.category orelse "-";
        if (std.mem.eql(u8, c, last)) continue;
        if (last.len > 0) try out.append(a, ',');
        try out.appendSlice(a, c);
        last = c;
    }
    return out.items;
}

const World = struct {
    temp: Temp,
    store: Store,
    marks: Bookmarks,

    fn open(w: *World) !void {
        w.temp = try Temp.init(gpa);
        w.store = try Store.init(gpa, w.temp.root, w.temp.suite);
        w.store.write(Bookmarks.file, try gpa.dupe(u8, fixture), true);
        w.marks = Bookmarks.init(gpa, &w.store);
    }

    fn close(w: *World) void {
        w.marks.deinit();
        w.store.deinit();
        w.temp.deinit(gpa);
    }
};

test "bookmarks fixture round-trips" {
    try @import("../tests/roundtrip.zig").check([]Bookmark, fixture, false);
}

test "bookmarks tree with nested folders round-trips with ids" {
    var w: World = undefined;
    try w.open();
    defer w.close();
    const m = &w.marks;
    try std.testing.expectEqual(@as(usize, 3), m.roots.len);
    try std.testing.expectEqual(@as(usize, 4), Bookmarks.count(m.roots));
    m.update(id(2), "Hacker News \"HN\"", null);
    w.store.disk.drain();
    var again = Bookmarks.init(gpa, &w.store);
    defer again.deinit();
    const deep = again.bookmark(id(4)).?;
    try std.testing.expect(deep.isFolder());
    try std.testing.expectEqual(@as(usize, 0), deep.children.?[1].children.?.len);
    try std.testing.expectEqualStrings("Hacker News \"HN\"", again.bookmark(id(2)).?.title);
    try std.testing.expect(again.parent(id(5)).?.eql(id(4)));
    try std.testing.expect(again.parent(id(3)) == null);
    const saved = w.store.readFile(Bookmarks.file).?;
    defer gpa.free(saved);
    // Ids as Swift writes them, empty folders kept, no nulls.
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"id\":\"A0B1C2D3-0000-4000-8000-000000000003\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"title\":\"Empty\",\"children\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "null") == null);
    try std.testing.expect(std.mem.startsWith(u8, saved, "[{\"id\":\"6F1D7E1A-3E5B-4A55-9B77-0C1E0A9A1A01\",\"title\":\"News\",\"children\":[{"));
}

test "bookmarks read: matches, paths, folders, duplicates" {
    var w: World = undefined;
    try w.open();
    defer w.close();
    const m = &w.marks;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const found = try m.matches(a, "EXAMPLE b=");
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expect(found[0].node.id.eql(id(5)));
    try std.testing.expectEqualStrings("News", found[0].path[0]);
    try std.testing.expectEqualStrings("Deep", found[0].path[1]);
    try std.testing.expectEqual(@as(usize, 0), (try m.matches(a, "  ")).len);
    const path = (try m.pathTo(a, id(6))).?;
    try std.testing.expectEqual(@as(usize, 2), path.len);
    try std.testing.expect((try m.pathTo(a, Uuid.first)) == null);
    const fs = try Bookmarks.folders(a, m.roots);
    try std.testing.expectEqual(@as(usize, 3), fs.len);
    try std.testing.expectEqual(@as(usize, 2), fs[2].depth);
    try std.testing.expect(m.contains("https://www.apple.com/"));
    try std.testing.expect(m.bookmark(id(5)).?.unnamed());
    try std.testing.expectEqualStrings("example.com/a", try m.bookmark(id(5)).?.label(a));
    try std.testing.expect(m.add("https://www.apple.com/", "Again") == null);
    m.insert(.{ .id = id(9), .title = "Apple again", .url = "https://www.apple.com/" }, id(4), 0);
    const dupes = try m.duplicates(a);
    try std.testing.expectEqual(@as(usize, 1), dupes.len);
    try std.testing.expect(dupes[0].eql(id(3)));
}

test "bookmarks move, group, sort, remove" {
    var w: World = undefined;
    try w.open();
    defer w.close();
    const m = &w.marks;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const zed = m.add("https://zed.dev/", "").?;
    // What the caller passed is copied: its buffers can go.
    const title = try gpa.dupe(u8, "Mine");
    const addr = try gpa.dupe(u8, "https://mine.example/");
    const mine = m.add(addr, title).?;
    @memset(title, 'x');
    @memset(addr, 'x');
    gpa.free(title);
    gpa.free(addr);
    try std.testing.expectEqualStrings("Mine", m.bookmark(mine).?.title);
    try std.testing.expect(m.contains("https://mine.example/"));
    m.remove(&.{mine});
    try std.testing.expectEqualStrings("zed.dev", m.bookmark(zed).?.title);
    const rev = m.revision;
    // Just below itself: nothing changes, nothing is saved.
    m.move(&.{id(3)}, null, 2);
    try std.testing.expectEqual(rev, m.revision);
    // A folder into its own child is refused.
    m.move(&.{news}, id(4), null);
    try std.testing.expectEqual(rev, m.revision);
    // Apple and zed (and HN, which is inside News, read first) into Deep at 1.
    m.move(&.{ zed, id(3), id(2) }, id(4), 1);
    try std.testing.expectEqualStrings("News,Odd folder with url and kids", try titles(a, m.roots));
    try std.testing.expectEqualStrings(",HN,Apple,zed.dev,Empty", try titles(a, m.bookmark(id(4)).?.children.?));
    try std.testing.expectEqualStrings("Deep", try titles(a, m.bookmark(news).?.children.?));
    const made = m.group(&.{ id(3), id(2) }, "Picked").?;
    try std.testing.expectEqualStrings(",Picked,zed.dev,Empty", try titles(a, m.bookmark(id(4)).?.children.?));
    try std.testing.expectEqualStrings("HN,Apple", try titles(a, m.bookmark(made).?.children.?));
    m.sort(id(4), .name);
    try std.testing.expectEqualStrings("Empty,Picked,,zed.dev", try titles(a, m.bookmark(id(4)).?.children.?));
    m.sort(made, .site);
    try std.testing.expectEqualStrings("Apple,HN", try titles(a, m.bookmark(made).?.children.?));
    m.remove(&.{ made, id(7) });
    try std.testing.expect(m.bookmark(id(2)) == null);
    try std.testing.expect(!m.contains("https://news.ycombinator.com/"));
    try std.testing.expectEqualStrings("News", try titles(a, m.roots));
    m.update(news, "Reading", "https://not-for-folders/");
    try std.testing.expect(m.bookmark(news).?.isFolder());
    try std.testing.expectEqualStrings("Reading", m.bookmark(news).?.title);
}

test "bookmarks take, withdraw and union" {
    var w: World = undefined;
    try w.open();
    defer w.close();
    const m = &w.marks;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var bar = [_]Bookmark{
        .{ .id = id(20), .title = "Apple", .url = "https://www.apple.com/" },
        .{ .id = id(21), .title = "New", .url = "https://new.example/" },
    };
    var theirs = [_]Bookmark{
        .{ .id = id(22), .title = "Bar", .children = &bar },
        .{ .id = id(23), .title = "Loose", .url = "https://loose.example/" },
    };
    // Safari filled the top level first, so Chrome's go in a folder of their own.
    w.store.setString(Bookmarks.top_key, "Safari");
    const t = m.takeNoting(a, &theirs, "Chrome");
    try std.testing.expectEqual(@as(usize, 3), t.added);
    try std.testing.expectEqual(@as(usize, 0), t.already);
    try std.testing.expectEqual(@as(usize, 5), t.ids.len);
    try std.testing.expectEqualStrings("Chrome", m.roots[3].title);
    // Again: everything is already there.
    const again = m.take(&theirs, "Chrome");
    try std.testing.expectEqual(@as(usize, 0), again.added);
    try std.testing.expectEqual(@as(usize, 3), again.already);
    try std.testing.expectEqual(@as(usize, 4), m.roots.len);
    try std.testing.expectEqual(@as(usize, 3), m.withdraw(t.ids));
    try std.testing.expectEqual(@as(usize, 3), m.roots.len);
    const merged = try Bookmarks.@"union"(a, m.roots, &theirs);
    try std.testing.expectEqual(@as(usize, 5), merged.len);
    try std.testing.expectEqual(@as(usize, 7), Bookmarks.count(merged));
}

test "an empty list takes another browser's at the top" {
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    var m = Bookmarks.init(gpa, &store);
    defer m.deinit();
    var theirs = [_]Bookmark{.{ .id = id(30), .title = "One", .url = "https://one.example/" }};
    try std.testing.expectEqual(@as(usize, 1), m.take(&theirs, "Safari").added);
    const top = store.string(Bookmarks.top_key).?;
    defer gpa.free(top);
    try std.testing.expectEqualStrings("Safari", top);
    try std.testing.expect(m.roots[0].id.eql(id(30)));
}

test "categories round-trip through bookmarks.json as written, the unsorted without a key" {
    var w: World = undefined;
    try w.open();
    defer w.close();
    const flat = [_]Bookmark{
        .{ .id = id(40), .title = "Magnesium", .url = "https://health.example/mg", .category = "Health & Supplements" },
        .{ .id = id(41), .title = "BPC-157", .url = "https://peptides.example/bpc", .category = "Peptides & Longevity" },
        .{ .id = id(42), .title = "Attention", .url = "https://arxiv.org/abs/1706.03762", .category = "AI/ML Research" },
        .{ .id = id(43), .title = "RISC-V", .url = "https://riscv.org/", .category = "EE \"Chip\" Engineering — 設計" },
        .{ .id = id(44), .title = "Loose", .url = "https://loose.example/" },
        .{ .id = id(45), .title = "Stray", .url = "https://stray.example/" },
    };
    w.marks.replace(&flat);
    w.store.disk.drain();
    const saved = w.store.readFile(Bookmarks.file).?;
    defer gpa.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"url\":\"https://health.example/mg\",\"category\":\"Health & Supplements\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"category\":\"Peptides & Longevity\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"category\":\"AI/ML Research\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"category\":\"EE \\\"Chip\\\" Engineering") != null);
    // One key for each filed site; an unsorted one ends at its address, with no key and no null.
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, saved, "\"category\":"));
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"title\":\"Loose\",\"url\":\"https://loose.example/\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"title\":\"Stray\",\"url\":\"https://stray.example/\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "null") == null);
    // As at the next launch: every category byte for byte, the unsorted still without one.
    var again = Bookmarks.init(gpa, &w.store);
    defer again.deinit();
    try std.testing.expectEqual(flat.len, again.roots.len);
    for (flat, again.roots) |want, got| {
        try std.testing.expect(got.id.eql(want.id));
        if (want.category) |c| try std.testing.expectEqualStrings(c, got.category.?) else try std.testing.expect(got.category == null);
    }
    try std.testing.expectEqual(@as(usize, 4), Bookmarks.cat.countCategories(again.roots));
    // Cleared by hand: its key goes too.
    Bookmarks.cat.setCategory(&w.marks, id(41), null);
    w.store.disk.drain();
    const cleared = w.store.readFile(Bookmarks.file).?;
    defer gpa.free(cleared);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, cleared, "\"category\":"));
    try std.testing.expect(std.mem.indexOf(u8, cleared, "null") == null);
}

test "union files a site kept unsorted under the other side's category, without a second copy" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const remote = [_]Bookmark{
        .{ .id = id(50), .title = "BPC-157", .url = "https://peptides.example/bpc" },
        .{ .id = id(51), .title = "Zig", .url = "https://ziglang.org/", .category = "Dev" },
        .{ .id = id(52), .title = "Loose", .url = "https://loose.example/" },
    };
    const local = [_]Bookmark{
        .{ .id = id(53), .title = "BPC-157 dosing", .url = "https://peptides.example/bpc", .category = "Peptides & Longevity" },
        .{ .id = id(54), .title = "Zig home", .url = "https://ziglang.org/", .category = "Languages" },
        .{ .id = id(55), .title = "Loose too", .url = "https://loose.example/" },
        .{ .id = id(56), .title = "Magnesium", .url = "https://health.example/mg", .category = "Health & Supplements" },
    };
    const merged = try Bookmarks.@"union"(a, &remote, &local);
    // Three already here and one new, each where it was: no address twice.
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    try std.testing.expectEqual(@as(usize, 4), Bookmarks.count(merged));
    // The one already here keeps its id and name, and takes the category.
    try std.testing.expect(merged[0].id.eql(id(50)));
    try std.testing.expectEqualStrings("BPC-157", merged[0].title);
    try std.testing.expectEqualStrings("Peptides & Longevity", merged[0].category.?);
    // Filed on this side already: its own category stays. Unsorted on both: still unsorted.
    try std.testing.expect(merged[1].id.eql(id(51)));
    try std.testing.expectEqualStrings("Dev", merged[1].category.?);
    try std.testing.expect(merged[2].id.eql(id(52)) and merged[2].category == null);
    try std.testing.expect(merged[3].id.eql(id(56)));
    try std.testing.expectEqualStrings("Health & Supplements", merged[3].category.?);
    // What was merged is as it was.
    try std.testing.expect(remote[0].category == null);
}

test "sorting a categorized top level sorts inside each category and keeps the categories in order" {
    var w: World = undefined;
    try w.open();
    defer w.close();
    const m = &w.marks;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const health = "Health & Supplements";
    const peptides = "Peptides & Longevity";
    const housing = "Housing Search";
    var held = [_]Bookmark{
        .{ .id = id(71), .title = "Zebra", .url = "https://a.example/zebra" },
        .{ .id = id(72), .title = "Aardvark", .url = "https://z.example/aardvark" },
    };
    const flat = [_]Bookmark{
        .{ .id = id(60), .title = "Zinc", .url = "https://www.a-labs.example/zinc", .category = health },
        .{ .id = id(61), .title = "Magnesium", .url = "https://c-labs.example/mg", .category = health },
        .{ .id = id(62), .title = "Ashwagandha", .url = "https://b-labs.example/ash", .category = health },
        .{ .id = id(63), .title = "TB-500", .url = "https://alpha.example/tb", .category = peptides },
        .{ .id = id(64), .title = "Ipamorelin", .url = "https://peptides.example/ipa", .category = peptides },
        .{ .id = id(65), .title = "BPC-157", .url = "https://peptides.example/bpc", .category = peptides },
        .{ .id = id(66), .title = "Zillow", .url = "https://homes.example/z", .category = housing },
        .{ .id = id(67), .title = "Apartments", .url = "https://rent.example/a", .category = housing },
        .{ .id = id(70), .title = "Reading", .children = &held },
        .{ .id = id(68), .title = "Yak", .url = "https://b.example/yak" },
        .{ .id = id(69), .title = "Bee", .url = "https://y.example/bee" },
    };
    m.replace(&flat);
    const order = health ++ "," ++ peptides ++ "," ++ housing ++ ",/,-";
    try std.testing.expectEqualStrings(order, try runs(a, m.roots));
    m.sort(null, .name);
    try std.testing.expectEqualStrings("Ashwagandha,Magnesium,Zinc,BPC-157,Ipamorelin,TB-500,Apartments,Zillow,Reading,Bee,Yak", try titles(a, m.roots));
    try std.testing.expectEqualStrings(order, try runs(a, m.roots));
    // By site, www aside, then by name on one site.
    m.sort(null, .site);
    try std.testing.expectEqualStrings("Zinc,Ashwagandha,Magnesium,TB-500,BPC-157,Ipamorelin,Zillow,Apartments,Reading,Yak,Bee", try titles(a, m.roots));
    try std.testing.expectEqualStrings(order, try runs(a, m.roots));
    // No site left its category, the folder is where it was with what it held, and sorting again changes nothing.
    for (flat) |b| try std.testing.expect(Bookmarks.cat.optEq(b.category, m.bookmark(b.id).?.category));
    try std.testing.expectEqualStrings("Zebra,Aardvark", try titles(a, m.bookmark(id(70)).?.children.?));
    const rev = m.revision;
    m.sort(null, .site);
    try std.testing.expectEqual(rev, m.revision);
    // Nothing filed: folders first, as ever.
    m.replace(&.{ flat[9], flat[8], flat[10] });
    m.sort(null, .name);
    try std.testing.expectEqualStrings("Reading,Bee,Yak", try titles(a, m.roots));
}
