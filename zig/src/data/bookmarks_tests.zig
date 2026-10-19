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
