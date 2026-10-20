//! `ProgressView().controlSize(.small)`: the system's spinner itself. A
//! small `NSProgressIndicator` in a window never shown draws its 24 frames
//! (one CoreUI strip) once per appearance; they play as pictures, one turn
//! every 0.8 s, as the indicator's own discrete animation does. Without an
//! app to make a window (a headless test), Kea's ring stands in.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const objc = nanoui.objc;
const cg = @import("../sys/cg.zig");
const ring = @import("ring.zig");

const frames = 24;
const turn_seconds: f64 = 0.8;
const side: f32 = 16;

const Strip = struct { pngs: [frames][]u8, scale: f32 };

/// Per appearance (light, dark), for the life of the app (main thread).
var strips: [2]?Strip = .{ null, null };
var tried: [2]bool = .{ false, false };

extern var NSApp: ?objc.Object;
extern "c" fn CGImageCreateWithImageInRect(image: cg.Image, rect: objc.CGRect) ?cg.Image;
extern "c" fn CFGetTypeID(cf: *anyopaque) usize;
extern "c" fn CGImageGetTypeID() usize;

pub fn spinner(c: *ui.Context) void {
    const dark = c.theme.dark;
    const s = strip(dark) orelse return ring.ring(c, side);
    const f = c.time / turn_seconds;
    const i: usize = @as(usize, @intFromFloat(@floor((f - @floor(f)) * frames))) % frames;
    _ = ui.image(c, .{ .key = c.print("kea.spinner.{d}.{d}", .{ @intFromBool(dark), i }), .bytes = s.pngs[i], .max_width = side, .max_height = side, .radius = 0, .scale = s.scale });
    c.frameIn(@floatCast(turn_seconds / frames));
}

fn strip(dark: bool) ?*const Strip {
    const k = @intFromBool(dark);
    if (strips[k]) |*s| return s;
    if (tried[k] or NSApp == null) return null;
    tried[k] = true;
    strips[k] = take(dark) orelse return null;
    return &strips[k].?;
}

fn take(dark: bool) ?Strip {
    const pool = objc.Pool.push();
    defer pool.pop();
    const window = objc.msg(?objc.Object, objc.alloc("NSWindow"), "initWithContentRect:styleMask:backing:defer:", .{
        objc.CGRect{ .origin = .{ .x = -20000, .y = -20000 }, .size = .{ .width = 32, .height = 32 } }, @as(objc.NSUInteger, 0), @as(objc.NSUInteger, 2), objc.NO,
    }) orelse return null;
    defer objc.release(window);
    objc.msg(void, window, "setReleasedWhenClosed:", .{objc.NO});
    const content = objc.msg(objc.Object, window, "contentView", .{});
    objc.msg(void, content, "setWantsLayer:", .{objc.YES});
    const p = objc.msg(objc.Object, objc.alloc("NSProgressIndicator"), "initWithFrame:", .{objc.CGRect{ .size = .{ .width = side, .height = side } }});
    defer objc.release(p);
    objc.msg(void, p, "setStyle:", .{@as(objc.NSUInteger, 1)}); // .spinning
    objc.msg(void, p, "setControlSize:", .{@as(objc.NSUInteger, 1)}); // .small
    objc.msg(void, p, "setIndeterminate:", .{objc.YES});
    const name = objc.nsString(if (dark) "NSAppearanceNameDarkAqua" else "NSAppearanceNameAqua");
    objc.msg(void, p, "setAppearance:", .{objc.msg(?objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{name})});
    objc.msg(void, content, "addSubview:", .{p});
    objc.msg(void, p, "startAnimation:", .{@as(?objc.Object, null)});
    objc.msg(void, window, "displayIfNeeded", .{});
    objc.msg(void, objc.class("CATransaction"), "flush", .{});
    defer {
        objc.msg(void, p, "stopAnimation:", .{@as(?objc.Object, null)});
        objc.msg(void, p, "removeFromSuperview", .{});
    }
    // The strip is the contents of the indicator's one sublayer.
    const layer = objc.msg(?objc.Object, p, "layer", .{}) orelse return null;
    const subs = objc.msg(?objc.Object, layer, "sublayers", .{}) orelse return null;
    const first = objc.msg(?objc.Object, subs, "firstObject", .{}) orelse return null;
    // CoreUI's layer, not ours: only a CGImage is read; anything else (an
    // IOSurface, a backing store, a change in a later macOS) is the ring.
    const contents = objc.msg(?*anyopaque, first, "contents", .{}) orelse return null;
    if (CFGetTypeID(contents) != CGImageGetTypeID()) return null;
    const sheet: cg.Image = @ptrCast(contents);
    const w = cg.CGImageGetWidth(sheet);
    const h = cg.CGImageGetHeight(sheet);
    if (w < frames or w % frames != 0 or h == 0) return null;
    const each = w / frames;
    var out: Strip = .{ .pngs = undefined, .scale = @as(f32, @floatFromInt(each)) / side };
    for (0..frames) |i| {
        const rect: objc.CGRect = .{ .origin = .{ .x = @floatFromInt(i * each) }, .size = .{ .width = @floatFromInt(each), .height = @floatFromInt(h) } };
        const one = CGImageCreateWithImageInRect(sheet, rect) orelse return free(&out, i);
        defer cg.CGImageRelease(one);
        out.pngs[i] = png(one) orelse return free(&out, i);
    }
    return out;
}

fn free(s: *Strip, made: usize) ?Strip {
    for (s.pngs[0..made]) |b| std.heap.c_allocator.free(b);
    return null;
}

fn png(image: cg.Image) ?[]u8 {
    const data = cg.CFDataCreateMutable(null, 0) orelse return null;
    defer cg.CFRelease(data);
    const dest = cg.CGImageDestinationCreateWithData(data, @ptrCast(objc.nsString("public.png")), 1, null) orelse return null;
    defer cg.CFRelease(dest);
    cg.CGImageDestinationAddImage(dest, image, null);
    if (!cg.CGImageDestinationFinalize(dest)) return null;
    return std.heap.c_allocator.dupe(u8, cg.CFDataGetBytePtr(data)[0..@intCast(cg.CFDataGetLength(data))]) catch null;
}

test "the system spinner's 24 frames come from AppKit" {
    _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const s = strip(false) orelse return error.NotTaken;
    try std.testing.expect(s.scale >= 1);
    for (s.pngs) |b| try std.testing.expectEqualStrings("\x89PNG", b[0..4]);
    // Each frame differs from the next: the spokes go round.
    try std.testing.expect(!std.mem.eql(u8, s.pngs[0], s.pngs[3]));
}
