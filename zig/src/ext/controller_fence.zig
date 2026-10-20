//! What an extension is allowed and what it is told it may reach
//! (Extensions.swift 995-1137): the grants written down on install and
//! compared on update, the fences around extension pages and files, the
//! native-messaging gate, and the words an install question uses.
const std = @import("std");
const objc = @import("nanoui").objc;
const ext = @import("ext.zig");
const disk = @import("../data/disk.zig");

const Strings = std.ArrayList([]u8);

pub fn freeAll(gpa: std.mem.Allocator, list: []const []u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn str(o: ?objc.Object) ?[]const u8 {
    const s = o orelse return null;
    return objc.fromNSString(s);
}

fn get(dict: objc.Object, key: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)});
}

fn isKind(o: objc.Object, comptime class: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class(class)});
}

/// An NSSet's or NSArray's members, as an NSArray.
fn members(set: ?objc.Object) ?objc.Object {
    const s = set orelse return null;
    return if (isKind(s, "NSArray")) s else objc.msg(objc.Object, s, "allObjects", .{});
}

fn count(arr: ?objc.Object) usize {
    return if (arr) |a| objc.msg(objc.NSUInteger, a, "count", .{}) else 0;
}

fn at(arr: objc.Object, i: usize) objc.Object {
    return objc.msg(objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
}

fn setHas(set: ?objc.Object, name: []const u8) bool {
    const s = set orelse return false;
    return objc.msg(objc.BOOL, s, "containsObject:", .{objc.nsString(name)});
}

fn isPageScheme(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, ext.scheme) or std.ascii.eqlIgnoreCase(s, ext.former_scheme) or std.ascii.eqlIgnoreCase(s, "webkit-extension");
}

/// A JSON file's strings: `.kea-added`, or the manifest's "permissions".
fn readStrings(gpa: std.mem.Allocator, folder: []const u8, name: []const u8, key: ?[]const u8) Strings {
    var out: Strings = .empty;
    const path = std.fs.path.join(gpa, &.{ folder, name }) catch return out;
    defer gpa.free(path);
    const text = disk.read(gpa, path) orelse return out;
    defer gpa.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch return out;
    defer parsed.deinit();
    var v = parsed.value;
    if (key) |k| {
        if (v != .object) return out;
        v = v.object.get(k) orelse return out;
    }
    if (v != .array) return out;
    for (v.array.items) |item| if (item == .string) {
        const s = gpa.dupe(u8, item.string) catch continue;
        out.append(gpa, s) catch gpa.free(s);
    };
    return out;
}

fn has(list: []const []u8, name: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

fn deinitStrings(gpa: std.mem.Allocator, l: *Strings) void {
    for (l.items) |s| gpa.free(s);
    l.deinit(gpa);
}

/// `Extensions.popupURL(for:)`: the manifest's button page, relative to the
/// extension and keeping a query it may carry. On `gpa`.
pub fn popupURL(gpa: std.mem.Allocator, context: objc.Object) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const found = objc.msg(objc.Object, context, "webExtension", .{});
    const manifest = objc.msg(objc.Object, found, "manifest", .{});
    const action = get(manifest, "action") orelse get(manifest, "browser_action") orelse return null;
    if (!isKind(action, "NSDictionary")) return null;
    const path = get(action, "default_popup") orelse return null;
    if (!isKind(path, "NSString") or objc.msg(objc.NSUInteger, path, "length", .{}) == 0) return null;
    return relative(gpa, context, objc.fromNSString(path));
}

/// `URL(string: path, relativeTo: context.baseURL)?.absoluteURL`, on `gpa`.
pub fn relative(gpa: std.mem.Allocator, context: objc.Object, path: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const base = objc.msg(?objc.Object, context, "baseURL", .{});
    const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:relativeToURL:", .{ objc.nsString(path), base }) orelse return null;
    const abs = objc.msg(objc.Object, url, "absoluteString", .{});
    return gpa.dupe(u8, objc.fromNSString(abs)) catch null;
}

