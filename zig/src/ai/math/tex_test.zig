const std = @import("std");
const tex = @import("tex.zig");
const Expr = tex.Expr;
const testing = std.testing;

fn parse(arena: *std.heap.ArenaAllocator, s: []const u8) !Expr {
    return tex.parse(arena.allocator(), s);
}

fn items(e: Expr) []const Expr {
    return switch (e) {
        .row => |r| r,
        else => &.{e},
    };
}

fn expectSym(e: Expr, text: []const u8, kind: tex.AtomKind) !void {
    try testing.expect(e == .sym);
    try testing.expectEqualStrings(text, e.sym.text);
    try testing.expectEqual(kind, e.sym.kind);
}

test "z = [z_1, z_2, \\dots, z_K]" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = items(try parse(&arena, "z = [z_1, z_2, \\dots, z_K]"));
    try testing.expectEqual(@as(usize, 11), r.len);
    try expectSym(r[0], "𝑧", .ord);
    try expectSym(r[1], "=", .rel);
    try expectSym(r[2], "[", .open);
    try testing.expect(r[3] == .scripts);
    try expectSym(r[3].scripts.base.*, "𝑧", .ord);
    try expectSym(items(r[3].scripts.sub.?.*)[0], "1", .ord);
    try testing.expect(r[3].scripts.sup == null);
    try expectSym(r[4], ",", .punct);
    try expectSym(r[7], "…", .ord);
    try expectSym(r[10], "]", .close);
}

test "p_i \\in (0, 1)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = items(try parse(&arena, "p_i \\in (0, 1)"));
    try testing.expectEqual(@as(usize, 7), r.len);
    try expectSym(r[1], "∈", .rel);
    try expectSym(r[2], "(", .open);
    try expectSym(r[6], ")", .close);
}

test "softmax: a fraction over a sum with limits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = items(try parse(&arena, "p_i = \\frac{e^{z_i}}{\\sum_{j=1}^K e^{z_j}}"));
    try testing.expectEqual(@as(usize, 3), r.len);
    const f = r[2].frac;
    try testing.expect(f.bar);
    const num = items(f.num.*);
    try testing.expectEqual(@as(usize, 1), num.len);
    try expectSym(num[0].scripts.base.*, "𝑒", .ord);
    try testing.expect(items(num[0].scripts.sup.?.*)[0] == .scripts);
    const den = items(f.den.*);
    try testing.expectEqual(@as(usize, 2), den.len);
    try expectSym(den[0].scripts.base.*, "∑", .big_op);
    try testing.expectEqual(@as(usize, 3), items(den[0].scripts.sub.?.*).len);
    try expectSym(den[0].scripts.sup.?.*, "𝐾", .ord);
}

test "cross-entropy: \\mathcal, named operators, \\quad and \\text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = items(try parse(&arena, "\\mathcal{L} = -\\log(p_y) \\quad \\text{or generally} \\quad \\mathcal{L} = -\\sum_{i=1}^K q_i \\log(p_i)"));
    try expectSym(items(r[0])[0], "ℒ", .ord);
    try expectSym(r[2], "−", .bin);
    try expectSym(r[3], "log", .op);
    try testing.expectEqual(tex.FontMode.upright, r[3].sym.font);
    try testing.expectEqual(@as(f32, 1.0), r[7].space);
    try expectSym(r[8], "or generally", .ord);
    try testing.expectEqual(tex.FontMode.text_prose, r[8].sym.font);
    try expectSym(r[12], "−", .bin);
    try expectSym(r[13].scripts.base.*, "∑", .big_op);
}

test "partial derivative fraction" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = items(try parse(&arena, "\\frac{\\partial \\mathcal{L}}{\\partial z_i} = p_i - q_i"));
    const num = items(r[0].frac.num.*);
    try expectSym(num[0], "𝜕", .ord);
    try expectSym(items(num[1])[0], "ℒ", .ord);
    try testing.expect(items(r[0].frac.den.*)[1] == .scripts);
    try expectSym(r[3], "−", .bin);
}

