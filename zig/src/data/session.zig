//! What was open last time (`Session.swift`): `session.json` for the first
//! space, `session-<UUID>.json` beside it for every other. Read leniently
//! where Swift is: groups, split extras and an entry's ids never put the
//! whole file in quarantine; a file that won't decode at all does.
const std = @import("std");
const json = @import("json.zig");
const Store = @import("store.zig").Store;
const Uuid = json.Uuid;
const Value = std.json.Value;
const Opts = std.json.ParseOptions;

pub const Axis = enum { horizontal, vertical };

/// `TabGroup.swift`: saved without its folded state, a group is open.
pub const TabGroup = struct {
    id: Uuid,
    name: []const u8,
    collapsed: bool = false,

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, opts: Opts) !TabGroup {
        return viaValue(TabGroup, gpa, source, opts);
    }
    pub fn jsonParseFromValue(gpa: std.mem.Allocator, v: Value, opts: Opts) !TabGroup {
        const o = try object(v);
        return .{
            .id = try need(Uuid, gpa, o, "id", opts),
            .name = try need([]const u8, gpa, o, "name", opts),
            .collapsed = lenient(bool, gpa, o, "collapsed", opts) orelse false,
        };
    }
};

pub const Entry = struct {
    url: []const u8,
    title: []const u8,
    pin: ?[]const u8 = null,
    /// The name you gave the tab, when you gave it one.
    name: ?[]const u8 = null,
    /// A pin's own page, the one it was pinned at.
    home: ?[]const u8 = null,
    groupID: ?Uuid = null,
    pinID: ?Uuid = null,
    /// A pin kept as a row. Nil for a square.
    listed: ?bool = null,

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, opts: Opts) !Entry {
        return viaValue(Entry, gpa, source, opts);
    }
    pub fn jsonParseFromValue(gpa: std.mem.Allocator, v: Value, opts: Opts) !Entry {
        const o = try object(v);
        return .{
            .url = try need([]const u8, gpa, o, "url", opts),
            .title = try need([]const u8, gpa, o, "title", opts),
            .pin = try maybe([]const u8, gpa, o, "pin", opts),
            .name = try maybe([]const u8, gpa, o, "name", opts),
            .home = try maybe([]const u8, gpa, o, "home", opts),
            .groupID = lenient(Uuid, gpa, o, "groupID", opts),
            .pinID = lenient(Uuid, gpa, o, "pinID", opts),
            .listed = lenient(bool, gpa, o, "listed", opts),
        };
    }
};

/// A split, its pages by their place in `tabs`.
pub const Split = struct {
    tabs: []const i64,
    axis: Axis = .horizontal,
    sizes: []const f64,
    /// The page last focused, by its place in `tabs`.
    focused: ?i64 = null,

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, opts: Opts) !Split {
        return viaValue(Split, gpa, source, opts);
    }
    /// An axis this version doesn't know is side by side, and the first
    /// shape Split View was written in — left, right, fraction — still reads.
    pub fn jsonParseFromValue(gpa: std.mem.Allocator, v: Value, opts: Opts) !Split {
        const o = try object(v);
        var s: Split = .{ .tabs = &.{}, .sizes = &.{} };
        if (lenient([]const i64, gpa, o, "tabs", opts)) |tabs| {
            s.tabs = tabs;
            s.sizes = lenient([]const f64, gpa, o, "sizes", opts) orelse try even(gpa, tabs.len);
        } else {
            const left = try need(i64, gpa, o, "left", opts);
            const right = try need(i64, gpa, o, "right", opts);
            const fraction = lenient(f64, gpa, o, "fraction", opts) orelse 0.5;
            s.tabs = try gpa.dupe(i64, &.{ left, right });
            s.sizes = try gpa.dupe(f64, &.{ fraction, 1 - fraction });
        }
        s.axis = lenient(Axis, gpa, o, "axis", opts) orelse .horizontal;
        s.focused = lenient(i64, gpa, o, "focused", opts);
        return s;
    }
};

/// `TabSplit.even`: equal shares adding up to 1.
pub fn even(gpa: std.mem.Allocator, n: usize) ![]f64 {
    const out = try gpa.alloc(f64, n);
    @memset(out, 1 / @as(f64, @floatFromInt(@max(1, n))));
    return out;
}

