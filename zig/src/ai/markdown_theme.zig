//! An answer's editorial look (after `tern`): soft body ink under crisp
//! strong ink, lavender inline-code pills, flush tables, recessed code
//! cards, and `highlightCode`'s syntax and diff colours for fenced code.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Palette = @import("../design/palette.zig").Palette;

pub const MdTheme = struct {
    body: ui.Color,
    strong: ui.Color,
    code_ink: ui.Color,
    code_bg: ui.Color,
    code_border: ui.Color,
    /// Room either side of an inline code pill, before zoom.
    pad_x: f32 = 3.5,
    mono_scale: f32 = 0.88,
    link: ui.Color,
    math_ink: ui.Color,
    math_block_bg: ui.Color,
    quote_bar: ui.Color,
    quote_bg: ui.Color,
    table_head: ui.Color,
    table_head_rule: ui.Color,
    table_row_rule: ui.Color,
    code_block_bg: ui.Color,
    code_block_border: ui.Color,
    /// Syntax: comments (italic), strings, numbers, keywords, types, calls.
    comment: ui.Color,
    string: ui.Color,
    number: ui.Color,
    keyword: ui.Color,
    type_: ui.Color,
    call: ui.Color,
    /// Diffs: added, removed, hunk header lines.
    added: ui.Color,
    removed: ui.Color,
    hunk: ui.Color,

    pub fn of(dark: bool, p: *const Palette) MdTheme {
        const d = dark;
        const quote_bar = if (d) rgb(0.42, 0.48, 0.68) else rgb(0.45, 0.50, 0.66);
        const edge: ui.Color = if (d) .white else .black;
        return .{
            .body = if (d) rgb(0.816, 0.843, 0.882) else rgb(0.141, 0.161, 0.184),
            .strong = if (d) rgb(0.955, 0.968, 0.988) else rgb(0.043, 0.059, 0.082),
            .code_ink = if (d) rgb(0.745, 0.678, 0.965) else rgb(0.310, 0.239, 0.600),
            .code_bg = if (d) rgb(0.42, 0.40, 0.64).alpha(0.20) else rgb(0.35, 0.30, 0.58).alpha(0.09),
            .code_border = if (d) rgb(0.56, 0.52, 0.80).alpha(0.26) else rgb(0.35, 0.30, 0.58).alpha(0.18),
            .link = if (d) rgb(0.478, 0.635, 0.969) else p.blue,
            .math_ink = if (d) rgb(0.875, 0.902, 0.945) else rgb(0.082, 0.106, 0.141),
            .math_block_bg = if (d) rgb(0.125, 0.141, 0.176).alpha(0.65) else rgb(0.953, 0.961, 0.976),
            .quote_bar = quote_bar,
            .quote_bg = quote_bar.alpha(0.08),
            .table_head = if (d) rgb(0.565, 0.612, 0.686) else rgb(0.341, 0.376, 0.416),
            .table_head_rule = edge.alpha(0.16),
            .table_row_rule = edge.alpha(0.075),
            .code_block_bg = if (d) rgb(0.075, 0.086, 0.114) else rgb(0.965, 0.973, 0.980),
            .code_block_border = edge.alpha(if (d) 0.08 else 0.09),
            .comment = if (d) rgb(0.420, 0.471, 0.561) else rgb(0.416, 0.451, 0.490),
            .string = if (d) rgb(0.620, 0.808, 0.549) else rgb(0.153, 0.459, 0.204),
            .number = if (d) rgb(1.0, 0.620, 0.392) else rgb(0.710, 0.329, 0.039),
            .keyword = if (d) rgb(0.733, 0.604, 0.969) else rgb(0.510, 0.239, 0.729),
            .type_ = if (d) rgb(0.490, 0.812, 1.0) else rgb(0.0, 0.420, 0.620),
            .call = if (d) rgb(0.451, 0.855, 0.792) else rgb(0.0, 0.502, 0.471),
            .added = if (d) rgb(0.580, 0.851, 0.502) else rgb(0.102, 0.498, 0.200),
            .removed = if (d) rgb(0.969, 0.463, 0.478) else rgb(0.800, 0.200, 0.220),
            .hunk = if (d) rgb(0.490, 0.729, 0.800) else rgb(0.153, 0.451, 0.549),
        };
    }
};

