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

test "sidebar category headers are unclickable while bookmark rows navigate" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    const b = f.browser;
    const tab = b.activeTab().?;
    tab.own(&tab.address, "https://initial.example/");
    const id1 = b.bookmarks.add("https://arxiv.org/", "arXiv").?;
    const id2 = b.bookmarks.add("https://huggingface.co/", "Hugging Face").?;
    const id3 = b.bookmarks.add("https://digikey.com/", "DigiKey").?;
    app.bookmarks_category.setCategory(b.bookmarks, id1, "AI & ML");
    app.bookmarks_category.setCategory(b.bookmarks, id2, "AI & ML");
    app.bookmarks_category.setCategory(b.bookmarks, id3, "EE & Chips");
    b.prefs.set("bookmarks_sidebar", true);
    f.tester.settle(1);
    try std.testing.expect(f.tester.hasText("AI & ML"));
    try std.testing.expect(f.tester.hasText("EE & Chips"));
    const hr = f.tester.findText("AI & ML") orelse return error.NoHeader;
    f.tester.click(hr.x + hr.w / 2, hr.y + hr.h / 2);
    f.tester.settle(0.5);
    try std.testing.expectEqualStrings("https://initial.example/", b.activeTab().?.url());
    try std.testing.expect(b.overlay == null);
    try std.testing.expect(f.tester.hasText("arXiv"));
    try std.testing.expect(f.tester.hasText("Hugging Face"));
    try f.tester.clickText("DigiKey");
    f.tester.settle(0.5);
    try std.testing.expectEqualStrings("https://digikey.com/", b.activeTab().?.url());
}

test "shift-cmd-B auto-categorizes into neighbor category while preserving live BookmarkCard typing" {
    const client = app.ai_client;
    const Pending = struct {
        sink: ?client.Sink = null,
        fn stream(ctx: ?*anyopaque, _: *app.ai_core.Ai, _: client.Ask, sink: client.Sink) ?client.Handle {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.sink = sink;
            return null;
        }
    };
    var pending = Pending{};
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const b = f.browser;
    const id1 = b.bookmarks.add("https://examine.com/", "Examine").?;
    const id2 = b.bookmarks.add("https://zillow.com/", "Zillow").?;
    app.bookmarks_category.setCategory(b.bookmarks, id1, "Health & Supplements");
    app.bookmarks_category.setCategory(b.bookmarks, id2, "Housing Search");
    const m = b.kea.ai;
    m.client = .{ .ctx = &pending, .stream = Pending.stream };
    m.prefs.set("ai", true);
    m.prefs.set("ai_provider", "ollama");
    m.prefs.setAIModel("m", "ollama");
    const tab = b.activeTab().?;
    tab.own(&tab.address, "https://peptides.example/bpc");
    tab.setTitle("BPC Page");
    f.tester.settle(0.2);
    try std.testing.expect(f.press("B", 11, .{ .cmd = true, .shift = true }));
    f.tester.settle(0.2);
    try std.testing.expect(b.overlay != null and b.overlay.? == .bookmark_card);
    f.tester.textOps(&.{.{ .command = .select_all }});
    f.tester.typeText("BPC-157 Guide");
    f.tester.settle(0.2);
    const sink = pending.sink orelse return error.MissingPendingSink;
    sink.piece(sink.ctx, "{\"category\":\"Peptides & Longevity\",\"after_category\":\"Health & Supplements\",\"before_category\":null,\"before_item\":null}");
    sink.done(sink.ctx, null);
    f.tester.settle(0.3);
    const bm = b.bookmarks.bookmarkFor("https://peptides.example/bpc") orelse return error.NotKept;
    try std.testing.expectEqualStrings("BPC-157 Guide", bm.title);
    try std.testing.expectEqualStrings("Peptides & Longevity", bm.category.?);
    try std.testing.expectEqual(@as(usize, 3), b.bookmarks.roots.len);
    try std.testing.expectEqualStrings("Examine", b.bookmarks.roots[0].title);
    try std.testing.expectEqualStrings("BPC-157 Guide", b.bookmarks.roots[1].title);
    try std.testing.expectEqualStrings("Zillow", b.bookmarks.roots[2].title);
    try std.testing.expect(f.tester.hasText("Peptides & Longevity"));
}
