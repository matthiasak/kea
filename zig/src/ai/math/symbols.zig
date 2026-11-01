//! LaTeX command → Unicode symbol table, atom classes for TeX spacing, the
//! Mathematical Alphanumeric letter maps, and rough per-glyph vertical
//! metrics (in em) so layout needn't ask CoreText for ink bounds.
const std = @import("std");

pub const AtomKind = enum { ord, op, big_op, bin, rel, open, close, punct };

pub const Sym = struct { utf8: []const u8, kind: AtomKind };

fn s(comptime name: []const u8, comptime utf8: []const u8, comptime kind: AtomKind) struct { []const u8, Sym } {
    return .{ name, .{ .utf8 = utf8, .kind = kind } };
}

/// Every symbol command, without its backslash.
pub const commands = std.StaticStringMap(Sym).initComptime(.{
    // Greek lowercase (math italic, as TeX sets them).
    s("alpha", "𝛼", .ord),          s("beta", "𝛽", .ord),       s("gamma", "𝛾", .ord),       s("delta", "𝛿", .ord),
    s("epsilon", "𝜖", .ord),        s("varepsilon", "𝜀", .ord), s("zeta", "𝜁", .ord),        s("eta", "𝜂", .ord),
    s("theta", "𝜃", .ord),          s("vartheta", "𝜗", .ord),   s("iota", "𝜄", .ord),        s("kappa", "𝜅", .ord),
    s("lambda", "𝜆", .ord),         s("mu", "𝜇", .ord),         s("nu", "𝜈", .ord),          s("xi", "𝜉", .ord),
    s("omicron", "𝜊", .ord),        s("pi", "𝜋", .ord),         s("varpi", "𝜛", .ord),       s("rho", "𝜌", .ord),
    s("varrho", "𝜚", .ord),         s("sigma", "𝜎", .ord),      s("varsigma", "𝜍", .ord),    s("tau", "𝜏", .ord),
    s("upsilon", "𝜐", .ord),        s("phi", "𝜙", .ord),        s("varphi", "𝜑", .ord),      s("chi", "𝜒", .ord),
    s("psi", "𝜓", .ord),            s("omega", "𝜔", .ord),
    // Greek uppercase (upright).
    s("Gamma", "Γ", .ord),          s("Delta", "Δ", .ord),      s("Theta", "Θ", .ord),       s("Lambda", "Λ", .ord),
    s("Xi", "Ξ", .ord),             s("Pi", "Π", .ord),         s("Sigma", "Σ", .ord),       s("Upsilon", "Υ", .ord),
    s("Phi", "Φ", .ord),            s("Psi", "Ψ", .ord),        s("Omega", "Ω", .ord),
    // Calculus, algebra, logic.
    s("partial", "𝜕", .ord),        s("nabla", "∇", .ord),      s("infty", "∞", .ord),       s("forall", "∀", .ord),
    s("exists", "∃", .ord),         s("nexists", "∄", .ord),    s("neg", "¬", .ord),         s("lnot", "¬", .ord),
    s("land", "∧", .bin),           s("lor", "∨", .bin),        s("wedge", "∧", .bin),       s("vee", "∨", .bin),
    s("emptyset", "∅", .ord),       s("varnothing", "∅", .ord), s("top", "⊤", .ord),         s("bot", "⊥", .ord),
    s("vdash", "⊢", .rel),          s("models", "⊨", .rel),     s("hbar", "ℏ", .ord),        s("ell", "ℓ", .ord),
    s("Re", "ℜ", .ord),             s("Im", "ℑ", .ord),         s("aleph", "ℵ", .ord),       s("wp", "℘", .ord),
    s("prime", "′", .ord),          s("angle", "∠", .ord),      s("triangle", "△", .ord),    s("degree", "°", .ord),
    s("checkmark", "✓", .ord),      s("square", "□", .ord),     s("Box", "□", .ord),         s("surd", "√", .ord),
    s("dagger", "†", .bin),         s("ddagger", "‡", .bin),    s("imath", "𝚤", .ord),       s("jmath", "𝚥", .ord),
    // Big operators.
    s("sum", "∑", .big_op),         s("prod", "∏", .big_op),    s("coprod", "∐", .big_op),   s("int", "∫", .big_op),
    s("iint", "∬", .big_op),        s("iiint", "∭", .big_op),   s("oint", "∮", .big_op),     s("bigcup", "⋃", .big_op),
    s("bigcap", "⋂", .big_op),      s("bigoplus", "⨁", .big_op), s("bigotimes", "⨂", .big_op), s("bigvee", "⋁", .big_op),
    s("bigwedge", "⋀", .big_op),    s("bigsqcup", "⨆", .big_op),
    // Binary operators.
    s("pm", "±", .bin),             s("mp", "∓", .bin),         s("times", "×", .bin),       s("div", "÷", .bin),
    s("cdot", "⋅", .bin),           s("ast", "∗", .bin),        s("star", "⋆", .bin),        s("circ", "∘", .bin),
    s("bullet", "∙", .bin),         s("oplus", "⊕", .bin),      s("ominus", "⊖", .bin),      s("otimes", "⊗", .bin),
    s("odot", "⊙", .bin),           s("oslash", "⊘", .bin),     s("cap", "∩", .bin),         s("cup", "∪", .bin),
    s("sqcup", "⊔", .bin),          s("sqcap", "⊓", .bin),      s("setminus", "∖", .bin),    s("wr", "≀", .bin),
    s("diamond", "⋄", .bin),        s("amalg", "⨿", .bin),
    // Relations.
    s("le", "≤", .rel),             s("leq", "≤", .rel),        s("ge", "≥", .rel),          s("geq", "≥", .rel),
    s("leqslant", "⩽", .rel),       s("geqslant", "⩾", .rel),   s("ll", "≪", .rel),          s("gg", "≫", .rel),
    s("ne", "≠", .rel),             s("neq", "≠", .rel),        s("approx", "≈", .rel),      s("sim", "∼", .rel),
    s("simeq", "≃", .rel),          s("cong", "≅", .rel),       s("equiv", "≡", .rel),       s("propto", "∝", .rel),
    s("in", "∈", .rel),             s("notin", "∉", .rel),      s("ni", "∋", .rel),          s("subset", "⊂", .rel),
    s("supset", "⊃", .rel),         s("subseteq", "⊆", .rel),   s("supseteq", "⊇", .rel),    s("subsetneq", "⊊", .rel),
    s("supsetneq", "⊋", .rel),      s("perp", "⊥", .rel),       s("parallel", "∥", .rel),    s("mid", "∣", .rel),
    s("nmid", "∤", .rel),           s("triangleq", "≜", .rel),  s("coloneqq", "≔", .rel),    s("coloneq", "≔", .rel),
    s("doteq", "≐", .rel),          s("prec", "≺", .rel),       s("succ", "≻", .rel),        s("preceq", "⪯", .rel),
    s("succeq", "⪰", .rel),         s("asymp", "≍", .rel),      s("lesssim", "≲", .rel),     s("gtrsim", "≳", .rel),
    s("vDash", "⊨", .rel),          s("dashv", "⊣", .rel),      s("sqsubseteq", "⊑", .rel),  s("bowtie", "⋈", .rel),
    // Arrows.
    s("to", "→", .rel),             s("rightarrow", "→", .rel), s("leftarrow", "←", .rel),   s("gets", "←", .rel),
    s("leftrightarrow", "↔", .rel), s("Rightarrow", "⇒", .rel), s("Leftarrow", "⇐", .rel),   s("Leftrightarrow", "⇔", .rel),
    s("iff", "⟺", .rel),            s("implies", "⟹", .rel),    s("impliedby", "⟸", .rel),   s("mapsto", "↦", .rel),
    s("longmapsto", "⟼", .rel),     s("uparrow", "↑", .rel),    s("downarrow", "↓", .rel),   s("updownarrow", "↕", .rel),
    s("Uparrow", "⇑", .rel),        s("Downarrow", "⇓", .rel),  s("longrightarrow", "⟶", .rel), s("longleftarrow", "⟵", .rel),
    s("Longrightarrow", "⟹", .rel), s("Longleftarrow", "⟸", .rel), s("hookrightarrow", "↪", .rel), s("hookleftarrow", "↩", .rel),
    s("rightharpoonup", "⇀", .rel), s("rightleftharpoons", "⇌", .rel), s("nearrow", "↗", .rel), s("searrow", "↘", .rel),
    s("leadsto", "⇝", .rel),
    // Dots.
    s("dots", "…", .ord),           s("ldots", "…", .ord),      s("cdots", "⋯", .ord),       s("vdots", "⋮", .ord),
    s("ddots", "⋱", .ord),          s("dotsc", "…", .ord),      s("dotsb", "⋯", .ord),
    // Escaped punctuation and delimiters.
    s("{", "{", .open),             s("}", "}", .close),        s("lbrace", "{", .open),     s("rbrace", "}", .close),
    s("langle", "⟨", .open),        s("rangle", "⟩", .close),   s("lfloor", "⌊", .open),     s("rfloor", "⌋", .close),
    s("lceil", "⌈", .open),         s("rceil", "⌉", .close),    s("lvert", "|", .open),      s("rvert", "|", .close),
    s("lVert", "‖", .open),         s("rVert", "‖", .close),    s("vert", "|", .ord),        s("Vert", "‖", .ord),
    s("|", "‖", .ord),              s("lbrack", "[", .open),    s("rbrack", "]", .close),    s("backslash", "∖", .ord),
    s("%", "%", .ord),              s("$", "$", .ord),          s("#", "#", .ord),           s("&", "&", .ord),
    s("_", "_", .ord),              s("colon", ":", .punct),    s("lt", "<", .rel),          s("gt", ">", .rel),
});

