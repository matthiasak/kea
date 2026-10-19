//! Turns the laid out tree into the renderer's instances, in paint order,
//! and records the visible rectangles of interactive boxes for hit testing.
const std = @import("std");
const types = @import("types.zig");
const metal = @import("gpu.zig");
const glass = @import("glass.zig");
const text_mod = @import("text.zig");
const rich = text_mod.rich;
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

pub fn paint(c: *Context, out: *std.ArrayList(metal.Instance)) void {
    out.clearRetainingCapacity();
    paintNode(c, out, 0, types.Rect.infinite, 1, false);
}

fn snap(v: f32, scale: f32) f32 {
    return @round(v * scale) / scale;
}

fn push(c: *Context, out: *std.ArrayList(metal.Instance), inst: metal.Instance) void {
    out.append(c.gpa, inst) catch {};
}

fn paintNode(c: *Context, out: *std.ArrayList(metal.Instance), index: u32, clip: types.Rect, opacity_in: f32, selectable_in: bool) void {
    const n = c.node(index).*;
    const st = n.style;
    const selectable = (selectable_in or st.selectable) and !st.control;
    const opacity = opacity_in * st.opacity;
    const r = n.rect;
    const visible = r.intersect(clip);
    if (opacity <= 0.001) return;
    const clip4 = metal.clip4(clip);
    const rect4: [4]f32 = .{ r.x, r.y, r.w, r.h };

    if (visible.w > 0 and visible.h > 0) {
        if (st.shadow) |sh| push(c, out, .{
            .rect = .{ r.x, r.y + sh.y, r.w, r.h },
            .color = metal.color4(sh.color.alpha(opacity)),
            .radius = st.radius,
            // CSS's blur radius is twice the Gaussian's standard deviation.
            .border_width = sh.blur / 2,
            .kind = metal.Kind.shadow,
            .clip = clip4,
        });
        // Glass takes the background's place.
        const fill: ?types.Color = if (st.glass != null) null else st.background;
        if (st.glass) |g| push(c, out, glass.instance(glass.material(g, r.w, r.h, c.theme.dark, c.scale), rect4, st.radius, clip4, opacity));
        if (fill != null or st.border != null) push(c, out, .{
            .rect = rect4,
            .color = metal.color4((fill orelse types.Color.transparent).alpha(opacity)),
            .border_color = metal.color4((st.border orelse types.Color.transparent).alpha(opacity)),
            .border_width = if (st.border != null) st.border_width else 0,
            .radius = st.radius,
            .clip = clip4,
        });
        switch (n.content) {
            .text => |t| paintText(c, out, index, n, t, clip4, opacity, selectable),
            .icon => |ic| if (c.text.atlas.symbol(ic.name, ic.size, @intFromEnum(ic.weight))) |sp| {
                // Centered in its box, which may be larger (a fixed frame).
                const inner = r.inset(st.padding);
                const x = inner.x + (inner.w - (sp.w + 2 * sp.x)) / 2;
                const y = inner.y + (inner.h - (sp.h + 2 * sp.y)) / 2;
                push(c, out, .{
                    .rect = .{ snap(x, c.scale) + sp.x, snap(y, c.scale) + sp.y, sp.w, sp.h },
                    .color = metal.color4(ic.color.alpha(opacity)),
                    .uv = sp.uv,
                    .kind = metal.Kind.text,
                    .clip = clip4,
                });
            },
            .image => |im| if (c.text.images.get(im.key, im.bytes)) |e| push(c, out, .{
                .rect = rect4,
                .color = .{ 1, 1, 1, im.opacity * opacity },
                // A tint (alpha above 0) fills the picture's shape instead.
                .border_color = if (im.tint) |t| metal.color4(t) else .{ 0, 0, 0, 0 },
                .uv = e.uv,
                .radius = st.radius,
                .kind = metal.Kind.image,
                .clip = clip4,
            }),
            .none => {},
        }
    }
    if (n.interactive and visible.w > 0 and visible.h > 0) c.addHit(n.id, index, visible, false);

    var child_clip = clip;
    if (st.clip) child_clip = visible;
    if (st.scroll) {
        child_clip = visible;
        c.addHit(n.id, index, visible, true);
    }
    const first = out.items.len;
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) paintNode(c, out, child, child_clip, opacity, selectable);
    if ((st.clip or st.scroll) and st.radius > 0) roundClip(out.items[first..], r, visible, st.radius);

    if (st.scroll) paintScrollbar(c, out, n, visible, opacity);
}

