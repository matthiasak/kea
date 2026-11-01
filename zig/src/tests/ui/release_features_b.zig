//! P15: the release's menus and keys — reload and the bookmarks bar's
//! menus, a held Back, bookmarks opened private, paired or grouped, ⌃Tab's
//! ⌃W and ⌃M, Esc twice out of full screen, tabs closed when left alone,
//! and Copy Clean Link.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");
const Bookmark = app.bookmarks_data.Bookmark;
const Uuid = app.json.Uuid;
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;

const gpa = t.allocator;

fn expectLabels(items: []const nanoui.MenuItem, want: []const []const u8) !void {
    try t.expectEqual(want.len, items.len);
    for (want, items) |w, it| try t.expectEqualStrings(w, it.label);
}

/// What NSMenu does with a click on the item labelled `label`.
fn fire(items: []const nanoui.MenuItem, label: []const u8) !void {
    for (items) |it| if (!it.is_separator and std.mem.eql(u8, it.label, label)) {
        const click = it.click orelse return error.NoClick;
        var unused: nanoui.menu.Item = undefined;
        click.func(click.ctx, &unused);
        return;
    };
    return error.NoItem;
}

/// The tab in front on `url`.
fn onPage(f: *Fixture, url: []const u8) *app.Tab {
    const b = f.browser;
    const tab = b.tabs.items[1];
    b.select(tab);
    tab.own(&tab.address, url);
    b.setEditing(false);
    return tab;
}

test "reload and the bookmarks bar's own menus" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false, .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try expectLabels(try app.tab_title.reloadMenu(a, b, 0), &.{ "Reload Page", "Reload Page From Origin" });
    b.prefs.set("bookmarks_bar", true);
    const empty = try app.bookmarks_outline_menu.builtBarEmpty(a, b, 0);
    try expectLabels(empty, &.{ "New Folder\u{2026}", "Show Bookmarks\u{2026}", "Hide Bookmarks Bar" });
    try fire(empty, "Hide Bookmarks Bar");
    try t.expect(!b.prefs.bookmarks_bar);
}

test "back held for 0.28 s asks for its list instead of going back" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true, .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    const tab = onPage(&f, "https://www.example.com/b");
    tab.can_go_back = true;
    f.tester.settle(1);
    const back = for (f.tester.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, "chevron.left")) break n.rect,
        else => {},
    } else return error.NoBack;
    f.tester.moveTo(back.x + back.w / 2, back.y + back.h / 2);
    f.tester.ctx.pointerDown();
    f.tester.frame();
    const at = b.helm_hold_at orelse return error.NotHeld;
    f.tester.advance(0.1);
    try t.expectEqual(at, b.helm_hold_at.?);
    // Past 0.28 s the list is asked for, once, and the let-go doesn't go back.
    f.tester.advance(0.3);
    try t.expect(b.helm_hold_at.? < at - 500);
    f.tester.ctx.pointerUp();
    f.tester.frame();
    try t.expect(b.helm_hold_at == null);
}

test "a bookmark opens private or in Split View, a folder as a tab group" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false, .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("split_view", true);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const id = b.bookmarks.add("https://kea.example/", "Kea") orelse return error.NotKept;
    const ids = [_]Uuid{id};
    const front = onPage(&f, "https://www.example.com/");
    const items = try app.bookmarks_outline_menu.items(a, b, &ids, .dropdown);

    try fire(items, "Open in New Private Tab");
    const shy = b.activeTab().?;
    try t.expect(shy.shy);
    try t.expectEqualStrings("https://kea.example/", shy.url());

    b.select(front);
    try fire(items, "Open in Split View");
    const pair = b.activeSplit() orelse return error.NotPaired;
    try t.expect(pair.contains(front.id));
    try t.expectEqualStrings("https://kea.example/", b.activeTab().?.url());
    try t.expect(!b.activeTab().?.shy);

    var kids = [_]Bookmark{
        .{ .id = .random(), .title = "One", .url = "https://one.example/" },
        .{ .id = .random(), .title = "Two", .url = "https://two.example/" },
    };
    b.bookmarks.insert(Bookmark.folder("Reading", &kids), null, null);
    const folder = for (b.bookmarks.roots) |n| {
        if (std.mem.eql(u8, n.title, "Reading")) break n.id;
    } else return error.NoFolder;
    const folder_ids = [_]Uuid{folder};
    // Offered only with tab groups on.
    try t.expectError(error.NoItem, fire(try app.bookmarks_outline_menu.items(a, b, &folder_ids, .dropdown), "Open All in Tab Group"));
    b.prefs.set("uses_tab_groups", true);
    try fire(try app.bookmarks_outline_menu.items(a, b, &folder_ids, .dropdown), "Open All in Tab Group");
    const group = for (b.tab_groups.items) |g| {
        if (std.mem.eql(u8, g.name, "Reading")) break g.id;
    } else return error.NoGroup;
    var in: usize = 0;
    for (b.tabs.items) |tab| in += @intFromBool(tab.group_id != null and tab.group_id.?.eql(group));
    try t.expectEqual(@as(usize, 2), in);
    try t.expectEqualStrings("https://one.example/", b.activeTab().?.url());
}

