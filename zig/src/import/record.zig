//! What was brought over from each browser, and when (ImportRecord.swift):
//! the sheet says so beside the browser, and "Replace" takes back out
//! exactly the bookmarks that came from it. Kept by the browser's name,
//! whichever profile, as JSON data under the defaults key `import.records`.
const std = @import("std");
const json = @import("../data/json.zig");
const Store = @import("../data/store.zig").Store;
const Uuid = json.Uuid;

pub const Record = struct {
    date: json.SwiftDate,
    bookmarks: i64 = 0,
    places: i64 = 0,
    passwords: i64 = 0,
    /// Every bookmark and folder an import from it added.
    bookmarkIDs: []const Uuid = &.{},
    /// Arc's spaces made, and its pins and pinned tabs brought. Absent in a
    /// record from before they were kept.
    spaces: ?i64 = null,
    pinned: ?i64 = null,
};

const key = "import.records";
const All = json.Map(Record);

/// What was noted of `name`, on `a` (an arena).
pub fn of(a: std.mem.Allocator, store: *const Store, name: []const u8) ?Record {
    const all = read(a, store);
    return all.map.get(name);
}

pub const Note = struct {
    ids: []const Uuid = &.{},
    bookmarks: i64 = 0,
    places: i64 = 0,
    passwords: i64 = 0,
    spaces: i64 = 0,
    pinned: i64 = 0,
};

/// What an import from `name` just added, on top of what was noted before.
pub fn note(gpa: std.mem.Allocator, store: *const Store, name: []const u8, n: Note) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var all = read(a, store);
    var r = all.map.get(name) orelse Record{ .date = json.now() };
    r.date = json.now();
    r.bookmarks += n.bookmarks;
    r.places += n.places;
    r.passwords += n.passwords;
    r.bookmarkIDs = try std.mem.concat(a, Uuid, &.{ r.bookmarkIDs, n.ids });
    if (n.spaces > 0) r.spaces = (r.spaces orelse 0) + n.spaces;
    if (n.pinned > 0) r.pinned = (r.pinned orelse 0) + n.pinned;
    try all.map.put(a, name, r);
    try write(a, store, all);
}

/// Its bookmarks taken back out: what is recorded of them goes too.
pub fn forgetBookmarks(gpa: std.mem.Allocator, store: *const Store, name: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var all = read(a, store);
    const r = all.map.getPtr(name) orelse return;
    r.bookmarkIDs = &.{};
    r.bookmarks = 0;
    try write(a, store, all);
}

fn read(a: std.mem.Allocator, store: *const Store) All {
    const bytes = store.data(key) orelse return .{};
    defer store.gpa.free(bytes);
    const parsed = json.decode(All, a, bytes) catch return .{};
    return parsed.value;
}

fn write(a: std.mem.Allocator, store: *const Store, all: All) !void {
    store.setData(key, try json.encode(a, all));
}
