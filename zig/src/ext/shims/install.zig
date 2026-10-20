//! The Chrome APIs WebKit doesn't have, put into an extension at install
//! (ExtensionShims.swift 1-246): a script at the front of its background
//! and of every page it ships, so `chrome.bookmarks` and the rest are there
//! and every call becomes a native message to `application`. Pure file I/O:
//! safe off the main thread.
const std = @import("std");
const files = @import("install_files.zig");
const crx = @import("../crx.zig");

const Value = std.json.Value;
const A = std.mem.Allocator;

/// The name native messages to the browser itself go to.
pub const application = "kea";
pub const file = "kea-shim.js";
pub const content_file = "kea-shim-content.js";
/// Kea's passkey patch, put first in every script an extension runs in a
/// page's own world.
pub const passkeys_file = "kea-passkeys.js";
/// The first line of a worker that already carries the shim.
pub const marker = "/* Kea: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */";
pub const ender = "/* Kea: end of shim */";
/// Written beside a prepared extension: which shim it carries.
pub const stamp = ".kea-shim";
/// Raised when `prepare` changes what it does to a package.
const preparation = "3";

/// `PasskeyRelay.page` as passwords/passkeys.zig `pageScript()` gives it on
/// macOS 15+ (always, where extensions run: they need 15.4).
pub const passkey_page = blk: {
    @setEvalBranchQuota(10_000_000);
    const src = @embedFile("../../passwords/js/passkeys_page.js");
    const at = std.mem.indexOf(u8, src, "__KEA_PRF__").?;
    break :blk src[0..at] ++ "true" ++ src[at + "__KEA_PRF__".len ..];
};

/// `Store.testing`, set once by the controller (Kea.testing) before the
/// first `prepare`/`shim`/`version`.
pub var testing = false;

/// The raw script (Swift's `script`), byte for byte.
pub const script = @embedFile("../js/shim_1.js") ++ @embedFile("../js/shim_2.js") ++
    @embedFile("../js/shim_3.js") ++ @embedFile("../js/shim_4.js") ++
    @embedFile("../js/shim_5.js") ++ @embedFile("../js/shim_6.js");

/// `contentScript`: the shim without the parts only a worker or page needs.
pub const content_script = blk: {
    @setEvalBranchQuota(50_000_000);
    const a = std.mem.indexOf(u8, script, "// kea:content-skip-begin\n").?;
    const b_mark = "// kea:content-skip-end\n";
    const b = std.mem.indexOf(u8, script, b_mark).? + b_mark.len;
    const e = std.mem.indexOf(u8, script, "// kea:content-end\n").?;
    break :blk script[0..a] ++ script[b..e] ++ "    })();\n";
};

/// `version`: the first 8 bytes of SHA-256(script + passkey page +
/// preparation) in hex, "-test" when testing.
pub fn version() []const u8 {
    const S = struct {
        var buf: [21]u8 = undefined;
        var len: usize = 0;
    };
    if (S.len == 0) {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(script);
        h.update(passkey_page);
        h.update(preparation);
        const d = h.finalResult();
        const hex = std.fmt.bytesToHex(d[0..8].*, .lower);
        @memcpy(S.buf[0..16], &hex);
        S.len = 16;
        if (testing) {
            @memcpy(S.buf[16..21], "-test");
            S.len = 21;
        }
    }
    return S.buf[0..S.len];
}

