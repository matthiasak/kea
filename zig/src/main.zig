//! KeaZig (`KeaZig.app`): native macOS WebKit browser built with Zig 0.17.0
//! and `nanoui`'s immediate-mode Metal renderer alongside `Kea.app`.
const std = @import("std");
const nanoui = @import("nanoui");
const kea = @import("app/kea.zig");
const browsers = @import("app/browsers.zig");

pub fn main(init: std.process.Init) !void {
    // Closing the last window keeps the app, as Safari and Chrome do (#327).
    const app = try nanoui.App.create(init, .{ .name = kea.app_name, .quit_on_last_window_closed = false });
    defer app.destroy();
    const k = try kea.Kea.create(app.gpa, app, .{});
    defer k.destroy();
    app.options.ctx = k;
    app.options.on_terminate = onTerminate;
    app.options.on_reopen = onReopen;
    app.options.on_active = onActive;
    app.options.dock_menu = browsers.dockMenu(k);
    _ = try k.newBrowser();
    browsers.restore(k);
    try app.run();
}

fn onTerminate(ctx: ?*anyopaque) void {
    const k: *kea.Kea = @ptrCast(@alignCast(ctx.?));
    k.flush();
}

fn onReopen(ctx: ?*anyopaque) void {
    browsers.ensureWindow(@ptrCast(@alignCast(ctx.?)));
}

fn onActive(ctx: ?*anyopaque, active: bool) void {
    browsers.appActive(@ptrCast(@alignCast(ctx.?)), active);
}

test {
    _ = @import("data/json.zig");
    _ = @import("data/disk.zig");
    _ = @import("data/store.zig");
    _ = @import("data/prefs.zig");
    _ = @import("data/kea_import.zig");
    _ = @import("data/history.zig");
    _ = @import("data/url.zig");
    _ = @import("data/registrable.zig");
    _ = @import("data/keywords.zig");
    _ = @import("model/address.zig");
    _ = @import("model/engine.zig");
    _ = @import("data/bookmarks.zig");
    _ = @import("data/site_search.zig");
    _ = @import("data/loot.zig");
    _ = @import("data/curtain.zig");
    _ = @import("data/chats_store.zig");
    _ = @import("data/session.zig");
    _ = @import("data/windows_file.zig");
    _ = @import("data/pins.zig");
    _ = @import("data/spaces.zig");
    _ = @import("web/tab.zig");
    _ = @import("web/dialogs.zig");
    _ = @import("web/favicons.zig");
    _ = @import("web/stage_host.zig");
    _ = @import("model/browser.zig");
    _ = @import("chrome/window_view.zig");
    _ = @import("chrome/room.zig");
    _ = @import("app/kea.zig");
    _ = @import("design/palette.zig");
    _ = @import("chrome/ring.zig");
    _ = @import("chrome/tests_controls.zig");
    _ = @import("chrome/lights.zig");
    _ = @import("chrome/tab_width.zig");
    _ = @import("chrome/pin_grid.zig");
    _ = @import("app/browsers.zig");
}
