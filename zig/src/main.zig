//! Kea (`Kea.app`): native macOS WebKit browser built with Zig 0.17.0
//! and `nanoui`'s immediate-mode Metal renderer.
const std = @import("std");
const nanoui = @import("nanoui");
const kea = @import("app/kea.zig");
const browsers = @import("app/browsers.zig");
const links = @import("app/links.zig");
const menus = @import("app/menus.zig");
const keys = @import("app/keys.zig");
const importing = @import("model/browser_import.zig");

pub fn main(init: std.process.Init) !void {
    // Closing the last window keeps the app, as Safari and Chrome do (#327).
    const app = try nanoui.App.create(init, .{ .name = kea.app_name, .quit_on_last_window_closed = false });
    defer app.destroy();
    refuseSecondCopy();
    const k = try kea.Kea.create(app.gpa, app, .{});
    defer k.destroy();
    links.watchForTrouble(k);
    // What an import left half done when the app last stopped (Links.swift:105).
    importing.sweepLater();
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
    // Keys and timers, once the windows are up (Links.swift:191).
    k.sync.start();
    // Addresses from other apps have somewhere to go from here on.
    links.hand(k);
    const ready_ms = (nanoui.ui.clock.now() - k.launch_t0) * 1000.0;
    std.log.info("launch: ai {d:.1} ms, history {d:.1} ms, ext {d:.1} ms, create {d:.1} ms, ready {d:.1} ms", .{
        k.launch_ai_ms, k.launch_history_ms, k.launch_ext_ms, k.launch_create_ms, ready_ms,
    });
    try app.run();
}

fn onTerminate(ctx: ?*anyopaque) void {
    const k: *kea.Kea = @ptrCast(@alignCast(ctx.?));
    // A file still being brought in stops, given up to five seconds.
    importing.waitForImports();
    k.flush();
}

fn onReopen(ctx: ?*anyopaque) void {
    _ = browsers.ensureWindow(@ptrCast(@alignCast(ctx.?)));
}

fn onActive(ctx: ?*anyopaque, active: bool) void {
    const k: *kea.Kea = @ptrCast(@alignCast(ctx.?));
    browsers.appActive(k, active);
    // Sync's didBecomeActive observer, from `start()` on.
    if (active and k.sync.started) k.sync.syncNow();
}

extern "c" fn exit(code: c_int) noreturn;

/// Another Kea already running (the same bundle id from another place): both would write the same folder, so this one says so and quits.
fn refuseSecondCopy() void {
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const running = objc.msg(objc.Object, objc.class("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:", .{objc.nsString("app.kea.browser")});
    const count = objc.msg(objc.NSUInteger, running, "count", .{});
    const my_pid = std.c.getpid();
    var other = false;
    for (0..count) |i| {
        const entry = objc.msg(objc.Object, running, "objectAtIndex:", .{i});
        if (objc.msg(c_int, entry, "processIdentifier", .{}) != my_pid) {
            other = true;
            break;
        }
    }
    if (!other) return;
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, nsapp, "activateIgnoringOtherApps:", .{objc.YES});
    const alert = objc.new("NSAlert");
    defer objc.release(alert);
    objc.msg(void, alert, "setMessageText:", .{objc.nsString("Kea is already open")});
    objc.msg(void, alert, "setInformativeText:", .{objc.nsString("Another copy of Kea is running and uses the same tabs, history and settings. Quit it, then open Kea again.")});
    _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString("Quit")});
    _ = objc.msg(objc.NSInteger, alert, "runModal", .{});
    exit(0);
}

test {
    _ = @import("ext/controller.zig");
    _ = @import("ext/controller_updates.zig");
    _ = @import("ext/controller_delegate_frames.zig");
    _ = @import("ext/controller_fence.zig");
    _ = @import("ext/crx_tests.zig");
    _ = @import("ext/store_relay.zig");
    _ = @import("ext/downloads.zig");
    _ = @import("ext/shims/install_tests.zig");
    _ = @import("ext/shims/answer_tests.zig");
    _ = @import("data/json.zig");
    _ = @import("data/disk.zig");
    _ = @import("data/store.zig");
    _ = @import("data/prefs.zig");
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
    _ = @import("chrome/pop_up_button.zig");
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
    _ = @import("ai/whitespace.zig");
    _ = @import("chrome/spinner.zig");
    _ = @import("ai/page_text.zig");
    _ = @import("ai/sign_in.zig");
    _ = @import("ai/catalog.zig");
    _ = @import("ai/shell.zig");
    _ = @import("ai/ubi_chat.zig");
    _ = @import("passwords/passwords_tests.zig");
    _ = @import("ai/organize.zig");
    _ = @import("ai/chat_sections.zig");
    _ = @import("ai/mermaid/mermaid.zig");
    _ = @import("ai/markdown_view.zig");
    _ = @import("sys/keychain.zig");
    _ = @import("sys/urlsession.zig");
    _ = @import("sync/core.zig");
    _ = @import("sync/sigv4.zig");
    _ = @import("sync/drop.zig");
    _ = @import("sync/sync_tests.zig");
    _ = @import("ext/ext.zig");
    _ = @import("ext/value.zig");
    _ = @import("ext/capture.zig");
    _ = @import("ext/capture_watch.zig");
    _ = @import("ext/offscreen.zig");
    _ = @import("ext/native_pipe.zig");
    _ = @import("ext/native.zig");
    _ = @import("ext/redirect.zig");
    _ = @import("ext/files.zig");
    _ = @import("ext/external.zig");
    _ = @import("import/tests.zig");
}
