//! TeX-style box layout of a `tex.Expr` into theme-independent draw ops:
//! glyph runs (STIX Two Math via `TextStyle.math`), rules and SDF line
//! segments, all drawn on the GPU through `ui.Canvas` (`emit`).
//! Coordinates: x from the box's left, y down from its baseline (y = 0).
const std = @import("std");
const ui = @import("nanoui").ui;
const tex = @import("tex.zig");
const symbols = @import("symbols.zig");
const parts = @import("layout_parts.zig");

pub const TextSystem = @typeInfo(@FieldType(ui.Context, "text")).pointer.child;
pub const MathStyle = tex.MathStyle;
pub const Tone = enum { ink, muted };

pub const DrawOp = union(enum) {
    glyphs: struct { x: f32, baseline: f32, str: []const u8, style: ui.TextStyle, tone: Tone = .ink },
    rule: struct { x: f32, y: f32, w: f32, h: f32, tone: Tone = .ink },
    line: struct { a: ui.Point, b: ui.Point, width: f32, tone: Tone = .ink },

    pub fn shifted(op: DrawOp, dx: f32, dy: f32) DrawOp {
        return switch (op) {
            .glyphs => |g| blk: {
                var o = g;
                o.x += dx;
                o.baseline += dy;
                break :blk .{ .glyphs = o };
            },
            .rule => |r| .{ .rule = .{ .x = r.x + dx, .y = r.y + dy, .w = r.w, .h = r.h, .tone = r.tone } },
            .line => |l| .{ .line = .{ .a = .{ .x = l.a.x + dx, .y = l.a.y + dy }, .b = .{ .x = l.b.x + dx, .y = l.b.y + dy }, .width = l.width, .tone = l.tone } },
        };
    }
};

pub const Box = struct {
    w: f32,
    /// Above the baseline (the top is y = -ascent).
    ascent: f32,
    /// Below the baseline (the bottom is y = +descent).
    descent: f32,
    ops: []const DrawOp,

    pub const empty: Box = .{ .w = 0, .ascent = 0, .descent = 0, .ops = &.{} };

    pub fn height(b: Box) f32 {
        return b.ascent + b.descent;
    }
};

pub const Err = std.mem.Allocator.Error;

/// Lays `expr` out in `style` at `base_size` points (before the text
/// system's zoom; measured extents include it). Glyph strings in the ops
/// are `expr`'s, so the box lives as long as the tree.
pub fn layout(a: std.mem.Allocator, ts: *TextSystem, expr: tex.Expr, style: MathStyle, base_size: f32) Err!Box {
    const l: L = .{ .a = a, .ts = ts, .base = base_size };
    return l.node(expr, style);
}

/// Draws `box` with its baseline's left end at (`x`, `baseline_y`).
pub fn emit(cv: *ui.Canvas, box: Box, x: f32, baseline_y: f32, ink: ui.Color, muted: ui.Color, alpha: f32) void {
    for (box.ops) |op| switch (op) {
        .glyphs => |g| {
            var st = g.style;
            st.color = (if (g.tone == .ink) ink else muted).alpha(alpha);
            cv.text(.{ .x = x + g.x, .y = baseline_y + g.baseline }, g.str, st);
        },
        .rule => |r| cv.rect(.{ .x = x + r.x, .y = baseline_y + r.y, .w = r.w, .h = r.h }, (if (r.tone == .ink) ink else muted).alpha(alpha), 0),
        .line => |ln| cv.line(
            .{ .x = x + ln.a.x, .y = baseline_y + ln.a.y },
            .{ .x = x + ln.b.x, .y = baseline_y + ln.b.y },
            .{ .width = ln.width, .color = (if (ln.tone == .ink) ink else muted).alpha(alpha) },
        ),
    };
}

pub fn scale(s: MathStyle) f32 {
    return switch (s) {
        .display => 1.05,
        .text => 1.0,
        .script => 0.72,
        .scriptscript => 0.56,
    };
}

