//! `DiagramView` (Mermaid.swift:1326-1522): a laid-out diagram drawn with
//! CoreGraphics and CoreText into a picture, as SwiftUI's Canvas draws it.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const cg = @import("../../sys/cg.zig");
const Palette = @import("../../design/palette.zig").Palette;
const mermaid = @import("mermaid.zig");

/// The PNG of `d` at `zoom`, two pixels a point, on `gpa`.
pub fn png(gpa: std.mem.Allocator, d: mermaid.Diagram, p: *const Palette, zoom: f32) ![]u8 {
    const w: f32 = @floatCast(d.width);
    const h: f32 = @floatCast(d.height);
    const b = try cg.Bitmap.init(gpa, w * zoom, h * zoom, 2);
    defer b.deinit(gpa);
    const pool = objc.Pool.push();
    defer pool.pop();
    // The Canvas's coordinates: points of the diagram, y down.
    cg.CGContextScaleCTM(b.ctx, zoom, zoom);
    cg.CGContextTranslateCTM(b.ctx, 0, d.height);
    cg.CGContextScaleCTM(b.ctx, 1, -1);
    cg.CGContextSetTextMatrix(b.ctx, .{ .d = -1 });
    for (d.items) |item| draw(b, p, item);
    return b.png(gpa);
}

/// `DiagramView.palette`: the colours of pie slices and their swatches.
fn tint(p: *const Palette, i: i64) ui.Color {
    const all = [_]ui.Color{ p.sunset, p.feather, p.blue, p.orange, p.purple, p.teal, p.pink, p.gray };
    return all[@intCast(@mod(i, all.len))];
}

fn rect(r: mermaid.Rect) objc.CGRect {
    return .{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = r.w, .height = r.h } };
}

fn inset(r: mermaid.Rect, by: f64) mermaid.Rect {
    return .{ .x = r.x + by, .y = r.y + by, .w = r.w - 2 * by, .h = r.h - 2 * by };
}

fn fillPath(b: cg.Bitmap, color: ui.Color) void {
    b.fill(color);
    cg.CGContextFillPath(b.ctx);
}

fn strokePath(b: cg.Bitmap, color: ui.Color, width: f64) void {
    b.stroke(color);
    cg.CGContextSetLineWidth(b.ctx, width);
    cg.CGContextStrokePath(b.ctx);
}

fn roundedRect(b: cg.Bitmap, r: mermaid.Rect, radius: f64) void {
    const rr = @min(radius, @min(r.w, r.h) / 2);
    const path = cg.CGPathCreateWithRoundedRect(rect(r), rr, rr, null) orelse return;
    defer cg.CGPathRelease(path);
    cg.CGContextAddPath(b.ctx, path);
}

fn ellipse(b: cg.Bitmap, r: mermaid.Rect) void {
    cg.CGContextAddEllipseInRect(b.ctx, rect(r));
}

