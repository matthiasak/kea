//! A LaTeX math parser into a small expression tree for `layout.zig`.
//! Streaming-safe: incomplete input (unclosed groups, `\left(` without
//! `\right`, `\frac{a}`, a trailing `^` or `\`, an unclosed `\begin`) yields
//! a partial tree, never an error. Nothing in the tree points into `latex`.
const std = @import("std");
const symbols = @import("symbols.zig");

pub const AtomKind = symbols.AtomKind;
pub const FontMode = enum { math_normal, upright, bold, italic, mono, sans, text_prose };
pub const Limits = enum { auto, above_below, side };
pub const FracStyle = enum { auto, display, text };
pub const MathStyle = enum { display, text, script, scriptscript };
pub const AccentKind = enum { hat, widehat, bar, overline, underline, tilde, widetilde, vec, dot, ddot, overbrace, underbrace, xrightarrow, xleftarrow, boxed };
pub const MatrixKind = enum { matrix, pmatrix, bmatrix, Bmatrix, vmatrix, Vmatrix, cases, aligned, gathered, array };

pub const Expr = union(enum) {
    row: []const Expr,
    sym: Sym,
    scripts: Scripts,
    frac: Frac,
    sqrt: Sqrt,
    delim: Delim,
    accent: Accent,
    matrix: Matrix,
    /// Horizontal space in em (negative pulls back).
    space: f32,
    /// The style of the rest of the enclosing row.
    style_change: MathStyle,
    /// Takes its body's room, draws nothing.
    phantom: *const Expr,

    pub const Sym = struct { text: []const u8, kind: AtomKind, font: FontMode = .math_normal };
    pub const Scripts = struct { base: *const Expr, sub: ?*const Expr, sup: ?*const Expr, limits: Limits = .auto };
    pub const Frac = struct { num: *const Expr, den: *const Expr, bar: bool = true, style: FracStyle = .auto };
    pub const Sqrt = struct { index: ?*const Expr, body: *const Expr };
    /// `left`/`right` are UTF-8 delimiters ("" for none); `fixed_scale` 0
    /// stretches to the body, else `\big`-style sizes in em.
    pub const Delim = struct { left: []const u8, right: []const u8, body: *const Expr, fixed_scale: f32 = 0 };
    pub const Accent = struct { kind: AccentKind, body: *const Expr };
    pub const Matrix = struct { kind: MatrixKind, rows: []const []const Expr };

    pub const empty: Expr = .{ .row = &.{} };
};

const Err = std.mem.Allocator.Error;

pub fn parse(a: std.mem.Allocator, latex: []const u8) Err!Expr {
    var p: P = .{ .a = a, .s = latex };
    const rows = try p.cells(false);
    if (rows.len == 1 and rows[0].len == 1) {
        const r = rows[0][0].row;
        return if (r.len == 1) r[0] else rows[0][0];
    }
    var one_col = true;
    for (rows) |r| one_col = one_col and r.len <= 1;
    return .{ .matrix = .{ .kind = if (one_col) .gathered else .aligned, .rows = rows } };
}

const ascii: [128]u8 = blk: {
    var t: [128]u8 = undefined;
    for (&t, 0..) |*b, i| b.* = @intCast(i);
    break :blk t;
};

fn char(ch: u8) []const u8 {
    return if (ch < 128) ascii[ch..][0..1] else "";
}

const Font = enum { normal, rm, it, bf, sf, tt, cal, bb, frak };

