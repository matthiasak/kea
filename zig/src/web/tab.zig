//! `Tab` (Tab.swift 232-1383): one page view per tab, built the first time
//! it is looked at and let go when the tab sleeps or closes. Its state is
//! heap-owned on `gpa`; KVO (`tab_kvo.zig`), Kea's page scripts and relays
//! (`tab_scripts.zig`), sleeping, zoom and crashes (`tab_state.zig`) are
//! beside it. Headless tabs (`Kea.Options.headless`) never build a view.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const Uuid = @import("../data/json.zig").Uuid;
const json = @import("../data/json.zig");
const Parts = @import("../data/url.zig").Parts;
const favicons = @import("favicons.zig");
const config = @import("config.zig");
const page_view = @import("page_view.zig");
const swipe = @import("swipe.zig");
const kvo = @import("tab_kvo.zig");
const scripts = @import("tab_scripts.zig");
const state = @import("tab_state.zig");
const dialogs = @import("dialogs.zig");
const delegates = @import("delegates_nav.zig");

/// `touched`'s clock: each look a step after the last.
var touches: u64 = 0;

/// Every live tab by `serial`, for answers that arrive after it may have
/// gone (main thread only).
var live: std.AutoHashMapUnmanaged(u64, *Tab) = .empty;
var serials: u64 = 0;

pub const Question = dialogs.Ask;

