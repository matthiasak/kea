//! P8.7: the bookmarks — the manager's drag and its undo, the bar's folder
//! menu, ⇧⌘B and the card, the button's list.
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const Bookmark = app.bookmarks_data.Bookmark;

const gpa = std.testing.allocator;

fn titles(b: *app.Browser, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (b.bookmarks.roots, 0..) |n, i| w.print("{s}{s}", .{ if (i > 0) "," else "", n.title }) catch {};
    return w.buffered();
}

/// A strip window keeping Alpha, Beta and Gamma.
fn seeded(f: *Fixture) !void {
    try f.init(gpa, .{ .sidebar = false });
    const b = f.browser;
    _ = b.bookmarks.add("https://a.example/", "Alpha");
    _ = b.bookmarks.add("https://b.example/", "Beta");
    _ = b.bookmarks.add("https://c.example/", "Gamma");
    f.tester.settle(1);
}

test "bookmarks manager move then undo restores" {
    var f: Fixture = undefined;
    try seeded(&f);
    defer f.deinit();
    const b = f.browser;
    var buf: [64]u8 = undefined;
    app.sheet.show(b, .bookmarking);
    f.tester.settle(1);
    try std.testing.expect(f.tester.hasText("3 bookmarks"));
    // Gamma carried above Alpha.
    const gamma = f.tester.findText("Gamma") orelse return error.NoRow;
    const alpha = f.tester.findText("Alpha") orelse return error.NoRow;
    f.tester.drag(gamma.x + 4, gamma.y + gamma.h / 2, alpha.x + 4, alpha.y - 2);
    f.tester.settle(1);
    try std.testing.expectEqualStrings("Gamma,Alpha,Beta", titles(b, &buf));
    // ⌘Z puts it back, ⇧⌘Z does it again.
    try std.testing.expect(f.press("z", 6, .{ .cmd = true }));
    try std.testing.expectEqualStrings("Alpha,Beta,Gamma", titles(b, &buf));
    try std.testing.expect(f.press("Z", 6, .{ .cmd = true, .shift = true }));
    try std.testing.expectEqualStrings("Gamma,Alpha,Beta", titles(b, &buf));
    // Closed, what was done there is kept and can't be undone.
    app.sheet.close(b, .bookmarking);
    f.tester.settle(1);
    _ = f.press("z", 6, .{ .cmd = true });
    try std.testing.expectEqualStrings("Gamma,Alpha,Beta", titles(b, &buf));
}

test "bookmarks manager picks with shift and cmd-A" {
    var f: Fixture = undefined;
    try seeded(&f);
    defer f.deinit();
    const b = f.browser;
    app.sheet.show(b, .bookmarking);
    f.tester.settle(1);
    try f.tester.clickText("Alpha");
    f.tester.setMods(.{ .shift = true });
    try f.tester.clickText("Gamma");
    f.tester.setMods(.{});
    try std.testing.expectEqual(@as(usize, 3), b.marks_ui.picks.ids.items.items.len);
    f.tester.settle(1);
    try f.tester.clickText("Beta");
    try std.testing.expectEqual(@as(usize, 1), b.marks_ui.picks.ids.items.items.len);
    try std.testing.expect(f.press("a", 0, .{ .cmd = true }));
    try std.testing.expectEqual(@as(usize, 3), b.marks_ui.picks.ids.items.items.len);
}

test "bookmarks bar folder menu lists children" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const b = f.browser;
    var deep = [_]Bookmark{.{ .id = .random(), .title = "Deep", .url = "https://deep.example/" }};
    var kids = [_]Bookmark{
        .{ .id = .random(), .title = "Xylo", .url = "https://x.example/" },
        Bookmark.folder("Sub", &deep),
        .{ .id = .random(), .title = "", .url = "https://z.example/page" },
    };
    b.bookmarks.insert(Bookmark.folder("Work", &kids), null, null);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try app.bookmarks_menu.items(arena.allocator(), b, b.bookmarks.roots[0].kids());
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("Xylo", items[0].label);
    try std.testing.expect(items[0].submenu == null and items[0].click != null);
    try std.testing.expectEqualStrings("Sub", items[1].label);
    try std.testing.expect(items[1].submenu != null and items[1].on_open != null);
    // One without a name reads as its address.
    try std.testing.expectEqualStrings("z.example/page", items[2].label);
    // The bar shows the folder, its chevron, and opens nothing by itself.
    b.prefs.set("bookmarks_bar", true);
    f.tester.settle(1);
    try std.testing.expect(f.tester.hasText("Work"));
}

test "shift-cmd-B adds then edits" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const b = f.browser;
    const t = b.activeTab().?;
    t.own(&t.address, "https://www.example.com/a");
    f.tester.settle(1);
    try std.testing.expect(f.press("B", 11, .{ .cmd = true, .shift = true }));
    f.tester.settle(1);
    const kept = b.bookmarks.bookmarkFor("https://www.example.com/a") orelse return error.NotKept;
    const id = kept.id;
    try std.testing.expect(b.overlay != null and b.overlay.? == .bookmark_card);
    try std.testing.expect(f.tester.hasText("Bookmarked"));
    try std.testing.expect(f.tester.hasText("Top Level"));
    // The name, typed over: kept as it is typed.
    f.tester.textOps(&.{.{ .command = .select_all }});
    f.tester.typeText("Reading");
    f.tester.settle(1);
    try std.testing.expectEqualStrings("Reading", b.bookmarks.bookmark(id).?.title);
    // Again: the same one's card, nothing added.
    _ = f.press("\x1b", 53, .{});
    f.tester.settle(1);
    try std.testing.expect(b.overlay == null);
    try std.testing.expect(f.press("B", 11, .{ .cmd = true, .shift = true }));
    f.tester.settle(1);
    try std.testing.expectEqual(@as(usize, 1), b.bookmarks.roots.len);
    try std.testing.expect(b.marks_ui.card.?.eql(id));
    try std.testing.expect(f.tester.hasText("Reading"));
}

test "bookmark door opens the list and a row opens its page" {
    var f: Fixture = undefined;
    try seeded(&f);
    defer f.deinit();
    const b = f.browser;
    const door = b.marks_ui.door;
    try std.testing.expect(door.w > 0);
    f.tester.click(door.x + door.w / 2, door.y + door.h / 2);
    f.tester.settle(1);
    try std.testing.expect(b.overlay != null and b.overlay.? == .bookmarks_dropdown);
    try std.testing.expect(f.tester.hasText("Add This Page"));
    try std.testing.expect(f.tester.hasText("Manage Bookmarks\u{2026}"));
    try f.tester.clickText("Beta");
    f.tester.settle(1);
    try std.testing.expect(b.overlay == null);
    try std.testing.expectEqualStrings("https://b.example/", b.activeTab().?.url());
}

test "card name arrives selected" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const b = f.browser;
    const tab = b.activeTab().?;
    tab.own(&tab.address, "https://www.example.com/a");
    tab.setTitle("Example Page");
    f.tester.settle(1);
    try std.testing.expect(f.press("B", 11, .{ .cmd = true, .shift = true }));
    f.tester.settle(1);
    const id = (b.bookmarks.bookmarkFor("https://www.example.com/a") orelse return error.NotKept).id;
    f.tester.typeText("x");
    f.tester.settle(1);
    try std.testing.expectEqualStrings("x", b.bookmarks.bookmark(id).?.title);
}
