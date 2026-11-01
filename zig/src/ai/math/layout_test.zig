const std = @import("std");
const testing = std.testing;
const ui = @import("nanoui").ui;
const tex = @import("tex.zig");
const layout = @import("layout.zig");

const Box = layout.Box;
const size: f32 = 14;

const Blank = struct {
    box: ?Box = null,
    texts: usize = 0,
    shapes: usize = 0,

    fn view(s: *Blank, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        const b = s.box orelse return;
        const cv = ui.canvas(c, .{ .width = .{ .px = b.w + 4 }, .height = .{ .px = b.height() + 4 } });
        layout.emit(cv, b, 2, 2 + b.ascent, .{ .r = 1 }, .{ .g = 1 }, 1);
        s.texts = cv.texts.items.len;
        s.shapes = cv.shapes.items.len;
    }
};

const Rig = struct {
    t: ui.Tester = undefined,
    arena: std.heap.ArenaAllocator,
    blank: Blank = .{},

    fn init(r: *Rig) !void {
        r.* = .{ .arena = .init(testing.allocator) };
        try r.t.init(testing.allocator, .init(&r.blank, Blank.view), .{});
    }

    fn deinit(r: *Rig) void {
        r.t.deinit();
        r.arena.deinit();
    }

    fn lay(r: *Rig, src: []const u8, style: layout.MathStyle) !Box {
        const a = r.arena.allocator();
        const b = try layout.layout(a, &r.t.text, try tex.parse(a, src), style, size);
        sane(b) catch |e| {
            std.debug.print("ops outside the box laying out \"{s}\"\n", .{src});
            return e;
        };
        return b;
    }

    fn width(r: *Rig, g: Glyph) f32 {
        return r.t.text.layout(g.str, g.style).width;
    }
};

const Glyph = @FieldType(layout.DrawOp, "glyphs");

/// The `n`th glyph run drawing `str`.
fn glyph(b: Box, str: []const u8, n: usize) !Glyph {
    var seen: usize = 0;
    for (b.ops) |op| if (op == .glyphs and std.mem.eql(u8, op.glyphs.str, str)) {
        if (seen == n) return op.glyphs;
        seen += 1;
    };
    std.debug.print("no glyph {s} #{d}\n", .{ str, n });
    return error.TestUnexpectedResult;
}

fn count(b: Box, tag: std.meta.Tag(layout.DrawOp)) usize {
    var n: usize = 0;
    for (b.ops) |op| n += @intFromBool(op == tag);
    return n;
}

/// Every op within the box (glyph pens and baselines; rules and lines whole).
fn sane(b: Box) !void {
    const slack = 1.0;
    try testing.expect(b.w >= 0 and b.ascent >= 0 and b.descent >= 0);
    try testing.expect(b.height() < 12 * size);
    for (b.ops) |op| switch (op) {
        .glyphs => |g| {
            try testing.expect(g.x >= -slack and g.x <= b.w + slack);
            try testing.expect(g.baseline >= -b.ascent - slack and g.baseline <= b.descent + slack);
        },
        .rule => |r| {
            try testing.expect(r.x >= -slack and r.x + r.w <= b.w + slack);
            try testing.expect(r.y >= -b.ascent - slack and r.y + r.h <= b.descent + slack);
        },
        .line => |l| for ([_]ui.Point{ l.a, l.b }) |p| {
            try testing.expect(p.x >= -slack and p.x <= b.w + slack);
            try testing.expect(p.y >= -b.ascent - slack and p.y <= b.descent + slack);
        },
    };
}