pub fn scriptStyle(s: MathStyle) MathStyle {
    return switch (s) {
        .display, .text => .script,
        .script, .scriptscript => .scriptscript,
    };
}

fn fracChild(s: MathStyle) MathStyle {
    return switch (s) {
        .display => .text,
        .text => .script,
        .script, .scriptscript => .scriptscript,
    };
}

/// Draw ops gathered from placed boxes.
pub const Ops = struct {
    list: std.ArrayList(DrawOp) = .empty,

    pub fn put(o: *Ops, a: std.mem.Allocator, b: Box, dx: f32, dy: f32) Err!void {
        try o.list.ensureUnusedCapacity(a, b.ops.len);
        for (b.ops) |op| o.list.appendAssumeCapacity(op.shifted(dx, dy));
    }

    pub fn add(o: *Ops, a: std.mem.Allocator, op: DrawOp) Err!void {
        try o.list.append(a, op);
    }

    /// A polyline of line segments through `pts`.
    pub fn poly(o: *Ops, a: std.mem.Allocator, pts: []const ui.Point, width: f32) Err!void {
        for (pts[0 .. pts.len - 1], pts[1..]) |p, q| try o.add(a, .{ .line = .{ .a = p, .b = q, .width = width } });
    }
};

pub const L = struct {
    a: std.mem.Allocator,
    ts: *TextSystem,
    base: f32,

    /// The font size of `s`, in points before zoom.
    pub fn size(l: L, s: MathStyle) f32 {
        return l.base * scale(s);
    }

    /// One em of `s` as measured (zoomed) on screen.
    pub fn emOf(l: L, s: MathStyle) f32 {
        return l.size(s) * l.ts.zoom;
    }

    pub fn ruleT(l: L, s: MathStyle) f32 {
        return @max(1.0, 0.055 * l.emOf(s));
    }

    pub fn node(l: L, e: tex.Expr, s: MathStyle) Err!Box {
        return switch (e) {
            .row => |items| l.row(items, s, null),
            .sym => |sym| l.symbol(sym, s),
            .scripts => |sc| l.scripts(sc, s),
            .frac => |f| l.frac(f, s),
            .sqrt => |r| l.sqrt(r, s),
            .delim => |d| parts.wrap(l, try l.node(d.body.*, s), d.left, d.right, s, d.fixed_scale),
            .accent => |ac| parts.accent(l, ac, s),
            .matrix => |m| parts.matrix(l, m, s),
            .space => |w| .{ .w = w * l.emOf(s), .ascent = 0, .descent = 0, .ops = &.{} },
            .style_change => Box.empty,
            .phantom => |p| blk: {
                var b = try l.node(p.*, s);
                b.ops = &.{};
                break :blk b;
            },
        };
    }

    /// `str` in one run at `sz` points, its extent from `symbols.metrics`.
    pub fn glyph(l: L, str: []const u8, sz: f32) Err!Box {
        if (str.len == 0) return Box.empty;
        const style: ui.TextStyle = .{ .size = sz, .math = true };
        const m = symbols.metrics(str);
        const e = sz * l.ts.zoom;
        const ops = try l.a.alloc(DrawOp, 1);
        ops[0] = .{ .glyphs = .{ .x = 0, .baseline = 0, .str = str, .style = style } };
        return .{ .w = l.ts.layout(str, style).width, .ascent = m.asc * e, .descent = m.desc * e, .ops = ops };
    }

    fn symbol(l: L, sym: tex.Expr.Sym, s: MathStyle) Err!Box {
        const big = isBigGlyph(sym);
        const grow: f32 = if (!big) 1 else switch (s) {
            .display => 1.45,
            .text => 1.18,
            else => 1,
        };
        var b = try l.glyph(sym.text, l.size(s) * grow);
        if (big) { // centered on the math axis
            const dy = (b.ascent - b.descent) / 2 - 0.25 * l.emOf(s);
            b.ops = try shiftAll(l.a, b.ops, 0, dy);
            b.ascent -= dy;
            b.descent += dy;
        }
        return b;
    }

    /// Children side by side with TeX's inter-atom spacing; `lead` is the
    /// class of what comes before the first (an aligned column's `{}`).
    pub fn row(l: L, items: []const tex.Expr, s0: MathStyle, lead: ?tex.AtomKind) Err!Box {
        const boxes = try l.a.alloc(Box, items.len);
        const kinds = try l.a.alloc(?tex.AtomKind, items.len);
        const styles = try l.a.alloc(MathStyle, items.len);
        var s = s0;
        for (items, 0..) |it, i| {
            if (it == .style_change) s = it.style_change;
            styles[i] = s;
            boxes[i] = try l.node(it, s);
            kinds[i] = kindOf(it);
        }
        // A binary operator with nothing to bind on its left or right is ordinary (`-x`, `(+`, `a + =`).
        var prev = lead;
        for (kinds) |*k| if (k.*) |kind| {
            if (kind == .bin and (prev == null or switch (prev.?) {
                .bin, .op, .big_op, .rel, .open, .punct => true,
                else => false,
            })) k.* = .ord;
            prev = k.*;
        };
        var next: ?tex.AtomKind = null;
        var i = kinds.len;
        while (i > 0) {
            i -= 1;
            const kind = kinds[i] orelse continue;
            if (kind == .bin and (next == null or next.? == .rel or next.? == .close or next.? == .punct)) kinds[i] = .ord;
            next = kinds[i];
        }
        var o: Ops = .{};
        var x: f32 = 0;
        var asc: f32 = 0;
        var desc: f32 = 0;
        prev = lead;
        for (boxes, kinds, styles) |b, k, st| {
            if (k) |kind| {
                if (prev) |p| x += spaceBetween(p, kind, st == .script or st == .scriptscript) * l.emOf(st);
                prev = kind;
            }
            try o.put(l.a, b, x, 0);
            x += b.w;
            asc = @max(asc, b.ascent);
            desc = @max(desc, b.descent);
        }
        return .{ .w = @max(x, 0), .ascent = asc, .descent = desc, .ops = o.list.items };
    }

    fn scripts(l: L, sc: tex.Expr.Scripts, s: MathStyle) Err!Box {
        const base = try l.node(sc.base.*, s);
        const ss = scriptStyle(s);
        const sup: ?Box = if (sc.sup) |e| try l.node(e.*, ss) else null;
        const sub: ?Box = if (sc.sub) |e| try l.node(e.*, ss) else null;
        const em = l.emOf(s);
        const b = sc.base.*;
        const braced = b == .accent and (b.accent.kind == .overbrace or b.accent.kind == .underbrace);
        const big = b == .sym and b.sym.kind == .big_op;
        const integral = b == .sym and isIntegral(b.sym.text);
        if (sc.limits == .above_below or (sc.limits == .auto and ((s == .display and big and !integral) or braced))) {
            var o: Ops = .{};
            const w = @max(base.w, @max(if (sup) |p| p.w else 0, if (sub) |p| p.w else 0));
            try o.put(l.a, base, (w - base.w) / 2, 0);
            var asc = base.ascent;
            var desc = base.descent;
            if (sup) |p| {
                const y = -(base.ascent + 0.12 * em + p.descent);
                try o.put(l.a, p, (w - p.w) / 2, y);
                asc = p.ascent - y + 0.04 * em;
            }
            if (sub) |p| {
                const y = base.descent + 0.14 * em + p.ascent;
                try o.put(l.a, p, (w - p.w) / 2, y);
                desc = y + p.descent + 0.04 * em;
            }
            return .{ .w = w, .ascent = asc, .descent = desc, .ops = o.list.items };
        }
        var u: f32 = if (sup) |p| @max(0.42 * em, @max(base.ascent - 0.28 * em, p.descent + 0.11 * em)) else 0;
        var v: f32 = if (sub) |p| @max(0.22 * em, base.descent + 0.2 * p.ascent) else 0;
        if (sup != null and sub != null) {
            v = @max(v, 0.25 * em);
            const clash = 0.16 * em - ((u - sup.?.descent) - (sub.?.ascent - v));
            if (clash > 0) {
                u += clash / 2;
                v += clash / 2;
            }
        }
        // Italic correction: a slanted base's superscript sits out to the right, an integral's subscript tucks under.
        const kern: f32 = if (b == .sym and b.sym.font == .math_normal) 0.05 * em else 0;
        const tuck: f32 = if (integral) 0.35 * base.w else 0;
        var o: Ops = .{};
        try o.put(l.a, base, 0, 0);
        var right = base.w;
        var asc = base.ascent;
        var desc = base.descent;
        if (sup) |p| {
            try o.put(l.a, p, base.w + kern, -u);
            right = @max(right, base.w + kern + p.w);
            asc = @max(asc, u + p.ascent);
        }
        if (sub) |p| {
            try o.put(l.a, p, base.w - tuck, v);
            right = @max(right, base.w - tuck + p.w);
            desc = @max(desc, v + p.descent);
        }
        return .{ .w = right + 0.05 * em, .ascent = asc, .descent = desc, .ops = o.list.items };
    }

    fn frac(l: L, f: tex.Expr.Frac, s: MathStyle) Err!Box {
        const own: MathStyle = switch (f.style) {
            .auto => s,
            .display => .display,
            .text => if (s == .display) .text else s,
        };
        const cs = fracChild(own);
        const num = try l.node(f.num.*, cs);
        const den = try l.node(f.den.*, cs);
        const em = l.emOf(own);
        const axis = 0.25 * em;
        const t: f32 = if (f.bar) l.ruleT(own) else 0;
        const disp = own == .display;
        const gap: f32 = if (!f.bar) (if (disp) 0.35 * em else 0.15 * em) else if (disp) @max(3 * t, 0.15 * em) else @max(1.5 * t, 0.09 * em);
        const u = @max(if (disp) 0.677 * em else 0.394 * em, axis + t / 2 + gap + num.descent);
        const v = @max(if (disp) 0.686 * em else 0.345 * em, den.ascent + gap + t / 2 - axis);
        const w = @max(num.w, den.w) + 0.24 * em;
        var o: Ops = .{};
        try o.put(l.a, num, (w - num.w) / 2, -u);
        try o.put(l.a, den, (w - den.w) / 2, v);
        if (f.bar) try o.add(l.a, .{ .rule = .{ .x = 0.08 * em, .y = -axis - t / 2, .w = w - 0.16 * em, .h = t } });
        const b: Box = .{ .w = w, .ascent = u + num.ascent, .descent = v + den.descent, .ops = o.list.items };
        return if (f.bar) b else parts.wrap(l, b, "(", ")", own, 0);
    }

    fn sqrt(l: L, r: tex.Expr.Sqrt, s: MathStyle) Err!Box {
        const body = try l.node(r.body.*, s);
        const em = l.emOf(s);
        const t = l.ruleT(s);
        const top_y = @max(body.ascent, 0.5 * em) + t + 0.1 * em; // the vinculum's underside
        const yb = @max(body.descent, 0.05 * em) + 0.06 * em; // the check's foot
        const yt = -top_y - t / 2; // the vinculum's centre line
        const h = yb - yt;
        const cw = @min(0.5 * em + 0.08 * h, 1.1 * em);
        // The check: a short rising tick, a heavy downstroke, the long rise to the vinculum.
        const p0: ui.Point = .{ .x = 0.04 * em, .y = yb - @min(0.45 * h, 0.5 * em) };
        const p1: ui.Point = .{ .x = 0.24 * cw, .y = p0.y - 0.06 * em };
        const p2: ui.Point = .{ .x = 0.5 * cw, .y = yb };
        const p3: ui.Point = .{ .x = cw, .y = yt };
        var dx: f32 = 0;
        var index: ?Box = null;
        if (r.index) |ie| {
            const ib = try l.node(ie.*, .scriptscript);
            dx = @max(0, ib.w - 0.55 * cw);
            index = ib;
        }
        var o: Ops = .{};
        try o.add(l.a, .{ .line = .{ .a = p0, .b = p1, .width = 0.9 * t } });
        try o.add(l.a, .{ .line = .{ .a = p1, .b = p2, .width = 1.6 * t } });
        try o.add(l.a, .{ .line = .{ .a = p2, .b = p3, .width = t } });
        try o.add(l.a, .{ .rule = .{ .x = cw, .y = -top_y - t, .w = body.w + 0.12 * em, .h = t } });
        try o.put(l.a, body, cw + 0.06 * em, 0);
        var asc = top_y + t + 0.04 * em;
        if (index) |ib| { // perched on the check's left shoulder, the rest moved right to make room
            const placed: Box = .{ .w = 0, .ascent = 0, .descent = 0, .ops = o.list.items };
            o = .{};
            try o.put(l.a, placed, dx, 0);
            const y = p0.y - 0.12 * em - ib.descent;
            try o.put(l.a, ib, dx + 0.55 * cw - ib.w, y);
            asc = @max(asc, ib.ascent - y);
        }
        return .{ .w = dx + cw + body.w + 0.16 * em, .ascent = asc, .descent = @max(body.descent, yb), .ops = o.list.items };
    }
};

