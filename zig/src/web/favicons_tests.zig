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

const cg = @import("../sys/cg.zig");

fn solidPng(gpa: std.mem.Allocator, w: f32, h: f32, r: u8, g: u8, b: u8) ![]u8 {
    const bmp = try cg.Bitmap.init(gpa, w, h, 1);
    defer bmp.deinit(gpa);
    bmp.fill(.{
        .r = @as(f32, @floatFromInt(r)) / 255.0,
        .g = @as(f32, @floatFromInt(g)) / 255.0,
        .b = @as(f32, @floatFromInt(b)) / 255.0,
        .a = 1,
    });
    const path = cg.CGPathCreateWithRoundedRect(.{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = w, .height = h } }, 0, 0, null).?;
    defer cg.CGPathRelease(path);
    cg.CGContextAddPath(bmp.ctx, path);
    cg.CGContextFillPath(bmp.ctx);
    return bmp.png(gpa);
}

fn decodeBgra(gpa: std.mem.Allocator, png: []const u8) !struct { w: usize, h: usize, px: []u8 } {
    const data = cg.CFDataCreate(null, png.ptr, @intCast(png.len)).?;
    defer cg.CFRelease(data);
    const src = cg.CGImageSourceCreateWithData(data, null).?;
    defer cg.CFRelease(src);
    const img = cg.CGImageSourceCreateImageAtIndex(src, 0, null).?;
    defer cg.CGImageRelease(img);
    const w = cg.CGImageGetWidth(img);
    const h = cg.CGImageGetHeight(img);
    const px = try gpa.alloc(u8, w * h * 4);
    @memset(px, 0);
    const space = cg.CGColorSpaceCreateWithName(cg.kCGColorSpaceSRGB).?;
    defer cg.CGColorSpaceRelease(space);
    const ctx = cg.CGBitmapContextCreate(px.ptr, w, h, 8, w * 4, space, cg.bgra_premultiplied).?;
    defer cg.CGContextRelease(ctx);
    cg.CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{ .w = w, .h = h, .px = px };
}

fn expectNear(got: u8, want: u8) !void {
    const diff = if (got > want) got - want else want - got;
    try t.expect(diff <= 1);
}

test "square decodes 16px, 48px, multi-frame ico, 32x16 letterbox and SVG into 128x128" {
    _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    // 16 px solid colour
    const p16 = try solidPng(t.allocator, 16, 16, 30, 140, 220);
    defer t.allocator.free(p16);
    const sq16 = f.square(t.allocator, p16) orelse return error.NotDecoded;
    defer t.allocator.free(sq16);
    const d16 = try decodeBgra(t.allocator, sq16);
    defer t.allocator.free(d16.px);
    try t.expectEqual(@as(usize, 128), d16.w);
    try t.expectEqual(@as(usize, 128), d16.h);
    const mid = (64 * 128 + 64) * 4;
    try expectNear(d16.px[mid + 2], 30);
    try expectNear(d16.px[mid + 1], 140);
    try expectNear(d16.px[mid + 0], 220);
    try t.expectEqual(@as(u8, 255), d16.px[mid + 3]);

    // 48 px solid colour
    const p48 = try solidPng(t.allocator, 48, 48, 200, 60, 80);
    defer t.allocator.free(p48);
    const sq48 = f.square(t.allocator, p48) orelse return error.NotDecoded;
    defer t.allocator.free(sq48);
    try t.expectEqual(@as(u32, 128), pngSide(sq48));

    // Multi-frame .ico (16x16 blue + 64x64 green: picks 64x64)
    const p64 = try solidPng(t.allocator, 64, 64, 20, 190, 70);
    defer t.allocator.free(p64);
    var ico: std.ArrayList(u8) = .empty;
    defer ico.deinit(t.allocator);
    try ico.appendSlice(t.allocator, &.{ 0, 0, 1, 0, 2, 0 });
    const off0: u32 = 6 + 32;
    const off1: u32 = off0 + @as(u32, @intCast(p16.len));
    var e0: [16]u8 = .{ 16, 16, 0, 0, 1, 0, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, e0[8..12], @intCast(p16.len), .little);
    std.mem.writeInt(u32, e0[12..16], off0, .little);
    var e1: [16]u8 = .{ 64, 64, 0, 0, 1, 0, 32, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, e1[8..12], @intCast(p64.len), .little);
    std.mem.writeInt(u32, e1[12..16], off1, .little);
    try ico.appendSlice(t.allocator, &e0);
    try ico.appendSlice(t.allocator, &e1);
    try ico.appendSlice(t.allocator, p16);
    try ico.appendSlice(t.allocator, p64);
    const sq_ico = f.square(t.allocator, ico.items) orelse return error.NotDecoded;
    defer t.allocator.free(sq_ico);
    const d_ico = try decodeBgra(t.allocator, sq_ico);
    defer t.allocator.free(d_ico.px);
    try t.expectEqual(@as(usize, 128), d_ico.w);
    try expectNear(d_ico.px[mid + 2], 20);
    try expectNear(d_ico.px[mid + 1], 190);
    try expectNear(d_ico.px[mid + 0], 70);

    // 32x16 wide: letterboxed top/bottom alpha 0, centre colour preserved
    const p32x16 = try solidPng(t.allocator, 32, 16, 210, 110, 40);
    defer t.allocator.free(p32x16);
    const sq_wide = f.square(t.allocator, p32x16) orelse return error.NotDecoded;
    defer t.allocator.free(sq_wide);
    const d_wide = try decodeBgra(t.allocator, sq_wide);
    defer t.allocator.free(d_wide.px);
    try t.expectEqual(@as(usize, 128), d_wide.w);
    try t.expectEqual(@as(u8, 0), d_wide.px[(4 * 128 + 64) * 4 + 3]);
    try t.expectEqual(@as(u8, 0), d_wide.px[(123 * 128 + 64) * 4 + 3]);
    try expectNear(d_wide.px[mid + 2], 210);
    try expectNear(d_wide.px[mid + 1], 110);
    try expectNear(d_wide.px[mid + 0], 40);

    // SVG fixture
    const svg =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64">
        \\  <rect width="64" height="64" fill="#ff0000"/>
        \\</svg>
    ;
    const sq_svg = f.square(t.allocator, svg) orelse return error.NotDecoded;
    defer t.allocator.free(sq_svg);
    const d_svg = try decodeBgra(t.allocator, sq_svg);
    defer t.allocator.free(d_svg.px);
    try t.expectEqual(@as(usize, 128), d_svg.w);
    try t.expectEqual(@as(usize, 128), d_svg.h);
    try expectNear(d_svg.px[mid + 2], 255);
    try expectNear(d_svg.px[mid + 1], 0);
    try expectNear(d_svg.px[mid + 0], 0);
}