const named_ops = std.StaticStringMap(struct { []const u8, bool }).initComptime(.{
    .{ "log", .{ "log", false } },     .{ "ln", .{ "ln", false } },         .{ "exp", .{ "exp", false } },
    .{ "sin", .{ "sin", false } },     .{ "cos", .{ "cos", false } },       .{ "tan", .{ "tan", false } },
    .{ "sec", .{ "sec", false } },     .{ "csc", .{ "csc", false } },       .{ "cot", .{ "cot", false } },
    .{ "sinh", .{ "sinh", false } },   .{ "cosh", .{ "cosh", false } },     .{ "tanh", .{ "tanh", false } },
    .{ "arcsin", .{ "arcsin", false } }, .{ "arccos", .{ "arccos", false } }, .{ "arctan", .{ "arctan", false } },
    .{ "arg", .{ "arg", false } },     .{ "dim", .{ "dim", false } },       .{ "ker", .{ "ker", false } },
    .{ "tr", .{ "tr", false } },       .{ "deg", .{ "deg", false } },       .{ "hom", .{ "hom", false } },
    .{ "lg", .{ "lg", false } },       .{ "min", .{ "min", true } },        .{ "max", .{ "max", true } },
    .{ "sup", .{ "sup", true } },      .{ "inf", .{ "inf", true } },        .{ "lim", .{ "lim", true } },
    .{ "liminf", .{ "lim inf", true } }, .{ "limsup", .{ "lim sup", true } }, .{ "det", .{ "det", true } },
    .{ "gcd", .{ "gcd", true } },      .{ "Pr", .{ "Pr", true } },          .{ "argmax", .{ "arg max", true } },
    .{ "argmin", .{ "arg min", true } },
});

const accents = std.StaticStringMap(AccentKind).initComptime(.{
    .{ "hat", .hat },             .{ "widehat", .widehat },     .{ "bar", .bar },               .{ "overline", .overline },
    .{ "underline", .underline }, .{ "tilde", .tilde },         .{ "widetilde", .widetilde },   .{ "vec", .vec },
    .{ "overrightarrow", .vec },  .{ "dot", .dot },             .{ "ddot", .ddot },             .{ "overbrace", .overbrace },
    .{ "underbrace", .underbrace }, .{ "xrightarrow", .xrightarrow }, .{ "xleftarrow", .xleftarrow }, .{ "boxed", .boxed },
});

const fonts = std.StaticStringMap(Font).initComptime(.{
    .{ "mathrm", .rm },  .{ "rm", .rm },    .{ "mathit", .it },     .{ "it", .it },       .{ "mathbf", .bf },
    .{ "bf", .bf },      .{ "boldsymbol", .bf }, .{ "bm", .bf },    .{ "mathsf", .sf },   .{ "mathtt", .tt },
    .{ "mathcal", .cal }, .{ "mathscr", .cal }, .{ "mathbb", .bb }, .{ "mathfrak", .frak },
});

const spaces = std.StaticStringMap(f32).initComptime(.{
    .{ "quad", 1.0 },  .{ "qquad", 2.0 },       .{ "thinspace", 0.17 }, .{ "medspace", 0.22 },
    .{ "thickspace", 0.28 }, .{ "enspace", 0.5 }, .{ "negthinspace", -0.17 },
});

const nots = std.StaticStringMap([]const u8).initComptime(.{
    .{ "=", "≠" }, .{ "∈", "∉" }, .{ "≡", "≢" }, .{ "∼", "≁" }, .{ "⊂", "⊄" }, .{ "⊃", "⊅" },
    .{ "⊆", "⊈" }, .{ "⊇", "⊉" }, .{ "≤", "≰" }, .{ "≥", "≱" }, .{ "<", "≮" }, .{ ">", "≯" },
    .{ "∣", "∤" }, .{ "∥", "∦" }, .{ "≈", "≉" }, .{ "≅", "≇" }, .{ "≃", "≄" }, .{ "∃", "∄" },
});

