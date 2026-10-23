//! The frame's textures on the GPU (`ui.texture`): a CVPixelBuffer wrapped
//! as a Metal texture without a copy (CVMetalTextureCache), or BGRA bytes
//! uploaded into a texture kept for its slot. A wrapped buffer is held
//! until the GPU is done with the frame that drew it.
const std = @import("std");
const objc = @import("../objc.zig");
const gpu = @import("gpu.zig");

const CVReturn = i32;
extern "c" fn CVMetalTextureCacheCreate(allocator: ?*anyopaque, attrs: ?*anyopaque, device: objc.Object, texture_attrs: ?*anyopaque, out: *?*anyopaque) CVReturn;
extern "c" fn CVMetalTextureCacheCreateTextureFromImage(allocator: ?*anyopaque, cache: *anyopaque, image: *anyopaque, attrs: ?*anyopaque, format: objc.NSUInteger, width: usize, height: usize, plane: usize, out: *?*anyopaque) CVReturn;
extern "c" fn CVMetalTextureGetTexture(texture: *anyopaque) ?objc.Object;
extern "c" fn CVMetalTextureCacheFlush(cache: *anyopaque, options: u64) void;
extern "c" fn CFRelease(obj: *anyopaque) void;

const bgra8: objc.NSUInteger = 80;

pub const Textures = struct {
    gpa: std.mem.Allocator,
    cache: ?*anyopaque = null,
    /// Textures for bytes, by slot, and their sizes.
    uploads: std.ArrayList(?objc.Object) = .empty,
    sizes: std.ArrayList([2]u32) = .empty,

    pub fn deinit(t: *Textures) void {
        for (t.uploads.items) |u| if (u) |o| objc.release(o);
        t.uploads.deinit(t.gpa);
        t.sizes.deinit(t.gpa);
        if (t.cache) |c| CFRelease(c);
    }

    /// The Metal texture for `tex` in `slot`; a wrapped pixel buffer joins
    /// `held`, to be released (`release`) once the frame is done.
    pub fn get(t: *Textures, device: objc.Object, tex: gpu.Texture, slot: usize, held: *std.ArrayList(*anyopaque)) ?objc.Object {
        if (tex.pixel_buffer) |pb| {
            if (t.cache == null) {
                var cache: ?*anyopaque = null;
                if (CVMetalTextureCacheCreate(null, null, device, null, &cache) != 0) return null;
                t.cache = cache;
            }
            var cv: ?*anyopaque = null;
            if (CVMetalTextureCacheCreateTextureFromImage(null, t.cache.?, pb, null, bgra8, tex.width, tex.height, 0, &cv) != 0) return null;
            held.append(t.gpa, cv.?) catch {
                CFRelease(cv.?);
                return null;
            };
            return CVMetalTextureGetTexture(cv.?);
        }
        if (tex.bgra.len == 0 or tex.width == 0 or tex.height == 0) return null;
        while (t.uploads.items.len <= slot) {
            t.uploads.append(t.gpa, null) catch return null;
            t.sizes.append(t.gpa, .{ 0, 0 }) catch return null;
        }
        if (t.uploads.items[slot] == null or t.sizes.items[slot][0] != tex.width or t.sizes.items[slot][1] != tex.height) {
            if (t.uploads.items[slot]) |o| objc.release(o);
            const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
                bgra8, @as(objc.NSUInteger, tex.width), @as(objc.NSUInteger, tex.height), objc.NO,
            });
            objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1)}); // shader read
            t.uploads.items[slot] = objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc});
            t.sizes.items[slot] = .{ tex.width, tex.height };
        }
        const o = t.uploads.items[slot] orelse return null;
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        const stride = if (tex.stride > 0) tex.stride else @as(usize, tex.width) * 4;
        objc.msg(void, o, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            Region{ .x = 0, .y = 0, .z = 0, .w = tex.width, .h = tex.height, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, tex.bgra.ptr), @as(objc.NSUInteger, stride),
        });
        return o;
    }

    /// Releases a done frame's wrapped buffers.
    pub fn release(t: *Textures, held: *std.ArrayList(*anyopaque)) void {
        for (held.items) |cv| CFRelease(cv);
        held.clearRetainingCapacity();
        if (t.cache) |c| CVMetalTextureCacheFlush(c, 0);
    }
};
