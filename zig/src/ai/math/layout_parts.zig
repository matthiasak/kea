//! Stretchy vector delimiters, accents and matrix grids for `layout.zig`.
const std = @import("std");
const ui = @import("nanoui").ui;
const tex = @import("tex.zig");
const layout = @import("layout.zig");

const Box = layout.Box;
const Ops = layout.Ops;
const L = layout.L;
const Err = layout.Err;
const MathStyle = layout.MathStyle;
const P = ui.Point;

/// `body` between `left` and `right` ("" for none): glyphs while short,
/// vector shapes symmetric about the math axis once taller than 1.25 em
/// (or `fixed` em tall when above 0, `\big` and kin).
pub fn wrap(l: L, body: Box, left: []const u8, right: []const u8, s: MathStyle, fixed: f32) Err!Box {
    const em = l.emOf(s);
    const axis = 0.25 * em;
    const span = if (fixed > 0) fixed * em else 2 * @max(body.ascent - axis, body.descent + axis);
    const stretchy = span > 1.25 * em or fixed > 1;
    var o: Ops = .{};
    var ext: Box = .{ .w = 0, .ascent = body.ascent, .descent = body.descent, .ops = &.{} };
    try one(l, &o, &ext, left, span, stretchy, s);
    try o.put(l.a, body, ext.w, 0);
    ext.w += body.w;
    try one(l, &o, &ext, right, span, stretchy, s);
    ext.ops = o.list.items;
    return ext;
}

/// Shapes in unit space (x across the delimiter from its open side, y down its span).
const paren = blk: {
    var pts: [17]P = undefined;
    for (&pts, 0..) |*p, i| {
        const y = @as(f32, @floatFromInt(i)) / 16;
        p.* = .{ .x = 0.9 - 0.72 * @sin(std.math.pi * y), .y = y };
    }
    break :blk pts;
};
const brace = [_]P{
    .{ .x = 0.92, .y = 0 },    .{ .x = 0.66, .y = 0.025 }, .{ .x = 0.54, .y = 0.09 },  .{ .x = 0.52, .y = 0.4 },
    .{ .x = 0.42, .y = 0.47 }, .{ .x = 0.1, .y = 0.5 },    .{ .x = 0.42, .y = 0.53 },  .{ .x = 0.52, .y = 0.6 },
    .{ .x = 0.54, .y = 0.91 }, .{ .x = 0.66, .y = 0.975 }, .{ .x = 0.92, .y = 1 },
};
const angle = [_]P{ .{ .x = 0.85, .y = 0 }, .{ .x = 0.15, .y = 0.5 }, .{ .x = 0.85, .y = 1 } };
// Brackets as polylines with round joins: [ ⌊ ⌈.
const bracket = [_]P{ .{ .x = 0.9, .y = 0 }, .{ .x = 0.25, .y = 0 }, .{ .x = 0.25, .y = 1 }, .{ .x = 0.9, .y = 1 } };
const floor = [_]P{ .{ .x = 0.25, .y = 0 }, .{ .x = 0.25, .y = 1 }, .{ .x = 0.9, .y = 1 } };
const ceil = [_]P{ .{ .x = 0.9, .y = 0 }, .{ .x = 0.25, .y = 0 }, .{ .x = 0.25, .y = 1 } };

const Shape = struct { pts: []const P, w: f32, close: bool };

fn shapeOf(d: []const u8) ?Shape {
    const eq = std.mem.eql;
    if (eq(u8, d, "(")) return .{ .pts = &paren, .w = 0.34, .close = false };
    if (eq(u8, d, ")")) return .{ .pts = &paren, .w = 0.34, .close = true };
    if (eq(u8, d, "[")) return .{ .pts = &bracket, .w = 0.3, .close = false };
    if (eq(u8, d, "]")) return .{ .pts = &bracket, .w = 0.3, .close = true };
    if (eq(u8, d, "{")) return .{ .pts = &brace, .w = 0.44, .close = false };
    if (eq(u8, d, "}")) return .{ .pts = &brace, .w = 0.44, .close = true };
    if (eq(u8, d, "⟨")) return .{ .pts = &angle, .w = 0.38, .close = false };
    if (eq(u8, d, "⟩")) return .{ .pts = &angle, .w = 0.38, .close = true };
    if (eq(u8, d, "⌊")) return .{ .pts = &floor, .w = 0.32, .close = false };
    if (eq(u8, d, "⌋")) return .{ .pts = &floor, .w = 0.32, .close = true };
    if (eq(u8, d, "⌈")) return .{ .pts = &ceil, .w = 0.32, .close = false };
    if (eq(u8, d, "⌉")) return .{ .pts = &ceil, .w = 0.32, .close = true };
    return null;
}

