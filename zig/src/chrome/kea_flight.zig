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

pub const pose_count = 8;
const pose_frames = [pose_count]usize{ 15, 19, 20, 21, 22, 23, 24, 25 };
pub const sprite_w: f32 = 198;
pub const sprite_h: f32 = 180;

const Sprites = struct {
    left: [pose_count][]u8,
    right: [pose_count][]u8,
};

const keys_left = [pose_count][]const u8{
    "kea.px.l.0", "kea.px.l.1", "kea.px.l.2", "kea.px.l.3",
    "kea.px.l.4", "kea.px.l.5", "kea.px.l.6", "kea.px.l.7",
};
const keys_right = [pose_count][]const u8{
    "kea.px.r.0", "kea.px.r.1", "kea.px.r.2", "kea.px.r.3",
    "kea.px.r.4", "kea.px.r.5", "kea.px.r.6", "kea.px.r.7",
};

var tried = false;
var flight: ?Flight = null;
var sprites_tried = false;
var sprites_source: ?cg.Source = null;
var sprites: ?Sprites = null;
var icon: ?[]u8 = null;
const gpa = std.heap.c_allocator;

/// The GIF, read once (`KeaArt.flight`); null without one.
fn findGifUrl() ?objc.Object {
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    if (objc.msg(?objc.Object, bundle, "URLForResource:withExtension:", .{ objc.nsString("kea"), objc.nsString("gif") })) |u| return u;
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    for ([_][]const u8{ "Icon/kea.gif", "../Icon/kea.gif" }) |p| {
        const s = objc.nsString(p);
        if (objc.msg(objc.BOOL, fm, "fileExistsAtPath:", .{s}))
            return objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{s});
    }
    return null;
}

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

// MARK: pixelated kea flock on New Tab

fn loadSprites() ?*const Sprites {
    if (sprites_tried) return if (sprites) |*s| s else null;
    sprites_tried = true;
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = findGifUrl() orelse return null;
    const source = cg.CGImageSourceCreateWithURL(url, null) orelse return null;
    sprites_source = source;
    sprites = extractSprites(source) orelse return null;
    return &sprites.?;
}

/// Extracts 8 unclipped wingbeat frames from `kea.gif`, keys out the peach
/// backdrop, quantizes to crisp 2x2 pixel-art blocks with boosted alpine
/// emerald and underwing scarlet-orange vibrance, and encodes left/right PNGs.
fn extractSprites(source: cg.Source) ?Sprites {
    if (cg.CGImageSourceGetCount(source) <= pose_frames[pose_count - 1]) return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const gw = 132;
    const gh = 120;
    const out_w = gw * 3;
    const out_h = gh * 3;
    var raw_bmp = cg.Bitmap.init(gpa, 640, 360, 1) catch return null;
    defer raw_bmp.deinit(gpa);
    var bmp_l = cg.Bitmap.init(gpa, out_w, out_h, 1) catch return null;
    defer bmp_l.deinit(gpa);
    var bmp_r = cg.Bitmap.init(gpa, out_w, out_h, 1) catch return null;
    defer bmp_r.deinit(gpa);
    const mask = gpa.alloc(bool, 640 * 360) catch return null;
    defer gpa.free(mask);

    var out: Sprites = undefined;
    var built: usize = 0;
    errdefer for (0..built) |i| {
        gpa.free(out.left[i]);
        gpa.free(out.right[i]);
    };

    for (pose_frames, 0..) |f_idx, k| {
        const img = cg.CGImageSourceCreateImageAtIndex(source, f_idx, null) orelse return null;
        defer cg.CGImageRelease(img);
        @memset(raw_bmp.bytes, 0);
        cg.CGContextDrawImage(raw_bmp.ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 640, .height = 360 } }, img);

        @memset(mask, false);
        for (0..360) |y| {
            const row = raw_bmp.bytes[y * 640 * 4 ..][0 .. 640 * 4];
            const b0: f32 = @floatFromInt(row[0]);
            const g0: f32 = @floatFromInt(row[1]);
            const r0: f32 = @floatFromInt(row[2]);
            const b1: f32 = @floatFromInt(row[(640 - 1) * 4 + 0]);
            const g1: f32 = @floatFromInt(row[(640 - 1) * 4 + 1]);
            const r1: f32 = @floatFromInt(row[(640 - 1) * 4 + 2]);
            for (0..640) |x| {
                const b: f32 = @floatFromInt(row[x * 4 + 0]);
                const g: f32 = @floatFromInt(row[x * 4 + 1]);
                const r: f32 = @floatFromInt(row[x * 4 + 2]);
                const u = @as(f32, @floatFromInt(x)) / 639.0;
                const er = r0 + (r1 - r0) * u;
                const eg = g0 + (g1 - g0) * u;
                const eb = b0 + (b1 - b0) * u;
                const diff = @abs(r - er) + @abs(g - eg) + @abs(b - eb);
                const pink_fringe = r > 195 and (r - g) > 35 and b > 95;
                if (diff > 58 and !pink_fringe) mask[y * 640 + x] = true;
            }
        }

        @memset(bmp_l.bytes, 0);
        @memset(bmp_r.bytes, 0);
        for (0..gh) |gy| {
            const cy: usize = @min(@as(usize, 357), gy * 3 + 1);
            for (0..gw) |gx| {
                const cx: usize = @min(@as(usize, 637), 204 + gx * 3 + 1);
                if (cy < 2 or cx < 2) continue;
                var solid = true;
                for (0..3) |dy| for (0..3) |dx| {
                    if (!mask[(cy + dy - 1) * 640 + (cx + dx - 1)]) solid = false;
                };
                if (!solid) continue;
                const px = raw_bmp.bytes[(cy * 640 + cx) * 4 ..][0..4];
                const b_in: f32 = @floatFromInt(px[0]);
                const g_in: f32 = @floatFromInt(px[1]);
                const r_in: f32 = @floatFromInt(px[2]);
                const lum = 0.299 * r_in + 0.587 * g_in + 0.114 * b_in;
                const sat: f32 = 1.50;
                var nr = (lum + (r_in - lum) * sat) * 1.38 + 12.0;
                var ng = (lum + (g_in - lum) * sat) * 1.38 + 12.0;
                var nb = (lum + (b_in - lum) * sat) * 1.38 + 12.0;
                if (r_in > g_in + 25 and g_in > b_in) {
                    nr *= 1.18;
                    ng *= 1.05;
                } else if (g_in > r_in + 8) {
                    ng *= 1.15;
                    nb *= 1.08;
                }
                const bgra = [4]u8{
                    @intFromFloat(std.math.clamp(nb, 0, 255)),
                    @intFromFloat(std.math.clamp(ng, 0, 255)),
                    @intFromFloat(std.math.clamp(nr, 0, 255)),
                    255,
                };
                const rx = gw - 1 - gx;
                for (0..3) |by| for (0..3) |bx| {
                    const yl = gy * 3 + by;
                    const xl = gx * 3 + bx;
                    const xr = rx * 3 + bx;
                    @memcpy(bmp_l.bytes[(yl * out_w + xl) * 4 ..][0..4], &bgra);
                    @memcpy(bmp_r.bytes[(yl * out_w + xr) * 4 ..][0..4], &bgra);
                };
            }
        }
        out.left[k] = bmp_l.png(gpa) catch return null;
        out.right[k] = bmp_r.png(gpa) catch {
            gpa.free(out.left[k]);
            return null;
        };
        built += 1;
    }
    return out;
}

