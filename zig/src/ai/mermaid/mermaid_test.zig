//! Layouts compared item by item against the Swift implementation's output
//! (fixture printed by Mermaid.swift's own `diagram`), plus the size caps.
const std = @import("std");
const m = @import("mermaid.zig");

const fixture = @embedFile("../../tests/fixtures/ai/mermaid_layout.json");
const J = std.json.Value;
const testing = std.testing;

fn num(v: J) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.NotANumber,
    };
}

fn near(v: J, x: f64) !void {
    try testing.expectApproxEqAbs(try num(v), x, 0.01);
}

fn field(v: J, key: []const u8) J {
    return v.object.get(key) orelse std.debug.panic("fixture item lacks {s}", .{key});
}

fn expectPoint(v: J, p: m.Point) !void {
    try near(v.array.items[0], p.x);
    try near(v.array.items[1], p.y);
}

fn expectRect(v: J, r: m.Rect) !void {
    const xs = v.array.items;
    try near(xs[0], r.x);
    try near(xs[1], r.y);
    try near(xs[2], r.w);
    try near(xs[3], r.h);
}

fn expectLines(v: J, lines: []const []const u8) !void {
    try testing.expectEqual(v.array.items.len, lines.len);
    for (v.array.items, lines) |e, l| try testing.expectEqualStrings(e.string, l);
}

fn expectItem(v: J, item: m.Item) !void {
    try testing.expectEqualStrings(field(v, "t").string, @tagName(item));
    switch (item) {
        .node => |n| {
            try expectRect(field(v, "rect"), n.rect);
            try testing.expectEqualStrings(field(v, "shape").string, @tagName(n.shape));
            try expectLines(field(v, "lines"), n.lines);
            try testing.expectEqual(field(v, "titled").bool, n.titled);
        },
        .edge => |e| {
            const pts = field(v, "points").array.items;
            try testing.expectEqual(pts.len, e.points.len);
            for (pts, e.points) |p, q| try expectPoint(p, q);
            try testing.expectEqual(field(v, "dashed").bool, e.dashed);
            try testing.expectEqual(field(v, "thick").bool, e.thick);
            try testing.expectEqualStrings(field(v, "head").string, @tagName(e.head));
            switch (field(v, "label")) {
                .null => try testing.expect(e.label == null),
                else => |l| try testing.expectEqualStrings(l.string, e.label orelse return error.MissingLabel),
            }
        },
        .text => |t| {
            try testing.expectEqualStrings(field(v, "str").string, t.str);
            try expectPoint(field(v, "at"), t.at);
            try testing.expectEqual(field(v, "bold").bool, t.bold);
            try testing.expectEqual(field(v, "muted").bool, t.muted);
        },
        .note => |n| {
            try expectRect(field(v, "rect"), n.rect);
            try expectLines(field(v, "lines"), n.lines);
        },
        .wedge => |w| {
            try expectPoint(field(v, "center"), w.center);
            try near(field(v, "radius"), w.radius);
            try near(field(v, "from"), w.from);
            try near(field(v, "to"), w.to);
            try testing.expectEqual(field(v, "color").integer, w.color);
        },
        .swatch => |s| {
            try expectRect(field(v, "rect"), s.rect);
            try testing.expectEqual(field(v, "color").integer, s.color);
        },
    }
}

test "mermaid layout matches fixture" {
    const objc = @import("nanoui").objc;
    _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const parsed = try std.json.parseFromSlice(J, testing.allocator, fixture, .{});
    defer parsed.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (parsed.value.array.items) |case| {
        const source = field(case, "source").string;
        errdefer std.debug.print("source: {s}\n", .{source});
        const got = m.diagram(arena.allocator(), source);
        const want = field(case, "diagram");
        if (want == .null) {
            try testing.expect(got == null);
            continue;
        }
        const d = got orelse return error.MissingDiagram;
        try testing.expectEqualStrings(field(want, "kind").string, d.kind);
        try near(field(want, "width"), d.width);
        try near(field(want, "height"), d.height);
        try testing.expectEqual(field(want, "nodes").integer, @as(i64, @intCast(d.nodes)));
        try testing.expectEqual(field(want, "edges").integer, @as(i64, @intCast(d.edges)));
        const items = field(want, "items").array.items;
        try testing.expectEqual(items.len, d.items.len);
        for (items, d.items, 0..) |v, item, i| {
            errdefer std.debug.print("item {d}\n", .{i});
            try expectItem(v, item);
        }
    }
}

test "mermaid caps and unknown headers yield null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "flowchart TD\n");
    for (0..m.max_nodes) |i| try src.print(a, "n{d}\n", .{i});
    try testing.expect(m.diagram(a, src.items) != null);
    try src.appendSlice(a, "extra\n");
    try testing.expect(m.diagram(a, src.items) == null);
    try testing.expect(m.diagram(a, "gantt\n  title x") == null);
    try testing.expect(m.diagram(a, "%% only a comment") == null);
    const long = try a.alloc(u8, m.max_chars + 1);
    @memset(long, ' ');
    @memcpy(long[0..11], "graph TD\nA\n");
    try testing.expect(m.diagram(a, long[0..m.max_chars]) != null);
    try testing.expect(m.diagram(a, long) == null);
}
