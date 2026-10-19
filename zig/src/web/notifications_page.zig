//! A page's own notifications (Notifications.swift `PageNotifications`):
//! `new Notification(…)` without a service worker reaches the app only
//! through WebKit's C notification provider, a table of callbacks set on
//! the process pool's notification manager. Its functions are exported but
//! declared nowhere, so each is looked up by name; if one is missing no
//! provider is set and a page's notification is shown nowhere.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const notifications = @import("notifications.zig");

const Ref = *anyopaque;
const gpa = std.heap.c_allocator;

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

/// WebKit's C functions, each looked up by name (`WebKitC`).
const C = struct {
    pageContext: *const fn (Ref) callconv(.c) ?Ref,
    manager: *const fn (Ref) callconv(.c) ?Ref,
    setProvider: *const fn (Ref, *const anyopaque) callconv(.c) void,
    title: *const fn (Ref) callconv(.c) ?Ref,
    body: *const fn (Ref) callconv(.c) ?Ref,
    tag: *const fn (Ref) callconv(.c) ?Ref,
    id: *const fn (Ref) callconv(.c) u64,
    origin: *const fn (Ref) callconv(.c) ?Ref,
    originString: *const fn (Ref) callconv(.c) ?Ref,
    cfString: *const fn (?*anyopaque, Ref) callconv(.c) ?objc.Object,
    didShow: *const fn (Ref, u64) callconv(.c) void,
    didClick: *const fn (Ref, u64) callconv(.c) void,
    didClose: *const fn (Ref, Ref) callconv(.c) void,
    uint64: *const fn (u64) callconv(.c) ?Ref,
    uint64Value: *const fn (Ref) callconv(.c) u64,
    array: *const fn ([*]const ?Ref, usize) callconv(.c) ?Ref,
    arraySize: *const fn (Ref) callconv(.c) usize,
    arrayItem: *const fn (Ref, usize) callconv(.c) ?Ref,
    dictionary: *const fn () callconv(.c) ?Ref,
    setItem: *const fn (Ref, Ref, Ref) callconv(.c) bool,
    boolean: *const fn (bool) callconv(.c) ?Ref,
    string: *const fn (objc.Object) callconv(.c) ?Ref,
    release: *const fn (Ref) callconv(.c) void,
    /// Optional: a service worker's, which the store's delegate posts, is left alone.
    persistent: ?*const fn (Ref) callconv(.c) bool,

    const names = .{
        .{ "pageContext", "WKPageGetContext" },                                    .{ "manager", "WKContextGetNotificationManager" },
        .{ "setProvider", "WKNotificationManagerSetProvider" },                    .{ "title", "WKNotificationCopyTitle" },
        .{ "body", "WKNotificationCopyBody" },                                     .{ "tag", "WKNotificationCopyTag" },
        .{ "id", "WKNotificationGetID" },                                          .{ "origin", "WKNotificationGetSecurityOrigin" },
        .{ "originString", "WKSecurityOriginCopyToString" },                       .{ "cfString", "WKStringCopyCFString" },
        .{ "didShow", "WKNotificationManagerProviderDidShowNotification" },        .{ "didClick", "WKNotificationManagerProviderDidClickNotification" },
        .{ "didClose", "WKNotificationManagerProviderDidCloseNotifications" },     .{ "uint64", "WKUInt64Create" },
        .{ "uint64Value", "WKUInt64GetValue" },                                    .{ "array", "WKArrayCreate" },
        .{ "arraySize", "WKArrayGetSize" },                                        .{ "arrayItem", "WKArrayGetItemAtIndex" },
        .{ "dictionary", "WKMutableDictionaryCreate" },                            .{ "setItem", "WKDictionarySetItem" },
        .{ "boolean", "WKBooleanCreate" },                                         .{ "string", "WKStringCreateWithCFString" },
        .{ "release", "WKRelease" },
    };

    /// A WKString copied out (on `gpa`), the copy let go.
    fn text(c: *const C, copied: ?Ref) []u8 {
        const s = copied orelse return &.{};
        defer c.release(s);
        const cf = c.cfString(null, s) orelse return &.{};
        defer objc.release(cf);
        return gpa.dupe(u8, objc.fromNSString(cf)) catch &.{};
    }
};

var loaded: union(enum) { unknown, missing, found: C } = .unknown;