fn rgb(r: f32, g: f32, b: f32) ui.Color {
    return .{ .r = r, .g = g, .b = b };
}

const Words = std.StaticStringMap(void);

const Lang = struct {
    /// Line comment openers ("" none).
    line: []const u8 = "//",
    line2: []const u8 = "",
    /// `/* … */` comments.
    block: bool = true,
    quotes: []const u8 = "\"'",
    /// Python's `"""…"""` strings.
    triple: bool = false,
    /// Zig's `\\` line strings.
    line_string: bool = false,
    keywords: Words,
    types: Words = Words.initComptime(.{}),
    /// Names that start upper case are types.
    caps_types: bool = true,
    /// Keywords in any case (SQL).
    nocase: bool = false,
};

const zig_lang: Lang = .{ .line_string = true, .keywords = .initComptime(.{
    .{"const"},  .{"var"},    .{"fn"},          .{"pub"},      .{"return"},    .{"if"},          .{"else"},     .{"while"},
    .{"for"},    .{"switch"}, .{"break"},       .{"continue"}, .{"defer"},     .{"errdefer"},    .{"try"},      .{"catch"},
    .{"orelse"}, .{"and"},    .{"or"},          .{"struct"},   .{"enum"},      .{"union"},       .{"error"},    .{"comptime"},
    .{"inline"}, .{"test"},   .{"unreachable"}, .{"null"},     .{"undefined"}, .{"true"},        .{"false"},    .{"export"},
    .{"extern"}, .{"packed"}, .{"opaque"},      .{"anytype"},  .{"noinline"},  .{"threadlocal"}, .{"callconv"}, .{"align"},
}), .types = .initComptime(.{
    .{"u8"},       .{"u16"},   .{"u32"},          .{"u64"},            .{"usize"}, .{"i8"},   .{"i16"},  .{"i32"},      .{"i64"},
    .{"isize"},    .{"f16"},   .{"f32"},          .{"f64"},            .{"bool"},  .{"void"}, .{"type"}, .{"anyerror"}, .{"anyopaque"},
    .{"noreturn"}, .{"c_int"}, .{"comptime_int"}, .{"comptime_float"},
}) };

const py_lang: Lang = .{ .line = "#", .block = false, .triple = true, .keywords = .initComptime(.{
    .{"def"},      .{"class"},   .{"return"}, .{"if"},   .{"elif"},   .{"else"},     .{"for"},    .{"while"}, .{"in"},
    .{"not"},      .{"and"},     .{"or"},     .{"is"},   .{"import"}, .{"from"},     .{"as"},     .{"with"},  .{"try"},
    .{"except"},   .{"finally"}, .{"raise"},  .{"pass"}, .{"break"},  .{"continue"}, .{"lambda"}, .{"yield"}, .{"global"},
    .{"nonlocal"}, .{"assert"},  .{"del"},    .{"None"}, .{"True"},   .{"False"},    .{"async"},  .{"await"}, .{"match"},
    .{"case"},
}), .types = .initComptime(.{
    .{"int"}, .{"str"}, .{"float"}, .{"bool"}, .{"list"}, .{"dict"}, .{"set"}, .{"tuple"}, .{"bytes"}, .{"object"},
}) };

const js_lang: Lang = .{ .quotes = "\"'`", .keywords = .initComptime(.{
    .{"const"},     .{"let"},     .{"var"},        .{"function"},   .{"return"}, .{"if"},       .{"else"},   .{"for"},
    .{"while"},     .{"do"},      .{"switch"},     .{"case"},       .{"break"},  .{"continue"}, .{"new"},    .{"this"},
    .{"class"},     .{"extends"}, .{"import"},     .{"export"},     .{"from"},   .{"default"},  .{"try"},    .{"catch"},
    .{"finally"},   .{"throw"},   .{"typeof"},     .{"instanceof"}, .{"in"},     .{"of"},       .{"async"},  .{"await"},
    .{"yield"},     .{"null"},    .{"undefined"},  .{"true"},       .{"false"},  .{"void"},     .{"delete"}, .{"interface"},
    .{"type"},      .{"enum"},    .{"implements"}, .{"readonly"},   .{"as"},     .{"static"},   .{"public"}, .{"private"},
    .{"protected"}, .{"declare"}, .{"keyof"},      .{"super"},
}), .types = .initComptime(.{
    .{"string"}, .{"number"}, .{"boolean"}, .{"any"}, .{"unknown"}, .{"never"}, .{"object"}, .{"bigint"},
}) };

