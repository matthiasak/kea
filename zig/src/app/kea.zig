//! App-wide state: the options a run starts with, the stores every window
//! shares, and the open browsers (one per window).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Store = @import("../data/store.zig").Store;
const Prefs = @import("../data/prefs.zig").Prefs;
const History = @import("../data/history.zig").History;
const Bookmarks = @import("../data/bookmarks.zig").Bookmarks;
const Browser = @import("../model/browser.zig").Browser;
const window_view = @import("../chrome/window_view.zig");

/// The app's name wherever Swift's strings name Kea the app.
pub const app_name = "KeaZig";

pub const Options = struct {
    /// Application Support folder override (tests).
    root: ?[]const u8 = null,
    /// NSUserDefaults suite override (tests).
    suite: ?[]const u8 = null,
    /// Windows created off-screen at (-20000,-20000), never ordered front.
    hidden: bool = false,
    /// Tabs never build a WKWebView and browsers get no window (ui-test, perf, snapshots).
    headless: bool = false,
    /// WKURLSchemeHandler registered for "kea-test" on every configuration (e2e).
    scheme_handler: ?objc.Object = null,
};

pub const Kea = struct {
    gpa: std.mem.Allocator,
    ui_app: ?*nanoui.App,
    opts: Options,
    store: Store,
    prefs: Prefs,
    history: History,
    bookmarks: Bookmarks,
    browsers: std.ArrayList(*Browser) = .empty,

    pub fn create(gpa: std.mem.Allocator, ui_app: ?*nanoui.App, opts: Options) !*Kea {
        const self = try gpa.create(Kea);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .ui_app = ui_app,
            .opts = opts,
            .store = try Store.init(gpa, opts.root, opts.suite),
            .prefs = undefined,
            .history = undefined,
            .bookmarks = undefined,
        };
        self.prefs = Prefs.init(&self.store);
        self.history = History.init(gpa, &self.store);
        self.bookmarks = Bookmarks.init(gpa, &self.store);
        // Hidden runs get no Dock icon and never take focus.
        if (opts.hidden) if (ui_app) |a| {
            _ = objc.msg(objc.BOOL, a.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 2)});
        };
        return self;
    }

    pub fn destroy(self: *Kea) void {
        while (self.browsers.items.len > 0) {
            const b = self.browsers.items[self.browsers.items.len - 1];
            // Closing the window runs `onWindowClose`, which drops `b`.
            if (b.window) |w| w.close();
            if (self.browsers.items.len > 0 and self.browsers.items[self.browsers.items.len - 1] == b) {
                _ = self.browsers.pop();
                b.destroy();
            }
        }
        self.browsers.deinit(self.gpa);
        self.history.flush();
        self.bookmarks.deinit();
        self.history.deinit();
        self.prefs.deinit();
        self.store.deinit();
        self.gpa.destroy(self);
    }

    /// A new browser, in its own window unless headless.
    pub fn newBrowser(self: *Kea) !*Browser {
        const b = try Browser.create(self);
        errdefer b.destroy();
        try self.browsers.append(self.gpa, b);
        errdefer _ = self.browsers.pop();
        if (self.opts.headless) return b;
        const app = self.ui_app orelse return b;
        const off: ?f64 = if (self.opts.hidden) -20000 else null;
        const win = try app.newWindow(.{
            .title = app_name,
            .width = 1280,
            .height = 820,
            .min_width = 520,
            .min_height = 380,
            .title_bar = .hidden,
            .visible = !self.opts.hidden,
            .x = off,
            .y = off,
            .on_close = .{ .ctx = b, .func = onWindowClose },
            .content = .{ .view = ui.View.init(b, window_view.view) },
        });
        try b.bindWindow(win);
        return b;
    }

    fn onWindowClose(ctx: *anyopaque, _: *nanoui.Window) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        const self = b.kea;
        b.unbindWindow();
        for (self.browsers.items, 0..) |item, i| {
            if (item == b) {
                _ = self.browsers.orderedRemove(i);
                break;
            }
        }
        b.destroy();
    }
};
