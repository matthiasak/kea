//! `ExtensionRedirectPolicy` (ExtensionRedirectPolicy.swift): a website may
//! return only to an extension page its manifest exposes. Unsupported
//! declarations are refused, never made more permissive.
const std = @import("std");
const Parts = @import("../data/url.zig").Parts;
const Value = std.json.Value;

pub fn allows(target: []const u8, source_origin: []const u8, manifest: Value) bool {
    const t = Parts.parse(target) orelse return false;
    const s = Parts.parse(source_origin) orelse return false;
    if (!t.schemeIs("chrome-extension") or t.hostName() == null or t.user != null or t.password != null or t.port != null) return false;
    if (!s.schemeIs("https") or s.hostName() == null or s.user != null or s.password != null) return false;

    // Fail closed on encodings with inconsistent path interpretations.
    const encoded = t.path;
    if (!std.mem.startsWith(u8, encoded, "/")) return false;
    if (std.ascii.findIgnoreCase(encoded, "%2f") != null or std.ascii.findIgnoreCase(encoded, "%5c") != null) return false;
    var buf: [4096]u8 = undefined;
    const decoded = percentDecode(&buf, encoded) orelse return false;
    if (std.mem.indexOfAny(u8, decoded, "\\%") != null or hasControl(decoded)) return false;
    const path = decoded[1..];
    if (path.len == 0 or !cleanSegments(path)) return false;

    if (manifest != .object) return false;
    const version = intOf(manifest.object.get("manifest_version"));
    const listed = manifest.object.get("web_accessible_resources");
    // MV2 lists resources, without MV3's per-origin declarations.
    if (version == 2) if (strings(listed)) |resources| return anyResource(path, resources);

    if (version != 3) return false;
    const rules = listed orelse return false;
    if (rules != .array) return false;
    for (rules.array.items) |rule| if (rule != .object) return false;
    for (rules.array.items) |rule| {
        // Dynamic extension origins need separate handling; refuse them here.
        if (rule.object.get("use_dynamic_url")) |dynamic| {
            // `as? Bool`: NSNumber 0 reads as false too.
            const off = (dynamic == .bool and !dynamic.bool) or (dynamic == .integer and dynamic.integer == 0);
            if (!off) continue;
        }
        const resources = strings(rule.object.get("resources")) orelse continue;
        const origins = strings(rule.object.get("matches")) orelse continue;
        if (!anyResource(path, resources)) continue;
        for (origins.array.items) |o| if (origin(s, o.string)) return true;
    }
    return false;
}

/// `as? Int`: an integer, or a float that is one.
fn intOf(v: ?Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f) @intFromFloat(f) else null,
        else => null,
    };
}

/// `as? [String]`: an array of strings only.
fn strings(v: ?Value) ?Value {
    const x = v orelse return null;
    if (x != .array) return null;
    for (x.array.items) |item| if (item != .string) return null;
    return x;
}

fn anyResource(path: []const u8, resources: Value) bool {
    for (resources.array.items) |r| if (resource(path, r.string)) return true;
    return false;
}

/// No ".", ".." or empty segment between slashes.
fn cleanSegments(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    return true;
}

fn resource(path: []const u8, pattern: []const u8) bool {
    // Only the '*' wildcard. Other regex metacharacters stay literal.
    if (pattern.len == 0 or std.mem.indexOfAny(u8, pattern, "\\%") != null or hasControl(pattern)) return false;
    const clean = if (pattern[0] == '/') pattern[1..] else pattern;
    if (!cleanSegments(clean)) return false;
    return glob(clean, path);
}

/// `\A` + pieces joined by `.*` + `\z`.
fn glob(pattern: []const u8, text: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, text);
    if (!std.mem.startsWith(u8, text, pattern[0..star])) return false;
    const rest = pattern[star + 1 ..];
    var i: usize = star;
    while (i <= text.len) : (i += 1) if (glob(rest, text[i..])) return true;
    return false;
}

fn origin(source: Parts, pattern: []const u8) bool {
    // Only HTTPS callers are accepted by allows(). MV3 origin patterns
    // have a /* path. Unsupported syntax is deliberately rejected.
    if (std.mem.eql(u8, pattern, "<all_urls>")) return true;
    const sep = std.mem.indexOf(u8, pattern, "://") orelse return false;
    var host_buf: [256]u8 = undefined;
    const raw_host = source.hostName() orelse return false;
    if (raw_host.len > host_buf.len) return false;
    const host = std.ascii.lowerString(&host_buf, raw_host);
    const scheme = pattern[0..sep];
    if (!std.ascii.eqlIgnoreCase(scheme, "https") and !std.mem.eql(u8, scheme, "*")) return false;
    const remainder = pattern[sep + 3 ..];
    const slash = std.mem.indexOfScalar(u8, remainder, '/') orelse return false;
    if (!std.mem.eql(u8, remainder[slash..], "/*")) return false;
    var allowed_buf: [256]u8 = undefined;
    if (slash > allowed_buf.len) return false;
    const allowed = std.ascii.lowerString(&allowed_buf, remainder[0..slash]);
    if (allowed.len == 0 or std.mem.indexOfAny(u8, allowed, ":@%\\") != null) return false;
    if (std.mem.eql(u8, allowed, "*")) return true;
    if (std.mem.startsWith(u8, allowed, "*.")) {
        const suffix = allowed[2..];
        if (suffix.len == 0 or std.mem.indexOfScalar(u8, suffix, '*') != null) return false;
        return std.mem.eql(u8, host, suffix) or (host.len > suffix.len and std.mem.endsWith(u8, host, suffix) and host[host.len - suffix.len - 1] == '.');
    }
    return std.mem.indexOfScalar(u8, allowed, '*') == null and std.mem.eql(u8, host, allowed);
}

