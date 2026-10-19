//! Storage paths (`opts.root`, else `~/Library/Application Support/KeaZig`),
//! the defaults suite, corrupt JSON quarantine (`*.corrupt`), and atomic writes.
const std = @import("std");
const c = struct {
    pub const FILE = opaque {};
    pub const SEEK_SET: c_int = 0;
    pub const SEEK_END: c_int = 2;
    pub const F_OK: c_int = 0;
    pub extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    pub extern "c" fn mkdir(path: [*]const u8, mode: u16) c_int;
    pub extern "c" fn fopen(path: [*]const u8, mode: [*:0]const u8) ?*FILE;
    pub extern "c" fn fclose(stream: *FILE) c_int;
    pub extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
    pub extern "c" fn ftell(stream: *FILE) c_long;
    pub extern "c" fn fread(ptr: [*]u8, size: usize, nitems: usize, stream: *FILE) usize;
    pub extern "c" fn fwrite(ptr: [*]const u8, size: usize, nitems: usize, stream: *FILE) usize;
    pub extern "c" fn rename(old: [*]const u8, new: [*]const u8) c_int;
    pub extern "c" fn unlink(path: [*]const u8) c_int;
    pub extern "c" fn access(path: [*]const u8, mode: c_int) c_int;
};

pub fn cPath(buf: *[1024]u8, s: []const u8) ?[*]const u8 {
    if (s.len >= buf.len) return null;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf;
}
pub const Store = struct {
    gpa: std.mem.Allocator,
    folder: []u8,
    /// NSUserDefaults suite (tests); null is the app's standard defaults.
    suite: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, root: ?[]const u8, suite: ?[]const u8) !Store {
        const folder = if (root) |r| try gpa.dupe(u8, r) else blk: {
            const home: []const u8 = if (c.getenv("HOME")) |h| std.mem.span(h) else "/tmp";
            break :blk try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/KeaZig", .{home});
        };
        errdefer gpa.free(folder);
        ensureDir(folder);
        return .{
            .gpa = gpa,
            .folder = folder,
            .suite = if (suite) |s| try gpa.dupe(u8, s) else null,
        };
    }

    pub fn deinit(self: *Store) void {
        self.gpa.free(self.folder);
        if (self.suite) |s| self.gpa.free(s);
    }

    pub fn path(self: *const Store, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.folder, name });
    }

    pub fn read(self: *const Store, name: []const u8) ?[]u8 {
        const p = self.path(name) catch return null;
        defer self.gpa.free(p);
        return readFileAlloc(self.gpa, p);
    }

    pub fn writeAtomic(self: *const Store, name: []const u8, data: []const u8) void {
        ensureDir(self.folder);
        const final_p = self.path(name) catch return;
        defer self.gpa.free(final_p);
        const tmp_p = std.fmt.allocPrint(self.gpa, "{s}.tmp", .{final_p}) catch return;
        defer self.gpa.free(tmp_p);
        if (writeFile(tmp_p, data)) {
            var b1: [1024]u8 = undefined;
            var b2: [1024]u8 = undefined;
            const p1 = cPath(&b1, tmp_p) orelse return;
            const p2 = cPath(&b2, final_p) orelse return;
            _ = c.rename(p1, p2);
        }
    }

    /// Moves an unreadable JSON file to `<name>.corrupt` so a subsequent save
    /// never overwrites the user's broken file without leaving a copy.
    pub fn quarantine(self: *const Store, name: []const u8) void {
        const src = self.path(name) catch return;
        defer self.gpa.free(src);
        const dst = std.fmt.allocPrint(self.gpa, "{s}.corrupt", .{src}) catch return;
        defer self.gpa.free(dst);
        var b1: [1024]u8 = undefined;
        var b2: [1024]u8 = undefined;
        const p1 = cPath(&b1, src) orelse return;
        const p2 = cPath(&b2, dst) orelse return;
        _ = c.unlink(p2);
        _ = c.rename(p1, p2);
    }

    pub fn exists(self: *const Store, name: []const u8) bool {
        const p = self.path(name) catch return false;
        defer self.gpa.free(p);
        var b1: [1024]u8 = undefined;
        const pz = cPath(&b1, p) orelse return false;
        return c.access(pz, c.F_OK) == 0;
    }
};

pub fn ensureDir(dir_path: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (dir_path.len >= buf.len) return;
    @memcpy(buf[0..dir_path.len], dir_path);
    buf[dir_path.len] = 0;
    var i: usize = 1;
    while (i < dir_path.len) : (i += 1) {
        if (buf[i] == '/') {
            buf[i] = 0;
            _ = c.mkdir(&buf, 0o755);
            buf[i] = '/';
        }
    }
    _ = c.mkdir(&buf, 0o755);
}

pub fn readFileAlloc(gpa: std.mem.Allocator, file_path: []const u8) ?[]u8 {
    var b1: [1024]u8 = undefined;
    const pz = cPath(&b1, file_path) orelse return null;
    const f = c.fopen(pz, "rb") orelse return null;
    defer _ = c.fclose(f);
    if (c.fseek(f, 0, c.SEEK_END) != 0) return null;
    const len_long = c.ftell(f);
    if (len_long < 0) return null;
    if (c.fseek(f, 0, c.SEEK_SET) != 0) return null;
    const len: usize = @intCast(len_long);
    const buf = gpa.alloc(u8, len) catch return null;
    if (len > 0) {
        const n = c.fread(buf.ptr, 1, len, f);
        if (n != len) {
            gpa.free(buf);
            return null;
        }
    }
    return buf;
}

pub fn writeFile(file_path: []const u8, data: []const u8) bool {
    var buf: [1024]u8 = undefined;
    if (file_path.len >= buf.len) return false;
    @memcpy(buf[0..file_path.len], file_path);
    buf[file_path.len] = 0;
    const f = c.fopen(&buf, "wb") orelse return false;
    defer _ = c.fclose(f);
    if (data.len > 0) {
        const n = c.fwrite(data.ptr, 1, data.len, f);
        if (n != data.len) return false;
    }
    return true;
}
