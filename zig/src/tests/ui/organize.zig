//! P9: Organize with AI in the bookmarks manager — the proposal shown in
//! place of the list, and Apply putting it in.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const client = app.ai_client;

const gpa = std.testing.allocator;

/// Every answer: the two sites, swapped, in a folder of their own.
pub fn stream(_: ?*anyopaque, _: *app.ai_core.Ai, _: client.Ask, sink: client.Sink) ?client.Handle {
    sink.piece(sink.ctx, "{\"tree\":[{\"folder\":\"Sites\",\"items\":[2,1]}]}");
    sink.done(sink.ctx, null);
    return null;
}

/// AI on, run by Ollama with a model, answered by `stream`.
pub fn ready(b: *app.Browser) void {
    const m = b.kea.ai;
    m.client = .{ .ctx = null, .stream = stream };
    m.prefs.set("ai", true);
    m.prefs.set("ai_provider", "ollama");
    m.prefs.setAIModel("m", "ollama");
}

test "organize with AI shows the proposal and Apply reorganises" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const b = f.browser;
    _ = b.bookmarks.add("https://a.example/", "Alpha");
    _ = b.bookmarks.add("https://b.example/", "Beta");
    ready(b);
    app.sheet.show(b, .bookmarking);
    f.tester.settle(1);
    // Headless, the instruction isn't asked; the checks pass and nothing is said.
    app.bookmarks_proposal.organizeBookmarks(b);
    try std.testing.expect(b.bookmarking);
    app.bookmarks_proposal.send(b, "");
    f.tester.settle(1);
    try std.testing.expect(b.marks_ui.picks.proposal != null);
    try std.testing.expect(f.tester.hasText("2 bookmarks in 1 folder"));
    try std.testing.expect(f.tester.hasText("Apply"));
    try f.tester.clickText("Apply");
    f.tester.settle(1);
    try std.testing.expect(b.marks_ui.picks.proposal == null);
    try std.testing.expectEqual(@as(usize, 1), b.bookmarks.roots.len);
    try std.testing.expectEqualStrings("Sites", b.bookmarks.roots[0].title);
    try std.testing.expectEqualStrings("Beta", b.bookmarks.roots[0].children.?[0].title);
}
