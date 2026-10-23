//! What is recording (ExtensionCapture.swift "what is recording", "test
//! runs", `ExtensionPageDelegate`): pages of extensions that asked to
//! capture, and every tab sharing its screen, watched by KVO for as long as
//! they last; the recordings in words; the mark on each recording tab
//! (RecordingIndicator.update); Stop; WebKit's pretend devices under tests.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("../app/kea.zig").Kea;
const site_card = @import("../chrome/site_card.zig");
const capture = @import("capture.zig");

extern "c" fn objc_initWeak(location: *?objc.Object, obj: ?objc.Object) ?objc.Object;
extern "c" fn objc_loadWeakRetained(location: *?objc.Object) ?objc.Object;
extern "c" fn objc_destroyWeak(location: *?objc.Object) void;

const gpa = std.heap.c_allocator;

/// A view held weakly: WebKit's views let their observers go with them.
pub const Weak = struct {
    slot: ?objc.Object = null,

    pub fn make(web: objc.Object) !*Weak {
        const w = try gpa.create(Weak);
        w.* = .{};
        _ = objc_initWeak(&w.slot, web);
        return w;
    }

    /// The view if it still lives, autoreleased.
    pub fn get(self: *Weak) ?objc.Object {
        const o = objc_loadWeakRetained(&self.slot) orelse return null;
        objc.autorelease(o);
        return o;
    }

    pub fn drop(self: *Weak) void {
        objc_destroyWeak(&self.slot);
        gpa.destroy(self);
    }
};

const Watched = struct {
    web: *Weak,
    /// The extension that asked; null for a tab watched only for sharing
    /// its screen, which the pill names by its site.
    extension_id: ?[]u8,
    capturing: bool = false,

    /// `id`: the extension's, or "site:<host>"; on `buf`.
    fn id(self: *const Watched, web: objc.Object, buf: []u8) []const u8 {
        if (self.extension_id) |e| return e;
        const u = objc.msg(?objc.Object, web, "URL", .{});
        const h = if (u) |x| objc.fromNSString(objc.msg(?objc.Object, x, "host", .{})) else "";
        return std.fmt.bufPrint(buf, "site:{s}", .{h}) catch "site:";
    }

    /// What counts: everything an extension captures; for a site, only its
    /// screen — its camera and microphone have their own marks.
    fn live(self: *const Watched, web: objc.Object) bool {
        return if (self.extension_id == null) screen(web) else capturing(web);
    }
};

/// One extension's captures, in words.
pub const Recording = struct {
    id: []u8,
    name: []u8,
    /// A website sharing its screen, rather than an extension.
    site: bool,
    screen: bool,
    camera: bool,
    microphone: bool,

    pub fn what(self: Recording) []const u8 {
        if (self.site) return "is sharing your screen";
        if (self.screen) return "is recording your screen";
        if (self.camera and self.microphone) return "is using your camera and microphone";
        return if (self.camera) "is using your camera" else "is using your microphone";
    }

    fn eql(a: Recording, b: Recording) bool {
        return std.mem.eql(u8, a.id, b.id) and std.mem.eql(u8, a.name, b.name) and a.site == b.site and
            a.screen == b.screen and a.camera == b.camera and a.microphone == b.microphone;
    }

    fn free(self: Recording) void {
        gpa.free(self.id);
        gpa.free(self.name);
    }
};

var watched: std.AutoArrayHashMapUnmanaged(usize, Watched) = .empty;
/// `recordings`: what the pill says, sorted by name. The UI wave draws it.
pub var recordings: std.ArrayList(Recording) = .empty;
/// Bumped whenever `recordings` changes (the pill redraws).
pub var generation: u64 = 0;
/// `RecordingIndicator.update`: the pill settles (web/recording_pill.zig).
pub var on_change: ?*const fn () void = null;

const keys = [_][:0]const u8{ "cameraCaptureState", "microphoneCaptureState", "_displayCaptureState" };

fn responds(o: objc.Object, comptime sel: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "respondsToSelector:", .{objc.sel(sel)});
}

/// `screen(_:)`: the page shares the screen.
pub fn screen(web: objc.Object) bool {
    if (!responds(web, "_displayCaptureState")) return false;
    return objc.msg(objc.NSInteger, web, "_displayCaptureState", .{}) != 0;
}

/// `capturing(_:)`: the page records anything, for Sleep.
pub fn capturing(web: objc.Object) bool {
    return screen(web) or camera(web) or microphone(web);
}

fn camera(web: objc.Object) bool {
    return objc.msg(objc.NSInteger, web, "cameraCaptureState", .{}) != 0;
}

