//! Web notifications (Notifications.swift `SiteNotifications`). A site asks
//! over its own page; the answer is kept per origin under
//! `capture.<origin>|notifications`, and Forget choices takes it back. A
//! private tab is never asked and keeps nothing. What a site sends is posted
//! as a Mac notification, named by the site and wearing its icon; a click
//! brings the site's tab forward, and the click or dismissal goes back to
//! its service worker. WebKit hands a worker's notifications to the data
//! store's private `_delegate`; a page's own come through WebKit's C
//! provider (`notifications_page.zig`). A test run (`opts.root`) posts
//! nothing and never touches UNUserNotificationCenter: it keeps what it
//! would have posted in `recorded`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("../app/kea.zig").Kea;
const Tab = @import("tab.zig").Tab;
const Parts = @import("../data/url.zig").Parts;
const dialogs = @import("dialogs.zig");
const page = @import("notifications_page.zig");

const gpa = std.heap.c_allocator;

/// What a test run would have posted, newest last.
pub const Recorded = struct { title: []u8, body: []u8, origin: []u8, tag: []u8, kind: []const u8 };

var kea_now: ?*Kea = null;
var delegate: ?objc.Object = null;
var authorized = false;
pub var recorded: std.ArrayList(Recorded) = .empty;
/// The store each shown notification came from, for its click (retained).
var stores: std.StringHashMapUnmanaged(objc.Object) = .empty;

pub fn testing(kea: *const Kea) bool {
    return kea.opts.root != null;
}

/// The Kea whose windows and choices the callbacks answer for.
pub fn current() ?*Kea {
    return kea_now;
}

/// `Kea.destroy`: nothing answers for it any more; what it recorded goes.
pub fn forgetKea(kea: *Kea) void {
    if (kea_now != kea) return;
    kea_now = null;
    for (recorded.items) |r| freeRecorded(r);
    recorded.clearAndFree(gpa);
    var it = stores.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        objc.release(e.value_ptr.*);
    }
    stores.clearAndFree(gpa);
    page.forget();
}

fn freeRecorded(r: Recorded) void {
    gpa.free(r.title);
    gpa.free(r.body);
    gpa.free(r.origin);
    gpa.free(r.tag);
}

// MARK: choices

/// `Browser.origin`: "scheme://host[:port]", the standard port left out.
pub fn origin(buf: []u8, scheme: []const u8, host: []const u8, port: i64) []const u8 {
    var sb: [32]u8 = undefined;
    var hb: [256]u8 = undefined;
    const s = std.ascii.lowerString(sb[0..@min(scheme.len, sb.len)], scheme[0..@min(scheme.len, sb.len)]);
    const h = std.ascii.lowerString(hb[0..@min(host.len, hb.len)], host[0..@min(host.len, hb.len)]);
    const standard = (std.mem.eql(u8, s, "https") and port == 443) or (std.mem.eql(u8, s, "http") and port == 80);
    if (port == 0 or standard) return std.fmt.bufPrint(buf, "{s}://{s}", .{ s, h }) catch "";
    return std.fmt.bufPrint(buf, "{s}://{s}:{d}", .{ s, h, port }) catch "";
}

pub fn originOf(buf: []u8, address: []const u8) []const u8 {
    const p = Parts.parse(address) orelse return "";
    const port = if (p.port) |s| std.fmt.parseInt(i64, s, 10) catch 0 else 0;
    return origin(buf, p.scheme orelse return "", p.hostName() orelse return "", port);
}

/// `askedForNotifications` (`_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:`):
/// only the page's own origin may ask; a private tab, or Settings › Privacy's
/// switch off, is refused without a card; what was answered before stands.
pub fn asked(self: objc.Object, _: objc.SEL, wv: objc.Object, from: objc.Object, decide: *const anyopaque) callconv(.c) void {
    const t = @import("delegates_nav.zig").tabOf(self) orelse return dialogs.call(decide, .{false});
    const pool = objc.Pool.push();
    defer pool.pop();
    var buf: [400]u8 = undefined;
    const host = objc.fromNSString(objc.msg(?objc.Object, from, "host", .{}));
    const site = origin(&buf, objc.fromNSString(objc.msg(?objc.Object, from, "protocol", .{})), host, objc.msg(objc.NSInteger, from, "port", .{}));
    const store = objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "websiteDataStore", .{});
    var pb: [400]u8 = undefined;
    const page_origin = originOf(&pb, @import("tab.zig").currentUrl(wv) orelse "");
    if (!t.kea.prefs.site_notifications or t.shy or !objc.msg(objc.BOOL, store, "isPersistent", .{}) or host.len == 0 or !std.mem.eql(u8, page_origin, site))
        return dialogs.call(decide, .{false});
    if (choice(t.kea, site)) |remembered| return dialogs.call(decide, .{remembered});
    // Asked over its own page, on the bar; the grant asks macOS too (`dialogs.answerBar`).
    const a = dialogs.make(t, .notify, host, "notifications", decide) orelse return dialogs.call(decide, .{false});
    var kb: [420]u8 = undefined;
    dialogs.keepAs(a, std.fmt.bufPrint(&kb, "{s}" ++ suffix, .{site}) catch "");
    dialogs.ask(t, a);
}

