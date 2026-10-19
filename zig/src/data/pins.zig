//! Pins, the same in every window (`Pins.swift`): `pins.json` holds
//! `{spaceUUID: [PinDef]}`. Before there is one, the pins come from every
//! space's session file.
const std = @import("std");
const json = @import("json.zig");
const session = @import("session.zig");
const spaces = @import("spaces.zig");
const Store = @import("store.zig").Store;
const Uuid = json.Uuid;

const file = "pins.json";

pub const PinDef = struct {
    id: Uuid,
    letter: []const u8,
    /// The page it was pinned at.
    home: []const u8,
    title: []const u8,
    name: ?[]const u8 = null,
    /// A row, not a square. Nil rather than false.
    listed: ?bool = null,
};

/// A space's pins, owning their strings.
const Row = struct {
    arena: std.heap.ArenaAllocator,
    defs: []PinDef,
};

pub const Pins = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    loaded: bool = false,
    by_space: std.AutoArrayHashMapUnmanaged(Uuid, Row) = .empty,

    pub fn init(gpa: std.mem.Allocator, store: *Store) Pins {
        return .{ .gpa = gpa, .store = store };
    }

    pub fn deinit(self: *Pins) void {
        for (self.by_space.values()) |*r| r.arena.deinit();
        self.by_space.deinit(self.gpa);
    }

    /// A space's pins, in order; valid until the next change to that space.
    pub fn defs(self: *Pins, space: Uuid) []const PinDef {
        self.load();
        const r = self.by_space.getPtr(space) orelse return &.{};
        return r.defs;
    }

    /// A window's pins for a space, as they now are. True when they differ
    /// from what was there, so the caller tells the other windows.
    pub fn set(self: *Pins, space: Uuid, list: []const PinDef) bool {
        self.load();
        if (same(self.gpa, self.defs(space), list)) return false;
        self.put(space, list);
        self.save();
        return true;
    }

    /// Every space's pins at once (sync, import); spaces left out lose theirs.
    pub fn replaceAll(self: *Pins, map: []const struct { space: Uuid, defs: []const PinDef }) void {
        self.load();
        self.clear();
        for (map) |e| self.put(e.space, e.defs);
        self.save();
    }

    /// A space deleted: its pins go with it.
    pub fn forget(self: *Pins, space: Uuid) void {
        var kv = self.by_space.fetchSwapRemove(space) orelse return;
        kv.value.arena.deinit();
        self.save();
    }

    /// Read once.
    pub fn load(self: *Pins) void {
        if (self.loaded) return;
        self.loaded = true;
        if (self.store.readFile(file)) |bytes| {
            defer self.gpa.free(bytes);
            if (json.decode(json.Map([]PinDef), self.gpa, bytes)) |saved| {
                defer saved.deinit();
                var it = saved.value.map.iterator();
                while (it.next()) |e| {
                    const space = Uuid.parse(e.key_ptr.*) catch continue;
                    self.put(space, e.value_ptr.*);
                }
                return;
            } else |_| self.store.quarantine(file);
        }
        const list = spaces.read(self.store);
        defer list.deinit();
        for (list.value) |sp| {
            const row = session.read(self.store, sp.id);
            defer row.deinit();
            var found: std.ArrayList(PinDef) = .empty;
            defer found.deinit(self.gpa);
            for (row.value.tabs) |e| {
                const letter = e.pin orelse continue;
                found.append(self.gpa, .{
                    .id = e.pinID orelse Uuid.random(),
                    .letter = letter,
                    .home = e.home orelse e.url,
                    .title = e.title,
                    .name = e.name,
                }) catch @panic("OOM");
            }
            self.put(sp.id, found.items);
        }
        self.save();
    }

    fn clear(self: *Pins) void {
        for (self.by_space.values()) |*r| r.arena.deinit();
        self.by_space.clearRetainingCapacity();
    }

    /// Copies `list` in; an empty list removes the space.
    fn put(self: *Pins, space: Uuid, list: []const PinDef) void {
        if (list.len == 0) {
            if (self.by_space.fetchSwapRemove(space)) |old| {
                var o = old;
                o.value.arena.deinit();
            }
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        const a = arena.allocator();
        const out = a.alloc(PinDef, list.len) catch @panic("OOM");
        for (list, out) |d, *o| o.* = .{
            .id = d.id,
            .letter = a.dupe(u8, d.letter) catch @panic("OOM"),
            .home = a.dupe(u8, d.home) catch @panic("OOM"),
            .title = a.dupe(u8, d.title) catch @panic("OOM"),
            .name = if (d.name) |n| a.dupe(u8, n) catch @panic("OOM") else null,
            .listed = d.listed,
        };
        const kept = self.by_space.fetchSwapRemove(space);
        self.by_space.put(self.gpa, space, .{ .arena = arena, .defs = out }) catch @panic("OOM");
        if (kept) |old| {
            var o = old;
            o.value.arena.deinit();
        }
    }

    fn save(self: *Pins) void {
        var map: json.Map([]const PinDef) = .{};
        defer map.deinit(self.gpa);
        var keys: std.ArrayList([36]u8) = .empty;
        defer keys.deinit(self.gpa);
        keys.ensureTotalCapacity(self.gpa, self.by_space.count()) catch return;
        for (self.by_space.keys(), self.by_space.values()) |k, v| {
            keys.appendAssumeCapacity(k.string());
            map.map.put(self.gpa, &keys.items[keys.items.len - 1], v.defs) catch return;
        }
        self.store.save(file, map, false);
    }
};