fn webkit() ?*const C {
    switch (loaded) {
        .found => return &loaded.found,
        .missing => return null,
        .unknown => {},
    }
    loaded = .missing;
    // RTLD_NOW
    const lib = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", 2) orelse return null;
    var c: C = undefined;
    inline for (C.names) |pair| {
        const f = dlsym(lib, pair[1]) orelse return null;
        @field(c, pair[0]) = @ptrCast(@alignCast(f));
    }
    c.persistent = if (dlsym(lib, "WKNotificationGetIsPersistent")) |f| @ptrCast(@alignCast(f)) else null;
    loaded = .{ .found = c };
    return &loaded.found;
}

/// `WKNotificationProviderV0`, laid out by hand: a version, the client's
/// pointer, then its seven callbacks in WebKit's order.
const Provider = extern struct {
    version: i32 = 0,
    client: ?*const anyopaque = null,
    show: *const fn (?Ref, ?Ref, ?*const anyopaque) callconv(.c) void = &onShow,
    cancel: *const fn (?Ref, ?*const anyopaque) callconv(.c) void = &onCancel,
    destroyed: *const fn (?Ref, ?*const anyopaque) callconv(.c) void = &onIgnored,
    add_manager: *const fn (?Ref, ?*const anyopaque) callconv(.c) void = &onIgnored,
    remove_manager: *const fn (?Ref, ?*const anyopaque) callconv(.c) void = &onIgnored,
    permissions: *const fn (?*const anyopaque) callconv(.c) ?Ref = &onPermissions,
    clear: *const fn (?Ref, ?*const anyopaque) callconv(.c) void = &onClear,
};
const provider: Provider = .{};

/// Managers given the provider, once each; each shown notification's
/// manager, for its click and close.
var managers: std.ArrayList(Ref) = .empty;
var shown: std.AutoHashMapUnmanaged(u64, Ref) = .empty;

/// The Kea it answered for went away.
pub fn forget() void {
    shown.clearAndFree(gpa);
}

fn pageOf(web: objc.Object) ?Ref {
    if (!objc.msg(objc.BOOL, web, "respondsToSelector:", .{objc.sel("_pageRefForTransitionToWKWebView")})) return null;
    return objc.msg(?*anyopaque, web, "_pageRefForTransitionToWKWebView", .{});
}

/// Set on the manager of a (not private) tab's page, once.
pub fn provide(web: objc.Object) void {
    const c = webkit() orelse return;
    const page = pageOf(web) orelse return;
    const context = c.pageContext(page) orelse return;
    const manager = c.manager(context) orelse return;
    for (managers.items) |m| if (m == manager) return;
    managers.append(gpa, manager) catch return;
    c.setProvider(manager, &provider);
}

fn noteOrigin(c: *const C, note: Ref, buf: []u8) []const u8 {
    const o = c.origin(note) orelse return "";
    const s = c.text(c.originString(o));
    defer gpa.free(s);
    return notifications.originOf(buf, s);
}

/// The view a page is drawn in, among every tab's.
fn webFor(page: Ref) ?objc.Object {
    const kea = notifications.current() orelse return null;
    for (kea.browsers.items) |b| {
        for (b.tabs.items) |t| if (t.web) |wv| if (pageOf(wv) == page) return wv;
        for (b.parked.values()) |row| for (row.tabs.items) |t| if (t.web) |wv| if (pageOf(wv) == page) return wv;
    }
    return null;
}

fn onShow(page_: ?Ref, note_: ?Ref, _: ?*const anyopaque) callconv(.c) void {
    const page = page_ orelse return;
    const note = note_ orelse return;
    const c = webkit() orelse return;
    const kea = notifications.current() orelse return;
    if (c.persistent) |p| if (p(note)) return;
    const manager = c.manager(c.pageContext(page) orelse return) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    var ob: [400]u8 = undefined;
    const site = noteOrigin(c, note, &ob);
    // Only a site you allowed, while the switch is on, and never from a
    // private tab, which shares the process pool but keeps nothing.
    const web = webFor(page) orelse return;
    const store = objc.msg(objc.Object, objc.msg(objc.Object, web, "configuration", .{}), "websiteDataStore", .{});
    if (!kea.prefs.site_notifications or notifications.choice(kea, site) != true or !objc.msg(objc.BOOL, store, "isPersistent", .{})) return;
    const id = c.id(note);
    const title = c.text(c.title(note));
    defer gpa.free(title);
    const body = c.text(c.body(note));
    defer gpa.free(body);
    const tag = c.text(c.tag(note));
    defer gpa.free(tag);
    var kb: [32]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "page|{d}", .{id}) catch return;
    var ib: [24]u8 = undefined;
    notifications.post(kea, .{ .id = key, .title = title, .body = body, .origin = site, .tag = tag, .kind = "page", .kea_id = std.fmt.bufPrint(&ib, "{d}", .{id}) catch return });
    shown.put(gpa, id, manager) catch {};
    notifications.keepStore(key, store);
    c.didShow(manager, id);
}

