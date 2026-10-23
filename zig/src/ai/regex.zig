//! ICU regular expressions through `NSRegularExpression`, as the Swift code
//! uses them (`range(of:options: .regularExpression)`, `NSRegularExpression`):
//! the same engine, so the same patterns match the same text.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const NSRange = extern struct { location: objc.NSUInteger, length: objc.NSUInteger };
const not_found: objc.NSUInteger = @bitCast(@as(objc.NSInteger, std.math.maxInt(objc.NSInteger)));

fn compile(pattern: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, objc.class("NSRegularExpression"), "regularExpressionWithPattern:options:error:", .{
        objc.nsString(pattern), @as(objc.NSUInteger, 0), @as(?*anyopaque, null),
    });
}

/// An autoreleased NSString of `text`, or null when it isn't UTF-8 (Swift's
/// `String` always is); call inside a pool.
fn str(text: []const u8) ?objc.Object {
    const s = objc.msg(?objc.Object, objc.alloc("NSString"), "initWithBytes:length:encoding:", .{ text.ptr, text.len, @as(objc.NSUInteger, 4) }) orelse return null;
    objc.autorelease(s);
    return s;
}

fn whole(s: objc.Object) NSRange {
    return .{ .location = 0, .length = objc.msg(objc.NSUInteger, s, "length", .{}) };
}

/// Whether `pattern` matches anywhere in `text`.
pub fn contains(pattern: []const u8, text: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const re = compile(pattern) orelse return false;
    const s = str(text) orelse return false;
    const r = objc.msg(NSRange, re, "rangeOfFirstMatchInString:options:range:", .{ s, @as(objc.NSUInteger, 0), whole(s) });
    return r.location != not_found;
}

/// Every match, whole, in order; on `a`.
pub fn matches(a: std.mem.Allocator, pattern: []const u8, text: []const u8) ![][]const u8 {
    const r = Regex.init(pattern) orelse return &.{};
    defer r.deinit();
    return r.matches(a, text);
}

/// A pattern compiled once, for many texts; safe on any thread.
pub const Regex = struct {
    re: objc.Object,

    pub fn init(pattern: []const u8) ?Regex {
        const pool = objc.Pool.push();
        defer pool.pop();
        return .{ .re = objc.retain(compile(pattern) orelse return null) };
    }

    pub fn deinit(r: Regex) void {
        objc.release(r.re);
    }

    pub fn contains(r: Regex, text: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = str(text) orelse return false;
        const m = objc.msg(NSRange, r.re, "rangeOfFirstMatchInString:options:range:", .{ s, @as(objc.NSUInteger, 0), whole(s) });
        return m.location != not_found;
    }

    /// Every match, whole, in order; on `a`.
    pub fn matches(r: Regex, a: std.mem.Allocator, text: []const u8) ![][]const u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = str(text) orelse return &.{};
        const found = objc.msg(objc.Object, r.re, "matchesInString:options:range:", .{ s, @as(objc.NSUInteger, 0), whole(s) });
        const n = objc.msg(objc.NSUInteger, found, "count", .{});
        const out = try a.alloc([]const u8, n);
        for (out, 0..) |*o, i| {
            const m = objc.msg(objc.Object, found, "objectAtIndex:", .{i});
            o.* = try a.dupe(u8, part(s, objc.msg(NSRange, m, "range", .{})));
        }
        return out;
    }
};

/// The first match and its groups (0 the whole), "" for a group that took no
/// part; null without a match. On `a`.
pub fn groups(a: std.mem.Allocator, pattern: []const u8, text: []const u8) !?[][]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const re = compile(pattern) orelse return null;
    const s = str(text) orelse return null;
    const m = objc.msg(?objc.Object, re, "firstMatchInString:options:range:", .{ s, @as(objc.NSUInteger, 0), whole(s) }) orelse return null;
    const n = objc.msg(objc.NSUInteger, m, "numberOfRanges", .{});
    const out = try a.alloc([]const u8, n);
    for (out, 0..) |*o, i| {
        const r = objc.msg(NSRange, m, "rangeAtIndex:", .{i});
        o.* = if (r.location == not_found) "" else try a.dupe(u8, part(s, r));
    }
    return out;
}

/// `text` with every match replaced by `template` (`$1` for a group); on `a`.
pub fn replace(a: std.mem.Allocator, text: []const u8, pattern: []const u8, template: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const re = compile(pattern) orelse return a.dupe(u8, text);
    const s = str(text) orelse return a.dupe(u8, text);
    const out = objc.msg(objc.Object, re, "stringByReplacingMatchesInString:options:range:withTemplate:", .{
        s, @as(objc.NSUInteger, 0), whole(s), objc.nsString(template),
    });
    return a.dupe(u8, objc.fromNSString(out));
}

/// Unicode compatibility mapping, composed (`precomposedStringWithCompatibilityMapping`, NFKC); on `a`.
pub fn nfkc(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = str(text) orelse return a.dupe(u8, text);
    return a.dupe(u8, objc.fromNSString(objc.msg(objc.Object, s, "precomposedStringWithCompatibilityMapping", .{})));
}

fn part(s: objc.Object, r: NSRange) []const u8 {
    return objc.fromNSString(objc.msg(objc.Object, s, "substringWithRange:", .{r}));
}

test "regex matches, groups and replaces as ICU does" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(contains("(?i)\\bignore\\b", "Please IGNORE this"));
    try std.testing.expect(!contains("^x$", "xy"));
    const m = try matches(a, "[a-z]+@[a-z]+\\.com", "write a@b.com or c@d.com");
    try std.testing.expectEqual(@as(usize, 2), m.len);
    try std.testing.expectEqualStrings("c@d.com", m[1]);
    const g = (try groups(a, "^(#{1,6})\\s+(.+)$", "## Title")).?;
    try std.testing.expectEqualStrings("##", g[1]);
    try std.testing.expectEqualStrings("Title", g[2]);
    try std.testing.expectEqualStrings("<b>x</b> é", try replace(a, "**x** é", "\\*\\*([^*]+)\\*\\*", "<b>$1</b>"));
    try std.testing.expectEqualStrings("A1", try nfkc(a, "Ａ１"));
    // Not UTF-8: no match and no exception.
    try std.testing.expect(!contains("x", "\xff x"));
    try std.testing.expectEqual(@as(usize, 0), (try matches(a, "x", "\xff x")).len);
}