fn microphone(web: objc.Object) bool {
    return objc.msg(objc.NSInteger, web, "microphoneCaptureState", .{}) != 0;
}

/// `watchCapture(_:frame:)`: every camera or microphone question passes
/// here; one from an extension — its page, or its frame in a site — is
/// watched.
pub fn watchCapture(web: objc.Object, frame: objc.Object) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const asker = objc.msg(objc.Object, frame, "securityOrigin", .{});
    const scheme = objc.fromNSString(objc.msg(?objc.Object, asker, "protocol", .{}));
    const extension = std.ascii.eqlIgnoreCase(scheme, "chrome-extension") or std.ascii.eqlIgnoreCase(scheme, "webkit-extension");
    const id = if (extension)
        objc.fromNSString(objc.msg(?objc.Object, asker, "host", .{}))
    else if (objc.msg(?objc.Object, web, "URL", .{})) |u|
        @import("ext.zig").idOf(objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}))) orelse ""
    else
        "";
    if (id.len == 0) return;
    register(web, id);
}

/// `watchScreen(_:)`: every tab — a site sharing its screen puts up the pill
/// too.
pub fn watchScreen(web: objc.Object) void {
    if (!responds(web, "_displayCaptureState")) return;
    register(web, null);
}

/// `watch(_:id:)`.
pub fn watch(web: objc.Object, id: []const u8) void {
    register(web, id);
}

fn register(web: objc.Object, id: ?[]const u8) void {
    const key = @intFromPtr(web);
    if (watched.getPtr(key)) |entry| {
        if (entry.web.get() == web) {
            if (entry.extension_id == null) if (id) |i| {
                entry.extension_id = gpa.dupe(u8, i) catch null;
            };
            return changed();
        }
        // A view gone, its address reused by a new one.
        forgetEntry(entry.*);
        _ = watched.swapRemove(key);
    }
    const w = Weak.make(web) catch return;
    const own: ?[]u8 = if (id) |i| gpa.dupe(u8, i) catch null else null;
    watched.put(gpa, key, .{ .web = w, .extension_id = own }) catch {
        w.drop();
        if (own) |o| gpa.free(o);
        return;
    };
    const pool = objc.Pool.push();
    defer pool.pop();
    const observer = capture.instance();
    for (keys) |k| {
        if (std.mem.eql(u8, k, "_displayCaptureState") and !responds(web, "_displayCaptureState")) continue;
        objc.msg(void, web, "addObserver:forKeyPath:options:context:", .{ observer, objc.nsString(k), @as(objc.NSUInteger, 0), @as(?*anyopaque, null) });
    }
    changed();
}

fn forgetEntry(e: Watched) void {
    e.web.drop();
    if (e.extension_id) |i| gpa.free(i);
}

pub fn unwatch(web: objc.Object) void {
    const key = @intFromPtr(web);
    const kv = watched.fetchSwapRemove(key) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (kv.value.web.get() == web) {
        const observer = capture.instance();
        for (keys) |k| {
            if (std.mem.eql(u8, k, "_displayCaptureState") and !responds(web, "_displayCaptureState")) continue;
            objc.msg(void, web, "removeObserver:forKeyPath:", .{ observer, objc.nsString(k) });
        }
    }
    forgetEntry(kv.value);
    if (kv.value.capturing) changed();
}

/// KVO fires off the main thread too: the change is looked at on it.
pub fn observed() void {
    objc.dispatchMain(null, struct {
        fn f(_: ?*anyopaque) callconv(.c) void {
            changed();
        }
    }.f);
}