/// One delimiter at `ext.w`, widening `ext` and growing its extent.
fn one(l: L, o: *Ops, ext: *Box, d: []const u8, span: f32, stretchy: bool, s: MathStyle) Err!void {
    const em = l.emOf(s);
    if (d.len == 0) {
        ext.w += 0.12 * em; // TeX's null delimiter space
        return;
    }
    const axis = 0.25 * em;
    if (!stretchy) {
        const g = try l.glyph(d, l.size(s));
        try o.put(l.a, g, ext.w, 0);
        ext.w += g.w;
        ext.ascent = @max(ext.ascent, g.ascent);
        ext.descent = @max(ext.descent, g.descent);
        return;
    }
    const top = -axis - span / 2;
    const sw = @max(1.1 * l.ruleT(s), 0.06 * em);
    const pad = 0.05 * em;
    ext.ascent = @max(ext.ascent, -top);
    ext.descent = @max(ext.descent, top + span);
    const bar = std.mem.eql(u8, d, "|") or std.mem.eql(u8, d, "∣");
    const dbl = std.mem.eql(u8, d, "‖") or std.mem.eql(u8, d, "∥");
    if (bar or dbl) {
        const xs: []const f32 = if (bar) &.{0.12} else &.{ 0.1, 0.3 };
        for (xs) |x| try o.add(l.a, .{ .rule = .{ .x = ext.w + pad + x * em - sw / 2, .y = top, .w = sw, .h = span } });
        ext.w += 2 * pad + @as(f32, if (bar) 0.24 else 0.4) * em;
        return;
    }
    const shape = shapeOf(d) orelse { // any other delimiter: its glyph scaled to the span, centred on the axis
        const g = try l.glyph(d, l.size(s) * span / em);
        const dy = (g.ascent - g.descent) / 2 - axis;
        try o.put(l.a, g, ext.w, dy);
        ext.w += g.w;
        return;
    };
    const w = @min(shape.w * em + 0.04 * span, 2 * shape.w * em);
    var pts = try l.a.alloc(P, shape.pts.len);
    for (shape.pts, 0..) |p, i| {
        const ux = if (shape.close) 1 - p.x else p.x;
        pts[i] = .{ .x = ext.w + pad + ux * w, .y = top + p.y * span };
    }
    try o.poly(l.a, pts, sw);
    ext.w += w + 2 * pad;
}