fn same(gpa: std.mem.Allocator, a: []const PinDef, b: []const PinDef) bool {
    const x = json.encode(gpa, a) catch return false;
    defer gpa.free(x);
    const y = json.encode(gpa, b) catch return false;
    defer gpa.free(y);
    return std.mem.eql(u8, x, y);
}

// MARK: tests

const testing = std.testing;
const Temp = @import("../tests/temp.zig").Temp;

test "pins fixture round-trips" {
    const bytes = @embedFile("../tests/fixtures/kea/pins.json");
    const a = try json.decode(json.Map([]PinDef), testing.allocator, bytes);
    defer a.deinit();
    const out = try json.encode(testing.allocator, a.value);
    defer testing.allocator.free(out);
    const b = try json.decode(json.Map([]PinDef), testing.allocator, out);
    defer b.deinit();
    const again = try json.encode(testing.allocator, b.value);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "pins load from file, skip bad keys, set and forget" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var store = try Store.init(testing.allocator, t.root, t.suite);
    defer store.deinit();
    store.write(file, try testing.allocator.dupe(u8, @embedFile("../tests/fixtures/kea/pins.json")), true);
    var pins = Pins.init(testing.allocator, &store);
    defer pins.deinit();
    try testing.expectEqual(@as(usize, 2), pins.defs(Uuid.first).len);
    try testing.expectEqual(@as(usize, 2), pins.by_space.count());
    const work = try Uuid.parse("5E4C0000-ABCD-4000-8000-00000000002A");
    try testing.expectEqualStrings("Work \"wiki\"", pins.defs(work)[0].title);
    try testing.expect(!pins.set(work, pins.defs(work)));
    try testing.expect(pins.set(work, &.{}));
    pins.forget(Uuid.first);
    store.disk.drain();
    var again = Pins.init(testing.allocator, &store);
    defer again.deinit();
    try testing.expectEqual(@as(usize, 0), again.defs(Uuid.first).len);
}

test "pins come from session files before pins.json" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var store = try Store.init(testing.allocator, t.root, t.suite);
    defer store.deinit();
    const tabs = [_]session.Entry{
        .{ .url = "https://a.com/x", .title = "A", .pin = "A", .home = "https://a.com/" },
        .{ .url = "https://b.com/", .title = "B" },
    };
    session.write(&store, Uuid.first, .{ .tabs = &tabs, .active = 0 }, true);
    var pins = Pins.init(testing.allocator, &store);
    defer pins.deinit();
    const d = pins.defs(Uuid.first);
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqualStrings("https://a.com/", d[0].home);
}
