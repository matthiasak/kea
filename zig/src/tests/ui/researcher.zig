//! Automatic Researcher Mode's overlay (researcher_view.zig): a page's
//! explained sections over it, minimized to a pill, dismissed.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

fn click(f: *Fixture, label: []const u8) !void {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == .button and std.mem.eql(u8, item.label, label)) {
        const r = c.rects.get(item.id) orelse return error.NotLaidOut;
        f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
        return f.tester.settle(1);
    };
    return error.NoButton;
}

test "researcher overlay shows sections, minimizes to a pill, and dismisses" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    const tab = b.activeTab() orelse return error.NoTab;
    const e = app.researcher.track(tab, false) orelse return error.NoEntry;
    app.researcher.feed(e, "## [1] Abstract\nKea solve **puzzles** together.\n## [2] Method\nObserve, then test.\n");
    e.status = .done;
    f.tester.settle(1);
    try t.expect(f.tester.hasText("Feynman Researcher"));
    try t.expect(f.tester.hasText("Abstract"));
    try t.expect(f.tester.hasText("Method"));
    try t.expect(f.tester.containsText("Observe, then test."));
    try click(&f, "Minimize");
    try t.expect(e.minimized);
    try t.expect(!f.tester.hasText("Feynman Researcher"));
    try t.expect(f.tester.hasText("Feynman · 2 sections"));
    try click(&f, "Dismiss");
    try t.expect(e.dismissed);
    try t.expect(!f.tester.hasText("Feynman · 2 sections"));
    try t.expect(app.researcher.entryFor(tab) == e);
}

/// The card's and the pill's boxes over the page (`researcher_view.layer`).
fn layers(f: *Fixture, out: *[2]@import("nanoui").ui.Style) usize {
    var n: usize = 0;
    for (f.tester.ctx.nodes.items) |node| if (node.style.absolute and node.style.scale_anchor.x == 1 and node.style.scale_anchor.y == 0) {
        if (n < 2) out[n] = node.style;
        n += 1;
    };
    return n;
}

test "researcher minimize morphs the card into the pill, then settles" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    const tab = b.activeTab() orelse return error.NoTab;
    const e = app.researcher.track(tab, false) orelse return error.NoEntry;
    app.researcher.feed(e, "## [1] Abstract\nKea solve **puzzles** together.\n");
    e.status = .done;
    f.tester.settle(1);
    var s: [2]@import("nanoui").ui.Style = undefined;
    try t.expectEqual(@as(usize, 1), layers(&f, &s));
    try t.expectApproxEqAbs(@as(f32, 1), s[0].opacity, 0.01);

    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == .button and std.mem.eql(u8, item.label, "Minimize")) {
        const r = c.rects.get(item.id) orelse return error.NotLaidOut;
        f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
        break;
    };
    try t.expect(e.minimized);
    f.tester.advance(0.08);
    // Midway: card and pill both there, each faded and scaled toward the corner.
    try t.expectEqual(@as(usize, 2), layers(&f, &s));
    for (s) |st| {
        try t.expect(st.opacity > 0.02 and st.opacity < 0.98);
        try t.expect(st.scale < 0.999);
    }
    try t.expect(f.tester.hasText("Feynman Researcher"));
    try t.expect(f.tester.hasText("Feynman · 1 section"));

    f.tester.settle(1);
    try t.expectEqual(@as(usize, 1), layers(&f, &s));
    try t.expectApproxEqAbs(@as(f32, 1), s[0].opacity, 0.01);
    try t.expectApproxEqAbs(@as(f32, 1), s[0].scale, 0.01);
    try t.expect(!f.tester.hasText("Feynman Researcher"));
    try t.expect(f.tester.hasText("Feynman · 1 section"));
}

const chat = @import("chat.zig");
const client = app.ai_client;

/// What the last question (not a name or follow-ups) was sent with.
var sent_messages: usize = 0;
var sent_turn0 = false;

fn recording(ctx: ?*anyopaque, m: *app.ai_core.Ai, q: client.Ask, sink: client.Sink) ?client.Handle {
    if (!std.mem.startsWith(u8, q.system, "Name this chat") and !std.mem.startsWith(u8, q.system, "Suggest 3")) {
        sent_messages = q.messages.len;
        sent_turn0 = false;
        for (q.messages) |msg| if (std.mem.indexOf(u8, msg.text, "Observe, then test.") != null) {
            sent_turn0 = true;
        };
    }
    return chat.stream(ctx, m, q, sink);
}

test "open in chat carries the explanation into one chat, and Ask follows it there" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    chat.ready(b);
    b.kea.ai.client = .{ .ctx = null, .stream = recording };
    const tab = b.activeTab() orelse return error.NoTab;
    const e = app.researcher.track(tab, false) orelse return error.NoEntry;
    e.title = "Kea Paper";
    app.researcher.feed(e, "## [1] Abstract\nKea solve **puzzles** together.\n## [2] Method\nObserve, then test.\n");
    e.status = .done;
    f.tester.settle(1);

    try click(&f, "Open in Chat");
    const a = b.assisting orelse return error.NoChat;
    try t.expectEqualStrings("Kea Paper", a.chat.title);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    try t.expect(std.mem.indexOf(u8, a.chat.turns[0].answer, "Abstract") != null);
    try t.expect(std.mem.indexOf(u8, a.chat.turns[0].answer, "Observe, then test.") != null);
    const id = a.chat.id;
    try t.expectEqual(@as(usize, 1), b.kea.ai.chats.index.len);

    // Again: the same chat.
    try click(&f, "Open in Chat");
    try t.expect(a.chat.id.eql(id));
    try t.expectEqual(@as(usize, 1), b.kea.ai.chats.index.len);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);

    // Ask on a section: a second turn in that chat, the explanation sent with it.
    try click(&f, "Ask");
    try t.expect(a.chat.id.eql(id));
    try t.expectEqual(@as(usize, 2), a.chat.turns.len);
    try t.expect(std.mem.indexOf(u8, a.chat.turns[1].question, "Abstract") != null);
    try t.expect(sent_turn0);
    try t.expect(sent_messages >= 3);
    try t.expectEqual(@as(usize, 1), b.kea.ai.chats.index.len);
}

test "open in chat while explaining keeps the turn in step" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .tabs = 1 });
    defer f.deinit();
    const b = f.browser;
    chat.ready(b);
    const tab = b.activeTab() orelse return error.NoTab;
    const e = app.researcher.track(tab, false) orelse return error.NoEntry;
    app.researcher.feed(e, "## [1] Abstract\nKea solve ");
    e.status = .streaming;
    f.tester.settle(1);
    try click(&f, "Open in Chat");
    const a = b.assisting orelse return error.NoChat;
    try t.expect(!a.chat.turns[0].done);
    try t.expect(std.mem.indexOf(u8, a.chat.turns[0].answer, "puzzles") == null);
    app.researcher.feed(e, "**puzzles** together.\n");
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 1), a.chat.turns.len);
    try t.expect(std.mem.indexOf(u8, a.chat.turns[0].answer, "puzzles") != null);
    try t.expect(!a.chat.turns[0].done);
}
