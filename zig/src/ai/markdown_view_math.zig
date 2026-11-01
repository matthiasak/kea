//! Math in an answer (markdown_view.zig), drawn on the GPU from its TeX
//! (math/tex.zig, math/layout.zig) on canvases that copy their source
//! whole: display blocks, formulas inline among the prose (lines packed
//! here, prose and formulas on one baseline), and the user's question
//! in its bubble, Markdown and math alike.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const inline_ = @import("markdown_inline.zig");
const theme = @import("markdown_theme.zig");
const view = @import("markdown_view.zig");
const rich = @import("markdown_view_rich.zig");
const tex = @import("math/tex.zig");
const layout = @import("math/layout.zig");
const Ctx = view.Ctx;

/// `src` laid out in `ms` at `size`, kept between frames with the answer.
fn mathBox(x: *const Ctx, src: []const u8, ms: layout.MathStyle, size: f32) ?layout.Box {
    var h = std.hash.Wyhash.init(@intFromEnum(ms));
    h.update(src);
    h.update(std.mem.asBytes(&size));
    h.update(std.mem.asBytes(&x.c.text.zoom));
    const k = h.final();
    if (x.st.math_cache.get(k)) |b| return b;
    // ponytail: past 1024 formulas the rest lay out each frame; evict if answers grow that long.
    const keep = x.o.cache and x.st.math_cache.count() < 1024;
    const a = if (keep) x.st.arenaAlloc(x.b.gpa) else x.c.alloc();
    const box = layout.layout(a, x.c.text, tex.parse(a, src) catch return null, ms, size) catch return null;
    if (keep) x.st.math_cache.put(x.b.gpa, k, box) catch {};
    return box;
}

/// A display formula centred on its own row (scrolling sideways when
/// wider than the answer), copying `raw` as written.
pub fn displayBlock(x: *const Ctx, text: []const u8, raw: []const u8, cp: rich.Copy) void {
    const c = x.c;
    const z = x.o.zoom;
    const th = theme.MdTheme.of(c.theme.dark, x.p);
    const box = mathBox(x, text, .display, 13.5 * z) orelse return;
    const i = c.open(.{ .direction = .row, .width = .fill, .padding = .xy(4, 6 * z), .radius = 8, .background = th.math_block_bg, .selectable = true }, null);
    defer c.end();
    const wide = if (c.rects.get(c.node(i).id)) |r| box.w + 12 > r.w else false;
    c.node(i).style.justify = if (wide) .start else .center;
    c.node(i).style.scroll_x = wide;
    const cv = ui.canvas(c, .{ .width = .{ .px = box.w + 4 }, .height = .{ .px = box.height() + 4 } });
    cv.copy_text = if (cp.prefix.len > 0) c.print("{s}{s}", .{ cp.prefix, raw }) else raw;
    cv.copy_join = cp.join;
    layout.emit(cv, box, 2, 2 + box.ascent, th.math_ink, x.p.muted, 1.0);
}

const Item = struct { start: usize, end: usize, math: ?usize = null, w: f32 = 0, nl: bool = false };

