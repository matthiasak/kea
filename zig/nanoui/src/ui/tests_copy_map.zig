//! Text that copies its source (`CopyMap`), canvases with glyph runs and a
//! source copied whole (`Canvas.copy_text`), and a selection taking ⌘C
//! from the field focused before it.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");

const style: ui.TextStyle = .{ .size = 13 };

// "say **bold** now" shown as "say bold now".
const bold_str = "say bold now";
const bold_cm: ui.CopyMap = .{
    .src = "say **bold** now",
    .open = &.{ 0, 1, 2, 3, 4, 7, 8, 9, 12, 13, 14, 15, 16 },
    .close = &.{ 0, 1, 2, 3, 4, 7, 8, 9, 12, 13, 14, 15, 16 },
    .wraps = &.{.{ .start = 4, .end = 8, .open = "**", .close = "**" }},
};
const long_str = "one two three four five six seven eight nine ten eleven twelve";

const Page = struct {
    buf: ui.TextBuffer = .{},
    fn view(p: *Page, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull().p(10).gap(14);
        defer root.end();
        _ = ui.textField(c, &p.buf, .{ .placeholder = "Ask" });
        const sel = ui.div(c).column().gap(14);
        c.node(sel.index).style.selectable = true;
        defer sel.end();
        _ = c.leaf(.{}, .{ .text = .{ .str = bold_str, .style = style, .color = c.theme.text, .copy = bold_cm } }, null);
        var wrap = style;
        wrap.wrap = true;
        _ = c.leaf(.{ .width = .{ .px = 120 } }, .{ .text = .{ .str = long_str, .style = wrap, .color = c.theme.text, .copy = .{ .src = long_str } } }, null);
        const cv = ui.canvas(c, .{ .width = .{ .px = 80 }, .height = .{ .px = 30 } });
        cv.copy_text = "$$\\frac{a}{b}$$";
        cv.text(.{ .x = 4, .y = 20 }, "x+1", .{ .size = 14, .math = true });
        cv.line(.{ .x = 40, .y = 15 }, .{ .x = 70, .y = 15 }, .{ .color = c.theme.text });
    }
};

fn open(t: *ui.Tester, p: *Page) !void {
    try t.init(testing.allocator, .init(p, Page.view), .{ .width = 320, .height = 360 });
    t.settle(1);
}

test "a canvas's glyph runs are glyphs, not pictures" {
    var p: Page = .{};
    defer p.buf.deinit();
    var t: ui.Tester = undefined;
    try open(&t, &p);
    defer t.deinit();
    const lr = t.findText(long_str).?;
    const top = lr.y + lr.h + 14;
    // "x+1" in the canvas at (10, top), 80 by 30.
    var glyphs: usize = 0;
    for (t.instances.items) |i| {
        try testing.expect(i.kind != gpu.Kind.image);
        if (i.kind == gpu.Kind.text and i.rect[0] >= 10 and i.rect[0] < 90 and i.rect[1] >= top and i.rect[1] < top + 30) glyphs += 1;
    }
    try testing.expectEqual(@as(usize, 3), glyphs);
}

test "a selection cut through bold copies its source, balanced" {
    var p: Page = .{};
    defer p.buf.deinit();
    var t: ui.Tester = undefined;
    try open(&t, &p);
    defer t.deinit();
    const r = t.findText(bold_str).?;
    const x5 = r.x + t.ctx.text.caretX(bold_str, style, 5);
    const x10 = r.x + t.ctx.text.caretX(bold_str, style, 10);
    t.drag(x5, r.y + r.h / 2, x10, r.y + r.h / 2);
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("**old** n", t.clipboard.items);
}

test "a wrapped text copies as its source, without newlines at its wraps" {
    var p: Page = .{};
    defer p.buf.deinit();
    var t: ui.Tester = undefined;
    try open(&t, &p);
    defer t.deinit();
    const r = t.findText(long_str).?;
    try testing.expect(r.h > 30); // wrapped
    t.drag(r.x + 0.5, r.y + 4, r.x + r.w + 4, r.y + r.h - 4);
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings(long_str, t.clipboard.items);
}

