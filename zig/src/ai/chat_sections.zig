//! The chat list's sections (`Chats.sections` in Chats.swift): tasks, then
//! starred (five unless all are asked for), then the rest by day; or one
//! "Results" section while searching.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const cs = @import("../data/chats_store.zig");
const when = @import("../chrome/when.zig");
const Entry = cs.Entry;

pub const Section = struct { title: []const u8, items: []const Entry, more: usize };

fn newerFirst(_: void, x: Entry, y: Entry) bool {
    if (x.touched != y.touched) return x.touched > y.touched;
    return std.mem.order(u8, &x.id.string(), &y.id.string()) == .lt;
}

fn contains(title: []const u8, q: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return objc.msg(objc.BOOL, objc.nsString(title), "localizedCaseInsensitiveContainsString:", .{objc.nsString(q)});
}

/// On `a`; entries borrowed.
pub fn sections(a: std.mem.Allocator, entries: []const Entry, query: []const u8, all_starred: bool) ![]Section {
    const sorted = try a.dupe(Entry, entries);
    std.mem.sort(Entry, sorted, {}, newerFirst);
    var out: std.ArrayList(Section) = .empty;
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len > 0) {
        var found: std.ArrayList(Entry) = .empty;
        for (sorted) |e| if (contains(e.title, q)) try found.append(a, e);
        if (found.items.len > 0) try out.append(a, .{ .title = "Results", .items = found.items, .more = 0 });
        return out.items;
    }
    var tasks: std.ArrayList(Entry) = .empty;
    var starred: std.ArrayList(Entry) = .empty;
    for (sorted) |e| {
        if (e.task) try tasks.append(a, e) else if (e.starred) try starred.append(a, e);
    }
    if (tasks.items.len > 0) try out.append(a, .{ .title = "Tasks", .items = tasks.items, .more = 0 });
    if (starred.items.len > 0) {
        const shown = if (all_starred) starred.items else starred.items[0..@min(5, starred.items.len)];
        try out.append(a, .{ .title = "Starred", .items = shown, .more = starred.items.len - shown.len });
    }
    var day: ?[]const u8 = null;
    var items: std.ArrayList(Entry) = .empty;
    for (sorted) |e| {
        if (e.task or e.starred) continue;
        const d = when.day(a, e.touched);
        if (day == null or !std.mem.eql(u8, day.?, d)) {
            if (day) |title| try out.append(a, .{ .title = title, .items = items.items, .more = 0 });
            day = d;
            items = .empty;
        }
        try items.append(a, e);
    }
    if (day) |title| try out.append(a, .{ .title = title, .items = items.items, .more = 0 });
    return out.items;
}

test "chat list sections" {
    const json = @import("../data/json.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = json.now();
    var list: [9]Entry = undefined;
    for (&list, 0..) |*e, i| e.* = .{ .id = json.Uuid.random(), .title = "Chat", .touched = now - @as(f64, @floatFromInt(i)), .starred = i >= 1 and i <= 6, .task = i == 0, .turns = 1 };
    list[7].touched = now - 86_400 * 9;
    list[8].title = "Kea facts";
    const s = try sections(a, &list, "", false);
    try std.testing.expectEqual(@as(usize, 4), s.len);
    try std.testing.expectEqualStrings("Tasks", s[0].title);
    try std.testing.expectEqualStrings("Starred", s[1].title);
    try std.testing.expectEqual(@as(usize, 5), s[1].items.len);
    try std.testing.expectEqual(@as(usize, 1), s[1].more);
    try std.testing.expectEqualStrings("Today", s[2].title);
    try std.testing.expect(s[2].items[0].id.eql(list[8].id));
    try std.testing.expectEqual(@as(usize, 1), s[3].items.len);
    const r = try sections(a, &list, " KEA ", false);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("Results", r[0].title);
    try std.testing.expectEqual(@as(usize, 0), (try sections(a, &list, "zebra", false)).len);
}
