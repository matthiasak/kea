//! Pages at 120 Hz on a screen that can go that fast (FrameRate.swift,
//! Settings › General, `pages.120`). WebKit holds pages near 60 unless its
//! private feature flag `PreferPageRenderingUpdatesNear60FPSEnabled` is off;
//! that flag is read as a page's view is made. Off, the flag is never
//! touched; switched off, only the preferences this changed get it back.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("../app/kea.zig").Kea;

extern "c" fn IOPSCopyPowerSourcesInfo() ?*const anyopaque;
extern "c" fn IOPSGetProvidingPowerSourceType(snapshot: ?*const anyopaque) ?objc.Object;
extern "c" fn IOPSNotificationCreateRunLoopSource(callback: *const fn (?*anyopaque) callconv(.c) void, context: ?*anyopaque) ?*anyopaque;
extern "c" fn CFRunLoopGetMain() ?*anyopaque;
extern "c" fn CFRunLoopAddSource(rl: ?*anyopaque, source: ?*anyopaque, mode: objc.Object) void;
extern "c" fn CFRelease(cf: *const anyopaque) void;
extern "c" const kCFRunLoopCommonModes: objc.Object;

/// Test override for power-source state (`null` uses IOKit).
pub var power_override: ?bool = null;
var watched_kea: ?*Kea = null;
var power_source: ?*anyopaque = null;

/// The preferences this has taken past 60, weakly (`changed`).
var changed: ?objc.Object = null;
/// The flag, looked up once (`near60`); `missing` where this WebKit has none.
var flag: union(enum) { unknown, missing, found: objc.Object } = .unknown;

pub fn onPower() bool {
    if (power_override) |ov| return ov;
    const blob = IOPSCopyPowerSourcesInfo() orelse return true;
    defer CFRelease(blob);
    const kind = IOPSGetProvidingPowerSourceType(blob) orelse return true;
    return std.mem.eql(u8, objc.fromNSString(kind), "AC Power");
}

pub fn effectiveFast(kea: *const Kea) bool {
    if (!kea.prefs.fast_pages) return false;
    return !kea.prefs.fast_pages_power or onPower();
}

fn watchPower(kea: *Kea) void {
    if (kea.opts.headless) return;
    watched_kea = kea;
    if (power_source != null) return;
    const src = IOPSNotificationCreateRunLoopSource(powerChanged, null) orelse return;
    power_source = src;
    if (CFRunLoopGetMain()) |rl| CFRunLoopAddSource(rl, src, kCFRunLoopCommonModes);
}

fn powerChanged(_: ?*anyopaque) callconv(.c) void {
    if (watched_kea) |k| sync(k);
}

pub fn teardown(kea: *Kea) void {
    if (watched_kea == kea) watched_kea = null;
}
fn near60() ?objc.Object {
    switch (flag) {
        .found => |f| return f,
        .missing => return null,
        .unknown => {},
    }
    flag = .missing;
    const prefs = objc.class("WKPreferences");
    if (!objc.msg(objc.BOOL, prefs, "respondsToSelector:", .{objc.sel("_features")})) return null;
    const all = objc.msg(?objc.Object, prefs, "_features", .{}) orelse return null;
    const n = objc.msg(objc.NSUInteger, all, "count", .{});
    for (0..n) |i| {
        const feature = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
        const key = objc.msg(?objc.Object, feature, "valueForKey:", .{objc.nsString("key")}) orelse continue;
        if (!std.mem.eql(u8, objc.fromNSString(key), "PreferPageRenderingUpdatesNear60FPSEnabled")) continue;
        flag = .{ .found = objc.retain(feature) };
        return flag.found;
    }
    return null;
}

fn set(on: bool, preferences: objc.Object) void {
    const f = near60() orelse return;
    if (!objc.msg(objc.BOOL, preferences, "respondsToSelector:", .{objc.sel("_setEnabled:forFeature:")})) return;
    objc.msg(void, preferences, "_setEnabled:forFeature:", .{ on, f });
}

/// Before a page's view is made, which is when WebKit reads the flag.
pub fn apply(kea: *Kea, preferences: objc.Object) void {
    if (kea.prefs.fast_pages) watchPower(kea);
    if (!effectiveFast(kea) or near60() == null) return;
    set(false, preferences);
    if (changed == null) changed = objc.retain(objc.msg(objc.Object, objc.class("NSHashTable"), "weakObjectsHashTable", .{}));
    objc.msg(void, changed.?, "addObject:", .{preferences});
}

/// Whether a page holds itself near 60, as its WebKit has it; null where
/// this WebKit has no such flag.
pub fn prefersNear60(preferences: objc.Object) ?bool {
    const f = near60() orelse return null;
    if (!objc.msg(objc.BOOL, preferences, "respondsToSelector:", .{objc.sel("_isEnabledForFeature:")})) return null;
    return objc.msg(objc.BOOL, preferences, "_isEnabledForFeature:", .{f});
}

/// `FrameRate.fast`'s `didSet`: told to every open page at once (an open
/// tab is sure to follow only once reloaded); off, only the pages this
/// changed are given WebKit's own rate back.
pub fn sync(kea: *Kea) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (effectiveFast(kea)) {
        watchPower(kea);
        for (kea.browsers.items) |b| {
            for (b.tabs.items) |t| if (t.web) |wv| apply(kea, preferencesOf(wv));
            for (b.parked.values()) |row| for (row.tabs.items) |t| if (t.web) |wv| apply(kea, preferencesOf(wv));
        }
        return;
    }
    const table = changed orelse return;
    const all = objc.msg(objc.Object, table, "allObjects", .{});
    for (0..objc.msg(objc.NSUInteger, all, "count", .{})) |i| set(true, objc.msg(objc.Object, all, "objectAtIndex:", .{i}));
    objc.msg(void, table, "removeAllObjects", .{});
}

pub fn setFast(kea: *Kea, on: bool) void {
    if (kea.prefs.fast_pages == on) return;
    kea.prefs.set("fast_pages", on);
    sync(kea);
}

pub fn setPowerOnly(kea: *Kea, on: bool) void {
    if (kea.prefs.fast_pages_power == on) return;
    kea.prefs.set("fast_pages_power", on);
    sync(kea);
}

fn preferencesOf(wv: objc.Object) objc.Object {
    return objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "preferences", .{});
}