const rust_lang: Lang = .{ .quotes = "\"", .keywords = .initComptime(.{
    .{"fn"},    .{"let"},   .{"mut"},   .{"pub"},   .{"return"},   .{"if"},     .{"else"},   .{"match"}, .{"for"},
    .{"while"}, .{"loop"},  .{"in"},    .{"break"}, .{"continue"}, .{"struct"}, .{"enum"},   .{"impl"},  .{"trait"},
    .{"use"},   .{"mod"},   .{"crate"}, .{"self"},  .{"super"},    .{"where"},  .{"as"},     .{"ref"},   .{"move"},
    .{"async"}, .{"await"}, .{"dyn"},   .{"const"}, .{"static"},   .{"unsafe"}, .{"extern"}, .{"type"},  .{"true"},
    .{"false"},
}), .types = .initComptime(.{
    .{"i8"},   .{"i16"},   .{"i32"}, .{"i64"}, .{"i128"}, .{"isize"}, .{"u8"},  .{"u16"}, .{"u32"}, .{"u64"},
    .{"u128"}, .{"usize"}, .{"f32"}, .{"f64"}, .{"bool"}, .{"char"},  .{"str"},
}) };

const go_lang: Lang = .{ .quotes = "\"'`", .keywords = .initComptime(.{
    .{"func"}, .{"package"}, .{"import"}, .{"var"},      .{"const"}, .{"type"},  .{"struct"}, .{"interface"},
    .{"map"},  .{"chan"},    .{"return"}, .{"if"},       .{"else"},  .{"for"},   .{"range"},  .{"switch"},
    .{"case"}, .{"default"}, .{"break"},  .{"continue"}, .{"go"},    .{"defer"}, .{"select"}, .{"fallthrough"},
    .{"goto"}, .{"nil"},     .{"true"},   .{"false"},    .{"iota"},
}), .types = .initComptime(.{
    .{"int"},    .{"int8"},   .{"int16"},   .{"int32"},   .{"int64"},   .{"uint"},   .{"uint8"}, .{"uint16"},
    .{"uint32"}, .{"uint64"}, .{"uintptr"}, .{"float32"}, .{"float64"}, .{"string"}, .{"bool"},  .{"byte"},
    .{"rune"},   .{"error"},  .{"any"},
}) };

const swift_lang: Lang = .{ .quotes = "\"", .keywords = .initComptime(.{
    .{"func"},   .{"let"},      .{"var"},      .{"class"},  .{"struct"},  .{"enum"},     .{"protocol"}, .{"extension"},
    .{"import"}, .{"return"},   .{"if"},       .{"else"},   .{"guard"},   .{"switch"},   .{"case"},     .{"default"},
    .{"for"},    .{"in"},       .{"while"},    .{"repeat"}, .{"break"},   .{"continue"}, .{"defer"},    .{"throw"},
    .{"throws"}, .{"try"},      .{"catch"},    .{"do"},     .{"self"},    .{"super"},    .{"init"},     .{"deinit"},
    .{"nil"},    .{"true"},     .{"false"},    .{"static"}, .{"private"}, .{"public"},   .{"internal"}, .{"fileprivate"},
    .{"open"},   .{"override"}, .{"mutating"}, .{"async"},  .{"await"},   .{"some"},     .{"any"},      .{"where"},
    .{"as"},     .{"is"},       .{"inout"},
}) };

