//! The list of spaces (`Spaces.swift` model): `spaces.json`, the first
//! space always first, made on the spot when there is no list yet.
const std = @import("std");
const json = @import("json.zig");
const Store = @import("store.zig").Store;
const Kea = @import("../app/kea.zig").Kea;
const Uuid = json.Uuid;

const file = "spaces.json";

pub const Space = struct {
    id: Uuid,
    name: []const u8,
    /// Which of `colours` — from before spaces had icons.
    colour: i64,
    /// One of `icons`.
    icon: ?[]const u8 = null,
    /// Signed in wherever the first space is; nil, from before the choice,
    /// is a store of its own.
    sharesSignIns: ?bool = null,
    /// Where this space's downloads go; nil for the folder in Settings.
    downloads: ?[]const u8 = null,

    pub fn isFirst(self: Space) bool {
        return self.id.eql(Uuid.first);
    }

    /// Its own icon, or a house for the first and a briefcase for any other.
    pub fn symbol(self: Space) []const u8 {
        if (self.icon) |i| for (icons) |known| if (std.mem.eql(u8, i, known)) return i;
        return if (self.isFirst()) "house" else "briefcase";
    }
};

/// sRGB, slate blue green orange red violet.
pub const colours = [_][3]f32{
    .{ 0.45, 0.47, 0.52 }, .{ 0.26, 0.52, 0.96 }, .{ 0.20, 0.66, 0.45 },
    .{ 0.96, 0.62, 0.20 }, .{ 0.90, 0.33, 0.40 }, .{ 0.62, 0.40, 0.90 },
};
pub const colour_names = [_][]const u8{ "Slate", "Blue", "Green", "Orange", "Red", "Violet" };

pub const icons = [_][]const u8{
    "briefcase",    "building.2",         "desktopcomputer", "laptopcomputer", "chevron.left.forwardslash.chevron.right", "terminal",
    "sparkles",     "brain.head.profile", "lightbulb",       "gamecontroller", "beach.umbrella",                          "cup.and.saucer",
    "music.note",   "film",               "paintpalette",    "camera",         "house",                                   "book",
    "graduationcap", "cart",              "airplane",        "dumbbell",       "leaf",                                    "heart",
};
pub const icon_names = [_][]const u8{
    "Work",    "Office",   "Desktop", "Laptop", "Code",    "Terminal",
    "AI",      "Thinking", "Ideas",   "Games",  "Leisure", "Café",
    "Music",   "Film",     "Art",     "Photos", "Home",    "Reading",
    "Studies", "Shopping", "Travel",  "Sport",  "Nature",  "Personal",
};

/// Every space, the first one first.
pub fn read(store: *Store) std.json.Parsed([]Space) {
    var p = store.load([]Space, file) orelse
        (json.decode([]Space, store.gpa, "[]") catch @panic("OOM"));
    const saved = p.value;
    const out = p.arena.allocator().alloc(Space, saved.len + 1) catch @panic("OOM");
    out[0] = .{ .id = Uuid.first, .name = "Personal", .colour = 0 };
    var n: usize = 1;
    for (saved) |s| {
        if (s.isFirst()) out[0] = s else {
            out[n] = s;
            n += 1;
        }
    }
    p.value = out[0..n];
    return p;
}

/// Written at once, then every window's list follows.
pub fn write(kea: *Kea, list: []const Space) void {
    kea.store.save(file, list, true);
    kea.spacesChanged();
}

// MARK: tests

const testing = std.testing;
const Temp = @import("../tests/temp.zig").Temp;

test "spaces fixture round-trips" {
    const bytes = @embedFile("../tests/fixtures/kea/spaces.json");
    const a = try json.decode([]Space, testing.allocator, bytes);
    defer a.deinit();
    const out = try json.encode(testing.allocator, a.value);
    defer testing.allocator.free(out);
    const b = try json.decode([]Space, testing.allocator, out);
    defer b.deinit();
    const again = try json.encode(testing.allocator, b.value);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
    try testing.expectEqualStrings("briefcase", a.value[2].symbol());
    try testing.expectEqualStrings("house", a.value[1].symbol());
    // nil optionals are omitted
    try testing.expect(std.mem.indexOf(u8, out, "null") == null);
}

test "spaces read puts the first first and makes it when missing" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var store = try Store.init(testing.allocator, t.root, t.suite);
    defer store.deinit();
    {
        const r = read(&store);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.value.len);
        try testing.expectEqualStrings("Personal", r.value[0].name);
    }
    store.write(file, try testing.allocator.dupe(u8, @embedFile("../tests/fixtures/kea/spaces.json")), true);
    const r = read(&store);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 3), r.value.len);
    try testing.expect(r.value[0].isFirst());
    try testing.expectEqualStrings("Work", r.value[1].name);
}
