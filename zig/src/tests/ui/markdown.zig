//! P9: an answer's Markdown (`AnswerView`) on its own, over the fixture's browser.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

/// `markdown_view.answer` filling a window, as Ubi Chat's panel draws a turn.
pub const Answer = struct {
    b: *app.Browser,
    text: []const u8,
    o: app.markdown_view.Options = .{},
    st: app.markdown_view.State = .{},

    pub fn build(s: *Answer, c: *ui.Context) void {
        const p = app.palette.get(c.theme.dark);
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(18), .background = p.ground });
        app.markdown_view.answer(s.b, c, p, &s.st, s.text, s.o);
        ui.end(c);
    }

    /// The fixture's window shows this answer from now on.
    pub fn show(s: *Answer, f: *Fixture) void {
        f.tester.view = ui.View.init(s, build);
        f.tester.frame();
    }
};

test "markdown view renders a table and a link that opens a tab on click" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 520, .height = 420 });
    defer f.deinit();
    var answer: Answer = .{ .b = f.browser, .text =
        \\| Bird | Home |
        \\|---|---|
        \\| Kea | Alps |
        \\| Tui | Bush |
        \\
        \\See [Kea](https://example.com/kea) now.
    };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);

    // Each column's cells start at one x, the second clear of the first.
    const bird = f.tester.findText("Bird") orelse return error.NoHeader;
    const home = f.tester.findText("Home") orelse return error.NoHeader;
    for ([_][]const u8{ "Kea", "Tui" }) |s| try t.expectEqual(bird.x, (f.tester.findText(s) orelse return error.NoCell).x);
    for ([_][]const u8{ "Alps", "Bush" }) |s| try t.expectEqual(home.x, (f.tester.findText(s) orelse return error.NoCell).x);
    try t.expect(home.x >= bird.x + bird.w + 14);
    try t.expect(f.tester.findText("Tui").?.y > f.tester.findText("Kea").?.y);

    // The link shows its label; a click beside it opens nothing, on it a tab in front.
    const line = f.tester.findText("See Kea now.") orelse return error.NoLink;
    const tabs = f.browser.tabs.items.len;
    const before = f.tester.text.width("See ", .{ .size = 13 });
    const label = f.tester.text.width("Kea", .{ .size = 13 });
    f.tester.click(line.x + before / 2, line.y + line.h / 2);
    try t.expectEqual(tabs, f.browser.tabs.items.len);
    f.tester.click(line.x + before + label / 2, line.y + line.h / 2);
    try t.expectEqual(tabs + 1, f.browser.tabs.items.len);
    try t.expectEqualStrings("https://example.com/kea", f.browser.activeTab().?.url());
}

test "markdown view wraps a long code line by default, and unwrapped keeps its lines" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 520, .height = 420 });
    defer f.deinit();
    const long = comptime rep("kea ", 49) ++ "kea!";
    var answer: Answer = .{ .b = f.browser, .text = "```\n" ++ long ++ "\nsecond line\n```" };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);

    const lh = f.tester.text.lineHeight(.{ .size = 12, .mono = true });
    const wrapped = f.tester.findText(long ++ "\nsecond line") orelse return error.NoCode;
    try t.expect(wrapped.x + wrapped.w <= 520 - 18);
    try t.expect(wrapped.h >= 3 * lh);
    try f.tester.clickText("Unwrap");
    f.tester.settle(1);

    // Unwrapped: a line each, the long one wider than the window.
    try t.expect(f.tester.findText("Wrap") != null);
    const first = f.tester.findText(long) orelse return error.NoLine;
    const second = f.tester.findText("second line") orelse return error.NoLine;
    try t.expect(first.w > 520 and first.h < 2 * lh);
    try t.expect(second.y >= first.y + first.h);
}