pub fn accent(l: L, ac: tex.Expr.Accent, s: MathStyle) Err!Box {
    const xarrow = ac.kind == .xrightarrow or ac.kind == .xleftarrow;
    const body = try l.node(ac.body.*, if (xarrow) layout.scriptStyle(s) else s);
    const em = l.emOf(s);
    const t = l.ruleT(s);
    var o: Ops = .{};
    if (xarrow) {
        const axis = 0.25 * em;
        const aw = @max(body.w + 0.6 * em, 1.4 * em);
        const m = 0.08 * em;
        const y = -axis;
        const tip: f32 = if (ac.kind == .xrightarrow) m + aw else m;
        const dir: f32 = if (ac.kind == .xrightarrow) -1 else 1;
        try o.add(l.a, .{ .line = .{ .a = .{ .x = m, .y = y }, .b = .{ .x = m + aw, .y = y }, .width = t } });
        try o.poly(l.a, &.{ .{ .x = tip + dir * 0.2 * em, .y = y - 0.13 * em }, .{ .x = tip, .y = y }, .{ .x = tip + dir * 0.2 * em, .y = y + 0.13 * em } }, t);
        const by = y - 0.16 * em - body.descent;
        try o.put(l.a, body, m + (aw - body.w) / 2, by);
        return .{ .w = aw + 2 * m, .ascent = @max(axis + 0.15 * em, body.ascent - by), .descent = 0, .ops = o.list.items };
    }
    if (ac.kind == .boxed) {
        const pad = 0.2 * em;
        const w = body.w + 2 * pad;
        const top = -(body.ascent + pad);
        const h = body.height() + 2 * pad;
        try o.put(l.a, body, pad, 0);
        try o.add(l.a, .{ .rule = .{ .x = 0, .y = top, .w = w, .h = t } });
        try o.add(l.a, .{ .rule = .{ .x = 0, .y = top + h - t, .w = w, .h = t } });
        try o.add(l.a, .{ .rule = .{ .x = 0, .y = top, .w = t, .h = h } });
        try o.add(l.a, .{ .rule = .{ .x = w - t, .y = top, .w = t, .h = h } });
        return .{ .w = w, .ascent = -top, .descent = body.descent + pad, .ops = o.list.items };
    }
    const mark_w: f32 = switch (ac.kind) {
        .hat => std.math.clamp(body.w * 0.7, 0.35 * em, 0.6 * em),
        .tilde => std.math.clamp(body.w * 0.8, 0.4 * em, 0.6 * em),
        .vec => @max(body.w, 0.45 * em),
        .bar => @max(body.w * 0.9, 0.3 * em),
        .dot => 0.12 * em,
        .ddot => 0.32 * em,
        else => body.w, // widehat, widetilde, overline, underline, braces
    };
    const w = @max(body.w, mark_w);
    const cx = w / 2;
    const x0 = cx - mark_w / 2;
    const x1 = cx + mark_w / 2;
    try o.put(l.a, body, (w - body.w) / 2, 0);
    var asc = body.ascent;
    var desc = body.descent;
    const y = -(body.ascent + 0.08 * em); // the mark's foot
    switch (ac.kind) {
        .bar, .overline => {
            try o.add(l.a, .{ .rule = .{ .x = x0, .y = y - t, .w = mark_w, .h = t } });
            asc = -y + t + 0.04 * em;
        },
        .underline => {
            const uy = body.descent + 0.1 * em;
            try o.add(l.a, .{ .rule = .{ .x = x0, .y = uy, .w = mark_w, .h = t } });
            desc = uy + t + 0.04 * em;
        },
        .hat, .widehat => {
            const h: f32 = if (ac.kind == .hat) 0.14 * em else 0.2 * em;
            try o.poly(l.a, &.{ .{ .x = x0, .y = y }, .{ .x = cx, .y = y - h }, .{ .x = x1, .y = y } }, t);
            asc = -y + h + t;
        },
        .tilde, .widetilde => {
            const h = 0.1 * em;
            var pts: [9]P = undefined;
            for (&pts, 0..) |*p, i| {
                const u = @as(f32, @floatFromInt(i)) / 8;
                p.* = .{ .x = x0 + u * mark_w, .y = y - h / 2 - (h / 2) * @sin(2 * std.math.pi * u) };
            }
            try o.poly(l.a, &pts, t);
            asc = -y + h + t;
        },
        .vec => {
            const vy = y - 0.06 * em;
            try o.add(l.a, .{ .line = .{ .a = .{ .x = x0, .y = vy }, .b = .{ .x = x1, .y = vy }, .width = t } });
            try o.poly(l.a, &.{ .{ .x = x1 - 0.14 * em, .y = vy - 0.09 * em }, .{ .x = x1, .y = vy }, .{ .x = x1 - 0.14 * em, .y = vy + 0.09 * em } }, t);
            asc = -vy + 0.09 * em + t;
        },
        .dot, .ddot => {
            const dy = y - 0.06 * em;
            const xs: []const f32 = if (ac.kind == .dot) &.{cx} else &.{ cx - 0.1 * em, cx + 0.1 * em };
            for (xs) |x| try o.add(l.a, .{ .line = .{ .a = .{ .x = x - 0.005 * em, .y = dy }, .b = .{ .x = x + 0.005 * em, .y = dy }, .width = 0.1 * em } });
            asc = -dy + 0.06 * em;
        },
        .overbrace, .underbrace => {
            const h = 0.3 * em;
            const over = ac.kind == .overbrace;
            const base_y = if (over) y - h else body.descent + 0.1 * em;
            var pts = try l.a.alloc(P, brace.len);
            for (brace, 0..) |p, i| pts[i] = .{ .x = x0 + p.y * mark_w, .y = base_y + (if (over) p.x else 1 - p.x) * h };
            try o.poly(l.a, pts, t);
            if (over) asc = -base_y + t else desc = base_y + h + t;
        },
        .xrightarrow, .xleftarrow, .boxed => unreachable,
    }
    return .{ .w = w, .ascent = asc, .descent = desc, .ops = o.list.items };
}

