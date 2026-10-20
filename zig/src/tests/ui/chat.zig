//! P9: Ubi Chat's panel (AssistantPanel) — the composer sends on Return
//! and breaks the line on ⇧Return; the answer shows in the transcript.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const client = app.ai_client;

const gpa = std.testing.allocator;
const t = std.testing;

pub const answer = "Kea are clever parrots of the Southern Alps.";

/// Every answer `answer`, in two pieces; a chat's name "Kea facts".
pub fn stream(_: ?*anyopaque, _: *app.ai_core.Ai, q: client.Ask, sink: client.Sink) ?client.Handle {
    if (std.mem.startsWith(u8, q.system, "Name this chat")) {
        sink.piece(sink.ctx, "Kea facts");
    } else {
        sink.piece(sink.ctx, answer[0..9]);
        sink.piece(sink.ctx, answer[9..]);
    }
    sink.done(sink.ctx, null);
    return null;
}

/// AI on, run by Ollama with a model (no key, no notice), answered by `stream`.
pub fn ready(b: *app.Browser) void {
    const m = b.kea.ai;
    m.client = .{ .ctx = null, .stream = stream };
    m.prefs.set("ai", true);
    m.prefs.set("ai_provider", "ollama");
    m.prefs.setAIModel("m", "ollama");
}

test "composer return sends and shift-return newlines" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    ready(b);
    b.toggleChat();
    f.tester.settle(1);
    const a = b.assisting orelse return error.NoChat;
    try t.expect(f.tester.hasText("Ask anything."));
    try f.tester.clickText("Ask, or type / or @…");
    f.tester.typeText("What is a kea?");
    f.tester.setMods(.{ .shift = true });
    f.tester.key(.enter);
    f.tester.setMods(.{});
    f.tester.typeText("Briefly.");
    // ⇧Return broke the line: two lines, nothing sent.
    try t.expectEqualStrings("What is a kea?\nBriefly.", a.draft.items);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, b.chat.draft.text(), "\n") + 1);
    try t.expectEqual(@as(usize, 0), a.chat.turns.len);
    // Return sent it: one turn with the answer, the composer empty.
    f.tester.key(.enter);
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    try t.expectEqualStrings("What is a kea?\nBriefly.", a.chat.turns[0].question);
    try t.expectEqualStrings(answer, a.chat.turns[0].answer);
    try t.expectEqual(@as(usize, 0), a.draft.items.len);
    try t.expectEqual(@as(usize, 0), b.chat.draft.text().len);
    try t.expect(f.tester.containsText("Kea are clever parrots"));
    try t.expect(f.tester.hasText("Kea facts"));
    // "/" brings the commands up over the field, which keeps the keys.
    f.tester.typeText("/");
    try t.expect(f.tester.hasText("/summarize"));
    f.tester.typeText("he");
    try t.expectEqualStrings("/he", a.draft.items);
    try t.expect(f.tester.hasText("/help") and !f.tester.hasText("/summarize"));
}

test "virtual chat list updates when starring or renaming a middle chat" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    ready(b);
    b.toggleChat();
    const a = b.assisting orelse return error.NoChat;
    var third_id: app.json.Uuid = undefined;
    for (0..45) |i| {
        const id = app.json.Uuid.random();
        if (i == 42) third_id = id;
        var title_buf: [32]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Chat item {d}", .{i}) catch "Chat";
        a.m.chats.put(.{
            .id = id,
            .title = title,
            .touched = @as(f64, @floatFromInt(1_000 + i)),
            .turns = &.{.{ .id = app.json.Uuid.random(), .question = "Q", .answer = "A", .done = true }},
        });
    }
    a.listing = true;
    f.tester.settle(1);
    try t.expect(!f.tester.hasText("Starred"));
    a.edit(third_id, {}, struct { fn setStar(_: void, _: std.mem.Allocator, c: *@TypeOf(a.chat)) error{OutOfMemory}!void { c.starred = true; } }.setStar);
    a.rename(third_id, "Renamed third chat");
    f.tester.settle(1);
    try t.expect(f.tester.hasText("Starred"));
    try t.expect(f.tester.hasText("Renamed third chat"));
}
