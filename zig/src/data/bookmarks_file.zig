//! A bookmarks file, as every browser exports one (BookmarksFile.swift):
//! the old Netscape format, an HTML page of nested lists, read loosely as
//! browsers write it loosely — tags in any case, paragraphs and closing tags
//! left out, attributes in any order. Only http and https addresses are
//! kept. Kea's own `bookmarks.json` tree is read too. Nothing is written:
//! Kea has no bookmarks export.
//!
//!     <DT><H3>Folder</H3>
//!     <DL><p>
//!         <DT><A HREF="https://example.com/">Example</A>
//!     </DL><p>
const std = @import("std");
const json = @import("json.zig");
const Parts = @import("url.zig").Parts;
const Bookmark = @import("bookmarks.zig").Bookmark;
const Uuid = json.Uuid;

/// The file's bookmarks, folders and all, on `a` (an arena); null for a
/// file that is neither a bookmarks page nor Kea's JSON list. Every node
/// gets a fresh id, as a page's do: a list exported from here and brought
/// back in must not put a second node under an id already kept.
pub fn read(a: std.mem.Allocator, bytes: []const u8) !?[]Bookmark {
    if (indexOfIgnoreCase(bytes, 0, "<DL") != null) return try parse(a, bytes);
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '[') return null;
    const parsed = json.decode([]Bookmark, a, trimmed) catch return null;
    renew(parsed.value);
    return parsed.value;
}

fn renew(nodes: []Bookmark) void {
    for (nodes) |*n| {
        n.id = Uuid.random();
        renew(n.kids());
    }
}

/// One pass over the tags that matter: a folder's heading is kept until its
/// list opens; a list that closes hands its pages to the folder holding it.
pub fn parse(a: std.mem.Allocator, text: []const u8) ![]Bookmark {
    const List = struct { title: ?[]const u8, nodes: std.ArrayList(Bookmark) = .empty };
    var stack: std.ArrayList(List) = .empty;
    var root: std.ArrayList(Bookmark) = .empty;
    var heading: ?[]const u8 = null;
    // The bookmarks bar, as Chrome and Firefox mark it: its pages go to
    // the top, as bringing Chrome's in directly puts them.
    var bar = false;

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '<')) |lt| {
        i = lt + 1;
        if (pairAt(text, lt)) |m| {
            i = m.end;
            const title = try clean(a, m.inner);
            if (m.heading) {
                heading = title;
                bar = if (try attribute(a, "PERSONAL_TOOLBAR_FOLDER", m.attributes)) |v| std.ascii.eqlIgnoreCase(v, "true") else false;
            } else if (try attribute(a, "HREF", m.attributes)) |href| {
                const parts = Parts.parse(href) orelse continue;
                const scheme = parts.scheme orelse continue;
                if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) continue;
                const name = if (title.len > 0) title else parts.hostName() orelse href;
                try append(a, &stack, &root, .{ .id = Uuid.random(), .title = name, .url = href });
            }
        } else if (listAt(text, lt)) |l| {
            i = l.end;
            if (!l.closing) {
                // The list of the folder just named — or, the first time, of
                // the file itself. Past a depth no one files at, a list's
                // pages join the folder holding it.
                const plain = stack.items.len >= 64 or (heading == null and stack.items.len == 0 and root.items.len == 0) or (bar and stack.items.len <= 1);
                try stack.append(a, .{ .title = if (plain) null else heading orelse "Folder" });
                heading = null;
                bar = false;
            } else if (stack.pop()) |open| try hand(a, &stack, &root, open.title, open.nodes.items);
        }
    }
    // A file cut short: what was open still counts.
    while (stack.pop()) |open| try hand(a, &stack, &root, open.title, open.nodes.items);
    return root.items;
}

fn append(a: std.mem.Allocator, stack: anytype, root: *std.ArrayList(Bookmark), node: Bookmark) !void {
    if (stack.items.len == 0) try root.append(a, node) else try stack.items[stack.items.len - 1].nodes.append(a, node);
}