/// `Extensions.grants`: WebKit's permissions (less what Kea added), the
/// sites it reaches ("site:"), and the APIs Kea answers for it ("kea:"),
/// sorted. An update adding any of them is asked about again.
pub fn grants(gpa: std.mem.Allocator, found: objc.Object, folder: []const u8) ![]const []u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var added = readStrings(gpa, folder, ".kea-added", null);
    defer deinitStrings(gpa, &added);
    var declared = readStrings(gpa, folder, "manifest.json", "permissions");
    defer deinitStrings(gpa, &declared);
    var out: std.StringArrayHashMapUnmanaged(void) = .empty;
    errdefer {
        for (out.keys()) |k| gpa.free(k);
        out.deinit(gpa);
    }
    const perms = members(objc.msg(?objc.Object, found, "requestedPermissions", .{}));
    for (0..count(perms)) |i| {
        const p = objc.fromNSString(at(perms.?, i));
        if (!has(added.items, p)) try put(gpa, &out, try gpa.dupe(u8, p));
    }
    const patterns = members(objc.msg(?objc.Object, found, "allRequestedMatchPatterns", .{}));
    for (0..count(patterns)) |i| {
        const s = objc.fromNSString(objc.msg(objc.Object, at(patterns.?, i), "string", .{}));
        try put(gpa, &out, try std.mem.concat(gpa, u8, &.{ "site:", s }));
    }
    for (declared.items) |d| if (answered(d) and !has(added.items, d)) {
        try put(gpa, &out, try std.mem.concat(gpa, u8, &.{ "kea:", d }));
    };
    const list = try gpa.alloc([]u8, out.count());
    for (out.keys(), list) |k, *slot| slot.* = @constCast(k);
    out.deinit(gpa);
    std.mem.sort([]u8, list, {}, lessThan);
    return list;
}

fn put(gpa: std.mem.Allocator, set: *std.StringArrayHashMapUnmanaged(void), key: []u8) !void {
    const r = set.getOrPut(gpa, key) catch |e| {
        gpa.free(key);
        return e;
    };
    if (r.found_existing) gpa.free(key);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `reachesExtensions`: a pattern naming extension pages, another's or all.
pub fn reachesExtensions(pattern: objc.Object) bool {
    const s = str(objc.msg(?objc.Object, pattern, "scheme", .{})) orelse return false;
    return isPageScheme(s);
}

/// `reachesFiles`: a pattern naming files on this Mac.
pub fn reachesFiles(pattern: objc.Object) bool {
    const s = str(objc.msg(?objc.Object, pattern, "scheme", .{})) orelse return false;
    return std.ascii.eqlIgnoreCase(s, "file");
}

/// `withheld`: what no extension is given or asked about.
pub fn withheld(pattern: objc.Object) bool {
    return reachesExtensions(pattern) or reachesFiles(pattern);
}

const granted_explicitly: objc.NSInteger = 3;
const denied_explicitly: objc.NSInteger = -3;

fn setStatus(context: objc.Object, status: objc.NSInteger, pattern: objc.Object) void {
    objc.msg(void, context, "setPermissionStatus:forMatchPattern:", .{ status, pattern });
}

/// `grantSites`: the sites its manifest names, granted as it loads, none
/// withheld (`fence` is set after).
pub fn grantSites(context: objc.Object) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const found = objc.msg(objc.Object, context, "webExtension", .{});
    const patterns = members(objc.msg(?objc.Object, found, "allRequestedMatchPatterns", .{}));
    for (0..count(patterns)) |i| {
        const p = at(patterns.?, i);
        if (!withheld(p)) setStatus(context, granted_explicitly, p);
    }
}

/// `fence`: other extensions' pages (counted by WebKit in <all_urls> once
/// chrome-extension is a registered scheme) and files are refused
/// outright. Set again after anything is granted.
pub fn fence(context: objc.Object) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    // Swift's Set of the three; webkit-extension is the former scheme.
    const strings = [_][]const u8{ ext.scheme ++ "://*/*", ext.former_scheme ++ "://*/*", "file:///*", "file://*/*" };
    for (strings) |s| {
        const p = objc.msg(?objc.Object, objc.class("WKWebExtensionMatchPattern"), "matchPatternWithString:", .{objc.nsString(s)}) orelse continue;
        setStatus(context, denied_explicitly, p);
    }
}

/// `asksForNative`: its manifest asks for "nativeMessaging", required (and
/// not added by Kea, see `.kea-added`) or optional.
pub fn asksForNative(gpa: std.mem.Allocator, context: objc.Object, folder: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    var added = readStrings(gpa, folder, ".kea-added", null);
    defer deinitStrings(gpa, &added);
    const found = objc.msg(objc.Object, context, "webExtension", .{});
    const required = setHas(objc.msg(?objc.Object, found, "requestedPermissions", .{}), "nativeMessaging") and !has(added.items, "nativeMessaging");
    return required or setHas(objc.msg(?objc.Object, found, "optionalPermissions", .{}), "nativeMessaging");
}

/// `othersPage`: `url` is a page of an extension other than `own_id`.
pub fn othersPage(url: ?[]const u8, own_id: []const u8) bool {
    const u = url orelse return false;
    const colon = std.mem.indexOf(u8, u, "://") orelse return false;
    if (!isPageScheme(u[0..colon])) return false;
    const rest = u[colon + 3 ..];
    const host = rest[0 .. std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len];
    return !std.ascii.eqlIgnoreCase(host, own_id);
}

