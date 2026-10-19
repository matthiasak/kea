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
const spaces = @import("../data/spaces.zig");
const Space = spaces.Space;
const Uuid = @import("../data/json.zig").Uuid;
const kea_import = @import("../data/kea_import.zig");
const Favicons = @import("../web/favicons.zig").Favicons;

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
    /// Every space, the first first (`Browser.spaces`, one list for every window).
    spaces: std.json.Parsed([]Space),
    browsers: std.ArrayList(*Browser) = .empty,
    windows: browsers.Windows = .{},
    /// Tab ids, unique across windows: a tab moved to another keeps its own.
    next_tab_id: u64 = 1,
    /// Each space's own WebKit store, made once (`Spaces.stores`).
    stores: std.AutoArrayHashMapUnmanaged(Uuid, objc.Object) = .empty,
    /// Sites' icons, every window's (`Favicons.shared`).
    favicons: *Favicons = undefined,
    /// Two fingers between spaces, every window's (`SpaceSwipe.shared`).
    swipe: @import("../chrome/space_swipe.zig").SpaceSwipe = .{},

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
            .spaces = undefined,
        };
        self.prefs = Prefs.init(gpa, &self.store, .{
            .testing = opts.root != null,
            .app = if (ui_app) |a| a.nsapp else null,
        });
        self.history.init(gpa, &self.store);
        self.bookmarks = Bookmarks.init(gpa, &self.store);
        self.site_search = SiteSearch.init(gpa, &self.store);
        self.pins = Pins.init(gpa, &self.store);
        self.spaces = spaces.read(&self.store);
        // What a deleted space left behind, if WebKit wouldn't let it go then.
        @import("../model/spaces.zig").sweep(self);
        self.favicons = try Favicons.create(self);
        // Hidden runs get no Dock icon and never take focus.
        if (opts.hidden) if (ui_app) |a| {
            _ = objc.msg(objc.BOOL, a.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 2)});
        };
        return self;
    }

    pub fn destroy(self: *Kea) void {
        self.flush();
        self.swipe.stop();
        browsers.closeAll(self);
        self.browsers.deinit(self.gpa);
        self.browsers = .empty;
        for (self.stores.values()) |s| objc.release(s);
        self.stores.deinit(self.gpa);
        self.favicons.deinit();
        self.spaces.deinit();
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

    /// The list of spaces changed (`Spaces.changed`, written by
    /// `data/spaces.write`): read again, and a window showing a space that
    /// went goes back to the first.
    pub fn spacesChanged(self: *Kea) void {
        self.spaces.deinit();
        self.spaces = spaces.read(&self.store);
        for (self.browsers.items) |b| {
            if (self.spaceIndex(b.space_id) == null) b.switchSpace(Uuid.first);
            b.redraw();
        }
    }

    pub fn spaceIndex(self: *const Kea, id: Uuid) ?usize {
        for (self.spaces.value, 0..) |s, i| if (s.id.eql(id)) return i;
        return null;
    }

    pub fn tabId(self: *Kea) u64 {
        defer self.next_tab_id += 1;
        return self.next_tab_id;
    }

    /// An icon arrived (`Favicons.arrived`): every window shows it on every
    /// tab of that site.
    pub fn iconsChanged(self: *Kea) void {
        for (self.browsers.items) |b| b.redraw();
    }

    /// A space's pins changed in one window; the others follow (`Pins.changed`).
    pub fn pinsChanged(self: *Kea, from: *Browser, space: Uuid) void {
        for (self.browsers.items) |b| if (b != from) b.pinsChanged(space);
    }

    /// `Spaces.store(for:)`: null for the default store — the first space's,
    /// and every space signed in with it — and always under tests, whose
    /// tabs keep nothing (`Tab.buildWeb`); otherwise the space's own.
    pub fn dataStore(self: *Kea, space: Uuid) ?objc.Object {
        if (self.opts.root != null or self.opts.headless or space.eql(Uuid.first)) return null;
        const at = self.spaceIndex(space) orelse return null;
        if (self.spaces.value[at].sharesSignIns == true) return null;
        if (self.stores.get(space)) |made| return made;
        const cls = objc.class("WKWebsiteDataStore");
        if (!objc.msg(objc.BOOL, cls, "respondsToSelector:", .{objc.sel("dataStoreForIdentifier:")})) return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        const uuid = objc.msg(objc.Object, objc.alloc("NSUUID"), "initWithUUIDBytes:", .{&space.bytes});
        defer objc.release(uuid);
        const made = objc.retain(objc.msg(objc.Object, cls, "dataStoreForIdentifier:", .{uuid}));
        self.stores.put(self.gpa, space, made) catch {
            objc.release(made);
            return null;
        };
        return made;
    }

    /// The oldest window's browser, its tabs from the session files; in a
    /// window of its own unless headless (`app/browsers.zig`).
    pub fn newBrowser(self: *Kea) !*Browser {
        return browsers.open(self, null, null);
    }
};