const c_lang: Lang = .{ .keywords = .initComptime(.{
    .{"if"},     .{"else"},     .{"for"},       .{"while"},    .{"do"},       .{"switch"},    .{"case"},    .{"default"},
    .{"break"},  .{"continue"}, .{"return"},    .{"struct"},   .{"union"},    .{"enum"},      .{"typedef"}, .{"static"},
    .{"const"},  .{"extern"},   .{"sizeof"},    .{"goto"},     .{"volatile"}, .{"inline"},    .{"auto"},    .{"class"},
    .{"public"}, .{"private"},  .{"protected"}, .{"template"}, .{"typename"}, .{"namespace"}, .{"using"},   .{"new"},
    .{"delete"}, .{"this"},     .{"virtual"},   .{"override"}, .{"nullptr"},  .{"true"},      .{"false"},   .{"constexpr"},
    .{"NULL"},
}), .types = .initComptime(.{
    .{"int"},     .{"char"},    .{"void"},    .{"short"},   .{"long"},     .{"float"},    .{"double"},   .{"unsigned"},
    .{"signed"},  .{"bool"},    .{"size_t"},  .{"uint8_t"}, .{"uint16_t"}, .{"uint32_t"}, .{"uint64_t"}, .{"int8_t"},
    .{"int16_t"}, .{"int32_t"}, .{"int64_t"},
}) };

const sh_lang: Lang = .{ .line = "#", .block = false, .caps_types = false, .keywords = .initComptime(.{
    .{"if"},      .{"then"},  .{"else"},  .{"elif"}, .{"fi"},       .{"for"},    .{"in"},    .{"do"},     .{"done"},
    .{"while"},   .{"until"}, .{"case"},  .{"esac"}, .{"function"}, .{"return"}, .{"local"}, .{"export"}, .{"readonly"},
    .{"declare"}, .{"unset"}, .{"shift"}, .{"exit"}, .{"set"},      .{"source"}, .{"echo"},  .{"cd"},
}) };

const data_words = Words.initComptime(.{ .{"true"}, .{"false"}, .{"null"}, .{"yes"}, .{"no"}, .{"on"}, .{"off"} });
const json_lang: Lang = .{ .line = "", .block = false, .quotes = "\"", .caps_types = false, .keywords = data_words };
const conf_lang: Lang = .{ .line = "#", .block = false, .caps_types = false, .keywords = data_words };

const sql_lang: Lang = .{ .line = "--", .quotes = "'\"", .caps_types = false, .nocase = true, .keywords = .initComptime(.{
    .{"select"},  .{"from"},       .{"where"},   .{"and"},      .{"or"},    .{"not"},       .{"insert"}, .{"into"},    .{"values"},
    .{"update"},  .{"set"},        .{"delete"},  .{"create"},   .{"table"}, .{"drop"},      .{"alter"},  .{"index"},   .{"join"},
    .{"left"},    .{"right"},      .{"inner"},   .{"outer"},    .{"on"},    .{"group"},     .{"by"},     .{"order"},   .{"having"},
    .{"limit"},   .{"offset"},     .{"as"},      .{"distinct"}, .{"union"}, .{"all"},       .{"null"},   .{"is"},      .{"in"},
    .{"like"},    .{"between"},    .{"case"},    .{"when"},     .{"then"},  .{"else"},      .{"end"},    .{"primary"}, .{"key"},
    .{"foreign"}, .{"references"}, .{"default"}, .{"exists"},   .{"with"},  .{"returning"}, .{"asc"},    .{"desc"},
}), .types = .initComptime(.{
    .{"int"}, .{"integer"}, .{"text"}, .{"varchar"}, .{"boolean"}, .{"real"}, .{"blob"}, .{"bigint"}, .{"timestamp"},
}) };

const generic_lang: Lang = .{ .line2 = "#", .keywords = .initComptime(.{
    .{"if"},     .{"else"},    .{"for"},    .{"while"}, .{"return"}, .{"function"}, .{"fn"},     .{"func"}, .{"def"},
    .{"class"},  .{"struct"},  .{"enum"},   .{"let"},   .{"const"},  .{"var"},      .{"import"}, .{"from"}, .{"true"},
    .{"false"},  .{"null"},    .{"nil"},    .{"None"},  .{"True"},   .{"False"},    .{"new"},    .{"this"}, .{"self"},
    .{"public"}, .{"private"}, .{"static"}, .{"try"},   .{"catch"},  .{"throw"},    .{"match"},  .{"case"}, .{"switch"},
}) };