pub fn matrix(l: L, m: tex.Expr.Matrix, s: MathStyle) Err!Box {
    const em = l.emOf(s);
    const axis = 0.25 * em;
    const display_rows = m.kind == .aligned or m.kind == .gathered;
    const cs: MathStyle = if (display_rows) s else if (s == .display) .text else s;
    var cols: usize = 0;
    for (m.rows) |r| cols = @max(cols, r.len);
    const boxes = try l.a.alloc([]Box, m.rows.len);
    const col_w = try l.a.alloc(f32, cols);
    @memset(col_w, 0);
    const row_asc = try l.a.alloc(f32, m.rows.len);
    const row_desc = try l.a.alloc(f32, m.rows.len);
    for (m.rows, 0..) |r, i| {
        boxes[i] = try l.a.alloc(Box, r.len);
        row_asc[i] = 0.7 * l.emOf(cs); // TeX's array strut
        row_desc[i] = 0.3 * l.emOf(cs);
        for (r, 0..) |cell, j| {
            // An aligned column after `&` starts as if after `{}`, so `&=` keeps its space.
            const lead: ?tex.AtomKind = if (m.kind == .aligned and j % 2 == 1) .ord else null;
            const b = if (cell == .row) try l.row(cell.row, cs, lead) else try l.node(cell, cs);
            boxes[i][j] = b;
            col_w[j] = @max(col_w[j], b.w);
            row_asc[i] = @max(row_asc[i], b.ascent);
            row_desc[i] = @max(row_desc[i], b.descent);
        }
    }
    const row_gap: f32 = if (display_rows) 0.25 * em else 0.2 * em;
    var y: f32 = 0;
    const ys = try l.a.alloc(f32, m.rows.len);
    for (ys, 0..) |*yi, i| {
        if (i > 0) y += row_desc[i - 1] + row_gap;
        y += row_asc[i];
        yi.* = y;
    }
    const total = if (m.rows.len == 0) 0 else y + row_desc[m.rows.len - 1];
    // Centred on the axis, but one aligned or gathered line keeps its baseline.
    const dy = if (display_rows and m.rows.len == 1) -ys[0] else -axis - total / 2;
    const pad: f32 = switch (m.kind) {
        .pmatrix, .bmatrix, .Bmatrix, .vmatrix, .Vmatrix, .cases => 0.15 * em,
        else => 0,
    };
    var o: Ops = .{};
    var x = pad;
    for (0..cols) |j| {
        if (j > 0) x += switch (m.kind) {
            .aligned => if (j % 2 == 1) 0 else 1.0 * em,
            .cases => 1.0 * em,
            else => 0.8 * em,
        };
        for (boxes, ys) |r, yi| {
            if (j >= r.len) continue;
            const b = r[j];
            const left = m.kind == .cases or (m.kind == .aligned and j % 2 == 1);
            const right = m.kind == .aligned and j % 2 == 0;
            const cx = if (left) x else if (right) x + col_w[j] - b.w else x + (col_w[j] - b.w) / 2;
            try o.put(l.a, b, cx, yi + dy);
        }
        x += col_w[j];
    }
    const grid: Box = .{ .w = x + pad, .ascent = -dy, .descent = total + dy, .ops = o.list.items };
    const lr: [2][]const u8 = switch (m.kind) {
        .pmatrix => .{ "(", ")" },
        .bmatrix => .{ "[", "]" },
        .Bmatrix => .{ "{", "}" },
        .vmatrix => .{ "|", "|" },
        .Vmatrix => .{ "‖", "‖" },
        .cases => .{ "{", "" },
        else => return grid,
    };
    return wrap(l, grid, lr[0], lr[1], s, 0);
}