test "setDark flips cached and clears missing" {
    const ca = std.heap.c_allocator;
    var favs = try ca.create(f.Favicons);
    favs.* = .{ .kea = null, .folder = try ca.dupe(u8, "/tmp/kea-favs-test-nonexistent") };
    defer favs.deinit();
    const light_png = try solidPng(ca, 16, 16, 10, 20, 30);
    const dark_png = try solidPng(ca, 16, 16, 230, 240, 250);
    _ = favs.remember("example.com", light_png);
    _ = favs.remember("example.com@dark", dark_png);
    favs.setDark(false);
    try t.expectEqualSlices(u8, light_png, favs.cached("example.com").?.png);

    try favs.missing.put(ca, try ca.dupe(u8, "missing.test"), {});
    favs.setDark(true);
    try t.expectEqual(@as(usize, 0), favs.missing.count());
    try t.expectEqualSlices(u8, dark_png, favs.cached("example.com").?.png);

    try favs.missing.put(ca, try ca.dupe(u8, "missing2.test"), {});
    favs.setDark(false);
    try t.expectEqual(@as(usize, 0), favs.missing.count());
    try t.expectEqualSlices(u8, light_png, favs.cached("example.com").?.png);
}

test "analyzeMono tints alpha silhouettes and leaves opaque two-tone icons untinted" {
    const decode = @import("favicons_decode.zig");
    // Opaque black square with a white mark inside (like x.com@dark): must stay .none.
    const two_tone = blk: {
        const bmp = try cg.Bitmap.init(t.allocator, 64, 64, 1);
        defer bmp.deinit(t.allocator);
        bmp.fill(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
        const bg = cg.CGPathCreateWithRoundedRect(.{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 64, .height = 64 } }, 0, 0, null).?;
        defer cg.CGPathRelease(bg);
        cg.CGContextAddPath(bmp.ctx, bg);
        cg.CGContextFillPath(bmp.ctx);
        bmp.fill(.{ .r = 1, .g = 1, .b = 1, .a = 1 });
        const fg = cg.CGPathCreateWithRoundedRect(.{ .origin = .{ .x = 24, .y = 24 }, .size = .{ .width = 16, .height = 16 } }, 0, 0, null).?;
        defer cg.CGPathRelease(fg);
        cg.CGContextAddPath(bmp.ctx, fg);
        cg.CGContextFillPath(bmp.ctx);
        break :blk try bmp.png(t.allocator);
    };
    defer t.allocator.free(two_tone);
    try t.expectEqual(f.Mono.none, decode.analyzeMono(two_tone));

    // Black silhouette on a transparent canvas: .dark.
    const dark_sil = blk: {
        const bmp = try cg.Bitmap.init(t.allocator, 64, 64, 1);
        defer bmp.deinit(t.allocator);
        bmp.fill(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
        const fg = cg.CGPathCreateWithRoundedRect(.{ .origin = .{ .x = 12, .y = 12 }, .size = .{ .width = 40, .height = 40 } }, 0, 0, null).?;
        defer cg.CGPathRelease(fg);
        cg.CGContextAddPath(bmp.ctx, fg);
        cg.CGContextFillPath(bmp.ctx);
        break :blk try bmp.png(t.allocator);
    };
    defer t.allocator.free(dark_sil);
    try t.expectEqual(f.Mono.dark, decode.analyzeMono(dark_sil));
}