const langs = std.StaticStringMap(*const Lang).initComptime(.{
    .{ "zig", &zig_lang },       .{ "py", &py_lang },     .{ "python", &py_lang },     .{ "js", &js_lang },
    .{ "javascript", &js_lang }, .{ "ts", &js_lang },     .{ "typescript", &js_lang }, .{ "tsx", &js_lang },
    .{ "jsx", &js_lang },        .{ "rs", &rust_lang },   .{ "rust", &rust_lang },     .{ "go", &go_lang },
    .{ "swift", &swift_lang },   .{ "c", &c_lang },       .{ "h", &c_lang },           .{ "cpp", &c_lang },
    .{ "c++", &c_lang },         .{ "cc", &c_lang },      .{ "hpp", &c_lang },         .{ "objc", &c_lang },
    .{ "sh", &sh_lang },         .{ "bash", &sh_lang },   .{ "zsh", &sh_lang },        .{ "shell", &sh_lang },
    .{ "console", &sh_lang },    .{ "json", &json_lang }, .{ "jsonc", &json_lang },    .{ "toml", &conf_lang },
    .{ "yaml", &conf_lang },     .{ "yml", &conf_lang },  .{ "ini", &conf_lang },      .{ "sql", &sql_lang },
});

/// Spans colouring `text`, fenced as `language` (its first word, any case):
/// sorted, apart, each within `text`; none for plain text.
pub fn highlightCode(a: std.mem.Allocator, th: *const MdTheme, language: []const u8, text: []const u8) ![]const ui.Span {
    var buf: [16]u8 = undefined;
    const word = std.mem.sliceTo(language, ' ');
    if (word.len == 0 or word.len > buf.len) return &.{};
    const name = std.ascii.lowerString(&buf, word);
    if (std.mem.eql(u8, name, "diff") or std.mem.eql(u8, name, "patch")) return diff(a, th, text);
    if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "txt") or std.mem.eql(u8, name, "plain") or std.mem.eql(u8, name, "markdown") or std.mem.eql(u8, name, "md")) return &.{};
    return code(a, th, langs.get(name) orelse &generic_lang, text);
}

const Out = struct {
    a: std.mem.Allocator,
    text: []const u8,
    list: std.ArrayList(ui.Span) = .empty,

    /// `[from, to)` in `color`, a span a line so each line keeps its own.
    fn add(o: *Out, from: usize, to: usize, color: ui.Color, italic: bool) !void {
        var s = from;
        while (s < to) {
            const e = if (std.mem.indexOfScalarPos(u8, o.text[0..to], s, '\n')) |nl| nl else to;
            if (e > s) try o.list.append(o.a, .{ .start = @intCast(s), .end = @intCast(e), .color = color, .italic = italic });
            s = e + 1;
        }
    }
};

fn diff(a: std.mem.Allocator, th: *const MdTheme, text: []const u8) ![]const ui.Span {
    var o: Out = .{ .a = a, .text = text };
    var start: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        defer start += line.len + 1;
        const head = std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or
            std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "index ");
        const color: ?ui.Color = if (head) th.comment else if (std.mem.startsWith(u8, line, "@@")) th.hunk else if (line.len > 0 and line[0] == '+') th.added else if (line.len > 0 and line[0] == '-') th.removed else null;
        if (color) |col| try o.add(start, start + line.len, col, false);
    }
    return o.list.items;
}

