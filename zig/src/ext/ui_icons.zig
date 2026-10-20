//! Extension icons for the chrome (`ExtensionIcon`, the Settings row): an
//! `NSImage` WebKit hands over, drawn once into a PNG at twice its size and
//! kept until the buttons change (`actions_changed`, which a new icon bumps).
const std = @import("std");
const objc = @import("nanoui").objc;
const value = @import("value.zig");

const heap = std.heap.c_allocator;

var cache: std.StringHashMapUnmanaged([]u8) = .empty;
/// The generation before's pictures: a frame that drew one may still be
/// handing its bytes to the renderer when a click moves the generation.
var retired: std.ArrayList([]u8) = .empty;
/// The `actions_changed` (and controller) the cache was made for.
var made_for: [2]u64 = .{ 0, 0 };

fn clear() void {
    for (retired.items) |b| heap.free(b);
    retired.clearRetainingCapacity();
    var it = cache.iterator();
    while (it.next()) |e| {
        heap.free(e.key_ptr.*);
        retired.append(heap, e.value_ptr.*) catch heap.free(e.value_ptr.*);
    }
    cache.clearRetainingCapacity();
}

/// The picture of `image` at `side` points, PNG bytes the cache keeps
/// (valid until `generation` or `serial` moves); null when it can't be drawn.
/// `key` names it among the extension's pictures.
pub fn png(key: []const u8, image: objc.Object, side: f64, serial: u64, generation: u64) ?[]const u8 {
    if (made_for[0] != serial or made_for[1] != generation) {
        clear();
        made_for = .{ serial, generation };
    }
    if (cache.get(key)) |b| return b;
    const bytes = draw(image, side) orelse return null;
    const k = heap.dupe(u8, key) catch return null;
    cache.put(heap, k, bytes) catch {
        heap.free(k);
        heap.free(bytes);
        return null;
    };
    return bytes;
}

fn draw(image: objc.Object, side: f64) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const n: objc.NSInteger = @intFromFloat(side * 2);
    const rep = objc.msg(?objc.Object, objc.alloc("NSBitmapImageRep"), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null), n, n, @as(objc.NSInteger, 8), @as(objc.NSInteger, 4), objc.YES, objc.NO, objc.nsString("NSDeviceRGBColorSpace"), @as(objc.NSInteger, 0), @as(objc.NSInteger, 0),
    }) orelse return null;
    objc.autorelease(rep);
    const ctx_class = objc.class("NSGraphicsContext");
    objc.msg(void, ctx_class, "saveGraphicsState", .{});
    const ctx = objc.msg(objc.Object, ctx_class, "graphicsContextWithBitmapImageRep:", .{rep});
    // NSImageInterpolationHigh: `.interpolation(.high)`.
    objc.msg(void, ctx, "setImageInterpolation:", .{@as(objc.NSUInteger, 3)});
    objc.msg(void, ctx_class, "setCurrentContext:", .{ctx});
    const s: f64 = @floatFromInt(n);
    objc.msg(void, image, "drawInRect:", .{objc.CGRect{ .size = .{ .width = s, .height = s } }});
    objc.msg(void, ctx_class, "restoreGraphicsState", .{});
    // NSBitmapImageFileTypePNG
    const out = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) }) orelse return null;
    return heap.dupe(u8, value.bytes(out)) catch null;
}