test "softmax: numerator above the bar above the denominator; display limits above and below the sum" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const b = try r.lay("p_i = \\frac{e^{z_i}}{\\sum_{j=1}^K e^{z_j}}", .display);
    try testing.expectEqual(@as(usize, 1), count(b, .rule));
    var bar: f32 = 0;
    for (b.ops) |op| if (op == .rule) {
        bar = op.rule.y;
    };
    const num = try glyph(b, "𝑒", 0);
    const den = try glyph(b, "𝑒", 1);
    try testing.expect(num.baseline < bar and bar < den.baseline);
    try testing.expect(b.ascent > size and b.descent > size);
    // A display fraction's denominator is text style (as in TeX): the sum's limits at its side.
    const dsum = try glyph(b, "∑", 0);
    try testing.expect((try glyph(b, "𝐾", 0)).x >= dsum.x + r.width(dsum) - 0.5);

    const d = try r.lay("\\sum_{j=1}^K e^{z_j}", .display);
    const sum = try glyph(d, "∑", 0);
    try testing.expect(sum.style.size > size * 1.3);
    const sc = sum.x + r.width(sum) / 2;
    const k = try glyph(d, "𝐾", 0);
    const j = try glyph(d, "𝑗", 0);
    const one = try glyph(d, "1", 0);
    try testing.expectApproxEqAbs(sc, k.x + r.width(k) / 2, 1);
    try testing.expect(j.x < sc and one.x + r.width(one) > sc);
    try testing.expect(k.baseline < sum.baseline - 0.5 * size and one.baseline > sum.baseline + 0.3 * size);

    const t = try r.lay("\\sum_{j=1}^K e^{z_j}", .text);
    const tsum = try glyph(t, "∑", 0);
    try testing.expect((try glyph(t, "𝐾", 0)).x >= tsum.x + r.width(tsum) - 0.5);
    try testing.expect((try glyph(t, "1", 0)).x >= tsum.x + r.width(tsum) - 0.5);
}

test "scripts shift up and down, to the base's right, in a smaller size" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const b = try r.lay("z_i + e^{x}", .text);
    const z = try glyph(b, "𝑧", 0);
    const i = try glyph(b, "𝑖", 0);
    const e = try glyph(b, "𝑒", 0);
    const x = try glyph(b, "𝑥", 0);
    try testing.expect(i.baseline > z.baseline and i.x >= z.x + r.width(z) - 0.1);
    try testing.expect(x.baseline < e.baseline and x.x >= e.x + r.width(e));
    try testing.expect(i.style.size < size and x.style.size < size);
    try testing.expect(b.ascent < 1.5 * size and b.descent < 0.8 * size);
}

test "a leading minus is tight, a binary minus spaced" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const em = size; // text style at zoom 1
    const unary = try r.lay("-\\log(p_y)", .text);
    const m1 = try glyph(unary, "−", 0);
    try testing.expectEqual(@as(f32, 0), m1.x);
    const after_unary = (try glyph(unary, "log", 0)).x - (m1.x + r.width(m1));
    try testing.expectApproxEqAbs(0.17 * em, after_unary, 0.01); // ord–op thin space only

    const tight = try r.lay("-x", .text);
    const m2 = try glyph(tight, "−", 0);
    try testing.expectApproxEqAbs(@as(f32, 0), (try glyph(tight, "𝑥", 0)).x - (m2.x + r.width(m2)), 0.01);

    const binary = try r.lay("p_i - q_i", .text);
    const m3 = try glyph(binary, "−", 0);
    const sub = try glyph(binary, "𝑖", 0);
    const after_binary = (try glyph(binary, "𝑞", 0)).x - (m3.x + r.width(m3));
    try testing.expectApproxEqAbs(0.22 * em, after_binary, 0.01);
    try testing.expect(m3.x - (sub.x + r.width(sub)) > 0.2 * em);
    try testing.expect(after_binary > after_unary);
}

test "cross-entropy and the partial derivative lay out on one line" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const ce = try r.lay("\\mathcal{L} = -\\log(p_y) \\quad \\text{or generally} \\quad \\mathcal{L} = -\\sum_{i=1}^K q_i \\log(p_i)", .display);
    const words = try glyph(ce, "or generally", 0);
    const second = try glyph(ce, "ℒ", 1);
    try testing.expect(second.x > words.x + r.width(words) + 0.9 * size);
    try testing.expectEqual(words.baseline, second.baseline);

    const pd = try r.lay("\\frac{\\partial \\mathcal{L}}{\\partial z_i} = p_i - q_i", .display);
    const top = try glyph(pd, "𝜕", 0);
    const bottom = try glyph(pd, "𝜕", 1);
    try testing.expect(top.baseline < 0 and bottom.baseline > 0);
    try testing.expect((try glyph(pd, "=", 0)).baseline == 0);
}

