//! The extensions controller (Extensions.swift 1-1003): WebKit's
//! controller and the installed list, what the row looks like to WebKit,
//! settings an extension set. Starting and loading: `controller_load.zig`;
//! following windows: `controller_follow.zig`; installing and reloading:
//! `controller_install.zig`; removing: `controller_forget.zig`; updates:
//! `controller_updates.zig`. ExtDelegate's half (asking, buttons, delegate,
//! adapters) is in its own files and its state in `del`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ext = @import("ext.zig");
const value = @import("value.zig");
const json = @import("../data/json.zig");
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const browsers = @import("../app/browsers.zig");
const load_ops = @import("controller_load.zig");
const follow_ops = @import("controller_follow.zig");
const install_ops = @import("controller_install.zig");
const forget_ops = @import("controller_forget.zig");
const updates_ops = @import("controller_updates.zig");

pub const Installed = ext.Installed;

/// `installed.json`, under the store's folder.
pub const list_name = "Extensions/installed.json";

/// A set of ids, keys owned.
pub const Ids = struct {
    map: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn has(s: *const Ids, id: []const u8) bool {
        return s.map.contains(id);
    }
    /// Whether it was newly put in (Swift `insert(_:).inserted`).
    pub fn put(s: *Ids, gpa: std.mem.Allocator, id: []const u8) bool {
        if (s.map.contains(id)) return false;
        const k = gpa.dupe(u8, id) catch return false;
        s.map.put(gpa, k, {}) catch {
            gpa.free(k);
            return false;
        };
        return true;
    }
    pub fn remove(s: *Ids, gpa: std.mem.Allocator, id: []const u8) void {
        const kv = s.map.fetchSwapRemove(id) orelse return;
        gpa.free(kv.key);
    }
    pub fn deinit(s: *Ids, gpa: std.mem.Allocator) void {
        for (s.map.keys()) |k| gpa.free(k);
        s.map.deinit(gpa);
    }
};

/// Every `Extensions` made, numbered: work finishing after its controller
/// went checks it is still the one (`alive`).
var serials: u64 = 0;
var current: ?*Extensions = null;