test "markdown view fits a wide table to the answer's width" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 520, .height = 420 });
    defer f.deinit();
    const cell = comptime rep("feathers ", 12) ++ "end";
    const row = comptime rep("| " ++ cell ++ " ", 4) ++ "|\n";
    var answer: Answer = .{ .b = f.browser, .text = "| Alpha | Beta | Gamma | Delta |\n|---|---|---|---|\n" ++ row };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);

    const lh = f.tester.text.lineHeight(.{ .size = 12.5 });
    const delta = f.tester.findText("Delta") orelse return error.NoHeader;
    try t.expect(delta.x + delta.w <= 520 - 18 - 10);
    var cells: usize = 0;
    for (f.tester.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, cell)) {
            cells += 1;
            try t.expect(n.rect.x + n.rect.w <= 520 - 18 - 10);
            try t.expect(n.rect.h >= 2 * lh);
        },
        else => {},
    };
    try t.expectEqual(@as(usize, 4), cells);
}

test "markdown view opens a link right after an inline code pill" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 520, .height = 420 });
    defer f.deinit();
    var answer: Answer = .{ .b = f.browser, .text = "Run `fetchAll` [Kea](https://example.com/kea) now." };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);

    // The pill's kerning (3.5 either side) moves the label right of the bare text widths.
    const line = f.tester.findText("Run fetchAll Kea now.") orelse return error.NoLink;
    const mono: f32 = @as(f32, 13) * @as(f32, 0.88);
    const label = line.x + f.tester.text.width("Run ", .{ .size = 13 }) + 3.5 +
        f.tester.text.width("fetchAll", .{ .size = mono, .mono = true }) + 3.5 + f.tester.text.width(" ", .{ .size = 13 });
    const tabs = f.browser.tabs.items.len;
    f.tester.click(label - 4, line.y + line.h / 2);
    try t.expectEqual(tabs, f.browser.tabs.items.len);
    f.tester.click(label + f.tester.text.width("Kea", .{ .size = 13 }) - 2, line.y + line.h / 2);
    try t.expectEqual(tabs + 1, f.browser.tabs.items.len);
    try t.expectEqualStrings("https://example.com/kea", f.browser.activeTab().?.url());
}

test "markdown view draws inline code pills, flush table rules and highlighted code" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 520, .height = 520 });
    defer f.deinit();
    var answer: Answer = .{ .b = f.browser, .text =
        \\Call `fetchAll` now.
        \\
        \\| Bird | Home |
        \\|---|---|
        \\| Kea | Alps |
        \\| Tui | Bush |
        \\
        \\```zig
        \\const n: u32 = 42; // count
        \\pub fn main() void {}
        \\```
    };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);

    // The inline code is a bordered pill within its line.
    const line = f.tester.findText("Call fetchAll now.") orelse return error.NoLine;
    var pills: usize = 0;
    for (f.tester.instances.items) |in| {
        if (in.kind == 0 and in.border_width > 0.5 and in.border_width < 1 and in.rect[0] > line.x and in.rect[0] + in.rect[2] < line.x + line.w and in.rect[1] < line.y + line.h and in.rect[1] + in.rect[3] > line.y) pills += 1;
    }
    try t.expectEqual(@as(usize, 1), pills);

    // The table is flush: a rule under the header and one between the rows.
    const bird = f.tester.findText("Bird") orelse return error.NoHeader;
    const tui = f.tester.findText("Tui") orelse return error.NoCell;
    var rules: usize = 0;
    for (f.tester.instances.items) |in| {
        if (in.kind == 0 and in.rect[3] > 0 and in.rect[3] <= 1.01 and in.rect[2] > 40 and in.rect[1] > bird.y and in.rect[1] < tui.y) rules += 1;
    }
    try t.expectEqual(@as(usize, 2), rules);

    // The code's glyphs wear several syntax colours.
    const src = f.tester.findText("const n: u32 = 42; // count\npub fn main() void {}") orelse return error.NoCode;
    var colours: std.ArrayList([4]f32) = .empty;
    defer colours.deinit(t.allocator);
    for (f.tester.instances.items) |in| {
        if (in.kind != 1 or in.rect[1] < src.y or in.rect[1] > src.y + src.h or in.rect[0] < src.x) continue;
        for (colours.items) |col| {
            if (std.mem.eql(f32, &col, &in.color)) break;
        } else try colours.append(t.allocator, in.color);
    }
    try t.expect(colours.items.len >= 5);
}