test "a canvas's copy text is selected whole, and the selection takes ⌘C from a focused field" {
    var p: Page = .{};
    defer p.buf.deinit();
    var t: ui.Tester = undefined;
    try open(&t, &p);
    defer t.deinit();
    // The field focused, its own text selected.
    const field = t.findText("Ask").?;
    t.click(field.x + 4, field.y + field.h / 2);
    t.typeText("hello");
    t.textOps(&.{.{ .command = .select_all }});
    t.frame();
    try testing.expect(t.ctx.focused_text != null);
    // From the canvas's middle to past its right side: all of it.
    const lr = t.findText(long_str).?;
    const top = lr.y + lr.h + 14;
    t.drag(10 + 30, top + 15, 10 + 78, top + 15);
    try testing.expect(t.ctx.focus == 0);
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("$$\\frac{a}{b}$$", t.clipboard.items);
}

test "a selection from bold across the wrapped text into the canvas" {
    var p: Page = .{};
    defer p.buf.deinit();
    var t: ui.Tester = undefined;
    try open(&t, &p);
    defer t.deinit();
    const r = t.findText(bold_str).?;
    const lr = t.findText(long_str).?;
    t.drag(r.x + t.ctx.text.caretX(bold_str, style, 4), r.y + r.h / 2, 10 + 78, lr.y + lr.h + 14 + 15);
    t.textOps(&.{.{ .command = .copy }});
    try testing.expectEqualStrings("**bold** now\n" ++ long_str ++ "\n$$\\frac{a}{b}$$", t.clipboard.items);
}

const Moving = struct {
    scale: f32 = 1,
    fn view(m: *Moving, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        const box = ui.div(c).column();
        c.node(box.index).style.scale = m.scale;
        c.node(box.index).style.scale_anchor = .{ .x = 0, .y = 0 };
        defer box.end();
        const cv = ui.canvas(c, .{ .width = .{ .px = 100 }, .height = .{ .px = 100 } });
        cv.line(.{ .x = 20, .y = 40 }, .{ .x = 80, .y = 40 }, .{ .color = c.theme.text, .dash = .{ 4, 2 } });
        cv.triangle(.{ .x = 0, .y = 0 }, .{ .x = 50, .y = 0 }, .{ .x = 0, .y = 50 }, c.theme.text, 7);
    }
};

test "a scaled box scales its canvas's segment ends and triangle corners" {
    var m: Moving = .{ .scale = 0.5 };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&m, Moving.view), .{ .width = 200, .height = 200 });
    defer t.deinit();
    t.settle(1);
    var seen: u8 = 0;
    for (t.instances.items) |i| {
        if (i.kind == gpu.Kind.segment) {
            try testing.expectEqualSlices(f32, &.{ 10, 20, 40, 20 }, &i.uv);
            try testing.expectEqual(@as(f32, 2), i.border_color[0]);
            seen |= 1;
        } else if (i.kind == gpu.Kind.triangle) {
            try testing.expectEqualSlices(f32, &.{ 0, 0, 25, 0 }, &i.uv);
            try testing.expectEqualSlices(f32, &.{ 0, 25 }, i.border_color[0..2]);
            seen |= 2;
        }
    }
    try testing.expectEqual(@as(u8, 3), seen);
}

test "moved points follow a layout shift" {
    var i: gpu.Instance = .{ .rect = .{ 0, 0, 1, 1 }, .color = .{ 0, 0, 0, 1 }, .uv = .{ 1, 2, 3, 4 }, .border_color = .{ 5, 6, 7, 0 }, .kind = gpu.Kind.triangle };
    @import("paint_canvas.zig").shiftPoints(&i, 10, 20);
    try testing.expectEqualSlices(f32, &.{ 11, 22, 13, 24 }, &i.uv);
    try testing.expectEqualSlices(f32, &.{ 15, 26, 7 }, i.border_color[0..3]);
    var s: gpu.Instance = .{ .rect = .{ 0, 0, 1, 1 }, .color = .{ 0, 0, 0, 1 }, .uv = .{ 1, 2, 3, 4 }, .border_color = .{ 5, 6, 7, 1 }, .kind = gpu.Kind.segment };
    @import("paint_canvas.zig").shiftPoints(&s, 10, 20);
    try testing.expectEqualSlices(f32, &.{ 11, 22, 13, 24 }, &s.uv);
    try testing.expectEqualSlices(f32, &.{ 5, 6, 7, 1 }, &s.border_color);
}
