//! The kea in flight (`KeaArt.flight`, `KeaFlight`, KeaArt.swift): the
//! bundle's `kea.gif`, its frames read with ImageIO, each made PNG the
//! first time it shows and played from the clock at the GIF's own delays,
//! fitted into its box. Where there is no GIF (a test run has no bundle),
//! the app's icon instead, as Swift falls back to.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const cg = @import("../sys/cg.zig");

const Flight = struct {
    source: cg.Source,
    /// When each frame ends, from the start of a flight.
    ends: []f64,
    frames: []?[]u8,
};

var tried = false;
var flight: ?Flight = null;
var icon: ?[]u8 = null;
const gpa = std.heap.c_allocator;

/// The GIF, read once (`KeaArt.flight`); null without one.
fn load() ?*Flight {
    if (tried) return if (flight) |*f| f else null;
    tried = true;
    const pool = objc.Pool.push();
    defer pool.pop();
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    const url = objc.msg(?objc.Object, bundle, "URLForResource:withExtension:", .{ objc.nsString("kea"), objc.nsString("gif") }) orelse return null;
    flight = read(url) orelse return null;
    return &flight.?;
}

/// The GIF at `url`: its frames, none made PNG yet, and when each ends.
fn read(url: objc.Object) ?Flight {
    const source = cg.CGImageSourceCreateWithURL(url, null) orelse return null;
    const n = cg.CGImageSourceGetCount(source);
    if (n == 0) {
        cg.CFRelease(source);
        return null;
    }
    const ends = gpa.alloc(f64, n) catch return null;
    const frames = gpa.alloc(?[]u8, n) catch return null;
    @memset(frames, null);
    var at: f64 = 0;
    for (ends, 0..) |*e, i| {
        at += delay(source, i);
        e.* = at;
    }
    return .{ .source = source, .ends = ends, .frames = frames };
}

/// A frame's delay as AppKit plays it: under 11 ms reads as a tenth.
fn delay(source: cg.Source, i: usize) f64 {
    const props = cg.CGImageSourceCopyPropertiesAtIndex(source, i, null) orelse return 0.1;
    defer cg.CFRelease(@ptrCast(props));
    const gif = objc.msg(?objc.Object, props, "objectForKey:", .{@as(objc.Object, @ptrCast(@constCast(cg.kCGImagePropertyGIFDictionary)))}) orelse return 0.1;
    const v = objc.msg(?objc.Object, gif, "objectForKey:", .{@as(objc.Object, @ptrCast(@constCast(cg.kCGImagePropertyGIFDelayTime)))}) orelse return 0.1;
    const d = objc.msg(f64, v, "doubleValue", .{});
    return if (d < 0.011) 0.1 else d;
}

/// The PNG of `image`, on `gpa`.
fn png(image: cg.Image) ?[]u8 {
    const data = cg.CFDataCreateMutable(null, 0) orelse return null;
    defer cg.CFRelease(data);
    const dest = cg.CGImageDestinationCreateWithData(data, @ptrCast(objc.nsString("public.png")), 1, null) orelse return null;
    defer cg.CFRelease(dest);
    cg.CGImageDestinationAddImage(dest, image, null);
    if (!cg.CGImageDestinationFinalize(dest)) return null;
    return gpa.dupe(u8, cg.CFDataGetBytePtr(data)[0..@intCast(cg.CFDataGetLength(data))]) catch null;
}

fn frame(f: *Flight, i: usize) ?[]u8 {
    if (f.frames[i]) |bytes| return bytes;
    const pool = objc.Pool.push();
    defer pool.pop();
    const image = cg.CGImageSourceCreateImageAtIndex(f.source, i, null) orelse return null;
    defer cg.CGImageRelease(image);
    f.frames[i] = png(image);
    return f.frames[i];
}

/// The flight in a `w`×`h` box, fitted, its corners `radius`; false (and
/// nothing drawn) without a GIF.
pub fn view(c: *ui.Context, w: f32, h: f32, radius: f32) bool {
    const f = load() orelse return false;
    const total = f.ends[f.ends.len - 1];
    const t = @mod(c.time, total);
    var i: usize = 0;
    while (i + 1 < f.ends.len and t >= f.ends[i]) i += 1;
    const bytes = frame(f, i) orelse return false;
    ui.column(c, .{ .width = .{ .px = w }, .height = .{ .px = h }, .radius = radius, .clip = true, .align_items = .center, .justify = .center });
    defer ui.end(c);
    _ = ui.image(c, .{ .key = c.print("kea.flight.{d}", .{i}), .bytes = bytes, .max_width = w, .max_height = h, .radius = radius, .scale = 2 });
    c.frameIn(@floatCast(@max(0.001, f.ends[i] - t)));
    return true;
}

/// `NSApp.applicationIconImage` at `size` points.
pub fn appIcon(c: *ui.Context, size: f32) void {
    if (icon == null) icon = iconPng();
    const bytes = icon orelse return;
    _ = ui.image(c, .{ .key = "kea.app-icon", .bytes = bytes, .max_width = size, .max_height = size, .radius = 0, .scale = 144 / size });
}

fn iconPng() ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const image = objc.msg(?objc.Object, objc.class("NSImage"), "imageNamed:", .{objc.nsString("NSApplicationIcon")}) orelse return null;
    var rect: objc.CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 144, .height = 144 } };
    const cgi = objc.msg(?*anyopaque, image, "CGImageForProposedRect:context:hints:", .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    return png(@ptrCast(cgi));
}

test "kea.gif reads as timed frames that become PNG" {
    const pool = objc.Pool.push();
    defer pool.pop();
    // `zig build test` runs in zig/: the GIF the bundle carries.
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString("../Icon/kea.gif")});
    var f = read(url) orelse return error.SkipZigTest;
    defer {
        for (f.frames) |fr| if (fr) |b| gpa.free(b);
        gpa.free(f.frames);
        gpa.free(f.ends);
        cg.CFRelease(f.source);
    }
    try std.testing.expect(f.ends.len > 1);
    for (f.ends[1..], f.ends[0 .. f.ends.len - 1]) |a, b| try std.testing.expect(a > b);
    const bytes = frame(&f, 1) orelse return error.NoFrame;
    try std.testing.expectEqualSlices(u8, "\x89PNG", bytes[0..4]);
}
