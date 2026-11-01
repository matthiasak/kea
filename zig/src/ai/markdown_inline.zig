//! `Markdown.shown` (Markdown.swift:386-398): a line of an answer as
//! Foundation's `AttributedString(markdown:)` reads it with
//! `.inlineOnlyPreservingWhitespace` — CommonMark's inlines and GFM's
//! strikethrough over text kept as written (no blocks, whitespace kept):
//! strong and emphasis, code spans, links, autolinks, images (their alt
//! text), escapes and entities. What it gives is the text shown and its
//! styled runs; the view maps them to spans. Beside them: inline math
//! (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`, shown as written) and where every
//! shown byte came from, so a selection copies the Markdown (`ui.CopyMap`).
const std = @import("std");
const Wrap = @import("nanoui").ui.CopyMap.Wrap;

pub const Flags = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
    link: bool = false,
    math: bool = false,
    _: u2 = 0,

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
/// Inline math over bytes [start, end) of the shown text (its source as
/// written, `raw`); `tex` the LaTeX inside the delimiters.
pub const MathSpan = struct { start: u32, end: u32, tex: []const u8, raw: []const u8, display: bool = false };
pub const Shown = struct {
    text: []const u8,
    runs: []const Run,
    links: []const Link,
    maths: []const MathSpan = &.{},
    /// `ui.CopyMap.open` / `.close` / `.wraps` over the source.
    open_map: []const u32 = &.{},
    close_map: []const u32 = &.{},
    wraps: []const Wrap = &.{},
};

const Role = enum { none, opener, closer };

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
    /// Its source, bytes [so, sc); where its shown text starts there when
    /// `text` is not a slice of it; a run's syntax opening or closing one.
    so: u32 = 0,
    sc: u32 = 0,
    inner: ?u32 = null,
    role: Role = .none,
    tex: []const u8 = "",
};

/// An emphasis or link run between pieces `o` and `cl`, as written.
const Pair = struct { o: usize, cl: usize, open: []const u8, close: []const u8 };

fn isPunct(ch: u8) bool {
    return std.ascii.isPrint(ch) and !std.ascii.isAlphanumeric(ch) and ch != ' ';
}

fn isWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0b or ch == 0x0c;
}

/// `text` as shown, everything on `a` (an arena).
pub fn shown(a: std.mem.Allocator, text: []const u8) !Shown {
    return shownOpts(a, text, false);
}

/// `shown`; `streaming`: math still being written (`$$…`, `\(…`, or a `$`
/// followed by TeX) shows as math to the end.
pub fn shownOpts(a: std.mem.Allocator, text: []const u8, streaming: bool) !Shown {
    var pieces: std.ArrayList(Piece) = .empty;
    var urls: std.ArrayList([]const u8) = .empty;
    var pairs: std.ArrayList(Pair) = .empty;
    var i: usize = 0;
    var plain_from: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (std.mem.indexOfScalar(u8, "\\`*_~![]<&$", ch) == null) {
            i += 1;
            continue;
        }
        if (plain_from < i) try pieces.append(a, .{ .text = text[plain_from..i], .so = @intCast(plain_from), .sc = @intCast(i) });
        i = try special(a, text, i, &pieces, &urls, &pairs, streaming);
        plain_from = i;
    }
    if (plain_from < text.len) try pieces.append(a, .{ .text = text[plain_from..], .so = @intCast(plain_from), .sc = @intCast(text.len) });
    try emphasis(a, pieces.items, 0, &pairs);

    var out: std.ArrayList(u8) = .empty;
    var runs: std.ArrayList(Run) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var maths: std.ArrayList(MathSpan) = .empty;
    var open_map: std.ArrayList(u32) = .empty;
    var close_map: std.ArrayList(u32) = .empty;
    var wraps: std.ArrayList(Wrap) = .empty;
    const starts = try a.alloc(u32, pieces.items.len);
    // Syntax met since the last shown byte: closing (copied with what
    // went before) and opening (with what comes after).
    var pend_close: ?u32 = null;
    var pend_open: ?u32 = null;
    var prev_end: u32 = 0;
    for (pieces.items, 0..) |pc, pi| {
        const run = pc.delim == '*' or pc.delim == '_' or pc.delim == '~';
        const s: []const u8 = if (run) pc.text[0..pc.count] else pc.text;
        const used: u32 = if (run) @intCast(pc.orig - pc.count) else 0;
        starts[pi] = @intCast(out.items.len);
        if (pc.role == .closer) {
            pend_close = if (run) pc.so + used else pc.sc;
            pend_open = null;
        } else if (pc.role == .opener and s.len == 0 and pend_open == null) pend_open = pc.so;
        if (s.len == 0) continue;
        // A closer's leftover delimiters come after the syntax it used.
        const first: u32 = if (pc.role == .closer and run) pc.so + used else pc.so;
        const inner: ?u32 = if (pc.role == .closer and run) first else pc.inner orelse within(text, s);
        try close_map.append(a, pend_close orelse prev_end);
        try open_map.append(a, pend_open orelse first);
        for (1..s.len) |k| {
            const m = if (inner) |n| n + @as(u32, @intCast(k)) else first;
            try open_map.append(a, m);
            try close_map.append(a, m);
        }
        // An opener's leftover delimiters come before the syntax it used.
        const opens_after = pc.role == .opener and run;
        prev_end = if (opens_after) pc.so + @as(u32, @intCast(pc.count)) else pc.sc;
        pend_close = null;
        pend_open = if (opens_after) prev_end else null;

        const start: u32 = @intCast(out.items.len);
        try out.appendSlice(a, s);
        const end: u32 = @intCast(out.items.len);
        if (pc.flags.code and !run) if (inner) |n| {
            try wraps.append(a, .{ .start = start, .end = end, .open = text[pc.so..n], .close = text[n + s.len .. pc.sc] });
        };
        if (pc.flags.math) try maths.append(a, .{ .start = start, .end = end, .tex = pc.tex, .raw = s, .display = std.mem.startsWith(u8, s, "$$") or std.mem.startsWith(u8, s, "\\[") });
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
    try close_map.append(a, pend_close orelse prev_end);
    try open_map.append(a, pend_open orelse @intCast(text.len));
    for (pairs.items) |pr| {
        const o = pieces.items[pr.o];
        const shown_o: u32 = @intCast(if (o.delim == '*' or o.delim == '_' or o.delim == '~') o.count else o.text.len);
        try wraps.append(a, .{ .start = starts[pr.o] + shown_o, .end = starts[pr.cl], .open = pr.open, .close = pr.close });
    }
    // Outer runs first, so a cut selection opens them in order.
    std.mem.sort(Wrap, wraps.items, {}, struct {
        fn lt(_: void, l: Wrap, r: Wrap) bool {
            return l.start < r.start or (l.start == r.start and l.end > r.end);
        }
    }.lt);
    return .{ .text = out.items, .runs = runs.items, .links = links.items, .maths = maths.items, .open_map = open_map.items, .close_map = close_map.items, .wraps = wraps.items };
}