/// A closed list: a folder of its own, or its pages to the one holding it.
fn hand(a: std.mem.Allocator, stack: anytype, root: *std.ArrayList(Bookmark), title: ?[]const u8, nodes: []Bookmark) !void {
    if (title) |t| return append(a, stack, root, Bookmark.folder(t, nodes));
    if (stack.items.len == 0) try root.appendSlice(a, nodes) else try stack.items[stack.items.len - 1].nodes.appendSlice(a, nodes);
}

/// `<(H3|A)\b([^>]*)>(.*?)</\1\s*>` at `lt`.
const Pair = struct { heading: bool, attributes: []const u8, inner: []const u8, end: usize };

fn pairAt(text: []const u8, lt: usize) ?Pair {
    const after = lt + 1;
    const heading = startsWithIgnoreCase(text[after..], "H3");
    const name_len: usize = if (heading) 2 else if (after < text.len and (text[after] | 0x20) == 'a') 1 else return null;
    const name_end = after + name_len;
    if (name_end < text.len and isWord(text[name_end])) return null;
    const gt = std.mem.indexOfScalarPos(u8, text, name_end, '>') orelse return null;
    var from = gt + 1;
    while (indexOfIgnoreCase(text, from, "</")) |close| {
        from = close + 2;
        if (!startsWithIgnoreCase(text[from..], text[after..name_end])) continue;
        var j = from + name_len;
        while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
        if (j < text.len and text[j] == '>') return .{ .heading = heading, .attributes = text[name_end..gt], .inner = text[gt + 1 .. close], .end = j + 1 };
    }
    return null;
}

/// `<(/?)DL\b[^>]*>` at `lt`.
fn listAt(text: []const u8, lt: usize) ?struct { closing: bool, end: usize } {
    var j = lt + 1;
    const closing = j < text.len and text[j] == '/';
    if (closing) j += 1;
    if (!startsWithIgnoreCase(text[j..], "DL")) return null;
    j += 2;
    if (j < text.len and isWord(text[j])) return null;
    const gt = std.mem.indexOfScalarPos(u8, text, j, '>') orelse return null;
    return .{ .closing = closing, .end = gt + 1 };
}

/// `NAME\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))`, the first anywhere, decoded.
fn attribute(a: std.mem.Allocator, name: []const u8, text: []const u8) !?[]const u8 {
    var from: usize = 0;
    while (indexOfIgnoreCase(text, from, name)) |at| {
        from = at + 1;
        var j = at + name.len;
        while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
        if (j >= text.len or text[j] != '=') continue;
        j += 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
        if (j >= text.len) continue;
        const q = text[j];
        if (q == '"' or q == '\'') {
            const end = std.mem.indexOfScalarPos(u8, text, j + 1, q) orelse continue;
            return try decode(a, text[j + 1 .. end]);
        }
        var end = j;
        while (end < text.len and !std.ascii.isWhitespace(text[end]) and text[end] != '>') end += 1;
        if (end > j) return try decode(a, text[j..end]);
    }
    return null;
}

/// A title without any markup left in it, its entities decoded.
fn clean(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var bare: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '<') if (std.mem.indexOfScalarPos(u8, text, i, '>')) |gt| {
            i = gt + 1;
            continue;
        };
        try bare.append(a, text[i]);
        i += 1;
    }
    return std.mem.trim(u8, try decode(a, bare.items), " \t\r\n");
}

fn decode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out = text;
    for ([_][2][]const u8{ .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" }, .{ "&apos;", "'" }, .{ "&nbsp;", " " } }) |e|
        out = try replaceIgnoreCase(a, out, e[0], e[1]);
    // Numbered ones, then the ampersand itself last, so "&amp;lt;" stays "&lt;".
    var num: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < out.len) {
        if (numbered(out[i..])) |n| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(n.code, &buf) catch 0;
            if (len > 0) {
                try num.appendSlice(a, buf[0..len]);
                i += n.len;
                continue;
            }
        }
        try num.append(a, out[i]);
        i += 1;
    }
    return replaceIgnoreCase(a, num.items, "&amp;", "&");
}

