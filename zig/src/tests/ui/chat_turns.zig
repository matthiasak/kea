//! Ubi Chat's turns and composer: "Ask anything." stays over the composer
//! with the model's follow-ups, a question and an answer copy as written,
//! Retry answers again, and ↑/↓ walk the chat's own inputs.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const chat = @import("chat.zig");
const md = @import("markdown.zig");

const gpa = std.testing.allocator;
const t = std.testing;
const prompt = "Ask, or type / or @…";

/// The `n`th text drawn that is exactly `s`, clicked.
fn clickNth(f: *Fixture, s: []const u8, n: usize) !void {
    var seen: usize = 0;
    for (f.tester.ctx.nodes.items) |node| switch (node.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s)) {
            if (seen == n) return f.tester.click(node.rect.x + node.rect.w / 2, node.rect.y + node.rect.h / 2);
            seen += 1;
        },
        else => {},
    };
    return error.TextNotFound;
}

fn send(f: *Fixture, text: []const u8) void {
    f.tester.typeText(text);
    f.tester.key(.enter);
    f.tester.settle(1);
}

test "ask anything stays with follow-ups; copy, Markdown copy and retry" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    chat.ready(b);
    chat.reply = "**Bold** and `code` here.";
    defer chat.reply = chat.answer;
    chat.answered = 0;
    b.toggleChat();
    f.tester.settle(1);
    const a = b.assisting orelse return error.NoChat;
    try t.expect(f.tester.hasText("Ask anything."));
    try f.tester.clickText(prompt);
    send(&f, "What is a kea?");
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    // Still there once the chat began, with the model's follow-ups.
    try t.expect(f.tester.hasText("Ask anything."));
    for (chat.followups) |q| try t.expect(f.tester.hasText(q));

    // The question's Copy, then the answer's: the Markdown as written.
    try clickNth(&f, "Copy", 0);
    f.tester.settle(0.1);
    try t.expectEqualStrings("What is a kea?", f.tester.clipboard.items);
    try t.expect(f.tester.hasText("Copied"));
    try clickNth(&f, "Copy", 0);
    f.tester.settle(0.1);
    try t.expectEqualStrings("**Bold** and `code` here.", f.tester.clipboard.items);

    // Retry answers the same question again, in its place.
    const first_id = a.chat.turns[0].id;
    try f.tester.clickText("Retry");
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 2), chat.answered);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    try t.expect(!a.chat.turns[0].id.eql(first_id));
    try t.expectEqualStrings("What is a kea?", a.chat.turns[0].question);

    // A follow-up asks itself.
    try f.tester.clickText(chat.followups[1]);
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 2), a.chat.turns.len);
    try t.expectEqualStrings(chat.followups[1], a.chat.turns[1].question);
}

test "up and down walk this chat's inputs while the composer is untouched" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    chat.ready(b);
    b.toggleChat();
    f.tester.settle(1);
    const a = b.assisting orelse return error.NoChat;
    try f.tester.clickText(prompt);
    send(&f, "First prompt");
    f.tester.typeText("Second");
    f.tester.setMods(.{ .shift = true });
    f.tester.key(.enter);
    f.tester.setMods(.{});
    send(&f, "multiline");
    try t.expectEqual(@as(usize, 2), a.chat.turns.len);
    const chat_a = a.chat.id;

    f.tester.key(.up);
    try t.expectEqualStrings("Second\nmultiline", a.draft.items);
    f.tester.key(.up);
    try t.expectEqualStrings("First prompt", b.chat.draft.text());
    f.tester.key(.down);
    try t.expectEqualStrings("Second\nmultiline", a.draft.items);
    f.tester.key(.down);
    try t.expectEqualStrings("", a.draft.items);

    // Typed text is never replaced.
    f.tester.typeText("Edited");
    f.tester.key(.up);
    try t.expectEqualStrings("Edited", a.draft.items);

    // Another chat has its own.
    a.new(false);
    f.tester.settle(1);
    try f.tester.clickText(prompt);
    f.tester.key(.up);
    try t.expectEqualStrings("", a.draft.items);
    send(&f, "Chat B question");
    f.tester.key(.up);
    try t.expectEqualStrings("Chat B question", a.draft.items);
    f.tester.key(.down);
    try t.expectEqualStrings("", a.draft.items);

    a.open(chat_a);
    f.tester.settle(1);
    try f.tester.clickText(prompt);
    f.tester.key(.up);
    try t.expectEqualStrings("Second\nmultiline", a.draft.items);
}

test "edit a question in place: escape and cancel keep it, send asks it again" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    chat.ready(b);
    b.toggleChat();
    f.tester.settle(1);
    const a = b.assisting orelse return error.NoChat;
    try f.tester.clickText(prompt);
    send(&f, "First question");
    send(&f, "Second question");
    try t.expectEqual(@as(usize, 2), a.chat.turns.len);
    const ui = @import("nanoui").ui;

    // Escape leaves both turns as they were.
    try clickNth(&f, "Edit", 0);
    f.tester.settle(1);
    try t.expectEqualStrings("First question", b.chat.edit_buf.text());
    try t.expect(b.chat.editing_turn.?.eql(a.chat.turns[0].id));
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.escape });
    f.tester.settle(1);
    try t.expect(b.chat.editing_turn == null);
    try t.expectEqual(@as(usize, 2), a.chat.turns.len);

    // So does Cancel.
    try clickNth(&f, "Edit", 0);
    f.tester.settle(1);
    try f.tester.clickText("Cancel");
    f.tester.settle(1);
    try t.expect(b.chat.editing_turn == null);
    try t.expectEqual(@as(usize, 2), a.chat.turns.len);
    try t.expectEqualStrings("Second question", a.chat.turns[1].question);

    // Send: the later turn goes, the edited question is answered afresh.
    const before = chat.answered;
    try clickNth(&f, "Edit", 0);
    f.tester.settle(1);
    f.tester.typeText(", edited");
    try f.tester.clickText("Send");
    f.tester.settle(1);
    try t.expect(b.chat.editing_turn == null);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    try t.expectEqualStrings("First question, edited", a.chat.turns[0].question);
    try t.expectEqual(before + 1, chat.answered);
    try t.expectEqualStrings(chat.answer, a.chat.turns[0].answer);

    // Return sends too.
    try clickNth(&f, "Edit", 0);
    f.tester.settle(1);
    f.tester.typeText(" again");
    f.tester.key(.enter);
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    try t.expectEqualStrings("First question, edited again", a.chat.turns[0].question);
}

test "a question's bubble draws its Markdown and math, a selection in it copies as written" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    chat.ready(b);
    b.toggleChat();
    f.tester.settle(1);
    const a = b.assisting orelse return error.NoChat;
    try f.tester.clickText(prompt);
    send(&f, "Check **this** $x_1$ please");
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    // The composer holds focus, its own text selected.
    f.tester.typeText("draft");
    f.tester.textOps(&.{.{ .command = .select_all }});
    f.tester.frame();
    try t.expect(f.tester.ctx.focused_text != null);

    try md.dragToCanvas(&f, "Check this ", 6, "$x_1$");
    try t.expectEqualStrings("**this** $x_1$", f.tester.clipboard.items);
}
