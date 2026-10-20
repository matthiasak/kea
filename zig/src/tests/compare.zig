//! `zig build compare -- <ref_dir> <zig_dir> <out_dir>`
//! Compares Swift reference PNGs/sidecars against KeaZig snapshots and films,
//! writing red-overlay `<state>-<look>-diff.png` images and `<out_dir>/report.md`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");

const cg = struct {
    const Context = *opaque {};
    const ColorSpace = *opaque {};
    const ImageRef = *opaque {};
    const Destination = *opaque {};
    const Source = *opaque {};
    const CFStringRef = *const opaque {};
    const CFDataRef = *opaque {};

    const bgra_premultiplied: u32 = 2 | (2 << 12);

    extern "c" const kCGColorSpaceSRGB: CFStringRef;
    extern "c" fn CGColorSpaceCreateWithName(name: CFStringRef) ?ColorSpace;
    extern "c" fn CGColorSpaceRelease(space: ColorSpace) void;
    extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: ColorSpace, info: u32) ?Context;
    extern "c" fn CGContextRelease(ctx: Context) void;
    extern "c" fn CGBitmapContextCreateImage(ctx: Context) ?ImageRef;
    extern "c" fn CGImageRelease(image: ImageRef) void;
    extern "c" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, len: isize) ?CFDataRef;
    extern "c" fn CFDataCreateMutable(allocator: ?*anyopaque, capacity: isize) ?CFDataRef;
    extern "c" fn CFDataGetBytePtr(data: CFDataRef) [*]const u8;
    extern "c" fn CFDataGetLength(data: CFDataRef) isize;
    extern "c" fn CFRelease(object: *anyopaque) void;
    extern "c" fn CGImageSourceCreateWithData(data: CFDataRef, options: ?*anyopaque) ?Source;
    extern "c" fn CGImageSourceCreateImageAtIndex(source: Source, index: usize, options: ?*anyopaque) ?ImageRef;
    extern "c" fn CGImageGetWidth(image: ImageRef) usize;
    extern "c" fn CGImageGetHeight(image: ImageRef) usize;
    extern "c" fn CGContextDrawImage(ctx: Context, rect: objc.CGRect, image: ImageRef) void;
    extern "c" fn CGImageDestinationCreateWithData(data: CFDataRef, kind: CFStringRef, count: usize, options: ?*anyopaque) ?Destination;
    extern "c" fn CGImageDestinationAddImage(dest: Destination, image: ImageRef, properties: ?*anyopaque) void;
    extern "c" fn CGImageDestinationFinalize(dest: Destination) bool;
};

const state_names = [_][]const u8{
    "p0-default",             "p3-cards",                "p3-strip",              "p4-strip-12-tabs",
    "p4-column-pins-groups",  "p4-strip-icons",          "p4-column-pins-icons",  "p6-site-card",
    "p6-omnibox-list",        "p6-site-chip",
    "p8-side-panel",          "p7-split",                "p7-peek",               "p7-switcher",
    "p8-settings-general",    "p8-settings-tabs",        "p8-settings-shortcuts", "p8-settings-downloads",
    "p8-settings-privacy",    "p8-settings-ai",          "p8-settings-about",     "p8-welcome",
    "p8-history",             "p8-downloads",            "p8-find",               "p8-bars",
    "p8-bookmarks-manager",   "p9-markdown",             "p9-mermaid",            "p8-bookmarks-bar",
    "p9-organize",            "p9-chat",                 "p12-sync-settings",     "p10-passwords",
    "p10-keep-asking",        "p10-settings-passwords",  "p11-import",            "p13-extensions-settings",
    "p13-slot",               "strip",                   "column",                "site",
    "fold",
};

const Sidecar = struct {
    pixels: [2]u32 = .{ 0, 0 },
    points: [2]u32 = .{ 0, 0 },
    lights: []const [2]f32 = &.{},
    cards: bool = false,
    holes: []const ui.Rect = &.{},
    card: ?ui.Rect = null,
    icons: []const ui.Rect = &.{},
};