const prefix = "capture.";
const suffix = "|notifications";

/// What `origin` was told, if it was asked.
pub fn choice(kea: *const Kea, site: []const u8) ?bool {
    var buf: [400]u8 = undefined;
    return kea.store.bool(std.fmt.bufPrint(&buf, prefix ++ "{s}" ++ suffix, .{site}) catch return null);
}

pub fn remember(kea: *const Kea, site: []const u8, on: bool) void {
    var buf: [400]u8 = undefined;
    kea.store.setBool(std.fmt.bufPrint(&buf, prefix ++ "{s}" ++ suffix, .{site}) catch return, on);
}

/// `forget`: Settings › Privacy's Remove.
pub fn forget(kea: *const Kea, site: []const u8) void {
    var buf: [400]u8 = undefined;
    kea.store.remove(std.fmt.bufPrint(&buf, prefix ++ "{s}" ++ suffix, .{site}) catch return);
}

/// Every origin answered (`choices`), as an NSDictionary of origin →
/// NSNumber, autoreleased; empty while Settings' switch is off.
pub fn choicesDictionary(kea: *const Kea) objc.Object {
    const out = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    if (!kea.prefs.site_notifications) return out;
    const all = objc.msg(objc.Object, kea.store.defaults, "dictionaryRepresentation", .{});
    const keys = objc.msg(objc.Object, all, "allKeys", .{});
    for (0..objc.msg(objc.NSUInteger, keys, "count", .{})) |i| {
        const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
        const key = objc.fromNSString(k);
        if (!std.mem.startsWith(u8, key, prefix) or !std.mem.endsWith(u8, key, suffix)) continue;
        const v = objc.msg(objc.Object, all, "objectForKey:", .{k});
        if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSNumber")})) continue;
        objc.msg(void, out, "setObject:forKey:", .{ v, objc.nsString(key[prefix.len .. key.len - suffix.len]) });
    }
    return out;
}

/// The sites allowed to send notifications, sorted, on `alloc`
/// (Settings › Privacy).
pub fn allowed(alloc: std.mem.Allocator, kea: *const Kea) ![][]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const all = choicesDictionary(kea);
    const keys = objc.msg(objc.Object, all, "allKeys", .{});
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    for (0..objc.msg(objc.NSUInteger, keys, "count", .{})) |i| {
        const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
        if (!objc.msg(objc.BOOL, objc.msg(objc.Object, all, "objectForKey:", .{k}), "boolValue", .{})) continue;
        try out.append(alloc, try alloc.dupe(u8, objc.fromNSString(k)));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

// MARK: WebKit

fn class() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigSiteNotifications",
        .protocols = &.{"UNUserNotificationCenterDelegate"},
        .methods = &.{
            .{ .name = "notificationPermissionsForWebsiteDataStore:", .imp = &permissions, .types = "@@:@" },
            .{ .name = "websiteDataStore:showNotification:", .imp = &workerShow, .types = "v@:@@" },
            .{ .name = "websiteDataStore:getDisplayedNotificationsForWorkerOrigin:completionHandler:", .imp = &displayed, .types = "v@:@@@?" },
            .{ .name = "websiteDataStore:openWindow:fromServiceWorkerOrigin:completionHandler:", .imp = &openWindow, .types = "v@:@@@@?" },
            .{ .name = "userNotificationCenter:willPresentNotification:withCompletionHandler:", .imp = &willPresent, .types = "v@:@@@?" },
            .{ .name = "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:", .imp = &didReceive, .types = "v@:@@@?" },
        },
    });
}

