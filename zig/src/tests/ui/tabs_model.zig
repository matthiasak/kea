//! The tab model (P4.1): closing and ⇧⌘T, `touched`, ghosts, pins in
//! every window, groups, a tab to another window, spaces, lazy restore.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;
const Uuid = app.json.Uuid;

test "every model method compiles" {
    std.testing.refAllDecls(app.Browser);
}

test "Close Group comes back whole with one reopen" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("uses_tab_groups", true);
    const id = b.addTabGroup(b.tabs.items[1]);
    b.moveToGroup(b.tabs.items[2], id);
    b.renameTabGroup(id, "  Reading  ");
    b.select(b.tabs.items[2]); // the blank tab, after the group
    b.closeTabGroup(id);
    try t.expectEqual(@as(usize, 0), b.tab_groups.items.len);
    try t.expectEqual(@as(usize, 2), b.tabs.items.len);
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("Reopen Closed Group", b.reopenTitle(&buf));
    b.reopen();
    try t.expectEqual(@as(usize, 1), b.tab_groups.items.len);
    try t.expectEqualStrings("Reading", b.tab_groups.items[0].name);
    const members = try b.tabsIn(t.allocator, id);
    defer t.allocator.free(members);
    try t.expectEqual(@as(usize, 2), members.len);
}

fn url(tab: *const app.Tab) []const u8 {
    return tab.url();
}

/// Another (headless) window, as ⌘N makes one.
fn secondWindow(k: *app.Kea) !*app.Browser {
    const record: app.windows_file.WindowRecord = .{ .id = Uuid.random() };
    return app.browsers.open(k, &record, null);
}

test "close then reopen brings tabs back in order (⇧⌘T)" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    var before: [4][]const u8 = undefined;
    var keep: [4][64]u8 = undefined;
    for (b.tabs.items, 0..) |tab, i| {
        @memcpy(keep[i][0..url(tab).len], url(tab));
        before[i] = keep[i][0..url(tab).len];
    }
    b.select(b.tabs.items[1]);
    b.close(b.tabs.items[1]);
    b.close(b.tabs.items[1]);
    try t.expectEqual(@as(usize, 2), b.tabs.items.len);
    try t.expectEqual(@as(usize, 2), b.ghosts.items.len);
    b.reopen();
    b.reopen();
    try t.expectEqual(@as(usize, 4), b.tabs.items.len);
    for (b.tabs.items, before) |tab, u| try t.expectEqualStrings(u, url(tab));
    try t.expectEqual(b.tabs.items[1].id, b.active_id);
    try t.expectEqual(@as(usize, 0), b.ghosts.items.len);
}

test "touched orders tabs most recently used first" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    const one = b.tabs.items[1];
    const two = b.tabs.items[2];
    const three = b.tabs.items[3];
    b.select(one);
    b.select(two);
    b.select(three);
    b.select(one);
    // Each tab left is the tab just looked at.
    try t.expect(one.touched > three.touched);
    try t.expect(three.touched > two.touched);
}

test "ghosts keep twelve steps, a Clear counting as one" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 15 });
    defer f.deinit();
    const b = f.browser;
    for (0..14) |_| b.close(b.tabs.items[b.tabs.items.len - 1]);
    try t.expectEqual(@as(usize, 12), b.ghosts.items.len);
    // The two closed first are the ones let go.
    try t.expectEqualStrings("kea-test://site/page?title=Tab%2013", b.ghosts.items[0].url);
    // A Clear is one step: the oldest single goes, all of the Clear stays.
    for (0..3) |_| _ = b.open("kea-test://site/page?title=Cleared", .{ .foreground = false });
    b.clearTabs();
    try t.expectEqual(@as(usize, 11 + 4), b.ghosts.items.len);
    b.reopen();
    var back: usize = 0;
    for (b.tabs.items) |tab| back += @intFromBool(std.mem.endsWith(u8, url(tab), "Cleared"));
    try t.expectEqual(@as(usize, 3), back);
}

