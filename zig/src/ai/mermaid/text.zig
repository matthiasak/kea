//! String helpers shared by the Mermaid parsers: Swift's `.whitespaces`
//! trimming, `isWhitespace` splitting, statement splitting, label cleanup
//! and AppKit text measurement.
//!
//! ponytail: Swift lowercases with full Unicode case mapping; keyword checks
//! here are ASCII case-insensitive (the keywords are ASCII; only exotic
//! case mappings like the Kelvin sign differ).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

pub const Lines = []const []const u8;

const Cp = struct { cp: u21, len: usize };

/// The code point at `i` (an invalid byte reads as itself, one byte long).
pub fn cpAt(s: []const u8, i: usize) Cp {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// `CharacterSet.whitespaces`: tab and the space separators (Zs).
fn isBlank(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `Character.isWhitespace`: the Unicode White_Space property.
pub fn isWhitespace(cp: u21) bool {
    return isBlank(cp) or switch (cp) {
        0x0A...0x0D, 0x85, 0x2028, 0x2029 => true,
        else => false,
    };
}

/// Byte length of the `Character.isWhitespace` code point at `i`, 0 if none.
pub fn wsLen(s: []const u8, i: usize) usize {
    const c = cpAt(s, i);
    return if (isWhitespace(c.cp)) c.len else 0;
}

/// `Character.isLetter || Character.isNumber`.
/// ponytail: non-ASCII goes through `NSCharacterSet.alphanumericCharacterSet`
/// (letters, marks, numbers), close to but not exactly Swift's properties.
pub fn isAlnum(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp));
    const pool = objc.Pool.push();
    defer pool.pop();
    const set = objc.msg(objc.Object, objc.class("NSCharacterSet"), "alphanumericCharacterSet", .{});
    return objc.msg(bool, set, "longCharacterIsMember:", .{@as(u32, cp)});
}

/// `trimmingCharacters(in: .whitespaces)`.
pub fn trim(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const c = cpAt(s, start);
        if (!isBlank(c.cp)) break;
        start += c.len;
    }
    var end = s.len;
    while (end > start) {
        var b = end - 1;
        while (b > start and s[b] & 0xC0 == 0x80) b -= 1;
        if (!isBlank(cpAt(s, b).cp)) break;
        end = b;
    }
    return s[start..end];
}

/// `split(whereSeparator: { $0.isWhitespace })`: non-empty words.
pub fn words(a: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var start: ?usize = null;
    while (i < s.len) {
        const n = wsLen(s, i);
        if (n > 0) {
            if (start) |st| try out.append(a, s[st..i]);
            start = null;
            i += n;
        } else {
            if (start == null) start = i;
            i += cpAt(s, i).len;
        }
    }
    if (start) |st| try out.append(a, s[st..]);
    return out.items;
}

/// The first `isWhitespace`-separated word, or null.
pub fn firstWord(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const n = wsLen(s, i);
        if (n == 0) break;
        i += n;
    }
    if (i == s.len) return null;
    const start = i;
    while (i < s.len and wsLen(s, i) == 0) i += cpAt(s, i).len;
    return s[start..i];
}

/// `s.drop(while: { !$0.isWhitespace })`.
pub fn dropWord(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and wsLen(s, i) == 0) i += cpAt(s, i).len;
    return s[i..];
}

pub fn normalizeDir(raw: []const u8) []const u8 {
    for ([_][]const u8{ "BT", "LR", "RL" }) |d| if (std.ascii.eqlIgnoreCase(raw, d)) return d;
    return "TD";
}

/// Trimmed, comment-free statements, split at top-level `;`.
pub fn statements(a: std.mem.Allocator, lines: []const []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lines) |raw| {
        const t = trim(raw);
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) continue;
        var start: usize = 0;
        var depth: usize = 0;
        var in_quotes = false;
        for (t, 0..) |ch, i| {
            if (ch == '"') {
                in_quotes = !in_quotes;
            } else if (!in_quotes) {
                switch (ch) {
                    '[', '(', '{' => depth += 1,
                    ']', ')', '}' => depth -|= 1,
                    ';' => if (depth == 0) {
                        try keep(a, &out, t[start..i]);
                        start = i + 1;
                    },
                    else => {},
                }
            }
        }
        try keep(a, &out, t[start..]);
    }
    return out.items;
}

