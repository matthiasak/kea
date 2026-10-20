//! P14: chrome parity — a group's name typed key by key keeps its field,
//! a page filling the screen takes the chrome away, and the chrome keeps
//! the arrow over what it makes clickable.
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;

test "group name typed key by key keeps its focus" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 2 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("uses_tab_groups", true);
    const id = b.addTabGroup(b.tabs.items[1]);
    b.editing_group_id = id;
    f.tester.settle(0.5);
    // Emptied: the placeholder shows, and must not take the field's place.
    b.column.group_draft.set("");
    f.tester.frame();
    f.tester.typeText("W");
    f.tester.typeText("o");
    f.tester.typeText("rk");
    try t.expectEqualStrings("Work", b.column.group_draft.text());
}

test "a page filling the screen takes the strip, column and ground" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    f.tester.settle(1);
    b.activeTab().?.immersed = true;
    f.tester.settle(1);
    try t.expectEqual(ui.Color.black, b.applied_ground.?);
    const hole = f.holes()[0];
    try t.expectApproxEqAbs(@as(f32, 0), hole.x, 0.5);
    try t.expectApproxEqAbs(@as(f32, 0), hole.y, 0.5);
    try t.expectApproxEqAbs(@as(f32, 1440), hole.w, 0.5);
    b.activeTab().?.immersed = false;
    f.tester.settle(1);
    try t.expectApproxEqAbs(@as(f32, 232), f.holes()[0].x, 0.5);
}

test "chrome keeps the arrow over a tab" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = false, .tabs = 2 });
    defer f.deinit();
    f.tester.settle(1);
    const s = f.browser.strip.seen.items[1];
    const r = f.tester.ctx.rects.get(s.node).?;
    f.tester.moveTo(r.x + r.w / 2, r.y + r.h / 2);
    f.tester.frame();
    try t.expect(!f.tester.ctx.cursor_hand);
}

test "new group name arrives selected" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .sidebar = true, .tabs = 2 });
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("uses_tab_groups", true);
    const id = b.addTabGroup(b.tabs.items[1]);
    b.editing_group_id = id;
    f.tester.settle(0.5);
    f.tester.typeText("W");
    try t.expectEqualStrings("W", b.column.group_draft.text());
}