fn center() objc.Object {
    return objc.msg(objc.Object, objc.class("UNUserNotificationCenter"), "currentNotificationCenter", .{});
}

/// Made the delegate of a store its tabs use (never a private tab's).
pub fn attach(kea: *Kea, store: objc.Object) void {
    kea_now = kea;
    if (delegate == null) delegate = objc.msg(objc.Object, class(), "new", .{});
    if (!objc.msg(objc.BOOL, store, "respondsToSelector:", .{objc.sel("set_delegate:")})) return;
    objc.msg(void, store, "set_delegate:", .{delegate.?});
    if (testing(kea)) return;
    const c = center();
    if (objc.msg(?objc.Object, c, "delegate", .{}) == null) objc.msg(void, c, "setDelegate:", .{delegate.?});
}

/// A page's own notifications, on a (not private) tab's view.
pub fn provide(kea: *Kea, web: objc.Object) void {
    kea_now = kea;
    page.provide(web);
}

const Ignored = struct {
    fn done(_: *u8, _: objc.BOOL, _: ?objc.Object) void {}
};
var ignored_ctx: u8 = 0;

/// The first site allowed: macOS asks, once, whether the app may notify.
pub fn authorize(kea: *Kea) void {
    if (testing(kea) or authorized) return;
    authorized = true;
    if (delegate == null) delegate = objc.msg(objc.Object, class(), "new", .{});
    const c = center();
    objc.msg(void, c, "setDelegate:", .{delegate.?});
    var block = objc.Block(u8, &.{ objc.BOOL, ?objc.Object }).init(&ignored_ctx, Ignored.done);
    // UNAuthorizationOptionBadge | Sound | Alert.
    objc.msg(void, c, "requestAuthorizationWithOptions:completionHandler:", .{ @as(objc.NSUInteger, 7), @as(*anyopaque, @ptrCast(&block)) });
    const pool = objc.Pool.push();
    defer pool.pop();
    // UNNotificationCategoryOptionCustomDismissAction.
    const site = objc.msg(objc.Object, objc.class("UNNotificationCategory"), "categoryWithIdentifier:actions:intentIdentifiers:options:", .{
        objc.nsString("site"), objc.msg(objc.Object, objc.class("NSArray"), "array", .{}), objc.msg(objc.Object, objc.class("NSArray"), "array", .{}), @as(objc.NSUInteger, 1),
    });
    objc.msg(void, c, "setNotificationCategories:", .{objc.msg(objc.Object, objc.class("NSSet"), "setWithObject:", .{site})});
}

/// WebKit asks, as a store opens, what each site was told.
fn permissions(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.Object {
    const kea = kea_now orelse return objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    return choicesDictionary(kea);
}

fn text(data: objc.Object, key: [:0]const u8) []const u8 {
    if (!objc.msg(objc.BOOL, data, "respondsToSelector:", .{objc.sel(key)})) return "";
    const v = objc.msg(?objc.Object, data, "valueForKey:", .{objc.nsString(key)}) orelse return "";
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) return "";
    return objc.fromNSString(v);
}

/// A service worker's notification: only an origin you allowed, while
/// the switch is on.
fn workerShow(_: objc.Object, _: objc.SEL, store: objc.Object, data: objc.Object) callconv(.c) void {
    const kea = kea_now orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const from = text(data, "origin");
    if (!kea.prefs.site_notifications or choice(kea, from) != true) return;
    const ident = if (objc.msg(objc.BOOL, data, "respondsToSelector:", .{objc.sel("identifier")}))
        objc.msg(?objc.Object, data, "valueForKey:", .{objc.nsString("identifier")})
    else
        null;
    var idb: [64]u8 = undefined;
    const id = if (ident) |i| objc.fromNSString(objc.msg(objc.Object, i, "description", .{})) else std.fmt.bufPrint(&idb, "{f}", .{@import("../data/json.zig").Uuid.random()}) catch return;
    const dictionary = if (objc.msg(objc.BOOL, data, "respondsToSelector:", .{objc.sel("dictionaryRepresentation")}))
        objc.msg(?objc.Object, data, "dictionaryRepresentation", .{})
    else
        null;
    keepStore(id, store);
    post(kea, .{ .id = id, .title = text(data, "title"), .body = text(data, "body"), .origin = from, .tag = text(data, "tag"), .kind = "worker", .kea_id = id, .data = dictionary });
}

