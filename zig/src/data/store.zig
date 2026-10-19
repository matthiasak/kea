//! Where KeaZig keeps things (`Store` in Store.swift): its folder
//! (`opts.root`, else `~/Library/Application Support/KeaZig`), its defaults
//! (`opts.suite`, else the app's standard defaults), and the `Disk` every file
//! is written through.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("json.zig");
const disk = @import("disk.zig");
const Disk = disk.Disk;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const Store = struct {
    gpa: std.mem.Allocator,
    folder: []u8,
    /// Retained `NSUserDefaults`.
    defaults: objc.Object,
    disk: Disk,

    pub fn init(gpa: std.mem.Allocator, root: ?[]const u8, suite: ?[]const u8) !Store {
        const folder = if (root) |r| try gpa.dupe(u8, r) else blk: {
            const home: []const u8 = if (getenv("HOME")) |h| std.mem.span(h) else "/tmp";
            break :blk try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/KeaZig", .{home});
        };
        disk.makePath(gpa, folder);
        const pool = objc.Pool.push();
        defer pool.pop();
        const defaults = if (suite) |s|
            objc.msg(objc.Object, objc.alloc("NSUserDefaults"), "initWithSuiteName:", .{objc.nsString(s)})
        else
            objc.retain(objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{}));
        return .{ .gpa = gpa, .folder = folder, .defaults = defaults, .disk = Disk.init(gpa) };
    }

    pub fn deinit(self: *Store) void {
        self.disk.deinit();
        objc.release(self.defaults);
        self.gpa.free(self.folder);
    }

    /// `<folder>/<name>`; the caller frees it.
    pub fn file(self: *const Store, name: []const u8) ![]u8 {
        return std.fs.path.join(self.gpa, &.{ self.folder, name });
    }

    /// `<folder>/<sub>`, created; the caller frees it.
    pub fn folderFor(self: *const Store, sub: []const u8) ![]u8 {
        const p = try self.file(sub);
        disk.makePath(self.gpa, p);
        return p;
    }

    /// A file in the folder (or an absolute path), or null when it can't be read.
    pub fn readFile(self: *const Store, name: []const u8) ?[]u8 {
        if (std.fs.path.isAbsolute(name)) return disk.read(self.gpa, name);
        const p = self.file(name) catch return null;
        defer self.gpa.free(p);
        return disk.read(self.gpa, p);
    }

    /// `name` decoded; null when missing, and set aside when it won't decode.
    pub fn load(self: *Store, comptime T: type, name: []const u8) ?std.json.Parsed(T) {
        const bytes = self.readFile(name) orelse return null;
        defer self.gpa.free(bytes);
        return json.decode(T, self.gpa, bytes) catch {
            self.quarantine(name);
            return null;
        };
    }

    /// Sets `name` aside as `<name>.unreadable-<unix seconds>.json`.
    pub fn quarantine(self: *Store, name: []const u8) void {
        const p = self.file(name) catch return;
        defer self.gpa.free(p);
        disk.quarantine(self.gpa, p);
    }

    /// `value` encoded here and written in its turn (see `Disk.write`).
    pub fn save(self: *Store, name: []const u8, value: anytype, now: bool) void {
        const bytes = json.encode(self.gpa, value) catch return;
        self.write(name, bytes, now);
    }

    /// Already-encoded `bytes` (on `gpa`, freed by the disk) to `name`.
    pub fn write(self: *Store, name: []const u8, bytes: []u8, now: bool) void {
        const p = self.file(name) catch return self.gpa.free(bytes);
        defer self.gpa.free(p);
        self.disk.write(p, bytes, now);
    }

    // MARK: defaults

    pub fn hasKey(self: *const Store, key: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        return objc.msg(?objc.Object, self.defaults, "objectForKey:", .{objc.nsString(key)}) != null;
    }

    /// null when the key is absent, so callers keep Swift's own defaults.
    /// Called as `store.bool(key)`; only the declaration needs `@"bool"`.
    pub fn @"bool"(self: *const Store, key: []const u8) ?bool {
        if (!self.hasKey(key)) return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        return objc.msg(objc.BOOL, self.defaults, "boolForKey:", .{objc.nsString(key)});
    }

    pub fn int(self: *const Store, key: []const u8) ?i64 {
        if (!self.hasKey(key)) return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        return objc.msg(objc.NSInteger, self.defaults, "integerForKey:", .{objc.nsString(key)});
    }

    pub fn double(self: *const Store, key: []const u8) ?f64 {
        if (!self.hasKey(key)) return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        return objc.msg(f64, self.defaults, "doubleForKey:", .{objc.nsString(key)});
    }

    /// A copy on `gpa`, or null when absent or not a string.
    pub fn string(self: *const Store, key: []const u8) ?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = objc.msg(?objc.Object, self.defaults, "stringForKey:", .{objc.nsString(key)}) orelse return null;
        return self.gpa.dupe(u8, objc.fromNSString(s)) catch null;
    }

    /// The bytes of an `NSData` value, copied to `gpa`.
    pub fn data(self: *const Store, key: []const u8) ?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const d = objc.msg(?objc.Object, self.defaults, "dataForKey:", .{objc.nsString(key)}) orelse return null;
        const len = objc.msg(objc.NSUInteger, d, "length", .{});
        const out = self.gpa.alloc(u8, len) catch return null;
        if (len > 0) objc.msg(void, d, "getBytes:length:", .{ out.ptr, len });
        return out;
    }

    pub fn setBool(self: *const Store, key: []const u8, v: bool) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.defaults, "setBool:forKey:", .{ if (v) objc.YES else objc.NO, objc.nsString(key) });
    }

    pub fn setInt(self: *const Store, key: []const u8, v: i64) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.defaults, "setInteger:forKey:", .{ @as(objc.NSInteger, v), objc.nsString(key) });
    }

    pub fn setDouble(self: *const Store, key: []const u8, v: f64) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.defaults, "setDouble:forKey:", .{ v, objc.nsString(key) });
    }

    pub fn setString(self: *const Store, key: []const u8, v: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.defaults, "setObject:forKey:", .{ objc.nsString(v), objc.nsString(key) });
    }

    pub fn setData(self: *const Store, key: []const u8, v: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ v.ptr, @as(objc.NSUInteger, v.len) });
        objc.msg(void, self.defaults, "setObject:forKey:", .{ d, objc.nsString(key) });
    }

    pub fn remove(self: *const Store, key: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.defaults, "removeObjectForKey:", .{objc.nsString(key)});
    }
};

