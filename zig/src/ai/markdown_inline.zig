//! `Markdown.shown` (Markdown.swift:386-398): a line of an answer as
//! Foundation's `AttributedString(markdown:)` reads it with
//! `.inlineOnlyPreservingWhitespace` — CommonMark's inlines and GFM's
//! strikethrough over text kept as written (no blocks, whitespace kept):
//! strong and emphasis, code spans, links, autolinks, images (their alt
//! text), escapes and entities. What it gives is the text shown and its
//! styled runs; the view maps them to spans.
const std = @import("std");

pub const Flags = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
    link: bool = false,
    _: u3 = 0,

    fn with(a: Flags, b: Flags) Flags {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }
    fn plain(f: Flags) bool {
        return @as(u8, @bitCast(f)) == 0;
    }
};

/// Bytes [start, end) of the shown text styled `flags` (only styled ones).
pub const Run = struct { start: u32, end: u32, flags: Flags };
/// Bytes [start, end) of the shown text that link to `url`.
pub const Link = struct { start: u32, end: u32, url: []const u8 };
pub const Shown = struct { text: []const u8, runs: []const Run, links: []const Link };

const Piece = struct {
    text: []const u8,
    flags: Flags = .{},
    link: ?u32 = null,
    /// `*`, `_`, `~` (a delimiter run), `[` or `!` (a link's or image's
    /// opening bracket), 0 for text.
    delim: u8 = 0,
    count: usize = 0,
    orig: usize = 0,
    open: bool = false,
    close: bool = false,
    active: bool = true,
};

fn isPunct(ch: u8) bool {
    return std.ascii.isPrint(ch) and !std.ascii.isAlphanumeric(ch) and ch != ' ';
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0b or ch == 0x0c;
}

/// `text` as shown, everything on `a` (an arena).
pub fn shown(a: std.mem.Allocator, text: []const u8) !Shown {
    var pieces: std.ArrayList(Piece) = .empty;
    var urls: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var plain_from: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (std.mem.indexOfScalar(u8, "\\`*_~![]<&", ch) == null) {
            i += 1;
            continue;
        }
        if (plain_from < i) try pieces.append(a, .{ .text = text[plain_from..i] });
        i = try special(a, text, i, &pieces, &urls);
        plain_from = i;
    }
    if (plain_from < text.len) try pieces.append(a, .{ .text = text[plain_from..] });
    emphasis(pieces.items, 0);

    var out: std.ArrayList(u8) = .empty;
    var runs: std.ArrayList(Run) = .empty;
    var links: std.ArrayList(Link) = .empty;
    for (pieces.items) |pc| {
        const s: []const u8 = switch (pc.delim) {
            '*', '_', '~' => pc.text[0..pc.count],
            else => pc.text,
        };
        if (s.len == 0) continue;
        const start: u32 = @intCast(out.items.len);
        try out.appendSlice(a, s);
        const end: u32 = @intCast(out.items.len);
        if (!pc.flags.plain()) {
            if (runs.items.len > 0 and runs.items[runs.items.len - 1].end == start and runs.items[runs.items.len - 1].flags == pc.flags)
                runs.items[runs.items.len - 1].end = end
            else
                try runs.append(a, .{ .start = start, .end = end, .flags = pc.flags });
        }
        if (pc.link) |l| {
            if (links.items.len > 0 and links.items[links.items.len - 1].end == start and links.items[links.items.len - 1].url.ptr == urls.items[l].ptr)
                links.items[links.items.len - 1].end = end
            else
                try links.append(a, .{ .start = start, .end = end, .url = urls.items[l] });
        }
    }
    return .{ .text = out.items, .runs = runs.items, .links = links.items };
}