/// `&#(x?)([0-9a-fA-F]+);` at the start of `s`, as a code point.
fn numbered(s: []const u8) ?struct { code: u21, len: usize } {
    if (!std.mem.startsWith(u8, s, "&#")) return null;
    var j: usize = 2;
    const hex = j < s.len and s[j] == 'x';
    if (hex) j += 1;
    const start = j;
    while (j < s.len and std.ascii.isHex(s[j])) j += 1;
    if (j == start or j >= s.len or s[j] != ';') return null;
    const code = std.fmt.parseInt(u21, s[start..j], if (hex) 16 else 10) catch return null;
    return .{ .code = code, .len = j + 1 };
}

fn replaceIgnoreCase(a: std.mem.Allocator, text: []const u8, what: []const u8, with: []const u8) ![]const u8 {
    if (indexOfIgnoreCase(text, 0, what) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (indexOfIgnoreCase(text, i, what)) |at| {
        try out.appendSlice(a, text[i..at]);
        try out.appendSlice(a, with);
        i = at + what.len;
    }
    try out.appendSlice(a, text[i..]);
    return out.items;
}

fn indexOfIgnoreCase(text: []const u8, from: usize, what: []const u8) ?usize {
    if (from >= text.len) return null;
    return std.ascii.findIgnoreCasePos(text, from, what);
}

fn startsWithIgnoreCase(text: []const u8, what: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(text, what);
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "netscape html bookmarks parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const page =
        \\<!DOCTYPE NETSCAPE-Bookmark-file-1>
        \\<dl><p>
        \\  <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        \\  <DL><p>
        \\    <DT><a add_date=2 href='https://kea.app/'>Kea &amp; <b>friends</b></a>
        \\    <DT><H3>Work</H3>
        \\    <DL><p>
        \\      <DT><A HREF="http://example.com/a?b=1&amp;c=2">  </A>
        \\      <DT><A HREF="ftp://example.com/">Not kept</A>
        \\    </DL><p>
        \\  </DL><p>
        \\  <DT><A HREF="https://zig.dev/">Zig &#8212; &#x41;</A>
        \\  <DT><H3>Cut short</H3>
        \\  <DL>
        \\    <DT><A HREF=https://late.example/>Late</A>
    ;
    const roots = try parse(a, page);
    // The bar's pages at the top, its folder kept; the cut-short folder kept.
    try std.testing.expectEqual(@as(usize, 4), roots.len);
    try std.testing.expectEqualStrings("Kea & friends", roots[0].title);
    try std.testing.expectEqualStrings("https://kea.app/", roots[0].url.?);
    try std.testing.expectEqualStrings("Work", roots[1].title);
    const work = roots[1].children.?;
    try std.testing.expectEqual(@as(usize, 1), work.len);
    try std.testing.expectEqualStrings("example.com", work[0].title);
    try std.testing.expectEqualStrings("http://example.com/a?b=1&c=2", work[0].url.?);
    try std.testing.expectEqualStrings("Zig \u{2014} A", roots[2].title);
    try std.testing.expectEqualStrings("Cut short", roots[3].title);
    try std.testing.expectEqualStrings("https://late.example/", roots[3].children.?[0].url.?);
    try std.testing.expect(try read(a, "not bookmarks") == null);
}

test "kea's own json list reads under fresh ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var inner = [_]Bookmark{.{ .id = Uuid.random(), .title = "Quote \"<this>\" & that", .url = "https://a.example/?x=1&y=2" }};
    const tree = [_]Bookmark{
        .{ .id = Uuid.random(), .title = "Top", .url = "https://top.example/" },
        Bookmark.folder("Folder", &inner),
    };
    // The same tree, under ids none of which are already kept.
    const again = (try read(a, try json.encode(a, &tree))).?;
    try std.testing.expectEqualStrings("Top", again[0].title);
    try std.testing.expectEqualStrings(inner[0].url.?, again[1].children.?[0].url.?);
    try std.testing.expect(!again[1].id.eql(tree[1].id));
    try std.testing.expect(!again[1].children.?[0].id.eql(inner[0].id));
    try std.testing.expectEqualStrings(inner[0].title, again[1].children.?[0].title);
}
