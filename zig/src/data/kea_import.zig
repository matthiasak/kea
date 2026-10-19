//! The one-time "bring over from Kea" on first launch (replaces Carry.swift):
//! Kea's folder, WebKit data and defaults copied — never moved — into
//! KeaZig's. Runs in `Kea.create` before any store loads, and only for the
//! real folder (`opts.root == null`). The keychain is not touched.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const kea = @import("../app/kea.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn exit(code: c_int) noreturn;

const kea_bundle = "app.kea.browser";
const zig_bundle = "app.kea.zig";
/// Left in Kea's folder: its bench socket, its crash log, its AI cache.
const skipped = [_][]const u8{ "bench.sock", "crash.log", "AI" };

/// Offers the import when KeaZig's folder doesn't exist and Kea's does.
/// `suite` is the defaults KeaZig will use (null: its standard defaults).
pub fn offer(gpa: std.mem.Allocator, suite: ?[]const u8) void {
    const home: []const u8 = if (getenv("HOME")) |h| std.mem.span(h) else return;
    const support = std.fmt.allocPrint(gpa, "{s}/Library/Application Support", .{home}) catch return;
    defer gpa.free(support);
    const pool = objc.Pool.push();
    defer pool.pop();
    const ours = nsPath(support, "KeaZig");
    const theirs = nsPath(support, "Kea");
    if (exists(ours) or !exists(theirs)) return;

    const running = objc.msg(objc.Object, objc.class("NSRunningApplication"), "runningApplicationsWithBundleIdentifier:", .{objc.nsString(kea_bundle)});
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, app, "activateIgnoringOtherApps:", .{objc.YES});
    if (objc.msg(objc.NSUInteger, running, "count", .{}) > 0) {
        const first = ask("Quit Kea first", kea.app_name ++ " brings over your tabs, history, bookmarks, settings and sign-ins from Kea the first time it opens. Quit Kea, then open " ++ kea.app_name ++ " again.", "Quit " ++ kea.app_name, "Start Fresh");
        if (first) exit(0);
        makeDir(ours);
        return;
    }
    if (!ask("Bring over what Kea keeps?", null, "Bring It Over", "Start Fresh")) {
        makeDir(ours);
        return;
    }
    copyTree(objc.fromNSString(theirs), objc.fromNSString(ours), &skipped) catch {};
    const library = std.fmt.allocPrint(gpa, "{s}/Library", .{home}) catch return;
    defer gpa.free(library);
    for ([_][2][]const u8{
        .{ "WebKit/" ++ kea_bundle, "WebKit/" ++ zig_bundle },
        .{ "HTTPStorages/" ++ kea_bundle, "HTTPStorages/" ++ zig_bundle },
        .{ "HTTPStorages/" ++ kea_bundle ++ ".binarycookies", "HTTPStorages/" ++ zig_bundle ++ ".binarycookies" },
    }) |pair| copyItem(nsPath(library, pair[0]), nsPath(library, pair[1]));
    copyDefaults(suite);
}

/// Each top-level item of `src_root` not named in `skip` into `dst_root`
/// (created), unless something of that name is already there.
pub fn copyTree(src_root: []const u8, dst_root: []const u8, skip: []const []const u8) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = fileManager();
    const src = objc.nsString(src_root);
    const dst = objc.nsString(dst_root);
    makeDir(dst);
    if (!exists(dst)) return error.CopyFailed;
    const names = objc.msg(?objc.Object, fm, "contentsOfDirectoryAtPath:error:", .{ src, @as(?*anyopaque, null) }) orelse return error.CopyFailed;
    const n = objc.msg(objc.NSUInteger, names, "count", .{});
    outer: for (0..n) |i| {
        const name = objc.msg(objc.Object, names, "objectAtIndex:", .{i});
        const text = objc.fromNSString(name);
        for (skip) |s| if (std.mem.eql(u8, s, text)) continue :outer;
        copyItem(
            objc.msg(objc.Object, src, "stringByAppendingPathComponent:", .{name}),
            objc.msg(objc.Object, dst, "stringByAppendingPathComponent:", .{name}),
        );
    }
}

/// Every key of Kea's defaults domain but the system's own (`NS…`, `Apple…`),
/// save the first window's frame, which KeaZig autosaves under the same name.
fn copyDefaults(suite: ?[]const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const standard = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
    const domain = objc.msg(?objc.Object, standard, "persistentDomainForName:", .{objc.nsString(kea_bundle)}) orelse return;
    const target = if (suite) |s|
        objc.msg(objc.Object, objc.msg(objc.Object, objc.alloc("NSUserDefaults"), "initWithSuiteName:", .{objc.nsString(s)}), "autorelease", .{})
    else
        standard;
    const all = objc.msg(objc.Object, domain, "allKeys", .{});
    const n = objc.msg(objc.NSUInteger, all, "count", .{});
    for (0..n) |i| {
        const key = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
        if (!carried(objc.fromNSString(key))) continue;
        objc.msg(void, target, "setObject:forKey:", .{ objc.msg(objc.Object, domain, "objectForKey:", .{key}), key });
    }
}