pub const Shape = struct {
    tabs: []const Entry,
    active: i64,
    /// Nil in sessions written before tab groups existed.
    groups: ?[]const TabGroup = null,
    splits: []const Split = &.{},

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, opts: Opts) !Shape {
        return viaValue(Shape, gpa, source, opts);
    }
    pub fn jsonParseFromValue(gpa: std.mem.Allocator, v: Value, opts: Opts) !Shape {
        const o = try object(v);
        return .{
            .tabs = try need([]const Entry, gpa, o, "tabs", opts),
            .active = try need(i64, gpa, o, "active", opts),
            .groups = lenient([]const TabGroup, gpa, o, "groups", opts),
            .splits = lenient([]const Split, gpa, o, "splits", opts) orelse &.{},
        };
    }
};

/// `session.json` or `session-<UUID>.json`, in `buf`.
pub fn fileName(buf: *[49]u8, space: Uuid) []const u8 {
    if (space.eql(Uuid.first)) return "session.json";
    return std.fmt.bufPrint(buf, "session-{s}.json", .{&space.string()}) catch unreachable;
}

/// A space's row; empty (`active` 0) when there is no file, and the file set
/// aside when it won't decode — not the same as no file.
pub fn read(store: *Store, space: Uuid) std.json.Parsed(Shape) {
    var buf: [49]u8 = undefined;
    if (store.load(Shape, fileName(&buf, space))) |p| return p;
    return json.decode(Shape, store.gpa, "{\"tabs\":[],\"active\":0}") catch @panic("OOM");
}

/// `now` writes on the calling thread: quitting doesn't wait for a queue.
pub fn write(store: *Store, space: Uuid, shape: Shape, now: bool) void {
    var buf: [49]u8 = undefined;
    store.save(fileName(&buf, space), shape, now);
}

/// Settings › General › Start with a fresh window: each space's file keeps
/// its pins and nothing else, with no tab in front.
pub fn startFresh(store: *Store, spaces: []const Uuid) void {
    for (spaces) |space| {
        const shape = read(store, space);
        defer shape.deinit();
        var pins: std.ArrayList(Entry) = .empty;
        defer pins.deinit(store.gpa);
        for (shape.value.tabs) |e| if (e.pin != null) pins.append(store.gpa, e) catch return;
        if (pins.items.len == shape.value.tabs.len and shape.value.active < 0) continue;
        write(store, space, .{ .tabs = pins.items, .active = -1 }, true);
    }
}

/// A deleted space's file; the first space's is never erased.
pub fn erase(store: *Store, space: Uuid) void {
    if (space.eql(Uuid.first)) return;
    var buf: [49]u8 = undefined;
    const p = store.file(fileName(&buf, space)) catch return;
    defer store.gpa.free(p);
    store.disk.remove(p);
}

// MARK: lenient decoding, shared by the other Kea files

pub fn viaValue(comptime T: type, gpa: std.mem.Allocator, source: anytype, opts: Opts) !T {
    const v = try std.json.innerParse(Value, gpa, source, opts);
    return T.jsonParseFromValue(gpa, v, opts);
}

pub fn object(v: Value) !std.json.ObjectMap {
    return if (v == .object) v.object else error.UnexpectedToken;
}

/// `decode`: present and well-formed, or the whole value fails.
pub fn need(comptime T: type, gpa: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8, opts: Opts) !T {
    return std.json.parseFromValueLeaky(T, gpa, o.get(key) orelse return error.MissingField, opts);
}

/// `decodeIfPresent`: absent or null is nil; anything else must decode.
pub fn maybe(comptime T: type, gpa: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8, opts: Opts) !?T {
    const v = o.get(key) orelse return null;
    if (v == .null) return null;
    return try std.json.parseFromValueLeaky(T, gpa, v, opts);
}

/// `try? decode`: whatever doesn't make sense is nil.
pub fn lenient(comptime T: type, gpa: std.mem.Allocator, o: std.json.ObjectMap, key: []const u8, opts: Opts) ?T {
    const v = o.get(key) orelse return null;
    return std.json.parseFromValueLeaky(T, gpa, v, opts) catch null;
}

// MARK: tests

const testing = std.testing;
const Temp = @import("../tests/temp.zig").Temp;

fn roundTrip(comptime T: type, bytes: []const u8) !void {
    const a = try json.decode(T, testing.allocator, bytes);
    defer a.deinit();
    const out = try json.encode(testing.allocator, a.value);
    defer testing.allocator.free(out);
    const b = try json.decode(T, testing.allocator, out);
    defer b.deinit();
    const again = try json.encode(testing.allocator, b.value);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
}

