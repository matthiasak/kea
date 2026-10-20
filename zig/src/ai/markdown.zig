//! Answers come in Markdown (Markdown.swift). This is its block parser,
//! exactly as Swift's, and the HTML made from it for the clipboard, so a
//! paste into a mail or a document keeps headings, lists, tables and code.
//! Inline emphasis on screen is the view's (markdown_view.zig).
const std = @import("std");
const regex = @import("regex.zig");
const white = @import("whitespace.zig");
const objc = @import("nanoui").objc;

pub const Block = union(enum) {
    heading: struct { level: u8, text: []const u8 },
    paragraph: []const u8,
    list: struct { ordered: bool, start: i64, items: []const []const Block },
    quote: []const Block,
    code: struct { language: []const u8, text: []const u8, closed: bool },
    table: struct { header: []const []const u8, rows: []const []const []const u8 },
    rule,
};

/// `trimmingCharacters(in: .whitespaces)`, Unicode's spaces included.
const trim = white.trim;

/// `Character.isWhitespace` of the last character of `s` (not empty).
fn endsWhite(s: []const u8) bool {
    return white.isWhite(white.at(s, white.before(s, s.len)).cp);
}

/// `lowercased()`: Foundation's, so not only ASCII letters; on `a`.
fn lower(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s) and for (s) |ch| {
        if (ch >= 0x80) break true;
    } else false) {
        const pool = objc.Pool.push();
        defer pool.pop();
        return a.dupe(u8, objc.fromNSString(objc.msg(objc.Object, objc.nsString(s), "lowercaseString", .{})));
    }
    return std.ascii.allocLowerString(a, s);
}

/// The blocks of `text`, everything on `a` (an arena).
pub fn blocks(a: std.mem.Allocator, text: []const u8) ![]const Block {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(a, if (std.mem.endsWith(u8, line, "\r")) line[0 .. line.len - 1] else line);
    return parseBlocks(a, lines.items, 0);
}

fn joinLines(a: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    return std.mem.join(a, "\n", lines);
}