pub fn carried(key: []const u8) bool {
    if (std.mem.eql(u8, key, "NSWindow Frame kea")) return true;
    return !std.mem.startsWith(u8, key, "NS") and !std.mem.startsWith(u8, key, "Apple");
}

/// A modal two-button alert; true for the first button.
fn ask(message: []const u8, info: ?[]const u8, first: []const u8, second: []const u8) bool {
    const alert = objc.new("NSAlert");
    defer objc.release(alert);
    objc.msg(void, alert, "setMessageText:", .{objc.nsString(message)});
    if (info) |text| objc.msg(void, alert, "setInformativeText:", .{objc.nsString(text)});
    _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString(first)});
    _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString(second)});
    // NSAlertFirstButtonReturn
    return objc.msg(objc.NSInteger, alert, "runModal", .{}) == 1000;
}

fn fileManager() objc.Object {
    return objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
}

fn nsPath(dir: []const u8, name: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.nsString(dir), "stringByAppendingPathComponent:", .{objc.nsString(name)});
}

fn exists(path: objc.Object) bool {
    return objc.msg(objc.BOOL, fileManager(), "fileExistsAtPath:", .{path});
}

fn makeDir(path: objc.Object) void {
    _ = objc.msg(objc.BOOL, fileManager(), "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
        path, objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
    });
}

/// `src` copied to `dst` when `src` exists and `dst` doesn't.
fn copyItem(src: objc.Object, dst: objc.Object) void {
    if (!exists(src) or exists(dst)) return;
    const url = objc.class("NSURL");
    _ = objc.msg(objc.BOOL, fileManager(), "copyItemAtURL:toURL:error:", .{
        objc.msg(objc.Object, url, "fileURLWithPath:", .{src}),
        objc.msg(objc.Object, url, "fileURLWithPath:", .{dst}),
        @as(?*anyopaque, null),
    });
}

test "copyTree copies and skips" {
    const Temp = @import("../tests/temp.zig").Temp;
    const disk = @import("disk.zig");
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    const src = try t.path(gpa, "Kea");
    defer gpa.free(src);
    const dst = try t.path(gpa, "KeaZig");
    defer gpa.free(dst);
    const pool = objc.Pool.push();
    defer pool.pop();
    const put = struct {
        fn put(dir: []const u8, name: []const u8, data: []const u8) void {
            const path = nsPath(dir, name);
            makeDir(objc.msg(objc.Object, path, "stringByDeletingLastPathComponent", .{}));
            const bytes = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ data.ptr, @as(objc.NSUInteger, data.len) });
            _ = objc.msg(objc.BOOL, bytes, "writeToFile:atomically:", .{ path, objc.YES });
        }
    }.put;
    put(src, "history.json", "[]");
    put(src, "chats/index.json", "{}");
    put(src, "crash.log", "boom");
    put(src, "bench.sock", "");
    put(src, "AI/cache/x", "x");
    put(src, "pins.json", "{\"theirs\":1}");
    // Already there: kept as is.
    put(dst, "pins.json", "{}");

    try copyTree(src, dst, &skipped);

    const Want = struct { name: []const u8, data: []const u8 };
    for ([_]Want{
        .{ .name = "/history.json", .data = "[]" },
        .{ .name = "/chats/index.json", .data = "{}" },
        .{ .name = "/pins.json", .data = "{}" },
    }) |w| {
        const path = try std.mem.concat(gpa, u8, &.{ dst, w.name });
        defer gpa.free(path);
        const got = disk.read(gpa, path) orelse return error.NotCopied;
        defer gpa.free(got);
        try std.testing.expectEqualStrings(w.data, got);
    }
    for ([_][]const u8{ "crash.log", "bench.sock", "AI" }) |gone| try std.testing.expect(!exists(nsPath(dst, gone)));
    // Copied, not moved.
    try std.testing.expect(exists(nsPath(src, "history.json")));
    try std.testing.expect(exists(nsPath(src, "AI/cache/x")));
    // A destination that doesn't exist yet is made, nested parents included.
    const fresh = try t.path(gpa, "new/KeaZig");
    defer gpa.free(fresh);
    try copyTree(src, fresh, &skipped);
    try std.testing.expect(exists(nsPath(fresh, "chats/index.json")));
    try std.testing.expect(!exists(nsPath(fresh, "AI")));
}

test "kea import carries app keys and the first window's frame" {
    try std.testing.expect(carried("sidebar.width"));
    try std.testing.expect(carried("NSWindow Frame kea"));
    try std.testing.expect(!carried("NSWindow Frame other"));
    try std.testing.expect(!carried("AppleLanguages"));
}