test "switcher: control-W closes a loose tab, puts a pin down, control-M mutes" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .tabs = 4 });
    defer f.deinit();
    const b = f.browser;
    const row = b.tabs.items;
    const loose = row[2];
    const loose_id = loose.id;
    b.select(row[2]);
    b.select(row[1]);
    try t.expect(f.press("\t", 48, .{ .ctrl = true }));
    try t.expectEqual(@as(?u64, loose_id), b.switcher.selected);
    try t.expect(f.press("w", 13, .{ .ctrl = true }));
    try t.expect(b.tabById(loose_id) == null);
    try t.expect(b.switcher.active());
    try t.expect(std.mem.indexOfScalar(u64, b.switcher.candidates.items, loose_id) == null);
    try t.expect(b.switcher.selected != null and b.switcher.selected.? != loose_id);

    // ⌃M: the card's tab, quiet.
    const muted = b.tabById(b.switcher.selected.?).?;
    try t.expect(!muted.muted);
    try t.expect(f.press("m", 46, .{ .ctrl = true }));
    try t.expect(muted.muted);
    f.mods(.{});

    // A pin under ⌃W sleeps where it is, still there to pick.
    const pin = b.tabs.items[b.tabs.items.len - 1];
    b.pin(pin, false);
    b.select(pin);
    b.select(b.tabs.items[b.tabs.items.len - 1]);
    try t.expect(f.press("\t", 48, .{ .ctrl = true }));
    try t.expect(std.mem.indexOfScalar(u64, b.switcher.candidates.items, pin.id) != null);
    b.switcher.selected = pin.id;
    try t.expect(f.press("w", 13, .{ .ctrl = true }));
    try t.expect(b.tabById(pin.id) != null);
    try t.expect(pin.asleep());
    if (b.switcher.active()) try t.expect(std.mem.indexOfScalar(u64, b.switcher.candidates.items, pin.id) != null);
}

test "Esc twice within 2 s leaves full screen, once only says so" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false, .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("double_esc_fullscreen", true);
    const tab = onPage(&f, "https://video.example/");
    tab.immersed = true;
    f.tester.settle(1);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expectEqualStrings("Press Esc again to exit full screen", b.announcement orelse return error.Unsaid);
    // More than 2 s later: said again, not left.
    b.esc_fullscreen_at = ui.clock.now() - 3;
    b.hush();
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expectEqualStrings("Press Esc again to exit full screen", b.announcement orelse return error.Unsaid);
    // At once: out, and the line gone.
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(b.announcement == null);
    try t.expectEqual(@as(f64, 0), b.esc_fullscreen_at);
}

