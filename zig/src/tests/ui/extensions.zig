//! P13: extensions in the chrome — Settings › Extensions lists one and its
//! switch turns it off, the slot shows its button, and the store's page
//! offers to add one that isn't here. Skipped below macOS 15.4.
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const ext_fixture = @import("ext_fixture.zig");

const gpa = std.testing.allocator;
const t = std.testing;

fn rectOf(f: *Fixture, role: ui.A11yRole, label: []const u8) ?ui.Rect {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) return c.rects.get(item.id);
    return null;
}

test "settings extensions lists the installed extension and its switch turns it off" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    const e = (try ext_fixture.install(&f)) orelse return error.SkipZigTest;
    app.settings.open(f.browser, .extensions);
    f.tester.settle(2);
    try t.expectEqual(app.settings.Page.extensions, f.browser.settings.page.?);
    try t.expect(f.tester.hasText("Kea Fixture"));
    if (!f.tester.containsText("Version 1.0 · From “Kea Fixture”")) {
        for (f.tester.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.indexOf(u8, tx.str, "Version") != null) std.debug.print("detail: '{s}'\n", .{tx.str}),
            else => {},
        };
        return error.NoDetail;
    }
    try t.expect(e.installed.items[0].enabled);
    const r = rectOf(&f, .switch_toggle, "Kea Fixture") orelse return error.NoSwitch;
    f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
    try t.expect(!e.installed.items[0].enabled);
    try t.expect(e.context(e.installed.items[0].id) == null);
}

test "extension slot shows the pinned button and the puzzle in strip and column" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const e = (try ext_fixture.install(&f)) orelse return error.SkipZigTest;
    const id = e.installed.items[0].id;
    f.tester.settle(1);
    // Unpinned: only the puzzle.
    try t.expect(rectOf(&f, .button, "Extensions") != null);
    try t.expect(rectOf(&f, .button, "Kea Fixture") == null);
    e.setPinned(id, true);
    // Drawn, then placed: its anchor is the frame before's rect.
    f.tester.frame();
    f.tester.frame();
    const strip = rectOf(&f, .button, "Kea Fixture") orelse return error.NoButton;
    try t.expect(strip.y < 52 and strip.w == 26);
    // Its place is handed over for the popup to hang from.
    const a = e.del.anchors.get(id) orelse return error.NoAnchor;
    try t.expectEqual(strip.x, @as(f32, @floatCast(a.rect.origin.x)));
    // The puzzle opens the list, which has the extension's row.
    const puzzle = rectOf(&f, .button, "Extensions").?;
    f.tester.click(puzzle.x + puzzle.w / 2, puzzle.y + puzzle.h / 2);
    f.tester.settle(1);
    try t.expect(app.ext_slot.isOpen(f.browser));
    try t.expect(f.tester.hasText("Manage Extensions…"));
    try t.expect(f.tester.hasText("Kea Fixture"));
    // In the column, at its foot.
    f.browser.overlay = null;
    f.kea.prefs.set("sidebar", true);
    f.tester.settle(2);
    const foot = rectOf(&f, .button, "Kea Fixture") orelse return error.NoButton;
    try t.expect(foot.y > 800 and foot.x < f.kea.prefs.side_width);
}

test "store offer shows on a store page and not once installed" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const e = (try ext_fixture.install(&f)) orelse return error.SkipZigTest;
    const b = f.browser;
    var buf: [200]u8 = undefined;
    const elsewhere = "https://chromewebstore.google.com/detail/other/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    _ = b.open(elsewhere, .{ .foreground = true });
    f.tester.settle(2);
    try t.expect(app.ext_ui.offered(b) != null);
    try t.expect(f.tester.hasText("Add this extension to KeaZig"));
    // The one installed: no offer.
    const mine = try std.fmt.bufPrint(&buf, "https://chromewebstore.google.com/detail/fixture/{s}", .{e.installed.items[0].id});
    _ = b.open(mine, .{ .foreground = true });
    f.tester.settle(2);
    try t.expect(app.ext_ui.offered(b) == null);
    try t.expect(!f.tester.hasText("Add this extension to KeaZig"));
}
