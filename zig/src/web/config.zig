//! `Web` (Tab.swift 15-144): Kea's content world, the user agent, the shared
//! process pool and every tab's configuration; `Muter` (152-165), `Autoplay`
//! (180-205) and `Store.followSignIns` (Store.swift 74-79).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("../app/kea.zig").Kea;
const Store = @import("../data/store.zig").Store;

/// `Web.world`: where Kea's page scripts run, apart from the page's own.
pub fn world() objc.Object {
    return objc.msg(objc.Object, objc.class("WKContentWorld"), "worldWithName:", .{objc.nsString("Kea")});
}

pub fn pageWorld() objc.Object {
    return objc.msg(objc.Object, objc.class("WKContentWorld"), "pageWorld", .{});
}

/// Every relay name Kea registers (`Web.release`).
pub const relay_names = [_][]const u8{ "keaScroll", "keaVeil", "keaForms", "keaImages", "keaStore", "keaPasskeys", "keaMiddle", "keaIcon" };
/// `HoveredLink.name`, in Kea's world only.
pub const link_relay = "link";

/// `Web.release`: every handler of Kea's off a controller, in both worlds
/// — registering a name twice is a hard crash.
pub fn release(ucc: objc.Object) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    for (relay_names) |name| {
        objc.msg(void, ucc, "removeScriptMessageHandlerForName:contentWorld:", .{ objc.nsString(name), world() });
        objc.msg(void, ucc, "removeScriptMessageHandlerForName:contentWorld:", .{ objc.nsString(name), pageWorld() });
    }
    objc.msg(void, ucc, "removeScriptMessageHandlerForName:contentWorld:", .{ objc.nsString(link_relay), world() });
}

var agent_buf: [96]u8 = undefined;
var agent: ?[]const u8 = null;

/// `Web.userAgentName`: the Safari this Mac has.
pub fn userAgentName() []const u8 {
    if (agent) |a| return a;
    const version = safariVersion();
    agent = std.fmt.bufPrint(&agent_buf, "Version/{s} Safari/605.1.15", .{version}) catch "Version/26.0 Safari/605.1.15";
    return agent.?;
}

var version_buf: [32]u8 = undefined;

fn safariVersion() []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    for ([_][]const u8{ "/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app" }) |path| {
        const bundle = objc.msg(?objc.Object, objc.class("NSBundle"), "bundleWithPath:", .{objc.nsString(path)}) orelse continue;
        const info = objc.msg(?objc.Object, bundle, "infoDictionary", .{}) orelse continue;
        const v = objc.fromNSString(objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("CFBundleShortVersionString")}));
        if (v.len == 0 or v.len > version_buf.len) continue;
        @memcpy(version_buf[0..v.len], v);
        return version_buf[0..v.len];
    }
    // From macOS 26 Safari shares its number; before, it was 3 ahead.
    const os = objc.msg(OsVersion, objc.msg(objc.Object, objc.class("NSProcessInfo"), "processInfo", .{}), "operatingSystemVersion", .{}).major;
    return std.fmt.bufPrint(&version_buf, "{d}.0", .{if (os >= 26) os else os + 3}) catch "26.0";
}

const OsVersion = extern struct { major: objc.NSInteger, minor: objc.NSInteger, patch: objc.NSInteger };

var shared_pool: ?objc.Object = null;

/// `Web.pool`: one process pool for every tab, so the next process is warm.
pub fn processPool() objc.Object {
    if (shared_pool) |p| return p;
    shared_pool = objc.new("WKProcessPool");
    return shared_pool.?;
}

/// `Web.playback`: sound waits for a click; video too with
/// Settings › Videos wait for a click (`media.click`).
pub fn playback(store: *const Store) objc.NSUInteger {
    // WKAudiovisualMediaTypeAudio = 1, All = ~0.
    return if (store.bool("media.click") orelse false) std.math.maxInt(objc.NSUInteger) else 1;
}

