//! Tests for the assistant, with a stand-in client that answers at once
//! from a script: chats kept and read back, private chats never written,
//! compaction's batches, cleaning up and the slash commands.
const std = @import("std");
const t = std.testing;
const json = @import("../data/json.zig");
const cs = @import("../data/chats_store.zig");
const ai = @import("ai.zig");
const client = @import("client.zig");
const runs = @import("assistant_runs.zig");
const Assistant = @import("assistant.zig").Assistant;
const Rig = @import("test_rig.zig").Rig;

/// Answers each request with the next reply, a word at a time, and notes
/// what each request said.
const Stub = struct {
    replies: []const []const u8,
    next: usize = 0,
    /// Each request's messages, joined by "|", and its system prompt.
    asked: std.ArrayList([]u8) = .empty,
    systems: std.ArrayList([]const u8) = .empty,

    fn deinit(s: *Stub) void {
        for (s.asked.items) |x| t.allocator.free(x);
        s.asked.deinit(t.allocator);
        s.systems.deinit(t.allocator);
    }

    fn stream(ctx: ?*anyopaque, _: *ai.Ai, q: client.Ask, sink: client.Sink) ?client.Handle {
        const s: *Stub = @ptrCast(@alignCast(ctx.?));
        var joined: std.ArrayList(u8) = .empty;
        for (q.messages, 0..) |m, i| {
            if (i > 0) joined.append(t.allocator, '|') catch {};
            joined.appendSlice(t.allocator, m.text) catch {};
        }
        s.asked.append(t.allocator, joined.toOwnedSlice(t.allocator) catch &.{}) catch {};
        s.systems.append(t.allocator, q.system) catch {};
        const reply = if (s.next < s.replies.len) s.replies[s.next] else "";
        s.next += 1;
        var words = std.mem.splitScalar(u8, reply, ' ');
        var first = true;
        while (words.next()) |w| {
            if (!first) sink.piece(sink.ctx, " ");
            first = false;
            sink.piece(sink.ctx, w);
        }
        sink.done(sink.ctx, if (std.mem.eql(u8, reply, "!fail")) .{ .http = .{ .status = 503, .said = "" } } else null);
        return null;
    }

    fn use(s: *Stub, m: *ai.Ai) void {
        m.client = .{ .ctx = s, .stream = stream };
    }
};

test "chats store round-trip with the Assistant" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var stub: Stub = .{ .replies = &.{ "A parrot of the mountains.", "\"Kea facts\"" } };
    defer stub.deinit();
    stub.use(rig.ai);

    const a = try Assistant.create(rig.ai, null, false);
    a.send("What is a kea?", ai.ollama, "llama3");
    try t.expect(a.live == null);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    const turn = a.chat.turns[0];
    try t.expectEqualStrings("A parrot of the mountains.", turn.answer);
    try t.expect(turn.done and turn.failed == null);
    try t.expectEqualStrings("on this Mac · Ollama · llama3", turn.place);
    // Named by the model from its first answer.
    try t.expectEqualStrings("Kea facts", a.chat.title);
    try t.expectEqualStrings(@import("ubi_chat.zig").naming, stub.systems.items[1]);
    try t.expect(std.mem.startsWith(u8, stub.asked.items[1], "Question:\nWhat is a kea?\n\nAnswer:\nA parrot"));
    const id = a.chat.id;
    a.destroy();

    try rig.relaunch();
    stub.use(rig.ai);
    try t.expectEqual(@as(usize, 1), rig.ai.chats.index.len);
    try t.expectEqualStrings("Kea facts", rig.ai.chats.index[0].title);
    const b = try Assistant.create(rig.ai, null, false);
    defer b.destroy();
    b.open(id);
    try t.expect(b.chat.id.eql(id));
    try t.expectEqualStrings("A parrot of the mountains.", b.chat.turns[0].answer);

    // A failed answer is kept with what went wrong; the earlier turn goes with the next question.
    stub.replies = &.{"!fail"};
    stub.next = 0;
    b.send("And its colour?", ai.ollama, "llama3");
    try t.expectEqual(@as(usize, 2), b.chat.turns.len);
    try t.expectEqualStrings("The provider answered 503.", b.chat.turns[1].failed.?);
    try t.expect(std.mem.startsWith(u8, stub.asked.items[2], "What is a kea?|A parrot of the mountains.|And its colour?"));
}

