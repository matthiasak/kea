//! KeaZig (`KeaZig.app`): native macOS WebKit browser built with Zig 0.17.0
//! and `nanoui`'s immediate-mode Metal renderer alongside `Kea.app`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("browser.zig").Browser;
const chrome = @import("chrome.zig");
const BenchServer = @import("bench.zig").BenchServer;

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{
        .name = "KeaZig",
        .quit_on_last_window_closed = true,
    });
    defer app.destroy();

    const browser = try Browser.create(app.gpa, app);
    defer browser.destroy();

    const bench_srv = try BenchServer.start(app.gpa, browser);
    defer if (bench_srv) |s| s.destroy();

    // Probe runs (`KEA_PROBE=...`) keep their window hidden offscreen so automated
    // tests never steal focus or flash a window on the desktop.
    const visible = !browser.store.testing;
    const win = try app.newWindow(.{
        .title = "KeaZig",
        .width = 1280,
        .height = 820,
        .min_width = 520,
        .min_height = 380,
        .title_bar = .hidden,
        .visible = visible,
        .content = .{ .view = ui.View.init(browser, chrome.view) },
    });
    try browser.bindWindow(win);

    try app.run();
}

test {
    _ = @import("store.zig");
    _ = @import("prefs.zig");
    _ = @import("history.zig");
    _ = @import("bookmarks.zig");
    _ = @import("tab.zig");
    _ = @import("stage_host.zig");
    _ = @import("browser.zig");
    _ = @import("chrome.zig");
    _ = @import("bench.zig");
    _ = @import("c_api.zig");
}