pub const Extensions = struct {
    kea: *Kea,
    gpa: std.mem.Allocator,
    serial: u64,
    /// WKWebExtensionController (retained).
    controller: objc.Object,
    /// ExtDelegate's WKWebExtensionControllerDelegate object, setZig → *Extensions.
    delegate: ?objc.Object = null,
    /// `Extensions.pages`: the extension pages' WKUserContentController (retained).
    pages: ?objc.Object = null,
    /// `Store.websites`: where extension pages keep what they store (retained).
    websites: objc.Object,
    /// Heap-owned rows (every string dup'd on gpa).
    installed: std.ArrayList(Installed) = .empty,
    /// id → WKWebExtensionContext (retained); keys owned.
    contexts: std.StringArrayHashMapUnmanaged(objc.Object) = .empty,
    /// Bumped when any button changes (UI redraws).
    actions_changed: u64 = 0,
    busy: ?[]u8 = null,
    /// id → errors, newest last, ≤40 each; keys owned.
    errors: std.StringArrayHashMapUnmanaged(std.ArrayList([]u8)) = .empty,
    started: bool = false,
    /// ExtDelegate's half.
    del: @import("controller_delegate_state.zig").State = .{},
    /// ExtAnswer's half.
    answer: @import("shims/answer.zig").State = .{},
    /// Waiting for `started` (`onStarted`).
    on_started: std.ArrayList(*load_ops.Waiter) = .empty,
    /// Each window's row as WebKit last heard it, and what was being followed.
    following: follow_ops.State = .{},
    reloading: Ids = .{},
    /// `start` ran: loading at launch begins once.
    begun: bool = false,
    /// Last revive, by id (Swift date).
    revived: std.StringArrayHashMapUnmanaged(f64) = .empty,
    loads_this_run: Ids = .{},
    loaded_before: Ids = .{},
    /// `errorWatchers`: id → observer (retained).
    error_watchers: std.StringArrayHashMapUnmanaged(objc.Object) = .empty,
    /// What removed extensions kept, still being cleared: id → loads waiting.
    forgetting: std.StringArrayHashMapUnmanaged(std.ArrayList(*load_ops.Load)) = .empty,
    /// The Settings page and anything else showing the list (UI wave).
    on_change: ?*const fn (*Extensions) void = null,

    pub fn create(kea: *Kea) !*Extensions {
        const self = try kea.gpa.create(Extensions);
        errdefer kea.gpa.destroy(self);
        const pool = objc.Pool.push();
        defer pool.pop();
        const testing = kea.opts.root != null;
        objc.msg(void, objc.class("WKWebExtensionMatchPattern"), "registerCustomURLScheme:", .{objc.nsString(ext.scheme)});
        @import("shims/install.zig").testing = testing;
        // A test run keeps its extensions' storage apart, as it does its
        // cookies and passwords.
        const config_cls = objc.class("WKWebExtensionControllerConfiguration");
        const configuration = objc.msg(objc.Object, config_cls, if (testing) "nonPersistentConfiguration" else "defaultConfiguration", .{});
        const store_cls = objc.class("WKWebsiteDataStore");
        const websites = objc.retain(objc.msg(objc.Object, store_cls, if (testing) "nonPersistentDataStore" else "defaultDataStore", .{}));
        objc.msg(void, configuration, "setDefaultWebsiteDataStore:", .{websites});
        const views = objc.msg(?objc.Object, configuration, "webViewConfiguration", .{}) orelse
            objc.msg(objc.Object, objc.new("WKWebViewConfiguration"), "autorelease", .{});
        objc.msg(void, views, "setWebsiteDataStore:", .{websites});
        // The same user agent as the web tabs, to the letter: WebKit stops
        // running workers when it changes, and never starts extension ones again.
        objc.msg(void, views, "setApplicationNameForUserAgent:", .{objc.nsString(@import("../web/config.zig").userAgentName())});
        const prefs = objc.msg(objc.Object, views, "preferences", .{});
        // A test run sits behind other windows (WKInactiveSchedulingPolicyNone).
        if (testing and objc.msg(objc.BOOL, prefs, "respondsToSelector:", .{objc.sel("setInactiveSchedulingPolicy:")}))
            objc.msg(void, prefs, "setInactiveSchedulingPolicy:", .{@as(objc.NSInteger, 2)});
        self.* = .{
            .kea = kea,
            .gpa = kea.gpa,
            .serial = blk: {
                serials += 1;
                break :blk serials;
            },
            .controller = undefined,
            .websites = websites,
        };
        // Screen recording: an extension's pages ask through this.
        const capture = @import("capture.zig");
        const ucc = objc.msg(objc.Object, views, "userContentController", .{});
        objc.msg(void, ucc, "addScriptMessageHandlerWithReply:contentWorld:name:", .{ capture.handler(self), @import("../web/config.zig").pageWorld(), objc.nsString(capture.channel) });
        self.pages = objc.retain(ucc);
        capture.mockDevices(kea, prefs);
        objc.msg(void, configuration, "setWebViewConfiguration:", .{views});
        self.controller = objc.msg(objc.Object, objc.alloc("WKWebExtensionController"), "initWithConfiguration:", .{configuration});
        @import("controller_delegate.zig").attach(self);
        self.readList();
        current = self;
        // Extension commands' keys go through Settings › Shortcuts (#189).
        kea.shortcuts.ext = self;
        return self;
    }

    pub fn destroy(self: *Extensions) void {
        const gpa = self.gpa;
        current = null;
        self.kea.shortcuts.ext = null;
        @import("capture.zig").release(self);
        const pool = objc.Pool.push();
        defer pool.pop();
        for (self.on_started.items) |w| w.drop();
        self.on_started.deinit(gpa);
        follow_ops.deinit(self);
        @import("controller_delegate_state.zig").deinit(self);
        @import("shims/answer.zig").deinit(self);
        const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
        for (self.error_watchers.keys(), self.error_watchers.values()) |k, o| {
            objc.msg(void, center, "removeObserver:", .{o});
            load_ops.dropWatcher(o);
            gpa.free(k);
        }
        self.error_watchers.deinit(gpa);
        for (self.contexts.keys(), self.contexts.values()) |k, c| {
            _ = objc.msg(objc.BOOL, self.controller, "unloadExtensionContext:error:", .{ c, @as(?*anyopaque, null) });
            objc.release(c);
            gpa.free(k);
        }
        self.contexts.deinit(gpa);
        for (self.forgetting.keys(), self.forgetting.values()) |k, *v| {
            for (v.items) |l| l.drop();
            v.deinit(gpa);
            gpa.free(k);
        }
        self.forgetting.deinit(gpa);
        if (self.delegate) |d| {
            objc.msg(void, self.controller, "setDelegate:", .{@as(?objc.Object, null)});
            objc.setZig(d, null);
            objc.release(d);
        }
        objc.release(self.controller);
        if (self.pages) |p| {
            objc.msg(void, p, "removeScriptMessageHandlerForName:contentWorld:", .{ objc.nsString(@import("capture.zig").channel), @import("../web/config.zig").pageWorld() });
            objc.release(p);
        }
        objc.release(self.websites);
        for (self.installed.items) |r| freeRow(gpa, r);
        self.installed.deinit(gpa);
        if (self.busy) |b| gpa.free(b);
        for (self.errors.keys(), self.errors.values()) |k, *v| {
            for (v.items) |s| gpa.free(s);
            v.deinit(gpa);
            gpa.free(k);
        }
        self.errors.deinit(gpa);
        self.reloading.deinit(gpa);
        for (self.revived.keys()) |k| gpa.free(k);
        self.revived.deinit(gpa);
        self.loads_this_run.deinit(gpa);
        self.loaded_before.deinit(gpa);
        gpa.destroy(self);
    }

    // MARK: the list

    fn readList(self: *Extensions) void {
        // `Store.load` sets aside a list that won't decode.
        const parsed = self.kea.store.load([]Installed, list_name) orelse return;
        defer parsed.deinit();
        for (parsed.value) |r| {
            const row_ = json.clone(self.gpa, r) catch continue;
            self.installed.append(self.gpa, row_) catch freeRow(self.gpa, row_);
        }
    }

    /// `save()`: the list as it is now.
    pub fn save(self: *Extensions) void {
        const dir = self.kea.store.folderFor("Extensions") catch return;
        self.gpa.free(dir);
        self.kea.store.save(list_name, self.installed.items, false);
        self.changed();
    }

    /// The list, a context or `busy` changed: whatever shows them hears.
    pub fn changed(self: *Extensions) void {
        @import("store_relay.zig").tellAll(self.kea);
        if (self.on_change) |f| f(self);
        for (self.kea.browsers.items) |b| b.redraw();
    }

    pub fn setBusy(self: *Extensions, id: ?[]const u8) void {
        if (self.busy) |b| self.gpa.free(b);
        self.busy = if (id) |i| self.gpa.dupe(u8, i) catch null else null;
        self.changed();
    }

    pub fn row(self: *Extensions, id: []const u8) ?*Installed {
        for (self.installed.items) |*r| if (std.mem.eql(u8, r.id, id)) return r;
        return null;
    }

    pub fn rowIndex(self: *Extensions, id: []const u8) ?usize {
        for (self.installed.items, 0..) |r, i| if (std.mem.eql(u8, r.id, id)) return i;
        return null;
    }

    pub fn context(self: *Extensions, id: []const u8) ?objc.Object {
        return self.contexts.get(id);
    }

    pub fn loadedBefore(self: *Extensions, id: []const u8) bool {
        return self.loaded_before.has(id);
    }

    /// `Extensions.folder(for:)`: <KeaZig folder>/Extensions/<id>, on gpa.
    pub fn folderFor(self: *Extensions, id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/Extensions/{s}", .{ self.kea.store.folder, id });
    }

    pub fn noteError(self: *Extensions, text: []const u8, id: []const u8) void {
        const gpa = self.gpa;
        const entry = self.errors.getOrPut(gpa, id) catch return;
        if (!entry.found_existing) {
            entry.key_ptr.* = gpa.dupe(u8, id) catch {
                self.errors.swapRemoveAt(entry.index);
                return;
            };
            entry.value_ptr.* = .empty;
        }
        const list = entry.value_ptr;
        list.append(gpa, gpa.dupe(u8, text) catch return) catch return;
        while (list.items.len > 40) gpa.free(list.orderedRemove(0));
        self.changed();
    }

    /// `errors[id] = nil`.
    pub fn clearErrors(self: *Extensions, id: []const u8) void {
        const kv = self.errors.fetchSwapRemove(id) orelse return;
        for (kv.value.items) |s| self.gpa.free(s);
        var list = kv.value;
        list.deinit(self.gpa);
        self.gpa.free(kv.key);
    }

    /// The browser to act in: the window in front's, else the first.
    pub fn browser(self: *Extensions) ?*Browser {
        return browsers.acting(self.kea);
    }

    fn announce(self: *Extensions, text: []const u8) void {
        if (self.browser()) |b| b.announce(text);
    }

    pub fn announceFmt(self: *Extensions, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        defer self.gpa.free(text);
        self.announce(text);
    }

    // MARK: the row, as WebKit sees it

    /// Private tabs see no extensions unless Settings › Extensions says
    /// they may — and then only the ones made since.
    pub fn seen(_: *Extensions, tab: *const Tab) bool {
        return !tab.shy or carriesExtensions(tab);
    }

    /// The tabs of `b` (null: the first window's) an extension sees, on `gpa`.
    pub fn visibleTabs(self: *Extensions, gpa: std.mem.Allocator, b: ?*Browser) ![]*Tab {
        const from = b orelse (if (self.kea.browsers.items.len > 0) self.kea.browsers.items[0] else return &.{});
        var out: std.ArrayList(*Tab) = .empty;
        errdefer out.deinit(gpa);
        for (from.tabs.items) |t| if (self.seen(t)) try out.append(gpa, t);
        return out.toOwnedSlice(gpa);
    }

    fn nthSeen(self: *Extensions, b: *Browser, index: usize) ?*Tab {
        var n: usize = 0;
        for (b.tabs.items) |t| if (self.seen(t)) {
            if (n == index) return t;
            n += 1;
        };
        return null;
    }

    /// `tab(window:index:)`: the window at `position` in the windows' order.
    pub fn tabAt(self: *Extensions, position: usize, index: usize) ?*Tab {
        if (position >= self.kea.browsers.items.len) return null;
        return self.nthSeen(self.kea.browsers.items[position], index);
    }

    /// `tab(windowFrame:index:)`: `frame` as windows.getAll() gives it —
    /// left, top, width, height — turned back from the top of the first
    /// screen, give or take two points.
    pub fn tabAtFrame(self: *Extensions, frame: objc.CGRect, index: usize) ?*Tab {
        const pool = objc.Pool.push();
        defer pool.pop();
        const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
        const height: f64 = if (objc.msg(?objc.Object, screens, "firstObject", .{})) |s| objc.msg(objc.CGRect, s, "frame", .{}).size.height else 0;
        var match: ?*Browser = null;
        for (self.kea.browsers.items) |b| {
            const w = b.window orelse continue;
            const f = objc.msg(objc.CGRect, w.nswindow, "frame", .{});
            const top = height - (f.origin.y + f.size.height);
            if (@abs(f.origin.x - frame.origin.x) <= 2 and @abs(top - frame.origin.y) <= 2 and
                @abs(f.size.width - frame.size.width) <= 2 and @abs(f.size.height - frame.size.height) <= 2)
            {
                if (match != null) return null;
                match = b;
            }
        }
        return self.nthSeen(match orelse return null, index);
    }

    /// `browser(of:)`: the window a tab is in, when it is in one's row.
    pub fn browserOf(self: *Extensions, tab: *const Tab) ?*Browser {
        for (self.kea.browsers.items) |b| for (b.tabs.items) |t| if (t.id == tab.id) return b;
        return null;
    }

    // MARK: settings an extension set (chrome.privacy, chrome.proxy)

    fn settingsKey(buf: []u8, id: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "extensions.settings.{s}", .{id}) catch null;
    }

    /// `Extensions.settings(for:)`; null for none. The caller deinits.
    pub fn settings(self: *Extensions, id: []const u8) ?std.json.Parsed(std.json.Value) {
        var buf: [160]u8 = undefined;
        const key = settingsKey(&buf, id) orelse return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        const d = objc.msg(?objc.Object, self.kea.store.defaults, "dictionaryForKey:", .{objc.nsString(key)}) orelse return null;
        return value.toJson(self.gpa, d);
    }

    /// `Extensions.setSettings(_:for:)`: an empty object (or anything not
    /// an object) takes the key away.
    pub fn setSettings(self: *Extensions, id: []const u8, values: std.json.Value) void {
        var buf: [160]u8 = undefined;
        const key = settingsKey(&buf, id) orelse return;
        if (values != .object or values.object.count() == 0) return self.kea.store.remove(key);
        const pool = objc.Pool.push();
        defer pool.pop();
        const o = value.toObject(values) orelse return;
        objc.msg(void, self.kea.store.defaults, "setObject:forKey:", .{ o, objc.nsString(key) });
    }

    /// The extension, on and running, that asked the browser not to offer
    /// to save passwords — a password manager doing the saving itself.
    pub fn passwordSavingTakenBy(self: *Extensions) ?[]const u8 {
        for (self.installed.items) |r| {
            if (!r.enabled) continue;
            const s = self.settings(r.id) orelse continue;
            defer s.deinit();
            if (s.value != .object) continue;
            const v = s.value.object.get("privacy.services.passwordSavingEnabled") orelse continue;
            if (v == .bool and !v.bool) return r.name;
        }
        return null;
    }

    // MARK: switches

    pub fn setPinned(self: *Extensions, id: []const u8, on: bool) void {
        const r = self.row(id) orelse return;
        r.pinned = on;
        self.save();
        self.actions_changed += 1;
    }

    pub fn setEnabled(self: *Extensions, id: []const u8, on: bool) void {
        const r = self.row(id) orelse return;
        r.enabled = on;
        self.save();
        if (on) {
            load_ops.load(self, id, null, null);
        } else {
            load_ops.unload(self, id);
            @import("capture.zig").forget(self, id);
        }
    }

    pub fn openOptions(self: *Extensions, id: []const u8) void {
        const c = self.context(id) orelse return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const url = objc.msg(?objc.Object, c, "optionsPageURL", .{}) orelse return;
        const b = self.browser() orelse return;
        _ = b.open(objc.fromNSString(objc.msg(objc.Object, url, "absoluteString", .{})), .{ .foreground = true });
    }

    // MARK: new tab pages

    pub const Candidate = struct { id: []const u8, url: objc.Object };

    /// `newTabCandidate`: the last added that asks (url autoreleased).
    pub fn newTabCandidate(self: *Extensions) ?Candidate {
        var i = self.installed.items.len;
        while (i > 0) {
            i -= 1;
            const r = self.installed.items[i];
            if (!r.enabled) continue;
            const c = self.context(r.id) orelse continue;
            if (objc.msg(?objc.Object, c, "overrideNewTabPageURL", .{})) |u| return .{ .id = r.id, .url = u };
        }
        return null;
    }

    fn newTabKey(buf: []u8, id: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "extensions.newtab.{s}", .{id}) catch null;
    }

    /// The page an extension asks to show in new tabs, once you said yes
    /// to it; on `gpa`, the caller frees.
    pub fn newTabPage(self: *Extensions, gpa: std.mem.Allocator) ?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const c = self.newTabCandidate() orelse return null;
        var buf: [160]u8 = undefined;
        if (!(self.kea.store.bool(newTabKey(&buf, c.id) orelse return null) orelse false)) return null;
        return gpa.dupe(u8, objc.fromNSString(objc.msg(objc.Object, c.url, "absoluteString", .{}))) catch null;
    }

    pub fn newTabAsked(self: *Extensions, id: []const u8) bool {
        var buf: [160]u8 = undefined;
        return self.kea.store.hasKey(newTabKey(&buf, id) orelse return true);
    }

    pub fn setNewTab(self: *Extensions, id: []const u8, yes: bool) void {
        var buf: [160]u8 = undefined;
        self.kea.store.setBool(newTabKey(&buf, id) orelse return, yes);
    }

    // MARK: the rest, by part (Swift names)

    pub const start = load_ops.start;
    pub const whenStarted = load_ops.whenStarted;
    pub const starting = load_ops.starting;
    /// Asked the first time an extension's page takes the new tab's place.
    pub const offerNewTabPage = install_ops.offerNewTabPage;
    /// Browser.swift:1722: a launch started hidden waits for extensions
    /// still to load before its pages do.
    pub fn holdsLaunch(self: *Extensions) bool {
        return appHidden(self.kea) and load_ops.starting(self);
    }
    pub const revive = load_ops.revive;
    pub const attach = follow_ops.attach;
    pub const detach = follow_ops.detach;
    pub const focused = follow_ops.focused;
    pub const follow = follow_ops.follow;
    pub const installFrom = install_ops.installFrom;
    pub const installId = install_ops.installId;
    pub const installFolder = install_ops.installFolder;
    pub const installFolderAt = install_ops.installFolderAt;
    pub const reload = install_ops.reload;
    pub const remove = forget_ops.remove;
    pub const checkForUpdates = updates_ops.checkForUpdates;
};

