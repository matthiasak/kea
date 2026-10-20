//! Throwaway state for one test: a folder `kea-test-<16 hex>` under
//! `NSTemporaryDirectory()` holding the Application Support root (`support/`)
//! and the defaults suite. The suite is named by path,
//! `<folder>/app.kea.zig.test.<16 hex>`, so cfprefsd keeps its plist there
//! and never in `~/Library/Preferences`. `deinit` removes all of it.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

extern "c" fn arc4random_buf(buf: [*]u8, n: usize) void;
extern "c" fn NSTemporaryDirectory() objc.Object;

pub const Temp = struct {
    folder: []u8,
    root: []u8,
    suite: []u8,

    pub fn init(gpa: std.mem.Allocator) !Temp {
        const pool = objc.Pool.push();
        defer pool.pop();
        var bytes: [8]u8 = undefined;
        arc4random_buf(&bytes, bytes.len);
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const tmp = std.mem.trimEnd(u8, objc.fromNSString(NSTemporaryDirectory()), "/");
        const folder = try std.fmt.allocPrint(gpa, "{s}/kea-test-{s}", .{ tmp, &hex });
        errdefer gpa.free(folder);
        const root = try std.fmt.allocPrint(gpa, "{s}/support", .{folder});
        errdefer gpa.free(root);
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        if (!objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
            objc.nsString(root), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
        })) return error.TempDir;
        const suite = try std.fmt.allocPrint(gpa, "{s}/app.kea.zig.test.{s}", .{ folder, &hex });
        return .{ .folder = folder, .root = root, .suite = suite };
    }

    /// The path of `name` inside the root, on `gpa`.
    pub fn path(t: Temp, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ t.root, name });
    }

    pub fn deinit(t: *Temp, gpa: std.mem.Allocator) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const defaults = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
        objc.msg(void, defaults, "removePersistentDomainForName:", .{objc.nsString(t.suite)});
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        _ = objc.msg(objc.BOOL, fm, "removeItemAtPath:error:", .{ objc.nsString(t.folder), @as(?*anyopaque, null) });
        gpa.free(t.folder);
        gpa.free(t.root);
        gpa.free(t.suite);
    }
};
