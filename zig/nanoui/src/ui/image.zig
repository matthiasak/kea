//! Writes rendered frames to PNG files with ImageIO.
const std = @import("std");
const cf = @import("cf.zig");
const metal = @import("metal.zig");

const CGImageRef = *opaque {};
const CFURLRef = *opaque {};
const CGImageDestinationRef = *opaque {};
extern "c" fn CGBitmapContextCreateImage(ctx: cf.CGContextRef) ?CGImageRef;
extern "c" fn CGImageRelease(img: CGImageRef) void;
extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, path: [*]const u8, len: cf.CFIndex, is_dir: bool) ?CFURLRef;
extern "c" fn CGImageDestinationCreateWithURL(url: CFURLRef, kind: cf.CFStringRef, count: usize, options: ?*anyopaque) ?CGImageDestinationRef;
extern "c" fn CGImageDestinationAddImage(dest: CGImageDestinationRef, img: CGImageRef, props: ?*anyopaque) void;
extern "c" fn CGImageDestinationFinalize(dest: CGImageDestinationRef) bool;

/// Premultiplied BGRA, little endian: `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`.
const bgra_premultiplied: u32 = 2 | (2 << 12);

pub fn writePng(path: []const u8, pixels: metal.Pixels) !void {
    const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(pixels.bytes.ptr, pixels.width, pixels.height, 8, pixels.width * 4, space, bgra_premultiplied) orelse
        return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    const img = CGBitmapContextCreateImage(ctx) orelse return error.Image;
    defer CGImageRelease(img);
    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse return error.Url;
    defer cf.CFRelease(url);
    const kind = cf.string("public.png");
    defer cf.CFRelease(kind);
    const dest = CGImageDestinationCreateWithURL(url, kind, 1, null) orelse return error.Destination;
    defer cf.CFRelease(dest);
    CGImageDestinationAddImage(dest, img, null);
    if (!CGImageDestinationFinalize(dest)) return error.WriteFailed;
}

const CFDataRef = *opaque {};
const CGImageSourceRef = *opaque {};
extern "c" fn CFDataCreate(alloc: ?*anyopaque, bytes: [*]const u8, len: cf.CFIndex) ?CFDataRef;
extern "c" fn CGImageSourceCreateWithData(data: CFDataRef, options: ?*anyopaque) ?CGImageSourceRef;
extern "c" fn CGImageSourceCreateImageAtIndex(src: CGImageSourceRef, index: usize, options: ?*anyopaque) ?CGImageRef;
extern "c" fn CGImageGetWidth(img: CGImageRef) usize;
extern "c" fn CGImageGetHeight(img: CGImageRef) usize;
extern "c" fn CGContextDrawImage(ctx: cf.CGContextRef, rect: @import("../objc.zig").CGRect, image: CGImageRef) void;

pub const Decoded = struct { width: u32, height: u32, bgra: []u8 };

/// Any image ImageIO reads (PNG, JPEG, GIF, HEIC, …) as premultiplied BGRA.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.Data;
    defer cf.CFRelease(data);
    const src = CGImageSourceCreateWithData(data, null) orelse return error.NotImage;
    defer cf.CFRelease(src);
    const img = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.NotImage;
    defer CGImageRelease(img);
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    if (w == 0 or h == 0 or w * h > 64 * 1024 * 1024) return error.TooLarge;
    const out = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(out.ptr, w, h, 8, w * 4, space, bgra_premultiplied) orelse return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{ .width = @intCast(w), .height = @intCast(h), .bgra = out };
}

extern "c" fn CGImageSourceCreateThumbnailAtIndex(src: CGImageSourceRef, index: usize, options: ?*anyopaque) ?CGImageRef;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(src: CGImageSourceRef, index: usize, options: ?*anyopaque) ?*anyopaque;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;
extern "c" fn CFNumberGetValue(n: *anyopaque, kind: c_int, out: *anyopaque) bool;
extern "c" fn CFNumberCreate(alloc: ?*anyopaque, kind: c_int, value: *const anyopaque) ?*anyopaque;
extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: cf.CFStringRef;
extern "c" const kCGImageSourceThumbnailMaxPixelSize: cf.CFStringRef;
extern "c" const kCGImageSourceCreateThumbnailWithTransform: cf.CFStringRef;
extern "c" const kCGImagePropertyPixelWidth: cf.CFStringRef;
extern "c" const kCGImagePropertyPixelHeight: cf.CFStringRef;

pub const Fitted = struct { width: u32, height: u32, w: u32, h: u32, bgra: []u8 };

/// A picture decoded straight to at most `max_side` pixels (ImageIO scales
/// while it decodes: no full-size copy is made), with its own size.
pub fn decodeFit(gpa: std.mem.Allocator, bytes: []const u8, max_side: u32) !Fitted {
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.Data;
    defer cf.CFRelease(data);
    const src = CGImageSourceCreateWithData(data, null) orelse return error.NotImage;
    defer cf.CFRelease(src);
    // Its own size, from its header.
    var width: i32 = 0;
    var height: i32 = 0;
    if (CGImageSourceCopyPropertiesAtIndex(src, 0, null)) |props| {
        defer cf.CFRelease(props);
        if (CFDictionaryGetValue(props, kCGImagePropertyPixelWidth)) |n| _ = CFNumberGetValue(n, 3, &width);
        if (CFDictionaryGetValue(props, kCGImagePropertyPixelHeight)) |n| _ = CFNumberGetValue(n, 3, &height);
    }
    const side: i32 = @intCast(max_side);
    const max_n = CFNumberCreate(null, 3, &side) orelse return error.Data;
    defer cf.CFRelease(max_n);
    const keys = [_]?*const anyopaque{ kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceThumbnailMaxPixelSize, kCGImageSourceCreateThumbnailWithTransform };
    const values = [_]?*const anyopaque{ cf.kCFBooleanTrue, max_n, cf.kCFBooleanTrue };
    const opts = cf.CFDictionaryCreate(null, &keys, &values, 3, &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse return error.Data;
    defer cf.CFRelease(opts);
    const img = CGImageSourceCreateThumbnailAtIndex(src, 0, @ptrCast(@constCast(opts))) orelse return error.NotImage;
    defer CGImageRelease(img);
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    if (w == 0 or h == 0) return error.NotImage;
    const out = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(out.ptr, w, h, 8, w * 4, space, bgra_premultiplied) orelse return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{
        .width = if (width > 0) @intCast(width) else @intCast(w),
        .height = if (height > 0) @intCast(height) else @intCast(h),
        .w = @intCast(w),
        .h = @intCast(h),
        .bgra = out,
    };
}