/// The class of an ASCII character in math mode.
pub fn charKind(ch: u8) AtomKind {
    return switch (ch) {
        '+', '-', '*' => .bin,
        '=', '<', '>', ':' => .rel,
        '(', '[' => .open,
        ')', ']', '!', '?' => .close,
        ',', ';' => .punct,
        else => .ord,
    };
}

/// The class of a Unicode symbol typed directly (`≤`, `α`): its command's, if any.
pub fn kindOfUtf8(utf8: []const u8) AtomKind {
    for (commands.values()) |v| if (std.mem.eql(u8, v.utf8, utf8)) return v.kind;
    return .ord;
}

/// A letter map: `ch` (A-Z, a-z, 0-9) to its UTF-8 in a Mathematical
/// Alphanumeric style, else `ch` itself.
const Table = [128][]const u8;

fn makeTable(comptime upper: u21, comptime lower: u21, comptime digit: u21, comptime holes: []const struct { u8, u21 }) Table {
    @setEvalBranchQuota(20_000);
    comptime {
        var t: Table = undefined;
        for (0..128) |i| {
            const ch: u8 = @intCast(i);
            var cp: u21 = ch;
            if (ch >= 'A' and ch <= 'Z' and upper != 0) cp = upper + (ch - 'A');
            if (ch >= 'a' and ch <= 'z' and lower != 0) cp = lower + (ch - 'a');
            if (ch >= '0' and ch <= '9' and digit != 0) cp = digit + (ch - '0');
            for (holes) |h| if (h[0] == ch) {
                cp = h[1];
            };
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            const final = buf[0..n].*;
            t[i] = &final;
        }
        return t;
    }
}

