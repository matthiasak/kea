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

test "Esc keeps Ubi Chat open, edge drag expands past 720, attachments send on Return, and 120 Hz power gate works" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .width = 1440, .height = 900 });
    defer f.deinit();
    const b = f.browser;
    ready(b);
    b.toggleChat();
    f.tester.settle(1);
    const a = b.assisting orelse return error.NoChat;

    // Pressing Esc unfocuses composer / keeps Ubi Chat open (`b.assisting != null`).
    _ = f.press("\x1b", 53, .{});
    f.tester.settle(1);
    try t.expect(b.assisting != null);

    // Dragging Ubi Chat's edge handle expands `chat_width` past the old 720 cap (to ~900).
    const edge = 1440 - b.prefs.chat_width + 4;
    f.tester.drag(edge, 400, 1440 - 900, 400);
    f.tester.settle(1);
    try t.expect(b.prefs.chat_width >= 880);

    // Attaching a buffer without typing text enables Send and submits on Return.
    a.addAttachment("snippet.zig", "text/plain", "const x = 42;", false);
    f.tester.settle(1);
    try t.expect(f.tester.hasText("snippet.zig"));
    a.submit();
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    try t.expect(a.chat.turns[0].shot);

    // 120 Hz power gate (`fast_pages_power` + `frame_rate.power_override`).
    const fr = @import("kea").frame_rate;
    defer fr.power_override = null;
    b.prefs.set("fast_pages", true);
    b.prefs.set("fast_pages_power", true);
    fr.power_override = true;
    try t.expect(fr.effectiveFast(f.kea));
    fr.power_override = false;
    try t.expect(!fr.effectiveFast(f.kea));
    b.prefs.set("fast_pages_power", false);
    try t.expect(fr.effectiveFast(f.kea));

    // Ubi Chat ModelPicker defaults: Thinking On, Effort High, Web Search On; clicking effort button cycles High -> Max -> Low.
    try t.expect(b.prefs.ai_thinking);
    try t.expectEqual(.high, b.prefs.ai_effort);
    try t.expect(b.prefs.ai_web_search);
    try t.expect(f.tester.hasText("High"));
    try f.tester.clickText("High");
    f.tester.settle(1);
    try t.expectEqual(.max, b.prefs.ai_effort);
    try t.expect(f.tester.hasText("Max"));
}
