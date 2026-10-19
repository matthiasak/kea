//! P4: the column (Side.swift), its groups and spaces, and the fold.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;

/// The rows the column shows (role tab), top to bottom.
fn rows(f: *Fixture) ![]ui.Rect {
    var out: std.ArrayList(ui.Rect) = .empty;
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| {
        if (item.role != .tab) continue;
        const r = c.rects.get(item.id) orelse continue;
        try out.append(t.allocator, r);
    }
    const list = try out.toOwnedSlice(t.allocator);
    std.mem.sort(ui.Rect, list, {}, struct {
        fn less(_: void, a: ui.Rect, b: ui.Rect) bool {
            return a.y < b.y;
        }
    }.less);
    return list;
}

fn rowCount(f: *Fixture) !usize {
    const r = try rows(f);
    defer t.allocator.free(r);
    return r.len;
}

test "side rows 28 high gap 2" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 4 });
    defer f.deinit();
    f.tester.settle(1);
    const r = try rows(&f);
    defer t.allocator.free(r);
    try t.expectEqual(@as(usize, 5), r.len);
    for (r, 0..) |row, i| {
        try t.expectApproxEqAbs(@as(f32, 28), row.h, 0.01);
        // Inside the column's 10-point margins.
        try t.expectApproxEqAbs(@as(f32, 10), row.x, 0.01);
        try t.expectApproxEqAbs(@as(f32, 232 - 20), row.w, 0.01);
        if (i > 0) try t.expectApproxEqAbs(@as(f32, 2), row.y - (r[i - 1].y + r[i - 1].h), 0.01);
    }
    // Under the lights' band.
    try t.expectApproxEqAbs(@as(f32, 52), r[0].y, 0.01);
}

fn near(a: ui.Rect, b: [4]f32) bool {
    return @abs(a.x - b[0]) < 0.5 and @abs(a.y - b[1]) < 0.5 and @abs(a.w - b[2]) < 0.5 and @abs(a.h - b[3]) < 0.5;
}

/// The live tab's own rect, from its a11y item.
fn liveRow(f: *Fixture) ?ui.Rect {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == .tab and item.selected) return c.rects.get(item.id);
    return null;
}

/// The grey under the live row: a fill at its rect, in the pill's colour.
fn expectPill(f: *Fixture) !void {
    const live = liveRow(f).?;
    const want = f.browser.column.pill.?.colour;
    for (f.tester.instances.items) |in| {
        if (near(live, in.rect) and @abs(in.color[0] - want.r) < 0.002 and @abs(in.color[1] - want.g) < 0.002 and @abs(in.color[2] - want.b) < 0.002 and in.color[3] > 0.99) return;
    }
    return error.NoPillUnderLiveRow;
}

test "live pill sits exactly under the live row, and follows a new one" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    for ([_]usize{ 0, 2 }) |n| {
        b.select(b.tabs.items[n]);
        f.tester.settle(2);
        try expectPill(&f);
    }
    // The rows moved down under new squares, the tab in front unchanged.
    var row: [4]*app.Tab = undefined;
    @memcpy(row[0..4], b.tabs.items[0..4]);
    const front = b.tabById(b.active_id).?;
    for (row) |tab| if (tab != front) b.pin(tab, false);
    f.tester.settle(2);
    try expectPill(&f);
}

test "resting pin squares all wear the tile grey" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    var row: [4]*app.Tab = undefined;
    @memcpy(row[0..4], b.tabs.items[0..4]);
    const front = b.tabById(b.active_id).?;
    for (row) |tab| if (tab != front) b.pin(tab, false);
    b.select(front);
    f.tester.settle(2);
    // Three cells of a 212-point row: 68 by 34.
    var colours: std.ArrayList([4]f32) = .empty;
    defer colours.deinit(t.allocator);
    for (f.tester.instances.items) |in| {
        if (in.rect[2] > 67.5 and in.rect[2] < 68.5 and in.rect[3] > 33.5 and in.rect[3] < 34.5 and in.color[3] > 0) try colours.append(t.allocator, in.color);
    }
    try t.expectEqual(@as(usize, 3), colours.items.len);
    for (colours.items[1..]) |col| try t.expectEqualSlices(f32, &colours.items[0], &col);
}