const italic_t = makeTable(0x1D434, 0x1D44E, 0, &.{.{ 'h', 0x210E }});
const bold_t = makeTable(0x1D400, 0x1D41A, 0x1D7CE, &.{});
const cal_t = makeTable(0x1D49C, 0x1D4B6, 0, &.{
    .{ 'B', 0x212C }, .{ 'E', 0x2130 }, .{ 'F', 0x2131 }, .{ 'H', 0x210B }, .{ 'I', 0x2110 }, .{ 'L', 0x2112 },
    .{ 'M', 0x2133 }, .{ 'R', 0x211B }, .{ 'e', 0x212F }, .{ 'g', 0x210A }, .{ 'o', 0x2134 },
});
const bb_t = makeTable(0x1D538, 0x1D552, 0x1D7D8, &.{
    .{ 'C', 0x2102 }, .{ 'H', 0x210D }, .{ 'N', 0x2115 }, .{ 'P', 0x2119 }, .{ 'Q', 0x211A }, .{ 'R', 0x211D }, .{ 'Z', 0x2124 },
});
const frak_t = makeTable(0x1D504, 0x1D51E, 0, &.{
    .{ 'C', 0x212D }, .{ 'H', 0x210C }, .{ 'I', 0x2111 }, .{ 'R', 0x211C }, .{ 'Z', 0x2128 },
});
const sans_t = makeTable(0x1D5A0, 0x1D5BA, 0x1D7E2, &.{});
const mono_t = makeTable(0x1D670, 0x1D68A, 0x1D7F6, &.{});

