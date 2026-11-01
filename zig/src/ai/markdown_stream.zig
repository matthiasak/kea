//! An answer as it streams in (markdown_view.zig): its words paced out at
//! the display's rate rather than in network bursts, the blocks already
//! finished parsed once and kept, and the unfinished tail made to look as
//! it will when done — an emphasis styled from its first letter, a link
//! still being written shown as its words.
const std = @import("std");
const ui = @import("nanoui").ui;
const State = @import("markdown_view.zig").State;

/// How much of a stream is shown, in bytes.
pub const Cursor = struct { pos: f32 };

/// What of `full` to show this frame: all of it unless it streams
/// (`stream_id`) and motion is welcome; otherwise a cursor gaining on its
/// end, faster the further behind.
pub fn visibleSlice(st: *State, gpa: std.mem.Allocator, c: *ui.Context, stream_id: ?u64, full: []const u8) []const u8 {
    const id = stream_id orelse return full;
    if (c.reduce_motion or full.len == 0) {
        _ = st.streams.remove(id);
        return full;
    }
    const total: f32 = @floatFromInt(full.len);
    // First seen (a turn scrolled back into view, a chat opened mid-answer): what came is shown.
    const gop = st.streams.getOrPut(gpa, id) catch return full;
    if (!gop.found_existing) gop.value_ptr.* = .{ .pos = total };
    const cur = gop.value_ptr;
    cur.pos = @min(cur.pos, total);
    const backlog = total - cur.pos;
    cur.pos = @min(total, cur.pos + @max(140.0, backlog * 18.0) * @min(c.dt, 0.05));
    var n: usize = @intFromFloat(cur.pos);
    if (n < full.len) {
        c.animating = true;
        while (n > 0 and full[n] & 0xc0 == 0x80) n -= 1;
    }
    return full[0..n];
}

const Open = struct { tok: []const u8, fence: bool };

const Scan = struct { settled: usize, open: bool };

/// Where `text`'s finished blocks end, and whether a fence or display math is still open at its end.
fn scan(text: []const u8) Scan {
    var settled: usize = 0;
    var open: ?Open = null;
    var prev_blank = false;
    var pos: usize = 0;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..end];
        const t = std.mem.trim(u8, line, " \t\r");
        // After a blank line, a block starting at the margin: what came before is finished.
        if (prev_blank and open == null and t.len > 0 and line[0] != ' ' and line[0] != '\t') settled = pos;
        if (open) |o| {
            const closes = if (o.fence)
                std.mem.startsWith(u8, t, o.tok) and std.mem.trim(u8, t[o.tok.len..], " \t`~").len == 0
            else
                std.mem.indexOf(u8, t, o.tok) != null;
            if (closes) open = null;
        } else open = opener(t);
        prev_blank = t.len == 0;
        pos = end + 1;
    }
    return .{ .settled = settled, .open = open != null };
}

fn opener(t: []const u8) ?Open {
    if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) {
        var n: usize = 3;
        while (n < t.len and t[n] == t[0]) n += 1;
        return .{ .tok = t[0..n], .fence = true };
    }
    if (std.mem.startsWith(u8, t, "$$") and !(t.len > 4 and std.mem.endsWith(u8, t, "$$"))) return .{ .tok = "$$", .fence = false };
    if (std.mem.startsWith(u8, t, "\\[") and !std.mem.endsWith(u8, t, "\\]")) return .{ .tok = "\\]", .fence = false };
    if (std.mem.startsWith(u8, t, "\\begin{") and std.mem.indexOf(u8, t, "\\end{") == null) return .{ .tok = "\\end{", .fence = false };
    return null;
}

/// The byte after the last blank line between finished blocks of `text`,
/// outside any open code fence or display math: what before it won't change.
pub fn splitSettled(text: []const u8) usize {
    return scan(text).settled;
}

const Kind = enum { bold, italic, strike };

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn runOf(s: []const u8, i: usize) usize {
    var n: usize = 1;
    while (i + n < s.len and s[i + n] == s[i]) n += 1;
    return n;
}