fn paintText(c: *Context, out: *std.ArrayList(metal.Instance), index: u32, n: ctx_mod.Node, t: ctx_mod.Content.Text, clip4: [4]f32, opacity: f32, selectable: bool) void {
    const sel: ?Sel = if (selectable) .{ .id = n.id, .index = index, .x0 = n.rect.x, .x1 = n.rect.x + n.rect.w } else null;
    const inner = n.rect.inset(n.style.padding);
    const f = c.text.font(t.style);
    const lh = if (t.style.leading == 1) f.lineHeight() else @ceil(f.lineHeight() * t.style.leading);
    if (t.style.wrap) {
        for (t.lines, 0..) |l, i| {
            const y = inner.y + lh * @as(f32, @floatFromInt(i));
            textRun(c, out, t, l.start, l.end, inner.x, y, f, lh, clip4, opacity, sel);
        }
    } else {
        textRun(c, out, t, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel);
    }
}

/// Draws bytes [start, end) of `t`, each glyph in its span's color.
/// A selectable text: its id, its place in the tree, and the box's
/// horizontal extent.
const Sel = struct { id: u64, index: u32, x0: f32, x1: f32 };

fn textRun(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, start: usize, end: usize, x: f32, y: f32, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel) void {
    const style = t.style;
    // Cull lines wholly above or below the clip before shaping them; a
    // selectable one still counts for where the pointer is.
    if (y > clip4[3] or y + lh < clip4[1] or x > clip4[2]) {
        if (sel) |s| if (y + lh <= c.input.mouse.y) {
            c.selection.below = .{ .id = s.id, .at = end };
            if (!c.selection.next_order.contains(s.id)) c.selection.next_order.put(c.gpa, s.id, @intCast(c.selection.next_order.count())) catch {};
        };
        return;
    }
    const styled = t.spans.len > 0 and rich.styled(t.spans);
    const lay = if (styled) rich.layout(c.text, t.str[start..end], style, t.spans, start) else c.text.layout(t.str[start..end], style);
    if (lay.glyphs.len == 0 or x + lay.width < clip4[0]) return;
    const scale = c.scale;
    // The line's extra height (its leading) goes half above, half below.
    const baseline = snap(y + (lh - f.lineHeight()) / 2 + f.leading / 2 + f.ascent, scale);
    const base = metal.color4(t.color.alpha(opacity));
    if (sel) |s| @import("selection.zig").line(c, out, s.id, s.index, t.str, start, end, lay, x, y, lh, s.x0, s.x1, clip4);
    if (t.spans.len > 0) decorations(c, out, t, lay, start, end, x, baseline, f, clip4, opacity);
    var span_i: usize = 0;
    for (lay.glyphs) |g| {
        const pen = (x + g.x) * scale;
        if (pen / scale > clip4[2]) break;
        const px = @floor(pen);
        const bin: u8 = @intFromFloat(@min(text_mod.subpixel_bins - 1, @floor((pen - px) * text_mod.subpixel_bins)));
        const sp = c.text.glyph(g, bin) orelse continue;
        var color = base;
        if (t.spans.len > 0) {
            const at = start + g.index;
            while (span_i < t.spans.len and t.spans[span_i].end <= at) span_i += 1;
            // Glyphs of a run are mostly in order; a ligature or bidi may step back.
            if (span_i < t.spans.len and t.spans[span_i].start > at) {
                span_i = 0;
                while (span_i < t.spans.len and t.spans[span_i].end <= at) span_i += 1;
            }
            if (span_i < t.spans.len and t.spans[span_i].start <= at) if (t.spans[span_i].color) |sc| {
                color = metal.color4(sc.alpha(opacity));
            };
        }
        push(c, out, .{
            .rect = .{ px / scale + sp.x, baseline - g.y + sp.y, sp.w, sp.h },
            .color = color,
            .uv = sp.uv,
            .kind = metal.Kind.text,
            .clip = clip4,
        });
    }
}

