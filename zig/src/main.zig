//! KeaZig (`KeaZig.app`): native macOS WebKit browser built with Zig 0.17.0
//! and `nanoui`'s immediate-mode Metal renderer alongside `Kea.app`.
const std = @import("std");
const nanoui = @import("nanoui");
const kea = @import("app/kea.zig");

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = kea.app_name, .quit_on_last_window_closed = true });
    defer app.destroy();
    const k = try kea.Kea.create(app.gpa, app, .{});
    defer k.destroy();
    _ = try k.newBrowser();
    try app.run();
}

test {
    _ = @import("data/store.zig");
    _ = @import("data/prefs.zig");
    _ = @import("data/history.zig");
    _ = @import("data/bookmarks.zig");
    _ = @import("web/tab.zig");
    _ = @import("web/stage_host.zig");
    _ = @import("model/browser.zig");
    _ = @import("chrome/window_view.zig");
    _ = @import("app/kea.zig");
}
