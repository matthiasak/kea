//! Chrome extensions on WebKit (Extensions.swift): what every `ext/` file
//! shares — the macOS 15.4 gate, the extension scheme, the `installed.json`
//! row. The controller itself is `controller.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

/// `#available(macOS 15.4, *)`: WebKit's extension engine is there. When it
/// isn't, nothing extension-related exists — no controller, slot, menu or
/// Settings page — as in Swift.
pub fn available() bool {
    const S = struct {
        var known: ?bool = null;
    };
    if (S.known) |k| return k;
    S.known = objc_getClass("WKWebExtensionController") != null;
    return S.known.?;
}

/// `Extensions.scheme`: an extension's pages are served from
/// chrome-extension://<id>/, the address they have in Chrome.
pub const scheme = "chrome-extension";
/// `Extensions.formerScheme`: WebKit's own, which Kea used before.
pub const former_scheme = "webkit-extension";

/// `Extensions.current(_:)`: an address kept from the webkit-extension days,
/// read as the chrome-extension one. Returns `url` itself when unchanged,
/// else a copy on `gpa`.
pub fn current(gpa: std.mem.Allocator, url: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, url, former_scheme ++ ":")) return url;
    return std.mem.concat(gpa, u8, &.{ scheme, url[former_scheme.len..] });
}

/// The host of a chrome-extension:// (or webkit-extension://) address — the
/// extension's id — or null (`Browser.extensionID(of:)`, Browser.swift:3429).
pub fn idOf(url: []const u8) ?[]const u8 {
    inline for (.{ scheme, former_scheme }) |s| {
        if (std.mem.startsWith(u8, url, s ++ "://")) {
            const rest = url[s.len + 3 ..];
            const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
            return if (end == 0) null else rest[0..end];
        }
    }
    return null;
}

/// One installed extension, as `installed.json` keeps it (`Installed`,
/// Extensions.swift:22-48). Field names are Swift's property names.
pub const Installed = struct {
    /// The Chrome Web Store id, or for one loaded from a folder the id
    /// Chrome would give it ("local-…" in lists written before that).
    id: []const u8,
    name: []const u8,
    version: []const u8,
    enabled: bool,
    fromStore: bool,
    /// The permissions it was installed with.
    permissions: []const []const u8,
    /// Kept in the row beside the menu rather than only in it.
    pinned: ?bool = null,
    /// For one loaded from a folder: where that folder is (links resolved).
    source: ?[]const u8 = null,
};

test "current maps the former scheme" {
    const gpa = std.testing.allocator;
    const same = try current(gpa, "https://a.b/");
    try std.testing.expectEqualStrings("https://a.b/", same);
    const moved = try current(gpa, "webkit-extension://abc/popup.html");
    defer gpa.free(moved);
    try std.testing.expectEqualStrings("chrome-extension://abc/popup.html", moved);
    try std.testing.expectEqualStrings("abc", idOf("chrome-extension://abc/x").?);
    try std.testing.expect(idOf("https://abc/") == null);
}
