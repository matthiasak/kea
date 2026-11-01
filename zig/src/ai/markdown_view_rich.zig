//! An answer's inline Markdown on screen (markdown_view.zig): the shown
//! text (markdown_inline.zig) with its editorial spans (markdown_theme.zig),
//! copying its source when selected (`ui.CopyMap`), its web links opening
//! in a new tab; inline math laid out by markdown_view_math.zig.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const inline_ = @import("markdown_inline.zig");
const theme = @import("markdown_theme.zig");
const view = @import("markdown_view.zig");
const math_view = @import("markdown_view_math.zig");
const Ctx = view.Ctx;

/// What a selection copies around a text's source: `prefix` when it takes
/// the text's start (`"## "`, `"1. "`, `"> "`), `suffix` when it takes its
/// end, `join` before it after other selected text.
pub const Copy = struct { prefix: []const u8 = "", suffix: []const u8 = "", join: []const u8 = "\n" };

pub fn copyMap(src: []const u8, shown: inline_.Shown, cp: Copy) ui.CopyMap {
    return .{ .src = src, .open = shown.open_map, .close = shown.close_map, .wraps = shown.wraps, .prefix = cp.prefix, .suffix = cp.suffix, .join = cp.join };
}

fn textKey(s: []const u8) u64 {
    return std.hash.Wyhash.hash(s.len, s);
}

/// `Markdown.shown(src)`, kept between frames when the answer is; a streaming
/// tail's (`stream_id`) each frame, its math still being written shown as math.
pub fn cachedShown(x: *const Ctx, src: []const u8) inline_.Shown {
    const k = textKey(src);
    const streaming = x.o.stream_id != null;
    if (!streaming) if (x.st.inlines_cache.get(k)) |sh| return sh;
    if (!x.o.cache or streaming or x.st.inlines_cache.count() >= 4096) {
        return inline_.shownOpts(x.c.alloc(), src, streaming) catch inline_.Shown{ .text = src, .runs = &.{}, .links = &.{} };
    }
    const sh = inline_.shown(x.st.arenaAlloc(x.b.gpa), src) catch return inline_.Shown{ .text = src, .runs = &.{}, .links = &.{} };
    x.st.inlines_cache.put(x.b.gpa, k, sh) catch {};
    return sh;
}

/// The width of `src` shown on one line in `style`.
// ponytail: inline math counts as its source's width; lay it out if tables with formulas run wide.
pub fn measure(x: *const Ctx, src: []const u8, style: ui.TextStyle) f32 {
    const shown = cachedShown(x, src);
    var st = style;
    st.mono_scale = theme.MdTheme.of(x.c.theme.dark, x.p).mono_scale;
    const spans = toSpans(x, shown) catch return x.c.text.width(shown.text, st);
    return @ceil(width(x.c, shown.text, spans, st, 0, shown.text.len));
}

/// The width of `str[from..to]` drawn with `spans` in `style`.
pub fn width(c: *ui.Context, str: []const u8, spans: []const ui.Span, style: ui.TextStyle, from: usize, to: usize) f32 {
    var w: f32 = 0;
    var it: Segments = .{ .spans = spans, .pos = from, .end = to };
    while (it.next()) |seg| w += c.text.width(str[seg.start..seg.end], seg.style(style)) + seg.pad;
    return w;
}

/// `Text(Markdown.shown(src))` in `style` (`selectable` as
/// `.textSelection(.enabled)`), copying `src` with `cp` around it.
pub fn rich(x: *const Ctx, src: []const u8, style_in: ui.TextStyle, selectable: bool, cp: Copy) void {
    var style = style_in;
    style.mono_scale = theme.MdTheme.of(x.c.theme.dark, x.p).mono_scale;
    const shown = cachedShown(x, src);
    const spans = toSpans(x, shown) catch &.{};
    if (shown.maths.len > 0) return math_view.inlineRich(x, shown, spans, style, selectable, copyMap(src, shown, cp), null);
    leaf(x, .{ .width = if (style.wrap) .fill else .auto, .selectable = selectable }, shown.text, shown.links, spans, style, copyMap(src, shown, cp));
}

/// One text in the box `node`; its web links open in a new tab when clicked.
pub fn leaf(x: *const Ctx, node: ui.Style, str: []const u8, links: []const inline_.Link, spans: []const ui.Span, style: ui.TextStyle, cm: ui.CopyMap) void {
    const i = x.c.leaf(node, .{ .text = .{ .str = str, .style = style, .color = style.color orelse x.p.ink, .spans = spans, .copy = cm } }, null);
    for (links) |l| {
        if (opens(l.url)) return follow(x, i, str, links, spans, style);
    }
}

/// Only web addresses open from an answer.
fn opens(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://");
}

