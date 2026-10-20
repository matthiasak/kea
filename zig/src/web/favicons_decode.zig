//! Decoding and pixel inspection for `Favicons` (`favicons.zig`):
//! rasterising allowed image formats and SVG into a 64 pt (128 px) sRGB
//! PNG square, validating cached PNG headers, and classifying monochrome
//! icons for dark/light tinting.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const cg = @import("../sys/cg.zig");

pub const Mono = @import("../chrome/mark.zig").Mono;

/// The kinds of picture a site's icon may be; anything else isn't opened.
pub const kinds = [_][]const u8{
    "public.png",
    "com.microsoft.ico",
    "public.jpeg",
    "com.compuserve.gif",
    "org.webmproject.webp",
    "com.microsoft.bmp",
    "image/svg+xml",
    "public.svg-image",
};

fn number(n: anytype) objc.Object {
    return switch (@TypeOf(n)) {
        bool => objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{n}),
        else => objc.msg(objc.Object, objc.class("NSNumber"), "numberWithInteger:", .{@as(objc.NSInteger, n)}),
    };
}

fn dict(keys: []const cg.CFStringRef, values: []const objc.Object) objc.Object {
    return objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ values.ptr, keys.ptr, keys.len });
}

fn intValue(props: objc.Object, key: cg.CFStringRef) usize {
    const v = objc.msg(?objc.Object, props, "objectForKey:", .{key}) orelse return 0;
    return @intCast(@max(0, objc.msg(objc.NSInteger, v, "integerValue", .{})));
}

/// True when `bytes` has a PNG signature and valid header dimensions.
pub fn validPng(bytes: []const u8) bool {
    if (!std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return false;
    return headerDimensions(bytes) != null;
}
pub fn headerDimensions(bytes: []const u8) ?struct { width: u32, height: u32 } {
    const data = cg.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return null;
    defer cg.CFRelease(data);
    const src = cg.CGImageSourceCreateWithData(data, null) orelse return null;
    defer cg.CFRelease(src);
    if (cg.CGImageSourceGetCount(src) == 0) return null;
    if (cg.CGImageSourceCopyPropertiesAtIndex(src, 0, null)) |props| {
        defer objc.release(props);
        const w = intValue(props, cg.kCGImagePropertyPixelWidth);
        const h = intValue(props, cg.kCGImagePropertyPixelHeight);
        if (w > 0 and h > 0 and w * h <= 64 * 1024 * 1024) return .{ .width = @intCast(w), .height = @intCast(h) };
    }
    const img = cg.CGImageSourceCreateImageAtIndex(src, 0, null) orelse return null;
    defer cg.CGImageRelease(img);
    const w = cg.CGImageGetWidth(img);
    const h = cg.CGImageGetHeight(img);
    if (w == 0 or h == 0 or w * h > 64 * 1024 * 1024) return null;
    return .{ .width = @intCast(w), .height = @intCast(h) };
}

fn isSvgBytes(bytes: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, bytes, " \t\r\n\xef\xbb\xbf");
    return std.ascii.startsWithIgnoreCase(trimmed, "<svg") or std.ascii.startsWithIgnoreCase(trimmed, "<?xml");
}

