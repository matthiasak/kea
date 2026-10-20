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
    if (out.capacity < 4096) out.ensureTotalCapacity(c.gpa, 4096) catch {};
    c.scrollbars.clearRetainingCapacity();
    c.text.images.beginPaint();
    paintNode(c, out, 0, types.Rect.infinite, 1, false);
}

fn snap(v: f32, scale: f32) f32 {
    return @round(v * scale) / scale;
}

fn push(c: *Context, out: *std.ArrayList(metal.Instance), inst: metal.Instance) void {
    out.append(c.gpa, inst) catch {};
}

fn paintNode(c: *Context, out: *std.ArrayList(metal.Instance), index: u32, clip: types.Rect, opacity_in: f32, selectable_in: bool) void {
    const n = c.node(index);
    const st = n.style;
    const selectable = (selectable_in or st.selectable) and !st.control;
    const opacity = opacity_in * st.opacity;
    const r = n.rect;
    const visible = r.intersect(clip);
    if (opacity <= 0.001) return;
    const clip4 = metal.clip4(clip);
    const sx0 = snap(r.x, c.scale);
    const sy0 = snap(r.y, c.scale);
    const sx1 = snap(r.x + r.w, c.scale);
    const sy1 = snap(r.y + r.h, c.scale);
    const rect4: [4]f32 = .{ sx0, sy0, sx1 - sx0, sy1 - sy0 };
    const rad: f32 = if (st.corner_circular) -st.radius else st.radius;
    // What the box and its subtree emit, for `Style.scale`.
    const start = out.items.len;

    if (visible.w > 0 and visible.h > 0) {
        if (st.shadow) |sh| push(c, out, .{
            .rect = .{ sx0 + sh.x, sy0 + sh.y, rect4[2], rect4[3] },
            .color = metal.color4(sh.color.alpha(opacity)),
            // A knocked out shadow is cut by the box, where it is from the shadow.
            .uv = if (sh.knockout) .{ -sh.x, -sh.y, 0, 0 } else .{ 0, 0, 0, 0 },
            .radius = rad,
            // CSS's blur radius is twice the Gaussian's standard deviation.
            .border_width = sh.blur / 2,
            .kind = if (sh.knockout) metal.Kind.shadow_out else metal.Kind.shadow,
            .clip = clip4,
        });
        // Glass takes the background's place.
        const fill: ?types.Color = if (st.glass != null) null else st.background;
        if (st.glass) |g| push(c, out, glass.instance(glass.material(g, rect4[2], rect4[3], c.theme.dark, c.scale), rect4, st.radius, clip4, opacity));
        if (fill != null or st.border != null) push(c, out, .{
            .rect = rect4,
            .color = metal.color4((fill orelse types.Color.transparent).alpha(opacity)),
            .border_color = metal.color4((st.border orelse types.Color.transparent).alpha(opacity)),
            .border_width = if (st.border != null) st.border_width else 0,
            .radius = rad,
            .clip = clip4,
        });
        switch (n.content) {
            .text => |*t| paintText(c, out, index, n, t, clip4, opacity, selectable),
            .icon => |ic| if (c.text.atlas.symbol(ic.name, ic.size, @intFromEnum(ic.weight), 0)) |sp| {
                // Centered in its box, which may be larger (a fixed frame).
                const inner = r.inset(st.padding);
                const x = snap(inner.x + (inner.w - (sp.w + 2 * sp.x)) / 2, c.scale) + sp.x;
                const y = snap(inner.y + (inner.h - (sp.h + 2 * sp.y)) / 2, c.scale) + sp.y;
                // Turned, the square it turns in, on the same centre.
                const d = if (ic.step != 0) c.text.atlas.symbol(ic.name, ic.size, @intFromEnum(ic.weight), ic.step) orelse sp else sp;
                push(c, out, .{
                    .rect = .{ x + (sp.w - d.w) / 2, y + (sp.h - d.h) / 2, d.w, d.h },
                    .color = metal.color4(ic.color.alpha(opacity)),
                    .uv = d.uv,
                    .kind = metal.Kind.text,
                    .clip = clip4,
                });
            },
            .image => |im| if (c.text.images.get(im.key, im.bytes, @intFromFloat(@max(1, @ceil(@max(rect4[2], rect4[3]) * c.scale))))) |e| push(c, out, .{
                .rect = rect4,
                .color = .{ 1, 1, 1, im.opacity * opacity },
                // A tint (alpha above 0) fills the picture's shape instead.
                .border_color = if (im.tint) |t| metal.color4(t) else .{ 0, 0, 0, 0 },
                .uv = e.uv,
                .radius = rad,
                .kind = metal.Kind.image,
                .clip = clip4,
            }),
            .none => {},
        }
    }
    if (n.interactive and visible.w > 0 and visible.h > 0) c.addHit(n.id, index, visible, false);

    var child_clip = clip;
    if (st.clip or st.scroll_x) child_clip = visible;
    if (st.scroll) {
        child_clip = visible;
        c.addHit(n.id, index, visible, true);
    }
    const first = out.items.len;
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) paintNode(c, out, child, child_clip, opacity, selectable);
    if ((st.clip or st.scroll or st.scroll_x) and st.radius > 0) roundClip(out.items[first..], r, visible, st.radius);

    if (st.scroll or st.scroll_x) @import("scroll.zig").paintScrollbars(c, out, n.*, visible, opacity);
    if (st.scale != 1) scaleItems(out.items[start..], r, st.scale, st.scale_anchor, clip4);
}

