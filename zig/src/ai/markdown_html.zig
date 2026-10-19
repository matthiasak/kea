//! `Markdown.html`: an answer as HTML for the clipboard, beside the
//! Markdown as written; and the block parser's tests.
const std = @import("std");
const regex = @import("regex.zig");
const md = @import("markdown.zig");

fn escape(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var s = try std.mem.replaceOwned(u8, a, text, "&", "&amp;");
    s = try std.mem.replaceOwned(u8, a, s, "<", "&lt;");
    s = try std.mem.replaceOwned(u8, a, s, ">", "&gt;");
    return std.mem.replaceOwned(u8, a, s, "\"", "&quot;");
}

fn inline_(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var s = try escape(a, text);
    s = try regex.replace(a, s, "`([^`]+)`", "<code>$1</code>");
    s = try regex.replace(a, s, "\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>");
    s = try regex.replace(a, s, "\\*([^*\\s][^*]*)\\*", "<em>$1</em>");
    return regex.replace(a, s, "\\[([^\\]]+)\\]\\((https?://[^\\s)]+)\\)", "<a href=\"$2\">$1</a>");
}

fn row(a: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, tag: []const u8) !void {
    var inner = line;
    if (std.mem.startsWith(u8, inner, "|")) inner = inner[1..];
    if (std.mem.endsWith(u8, inner, "|")) inner = inner[0 .. inner.len - 1];
    try out.appendSlice(a, "<tr>");
    var it = std.mem.splitScalar(u8, inner, '|');
    while (it.next()) |cell| try out.print(a, "<{s}>{s}</{s}>", .{ tag, try inline_(a, std.mem.trim(u8, cell, " \t")), tag });
    try out.appendSlice(a, "</tr>");
}

/// The HTML, on `a` (an arena).
// ponytail: one level of list; nest when answers need it
pub fn html(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "<meta charset=\"utf-8\">");
    var open: []const u8 = "";
    var lines: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |l| try lines.append(a, l);
    const close = struct {
        fn run(alloc: std.mem.Allocator, o: *std.ArrayList(u8), which: *[]const u8) !void {
            for ([_][]const u8{ "p", "ul", "ol", "table" }) |tag| if (std.mem.eql(u8, which.*, tag)) {
                try o.print(alloc, "</{s}>", .{tag});
            };
            which.* = "";
        }
    }.run;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, open, "pre")) {
            if (std.mem.startsWith(u8, trimmed, "```")) {
                try out.appendSlice(a, "</code></pre>");
                open = "";
            } else try out.print(a, "{s}\n", .{try escape(a, line)});
        } else if (std.mem.startsWith(u8, trimmed, "```")) {
            try close(a, &out, &open);
            try out.appendSlice(a, "<pre><code>");
            open = "pre";
        } else if (trimmed.len == 0) {
            try close(a, &out, &open);
        } else if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***")) {
            try close(a, &out, &open);
            try out.appendSlice(a, "<hr>");
        } else if (try regex.groups(a, "^(#{1,6})\\s+(.+)$", trimmed)) |g| {
            try close(a, &out, &open);
            try out.print(a, "<h{d}>{s}</h{d}>", .{ g[1].len, try inline_(a, g[2]), g[1].len });
        } else if (std.mem.startsWith(u8, trimmed, "|") and std.mem.eql(u8, open, "table")) {
            try row(a, &out, trimmed, "td");
        } else if (std.mem.startsWith(u8, trimmed, "|") and i + 1 < lines.items.len and
            regex.contains("^\\s*\\|?\\s*:?-{3,}:?\\s*(\\|\\s*:?-{3,}:?\\s*)*\\|?\\s*$", lines.items[i + 1]))
        {
            try close(a, &out, &open);
            try out.appendSlice(a, "<table>");
            try row(a, &out, trimmed, "th");
            open = "table";
            i += 1;
        } else if (try regex.groups(a, "^[-*+]\\s+(.+)$", trimmed)) |g| {
            if (!std.mem.eql(u8, open, "ul")) {
                try close(a, &out, &open);
                try out.appendSlice(a, "<ul>");
                open = "ul";
            }
            try out.print(a, "<li>{s}</li>", .{try inline_(a, g[1])});
        } else if (try regex.groups(a, "^\\d+[.)]\\s+(.+)$", trimmed)) |g| {
            if (!std.mem.eql(u8, open, "ol")) {
                try close(a, &out, &open);
                try out.appendSlice(a, "<ol>");
                open = "ol";
            }
            try out.print(a, "<li>{s}</li>", .{try inline_(a, g[1])});
        } else {
            if (std.mem.eql(u8, open, "p")) {
                try out.appendSlice(a, "<br>");
            } else {
                try close(a, &out, &open);
                try out.appendSlice(a, "<p>");
                open = "p";
            }
            try out.appendSlice(a, try inline_(a, trimmed));
        }
    }
    if (std.mem.eql(u8, open, "pre")) try out.appendSlice(a, "</code></pre>") else try close(a, &out, &open);
    return out.items;
}