const FilmLights = struct {
    hidden: bool = false,
    x: i64 = 0,
};

const FilmFrame = struct {
    t: i64 = 0,
    lights: ?FilmLights = null,
    edge_x: ?f32 = null,
};

const FilmJson = struct {
    action: []const u8 = "",
    look: []const u8 = "",
    t: []const i64 = &.{},
    frames: []const FilmFrame = &.{},
};

const Image = struct {
    width: u32,
    height: u32,
    bgra: []u8,

    fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.bgra);
    }
};

const Cluster = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    area: u32,
    pixels: u32,
};

fn decodePngFile(gpa: std.mem.Allocator, path: []const u8) !Image {
    const bytes = app.disk.read(gpa, path) orelse return error.FileNotFound;
    defer gpa.free(bytes);
    const data = cg.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.Data;
    defer cg.CFRelease(data);
    const src = cg.CGImageSourceCreateWithData(data, null) orelse return error.NotImage;
    defer cg.CFRelease(src);
    const img = cg.CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.NotImage;
    defer cg.CGImageRelease(img);
    const w = cg.CGImageGetWidth(img);
    const h = cg.CGImageGetHeight(img);
    if (w == 0 or h == 0 or w * h > 64 * 1024 * 1024) return error.InvalidSize;
    const out = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    const space = cg.CGColorSpaceCreateWithName(cg.kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer cg.CGColorSpaceRelease(space);
    const ctx = cg.CGBitmapContextCreate(out.ptr, w, h, 8, w * 4, space, cg.bgra_premultiplied) orelse return error.Context;
    defer cg.CGContextRelease(ctx);
    cg.CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, img);
    return .{ .width = @intCast(w), .height = @intCast(h), .bgra = out };
}

fn writeBytes(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    const file = std.c.fopen(z, "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(file);
    if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.WriteFailed;
}

fn writePngFile(gpa: std.mem.Allocator, path: []const u8, img: Image) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const space = cg.CGColorSpaceCreateWithName(cg.kCGColorSpaceSRGB) orelse return error.ColorSpace;
    defer cg.CGColorSpaceRelease(space);
    const ctx = cg.CGBitmapContextCreate(img.bgra.ptr, img.width, img.height, 8, @as(usize, img.width) * 4, space, cg.bgra_premultiplied) orelse return error.Context;
    defer cg.CGContextRelease(ctx);
    const cg_img = cg.CGBitmapContextCreateImage(ctx) orelse return error.Image;
    defer cg.CGImageRelease(cg_img);
    const data = cg.CFDataCreateMutable(null, 0) orelse return error.OutOfMemory;
    defer cg.CFRelease(data);
    const kind: cg.CFStringRef = @ptrCast(objc.nsString("public.png"));
    const dest = cg.CGImageDestinationCreateWithData(data, kind, 1, null) orelse return error.Destination;
    defer cg.CFRelease(dest);
    cg.CGImageDestinationAddImage(dest, cg_img, null);
    if (!cg.CGImageDestinationFinalize(dest)) return error.Encode;
    try writeBytes(gpa, path, cg.CFDataGetBytePtr(data)[0..@intCast(cg.CFDataGetLength(data))]);
}

fn readSidecar(gpa: std.mem.Allocator, path: []const u8) ?std.json.Parsed(Sidecar) {
    const bytes = app.disk.read(gpa, path) orelse return null;
    defer gpa.free(bytes);
    return app.json.decode(Sidecar, gpa, bytes) catch null;
}

fn cropImage(gpa: std.mem.Allocator, src: Image, x0: u32, y0: u32, cw: u32, ch: u32) !Image {
    const w = @min(cw, src.width -| x0);
    const h = @min(ch, src.height -| y0);
    if (w == 0 or h == 0) return error.EmptyCrop;
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |ry| {
        const sy = y0 + @as(u32, @intCast(ry));
        const src_off = (@as(usize, sy) * src.width + x0) * 4;
        const dst_off = ry * w * 4;
        @memcpy(out[dst_off .. dst_off + @as(usize, w) * 4], src.bgra[src_off .. src_off + @as(usize, w) * 4]);
    }
    return .{ .width = w, .height = h, .bgra = out };
}