/// `changed()`: the recordings again, and the marks on tabs.
pub fn changed() void {
    const pool = objc.Pool.push();
    defer pool.pop();
    var now: std.ArrayList(Recording) = .empty;
    var i: usize = 0;
    while (i < watched.count()) {
        const entry = &watched.values()[i];
        const web = entry.web.get() orelse {
            forgetEntry(entry.*);
            watched.swapRemoveAt(i);
            continue;
        };
        i += 1;
        const live = entry.live(web);
        // Stopped: an offscreen page lent to the pill goes back.
        if (entry.capturing and !live) giveBack(web);
        entry.capturing = live;
        if (!live) continue;
        var buf: [300]u8 = undefined;
        const id = entry.id(web, &buf);
        const site = entry.extension_id == null;
        const found = for (now.items) |*r| {
            if (std.mem.eql(u8, r.id, id)) break r;
        } else null;
        if (found) |r| {
            r.screen = r.screen or screen(web);
            r.camera = r.camera or camera(web);
            r.microphone = r.microphone or microphone(web);
            continue;
        }
        const name = if (site) blk: {
            const u = objc.msg(?objc.Object, web, "URL", .{});
            break :blk if (u) |x| site_card.site(objc.fromNSString(objc.msg(?objc.Object, x, "absoluteString", .{}))) else "A page";
        } else if (capture.kea()) |k| @import("controller.zig").extensionName(k, id) else "An extension";
        const r: Recording = .{
            .id = gpa.dupe(u8, id) catch continue,
            .name = gpa.dupe(u8, name) catch continue,
            .site = site,
            .screen = screen(web),
            .camera = camera(web),
            .microphone = microphone(web),
        };
        now.append(gpa, r) catch r.free();
    }
    std.mem.sort(Recording, now.items, {}, struct {
        fn lt(_: void, a: Recording, b: Recording) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    const same = now.items.len == recordings.items.len and for (now.items, recordings.items) |a, b| {
        if (!a.eql(b)) break false;
    } else true;
    if (same) {
        for (now.items) |r| r.free();
        now.deinit(gpa);
        return;
    }
    for (recordings.items) |r| r.free();
    recordings.deinit(gpa);
    recordings = now;
    generation +%= 1;
    marks();
    if (on_change) |f| f();
}

/// `RecordingIndicator.update(_:pages:)`: a tab whose page is capturing for
/// one of the recordings wears a mark in the row.
fn marks() void {
    const kea = capture.kea() orelse return;
    for (kea.browsers.items) |b| for (b.tabs.items) |t| {
        const now = if (t.web) |w| marked(w) else false;
        if (t.recording != now) {
            t.recording = now;
            t.changed(.state);
        }
    };
}

fn marked(web: objc.Object) bool {
    const e = watched.get(@intFromPtr(web)) orelse return false;
    if (!e.capturing) return false;
    var buf: [300]u8 = undefined;
    const id = e.id(web, &buf);
    for (recordings.items) |r| if (std.mem.eql(u8, r.id, id)) return true;
    return false;
}

/// `webViews(of:)`: the pages of an extension that are capturing now
/// (autoreleased views), on `out`.
pub fn webViews(id: []const u8, out: *std.ArrayList(objc.Object), alloc: std.mem.Allocator) !void {
    for (watched.values()) |*e| {
        const web = e.web.get() orelse continue;
        var buf: [300]u8 = undefined;
        if (std.mem.eql(u8, e.id(web, &buf), id) and e.live(web)) try out.append(alloc, web);
    }
}

/// How many watched pages still live, for the bench.
pub fn watching() usize {
    var n: usize = 0;
    for (watched.values()) |*e| {
        if (e.web.get() != null) n += 1;
    }
    return n;
}

/// `stop(_:)`: everything the extension captures ends; for a site, its
/// screen only.
pub fn stop(id: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    for (watched.values()) |*e| {
        const web = e.web.get() orelse continue;
        var buf: [300]u8 = undefined;
        if (!std.mem.eql(u8, e.id(web, &buf), id)) continue;
        if (responds(web, "_setDisplayCaptureState:completionHandler:"))
            objc.msg(void, web, "_setDisplayCaptureState:completionHandler:", .{ @as(objc.NSInteger, 0), @as(?*anyopaque, null) });
        // A site's Stop ends only its screen: the call it is on goes on.
        if (e.extension_id == null) continue;
        objc.msg(void, web, "setCameraCaptureState:completionHandler:", .{ @as(objc.NSInteger, 0), @as(?*anyopaque, null) });
        objc.msg(void, web, "setMicrophoneCaptureState:completionHandler:", .{ @as(objc.NSInteger, 0), @as(?*anyopaque, null) });
    }
}

// MARK: lending an offscreen page to the pill

/// Offscreen pages lent to the pill, until their recording ends. The pill
/// (UI wave, RecordingIndicator.swift:64-80) moves them into its panel via
/// `pill`.
pub var lent: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
/// How many times a page was lent, for the bench.
pub var lendings: u64 = 0;
/// `RecordingIndicator.host/release`, set by the pill.
pub var pill: ?*const fn (web: objc.Object, lend: bool) void = null;

/// Lent for a request that may never start: given back if nothing is
/// recording in it half a minute on.
pub fn lendAwhile(web: objc.Object) void {
    if (lent.contains(@intFromPtr(web))) return;
    host(web);
    const w = Weak.make(web) catch return;
    objc.dispatchAfter(30 * std.time.ns_per_s, w, struct {
        fn f(ctx: ?*anyopaque) callconv(.c) void {
            const weak: *Weak = @ptrCast(@alignCast(ctx.?));
            defer weak.drop();
            const pool = objc.Pool.push();
            defer pool.pop();
            const v = weak.get() orelse return;
            if (!capturing(v)) giveBack(v);
        }
    }.f);
}

pub fn host(web: objc.Object) void {
    lent.put(gpa, @intFromPtr(web), {}) catch {};
    lendings += 1;
    if (pill) |p| p(web, true);
}

/// `bringForward(_:)`: WebKit won't start a recording in a page that isn't
/// on screen. The caller skips it in a test run.
pub fn bringForward(k: *Kea, web: objc.Object) void {
    for (k.browsers.items) |b| for (b.tabs.items) |t| {
        if (t.web != web) continue;
        b.select(t);
        @import("../app/browsers.zig").show(b);
        return;
    };
}

/// `giveBack(_:)`.
pub fn giveBack(web: objc.Object) void {
    if (!lent.swapRemove(@intFromPtr(web))) return;
    if (pill) |p| p(web, false);
}

// MARK: test runs

/// `mockDevices(_:)`: WebKit's pretend camera, microphone and screen, so a
/// test run records with no hardware and no macOS question. Never outside
/// a test run. WebKit's own pretend prompt stays.
pub fn mockDevices(k: *Kea, prefs: objc.Object) void {
    if (k.opts.root == null) return;
    set("_setMockCaptureDevicesEnabled:", true, prefs);
    set("_setGetUserMediaRequiresFocus:", false, prefs);
}

/// `set(_:_:in:)`: one of WebKit's preferences it doesn't make public, if
/// it has it.
pub fn set(name: [:0]const u8, on: bool, prefs: objc.Object) void {
    if (!objc.msg(objc.BOOL, prefs, "respondsToSelector:", .{objc.sel(name)})) return;
    objc.msg(void, prefs, name, .{on});
}

// MARK: ExtensionPageDelegate

/// The UI delegate of a tab showing one of an extension's pages: WebKit's
/// question about recording the screen is answered here — yes only while
/// Kea's own call is under way in that page; everything else goes on to the
/// tab's own delegate (`next`, unretained: the tab holds it). Web tabs don't
/// get one, and keep WebKit's own way: the Mac's picker.
fn pageClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaExtensionPageDelegate",
        .protocols = &.{"WKUIDelegate"},
        .methods = &.{
            .{ .name = "respondsToSelector:", .imp = &pageResponds, .types = "B@::" },
            .{ .name = "forwardingTargetForSelector:", .imp = &pageForward, .types = "@@::" },
            .{ .name = capture.display_selector, .imp = &capture.displayCapture, .types = "v@:@@@B@?" },
        },
    });
}