const BirdSpec = struct {
    dir: u1,
    speed: f32,
    y_frac: f32,
    amp: f32,
    freq: f32,
    flap_hz: f32,
    scale: f32,
    alpha: f32,
    phase: f32,
};

const flock = [_]BirdSpec{
    .{ .dir = 1, .speed = 48, .y_frac = 0.15, .amp = 18, .freq = 1.05, .flap_hz = 1.45, .scale = 0.60, .alpha = 0.82, .phase = 0.42 },
    .{ .dir = 1, .speed = 56, .y_frac = 0.75, .amp = 22, .freq = 1.20, .flap_hz = 1.55, .scale = 0.74, .alpha = 0.88, .phase = 0.68 },
    .{ .dir = 1, .speed = 70, .y_frac = 0.23, .amp = 26, .freq = 1.35, .flap_hz = 1.70, .scale = 0.88, .alpha = 0.93, .phase = 0.16 },
    .{ .dir = 0, .speed = 78, .y_frac = 0.72, .amp = 28, .freq = 1.40, .flap_hz = 1.80, .scale = 0.98, .alpha = 0.96, .phase = 0.77 },
    .{ .dir = 0, .speed = 90, .y_frac = 0.20, .amp = 30, .freq = 1.55, .flap_hz = 1.90, .scale = 1.12, .alpha = 0.99, .phase = 0.26 },
    .{ .dir = 0, .speed = 104, .y_frac = 0.56, .amp = 34, .freq = 1.65, .flap_hz = 2.05, .scale = 1.28, .alpha = 1.00, .phase = 0.14 },
};

const spark_colors = [_]ui.Color{
    ui.Color.hex(0xFF6E30), // underwing scarlet-orange
    ui.Color.hex(0x58D665), // alpine emerald
    ui.Color.hex(0xEBB844), // golden olive
    ui.Color.hex(0x3EC9B0), // primary-shaft turquoise
};