fn draw(b: cg.Bitmap, p: *const Palette, item: mermaid.Item) void {
    switch (item) {
        .node => |n| {
            switch (n.shape) {
                .start => {
                    ellipse(b, n.rect);
                    return fillPath(b, p.ink);
                },
                .end => {
                    ellipse(b, n.rect);
                    strokePath(b, p.ink, 1.4);
                    ellipse(b, inset(n.rect, 3.5));
                    return fillPath(b, p.ink);
                },
                else => {
                    shapePath(b, n.rect, n.shape);
                    fillPath(b, p.wash);
                    shapePath(b, n.rect, n.shape);
                    strokePath(b, p.faint, 1);
                },
            }
            if (n.lines.len == 0) return;
            const r = n.rect;
            const mid_x = r.x + r.w / 2;
            if (n.titled) {
                text(b, n.lines[0], 12, true, p.ink, mid_x, r.y + 12);
                if (n.lines.len > 1) {
                    cg.CGContextBeginPath(b.ctx);
                    cg.CGContextMoveToPoint(b.ctx, r.x, r.y + 22);
                    cg.CGContextAddLineToPoint(b.ctx, r.x + r.w, r.y + 22);
                    strokePath(b, p.hairline, 1);
                    for (n.lines[1..], 0..) |member, i|
                        text(b, member, 11.5, false, p.ink, mid_x, r.y + 32 + @as(f64, @floatFromInt(i)) * 15);
                }
            } else {
                const total = @as(f64, @floatFromInt(n.lines.len)) * 16;
                const start_y = r.y + r.h / 2 - total / 2 + 8;
                for (n.lines, 0..) |l, i| if (l.len > 0)
                    text(b, l, 12, false, p.ink, mid_x, start_y + @as(f64, @floatFromInt(i)) * 16);
            }
        },
        .edge => |e| {
            if (e.points.len < 2) return;
            cg.CGContextBeginPath(b.ctx);
            cg.CGContextMoveToPoint(b.ctx, e.points[0].x, e.points[0].y);
            for (e.points[1..]) |pt| cg.CGContextAddLineToPoint(b.ctx, pt.x, pt.y);
            cg.CGContextSetLineCap(b.ctx, cg.line_cap_round);
            cg.CGContextSetLineJoin(b.ctx, cg.line_join_round);
            const dash = [_]f64{ 4, 3 };
            if (e.dashed) cg.CGContextSetLineDash(b.ctx, 0, &dash, dash.len);
            strokePath(b, p.muted, if (e.thick) 2.4 else 1.2);
            cg.CGContextSetLineDash(b.ctx, 0, null, 0);
            cg.CGContextSetLineCap(b.ctx, 0);
            cg.CGContextSetLineJoin(b.ctx, 0);
            head(b, p, e.head, e.points[e.points.len - 2], e.points[e.points.len - 1]);
            const label = e.label orelse return;
            if (label.len == 0) return;
            const mid_i = (e.points.len - 1) / 2;
            const a = e.points[mid_i];
            const z = e.points[@min(e.points.len - 1, mid_i + 1)];
            const mx = (a.x + z.x) / 2;
            const my = (a.y + z.y) / 2;
            const sz = measure(label, 11, false);
            roundedRect(b, .{ .x = mx - sz.w / 2 - 4, .y = my - sz.h / 2 - 2, .w = sz.w + 8, .h = sz.h + 4 }, 4);
            fillPath(b, p.ground);
            text(b, label, 11, false, p.muted, mx, my);
        },
        .text => |t| text(b, t.str, 11.5, t.bold, if (t.muted) p.muted else p.ink, t.at.x, t.at.y),
        .note => |n| {
            roundedRect(b, n.rect, 6);
            fillPath(b, p.sunset.alpha(0.12));
            roundedRect(b, n.rect, 6);
            strokePath(b, p.sunset.alpha(0.5), 1);
            const total = @as(f64, @floatFromInt(n.lines.len)) * 16;
            const start_y = n.rect.y + n.rect.h / 2 - total / 2 + 8;
            for (n.lines, 0..) |l, i| text(b, l, 11.5, false, p.ink, n.rect.x + n.rect.w / 2, start_y + @as(f64, @floatFromInt(i)) * 16);
        },
        .wedge => |w| {
            cg.CGContextBeginPath(b.ctx);
            cg.CGContextMoveToPoint(b.ctx, w.center.x, w.center.y);
            cg.CGContextAddArc(b.ctx, w.center.x, w.center.y, w.radius, w.from, w.to, 0);
            cg.CGContextClosePath(b.ctx);
            fillPath(b, tint(p, w.color));
            cg.CGContextBeginPath(b.ctx);
            cg.CGContextMoveToPoint(b.ctx, w.center.x, w.center.y);
            cg.CGContextAddArc(b.ctx, w.center.x, w.center.y, w.radius, w.from, w.to, 0);
            cg.CGContextClosePath(b.ctx);
            strokePath(b, p.ground, 1.5);
        },
        .swatch => |s| {
            roundedRect(b, s.rect, 2.5);
            fillPath(b, tint(p, s.color));
        },
    }
}

/// `shapePath(rect:shape:)`, added to the context's path.
fn shapePath(b: cg.Bitmap, r: mermaid.Rect, shape: mermaid.Shape) void {
    const ctx = b.ctx;
    switch (shape) {
        .rect, .start, .end => roundedRect(b, r, 4),
        .round => roundedRect(b, r, 8),
        .stadium => roundedRect(b, r, r.h / 2),
        .circle => ellipse(b, r),
        .diamond => {
            cg.CGContextBeginPath(ctx);
            cg.CGContextMoveToPoint(ctx, r.x + r.w / 2, r.y);
            cg.CGContextAddLineToPoint(ctx, r.x + r.w, r.y + r.h / 2);
            cg.CGContextAddLineToPoint(ctx, r.x + r.w / 2, r.y + r.h);
            cg.CGContextAddLineToPoint(ctx, r.x, r.y + r.h / 2);
            cg.CGContextClosePath(ctx);
        },
        .hexagon => {
            const in = @min(12, r.w / 4);
            cg.CGContextBeginPath(ctx);
            cg.CGContextMoveToPoint(ctx, r.x + in, r.y);
            cg.CGContextAddLineToPoint(ctx, r.x + r.w - in, r.y);
            cg.CGContextAddLineToPoint(ctx, r.x + r.w, r.y + r.h / 2);
            cg.CGContextAddLineToPoint(ctx, r.x + r.w - in, r.y + r.h);
            cg.CGContextAddLineToPoint(ctx, r.x + in, r.y + r.h);
            cg.CGContextAddLineToPoint(ctx, r.x, r.y + r.h / 2);
            cg.CGContextClosePath(ctx);
        },
    }
}

