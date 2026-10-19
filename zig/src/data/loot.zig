//! What you have kept (`Loot` in Loot.swift): the memory of downloads in
//! `downloads.json`, newest first, fifty at most. The files are the user's;
//! forgetting only empties the list.
const std = @import("std");
const json = @import("json.zig");
const Store = @import("store.zig").Store;

pub const Keep = struct {
    name: []const u8,
    from: []const u8,
    path: []const u8,
    date: json.SwiftDate,
};

pub const Loot = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    /// Owns `kept`.
    arena: std.heap.ArenaAllocator,
    kept: []const Keep = &.{},

    pub const file = "downloads.json";
    /// Fifty is more than anybody scrolls back through.
    pub const most = 50;

    pub fn init(gpa: std.mem.Allocator, store: *Store) Loot {
        var self: Loot = .{ .gpa = gpa, .store = store, .arena = .init(gpa) };
        if (store.load([]const Keep, file)) |p| {
            defer p.deinit();
            self.kept = json.clone(self.arena.allocator(), p.value) catch &.{};
        }
        return self;
    }

    pub fn deinit(self: *Loot) void {
        self.arena.deinit();
    }

    /// First, replacing one at the same path.
    pub fn add(self: *Loot, keep: Keep) void {
        var list: std.ArrayList(Keep) = .empty;
        defer list.deinit(self.gpa);
        list.append(self.gpa, keep) catch return;
        for (self.kept) |k| if (!std.mem.eql(u8, k.path, keep.path)) list.append(self.gpa, k) catch return;
        self.set(list.items[0..@min(list.items.len, most)]);
    }

    /// The one at `path` (its id).
    pub fn forget(self: *Loot, path: []const u8) void {
        var list: std.ArrayList(Keep) = .empty;
        defer list.deinit(self.gpa);
        for (self.kept) |k| if (!std.mem.eql(u8, k.path, path)) list.append(self.gpa, k) catch return;
        self.set(list.items);
    }

    pub fn forgetAll(self: *Loot) void {
        self.set(&.{});
    }

    /// `list` (which may point into the old snapshot) kept and saved.
    fn set(self: *Loot, list: []const Keep) void {
        var next: std.heap.ArenaAllocator = .init(self.gpa);
        const copy = json.clone(next.allocator(), list) catch return next.deinit();
        self.arena.deinit();
        self.arena = next;
        self.kept = copy;
        self.store.save(file, self.kept, false);
    }
};

test "downloads fixture round-trips" {
    try @import("../tests/roundtrip.zig").check([]const Keep, @embedFile("../tests/fixtures/kea/downloads.json"), false);
}

test "loot keeps fifty newest first and replaces the same path" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    store.write(Loot.file, try gpa.dupe(u8, @embedFile("../tests/fixtures/kea/downloads.json")), true);
    var loot = Loot.init(gpa, &store);
    defer loot.deinit();
    try std.testing.expectEqual(@as(usize, 2), loot.kept.len);
    var buf: [32]u8 = undefined;
    for (0..60) |i| {
        const p = try std.fmt.bufPrint(&buf, "/tmp/f{d}", .{i});
        loot.add(.{ .name = p[5..], .from = "https://site/", .path = p, .date = @floatFromInt(i) });
    }
    try std.testing.expectEqual(@as(usize, Loot.most), loot.kept.len);
    try std.testing.expectEqualStrings("/tmp/f59", loot.kept[0].path);
    loot.add(.{ .name = "again", .from = "", .path = "/tmp/f30", .date = 99 });
    try std.testing.expectEqualStrings("again", loot.kept[0].name);
    try std.testing.expectEqual(@as(usize, Loot.most), loot.kept.len);
    loot.forget("/tmp/f30");
    try std.testing.expectEqual(@as(usize, Loot.most - 1), loot.kept.len);
    store.disk.drain();
    var again = Loot.init(gpa, &store);
    defer again.deinit();
    try std.testing.expectEqualDeep(loot.kept, again.kept);
    loot.forgetAll();
    try std.testing.expectEqual(@as(usize, 0), loot.kept.len);
}