/// `shown` with its formulas: words and formulas packed into lines
/// `avail` wide (else the box's own width), each line's prose one text
/// and each formula a canvas, all on the line's baseline; copied through
/// `cm` (its source) as one text would be.
pub fn inlineRich(x: *const Ctx, shown: inline_.Shown, spans: []const ui.Span, style: ui.TextStyle, selectable: bool, cm: ui.CopyMap, avail_in: ?f32) void {
    const c = x.c;
    const a = c.alloc();
    const str = shown.text;
    const th = theme.MdTheme.of(c.theme.dark, x.p);
    const outer = c.open(.{ .direction = .column, .width = if (avail_in == null and style.wrap) .fill else .auto, .selectable = selectable }, null);
    defer c.end();
    const avail: f32 = if (!style.wrap) std.math.inf(f32) else avail_in orelse if (c.rects.get(c.node(outer).id)) |r| r.w else blk: {
        c.animationFrame();
        break :blk @max(160, x.b.prefs.chat_width - 72);
    };
    const boxes = a.alloc(?layout.Box, shown.maths.len) catch return;
    for (shown.maths, boxes) |m, *b| b.* = mathBox(x, m.tex, .text, style.size);

    // Words (with their trailing spaces), formulas and line breaks.
    var items: std.ArrayList(Item) = .empty;
    var pos: usize = 0;
    var mi: usize = 0;
    while (pos < str.len) {
        if (mi < shown.maths.len and shown.maths[mi].start == pos) {
            const w = if (boxes[mi]) |b| b.w + 2 else 0;
            items.append(a, .{ .start = pos, .end = shown.maths[mi].end, .math = mi, .w = w }) catch return;
            pos = shown.maths[mi].end;
            mi += 1;
            continue;
        }
        if (str[pos] == '\n') {
            items.append(a, .{ .start = pos, .end = pos + 1, .nl = true }) catch return;
            pos += 1;
            continue;
        }
        const stop = if (mi < shown.maths.len) shown.maths[mi].start else str.len;
        var end = pos;
        while (end < stop and str[end] != ' ' and str[end] != '\n') end += 1;
        const word_end = end;
        while (end < stop and str[end] == ' ') end += 1;
        items.append(a, .{ .start = pos, .end = end, .w = rich.width(c, str, spans, style, pos, word_end) }) catch return;
        pos = end;
    }

    // Greedy lines: a word or formula that would pass `avail` starts the next.
    var breaks: std.ArrayList(usize) = .empty;
    var x_at: f32 = 0;
    for (items.items, 0..) |it, k| {
        if (it.nl) {
            breaks.append(a, k + 1) catch return;
            x_at = 0;
            continue;
        }
        if (x_at > 0 and x_at + it.w > avail) {
            breaks.append(a, k) catch return;
            x_at = 0;
        }
        x_at += if (it.math == null) rich.width(c, str, spans, style, it.start, it.end) else it.w;
    }
    breaks.append(a, items.items.len) catch return;

    const f = c.text.font(style);
    const lh = c.text.lineHeight(style);
    const p_asc = (lh - f.lineHeight()) / 2 + f.leading / 2 + f.ascent;
    var from: usize = 0;
    for (breaks.items) |to| {
        defer from = to;
        const line = items.items[from..to];
        var asc = p_asc;
        for (line) |it| if (it.math) |m| if (boxes[m]) |b| {
            asc = @max(asc, b.ascent + 1);
        };
        ui.row(c, .{ .align_items = .start });
        defer ui.end(c);
        var k: usize = 0;
        while (k < line.len) {
            const it = line[k];
            if (it.nl) {
                k += 1;
                continue;
            }
            // After a line break the text copies on from a new line.
            const join = if (it.start == 0) cm.join else if (str[it.start - 1] == '\n') "\n" else "";
            if (it.math) |m| {
                k += 1;
                const b = boxes[m] orelse continue;
                const raw = shown.maths[m].raw;
                ui.column(c, .{ .padding = .{ .top = asc - b.ascent - 1 } });
                const cv = ui.canvas(c, .{ .width = .{ .px = b.w + 2 }, .height = .{ .px = b.height() + 2 } });
                cv.copy_text = c.print("{s}{s}{s}", .{ if (it.start == 0) cm.prefix else "", raw, if (it.end == str.len) cm.suffix else "" });
                cv.copy_join = join;
                layout.emit(cv, b, 1, 1 + b.ascent, th.math_ink, x.p.muted, 1.0);
                ui.end(c);
                continue;
            }
            // The line's prose up to its next formula, one text.
            var e = k;
            while (e < line.len and line[e].math == null and !line[e].nl) e += 1;
            prose(x, str[0..], shown.links, spans, style, cm, line[k].start, line[e - 1].end, join, asc - p_asc);
            k = e;
        }
    }
}

