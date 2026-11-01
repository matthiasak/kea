//! P15: the release's chrome — icons only, ⌘ numbers, pinning by drag,
//! two tabs picked for Split View, and what a tab's title says.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;

const gpa = t.allocator;

/// Every tab but the blank first one titled "Tab n", n its place.
fn titled(b: *app.Browser) void {
    var buf: [16]u8 = undefined;
    for (b.tabs.items, 0..) |tab, i| if (i > 0) tab.setTitle(std.fmt.bufPrint(&buf, "Tab {d}", .{i}) catch unreachable);
}

/// A background tab on `url`, titled `title`.
fn page(b: *app.Browser, url: []const u8, title: []const u8) *app.Tab {
    const tab = b.open(url, .{ .foreground = false, .at_end = true });
    tab.own(&tab.address, url);
    tab.setTitle(title);
    return tab;
}

/// The box VoiceOver knows as `role` named `label`, as last laid out.
fn rectOf(f: *Fixture, role: ui.A11yRole, label: []const u8) ?ui.Rect {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) return c.rects.get(item.id);
    return null;
}

/// The tab's pill in the strip, or its row in the column.
fn tabRect(f: *Fixture, side: bool, tab: *app.Tab) !ui.Rect {
    if (side) return rectOf(f, .tab, tab.label()) orelse error.NoRow;
    for (f.browser.strip.seen.items) |s| if (s.id == tab.id) return f.tester.ctx.rects.get(s.node) orelse error.NotLaidOut;
    return error.NotDrawn;
}

fn center(r: ui.Rect) ui.Point {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

/// Whether the text `s` is drawn inside `in`.
fn textIn(f: *Fixture, s: []const u8, in: ui.Rect) bool {
    for (f.tester.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s) and in.contains(center(n.rect))) return true,
        else => {},
    };
    return false;
}

fn countText(f: *Fixture, s: []const u8) usize {
    var n: usize = 0;
    for (f.tester.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| n += @intFromBool(std.mem.eql(u8, tx.str, s)),
        else => {},
    };
    return n;
}

fn hasLabel(items: []const nanoui.MenuItem, label: []const u8) bool {
    for (items) |it| if (!it.is_separator and std.mem.eql(u8, it.label, label)) return true;
    return false;
}

test "icons only: a 52-point column, one square a row, a group's letter, a narrow pair" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true, .tabs = 6 });
    defer f.deinit();
    const b = f.browser;
    titled(b);
    b.prefs.set("glyph", .icons_only);
    b.prefs.set("uses_tab_groups", true);
    b.prefs.set("split_view", true);
    var row: [7]*app.Tab = undefined;
    @memcpy(&row, b.tabs.items[0..7]);
    b.pin(row[1], false);
    b.pin(row[2], false);
    const gid = b.addTabGroup(row[3]);
    b.renameTabGroup(gid, "Work");
    b.editing_group_id = null;
    b.select(row[4]);
    b.pair(row[5], row[4], false);
    f.tester.settle(2);

    try t.expectEqual(@as(f32, 52), b.prefs.effectiveSideWidth());
    try t.expectApproxEqAbs(@as(f32, 52), f.holes()[0].x, 0.5);
    // The squares one above the other, in the one column.
    const one = rectOf(&f, .button, "Tab 1") orelse return error.NoSquare;
    const two = rectOf(&f, .button, "Tab 2") orelse return error.NoSquare;
    try t.expectApproxEqAbs(one.x, two.x, 0.5);
    try t.expect(@abs(one.y - two.y) >= one.h);
    // The group's heading is its first letter.
    try t.expect(f.tester.hasText("W"));
    try t.expect(!f.tester.hasText("Work"));
    // The pair's two lines fit the narrow column.
    const pair = rectOf(&f, .group, "Split tabs") orelse return error.NoPair;
    try t.expect(pair.w <= 32.5);
}

test "cmd held shows numbers 1 to 8 and 9 on the last tab" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true, .tabs = 11 });
    defer f.deinit();
    const b = f.browser;
    titled(b);
    b.prefs.set("shows_cmd_numbers", true);
    b.select(b.tabs.items[1]);
    f.tester.settle(2);
    try t.expect(!f.tester.hasText("⌘1"));

    f.mods(.{ .cmd = true });
    f.tester.frame();
    var buf: [8]u8 = undefined;
    for (1..10) |n| try t.expectEqual(@as(usize, 1), countText(&f, try std.fmt.bufPrint(&buf, "⌘{d}", .{n})));
    // Twelve tabs: the ninth to eleventh wear nothing, the twelfth ⌘9.
    const last = rectOf(&f, .tab, "Tab 11") orelse return error.NoRow;
    try t.expect(textIn(&f, "⌘9", last));
    const ninth = rectOf(&f, .tab, "Tab 8") orelse return error.NoRow;
    try t.expect(!textIn(&f, "⌘9", ninth));

    // ⇧ with it: not ⌘ alone, so no numbers.
    f.mods(.{ .cmd = true, .shift = true });
    f.tester.frame();
    try t.expect(!f.tester.hasText("⌘1"));
    // A key pressed puts them away too.
    f.mods(.{ .cmd = true });
    f.tester.frame();
    try t.expect(f.tester.hasText("⌘1"));
    _ = f.press("q", 12, .{});
    try t.expect(!b.cmd_held);
    try t.expect(!f.tester.hasText("⌘1"));
}