pub fn keepStore(key: []const u8, store: objc.Object) void {
    const k = gpa.dupe(u8, key) catch return;
    const gop = stores.getOrPut(gpa, k) catch return gpa.free(k);
    if (gop.found_existing) {
        gpa.free(k);
        objc.release(gop.value_ptr.*);
    }
    gop.value_ptr.* = objc.retain(store);
}

pub fn takeStore(key: []const u8) ?objc.Object {
    const kv = stores.fetchRemove(key) orelse return null;
    gpa.free(kv.key);
    return kv.value;
}

const Displayed = struct { completion: objc.Object, site: []u8 };

/// What a service worker's getNotifications() finds.
fn displayed(_: objc.Object, _: objc.SEL, _: objc.Object, from: objc.Object, completion: *const anyopaque) callconv(.c) void {
    const empty = objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
    const kea = kea_now orelse return dialogs.call(completion, .{empty});
    if (testing(kea)) return dialogs.call(completion, .{empty});
    var buf: [400]u8 = undefined;
    const site = origin(&buf, objc.fromNSString(objc.msg(?objc.Object, from, "protocol", .{})), objc.fromNSString(objc.msg(?objc.Object, from, "host", .{})), objc.msg(objc.NSInteger, from, "port", .{}));
    const d = gpa.create(Displayed) catch return dialogs.call(completion, .{empty});
    d.* = .{ .completion = _Block_copy(completion).?, .site = gpa.dupe(u8, site) catch {
        gpa.destroy(d);
        return dialogs.call(completion, .{empty});
    } };
    var block = objc.Block(Displayed, &.{objc.Object}).init(d, delivered);
    objc.msg(void, center(), "getDeliveredNotificationsWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
}

fn delivered(d: *Displayed, list: objc.Object) void {
    defer {
        _Block_release(d.completion);
        gpa.free(d.site);
        gpa.destroy(d);
    }
    const found = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
        const info = userInfo(objc.msg(objc.Object, list, "objectAtIndex:", .{i}));
        if (!std.mem.eql(u8, infoText(info, "kea.kind"), "worker") or !std.mem.eql(u8, infoText(info, "kea.origin"), d.site)) continue;
        if (objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("kea.data")})) |data| objc.msg(void, found, "addObject:", .{data});
    }
    dialogs.call(@ptrCast(d.completion), .{found});
}

extern "c" fn _Block_copy(block: ?*const anyopaque) ?objc.Object;
extern "c" fn _Block_release(block: objc.Object) void;

fn userInfo(note: objc.Object) objc.Object {
    return objc.msg(objc.Object, objc.msg(objc.Object, objc.msg(objc.Object, note, "request", .{}), "content", .{}), "userInfo", .{});
}

fn infoText(info: objc.Object, key: []const u8) []const u8 {
    const v = objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString(key)}) orelse return "";
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) return "";
    return objc.fromNSString(v);
}

