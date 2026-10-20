//! What is kept, and getting rid of it (Browser.swift 1069-1101): History's
//! clearing cards and Settings › Privacy call these.
const objc = @import("nanoui").objc;
const Browser = @import("browser.zig").Browser;

/// Everywhere you have been — and the sites' icons and the searches learned
/// from sites, which are lists of where you have been too.
pub fn clearHistory(b: *Browser) void {
    b.kea.history.forgetAll();
    // Other Macs clear theirs too (History.clear → `Sync.historyCleared`).
    b.kea.sync.historyCleared();
    b.kea.favicons.forgetAll();
    b.kea.site_search.forget();
    b.announce("History cleared — no footprints left");
}

/// Cookies, caches, local storage — everything a site left on this Mac, in
/// every space. Clearing it signs you out of everything, which is the point.
pub fn clearSites(b: *Browser) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    removeData(b, objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "allWebsiteDataTypes", .{}));
    b.announce("Signed out of everything");
}

extern const WKWebsiteDataTypeDiskCache: objc.Object;
extern const WKWebsiteDataTypeMemoryCache: objc.Object;
extern const WKWebsiteDataTypeOfflineWebApplicationCache: objc.Object;

/// Only what was fetched to draw pages, not what identifies you.
pub fn clearCache(b: *Browser) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const kinds = [_]objc.Object{ WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache };
    const set = objc.msg(objc.Object, objc.class("NSSet"), "setWithObjects:count:", .{ &kinds, @as(objc.NSUInteger, kinds.len) });
    removeData(b, set);
    b.announce("Cache cleared. Fresh snow.");
}

var nothing: u8 = 0;

/// `types` removed from every space's store. A test run's tabs keep nothing
/// and its hands stay off the stores WebKit keeps for this Mac.
fn removeData(b: *Browser, types: objc.Object) void {
    const kea = b.kea;
    if (kea.opts.root != null) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const since = objc.msg(objc.Object, objc.class("NSDate"), "distantPast", .{});
    var done = objc.Block(u8, &.{}).init(&nothing, struct {
        fn f(_: *u8) void {}
    }.f);
    const default = objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "defaultDataStore", .{});
    var cleared_default = false;
    for (kea.spaces.value) |s| {
        const store = kea.dataStore(s.id) orelse blk: {
            if (cleared_default) continue;
            cleared_default = true;
            break :blk default;
        };
        objc.msg(void, store, "removeDataOfTypes:modifiedSince:completionHandler:", .{ types, since, &done });
    }
}
