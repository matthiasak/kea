//! Tests for Organize with AI: the answer read as a list, and Apply refused
//! once the list changed.
const std = @import("std");
const t = std.testing;
const json = @import("../data/json.zig");
const bm = @import("../data/bookmarks.zig");
const ai = @import("ai.zig");
const client = @import("client.zig");
const org = @import("organize.zig");
const Rig = @import("test_rig.zig").Rig;

fn listOf(a: std.mem.Allocator, roots: []const bm.Bookmark) ![]bm.Bookmark {
    const found = try org.sites(a, roots);
    const out = try a.alloc(bm.Bookmark, found.len);
    for (out, found) |*o, s| o.* = s.node;
    return out;
}

test "organizer refuses Apply after the list changed" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var marks = bm.Bookmarks.init(t.allocator, &rig.store);
    defer marks.deinit();
    _ = marks.add("https://a.com/", "A");
    _ = marks.add("https://b.com/", "B");
    _ = marks.add("https://c.com/x", "C");
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base = try bm.Bookmark.copy(a, marks.roots);
    const list = try listOf(a, base);
    const answer = "Here you go: {\"tree\":[{\"folder\":\"  News  \",\"items\":[1,\" 3 \",1]},{\"folder\":\"Empty\",\"items\":[]}],\"remove\":[2,9,\"x\"]} done";
    const p = (try org.proposal(t.allocator, answer, base, list, "on this Mac · Ollama · m")).?;
    try t.expectEqual(@as(usize, 1), p.tree.len);
    try t.expectEqualStrings("News", p.tree[0].title);
    try t.expectEqual(@as(usize, 2), p.tree[0].children.?.len);
    try t.expect(p.tree[0].children.?[1].id.eql(list[2].id));
    try t.expectEqual(@as(usize, 1), p.removed.len);
    try t.expectEqual(@as(usize, 0), p.left_out);

    // The list changed after asking: Apply refuses and changes nothing.
    _ = marks.add("https://d.com/", "D");
    try t.expectEqual(org.Applied.changed, org.apply(&marks, p));
    try t.expectEqualStrings("Your bookmarks changed meanwhile; ask again", org.appliedSays(.changed));
    try t.expectEqual(@as(usize, 4), marks.roots.len);
    p.destroy();

    // Asked of the list as it is now, it applies as one change.
    const base2 = try bm.Bookmark.copy(a, marks.roots);
    const q = (try org.proposal(t.allocator, "{\"tree\":[4,{\"folder\":\"\",\"items\":[1,2]}]}", base2, try listOf(a, base2), "x")).?;
    defer q.destroy();
    try t.expectEqual(@as(usize, 3), q.tree.len);
    try t.expectEqualStrings("Folder", q.tree[1].title);
    try t.expectEqual(@as(usize, 1), q.left_out);
    try t.expectEqual(org.Applied.applied, org.apply(&marks, q));
    try t.expect(org.same(marks.roots, q.tree));

    // Nothing placed and nothing removed, or no JSON: no proposal.
    try t.expect((try org.proposal(t.allocator, "{\"tree\":[]}", base2, try listOf(a, base2), "x")) == null);
    try t.expect((try org.proposal(t.allocator, "I can't help", base2, try listOf(a, base2), "x")) == null);
}

const Stub = struct {
    max_tokens: u32 = 0,
    thinking: ?u32 = null,
    opening: []u8 = &.{},

    fn stream(ctx: ?*anyopaque, _: *ai.Ai, q: client.Ask, sink: client.Sink) ?client.Handle {
        const s: *Stub = @ptrCast(@alignCast(ctx.?));
        s.max_tokens = q.max_tokens;
        s.thinking = q.thinking;
        s.opening = t.allocator.dupe(u8, q.messages[0].text) catch &.{};
        sink.piece(sink.ctx, "{\"tree\":[2,1]}");
        sink.done(sink.ctx, null);
        return null;
    }
};

const Heard = struct {
    got: ?*org.Proposal = null,
    said: []const u8 = "",
    fn then(raw: *anyopaque, out: org.Outcome) void {
        const h: *Heard = @ptrCast(@alignCast(raw));
        switch (out) {
            .proposal => |p| h.got = p,
            .says => |s| h.said = s,
        }
    }
};

test "organizer asks with 8,192 tokens and a 1,024 thinking budget" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var stub: Stub = .{};
    defer t.allocator.free(stub.opening);
    rig.ai.client = .{ .ctx = &stub, .stream = Stub.stream };
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kids = try a.alloc(bm.Bookmark, 1);
    kids[0] = .{ .id = json.Uuid.random(), .title = "Line one\nline two", .url = "https://news.site/today?x=1" };
    const roots = try a.alloc(bm.Bookmark, 2);
    roots[0] = bm.Bookmark.folder("Work", kids);
    roots[1] = .{ .id = json.Uuid.random(), .title = "Top", .url = "notaurl" };
    var heard: Heard = .{};
    var slot: ?*org.Organizing = null;
    org.ask(rig.ai, roots, "  ", ai.ollama, "m", &heard, Heard.then, &slot);
    try t.expect(slot == null);
    try t.expectEqual(@as(u32, 8192), stub.max_tokens);
    try t.expectEqual(@as(?u32, 1024), stub.thinking);
    try t.expect(std.mem.indexOf(u8, stub.opening, "\n1. Line one line two — news.site/today  (in: Work)\n2. Top — notaurl\n</page-") != null);
    try t.expect(std.mem.endsWith(u8, stub.opening, "My instruction: " ++ org.standing));
    const p = heard.got.?;
    defer p.destroy();
    try t.expectEqualStrings("Top", p.tree[0].title);
    try t.expectEqualStrings("on this Mac · Ollama · m", p.place);
    try t.expectEqualStrings("No bookmarks to organize", (try org.refusal(a, &.{}, ai.ollama)).?);
}
