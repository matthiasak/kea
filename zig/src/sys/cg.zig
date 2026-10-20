//! CoreGraphics and ImageIO externs for what Kea draws by hand into
//! pictures (the ring, Mermaid's diagrams), and an sRGB
//! bitmap that becomes PNG bytes for `ui.image`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const objc = nanoui.objc;

pub const Context = *opaque {};
pub const ColorSpace = *opaque {};
pub const Image = *opaque {};
pub const Destination = *opaque {};
pub const CFStringRef = *const opaque {};
pub const CFDataRef = *opaque {};

pub const line_cap_round: i32 = 1;
/// `kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little`: BGRA,
/// premultiplied, as nanoui's `Pixels`.
pub const bgra_premultiplied: u32 = 2 | (2 << 12);

pub extern "c" const kCGColorSpaceSRGB: CFStringRef;
pub extern "c" fn CGColorSpaceCreateWithName(name: CFStringRef) ?ColorSpace;
pub extern "c" fn CGColorSpaceRelease(space: ColorSpace) void;
pub extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: ColorSpace, info: u32) ?Context;
pub extern "c" fn CGContextRelease(ctx: Context) void;
pub extern "c" fn CGContextScaleCTM(ctx: Context, sx: f64, sy: f64) void;
pub extern "c" fn CGContextSetRGBStrokeColor(ctx: Context, r: f64, g: f64, b: f64, a: f64) void;
pub extern "c" fn CGContextSetLineWidth(ctx: Context, width: f64) void;
pub extern "c" fn CGContextSetLineCap(ctx: Context, cap: i32) void;
pub extern "c" fn CGContextAddArc(ctx: Context, x: f64, y: f64, radius: f64, start: f64, end: f64, clockwise: c_int) void;
pub extern "c" fn CGContextStrokePath(ctx: Context) void;
pub extern "c" fn CGBitmapContextCreateImage(ctx: Context) ?Image;
pub extern "c" fn CGImageRelease(image: Image) void;

pub extern "c" fn CFDataCreateMutable(allocator: ?*anyopaque, capacity: isize) ?CFDataRef;
pub extern "c" fn CFDataGetBytePtr(data: CFDataRef) [*]const u8;
pub extern "c" fn CFDataGetLength(data: CFDataRef) isize;
pub extern "c" fn CFRelease(object: *anyopaque) void;
pub extern "c" fn CGImageDestinationCreateWithData(data: CFDataRef, kind: CFStringRef, count: usize, options: ?*anyopaque) ?Destination;
pub extern "c" fn CGImageDestinationAddImage(dest: Destination, image: Image, properties: ?*anyopaque) void;
pub extern "c" fn CGImageDestinationFinalize(dest: Destination) bool;

pub const Source = *opaque {};
pub const interpolation_high: i32 = 3;
pub extern "c" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, len: isize) ?CFDataRef;
pub extern "c" fn CGImageSourceCreateWithData(data: CFDataRef, options: ?objc.Object) ?Source;
pub extern "c" fn CGImageSourceGetType(source: Source) ?CFStringRef;
pub extern "c" fn CGImageSourceGetCount(source: Source) usize;
pub extern "c" fn CGImageSourceCopyPropertiesAtIndex(source: Source, index: usize, options: ?objc.Object) ?objc.Object;
pub extern "c" fn CGImageSourceCreateThumbnailAtIndex(source: Source, index: usize, options: ?objc.Object) ?Image;
pub extern "c" const kCGImageSourceShouldCache: CFStringRef;
pub extern "c" const kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
pub extern "c" const kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
pub extern "c" const kCGImageSourceCreateThumbnailWithTransform: CFStringRef;
pub extern "c" const kCGImagePropertyPixelWidth: CFStringRef;
pub extern "c" const kCGImagePropertyPixelHeight: CFStringRef;
pub extern "c" fn CGImageGetWidth(image: Image) usize;
pub extern "c" fn CGImageGetHeight(image: Image) usize;
pub extern "c" fn CGContextDrawImage(ctx: Context, rect: objc.CGRect, image: Image) void;
pub extern "c" fn CGContextSetInterpolationQuality(ctx: Context, quality: i32) void;
pub extern "c" fn CGImageSourceCreateWithURL(url: objc.Object, options: ?objc.Object) ?Source;
pub extern "c" fn CGImageSourceCreateImageAtIndex(source: Source, index: usize, options: ?objc.Object) ?Image;
pub extern "c" const kCGImagePropertyGIFDictionary: CFStringRef;
pub extern "c" const kCGImagePropertyGIFDelayTime: CFStringRef;

