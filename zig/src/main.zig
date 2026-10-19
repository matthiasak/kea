//! KeaZig (`KeaZig.app`): native macOS WebKit browser built with Zig 0.17.0
//! and `nanoui`'s immediate-mode Metal renderer alongside `Kea.app`.
const std = @import("std");
const nanoui = @import("nanoui");
const kea = @import("app/kea.zig");
const browsers = @import("app/browsers.zig");
const links = @import("app/links.zig");
const menus = @import("app/menus.zig");
const keys = @import("app/keys.zig");

pub fn main(init: std.process.Init) !void {
    // Closing the last window keeps the app, as Safari and Chrome do (#327).
    const app = try nanoui.App.create(init, .{ .name = kea.app_name, .quit_on_last_window_closed = false });
    defer app.destroy();
    const k = try kea.Kea.create(app.gpa, app, .{});
    defer k.destroy();
    links.watchForTrouble(k);
    app.options.ctx = k;
    app.options.on_terminate = onTerminate;
    app.options.on_reopen = onReopen;
    app.options.on_active = onActive;
    app.options.on_open_urls = links.onOpenURLs;
    app.options.on_continue_activity = links.onContinueActivity;
    app.options.dock_menu = browsers.dockMenu(k);
    _ = try k.newBrowser();
    // The menu bar and the app's keys, for the window in front.
    menus.install(k);
    keys.install(k);
    browsers.restore(k);
    // Addresses from other apps have somewhere to go from here on.
    links.hand(k);
    try app.run();
}

fn onTerminate(ctx: ?*anyopaque) void {
    const k: *kea.Kea = @ptrCast(@alignCast(ctx.?));
    k.flush();
}

fn onReopen(ctx: ?*anyopaque) void {
    _ = browsers.ensureWindow(@ptrCast(@alignCast(ctx.?)));
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
    _ = @import("web/shield.zig");
    _ = @import("web/downloads.zig");
    _ = @import("web/downloads_fetches.zig");
    _ = @import("web/stage_host.zig");
    _ = @import("model/browser.zig");
    _ = @import("chrome/window_view.zig");
    _ = @import("chrome/room.zig");
    _ = @import("app/kea.zig");
    _ = @import("design/palette.zig");
    _ = @import("chrome/ring.zig");
    _ = @import("chrome/when.zig");
    _ = @import("chrome/tests_controls.zig");
    _ = @import("chrome/lights.zig");
    _ = @import("chrome/tab_width.zig");
    _ = @import("chrome/pin_grid.zig");
    _ = @import("model/split.zig");
    _ = @import("chrome/pane_divider.zig");
    _ = @import("chrome/split_stage.zig");
    _ = @import("app/browsers.zig");
    _ = @import("app/links.zig");
    _ = @import("web/local_network.zig");
    _ = @import("web/float.zig");
    _ = @import("web/float_moves.zig");
    _ = @import("web/notifications.zig");
    _ = @import("web/inspector.zig");
    _ = @import("web/substitutions.zig");
    _ = @import("web/frame_rate.zig");
    _ = @import("web/little.zig");
    _ = @import("chrome/link_bubble.zig");
    _ = @import("app/commands.zig");
    _ = @import("app/shortcuts.zig");
    _ = @import("app/menus.zig");
    _ = @import("app/keys.zig");
    _ = @import("chrome/kea_flight.zig");
    _ = @import("ai/ai.zig");
    _ = @import("ai/assistant.zig");
    _ = @import("ai/regex.zig");
    _ = @import("ai/client.zig");
    _ = @import("ai/client_more.zig");
    _ = @import("ai/markdown.zig");
    _ = @import("ai/page_text.zig");
    _ = @import("ai/sign_in.zig");
    _ = @import("ai/catalog.zig");
    _ = @import("ai/shell.zig");
    _ = @import("ai/ubi_chat.zig");
    _ = @import("ai/organize.zig");
    _ = @import("ai/chat_sections.zig");
    _ = @import("ai/mermaid/mermaid.zig");
    _ = @import("sys/keychain.zig");
    _ = @import("sys/urlsession.zig");
    _ = @import("sync/core.zig");
    _ = @import("sync/sigv4.zig");
    _ = @import("sync/drop.zig");
    _ = @import("sync/sync_tests.zig");
}