test "radical with an index" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const e = try parse(&arena, "\\sqrt[3]{x^2 + 1}");
    try expectSym(items(e.sqrt.index.?.*)[0], "3", .ord);
    const body = items(e.sqrt.body.*);
    try testing.expectEqual(@as(usize, 3), body.len);
    try testing.expect(body[0] == .scripts);
    try expectSym(body[1], "+", .bin);
}

test "pmatrix and cases environments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(&arena, "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}");
    try testing.expectEqual(tex.MatrixKind.pmatrix, m.matrix.kind);
    try testing.expectEqual(@as(usize, 2), m.matrix.rows.len);
    try testing.expectEqual(@as(usize, 2), m.matrix.rows[1].len);
    try expectSym(items(m.matrix.rows[1][1])[0], "𝑑", .ord);

    const r = items(try parse(&arena, "f(x) = \\begin{cases} 1 & x > 0 \\\\ 0 & \\text{otherwise} \\end{cases} + 1"));
    try testing.expectEqual(@as(usize, 8), r.len);
    const cases = r[5].matrix;
    try testing.expectEqual(tex.MatrixKind.cases, cases.kind);
    try testing.expectEqual(@as(usize, 2), cases.rows.len);
    try expectSym(items(cases.rows[1][1])[0], "otherwise", .ord);

    const top = try parse(&arena, "a &= b \\\\ &= c \\\\");
    try testing.expectEqual(tex.MatrixKind.aligned, top.matrix.kind);
    try testing.expectEqual(@as(usize, 2), top.matrix.rows.len);
}

test "delimiters, primes, \\not and \\$" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try parse(&arena, "\\left\\{ \\frac{a}{b} \\right.");
    try testing.expectEqualStrings("{", d.delim.left);
    try testing.expectEqualStrings("", d.delim.right);
    const big = try parse(&arena, "\\Bigl(");
    try testing.expectEqual(@as(f32, 1.6), big.delim.fixed_scale);
    try testing.expectEqualStrings("(", big.delim.left);
    const f = try parse(&arena, "f'^2");
    try testing.expectEqual(@as(usize, 2), items(f.scripts.sup.?.*).len);
    try expectSym(try parse(&arena, "\\not="), "≠", .rel);
    try expectSym(try parse(&arena, "\\$"), "$", .ord);
    try expectSym(try parse(&arena, "\\operatorname*{arg\\,max}"), "arg max", .big_op);
}

test "streaming prefixes parse into partial trees" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const e = try parse(&arena, "\\frac{e^{z_i}}{\\sum_{j=1");
    const den = items(e.frac.den.*);
    try expectSym(den[0].scripts.base.*, "∑", .big_op);
    try testing.expectEqual(@as(usize, 3), items(den[0].scripts.sub.?.*).len);
    try testing.expect(den[0].scripts.sup == null);

    const half = try parse(&arena, "\\frac{a}");
    try testing.expectEqual(@as(usize, 0), items(half.frac.den.*).len);
    const x = try parse(&arena, "x^");
    try testing.expectEqual(@as(usize, 0), items(x.scripts.sup.?.*).len);

    const all = [_][]const u8{
        "p_i = \\frac{e^{z_i}}{\\sum_{j=1}^K e^{z_j}}",
        "\\mathcal{L} = -\\log(p_y) \\quad \\text{or generally} \\quad \\mathcal{L} = -\\sum_{i=1}^K q_i \\log(p_i)",
        "\\sqrt[3]{x^2 + 1}",
        "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}",
        "\\left( \\begin{cases} 1 & x > 0 \\\\ 0 & \\text{sonst ü} \\end{cases} \\right) \\not\\in \\Bigl[ \\overset{!}{=}",
        "\\begin{aligned} a &= \\binom{n}{k} \\\\[2pt] &\\le \\hat{x} \\xrightarrow{f} y \\end{aligned}",
    };
    for (all) |s| for (0..s.len + 1) |n| {
        _ = try parse(&arena, s[0..n]);
    };
}