pub fn of(kea: *Kea) ?*Extensions {
    return kea.ext;
}

/// The controller with this serial, if it is still the one.
pub fn alive(serial: u64) ?*Extensions {
    const c = current orelse return null;
    return if (c.serial == serial) c else null;
}

pub fn freeRow(gpa: std.mem.Allocator, r: Installed) void {
    gpa.free(r.id);
    gpa.free(r.name);
    gpa.free(r.version);
    for (r.permissions) |p| gpa.free(p);
    gpa.free(r.permissions);
    if (r.source) |s| gpa.free(s);
}

/// `Tab.carriesExtensions`: its view was made with the controller.
pub fn carriesExtensions(tab: *const Tab) bool {
    const c = tab.configuration orelse return false;
    return objc.msg(?objc.Object, c, "webExtensionController", .{}) != null;
}

/// `Extensions.attach(configuration)` (Tab.swift:95-100): every page view
/// built for a tab is handed the controller at birth. A private one only
/// when Settings › Extensions lets private tabs have extensions.
pub fn attachTo(kea: *Kea, configuration: objc.Object, shy: bool) void {
    const self = kea.ext orelse return;
    if (shy and !kea.prefs.extensions_in_private) return;
    objc.msg(void, configuration, "setWebExtensionController:", .{self.controller});
}