/// Where `s` starts in `text`, if it is a slice of it.
fn within(text: []const u8, s: []const u8) ?u32 {
    const p = @intFromPtr(s.ptr);
    const b = @intFromPtr(text.ptr);
    return if (p >= b and p + s.len <= b + text.len) @intCast(p - b) else null;
}

/// Where math opened at `text[from]` ends: before `shut`, or (still
/// streaming, within 240 bytes) at the end.
fn mathTo(text: []const u8, from: usize, shut: []const u8, streaming: bool) ?usize {
    if (std.mem.indexOfPos(u8, text, from, shut)) |k| return k;
    return if (streaming and text.len - from <= 240) text.len else null;
}

const Dollar = struct { open: usize, end: usize, shut: []const u8 };

/// Math opened by the `$` at `text[i]`: `$$…$$`, or `$…$` hugging its
/// TeX (no space inside either `$`, none after a letter or before a
/// digit), so `$5 and $10` stays prose.
fn dollar(text: []const u8, i: usize, streaming: bool) ?Dollar {
    if (i + 1 < text.len and text[i + 1] == '$') {
        return .{ .open = 2, .end = mathTo(text, i + 2, "$$", streaming) orelse return null, .shut = "$$" };
    }
    if (i + 1 >= text.len or isWs(text[i + 1]) or (i > 0 and std.ascii.isAlphanumeric(text[i - 1]))) return null;
    var j = i + 1;
    var depth: usize = 0;
    while (j < text.len) : (j += 1) switch (text[j]) {
        '\\' => j += 1,
        '{' => depth += 1,
        '}' => depth -|= 1,
        '$' => if (depth == 0) {
            if (!isWs(text[j - 1]) and (j + 1 == text.len or !std.ascii.isDigit(text[j + 1]))) return .{ .open = 1, .end = j, .shut = "$" };
            return null;
        },
        else => {},
    };
    // Unclosed: math only while it streams in, and only if it reads as TeX.
    const rest = text[i + 1 ..];
    if (!streaming or rest.len > 240 or std.ascii.isDigit(rest[0]) or std.mem.indexOfAny(u8, rest, "\\_^{") == null) return null;
    return .{ .open = 1, .end = text.len, .shut = "$" };
}

/// A math piece from `text[i]`, its TeX `text[i + open .. end]`, closed by `shut` if there.
fn math(a: std.mem.Allocator, text: []const u8, i: usize, open: usize, end: usize, shut: []const u8, pieces: *std.ArrayList(Piece)) !usize {
    const stop = if (std.mem.startsWith(u8, text[end..], shut)) end + shut.len else end;
    try pieces.append(a, .{ .text = text[i..stop], .flags = .{ .math = true }, .so = @intCast(i), .sc = @intCast(stop), .tex = text[i + open .. end] });
    return stop;
}