/// The unfinished `tail` as it will look done (on `a`): a link still being
/// written shown as its label, and its last line's open `` ` ``, `**`,
/// `*` and `~~` closed, a delimiter with nothing yet after it left out.
/// Inside an open fence or display math it is left as it is.
pub fn stabilizeTail(a: std.mem.Allocator, tail: []const u8) ![]const u8 {
    if (scan(tail).open) return tail;
    const ls = if (std.mem.lastIndexOfScalar(u8, tail, '\n')) |k| k + 1 else 0;
    var line = tail[ls..];
    var changed = false;
    if (std.mem.lastIndexOf(u8, line, "](")) |rb| if (std.mem.indexOfScalarPos(u8, line, rb + 2, ')') == null) {
        if (std.mem.lastIndexOfScalar(u8, line[0..rb], '[')) |lb| {
            const from = if (lb > 0 and line[lb - 1] == '!') lb - 1 else lb;
            line = try std.mem.concat(a, u8, &.{ line[0..from], line[lb + 1 .. rb] });
            changed = true;
        }
    };

    var stack: [16]Kind = undefined;
    var depth: usize = 0;
    var code_at: ?usize = null;
    var code_n: usize = 0;
    var keep = line.len;
    var i: usize = 0;
    scan_line: while (i < line.len) {
        const ch = line[i];
        if (code_at != null) {
            if (ch == '`') {
                const n = runOf(line, i);
                if (n == code_n) code_at = null;
                i += n;
            } else i += 1;
            continue;
        }
        switch (ch) {
            '\\' => i += 2,
            '`' => {
                const n = runOf(line, i);
                if (i + n == line.len) {
                    keep = i;
                    break :scan_line;
                }
                code_at = i;
                code_n = n;
                i += n;
            },
            '*', '~' => {
                const n = runOf(line, i);
                const before_ws = i == 0 or isWs(line[i - 1]);
                const at_end = i + n == line.len;
                const after_ws = at_end or isWs(line[i + n]);
                const kinds: []const Kind = if (ch == '~')
                    (if (n >= 2) &.{.strike} else &.{})
                else switch (n) {
                    1 => &.{.italic},
                    2 => &.{.bold},
                    else => &.{ .bold, .italic },
                };
                var closed = false;
                for (kinds) |k| {
                    const at = std.mem.lastIndexOfScalar(Kind, stack[0..depth], k);
                    if (!before_ws and at != null) {
                        std.mem.copyForwards(Kind, stack[at.?..], stack[at.? + 1 .. depth]);
                        depth -= 1;
                        closed = true;
                    } else if (!after_ws and depth < stack.len) {
                        stack[depth] = k;
                        depth += 1;
                    }
                }
                if (at_end and !closed and kinds.len > 0) {
                    keep = i;
                    break :scan_line;
                }
                i += n;
            },
            else => i += 1,
        }
    }
    if (code_at) |at| if (at + code_n >= keep) {
        keep = at;
        code_at = null;
    };
    if (!changed and keep == line.len and code_at == null and depth == 0) return tail;

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, tail[0..ls]);
    const body = line[0..keep];
    try out.appendSlice(a, if (code_at != null or depth > 0) std.mem.trimEnd(u8, body, " \t") else body);
    if (code_at != null) try out.appendNTimes(a, '`', code_n);
    while (depth > 0) {
        depth -= 1;
        try out.appendSlice(a, switch (stack[depth]) {
            .bold => "**",
            .italic => "*",
            .strike => "~~",
        });
    }
    return out.items;
}

const testing = std.testing;

test "splitSettled: finished blocks before the last blank line, never inside a fence" {
    try testing.expectEqual(@as(usize, 10), splitSettled("para one\n\npara two"));
    try testing.expectEqual(@as(usize, 0), splitSettled("para one\npara"));
    try testing.expectEqual(@as(usize, 3), splitSettled("a\n\n```zig\nconst x = 1;\n\nmore"));
    try testing.expectEqual(@as(usize, 3), splitSettled("a\n\n$$\nx\n\ny"));
    try testing.expectEqual(@as(usize, 3), splitSettled("a\n\n\\[\nx\n\ny"));
    try testing.expectEqual(@as(usize, 11), splitSettled("```\nx\n```\n\nb"));
    try testing.expectEqual(@as(usize, 11), splitSettled("$$x = 1$$\n\nb"));
    // An indented line goes on with the list item above it.
    try testing.expectEqual(@as(usize, 0), splitSettled("1. a\n\n   more"));
}

test "stabilizeTail: open inlines closed, a half-written link shown as its label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Some **bold**", try stabilizeTail(a, "Some **bold"));
    try testing.expectEqualStrings("a *it*", try stabilizeTail(a, "a *it"));
    try testing.expectEqualStrings("run `code`", try stabilizeTail(a, "run `code"));
    try testing.expectEqualStrings("~~gone~~", try stabilizeTail(a, "~~gone"));
    try testing.expectEqualStrings("***both***", try stabilizeTail(a, "***both"));
    try testing.expectEqualStrings("see title", try stabilizeTail(a, "see [title](https://half-url"));
    try testing.expectEqualStrings("**see title**", try stabilizeTail(a, "**see [title](https://ha"));
    try testing.expectEqualStrings("x ", try stabilizeTail(a, "x **"));
    try testing.expectEqualStrings("x ", try stabilizeTail(a, "x `"));
    try testing.expectEqualStrings("first\n**b**", try stabilizeTail(a, "first\n**b "));
    // Already whole, or not emphasis at all: as it is.
    try testing.expectEqualStrings("**bold** and [l](u)", try stabilizeTail(a, "**bold** and [l](u)"));
    try testing.expectEqualStrings("2 * 3", try stabilizeTail(a, "2 * 3"));
    try testing.expectEqualStrings("`a*b` c", try stabilizeTail(a, "`a*b` c"));
    // Inside an open fence or display math nothing is touched.
    try testing.expectEqualStrings("```zig\nconst s = \"**", try stabilizeTail(a, "```zig\nconst s = \"**"));
    try testing.expectEqualStrings("$$\n\\frac{a", try stabilizeTail(a, "$$\n\\frac{a"));
}
