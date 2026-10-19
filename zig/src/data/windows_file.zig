//! `windows.json` (`Windows.swift`): the oldest window's frame and space
//! first, then every other window whole. A frame is `NSStringFromRect` text.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("json.zig");
const session = @import("session.zig");
const Store = @import("store.zig").Store;
const Uuid = json.Uuid;
const Opts = std.json.ParseOptions;

const file = "windows.json";

pub const WindowRecord = struct {
    id: Uuid,
    frame: ?[]const u8 = null,
    space: Uuid = Uuid.first,
    /// Rows by space, keyed by the space's identifier.
    rows: json.Map(session.Shape) = .{},

    pub fn jsonParse(gpa: std.mem.Allocator, source: anytype, opts: Opts) !WindowRecord {
        return session.viaValue(WindowRecord, gpa, source, opts);
    }
    /// Every field leniently, each with its own fallback.
    pub fn jsonParseFromValue(gpa: std.mem.Allocator, v: std.json.Value, opts: Opts) !WindowRecord {
        const o = try session.object(v);
        return .{
            .id = session.lenient(Uuid, gpa, o, "id", opts) orelse Uuid.random(),
            .frame = session.lenient([]const u8, gpa, o, "frame", opts),
            .space = session.lenient(Uuid, gpa, o, "space", opts) orelse Uuid.first,
            .rows = session.lenient(json.Map(session.Shape), gpa, o, "rows", opts) orelse .{},
        };
    }
};

/// The records; none when there is no file, and an undecodable one set aside.
pub fn read(store: *Store) std.json.Parsed([]WindowRecord) {
    if (store.load([]WindowRecord, file)) |p| return p;
    return json.decode([]WindowRecord, store.gpa, "[]") catch @panic("OOM");
}

pub fn write(store: *Store, records: []const WindowRecord, now: bool) void {
    store.save(file, records, now);
}

/// Start with a fresh window: only the first window's line stays.
pub fn startFresh(store: *Store) void {
    const records = read(store);
    defer records.deinit();
    if (records.value.len <= 1) return;
    write(store, records.value[0..1], true);
}

/// Soon, not now: a window being dragged moves many times a second. The
/// owner (`app/browsers.zig`) outlives it and builds the records in `save`.
pub const Soon = struct {
    saving: bool = false,
    ctx: *anyopaque,
    save: *const fn (*anyopaque) void,

    pub fn saveSoon(self: *Soon) void {
        if (self.saving) return;
        self.saving = true;
        objc.dispatchAfter(std.time.ns_per_s, self, fire);
    }

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Soon = @ptrCast(@alignCast(ctx.?));
        self.saving = false;
        self.save(self.ctx);
    }
};

// MARK: tests

const testing = std.testing;
const Temp = @import("../tests/temp.zig").Temp;

test "windows fixture round-trips" {
    const bytes = @embedFile("../tests/fixtures/kea/windows.json");
    const a = try json.decode([]WindowRecord, testing.allocator, bytes);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 3), a.value.len);
    try testing.expectEqualStrings("{{120, 80}, {1180, 780}}", a.value[0].frame.?);
    try testing.expectEqual(@as(usize, 2), a.value[1].rows.map.count());
    try testing.expect(a.value[2].frame == null and a.value[2].space.eql(Uuid.first));
    const out = try json.encode(testing.allocator, a.value);
    defer testing.allocator.free(out);
    const b = try json.decode([]WindowRecord, testing.allocator, out);
    defer b.deinit();
    const again = try json.encode(testing.allocator, b.value);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(out, again);
    try testing.expect(std.mem.indexOf(u8, out, "\"rows\":{}") != null);
}

test "windows startFresh keeps the first line" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var store = try Store.init(testing.allocator, t.root, t.suite);
    defer store.deinit();
    const recs = [_]WindowRecord{ .{ .id = Uuid.random(), .frame = "{{0, 0}, {800, 600}}" }, .{ .id = Uuid.random() } };
    write(&store, &recs, true);
    startFresh(&store);
    const r = read(&store);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 1), r.value.len);
    try testing.expectEqualStrings("{{0, 0}, {800, 600}}", r.value[0].frame.?);
}