/// The node of the text `s` drawn last frame: its box and style.
pub fn textNode(f: *Fixture, s: []const u8) ?struct { rect: ui.Rect, style: ui.TextStyle } {
    for (f.tester.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, s)) return .{ .rect = n.rect, .style = tx.style },
        else => {},
    };
    return null;
}

/// The box of the canvas copying `copy` (a formula) drawn last frame.
pub fn findCanvas(f: *Fixture, copy: []const u8) ?ui.Rect {
    for (f.tester.ctx.nodes.items) |n| switch (n.content) {
        .canvas => |cv| if (std.mem.eql(u8, cv.copy_text, copy)) return n.rect,
        else => {},
    };
    return null;
}

/// Drags from byte `at` of the text `s` to the right edge of the canvas
/// copying `copy`, and copies.
pub fn dragToCanvas(f: *Fixture, s: []const u8, at: usize, copy: []const u8) !void {
    const n = textNode(f, s) orelse return error.NoText;
    const cv = findCanvas(f, copy) orelse return error.NoCanvas;
    const lh = f.tester.text.lineHeight(n.style);
    f.tester.drag(n.rect.x + f.tester.text.caretX(s, n.style, at) + 0.5, n.rect.y + n.rect.h - lh / 2, cv.x + cv.w - 1, cv.y + cv.h / 2);
    f.tester.textOps(&.{.{ .command = .copy }});
}

fn inside(in: anytype, r: ui.Rect) bool {
    return in.rect[0] >= r.x - 1 and in.rect[0] + in.rect[2] <= r.x + r.w + 1 and in.rect[1] >= r.y - 1 and in.rect[1] + in.rect[3] <= r.y + r.h + 1;
}

const softmax =
    \\Suppose (**logits**) $z = [z_1, z_2, \dots, z_K]$ with $p_i \in (0, 1)$.
    \\
    \\$$p_i = \frac{e^{z_i}}{\sum_{j=1}^K e^{z_j}}$$
    \\
    \\$$\mathcal{L} = -\sum_{i=1}^K q_i \log(p_i)$$
    \\
    \\$$\sqrt[3]{x^2 + 1}$$
;

