//! nanoui: desktop apps in Zig, with native UI drawn on the GPU or a web
//! frontend in the system webview, after mygo.
//!
//!     pub fn main(init: std.process.Init) !void {
//!         const app = try nanoui.App.create(init, .{ .name = "Hello" });
//!         defer app.destroy();
//!         _ = try app.newWindow(.{ .title = "Hello", .content = .{ .page = .{ .url = "/", .assets = &assets } } });
//!         try app.run();
//!     }
const std = @import("std");
const builtin = @import("builtin");

/// The platform's implementations, chosen at compile time.
const mac = builtin.os.tag == .macos;
const plat = switch (builtin.os.tag) {
    .macos => struct {
        pub const app = @import("app.zig");
        pub const window = @import("window.zig");
        pub const menu = @import("menu.zig");
        pub const tray = @import("tray.zig");
        pub const dialog = @import("dialog.zig");
        pub const desktop = @import("desktop.zig");
        pub const fdwatch = @import("fdwatch.zig");
    },
    .linux => struct {
        pub const app = @import("linux/app.zig");
        pub const window = @import("linux/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("tray_none.zig");
        pub const dialog = @import("linux/dialog.zig");
        pub const desktop = @import("linux/desktop.zig");
        pub const fdwatch = @import("linux/fdwatch.zig");
    },
    .windows => struct {
        pub const app = @import("windows/app.zig");
        pub const window = @import("windows/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("tray_none.zig");
        pub const dialog = @import("windows/dialog.zig");
        pub const desktop = @import("windows/desktop.zig");
        pub const fdwatch = @import("windows/fdwatch.zig");
    },
    else => @compileError("nanoui runs on macOS, Linux and Windows"),
};

/// The Objective-C runtime (macOS only).
pub const objc = if (mac) @import("objc.zig") else struct {};
pub const ui = @import("ui/ui.zig");
pub const tsgen = @import("tsgen.zig");
pub const Surface = if (mac) @import("ui/surface.zig").Surface else void;
pub const a11y = if (mac) @import("ui/a11y.zig") else struct {};

pub const App = plat.app.App;
pub const AppOptions = plat.app.Options;
pub const Window = plat.window.Window;
pub const WindowOptions = plat.window.Options;
pub const PageOptions = plat.window.PageOptions;
pub const Asset = plat.window.Asset;
/// Typed IPC for pages (macOS for now: pages need a webview).
pub const Call = if (mac) @import("ipc.zig").Call else void;
pub const Event = if (mac) @import("ipc.zig").Event else void;

pub const menu = plat.menu;
pub const MenuItem = plat.menu.MenuItem;
pub const MenuRole = plat.menu.Role;
pub const Menu = plat.menu.Menu;
pub const MenuClick = plat.menu.Click;
pub const Tray = plat.tray.Tray;
pub const TrayOptions = plat.tray.Options;
pub const dialog = plat.dialog;
pub const fdwatch = plat.fdwatch;
pub const clipboard = plat.desktop.clipboard;
pub const shell = plat.desktop.shell;
pub const Directory = plat.desktop.Directory;
pub const path = plat.desktop.path;
pub const isDark = plat.desktop.isDark;
pub const accentColor = plat.desktop.accentColor;
/// Updates from GitHub's releases for a signed app bundle (macOS).
pub const update = @import("update.zig");
pub const Updater = update.Updater;
pub const UpdateOptions = update.Options;
/// Runs the event loop for a while (headless tests: replies, processes, timers).
pub const runFor = @import("platform.zig").runFor;

/// nanoui's version, from build.zig.zon (set with tools/version.sh).
pub const version = @import("build_options").version;

test {
    _ = tsgen;
    _ = ui;
    _ = @import("menu_types.zig");
    _ = @import("update.zig");
    if (!mac) {
        inline for (.{ plat.app, plat.window, plat.menu, plat.dialog, plat.desktop, plat.fdwatch, }) |m| std.testing.refAllDecls(m);
        return;
    }
    // Analyze every declaration, used by an example or not.
    inline for (.{ @import("menu.zig"), @import("dialog.zig"), @import("desktop.zig"), @import("tray.zig"), @import("window.zig"), @import("app.zig"), @import("ui/textinput.zig"), @import("fdwatch.zig") }) |m| {
        std.testing.refAllDecls(m);
    }
    std.testing.refAllDecls(@import("desktop.zig").clipboard);
    std.testing.refAllDecls(@import("desktop.zig").shell);
    std.testing.refAllDecls(@import("window.zig").Window);
    std.testing.refAllDecls(@import("app.zig").App);
    std.testing.refAllDecls(@import("menu.zig").Menu);
    std.testing.refAllDecls(@import("menu.zig").Item);
    std.testing.refAllDecls(@import("tray.zig").Tray);
}