/// `drawHead(_:from:to:in:)`.
fn head(b: cg.Bitmap, p: *const Palette, kind: mermaid.Head, from: mermaid.Point, to: mermaid.Point) void {
    const ctx = b.ctx;
    const angle = std.math.atan2(to.y - from.y, to.x - from.x);
    switch (kind) {
        .none => {},
        .arrow => {
            const len: f64 = 8;
            const spread: f64 = 0.45;
            cg.CGContextBeginPath(ctx);
            cg.CGContextMoveToPoint(ctx, to.x, to.y);
            cg.CGContextAddLineToPoint(ctx, to.x - len * @cos(angle - spread), to.y - len * @sin(angle - spread));
            cg.CGContextAddLineToPoint(ctx, to.x - len * @cos(angle + spread), to.y - len * @sin(angle + spread));
            cg.CGContextClosePath(ctx);
            fillPath(b, p.muted);
        },
        .cross => {
            const r: f64 = 4;
            cg.CGContextBeginPath(ctx);
            cg.CGContextMoveToPoint(ctx, to.x - r, to.y - r);
            cg.CGContextAddLineToPoint(ctx, to.x + r, to.y + r);
            cg.CGContextMoveToPoint(ctx, to.x - r, to.y + r);
            cg.CGContextAddLineToPoint(ctx, to.x + r, to.y - r);
            strokePath(b, p.muted, 1.6);
        },
        .circle => {
            const r: f64 = 3.5;
            const c: mermaid.Rect = .{ .x = to.x - r, .y = to.y - r, .w = r * 2, .h = r * 2 };
            ellipse(b, c);
            fillPath(b, p.ground);
            ellipse(b, c);
            strokePath(b, p.muted, 1.4);
        },
    }
}

/// `str` set in the system font as a CoreText line (owned).
fn line(str: []const u8, size: f64, bold: bool) ?cg.Line {
    const font = objc.msg(objc.Object, objc.class("NSFont"), "systemFontOfSize:weight:", .{ size, @as(f64, if (bold) 0.3 else 0) });
    const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{true});
    const keys = [_]objc.Object{ objc.nsString("NSFont"), @ptrCast(@constCast(cg.kCTForegroundColorFromContextAttributeName)) };
    const values = [_]objc.Object{ font, yes };
    const attrs = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, keys.len) });
    const s = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSAttributedString"), "alloc", .{}), "initWithString:attributes:", .{ objc.nsString(str), attrs });
    defer objc.release(s);
    return cg.CTLineCreateWithAttributedString(s);
}

const Size = struct { w: f64, h: f64, ascent: f64 = 0 };

/// A resolved Text's size: its width and its line's height.
fn measure(str: []const u8, size: f64, bold: bool) Size {
    const l = line(str, size, bold) orelse return .{ .w = 0, .h = 0 };
    defer cg.CFRelease(@ptrCast(l));
    return sized(l);
}

fn sized(l: cg.Line) Size {
    var ascent: f64 = 0;
    var descent: f64 = 0;
    var leading: f64 = 0;
    const w = cg.CTLineGetTypographicBounds(l, &ascent, &descent, &leading);
    return .{ .w = w, .h = ascent + descent + leading, .ascent = ascent };
}

/// `ctx.draw(text, at: (x, y), anchor: .center)`.
fn text(b: cg.Bitmap, str: []const u8, size: f64, bold: bool, color: ui.Color, x: f64, y: f64) void {
    const l = line(str, size, bold) orelse return;
    defer cg.CFRelease(@ptrCast(l));
    const sz = sized(l);
    b.fill(color);
    cg.CGContextSetTextPosition(b.ctx, x - sz.w / 2, y - sz.h / 2 + sz.ascent);
    cg.CTLineDraw(l, b.ctx);
}

test "mermaid draw: a flowchart is a picture of the diagram's size, drawn on" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const d = mermaid.diagram(arena.allocator(), "graph TD\n  A-->B\n  A-->C") orelse return error.NoDiagram;
    const p = @import("../../design/palette.zig").get(false);
    const bytes = try png(std.testing.allocator, d, p, 1.5);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n"));
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    try std.testing.expectEqual(@as(u32, @intFromFloat(@ceil(d.width * 3))), width);
    try std.testing.expectEqual(@as(u32, @intFromFloat(@ceil(d.height * 3))), height);
    // Three nodes and two edges are far more than an empty picture's bytes.
    try std.testing.expect(bytes.len > 1500);
}