test "pin goes to the head, unpin to the head of the loose tabs" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    const one = b.tabs.items[1];
    const three = b.tabs.items[3];
    b.pin(one, false);
    b.pin(three, false);
    try t.expectEqual(one, b.tabs.items[0]);
    try t.expectEqual(three, b.tabs.items[1]);
    try t.expectEqualStrings("S", three.pin.?);
    try t.expectEqual(@as(usize, 2), b.pinnedCount());
    b.unpin(one);
    try t.expectEqual(three, b.tabs.items[0]);
    try t.expectEqual(one, b.tabs.items[1]);
    try t.expect(one.pin == null and one.home == null and one.pin_id == null);
    // ⌘W on a pin puts it down: still in the row, asleep.
    b.select(three);
    b.close(three);
    try t.expect(three.asleep() and three.pin != null);
    try t.expectEqual(@as(usize, 4), b.tabs.items.len);
}

test "pins are the same in every window" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    const other = try secondWindow(f.kea);
    try t.expectEqual(@as(usize, 0), other.pinnedCount());
    b.pin(b.tabs.items[1], false);
    try t.expectEqual(@as(usize, 1), other.pinnedCount());
    const theirs = other.tabs.items[0];
    try t.expect(theirs.pin_id.?.eql(b.tabs.items[0].pin_id.?));
    try t.expect(theirs.asleep());
    try t.expectEqualStrings(url(b.tabs.items[0]), theirs.home.?);
    b.unpin(b.tabs.items[0]);
    try t.expectEqual(@as(usize, 0), other.pinnedCount());
}

test "a folded group hides its tabs from the shown row" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("uses_tab_groups", true);
    const blank = b.tabs.items[0];
    const one = b.tabs.items[1];
    const two = b.tabs.items[2];
    const id = b.addTabGroup(one);
    b.moveToGroup(two, id);
    try t.expectEqualStrings("Group 1", b.tab_groups.items[0].name);
    // Grouped tabs come first after the pins.
    try t.expectEqual(one, b.tabs.items[0]);
    try t.expectEqual(two, b.tabs.items[1]);
    b.select(blank);
    b.toggleTabGroup(id);
    const shown = try b.shownTabs(t.allocator);
    defer t.allocator.free(shown);
    try t.expectEqual(@as(usize, 2), shown.len);
    try t.expect(std.mem.indexOfScalar(*app.Tab, shown, one) == null);
    // Going to a tab in a folded group opens it.
    b.select(one);
    try t.expect(!b.tab_groups.items[0].collapsed);
    // The last tab gone, the group goes.
    b.moveToGroup(one, null);
    b.moveToGroup(two, null);
    try t.expectEqual(@as(usize, 0), b.tab_groups.items.len);
}

test "a tab moves to another window, and the empty tab there makes way" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 2 });
    defer f.deinit();
    const b = f.browser;
    const other = try secondWindow(f.kea);
    const moving = b.tabs.items[1];
    b.select(moving);
    b.moveToWindow(moving, other, null);
    try t.expect(b.tabById(moving.id) == null);
    try t.expectEqual(@as(usize, 2), b.tabs.items.len);
    try t.expect(b.tabById(b.active_id) != null);
    try t.expectEqual(@as(usize, 1), other.tabs.items.len);
    try t.expectEqual(moving.id, other.active_id);
    try t.expectEqual(@as(?*app.Browser, other), moving.browser);
}

test "switching spaces swaps the rows and saves the space's session file" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("uses_spaces", true);
    b.addSpace("Work", null, true);
    const work = f.kea.spaces.value[1].id;
    try t.expect(b.space_id.eql(work));
    try t.expectEqual(@as(usize, 1), b.tabs.items.len);
    try t.expect(b.tabs.items[0].isBlank());
    _ = b.open("https://work.example/", .{ .foreground = true });
    b.switchSpace(Uuid.first);
    try t.expectEqual(@as(usize, 4), b.tabs.items.len);
    try t.expectEqual(@as(usize, 2), b.parked.get(work).?.tabs.items.len);
    f.kea.store.disk.drain();
    var name: [49]u8 = undefined;
    const file = f.kea.store.readFile(app.session.fileName(&name, work)) orelse return error.NoSessionFile;
    defer t.allocator.free(file);
    try t.expect(std.mem.indexOf(u8, file, "https://work.example/") != null);
    // Back again: the parked row, as it was.
    b.switchSpace(work);
    try t.expectEqualStrings("https://work.example/", url(b.tabById(b.active_id).?));
}