test "garbage is quarantined as .unreadable-<n>.json" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    const before: i64 = @intFromFloat(@floor(json.toUnix(json.now())));
    store.write("session.json", try gpa.dupe(u8, "{broken json"), true);
    try std.testing.expect(store.load(struct { tabs: []const u8 }, "session.json") == null);
    try std.testing.expect(store.readFile("session.json") == null);
    const after: i64 = @intFromFloat(@floor(json.toUnix(json.now())));
    var found = false;
    var n = before;
    while (n <= after) : (n += 1) {
        const name = try std.fmt.allocPrint(gpa, "session.unreadable-{d}.json", .{n});
        defer gpa.free(name);
        if (store.readFile(name)) |kept| {
            defer gpa.free(kept);
            try std.testing.expectEqualStrings("{broken json", kept);
            found = true;
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(store.load(struct { tabs: []const u8 }, "missing.json") == null);
}

test "store defaults and save round-trip" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    try std.testing.expect(store.bool("welcomed") == null);
    store.setBool("welcomed", true);
    store.setDouble("sidebar.width", 240);
    store.setInt("n", -3);
    store.setString("look", "dark");
    store.setData("search.keywords", "[]");
    try std.testing.expect(store.bool("welcomed").?);
    try std.testing.expectEqual(@as(f64, 240), store.double("sidebar.width").?);
    try std.testing.expectEqual(@as(i64, -3), store.int("n").?);
    const s = store.string("look").?;
    defer gpa.free(s);
    try std.testing.expectEqualStrings("dark", s);
    const d = store.data("search.keywords").?;
    defer gpa.free(d);
    try std.testing.expectEqualStrings("[]", d);
    store.remove("look");
    try std.testing.expect(!store.hasKey("look"));
    const V = struct { title: []const u8 };
    store.save("t.json", V{ .title = "He said \"hi\"" }, false);
    store.disk.drain();
    const back = store.load(V, "t.json").?;
    defer back.deinit();
    try std.testing.expectEqualStrings("He said \"hi\"", back.value.title);
}