/// Maps instances around the anchor of `box` (fractions of it) by `s`,
/// still within `outer`, the clip the box was given. Glass keeps its
/// bezel and rim (`uv`, in points) as they are.
fn scaleItems(items: []metal.Instance, box: types.Rect, s: f32, anchor: types.Point, outer: [4]f32) void {
    const ax = box.x + box.w * anchor.x;
    const ay = box.y + box.h * anchor.y;
    for (items) |*i| {
        i.rect = .{ ax + (i.rect[0] - ax) * s, ay + (i.rect[1] - ay) * s, i.rect[2] * s, i.rect[3] * s };
        i.clip = .{
            @max(outer[0], ax + (i.clip[0] - ax) * s), @max(outer[1], ay + (i.clip[1] - ay) * s),
            @min(outer[2], ax + (i.clip[2] - ax) * s), @min(outer[3], ay + (i.clip[3] - ay) * s),
        };
        i.radius *= s;
        // A border's width, a shadow's blur, a pane's backdrop blur.
        i.border_width *= s;
        if (i.kind == metal.Kind.shadow_out) i.uv = .{ i.uv[0] * s, i.uv[1] * s, 0, 0 };
        const round = metal.clipCorners(i.clip_round);
        if (round.corners != 0) i.clip_round = metal.clipRound(round.radius * s, round.corners);
    }
}

fn paintText(c: *Context, out: *std.ArrayList(metal.Instance), index: u32, n: *const ctx_mod.Node, t: *const ctx_mod.Content.Text, clip4: [4]f32, opacity: f32, selectable: bool) void {
    const sel: ?Sel = if (selectable) .{ .id = n.id, .index = index, .x0 = n.rect.x, .x1 = n.rect.x + n.rect.w } else null;
    const inner = n.rect.inset(n.style.padding);
    const f = c.text.font(t.style);
    const lh = if (t.style.leading == 1) f.lineHeight() else @ceil(f.lineHeight() * t.style.leading);
    if (t.style.wrap) {
        for (t.lines, 0..) |l, i| {
            const y = inner.y + lh * @as(f32, @floatFromInt(i));
            textRun(c, out, t, l.start, l.end, inner.x, y, f, lh, clip4, opacity, sel, n.rect.x + n.rect.w);
        }
    } else {
        textRun(c, out, t, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel, n.rect.x + n.rect.w);
    }
}

/// Draws bytes [start, end) of `t`, each glyph in its span's color.
/// A selectable text: its id, its place in the tree, and the box's
/// horizontal extent.
const Sel = struct { id: u64, index: u32, x0: f32, x1: f32 };

/// `right` is the box's right edge, where a fade (`TextStyle.fade`) ends.
fn textRun(c: *Context, out: *std.ArrayList(metal.Instance), t: *const ctx_mod.Content.Text, start: usize, end: usize, x: f32, y: f32, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel, right: f32) void {
    const style = t.style;
    // Cull lines wholly above or below the clip before shaping them; a
    // selectable one still counts for where the pointer is.
    if (y > clip4[3] or y + lh < clip4[1] or x > clip4[2]) {
        if (sel) |s| if (y + lh <= c.input.mouse.y) {
            c.selection.below = .{ .id = s.id, .at = end };
            const count: u32 = @intCast(c.selection.next_order.count());
            if (c.selection.next_order.getOrPut(c.gpa, s.id) catch null) |g| if (!g.found_existing) {
                g.value_ptr.* = count;
            };
        };
        return;
    }
    const styled = t.spans.len > 0 and rich.styled(t.spans);
    const lay = t.cut_lay orelse if (styled) rich.layout(c.text, t.str[start..end], style, t.spans, start) else c.text.layout(t.str[start..end], style);
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
        if (style.fade) |fd| {
            color[3] *= std.math.clamp((right - fd.clear - (x + g.x)) / @max(fd.ramp, 0.001), 0, 1);
            if (color[3] <= 0) continue;
        }
        var uv = sp.uv;
        if (!text_mod.portable and 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2] < 0.5) {
            const du = uv[2] - uv[0];
            uv[0] += du;
            uv[2] += du;
        }
        push(c, out, .{
            .rect = .{ px / scale + sp.x, baseline - g.y + sp.y, sp.w, sp.h },
            .color = color,
            .uv = uv,
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
fn decorations(c: *Context, out: *std.ArrayList(metal.Instance), t: *const ctx_mod.Content.Text, lay: text_mod.Layout, start: usize, end: usize, x: f32, baseline: f32, f: text_mod.Font, clip4: [4]f32, opacity: f32) void {
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