/// The pointer over the text `i`: a hand over a link, and a click on one
/// opens it in a new tab in front.
fn follow(x: *const Ctx, i: u32, str: []const u8, links: []const inline_.Link, spans: []const ui.Span, style: ui.TextStyle) void {
    const c = x.c;
    const it = c.interact(i, .{});
    if (!it.hovered and !it.clicked) return;
    const r = it.rect orelse return;
    const at = byteAt(c, str, spans, style, r, c.input.mouse);
    const url: ?[]const u8 = if (at) |k| for (links) |l| {
        if (k >= l.start and k < l.end and opens(l.url)) break l.url;
    } else null else null;
    if (c.hot == it.id) c.cursor_hand = url != null;
    if (it.clicked) if (url) |u| {
        const shy = if (x.b.assisting) |a| a.shy else false;
        // A private chat's links open private, out of a private tab; none: shut.
        const from = if (shy) shyTab(x.b) orelse return else x.b.activeTab();
        _ = x.b.open(u, .{ .foreground = !c.input.cmd or c.input.shift, .from = from, .may_wait = c.input.cmd and !c.input.shift });
        c.changed = true;
    };
}

/// A private tab, the one in front first.
fn shyTab(b: *Browser) ?*@import("../web/tab.zig").Tab {
    if (b.activeTab()) |front| if (front.shy) return front;
    for (b.tabs.items) |t| if (t.shy) return t;
    return null;
}

/// The byte of `str` (drawn with `spans` in `style`, wrapped to `r`)
/// under `m`, if any.
fn byteAt(c: *ui.Context, str: []const u8, spans: []const ui.Span, style: ui.TextStyle, r: ui.Rect, m: ui.Point) ?usize {
    if (m.x < r.x or m.y < r.y) return null;
    const row: usize = @intFromFloat(@floor((m.y - r.y) / c.text.lineHeight(style)));
    var it: Segments = .{ .spans = spans, .end = str.len };
    if (style.wrap) {
        const lines = c.text.wrapAttributed(str, style, spans, r.w);
        if (row >= lines.len) return null;
        it.pos = lines[row].start;
        it.end = lines[row].end;
    } else if (row > 0) return null;
    var left = r.x;
    while (it.next()) |seg| {
        const st = seg.style(style);
        const piece = str[seg.start..seg.end];
        const w = c.text.width(piece, st) + seg.pad;
        if (m.x < left + w) {
            var k = c.text.indexAt(piece, st, m.x - left);
            // The caret nearest the pointer may follow the glyph under it.
            if (k > 0 and c.text.caretX(piece, st, k) > m.x - left) {
                k -= 1;
                while (k > 0 and piece[k] & 0xc0 == 0x80) k -= 1;
            }
            return seg.start + k;
        }
        left += w;
    }
    return null;
}

/// Runs of a line between span edges, each with the span over it.
const Segments = struct {
    spans: []const ui.Span,
    pos: usize = 0,
    end: usize,

    const Seg = struct {
        start: usize,
        end: usize,
        span: ?ui.Span,
        /// A pill's kerning after the segment's last glyph (nanoui rich.zig).
        pad: f32 = 0,

        fn style(s: Seg, base: ui.TextStyle) ui.TextStyle {
            var st = base;
            const sp = s.span orelse return st;
            if (sp.weight) |w| st.weight = w;
            st.italic = st.italic or sp.italic;
            if (sp.mono and !base.mono) st.size = base.size * base.mono_scale;
            st.mono = st.mono or sp.mono;
            return st;
        }
    };

    fn next(it: *Segments) ?Seg {
        if (it.pos >= it.end) return null;
        var stop = it.end;
        var over: ?ui.Span = null;
        for (it.spans) |sp| {
            if (sp.start <= it.pos and sp.end > it.pos) {
                over = sp;
                stop = @min(stop, sp.end);
            } else if (sp.start > it.pos) stop = @min(stop, sp.start);
        }
        var seg: Seg = .{ .start = it.pos, .end = stop, .span = over };
        for (it.spans) |sp| if (sp.pad_x > 0 and (sp.start == stop or sp.end == stop)) {
            seg.pad = @max(seg.pad, sp.pad_x);
        };
        it.pos = stop;
        return seg;
    }
};

/// The editorial look of each inline (markdown_theme.zig): strong
/// semibold in crisp ink, emphasis italic, code a bordered lavender pill
/// padded clear of its neighbours, strikethrough struck, a web link in
/// the link blue, underlined.
pub fn toSpans(x: *const Ctx, shown: inline_.Shown) ![]const ui.Span {
    if (shown.runs.len == 0) return &.{};
    const th = theme.MdTheme.of(x.c.theme.dark, x.p);
    const out = try x.c.alloc().alloc(ui.Span, shown.runs.len);
    for (shown.runs, out) |r, *sp| {
        const web = r.flags.link and for (shown.links) |l| {
            if (r.start >= l.start and r.end <= l.end) break opens(l.url);
        } else false;
        sp.* = .{
            .start = r.start,
            .end = r.end,
            .weight = if (r.flags.bold) .semibold else null,
            .italic = r.flags.italic,
            .mono = r.flags.code,
            .background = if (r.flags.code) th.code_bg else null,
            .border = if (r.flags.code) th.code_border else null,
            .pad_x = if (r.flags.code) th.pad_x * x.o.zoom else 0,
            .strike = r.flags.strike,
            .underline = web,
            .color = if (web) th.link else if (r.flags.code) th.code_ink else if (r.flags.bold) th.strong else null,
        };
    }
    return out;
}