// Paths, fills, dashes and text, for Mermaid's diagrams (ai/mermaid/draw.zig).
pub const Path = *opaque {};
pub const AffineTransform = extern struct { a: f64 = 1, b: f64 = 0, c: f64 = 0, d: f64 = 1, tx: f64 = 0, ty: f64 = 0 };
pub const line_join_round: i32 = 1;
pub extern "c" fn CGContextTranslateCTM(ctx: Context, tx: f64, ty: f64) void;
pub extern "c" fn CGContextSetRGBFillColor(ctx: Context, r: f64, g: f64, b: f64, a: f64) void;
pub extern "c" fn CGContextSetLineJoin(ctx: Context, join: i32) void;
pub extern "c" fn CGContextSetLineDash(ctx: Context, phase: f64, lengths: ?[*]const f64, count: usize) void;
pub extern "c" fn CGContextBeginPath(ctx: Context) void;
pub extern "c" fn CGContextMoveToPoint(ctx: Context, x: f64, y: f64) void;
pub extern "c" fn CGContextAddLineToPoint(ctx: Context, x: f64, y: f64) void;
pub extern "c" fn CGContextClosePath(ctx: Context) void;
pub extern "c" fn CGContextAddEllipseInRect(ctx: Context, rect: objc.CGRect) void;
pub extern "c" fn CGContextAddPath(ctx: Context, path: Path) void;
pub extern "c" fn CGContextFillPath(ctx: Context) void;
pub extern "c" fn CGContextSetTextMatrix(ctx: Context, t: AffineTransform) void;
pub extern "c" fn CGContextSetTextPosition(ctx: Context, x: f64, y: f64) void;
pub extern "c" fn CGPathCreateWithRoundedRect(rect: objc.CGRect, corner_width: f64, corner_height: f64, transform: ?*const AffineTransform) ?Path;
pub extern "c" fn CGPathRelease(path: Path) void;
pub const Line = *opaque {};
pub extern "c" fn CTLineCreateWithAttributedString(string: objc.Object) ?Line;
pub extern "c" fn CTLineGetTypographicBounds(line: Line, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;
pub extern "c" fn CTLineDraw(line: Line, ctx: Context) void;
pub extern "c" const kCTForegroundColorFromContextAttributeName: CFStringRef;

/// An sRGB picture of `w`×`h` points at `scale` pixels a point, drawn in
/// points with y up (CoreGraphics' own way).
pub const Bitmap = struct {
    ctx: Context,
    bytes: []u8,
    width: usize,
    height: usize,

    pub fn init(gpa: std.mem.Allocator, w: f32, h: f32, scale: f32) !Bitmap {
        const pw: usize = @intFromFloat(@max(1, @ceil(w * scale)));
        const ph: usize = @intFromFloat(@max(1, @ceil(h * scale)));
        const bytes = try gpa.alloc(u8, pw * ph * 4);
        errdefer gpa.free(bytes);
        @memset(bytes, 0);
        const space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB) orelse return error.ColorSpace;
        defer CGColorSpaceRelease(space);
        const ctx = CGBitmapContextCreate(bytes.ptr, pw, ph, 8, pw * 4, space, bgra_premultiplied) orelse return error.Bitmap;
        CGContextScaleCTM(ctx, scale, scale);
        return .{ .ctx = ctx, .bytes = bytes, .width = pw, .height = ph };
    }

    pub fn deinit(b: Bitmap, gpa: std.mem.Allocator) void {
        CGContextRelease(b.ctx);
        gpa.free(b.bytes);
    }

    pub fn stroke(b: Bitmap, color: ui.Color) void {
        CGContextSetRGBStrokeColor(b.ctx, color.r, color.g, color.b, color.a);
    }

    pub fn fill(b: Bitmap, color: ui.Color) void {
        CGContextSetRGBFillColor(b.ctx, color.r, color.g, color.b, color.a);
    }

    /// The PNG of what is drawn (ImageIO's, `public.png`), on `gpa`.
    pub fn png(b: Bitmap, gpa: std.mem.Allocator) ![]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const image = CGBitmapContextCreateImage(b.ctx) orelse return error.Image;
        defer CGImageRelease(image);
        const data = CFDataCreateMutable(null, 0) orelse return error.OutOfMemory;
        defer CFRelease(data);
        const kind: CFStringRef = @ptrCast(objc.nsString("public.png"));
        const dest = CGImageDestinationCreateWithData(data, kind, 1, null) orelse return error.Destination;
        defer CFRelease(dest);
        CGImageDestinationAddImage(dest, image, null);
        if (!CGImageDestinationFinalize(dest)) return error.Encode;
        return gpa.dupe(u8, CFDataGetBytePtr(data)[0..@intCast(CFDataGetLength(data))]);
    }
};