/// `removingPercentEncoding`: null on a malformed escape or bytes that
/// aren't UTF-8 (and, here, on a path longer than `buf`).
fn percentDecode(buf: []u8, s: []const u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) {
        if (n == buf.len) return null;
        if (s[i] == '%') {
            if (i + 2 >= s.len) return null;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return null;
            buf[n] = hi * 16 + lo;
            i += 3;
        } else {
            buf[n] = s[i];
            i += 1;
        }
    }
    if (!std.unicode.utf8ValidateSlice(buf[0..n])) return null;
    return buf[0..n];
}

/// `CharacterSet.controlCharacters`: general categories Cc and Cf. Text
/// that isn't UTF-8 counts as containing one.
fn hasControl(s: []const u8) bool {
    const view = std.unicode.Utf8View.init(s) catch return true;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| if (isControl(c)) return true;
    return false;
}

const cf = [_][2]u21{
    .{ 0xAD, 0xAD },       .{ 0x600, 0x605 },     .{ 0x61C, 0x61C },     .{ 0x6DD, 0x6DD },
    .{ 0x70F, 0x70F },     .{ 0x890, 0x891 },     .{ 0x8E2, 0x8E2 },     .{ 0x180E, 0x180E },
    .{ 0x200B, 0x200F },   .{ 0x202A, 0x202E },   .{ 0x2060, 0x2064 },   .{ 0x2066, 0x206F },
    .{ 0xFEFF, 0xFEFF },   .{ 0xFFF9, 0xFFFB },   .{ 0x110BD, 0x110BD }, .{ 0x110CD, 0x110CD },
    .{ 0x13430, 0x1343F }, .{ 0x1BCA0, 0x1BCA3 }, .{ 0x1D173, 0x1D17A }, .{ 0xE0001, 0xE0001 },
    .{ 0xE0020, 0xE007F },
};

fn isControl(c: u21) bool {
    if (c < 0x20 or (c >= 0x7F and c <= 0x9F)) return true;
    for (cf) |r| if (c >= r[0] and c <= r[1]) return true;
    return false;
}

test "redirect policy matches web_accessible_resources" {
    const gpa = std.testing.allocator;
    const mv3 = try std.json.parseFromSlice(Value, gpa,
        \\{"manifest_version":3,"web_accessible_resources":[
        \\ {"resources":["auth/*.html","/done.html"],"matches":["https://*.example.com/*"]},
        \\ {"resources":["dyn.html"],"matches":["<all_urls>"],"use_dynamic_url":true},
        \\ {"resources":["any.html"],"matches":["*://site.org/*"],"use_dynamic_url":false}]}
    , .{});
    defer mv3.deinit();
    const m = mv3.value;
    const ok = "https://login.example.com/";
    try std.testing.expect(allows("chrome-extension://abc/auth/callback.html", ok, m));
    try std.testing.expect(allows("chrome-extension://abc/done.html?x=1", "https://example.com/", m));
    try std.testing.expect(allows("chrome-extension://abc/any.html", "https://SITE.org/", m));
    // Wrong origin, scheme, or a resource not listed.
    try std.testing.expect(!allows("chrome-extension://abc/auth/callback.html", "https://evil.com/", m));
    try std.testing.expect(!allows("chrome-extension://abc/auth/callback.html", "https://badexample.com/", m));
    try std.testing.expect(!allows("chrome-extension://abc/auth/callback.html", "http://login.example.com/", m));
    try std.testing.expect(!allows("chrome-extension://abc/other.html", ok, m));
    try std.testing.expect(!allows("https://abc/auth/x.html", ok, m));
    // Dynamic URLs refused; a port, a user, odd encodings and dot segments too.
    try std.testing.expect(!allows("chrome-extension://abc/dyn.html", ok, m));
    try std.testing.expect(!allows("chrome-extension://abc:1/done.html", ok, m));
    try std.testing.expect(!allows("chrome-extension://u@abc/done.html", ok, m));
    try std.testing.expect(!allows("chrome-extension://abc/auth%2fx.html", ok, m));
    try std.testing.expect(!allows("chrome-extension://abc/auth/../done.html", ok, m));
    try std.testing.expect(!allows("chrome-extension://abc/auth//x.html", ok, m));
    try std.testing.expect(!allows("chrome-extension://abc/auth/%E2%80%8Bx.html", ok, m));
    try std.testing.expect(!allows("chrome-extension://abc/auth/%zz.html", ok, m));
    try std.testing.expect(allows("chrome-extension://abc/auth/%61.html", ok, m));
    const mv2 = try std.json.parseFromSlice(Value, gpa,
        \\{"manifest_version":2,"web_accessible_resources":["pages/*"]}
    , .{});
    defer mv2.deinit();
    try std.testing.expect(allows("chrome-extension://abc/pages/a.html", "https://any.where/", mv2.value));
    try std.testing.expect(!allows("chrome-extension://abc/page.html", "https://any.where/", mv2.value));
    try std.testing.expect(!allows("chrome-extension://abc/pages/a.html", "https://u:p@any.where/", mv2.value));
}
