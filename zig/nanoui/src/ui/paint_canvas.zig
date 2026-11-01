//! A canvas's shapes and glyph runs, moved to its box and clipped to it;
//! shapes wholly outside what shows of it are left out.
const std = @import("std");
const types = @import("types.zig");
const metal = @import("gpu.zig");
const Context = @import("context.zig").Context;
const Canvas = @import("draw.zig").Canvas;
const paint = @import("paint.zig");

pub fn paintCanvas(c: *Context, out: *std.ArrayList(metal.Instance), id: u64, index: u32, cv: *const Canvas, r: types.Rect, visible: types.Rect, opacity: f32, selectable: bool, moving: bool) void {
    const clip = metal.clip4(visible);
    // Copied whole: a formula's source, never part of it.
    if (selectable and cv.copy_text.len > 0) @import("selection.zig").box(c, out, id, index, cv.copy_text, cv.copy_join, r, clip);
    out.ensureUnusedCapacity(c.gpa, cv.shapes.items.len) catch return;
    for (cv.shapes.items) |shape| {
        var i = shape;
        i.rect[0] += r.x;
        i.rect[1] += r.y;
        if (i.rect[0] > clip[2] or i.rect[1] > clip[3] or i.rect[0] + i.rect[2] < clip[0] or i.rect[1] + i.rect[3] < clip[1]) continue;
        shiftPoints(&i, r.x, r.y);
        i.color[3] *= opacity;
        i.border_color[3] *= if (i.kind == metal.Kind.quad) opacity else 1;
        i.clip = clip;
        out.appendAssumeCapacity(i);
    }
    for (cv.texts.items) |t| {
        const f = c.text.font(t.style);
        const lh = c.text.lineHeight(t.style);
        // The line's top for a baseline at `t.pos.y`, as `textRun` places it.
        const top = r.y + t.pos.y - ((lh - f.lineHeight()) / 2 + f.leading / 2 + f.ascent);
        const run: @import("context.zig").Content.Text = .{ .str = t.str, .style = t.style, .color = t.color };
        paint.textRun(c, out, run, 0, t.str.len, r.x + t.pos.x, top, f, lh, clip, opacity, null, clip[2], moving);
    }
}

/// Moves a segment's ends and a triangle's corners (kept in `uv` and
/// `border_color`, not `rect`) by `dx`, `dy`.
pub fn shiftPoints(i: *metal.Instance, dx: f32, dy: f32) void {
    if (i.kind != metal.Kind.segment and i.kind != metal.Kind.triangle) return;
    i.uv = .{ i.uv[0] + dx, i.uv[1] + dy, i.uv[2] + dx, i.uv[3] + dy };
    if (i.kind == metal.Kind.triangle) {
        i.border_color[0] += dx;
        i.border_color[1] += dy;
    }
}

/// Scales a segment's ends and a triangle's corners around (`ax`, `ay`).
pub fn scalePoints(i: *metal.Instance, ax: f32, ay: f32, s: f32) void {
    if (i.kind != metal.Kind.segment and i.kind != metal.Kind.triangle) return;
    i.uv = .{ ax + (i.uv[0] - ax) * s, ay + (i.uv[1] - ay) * s, ax + (i.uv[2] - ax) * s, ay + (i.uv[3] - ay) * s };
    if (i.kind == metal.Kind.triangle) {
        i.border_color[0] = ax + (i.border_color[0] - ax) * s;
        i.border_color[1] = ay + (i.border_color[1] - ay) * s;
    } else for (i.border_color[0..3]) |*d| d.* *= s; // dash, gap, phase
}