test "a row dragged above the squares is pinned, a blank one isn't, a square dragged onto a heading joins it" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true, .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    titled(b);
    b.prefs.set("uses_tab_groups", true);
    const blank = b.tabs.items[0];
    const loose = b.tabs.items[2];
    const gid = b.addTabGroup(b.tabs.items[3]);
    b.editing_group_id = null;
    b.select(b.tabs.items[1]);
    f.tester.settle(2);

    // The blank row carried up: still a row.
    var at = center(rectOf(&f, .tab, "New Tab") orelse return error.NoRow);
    f.tester.drag(at.x, at.y, at.x, b.column.grid_bottom - 20);
    f.tester.settle(1);
    try t.expect(blank.pin == null);

    at = center(rectOf(&f, .tab, "Tab 2") orelse return error.NoRow);
    f.tester.drag(at.x, at.y, at.x, b.column.grid_bottom - 20);
    f.tester.settle(1);
    try t.expect(loose.pin != null);

    // Its square let go over the group's heading, past the grid's foot.
    at = center(rectOf(&f, .button, "Tab 2") orelse return error.NoSquare);
    const head = center(f.tester.findText("Group 1") orelse return error.NoHeading);
    try t.expect(head.y > b.column.grid_bottom + 8);
    f.tester.drag(at.x, at.y, head.x, head.y);
    f.tester.settle(1);
    try t.expect(loose.pin == null);
    try t.expect(loose.group_id != null and loose.group_id.?.eql(gid));
}

test "cmd-click picks a second tab for Split View, in the strip and in the column" {
    for ([_]bool{ false, true }) |side| {
        var f: Fixture = undefined;
        try f.init(gpa, .{ .sidebar = side, .tabs = 3 });
        defer f.deinit();
        const b = f.browser;
        titled(b);
        b.prefs.set("split_view", true);
        const live = b.tabs.items[1];
        const picked = b.tabs.items[2];
        const third = b.tabs.items[3];
        b.select(live);
        f.tester.settle(2);

        // ⌘-click picks, again lets go, and the page stays.
        const at = center(try tabRect(&f, side, picked));
        f.tester.setMods(.{ .cmd = true });
        f.tester.click(at.x, at.y);
        try t.expectEqual(@as(?u64, picked.id), b.picked_tab);
        try t.expectEqual(live.id, b.active_id);
        f.tester.click(at.x, at.y);
        try t.expectEqual(@as(?u64, null), b.picked_tab);
        f.tester.click(at.x, at.y);
        f.tester.setMods(.{});
        try t.expectEqual(@as(?u64, picked.id), b.picked_tab);

        // The picked tab's menu and the live one's offer the two; another's its own.
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        for ([_]*app.Tab{ picked, live }) |tab| try t.expect(hasLabel(try app.tab_menu.items(a, b, tab), "Open 2 Tabs in Split View"));
        const other = try app.tab_menu.items(a, b, third);
        try t.expect(hasLabel(other, "Open in Split View") and !hasLabel(other, "Open 2 Tabs in Split View"));

        // Esc lets go of the pick.
        _ = f.press("\x1b", 53, .{});
        try t.expectEqual(@as(?u64, null), b.picked_tab);

        // Picked again, ⌥⌘N pairs the two.
        f.tester.setMods(.{ .cmd = true });
        f.tester.click(at.x, at.y);
        f.tester.setMods(.{});
        try t.expectEqual(@as(?u64, picked.id), b.picked_tab);
        try t.expect(f.press("n", 45, .{ .cmd = true, .alt = true }));
        const pair = b.activeSplit() orelse return error.NotPaired;
        try t.expect(pair.contains(live.id) and pair.contains(picked.id));
        try t.expectEqual(@as(?u64, null), b.picked_tab);
    }
}

/// Whether the row named `label` draws `s`.
fn rowShows(f: *Fixture, label: []const u8, s: []const u8) !bool {
    return textIn(f, s, rectOf(f, .tab, label) orelse return error.NoRow);
}

test "tab titles: the site on the tab you're on, warnings on any tab, a name over the site" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    const b = f.browser;
    const docs = page(b, "https://docs.github.com/en", "GitHub Docs");
    const plain = page(b, "http://example.com/", "Plain");
    _ = page(b, "http://127.0.0.1:8080/", "Local");
    _ = page(b, "https://xn--pple-43d.com/", "Apple");
    b.select(docs);
    f.tester.settle(2);
    try t.expect(try rowShows(&f, "GitHub Docs", "docs.github.com"));
    // Plain http says so even behind; the machine's own address doesn't.
    try t.expect(try rowShows(&f, "Plain", "Not secure — example.com"));
    try t.expect(try rowShows(&f, "Local", "Local"));
    // A punycode host shows itself, not its title.
    try t.expect(try rowShows(&f, "Apple", "xn--pple-43d.com"));

    // Pointed at, the tab you're on shows its title.
    const r = rectOf(&f, .tab, "GitHub Docs") orelse return error.NoRow;
    f.tester.moveTo(r.x + r.w / 2, r.y + r.h / 2);
    f.tester.settle(0.5);
    try t.expect(textIn(&f, "GitHub Docs", r));
    f.tester.moveTo(900, 600);
    f.tester.settle(0.5);

    // With the address off, the title.
    b.prefs.set("shows_tab_address", false);
    f.tester.settle(0.5);
    try t.expect(try rowShows(&f, "GitHub Docs", "GitHub Docs"));
    b.prefs.set("shows_tab_address", true);

    // A name of your own beats the site, not the warning.
    docs.own(&docs.name, "Work Docs");
    f.tester.settle(0.5);
    try t.expect(try rowShows(&f, "Work Docs", "Work Docs"));
    plain.own(&plain.name, "Mine");
    b.select(plain);
    f.tester.settle(0.5);
    try t.expect(try rowShows(&f, "Mine", "Not secure — example.com"));
}