/// Reads the inline at `text[i]` (one of the special characters) into
/// `pieces`; returns where reading goes on.
fn special(a: std.mem.Allocator, text: []const u8, i: usize, pieces: *std.ArrayList(Piece), urls: *std.ArrayList([]const u8), pairs: *std.ArrayList(Pair), streaming: bool) !usize {
    const ch = text[i];
    const at: u32 = @intCast(i);
    switch (ch) {
        '\\' => {
            if (i + 1 < text.len and (text[i + 1] == '(' or text[i + 1] == '[')) {
                const shut = if (text[i + 1] == '(') "\\)" else "\\]";
                if (mathTo(text, i + 2, shut, streaming)) |end| return math(a, text, i, 2, end, shut, pieces);
            }
            // `\$` among them: a dollar, never math.
            if (i + 1 < text.len and (isPunct(text[i + 1]) or text[i + 1] == '\n')) {
                try pieces.append(a, .{ .text = text[i + 1 .. i + 2], .so = at, .sc = at + 2 });
                return i + 2;
            }
        },
        '$' => if (dollar(text, i, streaming)) |d| return math(a, text, i, d.open, d.end, d.shut, pieces),
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
                    const body = try codeText(a, text[i + n .. j]);
                    const pad = (j - i - n - body.len) / 2;
                    try pieces.append(a, .{ .text = body, .flags = .{ .code = true }, .so = at, .sc = @intCast(j + m), .inner = @intCast(i + n + pad) });
                    return j + m;
                }
                j += m;
            }
            try pieces.append(a, .{ .text = text[i .. i + n], .so = at, .sc = @intCast(i + n) });
            return i + n;
        },
        '*', '_', '~' => {
            var n: usize = 0;
            while (i + n < text.len and text[i + n] == ch) n += 1;
            if (ch == '~' and n > 2) {
                try pieces.append(a, .{ .text = text[i .. i + n], .so = at, .sc = @intCast(i + n) });
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
            try pieces.append(a, .{ .text = text[i .. i + n], .delim = ch, .count = n, .orig = n, .open = open, .close = close, .so = at, .sc = @intCast(i + n) });
            return i + n;
        },
        '!' => if (i + 1 < text.len and text[i + 1] == '[') {
            try pieces.append(a, .{ .text = text[i .. i + 2], .delim = '!', .so = at, .sc = at + 2 });
            return i + 2;
        },
        '[' => {
            try pieces.append(a, .{ .text = text[i .. i + 1], .delim = '[', .so = at, .sc = at + 1 });
            return i + 1;
        },
        ']' => return closeBracket(a, text, i, pieces, urls, pairs),
        '<' => if (autolink(text[i + 1 ..])) |end| {
            const body = text[i + 1 .. i + 1 + end];
            const url = if (std.mem.indexOfScalar(u8, body, ':') == null) try std.mem.concat(a, u8, &.{ "mailto:", body }) else body;
            try urls.append(a, url);
            try pieces.append(a, .{ .text = body, .flags = .{ .link = true }, .link = @intCast(urls.items.len - 1), .so = at, .sc = @intCast(i + end + 2) });
            return i + end + 2;
        },
        '&' => if (try entity(a, text[i..])) |e| {
            try pieces.append(a, .{ .text = e.text, .so = at, .sc = @intCast(i + e.len) });
            return i + e.len;
        },
        else => {},
    }
    try pieces.append(a, .{ .text = text[i .. i + 1], .so = at, .sc = at + 1 });
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
fn closeBracket(a: std.mem.Allocator, text: []const u8, i: usize, pieces: *std.ArrayList(Piece), urls: *std.ArrayList([]const u8), pairs: *std.ArrayList(Pair)) !usize {
    const at32: u32 = @intCast(i);
    const items = pieces.items;
    var o = items.len;
    const opener: ?usize = while (o > 0) {
        o -= 1;
        if ((items[o].delim == '[' or items[o].delim == '!') and items[o].active) break o;
    } else null;
    const at = opener orelse {
        try pieces.append(a, .{ .text = "]", .so = at32, .sc = at32 + 1 });
        return i + 1;
    };
    const dest = destination(text, i + 1) orelse {
        items[at].active = false;
        items[at].delim = 0;
        try pieces.append(a, .{ .text = "]", .so = at32, .sc = at32 + 1 });
        return i + 1;
    };
    try emphasis(a, items, at + 1, pairs);
    const image = items[at].delim == '!';
    items[at] = .{ .text = "", .so = items[at].so, .sc = items[at].sc, .role = .opener };
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
    try pairs.append(a, .{ .o = at, .cl = pieces.items.len, .open = text[items[at].so..items[at].sc], .close = text[i..dest.end] });
    try pieces.append(a, .{ .text = "", .so = at32, .sc = @intCast(dest.end), .role = .closer });
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
fn emphasis(a: std.mem.Allocator, items: []Piece, bottom: usize, pairs: *std.ArrayList(Pair)) !void {
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
        try pairs.append(a, .{ .o = o, .cl = ci, .open = cl.text[0..use], .close = cl.text[0..use] });
        if (items[o].role == .none) items[o].role = .opener;
        cl.role = .closer;
        items[o].count -= use;
        cl.count -= use;
        if (cl.count == 0) ci += 1;
    }
}

test {
    _ = @import("markdown_inline_test.zig");
}