fn squareSvg(gpa: std.mem.Allocator, bytes: []const u8) ?[]u8 {
    const nsdata = objc.msg(?objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) }) orelse return null;
    const img = objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithData:", .{nsdata}) orelse return null;
    defer objc.release(img);
    const sz = objc.msg(objc.CGSize, img, "size", .{});
    if (sz.width <= 0 or sz.height <= 0 or sz.width > 4096 or sz.height > 4096) return null;
    const side: f64 = 64;
    const scale = @min(side / sz.width, side / sz.height);
    const w = sz.width * scale;
    const h = sz.height * scale;
    var proposed: objc.CGRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = w * 2, .height = h * 2 },
    };
    const cg_img = objc.msg(?cg.Image, img, "CGImageForProposedRect:context:hints:", .{ &proposed, @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const bitmap = cg.Bitmap.init(gpa, 64, 64, 2) catch return null;
    defer bitmap.deinit(gpa);
    cg.CGContextSetInterpolationQuality(bitmap.ctx, cg.interpolation_high);
    cg.CGContextDrawImage(bitmap.ctx, .{
        .origin = .{ .x = (side - w) / 2, .y = (side - h) / 2 },
        .size = .{ .width = w, .height = h },
    }, cg_img);
    return bitmap.png(gpa) catch null;
}

/// One of the allowed kinds, at most 4096 px a side, drawn into a 64 pt
/// square (128 px) as PNG bytes on `gpa`; the frame nearest 64 px from
/// above for an .ico of many. Any thread.
pub fn square(gpa: std.mem.Allocator, bytes: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (isSvgBytes(bytes)) return squareSvg(gpa, bytes);
    const data = cg.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return null;
    defer cg.CFRelease(data);
    const src = cg.CGImageSourceCreateWithData(data, dict(&.{cg.kCGImageSourceShouldCache}, &.{number(false)})) orelse return null;
    defer cg.CFRelease(src);
    const kind = objc.fromNSString(@ptrCast(@constCast(cg.CGImageSourceGetType(src) orelse return null)));
    for (kinds) |k| {
        if (std.mem.eql(u8, k, kind)) break;
    } else return null;
    var best: usize = 0;
    var best_side: usize = 0;
    for (0..@min(cg.CGImageSourceGetCount(src), 32)) |i| {
        const props = cg.CGImageSourceCopyPropertiesAtIndex(src, i, null) orelse continue;
        defer objc.release(props);
        const w = intValue(props, cg.kCGImagePropertyPixelWidth);
        const h = intValue(props, cg.kCGImagePropertyPixelHeight);
        if (w == 0 or h == 0 or w > 4096 or h > 4096) continue;
        const side = @max(w, h);
        if (best_side == 0 or (side >= 64 and (best_side < 64 or side < best_side)) or (best_side < 64 and side > best_side)) {
            best = i;
            best_side = side;
        }
    }
    if (best_side == 0) return null;
    const decoded = if (best_side <= 256)
        cg.CGImageSourceCreateImageAtIndex(src, best, null)
    else
        cg.CGImageSourceCreateThumbnailAtIndex(src, best, dict(
            &.{ cg.kCGImageSourceCreateThumbnailFromImageAlways, cg.kCGImageSourceThumbnailMaxPixelSize, cg.kCGImageSourceCreateThumbnailWithTransform },
            &.{ number(true), number(128), number(true) },
        ));
    const img = decoded orelse return null;
    defer cg.CGImageRelease(img);
    const w: f64 = @floatFromInt(cg.CGImageGetWidth(img));
    const h: f64 = @floatFromInt(cg.CGImageGetHeight(img));
    const side = 64;
    const bitmap = cg.Bitmap.init(gpa, side, side, 2) catch return null;
    defer bitmap.deinit(gpa);
    cg.CGContextSetInterpolationQuality(bitmap.ctx, cg.interpolation_high);
    const scale = @min(side / w, side / h);
    // Device-pixel sizing for each drawn mark happens in `Images.get`.
    cg.CGContextDrawImage(bitmap.ctx, .{
        .origin = .{ .x = (side - w * scale) / 2, .y = (side - h * scale) / 2 },
        .size = .{ .width = w * scale, .height = h * scale },
    }, img);
    return bitmap.png(gpa) catch null;
}

/// Computes opaque pixels' mean luminance and max chroma:
/// chroma < 0.08 -> `.dark` if luminance < 0.25, `.light` if luminance > 0.85.
pub fn analyzeMono(png: []const u8) Mono {
    const data = cg.CFDataCreate(null, png.ptr, @intCast(png.len)) orelse return .none;
    defer cg.CFRelease(data);
    const src = cg.CGImageSourceCreateWithData(data, null) orelse return .none;
    defer cg.CFRelease(src);
    const img = cg.CGImageSourceCreateImageAtIndex(src, 0, null) orelse return .none;
    defer cg.CGImageRelease(img);
    const w = cg.CGImageGetWidth(img);
    const h = cg.CGImageGetHeight(img);
    if (w == 0 or h == 0 or w > 512 or h > 512) return .none;
    const a = std.heap.c_allocator;
    const buf = a.alloc(u8, w * h * 4) catch return .none;
    defer a.free(buf);
    @memset(buf, 0);
    const space = cg.CGColorSpaceCreateWithName(cg.kCGColorSpaceSRGB) orelse return .none;
    defer cg.CGColorSpaceRelease(space);
    const ctx = cg.CGBitmapContextCreate(buf.ptr, w, h, 8, w * 4, space, cg.bgra_premultiplied) orelse return .none;
    defer cg.CGContextRelease(ctx);
    cg.CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    var sum_lum: f64 = 0;
    var max_chroma: f32 = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        const alpha = buf[i + 3];
        if (alpha < 128) continue;
        const af: f32 = @floatFromInt(alpha);
        const b = @min(1.0, @as(f32, @floatFromInt(buf[i])) / af);
        const g = @min(1.0, @as(f32, @floatFromInt(buf[i + 1])) / af);
        const r = @min(1.0, @as(f32, @floatFromInt(buf[i + 2])) / af);
        const hi = @max(r, @max(g, b));
        const lo = @min(r, @min(g, b));
        max_chroma = @max(max_chroma, hi - lo);
        sum_lum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
        count += 1;
    }
    if (count == 0 or max_chroma >= 0.08) return .none;
    const lum = sum_lum / @as(f64, @floatFromInt(count));
    if (lum < 0.25) return .dark;
    if (lum > 0.85) return .light;
    return .none;
}
