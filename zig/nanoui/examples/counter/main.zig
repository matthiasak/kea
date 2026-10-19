//! A window of native UI: a view is a Zig function of the app's state.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

const Counter = struct {
    n: i64 = 0,

    fn view(s: *Counter, c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 16 });
        defer ui.end(c);
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        ui.row(c, .{ .gap = 8 });
        defer ui.end(c);
        if (ui.button(c, "−", .{ .size = 16 }).clicked) s.n -= 1;
        if (ui.button(c, "Increment", .{ .variant = .primary, .size = 16 }).clicked) s.n += 1;
        if (ui.button(c, "Reset", .{ .variant = .ghost, .size = 16, .disabled = s.n == 0 }).clicked) s.n = 0;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{
        .title = "Counter",
        .width = 420,
        .height = 300,
        .content = .{ .view = .init(&state, Counter.view) },
    });
    try app.run();
}