test "a private tab's chat is never written" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var stub: Stub = .{ .replies = &.{"Hidden."} };
    defer stub.deinit();
    stub.use(rig.ai);
    const a = try Assistant.create(rig.ai, null, true);
    defer a.destroy();
    a.send("Secret?", ai.ollama, "m");
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    // Not named, not kept.
    try t.expectEqual(@as(usize, 1), stub.next);
    try t.expectEqual(@as(usize, 0), rig.ai.chats.index.len);
    a.rename(a.chat.id, "Named");
    try t.expectEqualStrings("Named", a.chat.title);
    try t.expectEqual(@as(usize, 0), rig.ai.chats.index.len);
}

fn seed(a: *Assistant, n: usize, failed_at: []const usize) void {
    const Seed = struct { n: usize, failed_at: []const usize };
    a.mutate(Seed{ .n = n, .failed_at = failed_at }, struct {
        fn f(s: Seed, al: std.mem.Allocator, c: *cs.Chat) !void {
            const list = try al.alloc(cs.Turn, s.n);
            for (list, 0..) |*x, i| {
                const bad = std.mem.indexOfScalar(usize, s.failed_at, i) != null;
                x.* = .{ .id = json.Uuid.random(), .question = try std.fmt.allocPrint(al, "q{d}", .{i}), .answer = if (bad) "" else try std.fmt.allocPrint(al, "a{d}", .{i}), .done = true, .failed = if (bad) "broke" else null };
            }
            c.turns = list;
        }
    }.f);
}

test "compaction folds all but the last two turns, twelve at a time" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var stub: Stub = .{ .replies = &.{ "S1", "S2", "  S3\n" } };
    defer stub.deinit();
    stub.use(rig.ai);
    const a = try Assistant.create(rig.ai, null, false);
    defer a.destroy();
    seed(a, 30, &.{ 3, 14 });
    try t.expect(a.canCompact());
    a.compactWith(ai.ollama, "m");
    try t.expect(!a.compacting);
    try t.expectEqual(@as(usize, 3), stub.asked.items.len);
    try t.expectEqualStrings(@import("ubi_chat.zig").compacting, stub.systems.items[0]);
    // Batch [0, 12): eleven good turns, the failed one left out, then the ask.
    var parts = std.mem.splitScalar(u8, stub.asked.items[0], '|');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) try t.expect(!std.mem.eql(u8, p, "q3"));
    try t.expectEqual(@as(usize, 11 * 2 + 1), n);
    try t.expect(std.mem.endsWith(u8, stub.asked.items[0], "|Summarize the conversation above, as asked."));
    // Each batch carries the summary before it.
    try t.expect(std.mem.startsWith(u8, stub.asked.items[1], "A summary of this chat so far:\n\nS1|Understood.|q12|a12|q13|a13|q15"));
    try t.expect(std.mem.startsWith(u8, stub.asked.items[2], "A summary of this chat so far:\n\nS2|Understood.|q24|a24"));
    try t.expect(std.mem.indexOf(u8, stub.asked.items[2], "q28") == null);
    try t.expectEqualStrings("S3", a.chat.summary.?);
    try t.expectEqual(@as(?i64, 28), a.chat.compacted);
    try t.expect(!a.canCompact());
    // Kept with the chat.
    const kept = rig.ai.chats.chat(a.chat.id).?;
    try t.expectEqual(@as(?i64, 28), kept.compacted);
}