test "markdown math draws glyphs, rules and segments on the GPU, no pictures" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 620, .height = 520 });
    defer f.deinit();
    var answer: Answer = .{ .b = f.browser, .text = softmax };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);

    var kinds: [32]usize = @splat(0);
    for (f.tester.instances.items) |in| kinds[@min(31, @as(usize, @intFromFloat(in.kind)))] += 1;
    try t.expectEqual(@as(usize, 0), kinds[3]);
    try t.expect(kinds[0] > 0 and kinds[1] > 0 and kinds[6] > 0);
    try t.expect(f.tester.hasText("Suppose (logits) "));
    try t.expect(findCanvas(&f, "$z = [z_1, z_2, \\dots, z_K]$") != null);

    // The fraction: numerator over the bar over the denominator.
    const frac = findCanvas(&f, "$$p_i = \\frac{e^{z_i}}{\\sum_{j=1}^K e^{z_j}}$$") orelse return error.NoFraction;
    const bar = for (f.tester.instances.items) |in| {
        if (in.kind == 0 and inside(in, frac) and in.rect[3] <= 3 and in.rect[2] > 20) break in;
    } else return error.NoBar;
    var num: ?f32 = null;
    var den: ?f32 = null;
    for (f.tester.instances.items) |in| if (in.kind == 1 and inside(in, frac)) {
        const cx = in.rect[0] + in.rect[2] / 2;
        if (cx < bar.rect[0] or cx > bar.rect[0] + bar.rect[2]) continue;
        if (in.rect[1] + in.rect[3] <= bar.rect[1] + 1) num = @min(num orelse in.rect[1], in.rect[1]);
        if (in.rect[1] >= bar.rect[1] + bar.rect[3] - 1) den = @max(den orelse in.rect[1], in.rect[1]);
    };
    try t.expect(num.? < bar.rect[1] and bar.rect[1] < den.?);

    // Display ∑: its limits above and below it.
    const loss = findCanvas(&f, "$$\\mathcal{L} = -\\sum_{i=1}^K q_i \\log(p_i)$$") orelse return error.NoLoss;
    var sum: ?@TypeOf(bar) = null;
    for (f.tester.instances.items) |in| if (in.kind == 1 and inside(in, loss)) {
        if (sum == null or in.rect[3] > sum.?.rect[3]) sum = in;
    };
    const s = sum.?.rect;
    var above = false;
    var below = false;
    for (f.tester.instances.items) |in| if (in.kind == 1 and inside(in, loss)) {
        const cx = in.rect[0] + in.rect[2] / 2;
        const cy = in.rect[1] + in.rect[3] / 2;
        if (cx < s[0] or cx > s[0] + s[2]) continue;
        above = above or cy < s[1];
        below = below or cy > s[1] + s[3];
    };
    try t.expect(above and below);
}

test "markdown selection copies the Markdown: emphasis, inline and display math" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 520, .height = 420 });
    defer f.deinit();
    var answer: Answer = .{ .b = f.browser, .text = "Suppose (**logits**) $z_i$\n\n$$\\frac{a}{b}$$\n\n- one **two**\n- three" };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);

    try dragToCanvas(&f, "Suppose (logits) ", 8, "$z_i$");
    try t.expectEqualStrings("(**logits**) $z_i$", f.tester.clipboard.items);

    const cv = findCanvas(&f, "$$\\frac{a}{b}$$") orelse return error.NoCanvas;
    f.tester.drag(cv.x + 2, cv.y + cv.h / 2, cv.x + cv.w - 1, cv.y + cv.h / 2);
    f.tester.textOps(&.{.{ .command = .copy }});
    try t.expectEqualStrings("$$\\frac{a}{b}$$", f.tester.clipboard.items);

    // From the formula through the list: its markers as written.
    const three = textNode(&f, "three") orelse return error.NoItem;
    f.tester.drag(cv.x + 2, cv.y + cv.h / 2, three.rect.x + three.rect.w + 2, three.rect.y + three.rect.h / 2);
    f.tester.textOps(&.{.{ .command = .copy }});
    try t.expectEqualStrings("$$\\frac{a}{b}$$\n\n- one **two**\n- three", f.tester.clipboard.items);
}

/// `s` `n` times over.
fn rep(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ s;
    return out;
}

test "a streaming answer paces its words out and shows its unfinished tail as it will look" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 520, .height = 420 });
    defer f.deinit();
    var answer: Answer = .{ .b = f.browser, .text = "First paragraph.\n\nSome **bold", .o = .{ .stream_id = 7 } };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);
    try t.expect(f.tester.hasText("First paragraph."));
    // The open `**` styled already, not shown.
    try t.expect(f.tester.hasText("Some bold"));

    answer.text = "First paragraph.\n\nSome **bold** words, and more words that keep coming, see [Kea](https://exa";
    f.tester.frame();
    try t.expect(!f.tester.containsText("Kea"));
    f.tester.settle(1);
    // The half-written link shows as its label.
    try t.expect(f.tester.hasText("Some bold words, and more words that keep coming, see Kea"));

    // Done: drawn whole at once.
    answer.text = "First paragraph.\n\nSome **bold** done.";
    answer.o.stream_id = null;
    f.tester.frame();
    try t.expect(f.tester.hasText("Some bold done."));
}
