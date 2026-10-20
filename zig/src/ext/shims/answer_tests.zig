//! What the shim's answers look like (ExtensionShims.swift `node/bar/root`,
//! `visit`, `chromeGroup`): the shapes, compared with what Swift writes.
const std = @import("std");
const bookmarks = @import("bookmarks.zig");
const history = @import("history.zig");
const groups = @import("groups.zig");
const json = @import("../../data/json.zig");
const Bookmark = @import("../../data/bookmarks.zig").Bookmark;
const Uuid = json.Uuid;
const Value = std.json.Value;

/// `x` written as JSON equals `expected`, numbers compared as numbers.
fn expectShape(a: std.mem.Allocator, expected: []const u8, x: anytype) !void {
    const text = try std.json.Stringify.valueAlloc(a, x, .{ .emit_null_optional_fields = false });
    const got = try std.json.parseFromSliceLeaky(Value, a, text, .{});
    const want = try std.json.parseFromSliceLeaky(Value, a, expected, .{});
    if (!same(want, got)) {
        std.debug.print("expected {s}\n     got {s}\n", .{ expected, text });
        return error.TestExpectedEqual;
    }
}

fn number(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn same(x: Value, y: Value) bool {
    if (number(x)) |nx| return if (number(y)) |ny| nx == ny else false;
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null => true,
        .bool => |b| b == y.bool,
        .string => |s| std.mem.eql(u8, s, y.string),
        .array => |arr| arr.items.len == y.array.items.len and for (arr.items, y.array.items) |p, q| {
            if (!same(p, q)) break false;
        } else true,
        .object => |o| o.count() == y.object.count() and for (o.keys(), o.values()) |k, v| {
            if (!same(v, y.object.get(k) orelse break false)) break false;
        } else true,
        else => false,
    };
}

const folder_id = "00000000-0000-0000-0000-00000000000A";
const site_id = "00000000-0000-0000-0000-00000000000B";
const top_id = "00000000-0000-0000-0000-00000000000C";

test "bookmarks shaped as Chrome nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inside = [_]Bookmark{.{ .id = try Uuid.parse(site_id), .title = "Site", .url = "https://site.example/" }};
    const roots = [_]Bookmark{
        .{ .id = try Uuid.parse(folder_id), .title = "Folder", .children = &inside },
        .{ .id = try Uuid.parse(top_id), .title = "Top", .url = "https://top.example/" },
    };
    const site = "{\"id\":\"" ++ site_id ++ "\",\"parentId\":\"" ++ folder_id ++ "\",\"index\":0,\"title\":\"Site\",\"url\":\"https://site.example/\",\"dateAdded\":0,\"syncing\":false}";
    const folder_head = "\"id\":\"" ++ folder_id ++ "\",\"parentId\":\"1\",\"index\":0,\"title\":\"Folder\",\"dateAdded\":0,\"dateGroupModified\":0,\"syncing\":false";
    const top = "{\"id\":\"" ++ top_id ++ "\",\"parentId\":\"1\",\"index\":1,\"title\":\"Top\",\"url\":\"https://top.example/\",\"dateAdded\":0,\"syncing\":false}";
    const bar_head = "\"id\":\"1\",\"parentId\":\"0\",\"index\":0,\"title\":\"Bookmarks\",\"dateAdded\":0,\"folderType\":\"bookmarks-bar\",\"syncing\":false";
    const bar = "{" ++ bar_head ++ ",\"children\":[{" ++ folder_head ++ ",\"children\":[" ++ site ++ "]}," ++ top ++ "]}";

    try expectShape(a, "{\"id\":\"0\",\"title\":\"\",\"dateAdded\":0,\"syncing\":false,\"children\":[" ++ bar ++ "]}", try bookmarks.root(a, &roots));
    try expectShape(a, bar, try bookmarks.bar(a, &roots, true));
    try expectShape(a, "{" ++ bar_head ++ "}", try bookmarks.bar(a, &roots, false));
    try expectShape(a, "{" ++ folder_head ++ "}", try bookmarks.node(a, roots[0], "1", 0, false));

    // Found anywhere, with its parent and place (`find`/`flat`).
    const hit = (try bookmarks.find(a, site_id, &roots)).?;
    try expectShape(a, site, try bookmarks.node(a, hit.node.*, hit.parent, hit.index, true));
    try std.testing.expectEqual(@as(usize, 3), (try bookmarks.flat(a, &roots)).len);
    try std.testing.expect(try bookmarks.find(a, "nope", &roots) == null);
}

test "history visit shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const trace: history.Trace = .{ .key = "a.example/", .address = "a.example", .title = "A", .url = "https://a.example/", .last = 0, .count = 3 };
    try expectShape(arena.allocator(), "{\"id\":\"a.example/\",\"url\":\"https://a.example/\",\"title\":\"A\",\"lastVisitTime\":978307200000,\"visitCount\":3,\"typedCount\":0}", history.visit(trace));
}

test "tab group shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const id = try Uuid.parse("01020304-0000-4000-8000-000000000000");
    var name = "Work".*;
    const g: groups.TabGroup = .{ .id = id, .name = &name, .collapsed = true };
    try expectShape(arena.allocator(), "{\"id\":16909060,\"title\":\"Work\",\"collapsed\":true,\"color\":\"grey\",\"windowId\":1,\"shared\":false}", groups.chromeGroup(g));
}