test "fold hides column and edge reveals it" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 2 });
    defer f.deinit();
    const b = f.browser;
    f.tester.settle(1);
    try t.expect(try rowCount(&f) > 0);
    // ⌘S: folded, the page takes the column's room but the card's gap.
    try t.expect(f.press("s", 1, .{ .cmd = true }));
    try t.expect(b.folded);
    f.tester.settle(1.5);
    try t.expectEqual(@as(usize, 0), try rowCount(&f));
    try t.expectApproxEqAbs(@as(f32, 8), f.holes()[0].x, 0.01);
    // The pointer against the left edge: out at once (not folded for good).
    app.fold.followAt(b, .{ .point = .{ .x = 2, .y = 450 }, .size = .{ .w = 1440, .h = 900 } });
    try t.expect(b.peeking);
    f.tester.settle(1.5);
    const r = try rows(&f);
    defer t.allocator.free(r);
    try t.expectEqual(@as(usize, 3), r.len);
    try t.expectApproxEqAbs(@as(f32, 10), r[0].x, 0.5);
    // Over the page, not beside it: the hole keeps the whole width.
    try t.expectApproxEqAbs(@as(f32, 8), f.holes()[0].x, 0.01);
    // The pointer off it: in again after the grace.
    app.fold.followAt(b, .{ .point = .{ .x = 800, .y = 450 }, .size = .{ .w = 1440, .h = 900 } });
    f.tester.frame();
    try t.expect(b.peeking);
    f.tester.advance(0.4);
    f.tester.frame();
    try t.expect(!b.peeking);
    // Folded for good: the edge waits for the pointer to settle.
    b.prefs.set("side_hides", true);
    f.tester.frame();
    app.fold.followAt(b, .{ .point = .{ .x = 2, .y = 450 }, .size = .{ .w = 1440, .h = 900 } });
    f.tester.frame();
    try t.expect(!b.peeking);
    f.tester.advance(0.2);
    f.tester.frame();
    try t.expect(b.peeking);
}

test "group collapse hides rows" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("uses_tab_groups", true);
    const tabs = b.tabs.items;
    const front = b.tabById(b.active_id).?;
    var grouped: [2]*app.Tab = undefined;
    var n: usize = 0;
    for (tabs) |tab| if (tab != front and n < 2) {
        grouped[n] = tab;
        n += 1;
    };
    const id = b.addTabGroup(grouped[0]);
    b.moveToGroup(grouped[1], id);
    b.editing_group_id = null;
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 4), try rowCount(&f));
    // A click on the heading folds the group away.
    try f.tester.clickText("Group 1");
    try t.expect(b.groupById(id).?.collapsed);
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 2), try rowCount(&f));
    try f.tester.clickText("Group 1");
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 4), try rowCount(&f));
}

test "space switch via SpaceMenu action changes rows" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("uses_spaces", true);
    b.addSpace("Work", null, true);
    f.tester.settle(1);
    try t.expectEqualStrings("Work", b.space().name);
    const work_rows = try rowCount(&f);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const items = try app.spaces_view.menuItems(arena.allocator(), b, 0);
    // The spaces first, the one on screen checked; then what can be done to it.
    try t.expectEqualStrings("Personal", items[0].label);
    try t.expectEqualStrings("Work", items[1].label);
    try t.expect(items[1].checked and !items[0].checked);
    try t.expectEqualStrings("Ctrl+1", items[0].accelerator);
    try t.expectEqualStrings("New Space…", items[3].label);
    try t.expectEqualStrings("Rename “Work”…", items[5].label);
    try t.expectEqualStrings("Delete “Work”…", items[items.len - 1].label);
    // Picking Personal brings its four rows back.
    var picked: nanoui.menu.Item = undefined;
    const click = items[0].click.?;
    click.func(click.ctx, &picked);
    try t.expectEqualStrings("Personal", b.space().name);
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 4), try rowCount(&f));
    try t.expect(work_rows != 4);
}