/// notification.close() from the page.
fn onCancel(note_: ?Ref, _: ?*const anyopaque) callconv(.c) void {
    const note = note_ orelse return;
    const c = webkit() orelse return;
    const id = c.id(note);
    removeDelivered(id);
    dropStore(id);
    closed(id);
}

fn onIgnored(_: ?Ref, _: ?*const anyopaque) callconv(.c) void {}

/// What each site was told, as WebKit asks for it (handed over, not kept).
fn onPermissions(_: ?*const anyopaque) callconv(.c) ?Ref {
    const c = webkit() orelse return null;
    const dictionary = c.dictionary() orelse return null;
    const kea = notifications.current() orelse return dictionary;
    const pool = objc.Pool.push();
    defer pool.pop();
    const all = notifications.choicesDictionary(kea);
    const keys = objc.msg(objc.Object, all, "allKeys", .{});
    for (0..objc.msg(objc.NSUInteger, keys, "count", .{})) |i| {
        const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
        const key = c.string(k) orelse continue;
        defer c.release(key);
        const value = c.boolean(objc.msg(objc.BOOL, objc.msg(objc.Object, all, "objectForKey:", .{k}), "boolValue", .{})) orelse continue;
        defer c.release(value);
        _ = c.setItem(dictionary, key, value);
    }
    return dictionary;
}

/// Notifications WebKit is done with (their page went away).
fn onClear(ids_: ?Ref, _: ?*const anyopaque) callconv(.c) void {
    const ids = ids_ orelse return;
    const c = webkit() orelse return;
    for (0..c.arraySize(ids)) |i| {
        const item = c.arrayItem(ids, i) orelse continue;
        const id = c.uint64Value(item);
        removeDelivered(id);
        _ = shown.remove(id);
        dropStore(id);
    }
}

fn dropStore(id: u64) void {
    var kb: [32]u8 = undefined;
    if (notifications.takeStore(std.fmt.bufPrint(&kb, "page|{d}", .{id}) catch return)) |s| objc.release(s);
}

const Gone = struct { id: u64 };

/// Taken out of Notification Centre: the page closed it, or went away.
fn removeDelivered(id: u64) void {
    const kea = notifications.current() orelse return;
    if (notifications.testing(kea)) return;
    const g = gpa.create(Gone) catch return;
    g.* = .{ .id = id };
    var block = objc.Block(Gone, &.{objc.Object}).init(g, delivered);
    const center = objc.msg(objc.Object, objc.class("UNUserNotificationCenter"), "currentNotificationCenter", .{});
    objc.msg(void, center, "getDeliveredNotificationsWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
}

fn delivered(g: *Gone, list: objc.Object) void {
    defer gpa.destroy(g);
    var ib: [24]u8 = undefined;
    const want = std.fmt.bufPrint(&ib, "{d}", .{g.id}) catch return;
    const gone = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
        const request = objc.msg(objc.Object, objc.msg(objc.Object, list, "objectAtIndex:", .{i}), "request", .{});
        const info = objc.msg(objc.Object, objc.msg(objc.Object, request, "content", .{}), "userInfo", .{});
        const id = objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("kea.id")}) orelse continue;
        const kind = objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("kea.kind")}) orelse continue;
        if (std.mem.eql(u8, objc.fromNSString(id), want) and std.mem.eql(u8, objc.fromNSString(kind), "page"))
            objc.msg(void, gone, "addObject:", .{objc.msg(objc.Object, request, "identifier", .{})});
    }
    const center = objc.msg(objc.Object, objc.class("UNUserNotificationCenter"), "currentNotificationCenter", .{});
    objc.msg(void, center, "removeDeliveredNotificationsWithIdentifiers:", .{gone});
}

pub fn clicked(id: u64) void {
    const c = webkit() orelse return;
    const manager = shown.get(id) orelse return;
    c.didClick(manager, id);
}

pub fn closed(id: u64) void {
    const c = webkit() orelse return;
    const kv = shown.fetchRemove(id) orelse return;
    const one = c.uint64(id) orelse return;
    defer c.release(one);
    const items = [_]?Ref{one};
    const ids = c.array(&items, 1) orelse return;
    defer c.release(ids);
    c.didClose(kv.value, ids);
}
