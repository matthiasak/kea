//! Favicons' pure rules (Icons.swift `site`, `media`, `rank`) and the decode.
const std = @import("std");
const objc = @import("nanoui").objc;
const f = @import("favicons.zig");
const t = std.testing;

test "site keeps a port the scheme doesn't have anyway" {
    var buf: [300]u8 = undefined;
    try t.expectEqualStrings("localhost:3000", f.site(&buf, "http://LocalHost:3000/x").?);
    try t.expectEqualStrings("example.com", f.site(&buf, "https://example.com:443/").?);
    try t.expectEqualStrings("example.com", f.site(&buf, "http://Example.com:80").?);
    try t.expectEqualStrings("example.com:443", f.site(&buf, "http://example.com:443").?);
    try t.expect(f.site(&buf, "about:blank") == null);
}

test "media reads prefers-color-scheme" {
    try t.expectEqual(f.Scheme.dark, f.media("(prefers-color-scheme: dark)"));
    try t.expectEqual(f.Scheme.light, f.media("(Prefers-Color-Scheme: Light)"));
    try t.expectEqual(f.Scheme.any, f.media("screen and (min-width: 9px)"));
    try t.expectEqual(f.Scheme.any, f.media("dark"));
    try t.expectEqual(f.Scheme.any, f.media(""));
}

const declared = [_]f.Declared{
    .{ .href = "https://a.test/small.png", .rel = "icon", .sizes = "16x16" },
    .{ .href = "https://a.test/touch.png", .rel = "apple-touch-icon" },
    .{ .href = "https://a.test/32.png", .rel = "icon", .sizes = "16x16 32x32" },
    .{ .href = "https://a.test/dark.png", .rel = "icon", .media = "(prefers-color-scheme: dark)" },
    .{ .href = "https://a.test/light.svg", .rel = "icon", .media = "(prefers-color-scheme: light)" },
    .{ .href = "https://a.test/favicon.ico", .rel = "shortcut icon" },
    .{ .href = "javascript:alert(1)", .rel = "icon" },
    .{ .href = "data:image/png;base64,AAAA", .rel = "icon", .sizes = "64x64" },
};

fn expectRank(dark: bool, page: []const u8, want: []const []const u8) !void {
    const got = try f.rank(t.allocator, &declared, page, dark);
    defer f.freeList(t.allocator, got);
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "rank puts this scheme first, drops the other, ends at the root once" {
    // Light: the light svg (35+40), 64 px (50), 32 px (45), touch (40),
    // plain (25, the root itself), 16 px (10); the dark one never.
    try expectRank(false, "https://a.test/page?q=1#x", &.{
        "https://a.test/light.svg",   "data:image/png;base64,AAAA", "https://a.test/32.png",
        "https://a.test/touch.png",   "https://a.test/favicon.ico", "https://a.test/small.png",
    });
    // Dark, on another port: the dark one first, the light one never, and
    // the root with its port at the end.
    try expectRank(true, "https://a.test:8443/", &.{
        "https://a.test/dark.png",    "data:image/png;base64,AAAA", "https://a.test/32.png",
        "https://a.test/touch.png",   "https://a.test/favicon.ico", "https://a.test/small.png",
        "https://a.test:8443/favicon.ico",
    });
}

fn pngSide(png: []const u8) u32 {
    return std.mem.readInt(u32, png[16..20], .big);
}

test "square fits an icon into 64 pt and refuses other kinds" {
    const icon = @embedFile("../tests/fixtures/icon.png");
    const png = f.square(t.allocator, icon) orelse return error.NotDecoded;
    defer t.allocator.free(png);
    try t.expectEqualSlices(u8, "\x89PNG", png[0..4]);
    try t.expectEqual(@as(u32, 128), pngSide(png));
    try t.expectEqual(@as(u32, 128), std.mem.readInt(u32, png[20..24], .big));

    // The same picture as a TIFF: a kind a site's icon may not be.
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ icon.ptr, @as(objc.NSUInteger, icon.len) });
    const rep = objc.msg(objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{data});
    const tiff = objc.msg(objc.Object, rep, "TIFFRepresentation", .{});
    const n = objc.msg(objc.NSUInteger, tiff, "length", .{});
    try t.expect(n > 60);
    try t.expect(f.square(t.allocator, objc.msg([*]const u8, tiff, "bytes", .{})[0..n]) == null);
    try t.expect(f.square(t.allocator, "not a picture at all") == null);
}
