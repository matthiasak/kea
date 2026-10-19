//! App-wide state: the options a run starts with, the stores every window
//! shares, and the open browsers (one per window).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const browsers = @import("browsers.zig");
const Store = @import("../data/store.zig").Store;
const Prefs = @import("../data/prefs.zig").Prefs;
const History = @import("../data/history.zig").History;
const Bookmarks = @import("../data/bookmarks.zig").Bookmarks;
const SiteSearch = @import("../data/site_search.zig").SiteSearch;
const Pins = @import("../data/pins.zig").Pins;
const Browser = @import("../model/browser.zig").Browser;
const kea_import = @import("../data/kea_import.zig");

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
    site_search: SiteSearch,
    pins: Pins,
    browsers: std.ArrayList(*Browser) = .empty,
    windows: browsers.Windows = .{},

    pub fn create(gpa: std.mem.Allocator, ui_app: ?*nanoui.App, opts: Options) !*Kea {
        const self = try gpa.create(Kea);
        errdefer gpa.destroy(self);
        // Before any store loads: the store makes KeaZig's folder.
        if (opts.root == null and ui_app != null) kea_import.offer(gpa, opts.suite);
        self.* = .{
            .gpa = gpa,
            .ui_app = ui_app,
            .opts = opts,
            .store = try Store.init(gpa, opts.root, opts.suite),
            .prefs = undefined,
            .history = undefined,
            .bookmarks = undefined,
            .site_search = undefined,
            .pins = undefined,
        };
        self.prefs = Prefs.init(gpa, &self.store, .{
            .testing = opts.root != null,
            .app = if (ui_app) |a| a.nsapp else null,
        });
        self.history.init(gpa, &self.store);
        self.bookmarks = Bookmarks.init(gpa, &self.store);
        self.site_search = SiteSearch.init(gpa, &self.store);
        self.pins = Pins.init(gpa, &self.store);
        // Hidden runs get no Dock icon and never take focus.
        if (opts.hidden) if (ui_app) |a| {
            _ = objc.msg(objc.BOOL, a.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 2)});
        };
        return self;
    }

    pub fn destroy(self: *Kea) void {
        self.flush();
        browsers.closeAll(self);
        self.browsers.deinit(self.gpa);
        self.browsers = .empty;
        self.pins.deinit();
        self.site_search.deinit();
        self.bookmarks.deinit();
        self.history.deinit();
        self.prefs.deinit();
        self.store.deinit();
        self.gpa.destroy(self);
    }

    /// What quitting must not lose (`applicationWillTerminate`, Links.swift:52-60):
    /// every window written down, the last visit still waiting out History's
    /// moment, then every write on its way.
    pub fn flush(self: *Kea) void {
        browsers.flush(self);
        self.history.flush();
        self.store.disk.drain();
    }

    /// The list of spaces changed (`Spaces.changed`): every window follows.
    pub fn spacesChanged(self: *Kea) void {
        for (self.browsers.items) |b| b.redraw();
    }

    /// The oldest window's browser, its tabs from the session files; in a
    /// window of its own unless headless (`app/browsers.zig`).
    pub fn newBrowser(self: *Kea) !*Browser {
        return browsers.open(self, null, null, null);
    }
};