/// clients.openWindow() from a notification's click: a tab in a window
/// signed in with the worker's store, only for a web address.
fn openWindow(_: objc.Object, _: objc.SEL, store: objc.Object, url: objc.Object, _: objc.Object, completion: *const anyopaque) callconv(.c) void {
    const none: ?objc.Object = null;
    const kea = kea_now orelse return dialogs.call(completion, .{none});
    const address = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
    const scheme = objc.fromNSString(objc.msg(?objc.Object, url, "scheme", .{}));
    if (testing(kea) or !(std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https"))) return dialogs.call(completion, .{none});
    const browsers = @import("../app/browsers.zig");
    const default = objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "defaultDataStore", .{});
    var pick: ?*@import("../model/browser.zig").Browser = null;
    var last_open: @TypeOf(pick) = null;
    for (kea.browsers.items) |b| {
        if ((kea.dataStore(b.space_id) orelse default) != store) continue;
        if (pick == null) pick = b;
        if (!b.shut) last_open = b;
        if (b == kea.windows.front and !b.shut) {
            last_open = b;
            break;
        }
    }
    const b = last_open orelse pick orelse return dialogs.call(completion, .{none});
    const t = b.open(address, .{ .foreground = true });
    browsers.show(b);
    dialogs.call(completion, .{t.web});
}

/// Shown even with the app in front, as a browser's are: banner, list, sound.
fn willPresent(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, completion: *const anyopaque) callconv(.c) void {
    dialogs.call(completion, .{@as(objc.NSUInteger, (1 << 4) | (1 << 3) | (1 << 1))});
}

const Response = struct { info: objc.Object, dismissed: bool, completion: objc.Object };

fn didReceive(_: objc.Object, _: objc.SEL, _: objc.Object, response: objc.Object, completion: *const anyopaque) callconv(.c) void {
    const r = gpa.create(Response) catch return dialogs.call(completion, .{});
    const action = objc.fromNSString(objc.msg(?objc.Object, response, "actionIdentifier", .{}));
    r.* = .{
        .info = objc.retain(userInfo(objc.msg(objc.Object, response, "notification", .{}))),
        .dismissed = std.mem.eql(u8, action, "com.apple.UNNotificationDismissActionIdentifier"),
        .completion = _Block_copy(completion).?,
    };
    objc.dispatchMain(r, answered);
}

fn answered(ctx: ?*anyopaque) callconv(.c) void {
    const r: *Response = @ptrCast(@alignCast(ctx.?));
    defer {
        dialogs.call(@ptrCast(r.completion), .{});
        _Block_release(r.completion);
        objc.release(r.info);
        gpa.destroy(r);
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    if (r.dismissed) closed(r.info) else clicked(r.info);
}

// MARK: posting

pub const Post = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8,
    origin: []const u8,
    tag: []const u8,
    /// "worker" or "page".
    kind: []const u8,
    kea_id: []const u8,
    data: ?objc.Object = null,
};

pub fn post(kea: *Kea, n: Post) void {
    if (testing(kea)) {
        const r: Recorded = .{
            .title = gpa.dupe(u8, n.title) catch return,
            .body = gpa.dupe(u8, n.body) catch return,
            .origin = gpa.dupe(u8, n.origin) catch return,
            .tag = gpa.dupe(u8, n.tag) catch return,
            .kind = if (std.mem.eql(u8, n.kind, "page")) "page" else "worker",
        };
        recorded.append(gpa, r) catch freeRecorded(r);
        return;
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const info = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    for ([_][2][]const u8{ .{ "kea.kind", n.kind }, .{ "kea.id", n.kea_id }, .{ "kea.origin", n.origin }, .{ "kea.key", n.id } }) |kv|
        objc.msg(void, info, "setObject:forKey:", .{ objc.nsString(kv[1]), objc.nsString(kv[0]) });
    if (n.data) |d| objc.msg(void, info, "setObject:forKey:", .{ d, objc.nsString("kea.data") });
    const content = objc.msg(objc.Object, objc.class("UNMutableNotificationContent"), "new", .{});
    defer objc.release(content);
    objc.msg(void, content, "setTitle:", .{objc.nsString(n.title)});
    objc.msg(void, content, "setBody:", .{objc.nsString(n.body)});
    objc.msg(void, content, "setSubtitle:", .{objc.nsString(@import("../chrome/site_card.zig").site(n.origin))});
    objc.msg(void, content, "setThreadIdentifier:", .{objc.nsString(n.origin)});
    objc.msg(void, content, "setCategoryIdentifier:", .{objc.nsString("site")});
    objc.msg(void, content, "setSound:", .{objc.msg(objc.Object, objc.class("UNNotificationSound"), "defaultSound", .{})});
    objc.msg(void, content, "setUserInfo:", .{info});
    if (iconAttachment(kea, n.origin)) |a| objc.msg(void, content, "setAttachments:", .{objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{a})});
    // A tag names a notification its site means to replace.
    var ib: [600]u8 = undefined;
    const identifier = if (n.tag.len == 0) n.id else std.fmt.bufPrint(&ib, "tag|{s}|{s}", .{ n.origin, n.tag }) catch n.id;
    const request = objc.msg(objc.Object, objc.class("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", .{ objc.nsString(identifier), content, @as(?objc.Object, null) });
    objc.msg(void, center(), "addNotificationRequest:withCompletionHandler:", .{ request, @as(?*anyopaque, null) });
}

/// The site's icon as a file of its own each time: macOS moves an
/// attachment's file into its own keeping.
fn iconAttachment(kea: *Kea, site: []const u8) ?objc.Object {
    const icon = kea.favicons.icon(site) orelse return null;
    const host = (Parts.parse(site) orelse return null).hostName() orelse return null;
    return attachmentAt(host, icon.png);
}

fn attachmentAt(host: []const u8, png: []const u8) ?objc.Object {
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const tmp = objc.msg(objc.Object, fm, "temporaryDirectory", .{});
    const folder = objc.msg(objc.Object, tmp, "URLByAppendingPathComponent:isDirectory:", .{ objc.nsString("Kea notifications"), objc.YES });
    _ = objc.msg(objc.BOOL, fm, "createDirectoryAtURL:withIntermediateDirectories:attributes:error:", .{ folder, objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null) });
    var nb: [400]u8 = undefined;
    const name = std.fmt.bufPrint(&nb, "{s}-{f}.png", .{ host, @import("../data/json.zig").Uuid.random() }) catch return null;
    const file = objc.msg(objc.Object, folder, "URLByAppendingPathComponent:", .{objc.nsString(name)});
    const bytes = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ png.ptr, png.len });
    if (!objc.msg(objc.BOOL, bytes, "writeToURL:atomically:", .{ file, objc.YES })) return null;
    return objc.msg(?objc.Object, objc.class("UNNotificationAttachment"), "attachmentWithIdentifier:URL:options:error:", .{ objc.nsString("icon"), file, @as(?objc.Object, null), @as(?*anyopaque, null) });
}