test "compaction: a failed batch stops it, keeping what was folded" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var stub: Stub = .{ .replies = &.{ "S1", "!fail" } };
    defer stub.deinit();
    stub.use(rig.ai);
    const a = try Assistant.create(rig.ai, null, false);
    defer a.destroy();
    seed(a, 20, &.{});
    a.compactWith(ai.ollama, "m");
    try t.expectEqual(@as(usize, 2), stub.asked.items.len);
    try t.expectEqual(@as(?i64, 12), a.chat.compacted);
    try t.expectEqualStrings("S1", a.chat.summary.?);
    try t.expect(!a.compacting);
    // Too few turns: nothing asked.
    const b = try Assistant.create(rig.ai, null, false);
    defer b.destroy();
    seed(b, 2, &.{});
    b.compactWith(ai.ollama, "m");
    try t.expectEqual(@as(usize, 2), stub.asked.items.len);
}

test "clean up removes failed turns and moves the fold back" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    const a = try Assistant.create(rig.ai, null, false);
    defer a.destroy();
    seed(a, 6, &.{ 1, 4 });
    a.mutate({}, struct {
        fn f(_: void, al: std.mem.Allocator, c: *cs.Chat) !void {
            c.compacted = 3;
            c.summary = try al.dupe(u8, "S");
        }
    }.f);
    a.keep();
    a.cleanUp();
    try t.expectEqual(@as(usize, 4), a.chat.turns.len);
    try t.expectEqual(@as(?i64, 2), a.chat.compacted);
    try t.expectEqualStrings("q5", a.chat.turns[3].question);
    // All bad: the chat goes, a new one with the same pins in its place.
    const old = a.chat.id;
    seed(a, 2, &.{ 0, 1 });
    a.keep();
    a.cleanUp();
    try t.expect(!a.chat.id.eql(old));
    try t.expect(rig.ai.chats.chat(old) == null);
}

test "slash commands and their suggestions" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    const a = try Assistant.create(rig.ai, null, false);
    defer a.destroy();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    a.setDraft("/x");
    try t.expectEqual(@as(usize, 0), (try a.suggestions(arena.allocator())).len);
    // Matched lowercased, as Swift does.
    a.setDraft("/C");
    try t.expectEqual(@as(usize, 5), (try a.suggestions(arena.allocator())).len);
    a.setDraft("/c");
    const c = try a.suggestions(arena.allocator());
    try t.expectEqual(@as(usize, 5), c.len);
    try t.expectEqualStrings("/clear", c[0].title);
    try t.expectEqualStrings("/clean-up", c[4].title);
    a.setDraft("/rename-ws");
    a.submit();
    try t.expectEqualStrings("/rename-ws ", a.draft.items);
    a.setDraft("/rename-ws  Birds of NZ ");
    a.submit();
    try t.expectEqualStrings("Birds of NZ", a.chat.title);
    try t.expectEqualStrings("", a.draft.items);
    a.setDraft("/nope now");
    a.submit();
    try t.expectEqualStrings("/nope now", a.draft.items);
    a.run("/help");
    try t.expect(a.help_shown);
}

test "attachments encode images as base64 and buffers as XML tags" {
    var rig: Rig = undefined;
    try rig.init(t.allocator);
    defer rig.deinit();
    var stub: Stub = .{ .replies = &.{ "Described.", "\"Attachment chat\"" } };
    defer stub.deinit();
    stub.use(rig.ai);
    const a = try Assistant.create(rig.ai, null, false);
    defer a.destroy();
    a.addAttachment("diagram.png", "image/png", "\x89PNG\r\n\x1a\n", true);
    a.addAttachment("notes.txt", "text/plain", "hello from buffer", false);
    try t.expectEqual(@as(usize, 2), a.attachments.items.len);
    a.send("Check this", ai.ollama, "m");
    try t.expectEqual(@as(usize, 0), a.attachments.items.len);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    try t.expect(a.chat.turns[0].shot);
    try t.expect(std.mem.indexOf(u8, stub.asked.items[0], "<attachment name=\"notes.txt\">\nhello from buffer\n</attachment>") != null);
}