/// Reads the inline at `text[i]` (one of the special characters) into
/// `pieces`; returns where reading goes on.
fn special(a: std.mem.Allocator, text: []const u8, i: usize, pieces: *std.ArrayList(Piece), urls: *std.ArrayList([]const u8)) !usize {
    const ch = text[i];
    switch (ch) {
        '\\' => {
            if (i + 1 < text.len and (isPunct(text[i + 1]) or text[i + 1] == '\n')) {
                try pieces.append(a, .{ .text = text[i + 1 .. i + 2] });
                return i + 2;
            }
        },
        '`' => {
            var n: usize = 0;
            while (i + n < text.len and text[i + n] == '`') n += 1;
            var j = i + n;
            while (j < text.len) {
                if (text[j] != '`') {
                    j += 1;
                    continue;
                }
                var m: usize = 0;
                while (j + m < text.len and text[j + m] == '`') m += 1;
                if (m == n) {
                    try pieces.append(a, .{ .text = try codeText(a, text[i + n .. j]), .flags = .{ .code = true } });
                    return j + m;
                }
                j += m;
            }
            try pieces.append(a, .{ .text = text[i .. i + n] });
            return i + n;
        },
        '*', '_', '~' => {
            var n: usize = 0;
            while (i + n < text.len and text[i + n] == ch) n += 1;
            if (ch == '~' and n > 2) {
                try pieces.append(a, .{ .text = text[i .. i + n] });
                return i + n;
            }
            const prev: ?u8 = if (i > 0) text[i - 1] else null;
            const next: ?u8 = if (i + n < text.len) text[i + n] else null;
            const prev_ws = prev == null or isWs(prev.?);
            const next_ws = next == null or isWs(next.?);
            const prev_p = prev != null and isPunct(prev.?);
            const next_p = next != null and isPunct(next.?);
            const left = !next_ws and (!next_p or prev_ws or prev_p);
            const right = !prev_ws and (!prev_p or next_ws or next_p);
            const open = if (ch == '_') left and (!right or prev_p) else left;
            const close = if (ch == '_') right and (!left or next_p) else right;
            try pieces.append(a, .{ .text = text[i .. i + n], .delim = ch, .count = n, .orig = n, .open = open, .close = close });
            return i + n;
        },
        '!' => if (i + 1 < text.len and text[i + 1] == '[') {
            try pieces.append(a, .{ .text = text[i .. i + 2], .delim = '!' });
            return i + 2;
        },
        '[' => {
            try pieces.append(a, .{ .text = text[i .. i + 1], .delim = '[' });
            return i + 1;
        },
        ']' => return closeBracket(a, text, i, pieces, urls),
        '<' => if (autolink(text[i + 1 ..])) |end| {
            const body = text[i + 1 .. i + 1 + end];
            const url = if (std.mem.indexOfScalar(u8, body, ':') == null) try std.mem.concat(a, u8, &.{ "mailto:", body }) else body;
            try urls.append(a, url);
            try pieces.append(a, .{ .text = body, .flags = .{ .link = true }, .link = @intCast(urls.items.len - 1) });
            return i + end + 2;
        },
        '&' => if (try entity(a, text[i..])) |e| {
            try pieces.append(a, .{ .text = e.text });
            return i + e.len;
        },
        else => {},
    }
    try pieces.append(a, .{ .text = text[i .. i + 1] });
    return i + 1;
}

/// A code span's content: line ends as spaces, one space stripped from
/// either end when both have one and it is not all spaces.
fn codeText(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var s = raw;
    if (std.mem.indexOfScalar(u8, s, '\n') != null) {
        const copy = try a.dupe(u8, s);
        std.mem.replaceScalar(u8, copy, '\n', ' ');
        s = copy;
    }
    if (s.len >= 2 and s[0] == ' ' and s[s.len - 1] == ' ' and std.mem.trim(u8, s, " ").len > 0) s = s[1 .. s.len - 1];
    return s;
}

/// `]`: closes the nearest open bracket into a link (or an image's alt
/// text) when an inline destination follows; else it is text.
fn closeBracket(a: std.mem.Allocator, text: []const u8, i: usize, pieces: *std.ArrayList(Piece), urls: *std.ArrayList([]const u8)) !usize {
    const items = pieces.items;
    var o = items.len;
    const opener: ?usize = while (o > 0) {
        o -= 1;
        if ((items[o].delim == '[' or items[o].delim == '!') and items[o].active) break o;
    } else null;
    const at = opener orelse {
        try pieces.append(a, .{ .text = "]" });
        return i + 1;
    };
    const dest = destination(text, i + 1) orelse {
        items[at].active = false;
        items[at].delim = 0;
        try pieces.append(a, .{ .text = "]" });
        return i + 1;
    };
    emphasis(items, at + 1);
    const image = items[at].delim == '!';
    items[at] = .{ .text = "" };
    if (!image) try urls.append(a, dest.url);
    for (items[at + 1 ..]) |*pc| {
        if (pc.delim == '*' or pc.delim == '_' or pc.delim == '~') pc.active = false;
        if (!image) {
            pc.flags.link = true;
            pc.link = @intCast(urls.items.len - 1);
        }
    }
    // No links within links: the brackets before it open none.
    if (!image) for (items[0..at]) |*pc| if (pc.delim == '[') {
        pc.active = false;
        pc.delim = 0;
    };
    return dest.end;
}

const Dest = struct { url: []const u8, end: usize };