fn fillMaskRect(mask: []bool, width: u32, height: u32, x0_f: f32, y0_f: f32, x1_f: f32, y1_f: f32) void {
    if (x1_f <= x0_f or y1_f <= y0_f) return;
    const x0: u32 = @intFromFloat(@max(0, @floor(x0_f)));
    const y0: u32 = @intFromFloat(@max(0, @floor(y0_f)));
    const x1: u32 = @min(width, @as(u32, @intFromFloat(@max(0, @ceil(x1_f)))));
    const y1: u32 = @min(height, @as(u32, @intFromFloat(@max(0, @ceil(y1_f)))));
    if (x0 >= x1 or y0 >= y1) return;
    var y = y0;
    while (y < y1) : (y += 1) {
        const row = @as(usize, y) * width;
        @memset(mask[row + x0 .. row + x1], true);
    }
}

fn applySidecarMasks(mask: []bool, width: u32, height: u32, sc: Sidecar, cards: bool) void {
    const scale_x: f32 = if (sc.points[0] > 0) @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(sc.points[0])) else 2.0;
    const scale_y: f32 = if (sc.points[1] > 0) @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(sc.points[1])) else 2.0;
    const inset: f32 = if (cards) 11.0 else 0.0;
    for (sc.holes) |h| {
        const hx0 = (h.x + inset) * scale_x;
        const hy0 = (h.y + inset) * scale_y;
        const hx1 = (h.x + h.w - inset) * scale_x;
        const hy1 = (h.y + h.h - inset) * scale_y;
        fillMaskRect(mask, width, height, hx0, hy0, hx1, hy1);
    }
    const default_lights = [_][2]f32{ .{ 19, 26 }, .{ 39, 26 }, .{ 59, 26 } };
    const lights_slice: []const [2]f32 = if (sc.lights.len > 0) sc.lights else &default_lights;
    for (lights_slice) |lt| {
        const lx0 = (lt[0] - 3.0) * scale_x;
        const ly0 = (lt[1] - 10.0) * scale_y;
        const lx1 = (lt[0] + 17.0) * scale_x;
        const ly1 = (lt[1] + 10.0) * scale_y;
        fillMaskRect(mask, width, height, lx0, ly0, lx1, ly1);
    }
}

fn findClusters(gpa: std.mem.Allocator, diff_map: []const u8, width: u32, height: u32) !struct { count: u32, largest: ?Cluster } {
    const visited = try gpa.alloc(bool, diff_map.len);
    defer gpa.free(visited);
    @memset(visited, false);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);

    var count: u32 = 0;
    var largest: ?Cluster = null;

    var idx: usize = 0;
    while (idx < diff_map.len) : (idx += 1) {
        if (diff_map[idx] == 0 or visited[idx]) continue;
        visited[idx] = true;
        queue.clearRetainingCapacity();
        try queue.append(gpa, @intCast(idx));

        var head: usize = 0;
        var min_x: u32 = @intCast(idx % width);
        var max_x: u32 = min_x;
        var min_y: u32 = @intCast(idx / width);
        var max_y: u32 = min_y;

        while (head < queue.items.len) : (head += 1) {
            const cur = queue.items[head];
            const cx: u32 = cur % width;
            const cy: u32 = cur / width;
            if (cx < min_x) min_x = cx;
            if (cx > max_x) max_x = cx;
            if (cy < min_y) min_y = cy;
            if (cy > max_y) max_y = cy;

            const nbs = [_]?u32{
                if (cx > 0) cur - 1 else null,
                if (cx + 1 < width) cur + 1 else null,
                if (cy > 0) cur - width else null,
                if (cy + 1 < height) cur + width else null,
            };
            for (nbs) |maybe_nb| if (maybe_nb) |nb| {
                if (diff_map[nb] != 0 and !visited[nb]) {
                    visited[nb] = true;
                    try queue.append(gpa, nb);
                }
            };
        }
        const cw = max_x - min_x + 1;
        const ch = max_y - min_y + 1;
        const area = cw * ch;
        if (area >= 4) {
            count += 1;
            const cl = Cluster{ .x = min_x, .y = min_y, .w = cw, .h = ch, .area = area, .pixels = @intCast(queue.items.len) };
            if (largest == null or cl.area > largest.?.area) largest = cl;
        }
    }
    return .{ .count = count, .largest = largest };
}