fn pageResponds(self: objc.Object, _: objc.SEL, sel: objc.SEL) callconv(.c) objc.BOOL {
    if (objc.msgSuper(objc.BOOL, self, objc.class("NSObject"), "respondsToSelector:", .{sel})) return objc.YES;
    const next = objc.getZig(anyopaque, self) orelse return objc.NO;
    return objc.msg(objc.BOOL, @as(objc.Object, @ptrCast(next)), "respondsToSelector:", .{sel});
}

fn pageForward(self: objc.Object, _: objc.SEL, _: objc.SEL) callconv(.c) ?objc.Object {
    const next = objc.getZig(anyopaque, self) orelse return null;
    return @ptrCast(next);
}

/// `Tab.uiDelegate(_:)` (Tab.swift:268-275): `delegate` itself, or — for a
/// view of the extension pages' content controller — a page delegate in
/// front of it, kept in `held` (retained; the tab releases it).
pub fn uiDelegate(k: *Kea, configuration: objc.Object, delegate: objc.Object, held: *?objc.Object) objc.Object {
    const owner = k.ext orelse return delegate;
    const pages = owner.pages orelse return delegate;
    if (objc.msg(?objc.Object, configuration, "userContentController", .{}) != pages) return delegate;
    const made = held.* orelse objc.msg(objc.Object, pageClass(), "new", .{});
    held.* = made;
    objc.setZig(made, @ptrCast(delegate));
    return made;
}

test "a recording says what it does" {
    var id = "x".*;
    var name = "Loom".*;
    var r: Recording = .{ .id = &id, .name = &name, .site = false, .screen = false, .camera = true, .microphone = true };
    try std.testing.expectEqualStrings("is using your camera and microphone", r.what());
    r.camera = false;
    try std.testing.expectEqualStrings("is using your microphone", r.what());
    r.screen = true;
    try std.testing.expectEqualStrings("is recording your screen", r.what());
    r.site = true;
    try std.testing.expectEqualStrings("is sharing your screen", r.what());
}