/// `keaAnswered`: Chrome's own APIs, which Kea answers itself, and what
/// each lets an extension do.
pub const kea_answered = [_][2][]const u8{
    .{ "userScripts", "Run scripts you add to it on websites" },    .{ "history", "Read and change your history" },
    .{ "bookmarks", "Read and change your bookmarks" },             .{ "downloads", "Manage your downloads" },
    .{ "privacy", "Change your privacy settings" },                 .{ "browsingData", "Clear your browsing data" },
    .{ "management", "See your other extensions" },                 .{ "notifications", "Show notifications" },
    .{ "sessions", "See your recently closed tabs" },               .{ "topSites", "See your most visited sites" },
    .{ "readingList", "Read and change your reading list" },        .{ "downloads.open", "Open files it downloads" },
    .{ "desktopCapture", "Record your screen or a window, when you choose what to share" },
    .{ "tabCapture", "Record a tab, when you ask it to" },
};

fn answered(name: []const u8) bool {
    for (kea_answered) |pair| if (std.mem.eql(u8, pair[0], name)) return true;
    return false;
}

const words = [_][2][]const u8{
    .{ "tabs", "See your open tabs and their addresses" },
    .{ "cookies", "Read and change cookies" },
    .{ "webNavigation", "See where you go" },
    .{ "webRequest", "See the requests pages make" },
    .{ "declarativeNetRequest", "Block or change requests pages make" },
    .{ "clipboardWrite", "Write to the clipboard" },
    .{ "nativeMessaging", "Talk to apps on this Mac" },
    .{ "scripting", "Run scripts in pages" },
};

/// `describe`: what an extension wants, in words (gpa strings; `freeAll`).
pub fn describe(gpa: std.mem.Allocator, found: objc.Object, folder: []const u8) ![]const []u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var added = readStrings(gpa, folder, ".kea-added", null);
    defer deinitStrings(gpa, &added);
    var declared = readStrings(gpa, folder, "manifest.json", "permissions");
    defer deinitStrings(gpa, &declared);
    var out: Strings = .empty;
    errdefer deinitStrings(gpa, &out);

    const patterns = members(objc.msg(?objc.Object, found, "allRequestedMatchPatterns", .{}));
    var all = false;
    var hosts: std.ArrayList([]const u8) = .empty;
    defer hosts.deinit(gpa);
    for (0..count(patterns)) |i| {
        const p = at(patterns.?, i);
        if (objc.msg(objc.BOOL, p, "matchesAllHosts", .{}) or objc.msg(objc.BOOL, p, "matchesAllURLs", .{})) all = true;
        if (str(objc.msg(?objc.Object, p, "host", .{}))) |h| if (h.len > 0) try hosts.append(gpa, h);
    }
    if (all) {
        try out.append(gpa, try gpa.dupe(u8, "Read and change everything on every website"));
    } else if (count(patterns) > 0) {
        try out.append(gpa, try sitesLine(gpa, hosts.items));
    }
    const requested = objc.msg(?objc.Object, found, "requestedPermissions", .{});
    for (words) |w| if (setHas(requested, w[0]) and !has(added.items, w[0])) try out.append(gpa, try gpa.dupe(u8, w[1]));
    for (kea_answered) |pair| if (has(declared.items, pair[0])) try out.append(gpa, try gpa.dupe(u8, pair[1]));
    return out.toOwnedSlice(gpa);
}

/// "Read and change what's on a, b, c, d and N more".
pub fn sitesLine(gpa: std.mem.Allocator, hosts: []const []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    try w.writer.writeAll("Read and change what's on ");
    for (hosts[0..@min(4, hosts.len)], 0..) |h, i| {
        if (i > 0) try w.writer.writeAll(", ");
        try w.writer.writeAll(h);
    }
    if (hosts.len > 4) try w.writer.print(" and {d} more", .{hosts.len - 4});
    return w.toOwnedSlice();
}

test "extension fence strings" {
    const gpa = std.testing.allocator;
    try std.testing.expect(othersPage("chrome-extension://other/p.html", "mine"));
    try std.testing.expect(!othersPage("chrome-extension://MINE/p.html", "mine"));
    try std.testing.expect(othersPage("webkit-extension://x/", "mine"));
    try std.testing.expect(!othersPage("https://x/", "mine"));
    try std.testing.expect(!othersPage(null, "mine"));
    const line = try sitesLine(gpa, &.{ "a", "b", "c", "d", "e", "f" });
    defer gpa.free(line);
    try std.testing.expectEqualStrings("Read and change what's on a, b, c, d and 2 more", line);
    try std.testing.expect(answered("downloads.open") and !answered("tabs"));
}