fn compareState(gpa: std.mem.Allocator, ref_dir: []const u8, zig_dir: []const u8, out_dir: []const u8, state: []const u8, look: []const u8, report: *std.ArrayList(u8)) !void {
    const ref_png = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ ref_dir, state, look });
    defer gpa.free(ref_png);
    var zig_png = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ zig_dir, state, look });
    defer gpa.free(zig_png);
    const ref_img_raw = decodePngFile(gpa, ref_png) catch {
        try report.print(gpa, "| `{s}-{s}` | missing ref | - | - | - |\n", .{ state, look });
        return;
    };
    defer ref_img_raw.deinit(gpa);
    var zig_state_for_sidecar = state;
    const zig_img_raw = decodePngFile(gpa, zig_png) catch blk: {
        const fallback = if (std.mem.eql(u8, state, "site")) "p6-site-card" else if (std.mem.eql(u8, state, "strip")) "p3-strip" else if (std.mem.eql(u8, state, "column")) "p3-cards" else {
            try report.print(gpa, "| `{s}-{s}` | missing zig | - | - | - |\n", .{ state, look });
            return;
        };
        gpa.free(zig_png);
        zig_png = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ zig_dir, fallback, look });
        zig_state_for_sidecar = fallback;
        break :blk decodePngFile(gpa, zig_png) catch {
            try report.print(gpa, "| `{s}-{s}` | missing zig | - | - | - |\n", .{ state, look });
            return;
        };
    };
    defer zig_img_raw.deinit(gpa);
    const ref_sc_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.json", .{ ref_dir, state, look });
    defer gpa.free(ref_sc_path);
    const zig_sc_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.json", .{ zig_dir, zig_state_for_sidecar, look });
    defer gpa.free(zig_sc_path);
    const ref_sc_parsed = readSidecar(gpa, ref_sc_path);
    defer if (ref_sc_parsed) |p| p.deinit();
    const zig_sc_parsed = readSidecar(gpa, zig_sc_path);
    defer if (zig_sc_parsed) |p| p.deinit();
    const ref_sc = if (ref_sc_parsed) |p| p.value else Sidecar{};
    const zig_sc = if (zig_sc_parsed) |p| p.value else Sidecar{};
    var ref_use = ref_img_raw;
    var zig_use = zig_img_raw;
    var cropped_zig: ?Image = null;
    defer if (cropped_zig) |c| c.deinit(gpa);
    var cropped_ref: ?Image = null;
    defer if (cropped_ref) |c| c.deinit(gpa);

    if (ref_use.width != zig_use.width or ref_use.height != zig_use.height) {
        if ((std.mem.eql(u8, state, "p6-site-card") or std.mem.eql(u8, state, "site")) and zig_sc.card != null) {
            const c = zig_sc.card.?;
            const sx: f32 = if (zig_sc.points[0] > 0) @as(f32, @floatFromInt(zig_use.width)) / @as(f32, @floatFromInt(zig_sc.points[0])) else 2.0;
            const sy: f32 = if (zig_sc.points[1] > 0) @as(f32, @floatFromInt(zig_use.height)) / @as(f32, @floatFromInt(zig_sc.points[1])) else 2.0;
            const cx: u32 = @intFromFloat(@max(0, @round(c.x * sx)));
            const cy: u32 = @intFromFloat(@max(0, @round(c.y * sy)));
            const cw = @min(ref_use.width, @as(u32, @intFromFloat(@max(1, @round(c.w * sx)))));
            const ch = @min(ref_use.height, @as(u32, @intFromFloat(@max(1, @round(c.h * sy)))));
            cropped_zig = cropImage(gpa, zig_use, cx, cy, cw, ch) catch null;
            if (cropped_zig) |cz| {
                zig_use = cz;
                if (ref_use.width != zig_use.width or ref_use.height != zig_use.height) {
                    const mw = @min(ref_use.width, zig_use.width);
                    const mh = @min(ref_use.height, zig_use.height);
                    cropped_ref = cropImage(gpa, ref_use, 0, 0, mw, mh) catch null;
                    if (cropped_ref) |cr| ref_use = cr;
                    const cz2 = cropImage(gpa, zig_use, 0, 0, mw, mh) catch null;
                    if (cz2) |c2| {
                        cz.deinit(gpa);
                        cropped_zig = c2;
                        zig_use = c2;
                    }
                }
            }
        } else if (std.mem.eql(u8, state, "strip") or std.mem.eql(u8, state, "column") or std.mem.eql(u8, state, "fold")) {
            const mw = @min(ref_use.width, zig_use.width);
            const mh = @min(ref_use.height, zig_use.height);
            cropped_ref = cropImage(gpa, ref_use, 0, 0, mw, mh) catch null;
            cropped_zig = cropImage(gpa, zig_use, 0, 0, mw, mh) catch null;
            if (cropped_ref) |cr| ref_use = cr;
            if (cropped_zig) |cz| zig_use = cz;
        }
    }

    if (ref_use.width != zig_use.width or ref_use.height != zig_use.height) {
        try report.print(gpa, "| `{s}-{s}` | size mismatch ({d}x{d} vs {d}x{d}) | - | - | - |\n", .{ state, look, ref_use.width, ref_use.height, zig_use.width, zig_use.height });
        return;
    }
    const w = ref_use.width;
    const h = ref_use.height;
    const n_px = @as(usize, w) * h;
    const mask = try gpa.alloc(bool, n_px);
    defer gpa.free(mask);
    @memset(mask, false);
    const cards = ref_sc.cards or zig_sc.cards;
    applySidecarMasks(mask, w, h, ref_sc, cards);
    applySidecarMasks(mask, w, h, zig_sc, cards);
    const diff_map = try gpa.alloc(u8, n_px);
    defer gpa.free(diff_map);
    @memset(diff_map, 0);
    const diff_img = Image{ .width = w, .height = h, .bgra = try gpa.alloc(u8, n_px * 4) };
    defer diff_img.deinit(gpa);
    var unmasked_total: u64 = 0;
    var diff_pixels: u64 = 0;

    for (0..n_px) |i| {
        const r_px = ref_use.bgra[i * 4 ..][0..4];
        const z_px = zig_use.bgra[i * 4 ..][0..4];
        const out_px = diff_img.bgra[i * 4 ..][0..4];

        if (mask[i]) {
            out_px.* = .{ z_px[0] / 3, z_px[1] / 3, z_px[2] / 3, 255 };
            continue;
        }
        unmasked_total += 1;
        const db = @abs(@as(i32, r_px[0]) - @as(i32, z_px[0]));
        const dg = @abs(@as(i32, r_px[1]) - @as(i32, z_px[1]));
        const dr = @abs(@as(i32, r_px[2]) - @as(i32, z_px[2]));
        const da = @abs(@as(i32, r_px[3]) - @as(i32, z_px[3]));
        const max_d = @max(@max(dr, dg), @max(db, da));
        if (max_d > 2) {
            diff_pixels += 1;
            diff_map[i] = 1;
            out_px.* = .{ z_px[0] / 4, z_px[1] / 4, @intCast(@min(255, @as(u32, z_px[2]) / 4 + 200)), 255 };
        } else {
            out_px.* = z_px.*;
        }
    }

    const diff_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}-diff.png", .{ out_dir, state, look });
    defer gpa.free(diff_path);
    try writePngFile(gpa, diff_path, diff_img);

    const cl = try findClusters(gpa, diff_map, w, h);
    const pct: f64 = if (unmasked_total > 0) (@as(f64, @floatFromInt(diff_pixels)) * 100.0 / @as(f64, @floatFromInt(unmasked_total))) else 0.0;

    if (cl.largest) |lg| {
        try report.print(gpa, "| `{s}-{s}` | {d} | {d:.2}% | {d} | `{d},{d} {d}x{d}` ({d} px) |\n", .{
            state, look, diff_pixels, pct, cl.count, lg.x, lg.y, lg.w, lg.h, lg.pixels,
        });
    } else {
        try report.print(gpa, "| `{s}-{s}` | {d} | {d:.2}% | 0 | none |\n", .{
            state, look, diff_pixels, pct,
        });
    }
}