/// `prepare(_:fresh:)`. `fresh`: a package just unpacked or copied in —
/// anything by Kea's own names inside it goes before a word is read.
pub fn prepare(gpa: A, folder: []const u8, fresh: bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const at = struct {
        fn f(al: A, dir: []const u8, name: []const u8) ![]u8 {
            return std.fs.path.join(al, &.{ dir, name });
        }
    }.f;
    if (fresh) for ([_][]const u8{ stamp, ".kea-added" }) |n| files.remove(a, try at(a, folder, n));
    const stamp_path = try at(a, folder, stamp);
    if (files.read(a, stamp_path)) |s| if (std.mem.eql(u8, s, version())) return;
    defer files.write(a, stamp_path, version()) catch {};

    const manifest_path = try at(a, folder, "manifest.json");
    const bytes = files.read(a, manifest_path) orelse return error.Unpack;
    // As JSONSerialization: a leading BOM is skipped, the last of a repeated key wins.
    const body = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
    var root = std.json.parseFromSliceLeaky(Value, a, body, .{ .parse_numbers = false, .duplicate_field_behavior = .use_last }) catch return error.Unpack;
    if (root != .object) return error.Unpack;
    const manifest = &root.object;

    const shimmed = try shim(a, folder);
    try files.write(a, try at(a, folder, file), shimmed);
    try files.write(a, try at(a, folder, content_file), content_script);
    try files.write(a, try at(a, folder, passkeys_file), passkey_page);

    // Native messaging is how the shim reaches the browser; user scripts
    // need scripting. What is added is written down.
    var permissions: std.json.Array = if (manifest.get("permissions")) |p| (if (p == .array) p.array else .init(a)) else .init(a);
    var asked: std.StringHashMapUnmanaged(void) = .empty;
    for (permissions.items) |p| if (p == .string) try asked.put(a, p.string, {});
    var added: std.ArrayList([]const u8) = .empty;
    const added_path = try at(a, folder, ".kea-added");
    if (files.read(a, added_path)) |t| if (std.json.parseFromSliceLeaky([][]const u8, a, t, .{})) |old| {
        try added.appendSlice(a, old);
    } else |_| {};
    const needs: []const []const u8 = if (asked.contains("userScripts")) &.{ "nativeMessaging", "scripting" } else &.{"nativeMessaging"};
    for (needs) |needed| if (!asked.contains(needed)) {
        try permissions.append(.{ .string = needed });
        try added.append(a, needed);
    };
    try manifest.put(a, "permissions", .{ .array = permissions });
    sortUnique(&added);
    if (swiftJson(a, added.items)) |t| files.write(a, added_path, t) catch {} else |_| {}

    // The background gets the shim first: a classic worker at the top of
    // its own file, a module one by importing it first.
    if (manifest.getPtr("background")) |bg| if (bg.* == .object) {
        const background = &bg.object;
        if (background.get("service_worker")) |w| if (w == .string) {
            files.unlink(a, w.string, folder);
            if (try files.inside(a, w.string, folder)) |path| if (files.read(a, path)) |text| if (std.unicode.utf8ValidateSlice(text)) {
                const module = if (background.get("type")) |t| t == .string and std.mem.eql(u8, t.string, "module") else false;
                const out = try rewriteWorker(a, text, shimmed, module);
                try files.write(a, path, out);
            };
        };
        // Scripts, alone or beside a worker.
        if (background.getPtr("scripts")) |s| if (s.* == .array and allStrings(s.array.items)) {
            const items = s.array.items;
            if (items.len == 0 or !std.mem.eql(u8, items[0].string, file)) try s.array.insert(0, .{ .string = file });
        };
    };

    // Content scripts: Chrome's behaviour mended, and the passkey patch
    // before one that runs in the page's own world.
    if (manifest.get("content_scripts")) |cs| if (cs == .array and allObjects(cs.array.items)) for (cs.array.items) |*entry| {
        const js = entry.object.getPtr("js") orelse continue;
        if (js.* != .array or !allStrings(js.array.items)) continue;
        var kept: std.json.Array = .init(a);
        const main_world = if (entry.object.get("world")) |w| w == .string and std.ascii.eqlIgnoreCase(w.string, "MAIN") else false;
        if (main_world) try kept.append(.{ .string = passkeys_file });
        try kept.append(.{ .string = content_file });
        for (js.array.items) |j| {
            const n = j.string;
            if (!std.mem.eql(u8, n, file) and !std.mem.eql(u8, n, content_file) and !std.mem.eql(u8, n, passkeys_file)) try kept.append(j);
        }
        js.* = .{ .array = kept };
    };

    // ponytail: key order kept as read and std.json's 2-space layout; Swift's
    // JSONSerialization order is a dictionary's (unspecified) anyway.
    const text = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
    try files.write(a, manifest_path, text);

    // Every page it ships — popup, options, background page, side panel.
    var pages: std.ArrayList(files.Entry) = .empty;
    try files.walk(a, folder, &pages);
    for (pages.items) |p| {
        if (p.link or p.dir) continue;
        const ext = std.fs.path.extension(p.path);
        if (!std.ascii.eqlIgnoreCase(ext, ".html") and !std.ascii.eqlIgnoreCase(ext, ".htm")) continue;
        const html = files.read(a, p.path) orelse continue;
        if (!std.unicode.utf8ValidateSlice(html) or std.mem.indexOf(u8, html, file) != null) continue;
        const tag = "<script src=\"/" ++ file ++ "\"></script>";
        const cut = headEnd(html) orelse 0;
        files.write(a, p.path, try std.mem.concat(a, u8, &.{ html[0..cut], tag, html[cut..] })) catch {};
    }
}

