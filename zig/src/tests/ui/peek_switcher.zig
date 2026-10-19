//! P7: the peek layer (Peek.swift) and ⌃Tab's switcher (TabSwitcher.swift).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;

/// The switcher's cards, in the order drawn (row by row).
fn cards(f: *Fixture, out: []ui.Rect) usize {
    var n: usize = 0;
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (std.mem.startsWith(u8, item.label, "Switch to ") and n < out.len) {
        out[n] = c.rects.get(item.id) orelse continue;
        n += 1;
    };
    return n;
}

test "switcher layout: five columns of Swift's cards" {
    // min(176, (W − 64 − 8·(columns − 1)) / columns); the picture (w − 16)·.62; the card the picture + 39.
    const layout = app.tab_switcher_view.layout;
    const wide = layout(1440, 7);
    try t.expectEqual(@as(usize, 5), wide.columns);
    try t.expectApproxEqAbs(@as(f32, 176), wide.width, 0.01);
    try t.expectApproxEqAbs(@as(f32, 99.2), wide.preview, 0.01);
    try t.expectApproxEqAbs(@as(f32, 138.2), wide.height, 0.01);
    const three = layout(500, 3);
    try t.expectEqual(@as(usize, 3), three.columns);
    try t.expectApproxEqAbs(@as(f32, 420.0 / 3.0), three.width, 0.01);
    try t.expectApproxEqAbs(@as(f32, 120.8), layout(700, 10).width, 0.01);

    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 6 });
    defer f.deinit();
    const b = f.browser;
    try t.expect(f.press("\t", 48, .{ .ctrl = true }));
    try t.expect(b.switcher.active());
    // Nothing shows for 0.15 s: a quick ⌃Tab goes back without a panel.
    f.tester.frame();
    try t.expect(!b.switcher.visible);
    f.tester.advance(0.2);
    try t.expect(b.switcher.visible);
    var r: [10]ui.Rect = undefined;
    const n = cards(&f, &r);
    try t.expectEqual(@as(usize, 7), n);
    for (r[0..n]) |card| {
        try t.expectApproxEqAbs(@as(f32, 176), card.w, 0.5);
        try t.expectApproxEqAbs(@as(f32, 138.2), card.h, 0.5);
    }
    // Five to a row, 8 apart; the panel (12 inside) centred in the window.
    try t.expectApproxEqAbs(@as(f32, 184), r[1].x - r[0].x, 0.5);
    try t.expectApproxEqAbs(r[0].y, r[4].y, 0.5);
    try t.expectApproxEqAbs(r[0].x, r[5].x, 0.5);
    try t.expectApproxEqAbs(@as(f32, 146.2), r[5].y - r[0].y, 0.5);
    try t.expectApproxEqAbs(@as(f32, (1440 - (5 * 176 + 4 * 8 + 24)) / 2 + 12), r[0].x, 0.5);
}

test "switcher: esc puts it away, arrows move, control let go of picks" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .tabs = 3 });
    defer f.deinit();
    const b = f.browser;
    const row = b.tabs.items;
    const first = row[0];
    const third = row[2];
    // Left latest first: the third, then the first.
    b.select(row[2]);
    b.select(row[1]);
    const here = b.active_id;
    try t.expect(f.press("\t", 48, .{ .ctrl = true }));
    try t.expectEqual(@as(?u64, third.id), b.switcher.selected);
    f.tester.advance(0.2);
    try t.expect(b.switcher.visible);
    // Escape does nothing else: the field and the page stay.
    try t.expect(f.press("\x1b", 53, .{ .ctrl = true }));
    try t.expect(!b.switcher.active() and !b.switcher.visible);
    try t.expectEqual(here, b.active_id);
    f.tester.advance(0.3);
    try t.expect(!b.switcher.visible);

    try t.expect(f.press("\t", 48, .{ .ctrl = true }));
    try t.expect(f.press("\u{F703}", 124, .{ .ctrl = true }));
    try t.expectEqual(@as(?u64, first.id), b.switcher.selected);
    try t.expect(b.switcher.visible);
    f.mods(.{});
    try t.expect(!b.switcher.active());
    try t.expectEqual(first.id, b.active_id);
}

test "peek panel is 82 by 86 percent of the page's room and esc puts it away" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = false });
    defer f.deinit();
    const b = f.browser;
    const from = b.activeTab().?;
    b.peek("https://example.com/", from);
    const count = b.tabs.items.len;
    f.tester.settle(1);
    const holes = f.holes();
    try t.expectEqual(@as(usize, 2), holes.len);
    // The strip's room: (0, 52, 1440, 848); the panel centred and 21 right,
    // the page beside its 28-point knobs, 10 apart.
    const page = holes[holes.len - 1];
    try t.expectApproxEqAbs(@as(f32, (1440 - 1440 * 0.82) / 2.0 + 21), page.x, 0.5);
    try t.expectApproxEqAbs(@as(f32, 52 + (848 - 848 * 0.86) / 2.0), page.y, 0.5);
    try t.expectApproxEqAbs(@as(f32, 1440 * 0.82 - 38), page.w, 0.5);
    try t.expectApproxEqAbs(@as(f32, 848 * 0.86), page.h, 0.5);
    try t.expectEqual(count, b.tabs.items.len);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(b.peek_tab == null);
    try t.expectEqual(from, b.activeTab().?);
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 1), f.holes().len);
}
