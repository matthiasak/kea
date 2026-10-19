//! P8.8: the side panels (SidePanels.swift) — carried by the header,
//! let out over the page, sized by their edge, popped into a window.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

/// The bookmarks open in their column, in the strip's layout (on the right).
fn openMarks(f: *Fixture) !void {
    try f.init(gpa, .{ .sidebar = false });
    f.kea.prefs.set("bookmarks_sidebar", true);
    f.tester.settle(1);
}

/// A point on the header's title, in the column on the right: the title
/// may be cut short at 232 points, so found by the Manage pill's line.
fn header(f: *Fixture) !struct { x: f32, y: f32 } {
    const m = f.tester.findText("Manage") orelse return error.NoHeader;
    return .{ .x = 1440 - f.kea.prefs.marks_width + 18, .y = m.y + m.h / 2 };
}

test "side panel header drag past midpoint flips side" {
    var f: Fixture = undefined;
    try openMarks(&f);
    defer f.deinit();
    try t.expect(!app.side_panels.panelOnLeft(f.browser, .bookmarks));
    try t.expectApproxEqAbs(@as(f32, 0), f.holes()[0].x, 0.5);
    const h = try header(&f);
    // Not past the middle: it stays.
    f.tester.drag(h.x, h.y, 800, h.y);
    try t.expect(!app.side_panels.panelOnLeft(f.browser, .bookmarks));
    f.tester.drag(h.x, h.y, 200, h.y);
    try t.expect(f.kea.prefs.marks_side.? == .left);
    f.tester.settle(1);
    // The page now starts past the panel.
    try t.expectApproxEqAbs(f.kea.prefs.marks_width, f.holes()[0].x, 0.5);
}

test "side panel header double-click lets it out at most 760 wide" {
    var f: Fixture = undefined;
    try openMarks(&f);
    defer f.deinit();
    const h = try header(&f);
    f.tester.doubleClick(h.x, h.y);
    try t.expectEqual(@as(?app.side_panels.SidePanel, .bookmarks), f.browser.expanded_panel);
    f.tester.settle(1);
    // Out of its column: the page has the window's width under it.
    try t.expectApproxEqAbs(@as(f32, 1440), f.holes()[0].w, 0.5);
    // Its content at most 760 wide, centred over the page.
    const title = f.tester.findText("Bookmarks").?;
    try t.expectApproxEqAbs(@as(f32, (1440 - 760) / 2 + 12), title.x, 1);
    // Esc puts it back.
    _ = f.press("\x1b", 53, .{});
    try t.expect(f.browser.expanded_panel == null);
}

test "side panel edge drag clamps to its range" {
    var f: Fixture = undefined;
    try openMarks(&f);
    defer f.deinit();
    const edge = 1440 - f.kea.prefs.marks_width + 4;
    f.tester.drag(edge, 400, edge - 500, 400);
    try t.expectEqual(@as(f32, 440), f.kea.prefs.marks_width);
    f.tester.settle(1);
    const wide = 1440 - 440 + 4;
    f.tester.drag(wide, 400, wide + 600, 400);
    try t.expectEqual(@as(f32, 176), f.kea.prefs.marks_width);
    // VoiceOver's increment: ten points wider (`accessibilityPerformIncrement`).
    f.tester.settle(1);
    const item = for (f.tester.ctx.a11y_items.items) |a| {
        if (std.mem.eql(u8, a.label, "Column width")) break a;
    } else return error.NoEdge;
    f.tester.ctx.a11yStep(item.id, 1);
    f.tester.frame();
    try t.expectEqual(@as(f32, 186), f.kea.prefs.marks_width);
}

test "popped bookmarks opens second window" {
    var f: Fixture = undefined;
    try openMarks(&f);
    defer f.deinit();
    try t.expect(f.kea.marks_window == null);
    app.side_panels.togglePopped(f.browser, .bookmarks);
    f.tester.settle(1);
    const w = f.kea.marks_window orelse return error.NoWindow;
    try t.expectEqual(app.side_panels.SidePanel.bookmarks, w.panel);
    // Out of the column: the page has its width back.
    try t.expectApproxEqAbs(@as(f32, 1440), f.holes()[0].w, 0.5);
    app.side_panels.togglePopped(f.browser, .bookmarks);
    f.tester.settle(1);
    try t.expect(f.kea.marks_window == null);
    try t.expectApproxEqAbs(@as(f32, 1440 - f.kea.prefs.marks_width), f.holes()[0].w, 0.5);
}