fn envKind(name: []const u8) MatrixKind {
    const n = std.mem.trimEnd(u8, name, "*");
    const map = std.StaticStringMap(MatrixKind).initComptime(.{
        .{ "matrix", .matrix },   .{ "smallmatrix", .matrix }, .{ "pmatrix", .pmatrix }, .{ "bmatrix", .bmatrix },
        .{ "Bmatrix", .Bmatrix }, .{ "vmatrix", .vmatrix },    .{ "Vmatrix", .Vmatrix }, .{ "cases", .cases },
        .{ "dcases", .cases },    .{ "aligned", .aligned },    .{ "align", .aligned },   .{ "alignat", .aligned },
        .{ "alignedat", .aligned }, .{ "split", .aligned },    .{ "array", .array },     .{ "eqnarray", .aligned },
    });
    return map.get(n) orelse .gathered;
}

const P = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    font: Font = .normal,

    fn box(p: *P, e: Expr) Err!*const Expr {
        const ptr = try p.a.create(Expr);
        ptr.* = e;
        return ptr;
    }

    fn skipWs(p: *P) void {
        while (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
    }

    /// At `\name` (a letter-named command not running into more letters).
    fn isCmd(p: *P, name: []const u8) bool {
        const rest = p.s[p.i..];
        if (rest.len < name.len + 1 or rest[0] != '\\' or !std.mem.eql(u8, rest[1 .. 1 + name.len], name)) return false;
        return !std.ascii.isAlphabetic(name[0]) or rest.len == name.len + 1 or !std.ascii.isAlphabetic(rest[1 + name.len]);
    }

    fn atStop(p: *P) bool {
        if (p.i >= p.s.len) return true;
        const c = p.s[p.i];
        return c == '}' or c == '&' or p.isCmd("\\") or p.isCmd("cr") or p.isCmd("right") or p.isCmd("end");
    }

    /// Cells split by `&` and rows by `\\` up to EOF (`env`: up to its `\end{…}`, consumed).
    fn cells(p: *P, env: bool) Err![]const []const Expr {
        var rows: std.ArrayList([]const Expr) = .empty;
        var cur: std.ArrayList(Expr) = .empty;
        var items: std.ArrayList(Expr) = .empty;
        while (true) {
            try p.rowInto(&items);
            if (p.i >= p.s.len) break;
            if (p.s[p.i] == '&') {
                p.i += 1;
                try cur.append(p.a, .{ .row = try items.toOwnedSlice(p.a) });
            } else if (p.isCmd("\\") or p.isCmd("cr")) {
                p.i += if (p.isCmd("\\")) 2 else 3;
                p.skipWs();
                if (p.i < p.s.len and p.s[p.i] == '[') p.i = if (std.mem.indexOfScalarPos(u8, p.s, p.i, ']')) |j| j + 1 else p.s.len;
                try cur.append(p.a, .{ .row = try items.toOwnedSlice(p.a) });
                try rows.append(p.a, try cur.toOwnedSlice(p.a));
            } else if (p.isCmd("end")) {
                p.i += 4;
                _ = p.rawGroup();
                if (env) break;
            } else if (p.isCmd("right")) {
                p.i += 6;
                _ = p.delimiter();
            } else p.i += 1; // a stray `}`
        }
        const last_empty = items.items.len == 0 and cur.items.len == 0;
        if (!last_empty or rows.items.len == 0) {
            try cur.append(p.a, .{ .row = try items.toOwnedSlice(p.a) });
            try rows.append(p.a, try cur.toOwnedSlice(p.a));
        }
        return rows.items;
    }

    /// Atoms until a stop, `\over`/`\choose` splitting them into a fraction.
    fn rowInto(p: *P, items: *std.ArrayList(Expr)) Err!void {
        while (true) {
            p.skipWs();
            if (p.atStop()) return;
            const over = p.isCmd("over");
            if (over or p.isCmd("choose")) {
                p.i += if (over) 5 else 7;
                const num = try p.box(.{ .row = try items.toOwnedSlice(p.a) });
                var den: std.ArrayList(Expr) = .empty;
                try p.rowInto(&den);
                try items.append(p.a, .{ .frac = .{ .num = num, .den = try p.box(.{ .row = den.items }), .bar = over } });
                return;
            }
            const at = try p.atom(false) orelse continue;
            try items.append(p.a, try p.postfix(at));
        }
    }

    fn group(p: *P) Err!Expr {
        p.i += 1;
        const saved = p.font;
        defer p.font = saved;
        var items: std.ArrayList(Expr) = .empty;
        try p.rowInto(&items);
        if (p.i < p.s.len and p.s[p.i] == '}') p.i += 1;
        return .{ .row = items.items };
    }

    /// A command's or script's argument: a group or one token (null at a stop).
    fn arg(p: *P) Err!?Expr {
        p.skipWs();
        if (p.atStop()) return null;
        return try p.atom(true);
    }

    fn argOrEmpty(p: *P) Err!*const Expr {
        return p.box((try p.arg()) orelse Expr.empty);
    }

    /// The text of a `{…}` group (to its end when unclosed), else of one token.
    fn rawGroup(p: *P) []const u8 {
        p.skipWs();
        if (p.i >= p.s.len) return "";
        const start = p.i;
        if (p.s[p.i] != '{') {
            p.i += if (p.s[p.i] == '\\') 1 + nameLen(p.s[p.i + 1 ..]) else std.unicode.utf8ByteSequenceLength(p.s[p.i]) catch 1;
            p.i = @min(p.i, p.s.len);
            return p.s[start..p.i];
        }
        var depth: usize = 0;
        while (p.i < p.s.len) : (p.i += 1) switch (p.s[p.i]) {
            '\\' => p.i += 1,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    p.i += 1;
                    return p.s[start + 1 .. p.i - 1];
                }
            },
            else => {},
        };
        p.i = p.s.len;
        return p.s[start + 1 ..];
    }

    fn nameLen(s: []const u8) usize {
        var n: usize = 0;
        while (n < s.len and std.ascii.isAlphabetic(s[n])) n += 1;
        return if (n == 0 and s.len > 0) 1 else n;
    }

    /// A `\left`/`\right`/`\big` delimiter as UTF-8 ("" for `.` or none).
    fn delimiter(p: *P) []const u8 {
        p.skipWs();
        if (p.i >= p.s.len) return "";
        const c = p.s[p.i];
        if (c == '\\') {
            const n = nameLen(p.s[p.i + 1 ..]);
            const name = p.s[p.i + 1 .. @min(p.s.len, p.i + 1 + n)];
            p.i = @min(p.s.len, p.i + 1 + n);
            return if (symbols.commands.get(name)) |sym| sym.utf8 else "";
        }
        p.i += 1;
        return switch (c) {
            '.' => "",
            '<' => "⟨",
            '>' => "⟩",
            else => char(c),
        };
    }

    fn letter(p: *P, ch: u8) Expr.Sym {
        return switch (p.font) {
            .normal => .{ .text = symbols.toMathItalic(ch), .kind = .ord },
            .it => .{ .text = symbols.toMathItalic(ch), .kind = .ord, .font = .italic },
            .rm => .{ .text = char(ch), .kind = .ord, .font = .upright },
            .bf => .{ .text = symbols.toBold(ch), .kind = .ord, .font = .bold },
            .sf => .{ .text = symbols.toSans(ch), .kind = .ord, .font = .sans },
            .tt => .{ .text = symbols.toMono(ch), .kind = .ord, .font = .mono },
            .cal => .{ .text = symbols.toCal(ch), .kind = .ord, .font = .upright },
            .bb => .{ .text = symbols.toBb(ch), .kind = .ord, .font = .upright },
            .frak => .{ .text = symbols.toFrak(ch), .kind = .ord, .font = .upright },
        };
    }

    fn atom(p: *P, single: bool) Err!?Expr {
        const c = p.s[p.i];
        switch (c) {
            '{' => return try p.group(),
            '^', '_' => return Expr.empty, // a script without a base: `postfix` takes it
            '\\' => return p.command(),
            '~' => {
                p.i += 1;
                return .{ .space = 0.33 };
            },
            '0'...'9', '.' => {
                const start = p.i;
                p.i += 1;
                while (!single and p.i < p.s.len and (std.ascii.isDigit(p.s[p.i]) or
                    (p.s[p.i] == '.' and p.i + 1 < p.s.len and std.ascii.isDigit(p.s[p.i + 1])))) p.i += 1;
                const digits = p.s[start..p.i];
                if (p.font == .normal or p.font == .rm or p.font == .it or p.font == .cal or p.font == .frak)
                    return .{ .sym = .{ .text = try p.a.dupe(u8, digits), .kind = .ord, .font = .upright } };
                var out: std.ArrayList(u8) = .empty;
                for (digits) |d| try out.appendSlice(p.a, p.letter(d).text);
                return .{ .sym = .{ .text = out.items, .kind = .ord, .font = p.letter('0').font } };
            },
            'a'...'z', 'A'...'Z' => {
                p.i += 1;
                return .{ .sym = p.letter(c) };
            },
            else => {},
        }
        if (c >= 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
            if (p.i + n > p.s.len or !std.unicode.utf8ValidateSlice(p.s[p.i .. p.i + n])) {
                p.i = @min(p.s.len, p.i + n); // a code point still streaming in, or junk
                return null;
            }
            const utf8 = try p.a.dupe(u8, p.s[p.i .. p.i + n]);
            p.i += n;
            return .{ .sym = .{ .text = utf8, .kind = symbols.kindOfUtf8(utf8), .font = .upright } };
        }
        p.i += 1;
        const text = switch (c) {
            '-' => "−",
            '*' => "∗",
            '\'' => "′",
            else => char(c),
        };
        return .{ .sym = .{ .text = text, .kind = symbols.charKind(c), .font = .upright } };
    }

    fn postfix(p: *P, base: Expr) Err!Expr {
        var sub: ?*const Expr = null;
        var sup: std.ArrayList(Expr) = .empty;
        var has_sup = false;
        var limits: Limits = .auto;
        var any = false;
        while (true) {
            p.skipWs();
            if (p.i >= p.s.len) break;
            const c = p.s[p.i];
            if (c == '^') {
                p.i += 1;
                if (try p.arg()) |e| try sup.append(p.a, e);
                has_sup = true;
            } else if (c == '_') {
                p.i += 1;
                sub = try p.argOrEmpty();
            } else if (c == '\'') {
                p.i += 1;
                try sup.append(p.a, .{ .sym = .{ .text = "′", .kind = .ord, .font = .upright } });
                has_sup = true;
            } else if (p.isCmd("limits")) {
                p.i += 7;
                limits = .above_below;
            } else if (p.isCmd("nolimits")) {
                p.i += 9;
                limits = .side;
            } else break;
            any = true;
        }
        if (!any) return base;
        const sup_e: ?*const Expr = if (!has_sup) null else if (sup.items.len == 1) try p.box(sup.items[0]) else try p.box(.{ .row = sup.items });
        return .{ .scripts = .{ .base = try p.box(base), .sub = sub, .sup = sup_e, .limits = limits } };
    }

    fn command(p: *P) Err!?Expr {
        p.i += 1;
        if (p.i >= p.s.len) return null; // a trailing `\` while streaming
        const start = p.i;
        p.i = @min(p.s.len, p.i + nameLen(p.s[p.i..]));
        const name = p.s[start..p.i];
        if (!std.ascii.isAlphabetic(name[0])) switch (name[0]) {
            ',' => return .{ .space = 0.17 },
            ':', '>' => return .{ .space = 0.22 },
            ';' => return .{ .space = 0.28 },
            '!' => return .{ .space = -0.17 },
            ' ', '\n', '\t' => return .{ .space = 0.33 },
            else => {},
        };
        if (symbols.commands.get(name)) |sym| return .{ .sym = .{ .text = sym.utf8, .kind = sym.kind, .font = .upright } };
        if (spaces.get(name)) |em| return .{ .space = em };
        if (named_ops.get(name)) |op| return .{ .sym = .{ .text = op[0], .kind = if (op[1]) .big_op else .op, .font = .upright } };
        if (accents.get(name)) |kind| {
            if (kind == .xrightarrow or kind == .xleftarrow) {
                p.skipWs();
                if (p.i < p.s.len and p.s[p.i] == '[') _ = p.until(']');
            }
            return .{ .accent = .{ .kind = kind, .body = try p.argOrEmpty() } };
        }
        if (fonts.get(name)) |f| {
            if (name.len == 2 and !std.mem.eql(u8, name, "bm")) { // `\rm`-style: the rest of the group
                p.font = f;
                return null;
            }
            const saved = p.font;
            defer p.font = saved;
            p.font = f;
            return (try p.arg()) orelse Expr.empty;
        }
        const eq = struct {
            fn f(a: []const u8, b: []const u8) bool {
                return std.mem.eql(u8, a, b);
            }
        }.f;
        inline for (.{ .{ "frac", FracStyle.auto, true }, .{ "cfrac", FracStyle.auto, true }, .{ "dfrac", FracStyle.display, true }, .{ "tfrac", FracStyle.text, true }, .{ "binom", FracStyle.auto, false }, .{ "dbinom", FracStyle.display, false }, .{ "tbinom", FracStyle.text, false } }) |fr| {
            if (eq(name, fr[0])) {
                const num = try p.argOrEmpty();
                return .{ .frac = .{ .num = num, .den = try p.argOrEmpty(), .bar = fr[2], .style = fr[1] } };
            }
        }
        if (eq(name, "sqrt")) {
            p.skipWs();
            var index: ?*const Expr = null;
            if (p.i < p.s.len and p.s[p.i] == '[') index = try p.box(try parse(p.a, p.until(']')));
            return .{ .sqrt = .{ .index = index, .body = try p.argOrEmpty() } };
        }
        if (eq(name, "left")) {
            const left = p.delimiter();
            var items: std.ArrayList(Expr) = .empty;
            try p.rowInto(&items);
            var right: []const u8 = "";
            if (p.isCmd("right")) {
                p.i += 6;
                right = p.delimiter();
            }
            return .{ .delim = .{ .left = left, .right = right, .body = try p.box(.{ .row = items.items }) } };
        }
        if (eq(name, "middle")) return .{ .sym = .{ .text = p.delimiter(), .kind = .rel, .font = .upright } };
        inline for (.{ .{ "big", 1.2 }, .{ "Big", 1.6 }, .{ "bigg", 2.1 }, .{ "Bigg", 2.6 } }) |b| {
            const n = b[0].len;
            if (std.mem.startsWith(u8, name, b[0]) and name.len <= n + 1 and (name.len == n or std.mem.indexOfScalar(u8, "lrm", name[n]) != null)) {
                const d = p.delimiter();
                const left = if (name.len > n) name[n] == 'l' else symbols.kindOfUtf8(d) == .open or (d.len == 1 and symbols.charKind(d[0]) == .open);
                return .{ .delim = .{ .left = if (left) d else "", .right = if (left) "" else d, .body = try p.box(Expr.empty), .fixed_scale = b[1] } };
            }
        }
        if (eq(name, "text") or eq(name, "textrm") or eq(name, "textnormal") or eq(name, "textit") or eq(name, "textbf") or
            eq(name, "textsf") or eq(name, "texttt") or eq(name, "mbox") or eq(name, "hbox"))
            return .{ .sym = .{ .text = try p.a.dupe(u8, validPrefix(p.rawGroup())), .kind = .ord, .font = .text_prose } };
        if (eq(name, "operatorname")) {
            const star = p.i < p.s.len and p.s[p.i] == '*';
            if (star) p.i += 1;
            const raw = p.rawGroup();
            var out: std.ArrayList(u8) = .empty;
            var k: usize = 0;
            while (k < raw.len) : (k += 1) {
                if (raw[k] != '\\') try out.append(p.a, raw[k]) else if (k + 1 < raw.len and !std.ascii.isAlphabetic(raw[k + 1])) {
                    try out.append(p.a, ' ');
                    k += 1;
                }
            }
            return .{ .sym = .{ .text = out.items, .kind = if (star) .big_op else .op, .font = .upright } };
        }
        if (eq(name, "begin")) {
            const env = p.rawGroup();
            const kind = envKind(env);
            if (kind == .array or std.mem.startsWith(u8, env, "alignat")) _ = p.rawGroup(); // column spec
            return .{ .matrix = .{ .kind = kind, .rows = try p.cells(true) } };
        }
        inline for (.{ "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle" }, .{ MathStyle.display, .text, .script, .scriptscript }) |n, st| {
            if (eq(name, n)) return .{ .style_change = st };
        }
        if (eq(name, "phantom") or eq(name, "hphantom") or eq(name, "vphantom")) return .{ .phantom = try p.argOrEmpty() };
        if (eq(name, "not")) {
            p.skipWs();
            if (p.atStop()) return null;
            const next = try p.atom(true) orelse return null;
            if (next != .sym) return next;
            var sym = next.sym;
            sym.text = nots.get(sym.text) orelse try std.mem.concat(p.a, u8, &.{ sym.text, "\u{338}" });
            return .{ .sym = sym };
        }
        if (eq(name, "overset") or eq(name, "underset") or eq(name, "stackrel")) {
            const over = try p.argOrEmpty();
            const base = try p.argOrEmpty();
            const under = eq(name, "underset");
            const b = if (base.* == .row and base.row.len == 1) try p.box(base.row[0]) else base;
            return .{ .scripts = .{ .base = b, .sup = if (under) null else over, .sub = if (under) over else null, .limits = .above_below } };
        }
        if (eq(name, "textcolor")) {
            _ = p.rawGroup();
            return (try p.arg()) orelse Expr.empty;
        }
        if (eq(name, "color") or eq(name, "label") or eq(name, "tag") or eq(name, "hspace") or eq(name, "kern") or eq(name, "mkern")) {
            _ = p.rawGroup();
            return if (eq(name, "hspace")) .{ .space = 0.33 } else null;
        }
        if (eq(name, "hline") or eq(name, "nonumber") or eq(name, "notag") or eq(name, "limits") or eq(name, "nolimits") or
            eq(name, "displaylimits") or eq(name, "left") or eq(name, "right")) return null;
        // Unknown: shown as written.
        return .{ .sym = .{ .text = try p.a.dupe(u8, p.s[start - 1 .. p.i]), .kind = .ord, .font = .text_prose } };
    }

    /// The text from after the `[` here to the matching `close` (or the end), consumed.
    fn until(p: *P, close: u8) []const u8 {
        p.i += 1;
        const start = p.i;
        var depth: usize = 0;
        while (p.i < p.s.len) : (p.i += 1) {
            const c = p.s[p.i];
            if (c == '\\') p.i += 1 else if (c == '{') depth += 1 else if (c == '}' and depth > 0) depth -= 1 else if (c == close and depth == 0) {
                p.i += 1;
                return p.s[start .. p.i - 1];
            }
        }
        p.i = p.s.len;
        return p.s[start..];
    }
};

/// `s` without a code point cut short at its end (still streaming in).
fn validPrefix(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0 and n + 4 > s.len and !std.unicode.utf8ValidateSlice(s[0..n])) n -= 1;
    return if (std.unicode.utf8ValidateSlice(s[0..n])) s[0..n] else "";
}

test {
    _ = @import("tex_test.zig");
}