test "session fixture round-trips" {
    try roundTrip(Shape, @embedFile("../tests/fixtures/kea/session.json"));
    const p = try json.decode(Shape, testing.allocator, @embedFile("../tests/fixtures/kea/session.json"));
    defer p.deinit();
    const s = p.value;
    try testing.expectEqual(@as(usize, 4), s.tabs.len);
    try testing.expectEqualStrings("G", s.tabs[0].pin.?);
    try testing.expect(s.tabs[0].listed.?);
    try testing.expect(s.tabs[1].pin == null and s.tabs[1].groupID != null);
    try testing.expectEqualStrings("He said \"hi\"", s.tabs[2].title);
    try testing.expect(!s.groups.?[0].collapsed and s.groups.?[1].collapsed);
    try testing.expectEqual(Axis.vertical, s.splits[0].axis);
    try testing.expectEqual(@as(?i64, 3), s.splits[0].focused);
}

test "session lenient fields and legacy split decode" {
    const p = try json.decode(Shape, testing.allocator, @embedFile("../tests/fixtures/kea/session-legacy.json"));
    defer p.deinit();
    const s = p.value;
    try testing.expect(s.groups == null);
    try testing.expect(s.tabs[0].groupID == null and s.tabs[0].listed == null);
    try testing.expectEqualSlices(i64, &.{ 0, 1 }, s.splits[0].tabs);
    try testing.expectEqualSlices(f64, &.{ 0.25, 0.75 }, s.splits[0].sizes);
    try testing.expectEqual(Axis.horizontal, s.splits[0].axis);
    try testing.expectEqualSlices(f64, &.{ 0.5, 0.5 }, s.splits[1].sizes);
    // Written back in today's shape.
    const out = try json.encode(testing.allocator, s.splits[0]);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("{\"tabs\":[0,1],\"axis\":\"horizontal\",\"sizes\":[0.25,0.75]}", out);
}

test "session file names by space" {
    var buf: [49]u8 = undefined;
    try testing.expectEqualStrings("session.json", fileName(&buf, Uuid.first));
    const u = try Uuid.parse("5e4c0000-abcd-4000-8000-00000000002a");
    try testing.expectEqualStrings("session-5E4C0000-ABCD-4000-8000-00000000002A.json", fileName(&buf, u));
}

test "session write, read, startFresh and erase" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var store = try Store.init(testing.allocator, t.root, t.suite);
    defer store.deinit();
    const other = try Uuid.parse("5e4c0000-abcd-4000-8000-00000000002a");
    const tabs = [_]Entry{
        .{ .url = "https://a.com/", .title = "He said \"hi\"", .pin = "A", .home = "https://a.com/" },
        .{ .url = "https://b.com/", .title = "B" },
    };
    write(&store, other, .{ .tabs = &tabs, .active = 1 }, true);
    {
        const r = read(&store, other);
        defer r.deinit();
        try testing.expectEqualStrings("He said \"hi\"", r.value.tabs[0].title);
        try testing.expectEqual(@as(i64, 1), r.value.active);
    }
    startFresh(&store, &.{other});
    {
        const r = read(&store, other);
        defer r.deinit();
        try testing.expectEqual(@as(usize, 1), r.value.tabs.len);
        try testing.expectEqual(@as(i64, -1), r.value.active);
    }
    erase(&store, other);
    store.disk.drain();
    const r = read(&store, other);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.value.tabs.len);
}

test "browser session keeps a quoted title and never a private tab" {
    const Kea = @import("../app/kea.zig").Kea;
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    {
        const k = try Kea.create(testing.allocator, null, .{ .root = t.root, .suite = t.suite, .headless = true });
        defer k.destroy();
        const b = try k.newBrowser();
        const example = b.open("https://example.com/", .{ .foreground = true });
        example.setTitle("He said \"hi\"");
        b.newShyTab();
        b.activeTab().?.go("https://secret.example/");
        b.select(example);
        b.pin(b.open("https://pinned.example/", .{ .foreground = false }), false);
    }
    const k = try Kea.create(testing.allocator, null, .{ .root = t.root, .suite = t.suite, .headless = true });
    defer k.destroy();
    const b = try k.newBrowser();
    var titles: usize = 0;
    for (b.tabs.items) |tab| {
        try testing.expect(std.mem.indexOf(u8, tab.url(), "secret") == null);
        if (std.mem.eql(u8, tab.title(), "He said \"hi\"")) titles += 1;
        if (std.mem.eql(u8, tab.url(), "https://pinned.example/")) try testing.expect(tab.pin != null);
    }
    try testing.expectEqual(@as(usize, 1), titles);
    try testing.expectEqualStrings("He said \"hi\"", b.tabById(b.active_id).?.title());
}
