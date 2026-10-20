//! What the importers ask of the file system, through `NSFileManager` (safe
//! off the main thread), and `Snapshot` (Import.swift): a copy of another
//! browser's SQLite file with its `-wal` and `-shm`, read in a scratch folder
//! of this process's own (`ImportFile.scratchFolder`), gone with the copy.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");

extern "c" fn NSTemporaryDirectory() objc.Object;
extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn __error() *c_int;
const EPERM = 1;

fn fm() objc.Object {
    return objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
}

pub fn exists(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return objc.msg(objc.BOOL, fm(), "fileExistsAtPath:", .{objc.nsString(path)});
}

pub fn isDir(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    var dir: objc.BOOL = false;
    return objc.msg(objc.BOOL, fm(), "fileExistsAtPath:isDirectory:", .{ objc.nsString(path), &dir }) and dir;
}

/// `a/b` on `gpa`.
pub fn join(gpa: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ a, b });
}

/// The names in `dir` but hidden ones (`.skipsHiddenFiles`), sorted bytewise;
/// empty when it can't be listed. Free with `freeList`.
pub fn list(gpa: std.mem.Allocator, dir: []const u8) ![][]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, out.items);
    errdefer out.deinit(gpa);
    const names = objc.msg(?objc.Object, fm(), "contentsOfDirectoryAtPath:error:", .{ objc.nsString(dir), @as(?*anyopaque, null) }) orelse return out.toOwnedSlice(gpa);
    const n = objc.msg(objc.NSUInteger, names, "count", .{});
    for (0..n) |i| {
        const name = objc.fromNSString(objc.msg(objc.Object, names, "objectAtIndex:", .{i}));
        if (name.len == 0 or name[0] == '.') continue;
        try out.append(gpa, try gpa.dupe(u8, name));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn less(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, names: []const []u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

/// When the file last changed, in unix seconds; `-inf` when unknown
/// (`.distantPast`).
pub fn modified(path: []const u8) f64 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const attrs = objc.msg(?objc.Object, fm(), "attributesOfItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) }) orelse return -std.math.inf(f64);
    const date = objc.msg(?objc.Object, attrs, "fileModificationDate", .{}) orelse return -std.math.inf(f64);
    return objc.msg(f64, date, "timeIntervalSince1970", .{});
}

/// The file's size in bytes, or null.
pub fn size(path: []const u8) ?u64 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const attrs = objc.msg(?objc.Object, fm(), "attributesOfItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) }) orelse return null;
    return objc.msg(c_ulonglong, attrs, "fileSize", .{});
}

/// Whether `path` is a symbolic link itself.
pub fn isLink(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const attrs = objc.msg(?objc.Object, fm(), "attributesOfItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) }) orelse return false;
    const kind = objc.msg(?objc.Object, attrs, "fileType", .{}) orelse return false;
    return std.mem.eql(u8, objc.fromNSString(kind), "NSFileTypeSymbolicLink");
}

pub fn remove(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.BOOL, fm(), "removeItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) });
}

fn makeDir(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return objc.msg(objc.BOOL, fm(), "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
        objc.nsString(path), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
    });
}

fn copy(src: []const u8, dst: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return objc.msg(objc.BOOL, fm(), "copyItemAtPath:toPath:error:", .{ objc.nsString(src), objc.nsString(dst), @as(?*anyopaque, null) });
}

fn temporary(gpa: std.mem.Allocator) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    return gpa.dupe(u8, std.mem.trimEnd(u8, objc.fromNSString(NSTemporaryDirectory()), "/"));
}

const prefix = "kea-import-";

/// A folder of its own for what an import unpacks or copies, named for this
/// process (`kea-import-<pid>-<UUID>`) so another copy running beside it
/// never takes it for a leftover. Not made yet. On `gpa`.
pub fn scratchFolder(gpa: std.mem.Allocator) ![]u8 {
    const tmp = try temporary(gpa);
    defer gpa.free(tmp);
    return std.fmt.allocPrint(gpa, "{s}/" ++ prefix ++ "{d}-{s}", .{ tmp, getpid(), &json.Uuid.random().string() });
}

/// At launch: scratch folders an import left behind when the app stopped in
/// the middle of it — a process that is gone, or an unnamed one a day old.
pub fn sweepScratch(gpa: std.mem.Allocator) void {
    const tmp = temporary(gpa) catch return;
    defer gpa.free(tmp);
    const names = list(gpa, tmp) catch return;
    defer freeList(gpa, names);
    const now = json.toUnix(json.now());
    for (names) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const folder = join(gpa, tmp, name) catch continue;
        defer gpa.free(folder);
        const rest = name[prefix.len..];
        const dash = std.mem.indexOfScalar(u8, rest, '-');
        const pid: ?c_int = if (dash) |d| std.fmt.parseInt(c_int, rest[0..d], 10) catch null else null;
        if (pid) |p| {
            // Still running — this one, or another beside it: its own.
            if (p == getpid() or kill(p, 0) == 0 or __error().* == EPERM) continue;
        } else if (now - modified(folder) <= 86_400) continue;
        remove(folder);
    }
}

/// A copy of one of another browser's SQLite files, with the two files
/// SQLite keeps beside it while the browser runs: what was written last is
/// often still in `-wal`. `deinit` removes it.
pub const Snapshot = struct {
    gpa: std.mem.Allocator,
    folder: []u8,
    file: []u8,

    pub fn init(gpa: std.mem.Allocator, source: []const u8) !Snapshot {
        const folder = try scratchFolder(gpa);
        errdefer gpa.free(folder);
        if (!makeDir(folder)) return error.Unreadable;
        errdefer remove(folder);
        const file = try join(gpa, folder, std.fs.path.basename(source));
        errdefer gpa.free(file);
        if (!copy(source, file)) return error.Unreadable;
        for ([_][]const u8{ "-wal", "-shm" }) |side| {
            const beside = try std.mem.concat(gpa, u8, &.{ source, side });
            defer gpa.free(beside);
            if (!exists(beside)) continue;
            const to = try std.mem.concat(gpa, u8, &.{ file, side });
            defer gpa.free(to);
            _ = copy(beside, to);
        }
        return .{ .gpa = gpa, .folder = folder, .file = file };
    }

    pub fn deinit(s: *Snapshot) void {
        remove(s.folder);
        s.gpa.free(s.file);
        s.gpa.free(s.folder);
    }
};