/// The worker's text with the shim (or for a module, its import) first,
/// any shim it already carried taken off.
pub fn rewriteWorker(a: A, text: []const u8, shimmed: []const u8, module: bool) ![]u8 {
    var source = text;
    if (std.mem.startsWith(u8, source, marker)) if (std.mem.indexOf(u8, source, ender)) |e| {
        source = source[e + ender.len ..];
        if (std.mem.startsWith(u8, source, "\n")) source = source[1..];
    };
    // A copy from before there was an end marker ends at the first `})();`
    // that starts a line.
    while (std.mem.startsWith(u8, source, marker)) {
        const e = std.mem.indexOf(u8, source, "\n})();\n") orelse break;
        source = source[e + 7 ..];
    }
    const first = "import \"/" ++ file ++ "\";\n";
    while (std.mem.startsWith(u8, source, first)) source = source[first.len..];
    if (module) return std.mem.concat(a, u8, &.{ first, source });
    return std.mem.concat(a, u8, &.{ marker, "\n", shimmed, "\n", ender, "\n", source });
}

/// Where `<head[^>]*>` (any case) ends, as Swift's regular expression.
fn headEnd(html: []const u8) ?usize {
    var i: usize = 0;
    while (i + 5 <= html.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(html[i .. i + 5], "<head")) continue;
        const gt = std.mem.indexOfScalarPos(u8, html, i + 5, '>') orelse return null;
        return gt + 1;
    }
    return null;
}

/// `shim(for:)`: the script with the events this extension's code mentions
/// and the scripts it ships filled in. On `gpa`.
pub fn shim(gpa: A, folder: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try std.fs.path.resolveAllocPosix(a, &.{folder});
    var entries: std.ArrayList(files.Entry) = .empty;
    try files.walk(a, root, &entries);
    var found: std.ArrayList([]const u8) = .empty;
    var scripts: std.ArrayList([]const u8) = .empty;
    for (entries.items) |e| {
        if (!std.mem.eql(u8, std.fs.path.extension(e.path), ".js")) continue;
        const text = if (e.dir) null else files.read(a, e.path);
        const valid = if (text) |t| std.unicode.utf8ValidateSlice(t) else false;
        const base = std.fs.path.basename(e.path);
        if (valid and !std.mem.eql(u8, base, file) and !std.mem.eql(u8, base, content_file)) {
            var t = text.?;
            // Not the shim's own words, in a worker that already carries it.
            if (std.mem.startsWith(u8, t, marker)) if (std.mem.indexOf(u8, t, ender)) |x| {
                t = t[x + ender.len ..];
            };
            try events(a, t, &found);
        }
        // An empty one is marked: there is nothing to run in it.
        const empty = valid and blank(text.?);
        try scripts.append(a, try std.mem.concat(a, u8, &.{ if (empty) "-" else "", e.path[root.len..] }));
    }
    sortUnique(&found);
    std.mem.sort([]const u8, scripts.items, {}, lessThan);
    const list = try swiftJson(a, found.items);
    const shipped = try swiftJson(a, scripts.items);

    var out = try std.mem.replaceOwned(u8, a, script, "__KEA_EVENTS__", list);
    inline for (.{
        .{ "__KEA_SCRIPTS__", shipped },
        .{ "__KEA_CHROME__", crx.chrome_version },
        .{ "__KEA_VERBOSE__", if (testing) "true" else "false" },
    }) |r| {
        out = try std.mem.replaceOwned(u8, a, out, r[0], r[1]);
    }
    return gpa.dupe(u8, out);
}

