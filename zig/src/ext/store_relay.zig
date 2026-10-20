//! The Chrome Web Store, made to work for this browser (StoreRelay.swift):
//! the "Switch to Chrome" banner goes and the store's grey button becomes
//! "Add to Kea". What gets installed is read from the tab's own address,
//! never from anything the page says; the page only asks.
const std = @import("std");
const objc = @import("nanoui").objc;
const Tab = @import("../web/tab.zig").Tab;
const Kea = @import("../app/kea.zig").Kea;
const Parts = @import("../data/url.zig").Parts;
const json = @import("../data/json.zig");
const crx = @import("crx.zig");

/// `StoreRelay.name`.
pub const name = "keaStore";
/// `StoreRelay.script`: main frame, document end, Kea's world.
pub const script = @embedFile("js/store_relay.js");
/// `Browser.webStore`: its extensions, not its themes.
pub const web_store = "https://chromewebstore.google.com/category/extensions";

/// `StoreOffer.isStorePage(_:)` (ExtensionsUI.swift:281).
pub fn isStorePage(url: []const u8) bool {
    const p = Parts.parse(url) orelse return false;
    if (!std.ascii.eqlIgnoreCase(p.scheme orelse "", "https") or p.user != null or p.password != null) return false;
    const host = p.host orelse "";
    return std.ascii.eqlIgnoreCase(host, "chromewebstore.google.com") or
        (std.ascii.eqlIgnoreCase(host, "chrome.google.com") and std.mem.startsWith(u8, p.path, "/webstore"));
}

/// `userContentController(_:didReceive:)`: `body` is the message's
/// NSDictionary.
pub fn received(t: *Tab, body: objc.Object) void {
    if (objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString("add")}) != null) addFromStore(t);
    const placed = objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString("placed")}) orelse return;
    if (!objc.msg(objc.BOOL, placed, "isKindOfClass:", .{objc.class("NSString")})) return;
    const copy = t.gpa.dupe(u8, objc.fromNSString(placed)) catch return;
    if (t.store_placed) |old| t.gpa.free(old);
    t.store_placed = copy;
    t.changed(.state);
}

/// `Browser.addFromStore(_:)`: the extension this tab is showing.
pub fn addFromStore(t: *Tab) void {
    const exts = t.kea.ext orelse return;
    const id = crx.storeID(t.address orelse return) orelse return;
    exts.installFrom(&id, true);
}

/// `Browser.tellStore(_:)` + `Tab.tellStore(installed:busy:)`: what is
/// installed and on its way, so the button says "Added to Kea"/"Adding…".
pub fn tellStore(t: *Tab) void {
    const exts = t.kea.ext orelse return;
    if (t.web == null or !isStorePage(t.address orelse return)) return;
    const ids = t.gpa.alloc([]const u8, exts.installed.items.len) catch return;
    defer t.gpa.free(ids);
    for (exts.installed.items, ids) |row, *slot| slot.* = row.id;
    const state = json.encode(t.gpa, .{ .installed = ids, .busy = @as(?[]const u8, exts.busy) }) catch return;
    defer t.gpa.free(state);
    const source = std.fmt.allocPrint(t.gpa, "window.__keaStore && window.__keaStore.state({s})", .{state}) catch return;
    defer t.gpa.free(source);
    t.evaluate(source, .kea, null, 0);
}

/// `Browser.followStore()`'s sink: every store page told again whenever
/// `installed` or `busy` changes. The controller calls this on each change.
pub fn tellAll(kea: *Kea) void {
    for (kea.browsers.items) |b| for (b.tabs.items) |t| tellStore(t);
}

test "store pages" {
    try std.testing.expect(isStorePage("https://chromewebstore.google.com/detail/x"));
    try std.testing.expect(isStorePage("https://chrome.google.com/webstore/detail/x"));
    try std.testing.expect(!isStorePage("https://chrome.google.com/other"));
    try std.testing.expect(!isStorePage("http://chromewebstore.google.com/"));
    try std.testing.expect(!isStorePage("https://u@chromewebstore.google.com/"));
}