fn identStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn identChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn code(a: std.mem.Allocator, th: *const MdTheme, l: *const Lang, text: []const u8) ![]const ui.Span {
    var o: Out = .{ .a = a, .text = text };
    const n = text.len;
    var i: usize = 0;
    while (i < n) {
        const ch = text[i];
        const rest = text[i..];
        const line_end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse n;
        if ((l.line.len > 0 and std.mem.startsWith(u8, rest, l.line)) or (l.line2.len > 0 and std.mem.startsWith(u8, rest, l.line2))) {
            try o.add(i, line_end, th.comment, true);
            i = line_end;
        } else if (l.block and std.mem.startsWith(u8, rest, "/*")) {
            const e = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |k| k + 2 else n;
            try o.add(i, e, th.comment, true);
            i = e;
        } else if (l.line_string and std.mem.startsWith(u8, rest, "\\\\")) {
            try o.add(i, line_end, th.string, false);
            i = line_end;
        } else if (l.triple and (std.mem.startsWith(u8, rest, "\"\"\"") or std.mem.startsWith(u8, rest, "'''"))) {
            const e = if (std.mem.indexOfPos(u8, text, i + 3, rest[0..3])) |k| k + 3 else n;
            try o.add(i, e, th.string, false);
            i = e;
        } else if (std.mem.indexOfScalar(u8, l.quotes, ch) != null) {
            // To the closing quote, past escapes; a line at most, but for backticks.
            var j = i + 1;
            while (j < n and text[j] != ch and (ch == '`' or text[j] != '\n')) j += if (text[j] == '\\') 2 else 1;
            const e = @min(n, if (j < n and text[j] == ch) j + 1 else j);
            try o.add(i, e, th.string, false);
            i = e;
        } else if (std.ascii.isDigit(ch) and (i == 0 or !identChar(text[i - 1]))) {
            var j = i + 1;
            while (j < n and (identChar(text[j]) or (text[j] == '.' and j + 1 < n and std.ascii.isDigit(text[j + 1])))) j += 1;
            try o.add(i, j, th.number, false);
            i = j;
        } else if ((identStart(ch) or (ch == '@' and i + 1 < n and identStart(text[i + 1]))) and (i == 0 or !identChar(text[i - 1]))) {
            var j = i + 1;
            while (j < n and identChar(text[j])) j += 1;
            const word = text[i..j];
            var low: [24]u8 = undefined;
            const key = if (l.nocase and word.len <= low.len) std.ascii.lowerString(&low, word) else word;
            const color: ?ui.Color = if (l.keywords.has(key))
                th.keyword
            else if (l.types.has(key) or (l.caps_types and std.ascii.isUpper(ch)))
                th.type_
            else if (ch == '@' or (j < n and text[j] == '('))
                th.call
            else
                null;
            if (color) |col| try o.add(i, j, col, false);
            i = j;
        } else i += 1;
    }
    return o.list.items;
}

fn expectSound(spans: []const ui.Span, text: []const u8, colours_at_least: usize) !void {
    var distinct: [16]ui.Color = undefined;
    var count: usize = 0;
    var last: u32 = 0;
    for (spans) |sp| {
        try std.testing.expect(sp.start < sp.end and sp.end <= text.len and sp.start >= last);
        last = sp.end;
        const col = sp.color.?;
        for (distinct[0..count]) |d| {
            if (std.meta.eql(d, col)) break;
        } else if (count < distinct.len) {
            distinct[count] = col;
            count += 1;
        }
    }
    try std.testing.expect(count >= colours_at_least);
}

test "highlightCode colours zig, python and diffs, its spans sorted and apart" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const th = MdTheme.of(true, @import("../design/palette.zig").get(true));
    const zig_src = "// kea\nconst n: u32 = 42;\npub fn main() void {\n    std.debug.print(\"hi {d}\\n\", .{n});\n}";
    const zs = try highlightCode(a, &th, "zig", zig_src);
    try expectSound(zs, zig_src, 5);
    try std.testing.expectEqualStrings("// kea", zig_src[zs[0].start..zs[0].end]);
    try std.testing.expect(zs[0].italic);
    try std.testing.expectEqualStrings("const", zig_src[zs[1].start..zs[1].end]);
    try std.testing.expectEqual(th.keyword, zs[1].color.?);

    const py_src = "def area(r: float) -> float:\n    \"\"\"Circle.\n    area\"\"\"\n    return 3.14 * r ** 2  # pi r^2\nprint(area(2))";
    const ps = try highlightCode(a, &th, "Python", py_src);
    try expectSound(ps, py_src, 5);
    // The docstring is a span a line.
    for (ps) |sp| try std.testing.expect(std.mem.indexOfScalar(u8, py_src[sp.start..sp.end], '\n') == null);

    const diff_src = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same";
    const ds = try highlightCode(a, &th, "diff", diff_src);
    try expectSound(ds, diff_src, 4);
    try std.testing.expectEqual(@as(usize, 5), ds.len);
    try std.testing.expectEqual(th.removed, ds[3].color.?);
    try std.testing.expectEqual(th.added, ds[4].color.?);

    try std.testing.expectEqual(@as(usize, 0), (try highlightCode(a, &th, "", zig_src)).len);
    // Unclosed strings and comments stay within the text.
    const cut = "x = \"open\n/* never";
    try expectSound(try highlightCode(a, &th, "js", cut), cut, 1);
}