/// Dynamic pixel-art kea circus flying across a blank New Tab (`area`), behind
/// the address field at `field_y`.
pub fn newTabArt(c: *ui.Context, area: ui.Size, field_y: f32) void {
    if (area.w < 240 or area.h < 180) return;
    const sp = loadSprites() orelse return;
    const t: f32 = if (c.reduce_motion) 0 else @floatCast(c.time);
    _ = c.open(.{ .absolute = true, .width = .{ .px = area.w }, .height = .{ .px = area.h }, .clip = true }, "kea.newtab.art");
    defer c.end();

    // Drifting alpine pixel motes across the sky.
    for (0..12) |i| {
        const fi: f32 = @floatFromInt(i);
        const mx = @mod(fi * 173.0 + t * (14.0 + @mod(fi, 4.0) * 5.0), @max(1, area.w));
        const my = @mod(fi * 97.0 + @sin(t * 0.9 + fi) * 18.0, @max(1, area.h));
        if (my > field_y - 24 and my < field_y + 96 and mx > (area.w - 600) * 0.5 and mx < (area.w + 600) * 0.5) continue;
        const pulse = 0.45 + 0.45 * (0.5 + 0.5 * @sin(t * 2.4 + fi * 1.7));
        const sz: f32 = if (i % 3 == 0) 5 else 4;
        _ = c.leaf(.{
            .absolute = true,
            .offset = .{ .x = @round(mx), .y = @round(my) },
            .width = .{ .px = sz },
            .height = .{ .px = sz },
            .background = spark_colors[i % spark_colors.len].alpha(pulse),
        }, .none, null);
    }

    const margin: f32 = 160;
    const span = area.w + margin * 2;
    for (flock, 0..) |b, idx| {
        const u = @mod(b.phase + t * b.speed / @max(span, 400), 1.0);
        const cx = if (b.dir == 1) -margin + u * span else area.w + margin - u * span;
        const wave = t * b.freq + b.phase * 6.2831853;
        // 8 active wingbeat poses + 2 outstretched-glide beats per 10-step cycle.
        const beat = @mod(t * b.flap_hz * 10.0 + b.phase * 10.0, 10.0);
        const step: usize = @intFromFloat(@floor(beat));
        const pose: usize = if (step < pose_count) step else 1;
        const bob = if (step < pose_count) -3.5 * @sin(beat * 0.785398) else 0;
        const reach = b.amp + 6.0;
        const base_y = if (b.y_frac < 0.5)
            @min(area.h * b.y_frac, @max(reach + 24.0, field_y - 48.0 - reach))
        else
            @max(area.h * b.y_frac, @min(area.h - reach - 24.0, field_y + 114.0 + reach));
        const cy = base_y + @sin(wave) * b.amp + bob;
        const dy = @cos(wave) * b.amp * b.freq;
        const slope = std.math.clamp(dy / @max(b.speed, 40), -0.20, 0.20);
        const tilt = if (b.dir == 1) slope else -slope;

        // Pixelated feather/wind sparks trailing the flapping wings.
        const tail_sign: f32 = if (b.dir == 1) -1 else 1;
        for (0..3) |si| {
            const fsi: f32 = @floatFromInt(si + 1);
            const drift = @mod(t * 28.0 + fsi * 9.0 + b.phase * 30.0, 36.0);
            const sx = cx + tail_sign * (52.0 * b.scale + drift);
            const sy = cy + @sin(t * 5.0 + fsi * 2.1 + @as(f32, @floatFromInt(idx))) * (14.0 * b.scale);
            const sa = (1.0 - drift / 36.0) * 0.85 * b.alpha;
            const s_px: f32 = if (si == 0) 6 else 5;
            _ = c.leaf(.{
                .absolute = true,
                .offset = .{ .x = @round(sx), .y = @round(sy) },
                .width = .{ .px = s_px },
                .height = .{ .px = s_px },
                .background = spark_colors[(idx + si) % spark_colors.len].alpha(sa),
            }, .none, null);
        }

        const key = if (b.dir == 1) keys_right[pose] else keys_left[pose];
        const bytes = if (b.dir == 1) sp.right[pose] else sp.left[pose];
        _ = c.open(.{
            .absolute = true,
            .offset = .{ .x = cx - sprite_w * 0.5, .y = cy - sprite_h * 0.5 },
            .width = .{ .px = sprite_w },
            .height = .{ .px = sprite_h },
            .scale = b.scale,
            .rotation = tilt,
            .opacity = b.alpha,
        }, null);
        _ = ui.image(c, .{
            .key = key,
            .bytes = bytes,
            .max_width = sprite_w,
            .max_height = sprite_h,
            .radius = 0,
            .scale = 2,
        });
        c.end();
    }
    if (!c.reduce_motion) c.frameIn(1.0 / 15.0);
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

test "extractSprites builds 8 left and 8 right transparent pixel-art PNGs and renders newTabArt" {
    const sp = loadSprites() orelse return error.NoSprites;
    for (0..pose_count) |i| {
        try std.testing.expectEqualSlices(u8, "\x89PNG", sp.left[i][0..4]);
        try std.testing.expectEqualSlices(u8, "\x89PNG", sp.right[i][0..4]);
    }
    const State = struct {
        fn draw(_: *@This(), c: *ui.Context) void {
            newTabArt(c, c.size, (c.size.h - 50 - 60) / 2);
        }
    };
    var st: State = .{};
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, ui.View.init(&st, State.draw), .{ .width = 1440, .height = 900, .scale = 2, .dark = true });
    defer tester.deinit();
    tester.theme.background = ui.Color.hex(0x1C1C1E);
    tester.dt = 1.0 / 24.0;
    tester.settle(4);
    try std.testing.expect(tester.ctx.nodes.items.len > 20);
}