/// A session of three kept tabs, the second in front.
fn seed(temp: app.Temp) !void {
    var store = try app.store.Store.init(t.allocator, temp.root, temp.suite);
    defer store.deinit();
    const tabs = [_]app.session.Entry{
        .{ .url = "https://a.example/", .title = "A" },
        .{ .url = "https://b.example/", .title = "B" },
        .{ .url = "https://c.example/", .title = "C" },
    };
    app.session.write(&store, Uuid.first, .{ .tabs = &tabs, .active = 1 }, true);
}

test "restore builds only the tab in front; the others wake when selected" {
    var temp = try app.Temp.init(t.allocator);
    defer temp.deinit(t.allocator);
    try seed(temp);
    const k = try app.Kea.create(t.allocator, null, .{ .root = temp.root, .suite = temp.suite, .headless = true });
    defer k.destroy();
    const b = try k.newBrowser();
    try t.expectEqual(@as(usize, 3), b.tabs.items.len);
    const front = b.tabById(b.active_id).?;
    try t.expectEqualStrings("https://b.example/", url(front));
    try t.expect(front.built and !front.asleep());
    const a = b.tabs.items[0];
    try t.expect(!a.built and a.asleep());
    try t.expectEqualStrings("A", a.title());
    b.select(a);
    try t.expect(a.built and !a.asleep());
}

test "restore writes nothing and records no visits" {
    var temp = try app.Temp.init(t.allocator);
    defer temp.deinit(t.allocator);
    try seed(temp);
    const k = try app.Kea.create(t.allocator, null, .{ .root = temp.root, .suite = temp.suite, .headless = true });
    defer k.destroy();
    // Pins read once, as they always are, before any window (writing pins.json the first time).
    k.pins.load();
    const writes = k.store.disk.count;
    _ = try k.newBrowser();
    try t.expectEqual(writes, k.store.disk.count);
    k.history.ensureIndexed();
    try t.expectEqual(@as(usize, 0), k.history.visits.count());
}

test "a split not in front survives restore and the next write" {
    var temp = try app.Temp.init(t.allocator);
    defer temp.deinit(t.allocator);
    {
        var store = try app.store.Store.init(t.allocator, temp.root, temp.suite);
        defer store.deinit();
        const tabs = [_]app.session.Entry{
            .{ .url = "https://a.example/", .title = "A" },
            .{ .url = "https://b.example/", .title = "B" },
            .{ .url = "https://c.example/", .title = "C" },
        };
        const splits = [_]app.session.Split{.{ .tabs = &.{ 1, 2 }, .sizes = &.{ 0.3, 0.7 } }};
        app.session.write(&store, Uuid.first, .{ .tabs = &tabs, .active = 0, .splits = &splits }, true);
    }
    const k = try app.Kea.create(t.allocator, null, .{ .root = temp.root, .suite = temp.suite, .headless = true });
    defer k.destroy();
    k.prefs.set("split_view", true);
    const b = try k.newBrowser();
    try t.expect(b.split_right_id == null);
    b.flushSession();
    {
        const saved = app.session.read(&k.store, Uuid.first);
        defer saved.deinit();
        try t.expectEqual(@as(usize, 1), saved.value.splits.len);
        try t.expectEqualSlices(i64, &.{ 1, 2 }, saved.value.splits[0].tabs);
    }
    // Picking one of its pages brings the pair in front.
    b.select(b.tabs.items[2]);
    try t.expectEqual(b.tabs.items[1].id, b.active_id);
    try t.expectEqual(@as(?u64, b.tabs.items[2].id), b.split_right_id);
}

test "a background tab opened to wait builds nothing while tabs.lazy is on" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{});
    defer f.deinit();
    const b = f.browser;
    const waiting = b.open("kea-test://site/page?title=Later", .{ .foreground = false, .may_wait = true });
    try t.expect(!waiting.built and waiting.asleep());
    b.prefs.set("lazy_tabs", false);
    const now = b.open("kea-test://site/page?title=Now", .{ .foreground = false, .may_wait = true });
    try t.expect(now.built and !now.asleep());
}
