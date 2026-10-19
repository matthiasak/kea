//! The default search engine (`Engine.swift`), stored by its raw name in
//! `search.engine`; `custom` takes the template in `search.custom`.
const std = @import("std");
const url_mod = @import("../data/url.zig");
const Parts = url_mod.Parts;

pub const Engine = enum {
    google,
    duckduckgo,
    bing,
    ecosia,
    startpage,
    kagi,
    brave,
    qwant,
    custom,

    pub const standard: Engine = .google;

    pub fn title(self: Engine) []const u8 {
        return switch (self) {
            .google => "Google",
            .duckduckgo => "DuckDuckGo",
            .bing => "Bing",
            .ecosia => "Ecosia",
            .startpage => "Startpage",
            .kagi => "Kagi",
            .brave => "Brave Search",
            .qwant => "Qwant",
            .custom => "Custom",
        };
    }

    /// A slice of `custom` (trimmed) or a constant.
    pub fn template(self: Engine, custom: []const u8) []const u8 {
        return switch (self) {
            .google => "https://www.google.com/search?q=%s",
            .duckduckgo => "https://duckduckgo.com/?q=%s",
            .bing => "https://www.bing.com/search?q=%s",
            .ecosia => "https://www.ecosia.org/search?q=%s",
            .startpage => "https://www.startpage.com/sp/search?query=%s",
            .kagi => "https://kagi.com/search?q=%s",
            .brave => "https://search.brave.com/search?q=%s",
            .qwant => "https://www.qwant.com/?q=%s",
            .custom => blk: {
                const trimmed = trim(custom);
                break :blk if (accepts(trimmed)) trimmed else standard.template("");
            },
        };
    }

    /// On `gpa`.
    pub fn name(self: Engine, gpa: std.mem.Allocator, custom: []const u8) ![]u8 {
        if (self != .custom) return gpa.dupe(u8, self.title());
        return try bareHost(gpa, custom) orelse gpa.dupe(u8, standard.title());
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
}

pub fn accepts(template: []const u8) bool {
    return rawHost(template) != null;
}

/// A template's host, lowercased, with any leading "www." dropped; on `gpa`.
pub fn bareHost(gpa: std.mem.Allocator, template: []const u8) !?[]u8 {
    const host = try url_mod.lower(gpa, rawHost(template) orelse return null);
    if (!std.mem.startsWith(u8, host, "www.")) return host;
    defer gpa.free(host);
    return try gpa.dupe(u8, host[4..]);
}

/// Swift's `host(of:)` before lowercasing. Swift parses the template twice,
/// %s as "a" and as "b", and wants one host: %s outside the host. Foundation
/// can't read "%s" itself; this parser can, and "%s" holds no delimiter.
fn rawHost(template: []const u8) ?[]const u8 {
    const trimmed = trim(template);
    if (std.mem.indexOf(u8, trimmed, "%s") == null) return null;
    const p = Parts.parse(trimmed) orelse return null;
    if (!p.isWeb()) return null;
    const host = p.hostName() orelse return null;
    if (std.mem.indexOf(u8, host, "%s") != null) return null;
    return host;
}

const mark = "SEARCHWORDSGOHERE";

/// The words, percent-encoded, put where `template` says; on `gpa`.
pub fn url(gpa: std.mem.Allocator, text: []const u8, template: []const u8) !?[]u8 {
    const words = trim(text);
    if (words.len == 0) return null;
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(gpa);
    for (words) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~')
            try escaped.append(gpa, ch)
        else
            try escaped.print(gpa, "%{X:0>2}", .{ch});
    }
    const raw = try std.mem.replaceOwned(u8, gpa, template, "%s", mark);
    defer gpa.free(raw);
    if (Parts.parse(raw) == null) return null;
    const base = try url_mod.encoded(gpa, raw);
    defer gpa.free(base);
    const out = try std.mem.replaceOwned(u8, gpa, base, mark, escaped.items);
    if (Parts.parse(out) == null) {
        gpa.free(out);
        return null;
    }
    return out;
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Engine);
}

test "engine templates, hosts and search urls" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("https://kagi.com/search?q=%s", Engine.kagi.template(""));
    try std.testing.expectEqualStrings("https://www.google.com/search?q=%s", Engine.custom.template("https://%s.example.com/"));
    try std.testing.expectEqualStrings("https://x.dev/?q=%s", Engine.custom.template(" https://x.dev/?q=%s "));
    try std.testing.expect(!accepts("ftp://x.com/?q=%s"));
    try std.testing.expect(!accepts("https://x.com/"));
    const n = try Engine.custom.name(gpa, "https://WWW.Search.Example/?q=%s");
    defer gpa.free(n);
    try std.testing.expectEqualStrings("search.example", n);
    const g = try Engine.bing.name(gpa, "");
    defer gpa.free(g);
    try std.testing.expectEqualStrings("Bing", g);
    const u = (try url(gpa, " cats & dogs ", Engine.duckduckgo.template(""))).?;
    defer gpa.free(u);
    try std.testing.expectEqualStrings("https://duckduckgo.com/?q=cats%20%26%20dogs", u);
    try std.testing.expect(try url(gpa, "  ", Engine.google.template("")) == null);
}