fn parseBlocks(a: std.mem.Allocator, lines: []const []const u8, depth: usize) error{OutOfMemory}![]const Block {
    if (depth > 6) {
        var kept: std.ArrayList([]const u8) = .empty;
        for (lines) |l| if (trim(l).len > 0) try kept.append(a, trim(l));
        if (kept.items.len == 0) return &.{};
        const one = try a.alloc(Block, 1);
        one[0] = .{ .paragraph = try joinLines(a, kept.items) };
        return one;
    }
    var out: std.ArrayList(Block) = .empty;
    var i: usize = 0;
    while (i < lines.len) {
        const line = lines[i];
        const trimmed = trim(line);

        // 1. Fence
        if (fenceOpen(trimmed)) |fence| {
            i += 1;
            var body: std.ArrayList([]const u8) = .empty;
            var closed = false;
            while (i < lines.len) {
                const t = trim(lines[i]);
                if (std.mem.startsWith(u8, t, fence.marker) and trim(t[fence.marker.len..]).len == 0) {
                    closed = true;
                    i += 1;
                    break;
                }
                try body.append(a, lines[i]);
                i += 1;
            }
            try out.append(a, .{ .code = .{ .language = try lower(a, fence.language), .text = try joinLines(a, body.items), .closed = closed } });
            continue;
        }

        // 2. Blank
        if (trimmed.len == 0) {
            i += 1;
            continue;
        }

        // 3. Rule
        if (isRule(line)) {
            try out.append(a, .rule);
            i += 1;
            continue;
        }

        // 4. Heading
        if (parseHeading(trimmed)) |h| {
            try out.append(a, .{ .heading = .{ .level = h.level, .text = h.text } });
            i += 1;
            continue;
        }

        // 5. Quote
        if (isQuoteLine(line)) {
            var q: std.ArrayList([]const u8) = .empty;
            while (i < lines.len and isQuoteLine(lines[i])) : (i += 1) try q.append(a, stripQuote(lines[i]));
            try out.append(a, .{ .quote = try parseBlocks(a, q.items, depth + 1) });
            continue;
        }

        // 6. Table
        if (std.mem.indexOfScalar(u8, line, '|') != null and i + 1 < lines.len and isTableDelimiter(lines[i + 1])) {
            const header = try tableCells(a, line);
            const cols = header.len;
            i += 2;
            var rows: std.ArrayList([]const []const u8) = .empty;
            while (i < lines.len) {
                const r = lines[i];
                if (trim(r).len == 0 or std.mem.indexOfScalar(u8, r, '|') == null) break;
                var cells = try tableCells(a, r);
                if (cells.len < cols) {
                    const padded = try a.alloc([]const u8, cols);
                    @memcpy(padded[0..cells.len], cells);
                    @memset(padded[cells.len..], "");
                    cells = padded;
                } else if (cells.len > cols) cells = cells[0..cols];
                try rows.append(a, cells);
                i += 1;
            }
            if (cols > 0) {
                try out.append(a, .{ .table = .{ .header = header, .rows = rows.items } });
                continue;
            }
        }

        // 7. List item
        if (parseListMarker(line)) |first| {
            const list_indent = first.indent;
            const ordered = first.ordered;
            var items: std.ArrayList([]const Block) = .empty;
            while (i < lines.len) {
                const cur = parseListMarker(lines[i]) orelse break;
                if (cur.indent > list_indent or cur.ordered != ordered) break;
                var item: std.ArrayList([]const u8) = .empty;
                try item.append(a, cur.rest);
                i += 1;
                while (i < lines.len) {
                    const next = lines[i];
                    const next_trim = trim(next);
                    if (next_trim.len == 0) {
                        var look = i + 1;
                        while (look < lines.len and trim(lines[look]).len == 0) look += 1;
                        if (look >= lines.len) break;
                        const peek = lines[look];
                        const sibling = if (parseListMarker(peek)) |pm| pm.indent <= list_indent and pm.ordered == ordered else false;
                        if (leadingIndent(peek) > list_indent or sibling) {
                            try item.append(a, "");
                            i += 1;
                            continue;
                        }
                        break;
                    }
                    const next_indent = leadingIndent(next);
                    if (next_indent > list_indent) {
                        try item.append(a, dedent(next, @min(next_indent, cur.content_indent)));
                        i += 1;
                        continue;
                    }
                    if (parseListMarker(next) != null or startsNonParagraphBlock(lines, i)) break;
                    try item.append(a, next_trim);
                    i += 1;
                }
                try items.append(a, try parseBlocks(a, item.items, depth + 1));
            }
            try out.append(a, .{ .list = .{ .ordered = ordered, .start = first.number, .items = items.items } });
            continue;
        }

        // 8. Paragraph
        var p: std.ArrayList([]const u8) = .empty;
        try p.append(a, trimmed);
        i += 1;
        while (i < lines.len) {
            const next_trim = trim(lines[i]);
            if (next_trim.len == 0 or startsNonParagraphBlock(lines, i)) break;
            try p.append(a, next_trim);
            i += 1;
        }
        try out.append(a, .{ .paragraph = try joinLines(a, p.items) });
    }
    return out.items;
}

fn startsNonParagraphBlock(lines: []const []const u8, index: usize) bool {
    const line = lines[index];
    const trimmed = trim(line);
    if (fenceOpen(trimmed) != null) return true;
    if (isRule(line)) return true;
    if (parseHeading(trimmed) != null) return true;
    if (isQuoteLine(line)) return true;
    if (std.mem.indexOfScalar(u8, line, '|') != null and index + 1 < lines.len and isTableDelimiter(lines[index + 1])) return true;
    return parseListMarker(line) != null;
}

const Fence = struct { marker: []const u8, language: []const u8 };

/// The fence's marker and its first word, both borrowed from `trimmed`;
/// the caller lowercases the language.
fn fenceOpen(trimmed: []const u8) ?Fence {
    for ("`~") |ch| {
        var count: usize = 0;
        while (count < trimmed.len and trimmed[count] == ch) count += 1;
        if (count >= 3) {
            const after = trim(trimmed[count..]);
            if (ch == '`' and std.mem.indexOfScalar(u8, after, '`') != null) return null;
            var words: white.Pieces(white.isWhite) = .{ .s = after };
            const word = while (words.next()) |w| {
                if (w.len > 0) break w;
            } else "";
            return .{ .marker = trimmed[0..count], .language = word };
        }
    }
    return null;
}

fn isRule(line: []const u8) bool {
    var first: u21 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const ch = white.at(line, i);
        i += ch.len;
        if (white.isWhite(ch.cp)) continue;
        if (n == 0) {
            if (ch.cp != '-' and ch.cp != '*' and ch.cp != '_') return false;
            first = ch.cp;
        } else if (ch.cp != first) return false;
        n += 1;
    }
    return n >= 3;
}

