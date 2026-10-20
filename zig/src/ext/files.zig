//! `ExtensionFiles` (ExtensionFiles.swift): replaces an extension folder
//! without removing the installed copy first.
const std = @import("std");
const objc = @import("nanoui").objc;

extern "c" fn renamex_np(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) c_int;
extern "c" fn __error() *c_int;

const RENAME_SWAP: c_uint = 0x2;
const RENAME_EXCL: c_uint = 0x4;

/// On success, an existing target is atomically swapped onto `staged`;
/// callers own cleaning up that old folder after releasing its consumers.
/// The error is the failed rename's errno by name (`error.EXIST`, …); say
/// it with `describe`.
pub fn replace(staged: []const u8, target: []const u8) anyerror!void {
    var a: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var b: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const from = std.fmt.bufPrintSentinel(&a, "{s}", .{staged}, 0) catch return error.INVAL;
    const to = std.fmt.bufPrintSentinel(&b, "{s}", .{target}, 0) catch return error.INVAL;
    const first = renameError(from, to, RENAME_EXCL) orelse return;
    if (first != .EXIST) return errorOf(first);
    if (renameError(from, to, RENAME_SWAP)) |e| return errorOf(e);
}

/// A nil result means the rename worked; errno is read at once, so it
/// describes the syscall that failed.
fn renameError(from: [*:0]const u8, to: [*:0]const u8, flags: c_uint) ?std.posix.E {
    if (renamex_np(from, to, flags) == 0) return null;
    return @enumFromInt(__error().*);
}

fn errorOf(e: std.posix.E) anyerror {
    const info = @typeInfo(std.posix.E).@"enum";
    inline for (info.field_names, info.field_values) |n, v| if (@intFromEnum(e) == v) return @field(anyerror, n);
    return error.Unexpected;
}

/// `replacementError`'s description: "Couldn't replace extension at
/// <target>: <the POSIX error's localizedDescription>", on `gpa`.
pub fn describe(gpa: std.mem.Allocator, err: anyerror, target: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const code: objc.NSInteger = if (std.meta.stringToEnum(std.posix.E, @errorName(err))) |e| @intFromEnum(e) else 0;
    const posix = objc.msg(objc.Object, objc.class("NSError"), "errorWithDomain:code:userInfo:", .{ objc.nsString("NSPOSIXErrorDomain"), code, @as(?objc.Object, null) });
    const why = objc.fromNSString(objc.msg(?objc.Object, posix, "localizedDescription", .{}));
    return std.fmt.allocPrint(gpa, "Couldn't replace extension at {s}: {s}", .{ target, why });
}

test "files replace swaps folders" {
    const gpa = std.testing.allocator;
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const base = try std.fmt.allocPrint(gpa, "/tmp/kea-files-test-{d}", .{std.c.getpid()});
    defer gpa.free(base);
    defer _ = objc.msg(objc.BOOL, fm, "removeItemAtPath:error:", .{ objc.nsString(base), @as(?*anyopaque, null) });
    const staged = try std.fmt.allocPrint(gpa, "{s}/staged", .{base});
    defer gpa.free(staged);
    const target = try std.fmt.allocPrint(gpa, "{s}/target", .{base});
    defer gpa.free(target);
    const mark = struct {
        fn make(m: objc.Object, dir: []const u8, name: []const u8) !void {
            _ = objc.msg(objc.BOOL, m, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{ objc.nsString(dir), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null) });
            var buf: [256]u8 = undefined;
            const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name });
            _ = objc.msg(objc.BOOL, m, "createFileAtPath:contents:attributes:", .{ objc.nsString(p), @as(?objc.Object, null), @as(?objc.Object, null) });
        }
        fn has(m: objc.Object, dir: []const u8, name: []const u8) bool {
            var buf: [256]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
            return objc.msg(objc.BOOL, m, "fileExistsAtPath:", .{objc.nsString(p)});
        }
    };
    // No target yet: a plain move.
    try mark.make(fm, staged, "new");
    try replace(staged, target);
    try std.testing.expect(mark.has(fm, target, "new"));
    try std.testing.expect(!mark.has(fm, staged, "new"));
    // A target there: swapped, the old copy left at `staged`.
    try mark.make(fm, staged, "newer");
    try replace(staged, target);
    try std.testing.expect(mark.has(fm, target, "newer"));
    try std.testing.expect(mark.has(fm, staged, "new"));
    // Nothing staged: the errno, said as Swift says it.
    const gone = try std.fmt.allocPrint(gpa, "{s}/missing", .{base});
    defer gpa.free(gone);
    const err = if (replace(gone, target)) |_| unreachable else |e| e;
    try std.testing.expectEqual(error.NOENT, err);
    const text = try describe(gpa, err, target);
    defer gpa.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "Couldn't replace extension at "));
}