/// `Web.configuration(shy:space:store:)`, retained (+1). `data_store`: the
/// space's own store, null for the default. Private tabs, and every tab
/// under tests (`opts.root`), get a store that keeps nothing.
pub fn configuration(kea: *Kea, shy: bool, data_store: ?objc.Object) objc.Object {
    const pool = objc.Pool.push();
    defer pool.pop();
    const config = objc.new("WKWebViewConfiguration");
    const cls = objc.class("WKWebsiteDataStore");
    const store = if (shy or kea.opts.root != null)
        objc.msg(objc.Object, cls, "nonPersistentDataStore", .{})
    else
        data_store orelse objc.msg(objc.Object, cls, "defaultDataStore", .{});
    if (!shy and kea.opts.root == null) followSignIns(store, kea.prefs.keeps_sign_ins);
    objc.msg(void, config, "setWebsiteDataStore:", .{store});
    // Its sites' notifications (Notifications.swift); a private tab's none.
    if (!shy) @import("notifications.zig").attach(kea, store);
    objc.msg(void, config, "setProcessPool:", .{processPool()});
    if (kea.opts.scheme_handler) |h| objc.msg(void, config, "setURLSchemeHandler:forURLScheme:", .{ h, objc.nsString("kea-test") });
    objc.msg(void, config, "setApplicationNameForUserAgent:", .{objc.nsString(userAgentName())});
    objc.msg(void, config, "setAllowsAirPlayForMediaPlayback:", .{objc.YES});
    const prefs = objc.msg(objc.Object, config, "preferences", .{});
    objc.msg(void, prefs, "setElementFullscreenEnabled:", .{objc.YES});
    objc.msg(void, prefs, "setJavaScriptCanOpenWindowsAutomatically:", .{objc.NO});
    objc.msg(void, config, "setMediaTypesRequiringUserActionForPlayback:", .{playback(&kea.store)});
    // A test run's hidden pages keep running (WKInactiveSchedulingPolicyNone).
    if (kea.opts.root != null and objc.msg(objc.BOOL, prefs, "respondsToSelector:", .{objc.sel("setInactiveSchedulingPolicy:")}))
        objc.msg(void, prefs, "setInactiveSchedulingPolicy:", .{@as(objc.NSInteger, 2)});
    // A test run's pretend camera and microphone (see ext/capture_watch.zig).
    if (kea.ext != null) @import("../ext/capture.zig").mockDevices(kea, prefs);
    // Chrome extensions see every page but a private one, unless Settings ›
    // Extensions says they may; the controller can't be added later.
    @import("../ext/controller.zig").attachTo(kea, config, shy);
    inspector(prefs, true);
    return config;
}

/// `Store.followSignIns`: tracking prevention off only once Settings says
/// to keep sign-ins; until then its flag is not touched.
fn followSignIns(store: objc.Object, keeps: bool) void {
    if (!keeps) return;
    if (!objc.msg(objc.BOOL, store, "respondsToSelector:", .{objc.sel("_setResourceLoadStatisticsEnabled:")})) return;
    objc.msg(void, store, "_setResourceLoadStatisticsEnabled:", .{objc.NO});
}

/// `Web.inspector`: WebKit's developer extras, asked for first.
pub fn inspector(prefs: objc.Object, on: bool) void {
    if (!objc.msg(objc.BOOL, prefs, "respondsToSelector:", .{objc.sel("_setDeveloperExtrasEnabled:")})) return;
    objc.msg(void, prefs, "_setDeveloperExtrasEnabled:", .{on});
}

/// `Muter.set`: the low bit of `_mediaMutedState`, the page's own sound.
pub fn setMuted(muted: bool, web: objc.Object) void {
    if (!objc.msg(objc.BOOL, web, "respondsToSelector:", .{objc.sel("_mediaMutedState")})) return;
    if (!objc.msg(objc.BOOL, web, "respondsToSelector:", .{objc.sel("_setPageMuted:")})) return;
    const state = objc.msg(objc.NSUInteger, web, "_mediaMutedState", .{});
    objc.msg(void, web, "_setPageMuted:", .{if (muted) state | 1 else state & ~@as(objc.NSUInteger, 1)});
}

// MARK: Autoplay

fn autoplayKey(buf: []u8, host: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "autoplay.{s}", .{host}) catch null;
}

pub fn autoplayAllowed(store: *const Store, host: []const u8) bool {
    var buf: [300]u8 = undefined;
    return store.bool(autoplayKey(&buf, host) orelse return false) orelse false;
}

/// Off keeps nothing, as a site at the usual zoom keeps nothing.
pub fn setAutoplay(store: *const Store, on: bool, host: []const u8) void {
    var buf: [300]u8 = undefined;
    const key = autoplayKey(&buf, host) orelse return;
    if (on) store.setBool(key, true) else store.remove(key);
}

/// `Autoplay.apply`: a page about to load at `host` allowed to play.
pub fn applyAutoplay(store: *const Store, preferences: objc.Object, host: []const u8, shy: bool) void {
    if (shy or host.len == 0 or !autoplayAllowed(store, host) or (store.bool("media.click") orelse false)) return;
    if (!objc.msg(objc.BOOL, preferences, "respondsToSelector:", .{objc.sel("_setAutoplayPolicy:")})) return;
    objc.msg(void, preferences, "_setAutoplayPolicy:", .{@as(objc.NSInteger, 1)});
}
