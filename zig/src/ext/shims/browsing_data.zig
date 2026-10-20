//! chrome.browsingData (ExtensionShims.swift 3971-3987, `clear` 4253-4279).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");
const json = @import("../../data/json.zig");

extern const WKWebsiteDataTypeDiskCache: objc.Object;
extern const WKWebsiteDataTypeMemoryCache: objc.Object;
extern const WKWebsiteDataTypeFetchCache: objc.Object;
extern const WKWebsiteDataTypeOfflineWebApplicationCache: objc.Object;
extern const WKWebsiteDataTypeCookies: objc.Object;
extern const WKWebsiteDataTypeLocalStorage: objc.Object;
extern const WKWebsiteDataTypeSessionStorage: objc.Object;
extern const WKWebsiteDataTypeIndexedDBDatabases: objc.Object;
extern const WKWebsiteDataTypeServiceWorkerRegistrations: objc.Object;
extern const WKWebsiteDataTypeWebSQLDatabases: objc.Object;
extern const WKWebsiteDataTypeFileSystem: objc.Object;

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    if (!std.mem.startsWith(u8, api, "browsingData.")) return null;
    if (std.mem.eql(u8, api, "browsingData.settings")) return try c.give(.{
        .options = .{ .since = 0 },
        .dataToRemove = .{},
        .dataRemovalPermitted = .{
            .cache = true, .cookies = true, .history = true, .downloads = true, .localStorage = true,
            .indexedDB = true, .serviceWorkers = true, .cacheStorage = true, .fileSystems = true, .webSQL = true,
        },
    });
    // What to clear: `remove`'s own bools, or `removeX` → `x`.
    var what: std.StringArrayHashMapUnmanaged(bool) = .empty;
    if (std.mem.eql(u8, api, "browsingData.remove")) {
        if (c.arg(1)) |v| if (v == .object) {
            var it = v.object.iterator();
            while (it.next()) |e| if (e.value_ptr.* == .bool) try what.put(c.a, e.key_ptr.*, e.value_ptr.bool);
        };
    } else {
        const key = try c.a.dupe(u8, api[@min(api.len, "browsingData.remove".len)..]);
        if (key.len > 0) key[0] = std.ascii.toLower(key[0]);
        try what.put(c.a, key, true);
    }
    try clear(c, what, c.first());
    return .later;
}

const map = std.StaticStringMap([]const *const objc.Object).initComptime(.{
    .{ "cache", &.{ &WKWebsiteDataTypeDiskCache, &WKWebsiteDataTypeMemoryCache, &WKWebsiteDataTypeFetchCache } },
    .{ "cacheStorage", &.{&WKWebsiteDataTypeFetchCache} },
    .{ "appcache", &.{&WKWebsiteDataTypeOfflineWebApplicationCache} },
    .{ "cookies", &.{&WKWebsiteDataTypeCookies} },
    .{ "localStorage", &.{ &WKWebsiteDataTypeLocalStorage, &WKWebsiteDataTypeSessionStorage } },
    .{ "indexedDB", &.{&WKWebsiteDataTypeIndexedDBDatabases} },
    .{ "serviceWorkers", &.{&WKWebsiteDataTypeServiceWorkerRegistrations} },
    .{ "webSQL", &.{&WKWebsiteDataTypeWebSQLDatabases} },
    .{ "fileSystems", &.{&WKWebsiteDataTypeFileSystem} },
});

/// One clear in flight: the types (retained NSSet) and the hosts to match.
const Clearing = struct {
    store: objc.Object,
    types: objc.Object,
    origins: []const []const u8,
    p: *ans.Pending,

    fn records(s: *Clearing, all: objc.Object) void {
        const hit = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
        const n = objc.msg(objc.NSUInteger, all, "count", .{});
        var i: objc.NSUInteger = 0;
        while (i < n) : (i += 1) {
            const record = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
            const name = objc.fromNSString(objc.msg(objc.Object, record, "displayName", .{}));
            for (s.origins) |o| if (std.mem.eql(u8, o, name) or (o.len > name.len and
                std.mem.endsWith(u8, o, name) and o[o.len - name.len - 1] == '.'))
            {
                objc.msg(void, hit, "addObject:", .{record});
                break;
            };
        }
        var done = objc.Block(Clearing, &.{}).init(s, finished);
        objc.msg(void, s.store, "removeDataOfTypes:forDataRecords:completionHandler:", .{ s.types, hit, &done });
    }

    fn finished(s: *Clearing) void {
        objc.release(s.types);
        s.p.value(.null);
    }
};

/// `clear`: from what WebKit and Kea keep; answered null once done.
fn clear(c: *ans.Call, what: std.StringArrayHashMapUnmanaged(bool), options: ?ans.Value) ans.Error!void {
    const since = json.fromUnix((ans.num(ans.field(options, "since")) orelse 0) / 1000);
    const origins: ?[]const []const u8 = if (try ans.allStrings(c.a, ans.field(options, "origins"))) |urls| blk: {
        var hosts: std.ArrayList([]const u8) = .empty;
        const pool = objc.Pool.push();
        defer pool.pop();
        for (urls) |u| {
            const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(u)}) orelse continue;
            const host = objc.msg(?objc.Object, url, "host", .{}) orelse continue;
            try hosts.append(c.a, try c.a.dupe(u8, objc.fromNSString(host)));
        }
        break :blk hosts.items;
    } else null;

    if (what.get("history") == true and origins == null) {
        const h = &c.browser.kea.history;
        h.ensureIndexed();
        var keys: std.ArrayList([]const u8) = .empty;
        for (h.visits.values()) |e| if (e.visit.last >= since) try keys.append(c.a, try c.a.dupe(u8, e.visit.key));
        for (keys.items) |k| {
            c.browser.kea.sync.historyForgot(k);
            h.forget(k);
        }
    }

    const pool = objc.Pool.push();
    defer pool.pop();
    const types = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSMutableSet"), "alloc", .{}), "init", .{});
    var it = what.iterator();
    while (it.next()) |e| if (e.value_ptr.*) if (map.get(e.key_ptr.*)) |list| for (list) |t| objc.msg(void, types, "addObject:", .{t.*});
    // A test run never touches the Mac's own website data (`Store.websites`' probe).
    if (c.browser.kea.opts.root != null or objc.msg(objc.NSUInteger, types, "count", .{}) == 0) {
        objc.release(types);
        return c.pending.value(.null);
    }
    const s = try c.a.create(Clearing);
    s.* = .{
        .store = objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "defaultDataStore", .{}),
        .types = types,
        .origins = origins orelse &.{},
        .p = c.pending,
    };
    if (origins != null) {
        var got = objc.Block(Clearing, &.{objc.Object}).init(s, Clearing.records);
        objc.msg(void, s.store, "fetchDataRecordsOfTypes:completionHandler:", .{ types, &got });
    } else {
        const date = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceReferenceDate:", .{since});
        var done = objc.Block(Clearing, &.{}).init(s, Clearing.finished);
        objc.msg(void, s.store, "removeDataOfTypes:modifiedSince:completionHandler:", .{ types, date, &done });
    }
}
