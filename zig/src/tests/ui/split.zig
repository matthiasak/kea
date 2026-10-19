//! P7: Split View's stage — a pair's two holes a gutter apart, the divider
//! dragged and snapped, a window too narrow for two, and pairs in the
//! session.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;
const app = @import("kea");
const Uuid = app.json.Uuid;
const Fixture = @import("fixture.zig").Fixture;

const gpa = t.allocator;

/// A strip window (the stage the whole width), the opened tab paired to
/// the right of the first, and every move over.
fn paired(f: *Fixture, width: f32) !void {
    try f.init(gpa, .{ .sidebar = false, .tabs = 1, .width = width });
    const b = f.browser;
    b.prefs.set("split_view", true);
    b.pair(b.tabs.items[1], b.tabs.items[0], false);
    f.tester.settle(2);
}

/// Where the divider is: in the gutter after the first hole.
fn dividerX(f: *Fixture) f32 {
    const h = f.holes();
    return h[0].x + h[0].w + 3.5;
}

test "split halves at even" {
    var f: Fixture = undefined;
    try paired(&f, 1440);
    defer f.deinit();
    const h = f.holes();
    try t.expectEqual(@as(usize, 2), h.len);
    const each = (1440.0 - 7.0) / 2.0;
    try t.expectApproxEqAbs(each, h[0].w, 0.5);
    try t.expectApproxEqAbs(each, h[1].w, 0.5);
    try t.expectApproxEqAbs(h[0].x + h[0].w + 7, h[1].x, 0.5);
    // The page with the keys is the one dragged in, on the right.
    try t.expectEqual(f.browser.tabs.items[1].id, f.browser.active_id);
}

test "divider drag by 100 moves boundary 100" {
    var f: Fixture = undefined;
    try paired(&f, 1440);
    defer f.deinit();
    const before = f.holes()[0].w;
    const x = dividerX(&f);
    const y = f.holes()[0].y + 200;
    f.tester.drag(x, y, x + 100, y);
    f.tester.settle(2);
    try t.expectApproxEqAbs(before + 100, f.holes()[0].w, 0.5);
    // Told once, let go: the pair keeps the share.
    const pair = f.browser.activeSplit().?;
    try t.expectApproxEqAbs((before + 100) / (1440.0 - 7.0), pair.fraction(), 0.001);
}

test "divider snaps to even within 15" {
    var f: Fixture = undefined;
    try paired(&f, 1440);
    defer f.deinit();
    const pair = f.browser.activeSplit().?;
    f.browser.setSplitFraction(pair.id, 0.3);
    f.tester.settle(2);
    const room: f32 = 1440 - 7;
    try t.expectApproxEqAbs(room * 0.3, f.holes()[0].w, 0.5);
    // Let go 10 short of even: it settles on even.
    const x = dividerX(&f);
    const y = f.holes()[0].y + 200;
    f.tester.drag(x, y, x + (room / 2 - 10 - room * 0.3), y);
    f.tester.settle(2);
    try t.expectApproxEqAbs(room / 2, f.holes()[0].w, 0.5);
    try t.expectApproxEqAbs(@as(f64, 0.5), f.browser.activeSplit().?.fraction(), 0.0001);
}

test "narrow window keeps only focused hole" {
    var f: Fixture = undefined;
    // 500 wide: a stage below 2 · 250 + 7.
    try paired(&f, 500);
    defer f.deinit();
    const h = f.holes();
    try t.expectEqual(@as(usize, 1), h.len);
    try t.expectApproxEqAbs(@as(f32, 500), h[0].w, 0.5);
    const shown = f.browser.stage.shown();
    try t.expectEqual(f.browser.active_id, shown[0].tab);
    // Still a pair, and two holes again once there is room.
    try t.expect(f.browser.activeSplit() != null);
    f.tester.resize(1440, 900);
    f.tester.settle(2);
    try t.expectEqual(@as(usize, 2), f.holes().len);
}

test "split survives session round-trip" {
    var temp = try app.Temp.init(gpa);
    defer temp.deinit(gpa);
    {
        const k = try app.Kea.create(gpa, null, .{ .root = temp.root, .suite = temp.suite, .headless = true });
        defer k.destroy();
        k.prefs.set("split_view", true);
        const b = try k.newBrowser();
        const a = b.open("https://a.example/", .{ .foreground = true, .at_end = true });
        const c = b.open("https://c.example/", .{ .foreground = false, .at_end = true });
        b.pair(c, a, false);
        b.flushSession();
        const saved = app.session.read(&k.store, Uuid.first);
        defer saved.deinit();
        // The blank first tab isn't kept: the pair is places 0 and 1.
        try t.expectEqual(@as(usize, 1), saved.value.splits.len);
        try t.expectEqualSlices(i64, &.{ 0, 1 }, saved.value.splits[0].tabs);
        try t.expectEqual(@as(?i64, 1), saved.value.splits[0].focused);
    }
    const k = try app.Kea.create(gpa, null, .{ .root = temp.root, .suite = temp.suite, .headless = true });
    defer k.destroy();
    const b = try k.newBrowser();
    try t.expectEqual(@as(usize, 1), b.splits.items.len);
    const pair = b.activeSplit().?;
    try t.expectEqualStrings("https://a.example/", b.tabById(pair.left()).?.url());
    try t.expectEqualStrings("https://c.example/", b.tabById(pair.right()).?.url());
    try t.expectEqual(pair.right(), b.active_id);
}

test "swap, separate and close both" {
    var f: Fixture = undefined;
    try paired(&f, 1440);
    defer f.deinit();
    const b = f.browser;
    const l = b.tabs.items[0].id;
    const r = b.tabs.items[1].id;
    b.swapSplit();
    try t.expectEqual([2]u64{ r, l }, b.activeSplit().?.tabs);
    try t.expectEqual(r, b.tabs.items[0].id);
    b.detachSplit(b.activeTab().?);
    try t.expect(b.activeSplit() == null);
    f.tester.settle(2);
    try t.expectEqual(@as(usize, 1), f.holes().len);
    b.openInSplit(b.tabById(l).?);
    try t.expect(b.activeSplit() != null);
    const n = b.tabs.items.len;
    b.closeSplit();
    try t.expectEqual(n - 1, b.tabs.items.len);
}