/// The x of the first glyph at or after byte `at` of the line, else its end.
fn xAt(lay: text_mod.Layout, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

/// What spans draw besides their glyphs: backgrounds (inline code, marks)
/// behind the text, underlines (links) and lines through.
fn decorations(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, lay: text_mod.Layout, start: usize, end: usize, x: f32, baseline: f32, f: text_mod.Font, clip4: [4]f32, opacity: f32) void {
    for (t.spans) |sp| {
        if (sp.end <= start or sp.start >= end) continue;
        if (sp.background == null and !sp.underline and !sp.strike) continue;
        const a = @max(sp.start, start) - start;
        const b = @min(sp.end, end) - start;
        const x0 = x + xAt(lay, a);
        const x1 = x + xAt(lay, b);
        if (x1 <= x0) continue;
        const color = sp.color orelse t.color;
        if (sp.background) |bg| push(c, out, .{
            .rect = .{ x0 - 3, baseline - f.ascent * 0.92 - 2, x1 - x0 + 6, (f.ascent + f.descent) * 0.92 + 4 },
            .color = metal.color4(bg.alpha(opacity)),
            .radius = 4,
            .clip = clip4,
        });
        if (sp.underline) push(c, out, .{
            .rect = .{ x0, baseline + 2, x1 - x0, 1 },
            .color = metal.color4(color.alpha(0.6 * opacity)),
            .clip = clip4,
        });
        if (sp.strike) push(c, out, .{
            .rect = .{ x0, baseline - f.ascent * 0.32, x1 - x0, 1 },
            .color = metal.color4(color.alpha(opacity)),
            .clip = clip4,
        });
    }
}

/// What a box with rounded corners clips is cut by its corners too: each
/// instance it clipped whose clip shares one of the box's corners (one the
/// box's own clip didn't cut off) has that corner rounded. A clip within
/// keeps its own rounding.
fn roundClip(items: []metal.Instance, box: types.Rect, visible: types.Rect, radius: f32) void {
    const near = struct {
        fn f(a: f32, b: f32) bool {
            return @abs(a - b) < 0.01;
        }
    }.f;
    const v = metal.clip4(visible);
    const b = metal.clip4(box);
    // The box's corners left whole by its own clip: 1 top left, 2 top
    // right, 4 bottom right, 8 bottom left.
    var whole: u4 = 0;
    if (near(v[0], b[0]) and near(v[1], b[1])) whole |= 1;
    if (near(v[2], b[2]) and near(v[1], b[1])) whole |= 2;
    if (near(v[2], b[2]) and near(v[3], b[3])) whole |= 4;
    if (near(v[0], b[0]) and near(v[3], b[3])) whole |= 8;
    if (whole == 0) return;
    for (items) |*i| {
        const k = i.clip;
        var corners: u4 = 0;
        if (near(k[0], v[0]) and near(k[1], v[1])) corners |= 1;
        if (near(k[2], v[2]) and near(k[1], v[1])) corners |= 2;
        if (near(k[2], v[2]) and near(k[3], v[3])) corners |= 4;
        if (near(k[0], v[0]) and near(k[3], v[3])) corners |= 8;
        corners &= whole;
        if (corners == 0) continue;
        const had = metal.clipCorners(i.clip_round);
        if (had.corners == 0) {
            i.clip_round = metal.clipRound(radius, corners);
        } else if (near(had.radius, radius)) i.clip_round = metal.clipRound(radius, had.corners | corners);
    }
}

fn paintScrollbar(c: *Context, out: *std.ArrayList(metal.Instance), n: ctx_mod.Node, visible: types.Rect, opacity: f32) void {
    const offset = c.scroll.get(n.id) orelse 0;
    // The content's height: from the first child's top to the last child's bottom.
    if (n.first_child == none) return;
    const first = c.node(n.first_child).rect;
    const last = c.node(n.last_child).rect;
    const content_h = last.y + last.h - first.y + n.style.padding.vertical();
    const view_h = n.rect.h;
    if (content_h <= view_h + 0.5) return;
    const bar_h = @max(24, view_h * view_h / content_h);
    const t = offset / (content_h - view_h);
    const y = n.rect.y + (view_h - bar_h) * std.math.clamp(t, 0, 1);
    push(c, out, .{
        .rect = .{ n.rect.x + n.rect.w - 7, y + 2, 4, bar_h - 4 },
        .color = metal.color4(c.theme.muted.alpha(0.5 * opacity)),
        .radius = 2,
        .clip = metal.clip4(visible),
    });
}