/// Finds the column edge x (in points) along a fixed row in the top-left 380x460 pt region.
fn extractColumnEdgePt(img: Image, scale: f32) f32 {
    const scan_w: u32 = @min(img.width, @as(u32, @intFromFloat(@round(380.0 * scale))));
    const scan_y: u32 = @min(img.height -| 1, @as(u32, @intFromFloat(@round(230.0 * scale))));
    if (scan_w < 8) return 0;
    const row = @as(usize, scan_y) * img.width;
    const bg = img.bgra[(row + scan_w - 2) * 4 ..][0..4];
    var x: u32 = scan_w - 2;
    while (x > 0) : (x -= 1) {
        const px = img.bgra[(row + x) * 4 ..][0..4];
        const db = @abs(@as(i32, px[0]) - @as(i32, bg[0]));
        const dg = @abs(@as(i32, px[1]) - @as(i32, bg[1]));
        const dr = @abs(@as(i32, px[2]) - @as(i32, bg[2]));
        if (@max(dr, @max(dg, db)) > 3) return @as(f32, @floatFromInt(x)) / scale;
    }
    return 0;
}
fn compareFilms(gpa: std.mem.Allocator, ref_dir: []const u8, zig_dir: []const u8, report: *std.ArrayList(u8)) !void {
    try report.appendSlice(gpa, "\n## Film Motion Comparison\n\n");
    try report.appendSlice(gpa, "| Film | Frames | Max \\|Δx\\| (pt) | Worst frame (t ms, ref x, zig x) |\n");
    try report.appendSlice(gpa, "|---|---:|---:|---|\n");

    const actions = [_][]const u8{ "peek", "unpeek", "fold" };
    for (actions) |action| {
        for ([_][]const u8{ "light", "dark" }) |look| {
            const ref_jpath = try std.fmt.allocPrint(gpa, "{s}/film-{s}-{s}.json", .{ ref_dir, action, look });
            defer gpa.free(ref_jpath);
            const zig_jpath = try std.fmt.allocPrint(gpa, "{s}/film-{s}-{s}.json", .{ zig_dir, action, look });
            defer gpa.free(zig_jpath);

            const ref_bytes = app.disk.read(gpa, ref_jpath) orelse {
                try report.print(gpa, "| `film-{s}-{s}` | missing ref | - | - |\n", .{ action, look });
                continue;
            };
            defer gpa.free(ref_bytes);
            const zig_bytes = app.disk.read(gpa, zig_jpath) orelse {
                try report.print(gpa, "| `film-{s}-{s}` | missing zig | - | - |\n", .{ action, look });
                continue;
            };
            defer gpa.free(zig_bytes);

            const ref_parsed = app.json.decode(FilmJson, gpa, ref_bytes) catch continue;
            defer ref_parsed.deinit();
            const zig_parsed = app.json.decode(FilmJson, gpa, zig_bytes) catch continue;
            defer zig_parsed.deinit();

            const count = @min(ref_parsed.value.t.len, zig_parsed.value.t.len);
            if (count == 0) continue;
            var max_dx: f32 = 0;
            var worst_idx: usize = 0;
            var worst_t: i64 = 0;
            var worst_ref_x: f32 = 0;
            var worst_zig_x: f32 = 0;
            const r_frames = ref_parsed.value.frames;
            const z_frames = zig_parsed.value.frames;
            const frame_limit = if (r_frames.len > 0) @min(count -| 1, @min(r_frames.len, z_frames.len)) else count;
            var stalled: usize = 0;
            for (0..frame_limit) |i| {
                if (i + 1 < ref_parsed.value.t.len and ref_parsed.value.t[i + 1] - ref_parsed.value.t[i] > 100) {
                    stalled += 1;
                    continue;
                }
                const rx: f32 = if (i < r_frames.len and r_frames[i].lights != null) blk: {
                    const l = r_frames[i].lights.?;
                    if (std.mem.eql(u8, action, "peek")) {
                        break :blk if (i == 0 or l.hidden) 0 else @max(0, 232.0 + @as(f32, @floatFromInt(l.x)));
                    }
                    break :blk if (l.hidden) 0 else @max(0, 232.0 + @as(f32, @floatFromInt(l.x)));
                } else blk: {
                    const rf_path = try std.fmt.allocPrint(gpa, "{s}/film-{s}-{s}-{d:0>2}.png", .{ ref_dir, action, look, i });
                    defer gpa.free(rf_path);
                    const r_img = decodePngFile(gpa, rf_path) catch continue;
                    defer r_img.deinit(gpa);
                    const r_scale: f32 = @max(1.0, @round(@as(f32, @floatFromInt(r_img.width)) / 380.0));
                    break :blk extractColumnEdgePt(r_img, r_scale);
                };

                const zx: f32 = if (i < z_frames.len and z_frames[i].edge_x != null)
                    z_frames[i].edge_x.?
                else blk: {
                    const zf_path = try std.fmt.allocPrint(gpa, "{s}/film-{s}-{s}-{d:0>2}.png", .{ zig_dir, action, look, i });
                    defer gpa.free(zf_path);
                    const z_img = decodePngFile(gpa, zf_path) catch continue;
                    defer z_img.deinit(gpa);
                    const z_scale: f32 = @max(1.0, @round(@as(f32, @floatFromInt(z_img.width)) / 1440.0));
                    break :blk extractColumnEdgePt(z_img, z_scale);
                };

                const dx = @abs(rx - zx);
                if (dx >= max_dx) {
                    max_dx = dx;
                    worst_idx = i;
                    worst_t = ref_parsed.value.t[i];
                    worst_ref_x = rx;
                    worst_zig_x = zx;
                }
            }
            if (stalled > 0) try report.print(gpa, "| `film-{s}-{s}` | {d} (-{d} stalled) | {d:.2} | #{d} (t={d} ms, ref={d:.1}, zig={d:.1}) |\n", .{ action, look, count, stalled, max_dx, worst_idx, worst_t, worst_ref_x, worst_zig_x }) else try report.print(gpa, "| `film-{s}-{s}` | {d} | {d:.2} | #{d} (t={d} ms, ref={d:.1}, zig={d:.1}) |\n", .{ action, look, count, max_dx, worst_idx, worst_t, worst_ref_x, worst_zig_x });
        }
    }
}