/// `Browser.extensionConfiguration(for:)`: the configuration for an
/// extension's page (its context's, a copy, autoreleased), or null for
/// anything else — or no such extension loaded.
pub fn configurationFor(kea: *Kea, url: []const u8) ?objc.Object {
    const self = kea.ext orelse return null;
    if (ext.idOf(url) == null) return null;
    const now = ext.current(self.gpa, url) catch return null;
    defer if (now.ptr != url.ptr) self.gpa.free(now);
    const u = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(now)}) orelse return null;
    const c = objc.msg(?objc.Object, self.controller, "extensionContextForURL:", .{u}) orelse return null;
    return objc.msg(?objc.Object, c, "webViewConfiguration", .{});
}

/// `NSApp.isHidden`: launched hidden (a login item), with no frame to wait for.
pub fn appHidden(kea: *Kea) bool {
    const a = kea.ui_app orelse return false;
    return objc.msg(objc.BOOL, a.nsapp, "isHidden", .{});
}

/// `Browser.extensionName(_:)` (Browser.swift:4718-4722): an installed
/// extension's name for its id, any case; else "An extension".
pub fn extensionName(kea: *Kea, id: []const u8) []const u8 {
    const self = kea.ext orelse return "An extension";
    for (self.installed.items) |r| if (std.ascii.eqlIgnoreCase(r.id, id)) return r.name;
    return "An extension";
}

test "ids set owns its keys" {
    const gpa = std.testing.allocator;
    var s: Ids = .{};
    defer s.deinit(gpa);
    try std.testing.expect(s.put(gpa, "a"));
    try std.testing.expect(!s.put(gpa, "a"));
    try std.testing.expect(s.has("a"));
    s.remove(gpa, "a");
    try std.testing.expect(!s.has("a"));
}