/// Bytes [s, e) of `str` as one unwrapped text, `top` down: its spans,
/// links and source map cut to it.
fn prose(x: *const Ctx, str: []const u8, links: []const inline_.Link, spans: []const ui.Span, style: ui.TextStyle, cm: ui.CopyMap, s: usize, e: usize, join: []const u8, top: f32) void {
    const a = x.c.alloc();
    var sub_spans: std.ArrayList(ui.Span) = .empty;
    for (spans) |sp| if (sp.end > s and sp.start < e) {
        var n = sp;
        n.start = @intCast(@max(sp.start, s) - s);
        n.end = @intCast(@min(sp.end, e) - s);
        sub_spans.append(a, n) catch {};
    };
    var sub_links: std.ArrayList(inline_.Link) = .empty;
    for (links) |l| if (l.end > s and l.start < e) {
        sub_links.append(a, .{ .start = @intCast(@max(l.start, s) - s), .end = @intCast(@min(l.end, e) - s), .url = l.url }) catch {};
    };
    // ponytail: a run cut by a line break reopens only on the line it started on.
    var wraps: std.ArrayList(ui.CopyMap.Wrap) = .empty;
    for (cm.wraps) |w| if (w.end > s and w.start < e) {
        wraps.append(a, .{ .start = @intCast(@max(w.start, s) - s), .end = @intCast(@min(w.end, e) - s), .open = w.open, .close = w.close }) catch {};
    };
    const mapped = cm.open.len > e and cm.close.len > e;
    var st = style;
    st.wrap = false;
    rich.leaf(x, .{ .padding = .{ .top = top } }, str[s..e], sub_links.items, sub_spans.items, st, .{
        .src = cm.src,
        .open = if (mapped) cm.open[s .. e + 1] else &.{},
        .close = if (mapped) cm.close[s .. e + 1] else &.{},
        .wraps = wraps.items,
        .prefix = if (s == 0) cm.prefix else "",
        .suffix = if (e == str.len) cm.suffix else "",
        .join = join,
    });
}

/// The user's question on the right in its bubble, as Markdown: one
/// paragraph hugs its width; formulas, lists, code or several blocks
/// draw as an answer does. Selected, it copies as written.
pub fn promptBubble(b: *Browser, c: *ui.Context, p: *const Palette, st: *view.State, question: []const u8, z: f32) void {
    const x: Ctx = .{ .b = b, .c = c, .p = p, .st = st, .o = .{ .zoom = z } };
    const row = c.open(.{ .direction = .row, .width = .fill, .padding = .{ .left = 40 } }, null);
    defer c.end();
    const bubble: ui.Style = .{ .direction = .column, .padding = .xy(12, 8), .radius = 14, .background = p.wash, .border = p.hairline, .selectable = true };
    const blocks = view.cachedBlocks(st, b.gpa, question, true, c.alloc()) orelse &.{};
    if (blocks.len == 1 and blocks[0] == .paragraph) {
        _ = c.leaf(.{ .grow = 1 }, .none, null);
        const src = blocks[0].paragraph;
        var style: ui.TextStyle = .{ .size = 12.5 * z, .wrap = true, .color = p.ink };
        style.mono_scale = theme.MdTheme.of(c.theme.dark, p).mono_scale;
        const shown = rich.cachedShown(&x, src);
        const spans = rich.toSpans(&x, shown) catch &.{};
        const cm = rich.copyMap(src, shown, .{});
        if (shown.maths.len == 0) return rich.leaf(&x, bubble, shown.text, shown.links, spans, style, cm);
        const avail = if (c.rects.get(c.node(row).id)) |r| r.w - 40 - 26 else @max(160, b.prefs.chat_width - 120);
        _ = c.open(bubble, null);
        defer c.end();
        return inlineRich(&x, shown, spans, style, true, cm, avail);
    }
    var wide = bubble;
    wide.width = .fill;
    _ = c.open(wide, null);
    defer c.end();
    view.answer(b, c, p, st, question, .{ .zoom = z });
}

test {
    _ = tex;
    _ = layout;
}
