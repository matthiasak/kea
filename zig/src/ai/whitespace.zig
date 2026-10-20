//! Foundation's `CharacterSet.whitespaces` and `.newlines` on UTF-8: what
//! Swift's `trimmingCharacters(in: .whitespaces)`,
//! `components(separatedBy: .newlines)` and `Character.isWhitespace` take,
//! beyond ASCII. A byte that isn't UTF-8 is never a space.
const std = @import("std");

/// `.whitespaces`: tab and Unicode's space separators (Zs).
pub fn isSpace(cp: u21) bool {
    return switch (cp) {
        '\t', ' ', 0xA0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `.newlines`.
pub fn isNewline(cp: u21) bool {
    return switch (cp) {
        0x0A...0x0D, 0x85, 0x2028, 0x2029 => true,
        else => false,
    };
}

/// `Character.isWhitespace`: either.
pub fn isWhite(cp: u21) bool {
    return isSpace(cp) or isNewline(cp);
}

/// The code point starting at `s[i]` and its length; a stray byte is
/// U+FFFD, one long.
pub fn at(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + n > s.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// The start of the code point ending at `s[end - 1]`.
pub fn before(s: []const u8, end: usize) usize {
    var b = end - 1;
    while (b > 0 and end - b < 4 and s[b] & 0xC0 == 0x80) b -= 1;
    return if (at(s, b).len == end - b) b else end - 1;
}

/// `s` less the code points `drop` takes at either end.
pub fn trimWhere(s: []const u8, comptime drop: fn (u21) bool) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const c = at(s, start);
        if (!drop(c.cp)) break;
        start += c.len;
    }
    var end = s.len;
    while (end > start) {
        const b = before(s, end);
        if (!drop(at(s, b).cp)) break;
        end = b;
    }
    return s[start..end];
}

/// `trimmingCharacters(in: .whitespaces)`.
pub fn trim(s: []const u8) []const u8 {
    return trimWhere(s, isSpace);
}

/// Pieces of `s` between code points `cut` takes (`components(separatedBy:)`
/// with a set, or `split(whereSeparator:)` keeping empties).
pub fn Pieces(comptime cut: fn (u21) bool) type {
    return struct {
        s: []const u8,
        pos: ?usize = 0,

        pub fn next(it: *@This()) ?[]const u8 {
            const from = it.pos orelse return null;
            var i = from;
            while (i < it.s.len) {
                const c = at(it.s, i);
                if (cut(c.cp)) {
                    it.pos = i + c.len;
                    return it.s[from..i];
                }
                i += c.len;
            }
            it.pos = null;
            return it.s[from..];
        }
    };
}

test "unicode spaces and newlines trim and cut as Foundation's do" {
    const t = std.testing;
    try t.expectEqualStrings("a b", trim("\u{3000}\t a b\u{00A0}\u{2009}"));
    try t.expectEqualStrings("x\n", trim(" x\n"));
    var lines: Pieces(isNewline) = .{ .s = "one\u{2028}two\u{85}three\r\nfour" };
    for ([_][]const u8{ "one", "two", "three", "", "four" }) |want| try t.expectEqualStrings(want, lines.next().?);
    try t.expect(lines.next() == null);
    // A stray byte is kept, not a space.
    try t.expectEqualStrings("\xff", trim(" \xff "));
}