test "a radical: three-segment check, a vinculum over the body, the index on its shoulder" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const b = try r.lay("\\sqrt[3]{x^2 + 1}", .display);
    try testing.expectEqual(@as(usize, 3), count(b, .line));
    try testing.expectEqual(@as(usize, 1), count(b, .rule));
    const x = try glyph(b, "𝑥", 0);
    const three = try glyph(b, "3", 0);
    try testing.expect(three.x < x.x and three.baseline < x.baseline);
    try testing.expect(three.style.size < 0.6 * size);
    for (b.ops) |op| if (op == .rule) try testing.expect(op.rule.y + op.rule.h <= -0.46 * size);
}

test "pmatrix and cases: grids with stretchy vector delimiters" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const m = try r.lay("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", .display);
    const a = try glyph(m, "𝑎", 0);
    const b_ = try glyph(m, "𝑏", 0);
    const c = try glyph(m, "𝑐", 0);
    try testing.expect(a.baseline < c.baseline and a.x < b_.x);
    try testing.expectEqual(a.baseline, b_.baseline);
    try testing.expect(count(m, .line) >= 2 * 16); // both parens drawn as curves, not glyphs
    for (m.ops) |op| if (op == .glyphs) try testing.expect(!std.mem.eql(u8, op.glyphs.str, "("));
    // Centred on the math axis.
    try testing.expectApproxEqAbs(m.ascent - 0.25 * 1.05 * size, m.descent + 0.25 * 1.05 * size, 0.5);

    const cs = try r.lay("f(x) = \\begin{cases} 1 & x > 0 \\\\ 0 & \\text{otherwise} \\end{cases}", .display);
    const one = try glyph(cs, "1", 0);
    const zero = try glyph(cs, "0", 0);
    try testing.expectEqual(one.x, zero.x); // left-aligned column
    try testing.expect(one.baseline < zero.baseline);
    try testing.expect(count(cs, .line) >= 10); // the brace
}

test "streaming prefixes and odd input lay out without error" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const b = try r.lay("\\frac{e^{z_i}}{\\sum_{j=1", .display);
    try testing.expectEqual(@as(usize, 1), count(b, .rule));
    const all = [_][]const u8{
        "\\left( \\frac{a}{b} \\right] \\Bigl\\{ x \\Bigr\\} \\langle u \\rangle \\lfloor y \\rfloor \\left| \\frac{1}{2} \\right\\|",
        "\\hat{x} \\widehat{xy} \\bar{a} \\overline{AB} \\underline{c} \\tilde{n} \\vec{v} \\dot{q} \\ddot{q} \\boxed{1}",
        "\\overbrace{a+b}^{n} \\underbrace{c}_{k} \\xrightarrow{f} \\xleftarrow{g} \\binom{n}{k} \\int_0^1 \\lim_{n \\to \\infty}",
        "\\begin{aligned} a &= b + c \\\\ &\\le d \\end{aligned} \\begin{bmatrix} 1 \\end{bmatrix} \\phantom{x} \\scriptstyle y",
        "\\frac{a}",
        "x^",
        "\\",
        "",
    };
    for (all) |s| for (0..s.len + 1) |n| {
        _ = try r.lay(s[0..n], .display);
    };
}

test "emit draws glyph runs and shapes on a canvas" {
    var r: Rig = undefined;
    try r.init();
    defer r.deinit();
    const b = try r.lay("\\sqrt{\\frac{a}{b}}", .display);
    r.blank.box = b;
    r.t.frame();
    try testing.expectEqual(count(b, .glyphs), r.blank.texts);
    try testing.expect(r.blank.shapes >= count(b, .rule) + count(b, .line));
}
