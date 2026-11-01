//! markdown_inline.zig's tests: what is shown, the math in it, and
//! where each shown byte came from.
const std = @import("std");
const mi = @import("markdown_inline.zig");
const Shown = mi.Shown;
const shown = mi.shown;
const shownOpts = mi.shownOpts;

const t = std.testing;

// Freed when the test binary exits.
var test_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn expectShown(src: []const u8, want: []const u8) !Shown {
    const s = try shown(test_arena.allocator(), src);
    try t.expectEqualStrings(want, s.text);
    return s;
}

test "markdown inline: strong, emphasis, both, and what stays text" {
    var s = try expectShown("a **bold** and *it* and ***both***", "a bold and it and both");
    try t.expectEqual(@as(usize, 3), s.runs.len);
    try t.expect(s.runs[0].flags.bold and !s.runs[0].flags.italic);
    try t.expectEqualStrings("bold", s.text[s.runs[0].start..s.runs[0].end]);
    try t.expect(s.runs[1].flags.italic and !s.runs[1].flags.bold);
    try t.expect(s.runs[2].flags.italic and s.runs[2].flags.bold);
    s = try expectShown("__under__ _it_ snake_case_name", "under it snake_case_name");
    try t.expectEqual(@as(usize, 2), s.runs.len);
    s = try expectShown("2 * 3 * 4 and **open", "2 * 3 * 4 and **open");
    try t.expectEqual(@as(usize, 0), s.runs.len);
    s = try expectShown("*a **b** c*", "a b c");
    try t.expect(s.runs[0].flags.italic and !s.runs[0].flags.bold);
    try t.expect(s.runs[1].flags.italic and s.runs[1].flags.bold);
}

test "markdown inline: code spans, strikethrough, escapes, entities" {
    var s = try expectShown("run `a *b* c` now", "run a *b* c now");
    try t.expectEqual(@as(usize, 1), s.runs.len);
    try t.expect(s.runs[0].flags.code);
    s = try expectShown("``x ` y`` and `` `z` ``", "x ` y and `z`");
    s = try expectShown("~~gone~~ and ~one~", "gone and one");
    try t.expect(s.runs[0].flags.strike and s.runs[1].flags.strike);
    s = try expectShown("\\*not\\* &amp; &lt;b&gt; &#65;&#x42; \\q", "*not* & <b> AB \\q");
    try t.expectEqual(@as(usize, 0), s.runs.len);
}

test "markdown inline: links, autolinks and images" {
    var s = try expectShown("See [the **Kea**](https://example.com/kea \"t\") now", "See the Kea now");
    try t.expectEqual(@as(usize, 1), s.links.len);
    try t.expectEqualStrings("https://example.com/kea", s.links[0].url);
    try t.expectEqualStrings("the Kea", s.text[s.links[0].start..s.links[0].end]);
    try t.expect(s.runs[1].flags.bold and s.runs[1].flags.link);
    s = try expectShown("<https://a.example/x> and <me@a.example>", "https://a.example/x and me@a.example");
    try t.expectEqualStrings("mailto:me@a.example", s.links[1].url);
    s = try expectShown("![a kea](k.png) [no link] [x](y z)", "a kea [no link] [x](y z)");
    try t.expectEqual(@as(usize, 0), s.links.len);
    s = try expectShown("[a](u(1)) *[b](v)*", "a b");
    try t.expectEqualStrings("u(1)", s.links[0].url);
    try t.expect(s.runs[s.runs.len - 1].flags.italic);
}