pub const Tab = struct {
    gpa: std.mem.Allocator,
    id: u64,
    /// Unique for the life of the process (`alive`).
    serial: u64 = 0,
    kea: *Kea,
    /// The window that hears what the tab says (`delegate`, `prepare`).
    browser: ?*Browser = null,

    /// The page (`built`), a `KeaPageView`; null until built, and always
    /// under headless runs.
    web: ?objc.Object = null,
    /// Its navigation, UI and relay handler (`KeaWebDelegate`).
    delegate: ?objc.Object = null,
    /// Its KVO observer (`watch`, `AudioWatch`, the capture states).
    observer: ?objc.Object = null,
    observes_capture: bool = false,
    /// An extension page's UI delegate in front of `delegate` (Tab.swift:266).
    page_delegate: ?objc.Object = null,
    /// What the page view keeps (swipes, keys handed to the page).
    page: ?*page_view.Page = null,
    /// What its next view is made with (`configuration`), retained.
    configuration: ?objc.Object = null,
    /// The app's icons (`Kea.favicons`).
    favicons: ?*favicons.Favicons = null,

    /// Where it is (`address`), and the page actually on screen (`committed`).
    address: ?[]u8 = null,
    committed: ?[]u8 = null,
    page_title: []u8 = &.{},
    /// The page never arrived (`failure`), shown in its place.
    failure: ?[]u8 = null,
    /// Its page is out in the floating window (`floating`, Float.swift).
    floating: bool = false,

    loading: bool = false,
    can_go_back: bool = false,
    can_go_forward: bool = false,
    reading_drawn_at: f64 = 0,
    reading_pending: bool = false,
    muted: bool = false,
    /// Something on the page is making noise (`noisy`, AudioWatch).
    noisy: bool = false,
    /// An extension is recording from this tab's page (RecordingIndicator).
    recording: bool = false,
    /// How far down its page, 0…1 in hundredths (`reading`, keaScroll).
    reading: f32 = 0,
    /// The caret is in something on the page that takes typing.
    typing: bool = false,
    /// `zoom`: how much bigger the page is laid out.
    zoom: f64 = 1,
    mem_mb: f32 = 0,
    mem_at: f64 = 0,
    /// Its process went away out of sight (`stale`).
    stale: bool = false,
    /// When its process went away lately (`crashes`), SwiftDates.
    crashes: std.ArrayList(f64) = .empty,
    /// A window a page opened at a size of its own (`popup`).
    popup: bool = false,
    /// The tab whose page opened this one (`opener`).
    opener: ?u64 = null,
    shy: bool = false,
    /// Reading mode is on (`reader`, Reader.swift).
    reader: bool = false,
    /// The hidden-things stylesheet its next page is armed with (`veils`),
    /// and what was armed last (`armedKey`; 0: nothing yet).
    veils: []u8 = &.{},
    /// The extension whose store page has its own "Add to Kea" in place
    /// (`storePlaced`), so the bottom bar doesn't offer it twice.
    store_placed: ?[]u8 = null,
    armed_key: u64 = 0,

    /// A slept tab's history and scroll (`memory`, retained), its picture
    /// (`picture`, JPEG) and that picture shown while it wakes (`cover`).
    memory: ?objc.Object = null,
    picture: ?[]u8 = null,
    cover: ?[]u8 = null,
    cover_serial: u32 = 0,
    /// A sideways swipe in progress (`pull`), for the disc.
    pull: ?swipe.Pull = null,
    /// A sign-in in flight (`sent`, `named`; Forms), and the page in full screen (`immersed`).
    sign_in: @import("../passwords/forms.zig").SignIn = .{},
    immersed: bool = false,

    /// Questions shown and waiting (the pane card; a hidden run's, answered
    /// with `answerQuestion`), and those held until the tab is in front.
    questions: std.ArrayList(*dialogs.Ask) = .empty,
    held: std.ArrayList(*dialogs.Ask) = .empty,

    /// The title throttle (`prepare`'s 2 s `throttle(latest:)`).
    retitled_at: f64 = -10,
    retitle_due: bool = false,

    /// What makes it a pin (Tab.swift 523-542), all on `gpa`.
    pin: ?[]u8 = null,
    home: ?[]u8 = null,
    pin_id: ?Uuid = null,
    listed: bool = false,
    group_id: ?Uuid = null,
    name: ?[]u8 = null,
    /// What was typed into this blank tab's field and not sent, kept while
    /// another tab is in front; gone once it goes somewhere (`draft`).
    draft: ?[]u8 = null,
    /// When you last looked at it: a step of `touches`, and the time.
    touched: u64 = 0,
    touched_at: f64 = 0,
    /// Brought back and not yet opened, or put down: the address it loads
    /// at when looked at (`wake`).
    pending: ?[]u8 = null,
    /// Its page was made: a web view, or headless, where one would be.
    built: bool = false,
    /// Its space's sign-ins; null for the default.
    data_store: ?objc.Object = null,
    /// Where an extension return comes from (`extensionReturn`, Tab.swift 248).
    ext_return: @import("../ext/return_nav.zig").ReturnNavigation = .{},
    /// An address shown and reported to extensions without loading it, and
    /// the page under it (`held`, `heldOver`; `ext/auth.zig` `hold`).
    held_url: ?[]u8 = null,
    held_over: ?[]u8 = null,

    fn make(gpa: std.mem.Allocator, id: u64, kea: *Kea) !*Tab {
        const self = try gpa.create(Tab);
        serials += 1;
        self.* = .{ .gpa = gpa, .id = id, .kea = kea, .serial = serials };
        // On the process's allocator: the map outlives any one Kea.
        try live.put(std.heap.c_allocator, self.serial, self);
        self.touch();
        return self;
    }

    /// A blank tab; its page is built when it is first needed.
    pub fn create(gpa: std.mem.Allocator, id: u64, shy: bool, data_store: ?objc.Object, kea: *Kea) !*Tab {
        const self = try make(gpa, id, kea);
        self.shy = shy;
        self.data_store = data_store;
        return self;
    }

    /// A page WebKit asked for (`createWebViewWith`): built with the
    /// configuration it hands over, so opener and opened can talk.
    pub fn createWith(gpa: std.mem.Allocator, id: u64, shy: bool, configuration: objc.Object, kea: *Kea) !*Tab {
        const self = try make(gpa, id, kea);
        self.shy = shy;
        self.configuration = objc.retain(configuration);
        self.build();
        return self;
    }

    /// `restore(url:title:name:)`: everything the row needs, nothing fetched.
    pub fn createAsleep(gpa: std.mem.Allocator, id: u64, url_: []const u8, title_: []const u8, name_: ?[]const u8, kea: *Kea) !*Tab {
        const self = try make(gpa, id, kea);
        errdefer self.destroy();
        self.own(&self.address, url_);
        self.setTitle(title_);
        self.setName(name_);
        self.own(&self.pending, url_);
        return self;
    }

    /// The tab with this serial, if it is still alive.
    pub fn alive(serial: u64) ?*Tab {
        return live.get(serial);
    }

    pub fn destroy(self: *Tab) void {
        // Going: its window, perhaps going too, hears nothing more of it.
        self.browser = null;
        dialogs.dropAll(self);
        self.discard();
        _ = live.remove(self.serial);
        for ([_]?[]u8{ self.pin, self.home, self.name, self.pending, self.address, self.committed, self.failure, self.picture, self.cover, self.draft, self.held_url, self.held_over }) |s| if (s) |owned| self.gpa.free(owned);
        self.ext_return.deinit(self.gpa);
        self.gpa.free(self.page_title);
        self.gpa.free(self.veils);
        if (self.store_placed) |s| self.gpa.free(s);
        self.crashes.deinit(self.gpa);
        self.questions.deinit(self.gpa);
        self.held.deinit(self.gpa);
        self.sign_in.deinit(self.gpa);
        if (self.memory) |m| objc.release(m);
        if (self.configuration) |c| objc.release(c);
        self.gpa.destroy(self);
    }

    /// `build()`: the view, its delegate, relays and observers.
    pub fn build(self: *Tab) void {
        if (self.built) return;
        self.built = true;
        if (self.kea.opts.headless) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        if (self.configuration == null) self.configuration = config.configuration(self.kea, self.shy, self.data_store);
        @import("frame_rate.zig").apply(self.kea, objc.msg(objc.Object, self.configuration.?, "preferences", .{}));
        const view = page_view.make(self.configuration.?, self);
        objc.msg(void, view, "setAllowsMagnification:", .{objc.YES});
        objc.msg(void, view, "setAllowsBackForwardNavigationGestures:", .{objc.NO});
        swipe.calm(view);
        if (objc.msg(objc.BOOL, view, "respondsToSelector:", .{objc.sel("setInspectable:")}))
            objc.msg(void, view, "setInspectable:", .{objc.YES});
        config.inspector(objc.msg(objc.Object, objc.msg(objc.Object, view, "configuration", .{}), "preferences", .{}), true);
        const delegate = delegates.makeDelegate(self);
        objc.msg(void, view, "setNavigationDelegate:", .{delegate});
        const capture = @import("../ext/capture.zig");
        objc.msg(void, view, "setUIDelegate:", .{if (self.kea.ext != null) capture.uiDelegate(self.kea, self.configuration.?, delegate, &self.page_delegate) else delegate});
        if (self.kea.ext != null) capture.watchScreen(view);
        self.web = view;
        self.delegate = delegate;
        page_view.holdForFirstFrame(self);
        scripts.install(self);
        if (!self.shy) @import("notifications.zig").provide(self.kea, view);
        // A tab muted before it went to sleep wakes muted.
        if (self.muted) config.setMuted(true, view);
        self.observer = kvo.watch(self, view);
    }

    /// `discard()`: the view and everything listening to it, gone. The
    /// browser takes it off the stage first (`StageHost.forget`).
    pub fn discard(self: *Tab) void {
        self.built = false;
        if (self.observer) |o| kvo.stop(o, self.web, self.observes_capture);
        self.observes_capture = false;
        self.observer = null;
        if (self.web) |wv| {
            // Its page out in the floating window: that window goes first.
            if (self.floating) @import("float.zig").dropped(self);
            const pool = objc.Pool.push();
            defer pool.pop();
            self.kea.passkeys.forget(wv);
            scripts.uninstall(self, wv);
            objc.msg(void, wv, "stopLoading", .{});
            objc.msg(void, wv, "setNavigationDelegate:", .{@as(?objc.Object, null)});
            objc.msg(void, wv, "setUIDelegate:", .{@as(?objc.Object, null)});
            objc.msg(void, wv, "removeFromSuperview", .{});
            page_view.forget(self, wv);
            objc.release(wv);
        }
        if (self.delegate) |d| {
            objc.setZig(d, null);
            objc.release(d);
        }
        if (self.page_delegate) |d| objc.release(d);
        self.page_delegate = null;
        self.web = null;
        self.delegate = null;
        self.loading = false;
        self.noisy = false;
        self.recording = false;
        self.immersed = false;
    }

    // MARK: what the row reads

    /// No address: a new tab.
    pub fn isBlank(self: *const Tab) bool {
        return self.address == null;
    }

    pub fn asleep(self: *const Tab) bool {
        return self.pending != null;
    }

    pub fn touch(self: *Tab) void {
        touches += 1;
        self.touched = touches;
        self.touched_at = json.now();
    }

    pub fn url(self: *const Tab) []const u8 {
        return self.address orelse "";
    }

    /// The page's title, its address until it has one, else "New Tab".
    pub fn title(self: *const Tab) []const u8 {
        if (self.page_title.len > 0) return self.page_title;
        if (self.address) |a| return a;
        return "New Tab";
    }

    /// `label`: your name for it, a popup's site, the title, the address.
    pub fn label(self: *const Tab) []const u8 {
        if (self.name) |n| if (n.len > 0) return n;
        if (self.popup) if (Parts.parse(self.url())) |p| if (p.hostName()) |host| if (host.len > 0)
            return if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
        return self.title();
    }

    /// The letter a pinned tab is reduced to: a file's first letter, or
    /// the host's without its www.; "•" when there is neither.
    pub fn monogram(self: *const Tab, buf: *[4]u8) []const u8 {
        const p = Parts.parse(self.url()) orelse return "•";
        const word = if (p.schemeIs("file")) std.mem.trim(u8, std.fs.path.basename(p.path), "/.") else blk: {
            const host = p.hostName() orelse "";
            break :blk if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
        };
        return @import("../chrome/mark.zig").initialBuf(buf, word);
    }

    /// Replaces an owned optional string with a copy of `s`.
    pub fn own(self: *Tab, field: *?[]u8, s: ?[]const u8) void {
        const copy = if (s) |v| self.gpa.dupe(u8, v) catch return else null;
        if (field.*) |old| self.gpa.free(old);
        field.* = copy;
    }

    pub fn setName(self: *Tab, s: ?[]const u8) void {
        self.own(&self.name, s);
    }

    /// The page's own title (KVO, and `restore`).
    pub fn setTitle(self: *Tab, s: []const u8) void {
        const copy = self.gpa.dupe(u8, s) catch return;
        self.gpa.free(self.page_title);
        self.page_title = copy;
    }

    pub fn setFailure(self: *Tab, s: ?[]const u8) void {
        self.own(&self.failure, s);
    }

    /// Its speaker or its menu: the page plays on, unheard.
    pub fn toggleMute(self: *Tab) void {
        self.muted = !self.muted;
        if (self.web) |wv| config.setMuted(self.muted, wv);
        self.changed(.state);
    }

    pub fn changed(self: *Tab, what: delegates.Change) void {
        if (self.browser) |b| b.tabChanged(self, what);
    }

    // MARK: going places

    /// `go(to:)`: set straight away, so the tab stops being blank in the
    /// frame the field goes; a sleeping tab is simply awake again.
    pub fn go(self: *Tab, target: []const u8) void {
        // From the web into an extension's page or back: another view, swapped
        // in next turn (`onCross` → `Browser.replace`).
        if (self.kea.ext != null and @import("../model/browser_ext.zig").crosses(self, target)) return;
        self.own(&self.address, target);
        self.own(&self.held_url, null);
        self.setTitle("");
        self.setFailure(null);
        self.reading = 0;
        self.reader = false;
        self.typing = false;
        self.own(&self.draft, null);
        self.own(&self.pending, null);
        state.forgetSleep(self);
        self.build();
        if (self.web) |wv| open(wv, target);
        self.changed(.address);
    }

    /// `setAddressOptimistically`: a tab opened by a link is not blank.
    pub fn setAddressOptimistically(self: *Tab, target: []const u8) void {
        self.own(&self.address, target);
        self.setFailure(null);
    }

    /// `forget`: a new tab again — where it went was a file, not a page.
    pub fn forget(self: *Tab) void {
        self.own(&self.address, null);
    }

    pub fn wake(self: *Tab) bool {
        return state.wake(self);
    }

    /// `revive()`: coming back to a tab whose page may have gone white.
    pub fn revive(self: *Tab) void {
        state.revive(self);
    }

    /// ⌘+ / ⌘- (`magnify(by:)`) and ⌘0 (`resetZoom`).
    pub fn magnifyBy(self: *Tab, factor: f64) void {
        state.magnifyBy(self, factor);
    }

    pub fn resetZoom(self: *Tab) void {
        state.resetZoom(self);
    }

    pub fn rest(self: *Tab) void {
        state.rest(self);
    }

    pub fn rehome(self: *Tab, data_store: ?objc.Object) void {
        state.rehome(self, data_store);
    }

    /// `reload(fromOrigin:)`: a pin put down wakes; a view that lost its
    /// document, or a file, is given its address back.
    pub fn reload(self: *Tab, from_origin: bool) void {
        if (self.wake()) return;
        self.setFailure(null);
        self.reader = false;
        self.build();
        const wv = self.web orelse return;
        if (self.address) |a| if (self.hollow() or std.mem.startsWith(u8, a, "file:")) return open(wv, a);
        if (from_origin) _ = objc.msg(?objc.Object, wv, "reloadFromOrigin", .{}) else _ = objc.msg(?objc.Object, wv, "reload", .{});
    }

    /// `stop()`.
    pub fn stopLoading(self: *Tab) void {
        if (self.web) |wv| objc.msg(void, wv, "stopLoading", .{});
    }

    pub fn goBack(self: *Tab) void {
        if (self.web) |wv| _ = objc.msg(?objc.Object, wv, "goBack", .{});
    }

    pub fn goForward(self: *Tab) void {
        if (self.web) |wv| _ = objc.msg(?objc.Object, wv, "goForward", .{});
    }

    /// `hollow`: the view holds nothing while the tab still names a page.
    pub fn hollow(self: *const Tab) bool {
        const wv = self.web orelse return self.address != null;
        const there = currentUrl(wv) orelse return self.address != null;
        return std.mem.eql(u8, there, "about:blank") and self.pending == null and self.address != null;
    }

    /// Answers the question in front — a hidden run's, or the pane card's.
    pub fn answerQuestion(self: *Tab, ok: bool, text: ?[]const u8) void {
        if (self.questions.items.len == 0) return;
        dialogs.answer(self.questions.items[0], ok, text);
    }

    /// The question in front, if any.
    pub fn question(self: *const Tab) ?*dialogs.Ask {
        return if (self.questions.items.len > 0) self.questions.items[0] else null;
    }

    // MARK: running JavaScript

    pub const Then = *const fn (tab: *Tab, value: ?objc.Object, err: ?objc.Object, arg: usize) void;

    const Eval = struct { serial: u64, then: ?Then, arg: usize };
    const EvalBlock = objc.Block(Eval, &.{ ?objc.Object, ?objc.Object });

    fn evaluated(e: *Eval, value: ?objc.Object, err: ?objc.Object) void {
        defer std.heap.c_allocator.destroy(e);
        const then = e.then orelse return;
        if (alive(e.serial)) |t| then(t, value, err, e.arg);
    }

    /// Where JavaScript runs: the page's own world (`evaluateJavaScript`),
    /// Kea's (`evaluateInKea`), or WebKit's default client world.
    pub const World = enum { page, kea, client };

    /// Runs `js`, answered on the main thread while the tab still lives.
    pub fn evaluate(self: *Tab, js: []const u8, in: World, then: ?Then, arg: usize) void {
        const wv = self.web orelse {
            if (then) |f| f(self, null, null, arg);
            return;
        };
        const e = std.heap.c_allocator.create(Eval) catch return;
        e.* = .{ .serial = self.serial, .then = then, .arg = arg };
        const pool = objc.Pool.push();
        defer pool.pop();
        var block = EvalBlock.init(e, evaluated);
        const world = switch (in) {
            .page => config.pageWorld(),
            .kea => config.world(),
            .client => objc.msg(objc.Object, objc.class("WKContentWorld"), "defaultClientWorld", .{}),
        };
        objc.msg(void, wv, "evaluateJavaScript:inFrame:inContentWorld:completionHandler:", .{ objc.nsString(js), @as(?objc.Object, null), world, @as(*anyopaque, @ptrCast(&block)) });
    }

    const Later = struct { serial: u64, then: *const fn (*Tab, usize) void, arg: usize, drop: ?*const fn (usize) void = null };

    fn fired(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Later = @ptrCast(@alignCast(ctx orelse return));
        defer std.heap.c_allocator.destroy(l);
        if (alive(l.serial)) |t| l.then(t, l.arg) else if (l.drop) |d| d(l.arg);
    }

    /// `then(tab, arg)` after `seconds`, if the tab is still alive.
    pub fn after(self: *Tab, seconds: f64, then: *const fn (*Tab, usize) void, arg: usize) void {
        self.afterOwned(seconds, then, arg, null);
    }

    /// `after`, with `drop(arg)` run instead when the tab died first, so an
    /// `arg` that owns memory is freed either way.
    pub fn afterOwned(self: *Tab, seconds: f64, then: *const fn (*Tab, usize) void, arg: usize, drop: ?*const fn (usize) void) void {
        const l = std.heap.c_allocator.create(Later) catch return if (drop) |d| d(arg);
        l.* = .{ .serial = self.serial, .then = then, .arg = arg, .drop = drop };
        objc.dispatchAfter(@intFromFloat(seconds * std.time.ns_per_s), l, fired);
    }
};

