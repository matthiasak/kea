//! Text without a size limit, selection and focus asked by the app, and
//! the text area: tested through `Tester`.
const std = @import("std");
const ui = @import("ui.zig");
const testing = std.testing;

test "100 KB set keeps every byte" {
    const big = try testing.allocator.alloc(u8, 100 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
    var buf: ui.TextBuffer = .{};
    defer buf.deinit();
    buf.set(big);
    try testing.expectEqualSlices(u8, big, buf.text());
    _ = buf.insert(50 * 1024, "middle");
    try testing.expectEqual(big.len + 6, buf.text().len);
    try testing.expectEqualStrings("middle", buf.text()[50 * 1024 ..][0..6]);
    try testing.expectEqualSlices(u8, big[50 * 1024 ..], buf.text()[50 * 1024 + 6 ..]);
    // Set from a part of itself (an address trimmed in place).
    buf.set(buf.text()[50 * 1024 ..][0..6]);
    try testing.expectEqualStrings("middle", buf.text());
}

const Field = struct {
    buf: ui.TextBuffer = .{},
    other: ui.TextBuffer = .{},
    focus: ?bool = null,
    fn view(s: *Field, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .gap = 12 });
        defer ui.end(c);
        _ = ui.textField(c, &s.other, .{ .placeholder = "Other" });
        if (s.focus) |all| c.focusNext(all);
        s.focus = null;
        _ = ui.textField(c, &s.buf, .{ .placeholder = "Address", .width = .{ .px = 300 } });
    }
    fn deinit(s: *Field) void {
        s.buf.deinit();
        s.other.deinit();
    }
};

fn selected(t: *ui.Tester) []const u8 {
    const f = t.ctx.focused_text.?;
    return f.text[@min(f.caret, f.anchor)..@max(f.caret, f.anchor)];
}

test "want_selection selects range" {
    var s: Field = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    try t.clickText("Address");
    s.buf.set("github.com");
    s.buf.want_selection = .{ 2, 10 };
    t.frame();
    const f = t.ctx.focused_text.?;
    try testing.expectEqual(@as(usize, 2), f.anchor);
    try testing.expectEqual(@as(usize, 10), f.caret);
    // Typing replaces what is selected.
    t.typeText("x");
    try testing.expectEqualStrings("gix", s.buf.text());
}

test "focusNext focuses field" {
    var s: Field = .{};
    defer s.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Field.view), .{});
    defer t.deinit();
    s.buf.set("kea.app");
    t.frame();
    try testing.expect(t.ctx.focused_text == null);
    s.focus = true;
    t.frame();
    try testing.expectEqualStrings("kea.app", t.ctx.focused_text.?.text);
    try testing.expectEqualStrings("kea.app", selected(&t));
    // Without select-all, the caret stays where it was.
    t.typeText("/x");
    s.focus = false;
    t.frame();
    try testing.expectEqualStrings("/x", s.buf.text());
    try testing.expectEqualStrings("", selected(&t));
}

const Composer = struct {
    buf: ui.TextBuffer = .{},
    sent: u32 = 0,
    max: u8 = 8,
    fn view(s: *Composer, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(20), .width = .fill });
        defer ui.end(c);
        if (ui.textArea(c, &s.buf, .{ .placeholder = "Ask", .max_lines = s.max }).submitted) s.sent += 1;
    }
};

test "shift-return inserts newline" {
    var s: Composer = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Composer.view), .{});
    defer t.deinit();
    try t.clickText("Ask");
    t.typeText("a");
    t.ctx.input.shift = true;
    t.key(.enter);
    t.ctx.input.shift = false;
    t.typeText("b");
    // ⌥Return through the input system breaks the line too.
    t.ctx.input.alt = true;
    t.textOps(&.{.{ .command = .insert_newline }});
    t.ctx.input.alt = false;
    try testing.expectEqualStrings("a\nb\n", s.buf.text());
    try testing.expectEqual(@as(u32, 0), s.sent);
}

test "return submits" {
    var s: Composer = .{};
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Composer.view), .{});
    defer t.deinit();
    try t.clickText("Ask");
    t.typeText("hello");
    t.key(.enter);
    try testing.expectEqual(@as(u32, 1), s.sent);
    t.textOps(&.{.{ .command = .insert_newline }});
    try testing.expectEqual(@as(u32, 2), s.sent);
    try testing.expectEqualStrings("hello", s.buf.text());
}

test "grows to max_lines then scrolls" {
    var s: Composer = .{ .max = 3 };
    defer s.buf.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Composer.view), .{});
    defer t.deinit();
    try t.clickText("Ask");
    t.typeText("1");
    const lh = t.ctx.focused_text.?.caret_rect.h;
    // The column: 20 of padding above and below the area.
    try testing.expectApproxEqAbs(40 + lh, t.ctx.nodes.items[1].rect.h, 0.5);
    for ("2345", 0..) |ch, i| {
        t.ctx.input.shift = true;
        t.key(.enter);
        t.ctx.input.shift = false;
        t.typeText(&.{ch});
        const lines: f32 = @floatFromInt(@min(i + 2, 3));
        try testing.expectApproxEqAbs(40 + lines * lh, t.ctx.nodes.items[1].rect.h, 0.5);
    }
    try testing.expectEqualStrings("1\n2\n3\n4\n5", s.buf.text());
    // Five lines in three: the caret's, the last, in view at the bottom.
    const caret = t.ctx.focused_text.?.caret_rect;
    try testing.expectApproxEqAbs(20 + 2 * lh, caret.y, 0.5);
    try testing.expectApproxEqAbs(caret.y, t.findText("5").?.y, 0.5);
    // ↑ walks back to the first line, which scrolls into view.
    for (0..4) |_| t.key(.up);
    try testing.expect(t.ctx.focused_text.?.caret <= 1);
    try testing.expectApproxEqAbs(@as(f32, 20), t.ctx.focused_text.?.caret_rect.y, 0.5);
}