test "markdown inline: math, and dollars that are money" {
    var s = try expectShown("$5 and $10", "$5 and $10");
    try t.expectEqual(@as(usize, 0), s.maths.len);
    s = try expectShown("costs \\$5 or \\$x\\$, $5 and $x$", "costs $5 or $x$, $5 and $x$");
    try t.expectEqual(@as(usize, 1), s.maths.len);
    try t.expectEqualStrings("x", s.maths[0].tex);
    s = try expectShown("Let $z_i$ be \\(p_i \\in (0, 1)\\) and $$\\frac{a}{b}$$.", "Let $z_i$ be \\(p_i \\in (0, 1)\\) and $$\\frac{a}{b}$$.");
    try t.expectEqual(@as(usize, 3), s.maths.len);
    try t.expectEqualStrings("z_i", s.maths[0].tex);
    try t.expectEqualStrings("$z_i$", s.text[s.maths[0].start..s.maths[0].end]);
    try t.expectEqualStrings("p_i \\in (0, 1)", s.maths[1].tex);
    try t.expect(!s.maths[1].display and s.maths[2].display);
    try t.expectEqualStrings("\\frac{a}{b}", s.maths[2].tex);
    // No emphasis inside math.
    s = try expectShown("$a_1 * b_2 * c$", "$a_1 * b_2 * c$");
    try t.expectEqual(@as(usize, 1), s.runs.len);
    try t.expect(s.runs[0].flags.math and !s.runs[0].flags.italic);
    // Unclosed: math only while streaming, and only if it reads as TeX.
    const a = test_arena.allocator();
    try t.expectEqual(@as(usize, 0), (try shown(a, "so $\\frac{e^{z")).maths.len);
    try t.expectEqualStrings("\\frac{e^{z", (try shownOpts(a, "so $\\frac{e^{z", true)).maths[0].tex);
    try t.expectEqual(@as(usize, 0), (try shownOpts(a, "costs $50 today", true)).maths.len);
    try t.expectEqualStrings("p_i = ", (try shownOpts(a, "$$p_i = ", true)).maths[0].tex);
}

/// Bytes [a, b) of `s` copied from `src` as one text's selection does (`ui.CopyMap`).
fn copied(s: Shown, src: []const u8, a: usize, b: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const al = test_arena.allocator();
    for (s.wraps) |w| if (w.start < a and a < w.end) try out.appendSlice(al, w.open);
    try out.appendSlice(al, src[s.open_map[a]..s.close_map[b]]);
    var i = s.wraps.len;
    while (i > 0) {
        i -= 1;
        if (s.wraps[i].start < b and b < s.wraps[i].end) try out.appendSlice(al, s.wraps[i].close);
    }
    return out.items;
}

test "markdown inline: where each shown byte came from, and the runs over them" {
    const src = "(**logits**) $z_i$";
    const s = try expectShown(src, "(logits) $z_i$");
    try t.expectEqualSlices(u32, &.{ 0, 1, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18 }, s.open_map);
    try t.expectEqualSlices(u32, &.{ 0, 1, 4, 5, 6, 7, 8, 11, 12, 13, 14, 15, 16, 17, 18 }, s.close_map);
    try t.expectEqual(@as(usize, 1), s.wraps.len);
    try t.expectEqual(@as(u32, 1), s.wraps[0].start);
    try t.expectEqual(@as(u32, 7), s.wraps[0].end);
    try t.expectEqualStrings("**", s.wraps[0].open);
    try t.expectEqualStrings(src, try copied(s, src, 0, s.text.len));
    try t.expectEqualStrings("**logits**", try copied(s, src, 1, 7));
    try t.expectEqualStrings("**git**", try copied(s, src, 3, 6));
    try t.expectEqualStrings("**its**) $z_i$", try copied(s, src, 4, s.text.len));

    const src2 = "Run `a b` and [the **Kea**](https://k.example) now";
    const s2 = try expectShown(src2, "Run a b and the Kea now");
    try t.expectEqualStrings(src2, try copied(s2, src2, 0, s2.text.len));
    try t.expectEqualStrings("`a b`", try copied(s2, src2, 4, 7));
    try t.expectEqualStrings("`b`", try copied(s2, src2, 6, 7));
    try t.expectEqualStrings("[the **Ke**](https://k.example)", try copied(s2, src2, 12, 18));
    const src3 = "***both*** \\$1 &amp; x";
    const s3 = try expectShown(src3, "both $1 & x");
    try t.expectEqualStrings(src3, try copied(s3, src3, 0, s3.text.len));
    try t.expectEqualStrings("***ot***", try copied(s3, src3, 1, 3));
}