/// Every match of `\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b` in `text`, as
/// "group1.group2", appended to `found` (heap strings on `a`).
pub fn events(a: A, text: []const u8, found: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '.') continue;
        const g1 = i + 1;
        var j = g1;
        while (j < text.len and std.ascii.isAlphabetic(text[j])) j += 1;
        if (j == g1 or j >= text.len or text[j] != '.') continue;
        const g2 = j + 1;
        var k = g2;
        while (k < text.len and std.ascii.isAlphabetic(text[k])) k += 1;
        // "on", a capital, then at least one more letter.
        if (k - g2 < 4 or text[g2] != 'o' or text[g2 + 1] != 'n' or !std.ascii.isUpper(text[g2 + 2])) continue;
        // \b: what follows is not a word character.
        if (k < text.len and isWordAt(text, k)) continue;
        try found.append(a, try std.mem.concat(a, u8, &.{ text[g1..j], ".", text[g2..k] }));
        i = k - 1;
    }
}

extern fn CFCharacterSetGetPredefined(set: isize) *const anyopaque;
extern fn CFCharacterSetIsLongCharacterMember(set: *const anyopaque, char: u32) u8;
const cf_whitespace_and_newline = 3;
const cf_decimal_digit = 4;
const cf_letter = 5;

fn inSet(set: isize, cp: u21) bool {
    return CFCharacterSetIsLongCharacterMember(CFCharacterSetGetPredefined(set), cp) != 0;
}

/// The code point at `text[k]`, or null where the UTF-8 is broken.
fn codePointAt(text: []const u8, k: usize) ?struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(text[k]) catch return null;
    if (k + n > text.len) return null;
    return .{ .cp = std.unicode.utf8Decode(text[k .. k + n]) catch return null, .len = n };
}

/// ICU's word character, as `\b` reads it (NSRegularExpression): a letter
/// or mark in any script, a decimal digit, connector punctuation, ZWNJ/ZWJ.
fn isWordAt(text: []const u8, k: usize) bool {
    const at = codePointAt(text, k) orelse return false;
    return switch (at.cp) {
        '_', 0x200c, 0x200d, 0x203f, 0x2040, 0x2054, 0xfe33, 0xfe34, 0xfe4d...0xfe4f, 0xff3f => true,
        else => inSet(cf_letter, at.cp) or inSet(cf_decimal_digit, at.cp),
    };
}

/// Nothing but white space and new lines, in Unicode's sense
/// (`trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`).
fn blank(text: []const u8) bool {
    var k: usize = 0;
    while (k < text.len) {
        const at = codePointAt(text, k) orelse return false;
        if (!inSet(cf_whitespace_and_newline, at.cp)) return false;
        k += at.len;
    }
    return true;
}

test "word characters and blanks are Unicode's" {
    try std.testing.expect(isWordAt("é", 0));
    try std.testing.expect(isWordAt("٣", 0));
    try std.testing.expect(!isWordAt("→", 0));
    try std.testing.expect(!isWordAt(" ", 0));
    try std.testing.expect(blank(" \u{3000}\u{a0}\n\u{2028}"));
    try std.testing.expect(!blank(" x "));
    var found: std.ArrayList([]const u8) = .empty;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try events(arena.allocator(), "chrome.tabs.onUpdated→x chrome.tabs.onMovedé", &found);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expectEqualStrings("tabs.onUpdated", found.items[0]);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// Sorted, each once (`Array(Set(x)).sorted()`); duplicates dropped without
/// freeing (callers use an arena).
fn sortUnique(list: *std.ArrayList([]const u8)) void {
    std.mem.sort([]const u8, list.items, {}, lessThan);
    var n: usize = 0;
    for (list.items) |s| {
        if (n > 0 and std.mem.eql(u8, list.items[n - 1], s)) continue;
        list.items[n] = s;
        n += 1;
    }
    list.shrinkRetainingCapacity(n);
}

fn allStrings(items: []const Value) bool {
    for (items) |v| if (v != .string) return false;
    return true;
}

fn allObjects(items: []const Value) bool {
    for (items) |v| if (v != .object) return false;
    return true;
}

/// JSON as Foundation's JSONSerialization writes it by default: compact,
/// with `/` escaped. A `/` only occurs inside strings, so escaping every one
/// is exact.
pub fn swiftJson(a: A, value: anytype) ![]u8 {
    const plain = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(plain);
    return std.mem.replaceOwned(u8, a, plain, "/", "\\/");
}

pub const scriptingFile = files.scriptingFile;
pub const userScriptFile = files.userScriptFile;
pub const invalid_script = files.invalid_script;