fn compareIconCrops(gpa: std.mem.Allocator, ref_dir: []const u8, zig_dir: []const u8, report: *std.ArrayList(u8)) !void {
    try report.appendSlice(gpa, "\n## Icon Crop Comparison\n\n| State | Crops | Mean Abs Diff (/255) | Max Diff | Status |\n|---|---:|---:|---:|---|\n");
    const icon_states = [_][]const u8{ "p4-strip-icons", "p4-column-pins-icons" };
    for (icon_states) |state| {
        for ([_][]const u8{ "light", "dark" }) |look| {
            const ref_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ ref_dir, state, look });
            defer gpa.free(ref_path);
            const zig_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ zig_dir, state, look });
            defer gpa.free(zig_path);
            const sc_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.json", .{ zig_dir, state, look });
            defer gpa.free(sc_path);
            const zig_img = decodePngFile(gpa, zig_path) catch {
                try report.print(gpa, "| `{s}-{s}` | - | - | - | missing zig |\n", .{ state, look });
                continue;
            };
            defer zig_img.deinit(gpa);
            const ref_img = decodePngFile(gpa, ref_path) catch {
                try report.print(gpa, "| `{s}-{s}` | - | - | - | missing ref |\n", .{ state, look });
                continue;
            };
            defer ref_img.deinit(gpa);
            const sc_parsed = readSidecar(gpa, sc_path);
            defer if (sc_parsed) |p| p.deinit();
            const sc = if (sc_parsed) |p| p.value else Sidecar{};
            const sx: f32 = if (sc.points[0] > 0) @as(f32, @floatFromInt(zig_img.width)) / @as(f32, @floatFromInt(sc.points[0])) else 2.0;
            const sy: f32 = if (sc.points[1] > 0) @as(f32, @floatFromInt(zig_img.height)) / @as(f32, @floatFromInt(sc.points[1])) else 2.0;
            var sum_diff: u64 = 0;
            var samples: u64 = 0;
            var max_diff: u32 = 0;
            for (sc.icons) |r| {
                const x0: u32 = @intFromFloat(@max(0, @round(r.x * sx)));
                const y0: u32 = @intFromFloat(@max(0, @round(r.y * sy)));
                const cw: u32 = @intFromFloat(@max(1, @round(r.w * sx)));
                const ch: u32 = @intFromFloat(@max(1, @round(r.h * sy)));
                var y = y0;
                while (y < @min(y0 + ch, @min(ref_img.height, zig_img.height))) : (y += 1) {
                    var x = x0;
                    while (x < @min(x0 + cw, @min(ref_img.width, zig_img.width))) : (x += 1) {
                        const off = (@as(usize, y) * zig_img.width + x) * 4;
                        for (0..3) |c_idx| {
                            const d = @abs(@as(i32, ref_img.bgra[off + c_idx]) - @as(i32, zig_img.bgra[off + c_idx]));
                            sum_diff += d;
                            samples += 1;
                            if (d > max_diff) max_diff = d;
                        }
                    }
                }
            }
            const mean: f64 = if (samples > 0) @as(f64, @floatFromInt(sum_diff)) / @as(f64, @floatFromInt(samples)) else 0;
            const pass = mean <= 6.0 and max_diff <= 40;
            try report.print(gpa, "| `{s}-{s}` | {d} | {d:.2} | {d} | {s} |\n", .{ state, look, sc.icons.len, mean, max_diff, if (pass) "PASS" else "FAIL" });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const ref_dir = if (args.len > 1) args[1] else "/tmp/kea-ref";
    const zig_dir = if (args.len > 2) args[2] else (init.environ_map.get("KEAZIG_SNAPSHOTS") orelse "/tmp/keazig-snapshots");
    const out_dir = if (args.len > 3) args[3] else "/tmp/keazig-compare";

    app.disk.makePath(gpa, out_dir);

    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(gpa);

    try report.appendSlice(gpa, "# KeaZig vs Swift Kea Reference Comparison\n\n");
    try report.print(gpa, "- Reference dir: `{s}`\n- KeaZig dir: `{s}`\n\n", .{ ref_dir, zig_dir });
    try report.appendSlice(gpa, "## Snapshot Pixel Comparison\n\n");
    try report.appendSlice(gpa, "| State | Diff Pixels | Diff % | Clusters (≥4px²) | Largest Cluster |\n");
    try report.appendSlice(gpa, "|---|---:|---:|---:|---|\n");

    for (state_names) |state| {
        for ([_][]const u8{ "light", "dark" }) |look| {
            try compareState(gpa, ref_dir, zig_dir, out_dir, state, look, &report);
        }
    }

    try compareIconCrops(gpa, ref_dir, zig_dir, &report);
    try compareFilms(gpa, ref_dir, zig_dir, &report);

    const report_path = try std.fmt.allocPrint(gpa, "{s}/report.md", .{out_dir});
    defer gpa.free(report_path);
    try writeBytes(gpa, report_path, report.items);
    std.debug.print("{s}", .{report.items});
}