// MARK: answered

/// Clicked: the site's tab in front, and the click to its worker.
fn clicked(info: objc.Object) void {
    const from = takeStore(infoText(info, "kea.key"));
    defer if (from) |s| objc.release(s);
    bringForward(infoText(info, "kea.origin"), from);
    const kind = infoText(info, "kea.kind");
    if (std.mem.eql(u8, kind, "page")) {
        if (std.fmt.parseInt(u64, infoText(info, "kea.id"), 10)) |id| page.clicked(id) else |_| {}
        return;
    }
    if (std.mem.eql(u8, kind, "worker")) tell(from, "_processPersistentNotificationClick:completionHandler:", info);
}

/// Dismissed: the worker hears its notification closed.
fn closed(info: objc.Object) void {
    const from = takeStore(infoText(info, "kea.key"));
    defer if (from) |s| objc.release(s);
    const kind = infoText(info, "kea.kind");
    if (std.mem.eql(u8, kind, "page")) {
        if (std.fmt.parseInt(u64, infoText(info, "kea.id"), 10)) |id| page.closed(id) else |_| {}
        return;
    }
    if (std.mem.eql(u8, kind, "worker")) tell(from, "_processPersistentNotificationClose:completionHandler:", info);
}

fn tell(from: ?objc.Object, name: [:0]const u8, info: objc.Object) void {
    const data = objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("kea.data")}) orelse return;
    const store = from orelse objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "defaultDataStore", .{});
    if (!objc.msg(objc.BOOL, store, "respondsToSelector:", .{objc.sel(name)})) return;
    var block = objc.Block(u8, &.{objc.BOOL}).init(&ignored_ctx, struct {
        fn done(_: *u8, _: objc.BOOL) void {}
    }.done);
    objc.msg(void, store, name, .{ data, @as(*anyopaque, @ptrCast(&block)) });
}

/// The tab showing the site in front: one signed in with the store the
/// notification came from if there is one, never a private tab.
fn bringForward(site: []const u8, from: ?objc.Object) void {
    const kea = kea_now orelse return;
    var first: ?*Tab = null;
    var best: ?*Tab = null;
    for (kea.browsers.items) |b| for (b.tabs.items) |t| {
        if (t.shy) continue;
        var buf: [400]u8 = undefined;
        if (!std.mem.eql(u8, originOf(&buf, t.address orelse continue), site)) continue;
        if (first == null) first = t;
        const store = if (t.web) |wv| objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "websiteDataStore", .{}) else null;
        if (from != null and store == from) {
            best = t;
            break;
        }
    };
    const t = best orelse first orelse return;
    const b = t.browser orelse return;
    b.select(t);
    @import("../app/browsers.zig").show(b);
    if (kea.ui_app) |a| objc.msg(void, a.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
}

test "origin leaves out the standard port and lowercases" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("https://kea.app", origin(&buf, "HTTPS", "Kea.App", 443));
    try std.testing.expectEqualStrings("http://localhost:8080", origin(&buf, "http", "localhost", 8080));
    try std.testing.expectEqualStrings("http://a.b", origin(&buf, "http", "a.b", 0));
    try std.testing.expectEqualStrings("https://x.y:80", originOf(&buf, "https://x.y:80/path"));
}