/// The view's address as WebKit has it, borrowed for the pool's life.
pub fn currentUrl(wv: objc.Object) ?[]const u8 {
    const u = objc.msg(?objc.Object, wv, "URL", .{}) orelse return null;
    return objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
}

/// `WKWebView.open`: an address, or a file with the folder it may read —
/// unless that folder is home, the disk or a volume.
pub fn open(wv: objc.Object, target: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(target)}) orelse return;
    if (objc.msg(objc.BOOL, nsurl, "isFileURL", .{})) {
        const folder = objc.msg(objc.Object, objc.msg(objc.Object, nsurl, "URLByDeletingLastPathComponent", .{}), "URLByStandardizingPath", .{});
        const path = objc.fromNSString(objc.msg(?objc.Object, folder, "path", .{}));
        const home = objc.fromNSString(objc.msg(?objc.Object, objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{}), "homeDirectoryForCurrentUser", .{}), "path", .{}));
        const parent = std.fs.path.dirname(path) orelse "";
        const too_wide = std.mem.eql(u8, path, home) or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/Users") or
            std.mem.eql(u8, path, "/Volumes") or std.mem.eql(u8, parent, "/Volumes");
        _ = objc.msg(?objc.Object, wv, "loadFileURL:allowingReadAccessToURL:", .{ nsurl, if (too_wide) nsurl else folder });
        return;
    }
    const req = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl});
    _ = objc.msg(?objc.Object, wv, "loadRequest:", .{req});
}
