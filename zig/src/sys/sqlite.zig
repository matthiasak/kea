//! SQLite3 externs (libsqlite3, linked in build.zig) and the little the
//! importers need on top: a file opened read-only, statements stepped row by
//! row. Text and blobs read from a row live until the next step.
const std = @import("std");

const Handle = opaque {};
const Statement = opaque {};

pub const ok: c_int = 0;
pub const row: c_int = 100;
pub const done: c_int = 101;
pub const open_readonly: c_int = 0x1;
pub const open_readwrite: c_int = 0x2;
pub const open_create: c_int = 0x4;
/// `SQLITE_TRANSIENT`: SQLite copies the bound bytes.
const transient: isize = -1;

extern "c" fn sqlite3_open_v2(path: [*:0]const u8, db: *?*Handle, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(db: ?*Handle) c_int;
extern "c" fn sqlite3_exec(db: *Handle, sql: [*:0]const u8, cb: ?*anyopaque, ctx: ?*anyopaque, err: ?*?[*:0]u8) c_int;
extern "c" fn sqlite3_prepare_v2(db: *Handle, sql: [*]const u8, n: c_int, stmt: *?*Statement, tail: ?*?[*]const u8) c_int;
extern "c" fn sqlite3_finalize(stmt: ?*Statement) c_int;
extern "c" fn sqlite3_reset(stmt: *Statement) c_int;
extern "c" fn sqlite3_step(stmt: *Statement) c_int;
extern "c" fn sqlite3_bind_text(stmt: *Statement, i: c_int, text: [*]const u8, n: c_int, destructor: isize) c_int;
extern "c" fn sqlite3_bind_blob(stmt: *Statement, i: c_int, bytes: ?*const anyopaque, n: c_int, destructor: isize) c_int;
extern "c" fn sqlite3_bind_int64(stmt: *Statement, i: c_int, v: i64) c_int;
extern "c" fn sqlite3_column_text(stmt: *Statement, i: c_int) ?[*:0]const u8;
extern "c" fn sqlite3_column_blob(stmt: *Statement, i: c_int) ?[*]const u8;
extern "c" fn sqlite3_column_bytes(stmt: *Statement, i: c_int) c_int;
extern "c" fn sqlite3_column_int64(stmt: *Statement, i: c_int) i64;

pub const Db = struct {
    handle: *Handle,

    /// `path` opened with `flags` (`open_readonly` by default).
    pub fn open(path: []const u8, flags: c_int) !Db {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.mem.printSentinel(&buf, "{s}", .{path}, 0) catch return error.Unreadable;
        var h: ?*Handle = null;
        if (sqlite3_open_v2(z, &h, flags, null) != ok or h == null) {
            _ = sqlite3_close(h);
            return error.Unreadable;
        }
        return .{ .handle = h.? };
    }

    pub fn close(db: Db) void {
        _ = sqlite3_close(db.handle);
    }

    /// Statements with no rows to read (tests build their files with it).
    pub fn exec(db: Db, sql: [:0]const u8) !void {
        if (sqlite3_exec(db.handle, sql, null, null, null) != ok) return error.Unreadable;
    }

    pub fn prepare(db: Db, sql: []const u8) !Stmt {
        var s: ?*Statement = null;
        if (sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &s, null) != ok or s == null) {
            _ = sqlite3_finalize(s);
            return error.Unreadable;
        }
        return .{ .handle = s.? };
    }
};

pub const Stmt = struct {
    handle: *Statement,

    pub fn finalize(s: Stmt) void {
        _ = sqlite3_finalize(s.handle);
    }

    pub fn reset(s: Stmt) void {
        _ = sqlite3_reset(s.handle);
    }

    /// Whether a row came; false at the end or on an error.
    pub fn step(s: Stmt) bool {
        return sqlite3_step(s.handle) == row;
    }

    /// Runs a statement that returns no rows.
    pub fn run(s: Stmt) !void {
        if (sqlite3_step(s.handle) != done) return error.Unreadable;
    }

    /// 1-based, as SQLite counts parameters.
    pub fn bindText(s: Stmt, i: c_int, value: []const u8) void {
        _ = sqlite3_bind_text(s.handle, i, value.ptr, @intCast(value.len), transient);
    }

    pub fn bindBlob(s: Stmt, i: c_int, bytes: []const u8) void {
        _ = sqlite3_bind_blob(s.handle, i, bytes.ptr, @intCast(bytes.len), transient);
    }

    pub fn bindInt(s: Stmt, i: c_int, v: i64) void {
        _ = sqlite3_bind_int64(s.handle, i, v);
    }

    /// Null for SQL NULL.
    pub fn text(s: Stmt, i: c_int) ?[]const u8 {
        const p = sqlite3_column_text(s.handle, i) orelse return null;
        return p[0..@intCast(sqlite3_column_bytes(s.handle, i))];
    }

    /// Empty for NULL or a zero-length blob.
    pub fn blob(s: Stmt, i: c_int) []const u8 {
        const p = sqlite3_column_blob(s.handle, i) orelse return &.{};
        return p[0..@intCast(sqlite3_column_bytes(s.handle, i))];
    }

    pub fn int(s: Stmt, i: c_int) i64 {
        return sqlite3_column_int64(s.handle, i);
    }
};