fn keep(a: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8) !void {
    const s = trim(raw);
    if (s.len > 0 and !std.mem.startsWith(u8, s, "%%")) try out.append(a, s);
}

pub fn replaceIfPresent(a: std.mem.Allocator, s: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, needle) == null) return s;
    return std.mem.replaceOwned(u8, a, s, needle, replacement);
}

/// Unquoted, entity-decoded label lines, wrapped at 180 points.
pub fn cleanLabel(a: std.mem.Allocator, raw: []const u8) !Lines {
    var s = trim(raw);
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    for ([_][]const u8{ "<br/>", "<br />", "<br>", "<BR/>", "<BR />", "<BR>" }) |br| {
        s = try replaceIfPresent(a, s, br, "\n");
    }
    const entities = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "#quot;", "\"" } };
    for (entities) |e| s = try replaceIfPresent(a, s, e[0], e[1]);
    var wrapped: std.ArrayList([]const u8) = .empty;
    var paragraphs = std.mem.splitScalar(u8, s, '\n');
    while (paragraphs.next()) |paragraph| {
        const ws = try words(a, paragraph);
        if (ws.len == 0) {
            try wrapped.append(a, "");
            continue;
        }
        var line = ws[0];
        for (ws[1..]) |word| {
            const candidate = try std.mem.concat(a, u8, &.{ line, " ", word });
            if (textWidth(candidate, false, 12) <= 180) {
                line = candidate;
            } else {
                try wrapped.append(a, line);
                line = word;
            }
        }
        try wrapped.append(a, line);
    }
    return wrapped.items;
}

/// `cleanLabel(raw).joined(separator: " ")`.
pub fn cleanJoined(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return std.mem.join(a, " ", try cleanLabel(a, raw));
}

var app_ready = false;

/// Width of `text` in the system font, rounded up, as AppKit measures it.
pub fn textWidth(text: []const u8, bold: bool, size: f64) f64 {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (!app_ready) {
        _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        app_ready = true;
    }
    const font = objc.msg(objc.Object, objc.class("NSFont"), if (bold) "boldSystemFontOfSize:" else "systemFontOfSize:", .{size});
    // NSFontAttributeName is @"NSFont".
    const attrs = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ font, objc.nsString("NSFont") });
    const str = objc.msg(objc.Object, objc.alloc("NSAttributedString"), "initWithString:attributes:", .{ objc.nsString(text), attrs });
    defer objc.release(str);
    // Measured as a view's body measures it: with no drawing context current
    // (a leftover one, e.g. from an image drawn, would switch AppKit to its
    // screen-font advancements and change the widths).
    const gc = objc.class("NSGraphicsContext");
    objc.msg(void, gc, "saveGraphicsState", .{});
    defer objc.msg(void, gc, "restoreGraphicsState", .{});
    objc.msg(void, gc, "setCurrentContext:", .{@as(?objc.Object, null)});
    return @ceil(objc.msg(objc.CGSize, str, "size", .{}).width);
}

/// The widest of `lines` (0 for none).
pub fn maxWidth(lines: []const []const u8, bold: bool, size: f64) f64 {
    var w: f64 = 0;
    for (lines) |l| w = @max(w, textWidth(l, bold, size));
    return w;
}

test "trim, words and statements follow Swift" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a b", trim("\u{3000} a b\t\u{A0}"));
    try std.testing.expectEqual(@as(usize, 2), (try words(a, " x\u{2003}y ")).len);
    const st = try statements(a, &.{ "A[x;y] --> B; C", "%% no", "  ;D;" });
    try std.testing.expectEqual(@as(usize, 3), st.len);
    try std.testing.expectEqualStrings("A[x;y] --> B", st[0]);
    try std.testing.expectEqualStrings("D", st[2]);
}
