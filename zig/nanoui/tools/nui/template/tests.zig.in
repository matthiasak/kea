//! The view, driven by ui.Tester: rendered offscreen, clicked by its text.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("app.zig");

test "Increment counts up; Reset goes back to 0" {
    var state: app_view.State = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&state, app_view.State.view), .{ .width = 480, .height = 360 });
    defer t.deinit();
    t.settle(0.2);
    try t.clickText("Increment");
    try t.clickText("Increment");
    t.settle(0.2);
    try std.testing.expectEqual(@as(i64, 2), state.count);
    try std.testing.expect(t.hasText("2"));
    try t.clickText("Reset");
    t.settle(0.2);
    try std.testing.expectEqual(@as(i64, 0), state.count);
}