pub fn shiftAll(a: std.mem.Allocator, ops: []const DrawOp, dx: f32, dy: f32) Err![]const DrawOp {
    const out = try a.alloc(DrawOp, ops.len);
    for (ops, out) |op, *d| d.* = op.shifted(dx, dy);
    return out;
}

fn isIntegral(text: []const u8) bool {
    return std.mem.eql(u8, text, "∫") or std.mem.eql(u8, text, "∬") or std.mem.eql(u8, text, "∭") or std.mem.eql(u8, text, "∮");
}

/// A big operator drawn as an enlarged glyph (`∑`), not a word (`lim`).
fn isBigGlyph(sym: tex.Expr.Sym) bool {
    return sym.kind == .big_op and sym.text.len > 0 and sym.text[0] >= 0x80;
}

/// The atom class for spacing (null: no atom, like a space).
pub fn kindOf(e: tex.Expr) ?tex.AtomKind {
    return switch (e) {
        .sym => |s| s.kind,
        .scripts => |sc| kindOf(sc.base.*) orelse .ord,
        .space, .style_change => null,
        .accent => |ac| if (ac.kind == .xrightarrow or ac.kind == .xleftarrow) .rel else .ord,
        .delim => |d| if (d.fixed_scale > 0 and d.right.len == 0) .open else if (d.fixed_scale > 0 and d.left.len == 0) .close else .ord,
        else => .ord,
    };
}

/// TeX's spacing between atoms, in em (thin 0.17, medium 0.22, thick 0.28).
pub fn spaceBetween(l: tex.AtomKind, r: tex.AtomKind, script: bool) f32 {
    const op = struct {
        fn f(k: tex.AtomKind) bool {
            return k == .op or k == .big_op;
        }
    }.f;
    if (l == .bin or r == .bin) return if (script) 0 else 0.22;
    if (l == .rel or r == .rel) {
        if (l == r or l == .open or r == .close or r == .punct) return 0;
        return if (script) 0 else 0.28;
    }
    if (l == .punct) return if (script) 0 else 0.17;
    if (op(r) and (l == .ord or l == .close or op(l))) return 0.17;
    if (op(l) and (r == .ord or op(r))) return 0.17;
    return 0;
}

test {
    _ = @import("layout_test.zig");
}
