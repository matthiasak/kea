//! P0: the headless fixture itself — layout holes, shortcuts, no webviews.
const std = @import("std");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;

test "headless tabs build no webview" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .tabs = 2 });
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 3), f.browser.tabs.items.len);
    for (f.browser.tabs.items) |t| try std.testing.expect(t.web == null);
    try std.testing.expectEqualStrings("kea-test://site/page?title=Tab%201", f.browser.tabs.items[1].url());
}

test "strip layout: one hole the window's width" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const h = f.holes();
    try std.testing.expectEqual(@as(usize, 1), h.len);
    try std.testing.expectEqual(@as(f32, 0), h[0].x);
    try std.testing.expectEqual(@as(f32, 1440), h[0].w);
    try std.testing.expectEqual(@as(f32, 900), h[0].y + h[0].h);
}

test "sidebar moves the hole past the column" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    const h = f.holes();
    try std.testing.expectEqual(@as(usize, 1), h.len);
    // The column's edge handle lies over its own inner edge (Side.swift).
    try std.testing.expectApproxEqAbs(f.kea.prefs.side_width, h[0].x, 0.5);
}

test "ctrl-cmd-B bookmarks panel shrinks the hole by the panel" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const before = f.holes()[0].w;
    _ = f.tester.shortcut(.{ .key = 'b', .cmd = true, .ctrl = true });
    f.tester.frame();
    try std.testing.expect(f.browser.marks_open);
    const after = f.holes()[0].w;
    try std.testing.expectApproxEqAbs(f.kea.prefs.marks_width, before - after, 0.5);
}