fn pick(t: *const Table, ch: u8) []const u8 {
    return if (ch < 128) t[ch] else "";
}

pub fn toMathItalic(ch: u8) []const u8 {
    return pick(&italic_t, ch);
}
pub fn toBold(ch: u8) []const u8 {
    return pick(&bold_t, ch);
}
pub fn toCal(ch: u8) []const u8 {
    return pick(&cal_t, ch);
}
pub fn toBb(ch: u8) []const u8 {
    return pick(&bb_t, ch);
}
pub fn toFrak(ch: u8) []const u8 {
    return pick(&frak_t, ch);
}
pub fn toSans(ch: u8) []const u8 {
    return pick(&sans_t, ch);
}
pub fn toMono(ch: u8) []const u8 {
    return pick(&mono_t, ch);
}

/// Vertical extent in em above and below the baseline.
pub const Metrics = struct { asc: f32, desc: f32 };

/// The ASCII letter a Mathematical Alphanumeric (or Greek) code point draws, else 0.
fn letterOf(cp: u21) u8 {
    const ranges = [_]u21{ 0x1D400, 0x1D434, 0x1D468, 0x1D49C, 0x1D504, 0x1D538, 0x1D5A0, 0x1D670 };
    if (cp == 0x210E) return 'h';
    if (cp < 128) return @intCast(cp);
    for (ranges) |r| if (cp >= r and cp < r + 52) {
        const i: u8 = @intCast(cp - r);
        return if (i < 26) 'A' + i else 'a' + (i - 26);
    };
    return 0;
}