/// `(destination "title")` at `text[j]`.
fn destination(text: []const u8, j: usize) ?Dest {
    if (j >= text.len or text[j] != '(') return null;
    var k = j + 1;
    while (k < text.len and isWs(text[k])) k += 1;
    var url: []const u8 = "";
    if (k < text.len and text[k] == '<') {
        const end = std.mem.indexOfAnyPos(u8, text, k + 1, ">\n") orelse return null;
        if (text[end] != '>') return null;
        url = text[k + 1 .. end];
        k = end + 1;
    } else {
        const from = k;
        var depth: usize = 0;
        while (k < text.len and !isWs(text[k]) and std.ascii.isPrint(text[k]) or (k < text.len and text[k] >= 0x80)) : (k += 1) {
            if (text[k] == '\\' and k + 1 < text.len) {
                k += 1;
            } else if (text[k] == '(') {
                depth += 1;
            } else if (text[k] == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
        }
        url = text[from..k];
    }
    while (k < text.len and isWs(text[k])) k += 1;
    if (k < text.len and (text[k] == '"' or text[k] == '\'' or text[k] == '(')) {
        const shut: u8 = if (text[k] == '(') ')' else text[k];
        const end = std.mem.indexOfScalarPos(u8, text, k + 1, shut) orelse return null;
        k = end + 1;
        while (k < text.len and isWs(text[k])) k += 1;
    }
    if (k >= text.len or text[k] != ')') return null;
    return .{ .url = url, .end = k + 1 };
}

/// The length of an autolink's body before its `>`: a URI (a scheme of
/// 2–32 letters, `:`, no spaces) or an email address.
fn autolink(rest: []const u8) ?usize {
    const end = std.mem.indexOfAny(u8, rest, "<> \t\n") orelse return null;
    if (rest[end] != '>' or end == 0) return null;
    const body = rest[0..end];
    if (std.mem.indexOfScalar(u8, body, ':')) |colon| {
        if (colon < 2 or colon > 32 or !std.ascii.isAlphabetic(body[0])) return null;
        for (body[0..colon]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '.' and c != '-') return null;
        return end;
    }
    const at = std.mem.indexOfScalar(u8, body, '@') orelse return null;
    if (at == 0 or at + 1 >= body.len or std.mem.indexOfScalar(u8, body[at + 1 ..], '.') == null) return null;
    return end;
}

const Entity = struct { text: []const u8, len: usize };

// ponytail: the common named entities and numeric ones; CommonMark knows all of HTML's.
fn entity(a: std.mem.Allocator, rest: []const u8) !?Entity {
    const semi = std.mem.indexOfScalar(u8, rest[0..@min(rest.len, 12)], ';') orelse return null;
    const name = rest[1..semi];
    const named = [_][2][]const u8{ .{ "amp", "&" }, .{ "lt", "<" }, .{ "gt", ">" }, .{ "quot", "\"" }, .{ "apos", "'" }, .{ "nbsp", "\u{a0}" } };
    for (named) |n| if (std.mem.eql(u8, name, n[0])) return .{ .text = n[1], .len = semi + 1 };
    if (name.len < 2 or name[0] != '#') return null;
    const hex = name[1] == 'x' or name[1] == 'X';
    const cp = std.fmt.parseInt(u21, name[if (hex) 2 else 1..], if (hex) 16 else 10) catch return null;
    const ok = if (cp == 0) 0xfffd else cp;
    const buf = try a.alloc(u8, 4);
    const len = std.unicode.utf8Encode(ok, buf) catch return null;
    return .{ .text = buf[0..len], .len = semi + 1 };
}

/// CommonMark's "process emphasis" over the delimiter runs from `bottom`:
/// each closer with the nearest opener of its kind; `~` runs of the same
/// length strike through.
fn emphasis(items: []Piece, bottom: usize) void {
    var ci = bottom;
    while (ci < items.len) {
        const cl = &items[ci];
        const kind = cl.delim;
        if (!((kind == '*' or kind == '_' or kind == '~') and cl.close and cl.active and cl.count > 0)) {
            ci += 1;
            continue;
        }
        var oi = ci;
        const found: ?usize = while (oi > bottom) {
            oi -= 1;
            const op = items[oi];
            if (op.delim != kind or !op.open or !op.active or op.count == 0) continue;
            if (kind == '~') {
                if (op.count != cl.count) continue;
            } else if ((op.close or cl.open) and (op.orig + cl.orig) % 3 == 0 and !(op.orig % 3 == 0 and cl.orig % 3 == 0)) continue;
            break oi;
        } else null;
        const o = found orelse {
            if (!cl.open) cl.active = false;
            ci += 1;
            continue;
        };
        const use: usize = if (kind == '~') cl.count else if (items[o].count >= 2 and cl.count >= 2) 2 else 1;
        const flag: Flags = if (kind == '~') .{ .strike = true } else if (use == 2) .{ .bold = true } else .{ .italic = true };
        for (items[o + 1 .. ci]) |*pc| {
            pc.flags = pc.flags.with(flag);
            if (pc.delim == '*' or pc.delim == '_' or pc.delim == '~') pc.active = false;
        }
        items[o].count -= use;
        cl.count -= use;
        if (cl.count == 0) ci += 1;
    }
}

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
