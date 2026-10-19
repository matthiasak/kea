//! What windows are made of, the same on every platform: their options,
//! a page's or a native view's content, and the files pages are served.
const ui = @import("ui/ui.zig");

/// A file served to pages at `nanoui://localhost<path>`.
pub const Asset = struct {
    path: []const u8,
    data: []const u8,
    mime: ?[]const u8 = null,
};

pub const PageOptions = struct {
    /// Relative URLs resolve against `nanoui://localhost/`, served from
    /// `assets`; absolute URLs (`http://localhost:5173`) load as is.
    url: []const u8 = "/",
    assets: []const Asset = &.{},
    /// Web Inspector (right click > Inspect Element).
    inspectable: bool = true,
};

pub const Content = union(enum) {
    page: PageOptions,
    view: ui.View,
};

pub const TitleBar = enum {
    default,
    /// Content under a transparent title bar; the traffic lights stay.
    hidden,
};

pub fn Callback(comptime Window: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, window: *Window) void,
    };
}

pub fn Options(comptime Window: type) type {
    return struct {
        title: []const u8 = "",
        width: f64 = 800,
        height: f64 = 600,
        min_width: f64 = 200,
        min_height: f64 = 150,
        resizable: bool = true,
        title_bar: TitleBar = .default,
        /// Native UI's colors, fixed; the system's light or dark when null.
        theme: ?ui.Theme = null,
        /// Where the window opens, in screen points from the primary screen's
        /// top left; centered when null.
        x: ?f64 = null,
        y: ?f64 = null,
        always_on_top: bool = false,
        /// Shown at once; otherwise call `show`.
        visible: bool = true,
        /// Called as the window closes, before it is freed.
        on_close: ?Callback(Window) = null,
        content: Content,
    };
}

/// A window's native UI as `--nanoui-snapshot` draws it.
pub const NativeView = struct {
    view: ui.View,
    width: f32,
    height: f32,
    scale: f32,
    theme: ?ui.Theme,
};