const Heading = struct { level: u8, text: []const u8 };

fn parseHeading(trimmed: []const u8) ?Heading {
    var hashes: usize = 0;
    while (hashes < trimmed.len and trimmed[hashes] == '#') hashes += 1;
    if (hashes < 1 or hashes > 6) return null;
    const rest = trimmed[hashes..];
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return null;
    var text = trim(rest);
    while (std.mem.endsWith(u8, text, "#")) {
        const dropped = text[0 .. text.len - 1];
        if (dropped.len == 0 or endsWhite(dropped)) {
            text = trim(dropped);
            break;
        } else if (dropped[dropped.len - 1] == '#') {
            text = dropped;
        } else break;
    }
    return .{ .level = @intCast(hashes), .text = text };
}

fn isQuoteLine(line: []const u8) bool {
    var spaces: usize = 0;
    for (line) |ch| {
        if (ch == ' ') {
            spaces += 1;
            if (spaces > 3) return false;
        } else return ch == '>';
    }
    return false;
}

fn stripQuote(line: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, line, '>') orelse return line;
    const after = line[idx + 1 ..];
    return if (after.len > 0 and after[0] == ' ') after[1..] else after;
}

fn isTableDelimiter(line: []const u8) bool {
    const t = trim(line);
    if (std.mem.indexOfScalar(u8, t, '|') == null or std.mem.indexOfScalar(u8, t, '-') == null) return false;
    for (t) |ch| if (ch != '|' and ch != ':' and ch != '-' and ch != ' ') return false;
    return true;
}

fn tableCells(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var s = trim(line);
    if (std.mem.startsWith(u8, s, "|")) s = s[1..];
    if (std.mem.endsWith(u8, s, "|")) s = s[0 .. s.len - 1];
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '|');
    while (it.next()) |cell| try out.append(a, trim(cell));
    return out.items;
}

fn leadingIndent(line: []const u8) usize {
    var cols: usize = 0;
    for (line) |ch| switch (ch) {
        ' ' => cols += 1,
        '\t' => cols += 4,
        else => break,
    };
    return cols;
}

fn dedent(line: []const u8, amount: usize) []const u8 {
    var left = amount;
    var idx: usize = 0;
    while (idx < line.len and left > 0) {
        if (line[idx] == ' ') {
            left -= 1;
        } else if (line[idx] == '\t') {
            left -|= 4;
        } else break;
        idx += 1;
    }
    return line[idx..];
}

const ListMarker = struct { indent: usize, ordered: bool, number: i64, content_indent: usize, rest: []const u8 };

fn parseListMarker(line: []const u8) ?ListMarker {
    if (isRule(line)) return null;
    var indent: usize = 0;
    var idx: usize = 0;
    while (idx < line.len) : (idx += 1) switch (line[idx]) {
        ' ' => indent += 1,
        '\t' => indent += 4,
        else => break,
    };
    if (idx >= line.len) return null;
    const ch = line[idx];
    var ordered = false;
    var number: i64 = 1;
    var marker_len: usize = 0;
    if (ch == '-' or ch == '*' or ch == '+') {
        marker_len = 1;
        idx += 1;
    } else if (std.ascii.isDigit(ch)) {
        const start = idx;
        var digits: usize = 0;
        while (idx < line.len and std.ascii.isDigit(line[idx]) and digits < 9) : (idx += 1) digits += 1;
        if (idx >= line.len or (line[idx] != '.' and line[idx] != ')')) return null;
        number = std.fmt.parseInt(i64, line[start..idx], 10) catch 1;
        ordered = true;
        marker_len = digits + 1;
        idx += 1;
    } else return null;
    var spaces: usize = 0;
    while (idx < line.len) : (idx += 1) switch (line[idx]) {
        ' ' => spaces += 1,
        '\t' => spaces += 4,
        else => break,
    };
    if (spaces < 1) return null;
    return .{ .indent = indent, .ordered = ordered, .number = number, .content_indent = indent + marker_len + spaces, .rest = line[idx..] };
}

test {
    _ = @import("markdown_html.zig");
    _ = white;
}

test "unicode spaces count as Swift's do" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try blocks(a, "\u{3000}- - -\u{00A0}\n```\u{00A0}ÄBC\u{2003}x\ncode\n```\n# Title\u{3000}#");
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expect(got[0] == .rule);
    try std.testing.expectEqualStrings("äbc", got[1].code.language);
    try std.testing.expectEqualStrings("Title", got[2].heading.text);
}