// MARK: tests

const t = std.testing;

test "markdown blocks: headings, paragraphs, rules, quotes" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const b = try md.blocks(arena.allocator(), "# Title ##\r\nOne\ntwo\n\n---\n> quoted\n> # inside\n## C#\n####### seven\n#nospace");
    try t.expectEqual(@as(usize, 6), b.len);
    try t.expectEqualStrings("Title", b[0].heading.text);
    try t.expectEqual(@as(u8, 1), b[0].heading.level);
    try t.expectEqualStrings("One\ntwo", b[1].paragraph);
    try t.expect(b[2] == .rule);
    try t.expectEqualStrings("quoted", b[3].quote[0].paragraph);
    try t.expectEqualStrings("inside", b[3].quote[1].heading.text);
    try t.expectEqualStrings("C#", b[4].heading.text);
    try t.expectEqualStrings("####### seven\n#nospace", b[5].paragraph);
}

test "markdown blocks: code fences" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const b = try md.blocks(arena.allocator(), "```Mermaid extra\ngraph TD\n  A-->B\n```\n~~~~\nopen\n~~~\n");
    try t.expectEqual(@as(usize, 2), b.len);
    try t.expectEqualStrings("mermaid", b[0].code.language);
    try t.expectEqualStrings("graph TD\n  A-->B", b[0].code.text);
    try t.expect(b[0].code.closed);
    // A shorter marker doesn't close a longer fence.
    try t.expect(!b[1].code.closed);
    try t.expectEqualStrings("open\n~~~\n", b[1].code.text);
    const inline_ticks = try md.blocks(arena.allocator(), "``` a`b");
    try t.expect(inline_ticks[0] == .paragraph);
}

test "markdown blocks: lists, nesting and loose items" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const b = try md.blocks(arena.allocator(), "3. three\n4. four\n   - inner\n   - inner2\n\n5. five\nafter\n- bullet");
    try t.expectEqual(@as(usize, 2), b.len);
    const l = b[0].list;
    try t.expect(l.ordered);
    try t.expectEqual(@as(i64, 3), l.start);
    try t.expectEqual(@as(usize, 3), l.items.len);
    try t.expectEqualStrings("four", l.items[1][0].paragraph);
    try t.expectEqual(@as(usize, 2), l.items[1][1].list.items.len);
    try t.expectEqualStrings("inner2", l.items[1][1].list.items[1][0].paragraph);
    // A lazy continuation line joins the item's paragraph.
    try t.expectEqualStrings("five\nafter", l.items[2][0].paragraph);
    try t.expect(!b[1].list.ordered);
    // Not a marker: no space after it, or a rule.
    const c = try md.blocks(arena.allocator(), "-nospace\n* * *");
    try t.expect(c[0] == .paragraph);
    try t.expect(c[1] == .rule);
}

test "markdown blocks: tables pad and cut rows" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const b = try md.blocks(arena.allocator(), "| A | B |\n|---|:-:|\n| 1 |\n| 2 | 3 | 4 |\nafter");
    try t.expectEqual(@as(usize, 2), b.len);
    const tb = b[0].table;
    try t.expectEqualStrings("B", tb.header[1]);
    try t.expectEqual(@as(usize, 2), tb.rows.len);
    try t.expectEqualStrings("", tb.rows[0][1]);
    try t.expectEqual(@as(usize, 2), tb.rows[1].len);
    try t.expectEqualStrings("3", tb.rows[1][1]);
    try t.expectEqualStrings("after", b[1].paragraph);
}

test "markdown blocks: deep quotes fall back to a paragraph" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var b = try md.blocks(arena.allocator(), ">>>>>>>> deep\n>>>>>>>> two");
    var depth: usize = 0;
    while (b[0] == .quote) : (depth += 1) b = b[0].quote;
    try t.expectEqual(@as(usize, 7), depth);
    try t.expectEqualStrings("> deep\n> two", b[0].paragraph);
}

test "markdown html for the clipboard" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const out = try html(arena.allocator(), "# Hi\nSome **bold** `x<y` and [a](https://a.com)\nmore\n\n- one\n- *two*\n\n| A | B |\n|---|---|\n| 1 | 2 |\n```\n<tag>\n```");
    try t.expectEqualStrings(
        "<meta charset=\"utf-8\"><h1>Hi</h1><p>Some <strong>bold</strong> <code>x&lt;y</code> and <a href=\"https://a.com\">a</a><br>more</p>" ++
            "<ul><li>one</li><li><em>two</em></li></ul><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table><pre><code>&lt;tag&gt;\n</code></pre>",
        out,
    );
}