test "tabs left alone close, but not pinned, grouped, named, private, paired or kept-awake ones" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("uses_tab_groups", true);
    b.prefs.set("split_view", true);
    const bg: app.OpenOptions = .{ .foreground = false, .at_end = true };
    const front = b.open("https://front.example/", .{ .foreground = true, .at_end = true });
    const plain = b.open("https://plain.example/", bg).id;
    const pinned = b.open("https://pinned.example/", bg);
    b.pin(pinned, false);
    const grouped = b.open("https://grouped.example/", bg);
    _ = b.addTabGroup(grouped);
    b.editing_group_id = null;
    const named = b.open("https://named.example/", bg);
    named.own(&named.name, "Kept");
    const shy = b.open("https://shy.example/", .{ .foreground = false, .at_end = true, .shy = true });
    const left = b.open("https://left.example/", bg);
    const right = b.open("https://right.example/", bg);
    b.pair(right, left, false);
    b.select(front);
    // A saved pair is spared even with Split View off.
    b.prefs.set("split_view", false);
    const awake = b.open("https://awake.example/", bg);
    app.sleep.setKeptAwake(&f.kea.store, true, "awake.example");
    for (b.tabs.items) |tab| if (tab != front) {
        tab.touched_at = 0;
    };
    b.prefs.set("closes_tabs", true);
    var kept: [8]u64 = undefined;
    for ([_]*app.Tab{ front, pinned, grouped, named, shy, left, right, awake }, &kept) |tab, *id| id.* = tab.id;
    app.sleep.sleepIdle(b, null);
    try t.expect(b.tabById(plain) == null);
    for (kept) |id| try t.expect(b.tabById(id) != null);
}

test "Keep This Site Awake on the site card spares the site's tabs" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false, .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("closes_tabs", true);
    const tab = onPage(&f, "https://awake.example/");
    f.tester.settle(1);
    try openCard(&f, tab);
    try t.expect(f.tester.hasText("Keep This Site Awake"));
    const sw = for (f.tester.ctx.a11y_items.items) |item| {
        if (item.role == .switch_toggle and std.mem.eql(u8, item.label, "Keep This Site Awake")) break f.tester.ctx.rects.get(item.id) orelse return error.NotLaidOut;
    } else return error.NoSwitch;
    f.tester.click(sw.x + sw.w / 2, sw.y + sw.h / 2);
    try t.expect(app.sleep.isKeptAwake(&f.kea.store, "awake.example"));
}

/// The card opened through the tab menu's Site Information….
fn openCard(f: *Fixture, tab: *app.Tab) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try fire(try app.tab_menu.items(arena.allocator(), f.browser, tab), "Site Information…");
    f.tester.settle(1);
    const o = f.browser.overlay orelse return error.NoCard;
    try t.expect(o == .site_card);
}

test "Copy Clean Link from the key, the card and the tab menu; signed links kept whole" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false, .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    const tracked = "https://example.com/page?utm_medium=email&fbclid=123";
    const tab = onPage(&f, tracked);
    f.tester.settle(1);
    try t.expect(f.press("c", 8, .{ .cmd = true, .shift = true, .alt = true }));
    try t.expectEqualStrings("https://example.com/page", f.tester.clipboard.items);

    f.tester.clipboard.clearRetainingCapacity();
    try openCard(&f, tab);
    try f.tester.clickText("Copy Clean Link");
    try t.expectEqualStrings("https://example.com/page", f.tester.clipboard.items);
    f.tester.settle(1);

    const signed = "https://s3.amazonaws.com/bucket/file.pdf?X-Amz-Signature=deadbeef&utm_source=test";
    tab.own(&tab.address, signed);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try fire(try app.tab_menu.items(arena.allocator(), b, tab), "Copy Clean Link");
    try t.expectEqualStrings(signed, f.tester.clipboard.items);
}

test "slept tabs keep the 16 pictures looked at last, and every address" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true, .tabs = 20 });
    defer f.deinit();
    const slept = f.browser.tabs.items[f.browser.tabs.items.len - 20 ..];
    for (slept, 0..) |tab, i| {
        if (tab.pending == null) tab.own(&tab.pending, tab.url());
        tab.own(&tab.picture, "jpeg");
        tab.touched_at = @floatFromInt(i);
    }
    app.sleep.trimPictures(f.browser, app.sleep.max_kept_pictures);
    for (slept, 0..) |tab, i| {
        try t.expect(tab.pending != null);
        try t.expectEqual(i >= 4, tab.picture != null);
    }
}
