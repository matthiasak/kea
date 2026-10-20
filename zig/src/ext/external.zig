//! `ExtensionExternal` (ExtensionExternal.swift, #496): a website talking
//! to an extension that lists it under `externally_connectable`. WebKit
//! hands such a page a `browser.runtime`; a page some loaded extension lists
//! — by Chrome's match-pattern rules — gets it as `chrome.runtime` too, only
//! if it has no `chrome` of its own. The list is read again for every page.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const Extensions = @import("controller.zig").Extensions;

/// Chrome refuses a pattern for every site (`*://*/*`) and a wildcard over
/// a whole top-level domain (`*.com`): a wildcard needs a domain with a dot
/// in it. Google's sites are left out too (their sign-in and reCAPTCHA turn
/// a browser with a partial `chrome` away).
pub fn allowed(pattern: []const u8) bool {
    const start = std.mem.indexOf(u8, pattern, "://") orelse return false;
    const scheme = pattern[0..start];
    if (!(std.mem.eql(u8, scheme, "*") or std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https"))) return false;
    const rest = pattern[start + 3 ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    var buf: [256]u8 = undefined;
    if (end > buf.len) return false;
    var host = std.ascii.lowerString(&buf, rest[0..end]);
    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| if (!std.mem.endsWith(u8, host, "]")) {
        host = host[0..colon];
    };
    if (host.len == 0 or std.mem.eql(u8, host, "*")) return false;
    if (std.mem.startsWith(u8, host, "*.")) {
        const base = host[2..];
        if (std.mem.indexOfScalar(u8, base, '.') == null or std.mem.indexOfScalar(u8, base, '*') != null) return false;
    } else if (std.mem.indexOfScalar(u8, host, '*') != null) return false;
    // Every label but the last.
    var labels = std.mem.tokenizeScalar(u8, host, '.');
    var previous: ?[]const u8 = null;
    while (labels.next()) |label| {
        if (previous) |p| if (std.mem.eql(u8, p, "google")) return false;
        previous = label;
    }
    return true;
}

/// The `externally_connectable` patterns of every extension loaded now,
/// those Chrome would take, unique and sorted; borrowed from the manifests
/// (push a Pool around the call).
fn patterns(owner: *Extensions, gpa: std.mem.Allocator) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    for (owner.contexts.values()) |context| {
        const manifest = objc.msg(?objc.Object, objc.msg(objc.Object, context, "webExtension", .{}), "manifest", .{}) orelse continue;
        const listed = dict(manifest, "externally_connectable") orelse continue;
        const matches = objc.msg(?objc.Object, listed, "objectForKey:", .{objc.nsString("matches")}) orelse continue;
        if (!kind(matches, "NSArray")) continue;
        // `as? [String]`: all strings, or none at all.
        const n = objc.msg(objc.NSUInteger, matches, "count", .{});
        var all = true;
        for (0..n) |i| all = all and kind(objc.msg(objc.Object, matches, "objectAtIndex:", .{i}), "NSString");
        if (!all) continue;
        for (0..n) |i| {
            const p = objc.fromNSString(objc.msg(objc.Object, matches, "objectAtIndex:", .{i}));
            if (!allowed(p)) continue;
            for (out.items) |have| {
                if (std.mem.eql(u8, have, p)) break;
            } else try out.append(gpa, p);
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

fn kind(o: objc.Object, comptime cls: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class(cls)});
}

fn dict(o: objc.Object, key: []const u8) ?objc.Object {
    const v = objc.msg(?objc.Object, o, "objectForKey:", .{objc.nsString(key)}) orelse return null;
    return if (kind(v, "NSDictionary")) v else null;
}

/// For the page about to load, in its own world before any of its
/// scripts, on `gpa`; null with nothing listed anywhere.
pub fn script(owner: *Extensions, gpa: std.mem.Allocator) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    var list = patterns(owner, gpa) catch return null;
    defer list.deinit(gpa);
    if (list.items.len == 0) return null;
    const encoded = json.encode(gpa, list.items) catch return null;
    defer gpa.free(encoded);
    return std.mem.concat(gpa, u8, &.{ body, encoded, ");" }) catch null;
}

const body =
    \\(function (patterns) {
    \\  var made = window.browser, runtime = made && made.runtime;
    \\  if (typeof window.chrome !== 'undefined' || !runtime || typeof runtime.sendMessage !== 'function') return;
    \\  // Chrome's match patterns: scheme, host, then path. A host with a
    \\  // port matches that port only; one without, any.
    \\  var glob = function (text) {
    \\    return new RegExp('^' + text.replace(/[.+?^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
    \\  };
    \\  var listed = function (pattern) {
    \\    var parts = /^(\*|https?):\/\/([^\/]+)(\/.*)$/.exec(pattern);
    \\    if (!parts) return false;
    \\    var scheme = location.protocol.slice(0, -1);
    \\    if (parts[1] === '*' ? scheme !== 'http' && scheme !== 'https' : parts[1] !== scheme) return false;
    \\    var host = parts[2], port = '';
    \\    var colon = host.lastIndexOf(':');
    \\    if (colon > 0 && host.indexOf(']') < colon) { port = host.slice(colon + 1); host = host.slice(0, colon); }
    \\    if (port && port !== '*' && port !== location.port) return false;
    \\    var here = location.hostname;
    \\    if (host.indexOf('*.') === 0) {
    \\      var base = host.slice(2);
    \\      if (base.indexOf('.') < 0) return false;
    \\      if (here !== base && here.slice(-base.length - 1) !== '.' + base) return false;
    \\    } else if (host !== here) return false;
    \\    return glob(parts[3]).test(location.pathname + location.search);
    \\  };
    \\  if (!patterns.some(listed)) return;
    \\  var chromeRuntime = {
    \\    sendMessage: function (id, message, options, callback) {
    \\      if (typeof options === 'function') { callback = options; options = undefined; }
    \\      var sent = options === undefined ? runtime.sendMessage(id, message) : runtime.sendMessage(id, message, options);
    \\      if (typeof callback !== 'function') return sent;
    \\      Promise.resolve(sent).then(function (reply) { callback(reply); }, function (error) {
    \\        chromeRuntime.lastError = { message: String(error && error.message || error) };
    \\        try { callback(); } finally { delete chromeRuntime.lastError; }
    \\      });
    \\    }
    \\  };
    \\  if (typeof runtime.connect === 'function') {
    \\    chromeRuntime.connect = function () { return runtime.connect.apply(runtime, arguments); };
    \\  }
    \\  try {
    \\    Object.defineProperty(window, 'chrome', {
    \\      value: { runtime: chromeRuntime }, configurable: true, writable: true, enumerable: false
    \\    });
    \\  } catch (e) {}
    \\})(
;

test "external patterns Chrome would take" {
    try std.testing.expect(allowed("https://claude.ai/*"));
    try std.testing.expect(allowed("*://*.example.com:8080/x/*"));
    try std.testing.expect(allowed("http://[::1]/*"));
    try std.testing.expect(!allowed("*://*/*"));
    try std.testing.expect(!allowed("https://*.com/*"));
    try std.testing.expect(!allowed("https://a*b.com/*"));
    try std.testing.expect(!allowed("ftp://a.com/*"));
    try std.testing.expect(!allowed("https://a.com"));
    try std.testing.expect(!allowed("https://accounts.google.com/*"));
    try std.testing.expect(allowed("https://google/*"));
}