// ponytail: a heuristic table, not per-glyph ink bounds; good enough to
// place scripts and fraction bars. Read CTFontGetBoundingRectsForGlyphs if
// tight boxes ever matter.
fn cpMetrics(cp: u21) Metrics {
    const ch = letterOf(cp);
    if (ch != 0) return switch (ch) {
        'a', 'c', 'e', 'm', 'n', 'o', 'r', 's', 'u', 'v', 'w', 'x', 'z' => .{ .asc = 0.46, .desc = 0 },
        'g', 'p', 'q', 'y' => .{ .asc = 0.46, .desc = 0.21 },
        'j' => .{ .asc = 0.66, .desc = 0.21 },
        'f' => .{ .asc = 0.70, .desc = if (cp > 127) 0.21 else 0 },
        'Q' => .{ .asc = 0.70, .desc = 0.12 },
        '(', ')', '[', ']', '{', '}', '|' => .{ .asc = 0.75, .desc = 0.25 },
        '+', '=', '<', '>', '-', '*' => .{ .asc = 0.58, .desc = 0.08 },
        ',', ';' => .{ .asc = 0.46, .desc = 0.19 },
        '.', '_' => .{ .asc = 0.11, .desc = 0 },
        ':' => .{ .asc = 0.46, .desc = 0 },
        '\'', '"', '^', '`' => .{ .asc = 0.70, .desc = 0 },
        else => .{ .asc = 0.70, .desc = 0 },
    };
    return switch (cp) {
        // Big operators at their own (enlarged) size.
        '∑', '∏', '∐', '⋃', '⋂', '⨁', '⨂', '⋁', '⋀', '⨆' => .{ .asc = 0.76, .desc = 0.25 },
        '∫', '∬', '∭', '∮' => .{ .asc = 0.86, .desc = 0.32 },
        // Lowercase Greek: x-height ones, then those with descenders.
        0x1D6FC, 0x1D700, 0x1D704, 0x1D705, 0x1D708, 0x1D70A, 0x1D70B, 0x1D70E, 0x1D70F, 0x1D710, 0x1D714, 0x1D716, 0x1D71B => .{ .asc = 0.46, .desc = 0 },
        0x1D6FE, 0x1D702, 0x1D707, 0x1D70C, 0x1D70D, 0x1D711, 0x1D712, 0x1D713, 0x1D71A, 0x1D719 => .{ .asc = 0.46, .desc = 0.21 },
        0x1D6FD, 0x1D701, 0x1D709 => .{ .asc = 0.70, .desc = 0.21 },
        '≤', '≥', '≠', '≈', '∼', '≃', '≅', '≡', '∈', '∉', '∋', '⊂', '⊃', '⊆', '⊇', '→', '←', '↔', '⇒', '⇐', '⇔', '±', '∓', '×', '÷', '⋅', '∘', '∗', '⊕', '⊗', '∪', '∩', '∝', '−', '⟹', '⟸', '⟺', '↦' => .{ .asc = 0.58, .desc = 0.08 },
        '⟨', '⟩', '⌊', '⌋', '⌈', '⌉', '‖', '∣', '∥' => .{ .asc = 0.75, .desc = 0.25 },
        '…', '⋯' => .{ .asc = 0.30, .desc = 0 },
        '⋮' => .{ .asc = 0.75, .desc = 0.05 },
        '′' => .{ .asc = 0.75, .desc = 0 },
        else => .{ .asc = 0.70, .desc = 0 },
    };
}

/// The extent of `utf8` set in one run: the largest of its code points'.
pub fn metrics(utf8: []const u8) Metrics {
    var m: Metrics = .{ .asc = 0, .desc = 0 };
    const view = std.unicode.Utf8View.init(utf8) catch return .{ .asc = 0.70, .desc = 0.2 };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == ' ') continue;
        const g = cpMetrics(cp);
        m.asc = @max(m.asc, g.asc);
        m.desc = @max(m.desc, g.desc);
    }
    return m;
}

test "letters map to Mathematical Alphanumerics, holes to letterlike symbols" {
    try std.testing.expectEqualStrings("𝑎", toMathItalic('a'));
    try std.testing.expectEqualStrings("ℎ", toMathItalic('h'));
    try std.testing.expectEqualStrings("𝐾", toMathItalic('K'));
    try std.testing.expectEqualStrings("1", toMathItalic('1'));
    try std.testing.expectEqualStrings("ℒ", toCal('L'));
    try std.testing.expectEqualStrings("𝒜", toCal('A'));
    try std.testing.expectEqualStrings("ℝ", toBb('R'));
    try std.testing.expectEqualStrings("𝔸", toBb('A'));
    try std.testing.expectEqualStrings("𝔤", toFrak('g'));
    try std.testing.expectEqualStrings("∑", commands.get("sum").?.utf8);
    try std.testing.expect(commands.get("le").?.kind == .rel);
    try std.testing.expect(commands.keys().len > 200);
}

test "metrics tell x-height letters from ascenders and descenders" {
    try std.testing.expectEqual(@as(f32, 0.46), metrics(toMathItalic('x')).asc);
    try std.testing.expectEqual(@as(f32, 0.21), metrics(toMathItalic('p')).desc);
    try std.testing.expectEqual(@as(f32, 0.70), metrics("K").asc);
    try std.testing.expect(metrics("∑").desc > 0);
    try std.testing.expect(kindOfUtf8("≤") == .rel);
}
