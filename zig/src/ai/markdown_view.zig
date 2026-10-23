//! `AnswerView` (AIAssist.swift:1325-1441): an answer's Markdown, block by
//! block — headings, paragraphs, lists, quotes, tables, rules and code
//! (`CodeBlock`, markdown_view_code.zig) — its inline emphasis from
//! markdown_inline.zig. Text selects, as `.textSelection(.enabled)`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const markdown = @import("markdown.zig");
const inline_ = @import("markdown_inline.zig");
const code = @import("markdown_view_code.zig");
const mermaid = @import("mermaid/mermaid.zig");
const draw = @import("mermaid/draw.zig");
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");

const pictures_kept = 24;

/// What the answers of one window keep between frames (`@State` of each
/// `CodeBlock`), by the code block's box id.
pub const State = struct {
    /// Mermaid blocks shown as source rather than drawn (`source`).
    sources: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Code blocks just copied: until when (`c.time`) they say "Copied".
    copied: std.AutoHashMapUnmanaged(u64, f64) = .empty,
    /// Drawn diagrams' PNGs, by source, look and zoom, with the frame
    /// (`c.time`) that last showed each; owned.
    pictures: std.AutoHashMapUnmanaged(u64, Picture) = .empty,
    /// Cached Markdown block ASTs, inline runs, and Mermaid layouts.
    cache_arena: ?std.heap.ArenaAllocator = null,
    blocks_cache: std.AutoHashMapUnmanaged(u64, []const markdown.Block) = .empty,
    inlines_cache: std.AutoHashMapUnmanaged(u64, inline_.Shown) = .empty,
    diagrams_cache: std.AutoHashMapUnmanaged(u64, ?mermaid.Diagram) = .empty,
    boxes: std.AutoHashMapUnmanaged(u64, BoxState) = .empty,

    pub const Picture = struct { bytes: []u8, used: f64 };
    pub const BoxState = struct {
        scale: f32 = 1.0,
        height: f32 = 0,
        pan_x: f32 = 0,
        wrapped: bool = false,
        col_scale: f32 = 1.0,
        drag_start: f32 = 0,
        drag_base: f32 = 0,
    };

    pub fn boxState(s: *State, gpa: std.mem.Allocator, id: u64) *BoxState {
        const gop = s.boxes.getOrPut(gpa, id) catch {
            const S = struct {
                var spare: BoxState = .{};
            };
            return &S.spare;
        };
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        var it = s.pictures.valueIterator();
        while (it.next()) |v| gpa.free(v.bytes);
        s.pictures.deinit(gpa);
        s.sources.deinit(gpa);
        s.copied.deinit(gpa);
        s.blocks_cache.deinit(gpa);
        s.inlines_cache.deinit(gpa);
        s.diagrams_cache.deinit(gpa);
        s.boxes.deinit(gpa);
        if (s.cache_arena) |*ca| ca.deinit();
        s.* = .{};
    }

    pub fn clearCache(s: *State, gpa: std.mem.Allocator) void {
        var it = s.pictures.valueIterator();
        while (it.next()) |v| gpa.free(v.bytes);
        s.pictures.clearRetainingCapacity();
        s.sources.clearRetainingCapacity();
        s.copied.clearRetainingCapacity();
        s.boxes.clearRetainingCapacity();
        if (s.cache_arena) |*ca| _ = ca.reset(.{ .retain_with_limit = 256 * 1024 });
        s.blocks_cache.clearRetainingCapacity();
        s.inlines_cache.clearRetainingCapacity();
        s.diagrams_cache.clearRetainingCapacity();
    }

    pub fn arenaAlloc(s: *State, gpa: std.mem.Allocator) std.mem.Allocator {
        if (s.cache_arena == null) s.cache_arena = std.heap.ArenaAllocator.init(gpa);
        return s.cache_arena.?.allocator();
    }
    /// Lets go of the picture shown longest ago, unless every one was
    /// shown this frame (`now`): the renderer may still read those bytes.
    pub fn forgetOldest(s: *State, gpa: std.mem.Allocator, now: f64) void {
        var oldest: ?u64 = null;
        var when = now;
        var it = s.pictures.iterator();
        while (it.next()) |e| if (e.value_ptr.used < when) {
            when = e.value_ptr.used;
            oldest = e.key_ptr.*;
        };
        const k = oldest orelse return;
        gpa.free(s.pictures.fetchRemove(k).?.value.bytes);
    }
};

pub const Options = struct { zoom: f32 = 1, drawn: bool = false, cache: bool = true };

/// What every block of one answer is drawn with.
pub const Ctx = struct {
    b: *Browser,
    c: *ui.Context,
    p: *const Palette,
    st: *State,
    o: Options,
};

fn textKey(s: []const u8) u64 {
    return std.hash.Wyhash.hash(s.len, s);
}

pub fn cachedBlocks(st: *State, gpa: std.mem.Allocator, text: []const u8, cache: bool, scratch: std.mem.Allocator) ?[]const markdown.Block {
    const k = textKey(text);
    if (st.blocks_cache.get(k)) |b| return b;
    if (!cache) return markdown.blocks(scratch, text) catch null;
    if (st.blocks_cache.count() >= 512) st.clearCache(gpa);
    const a = st.arenaAlloc(gpa);
    const parsed = markdown.blocks(a, text) catch return null;
    st.blocks_cache.put(gpa, k, parsed) catch {};
    return parsed;
}

/// `AnswerView(text:zoom:drawn:)`.
pub fn answer(b: *Browser, c: *ui.Context, p: *const Palette, st: *State, text: []const u8, o: Options) void {
    const x: Ctx = .{ .b = b, .c = c, .p = p, .st = st, .o = o };
    const parsed = cachedBlocks(st, b.gpa, text, o.cache, c.alloc()) orelse return;
    ui.column(c, .{ .gap = 10 * o.zoom, .width = .fill });
    defer ui.end(c);
    for (parsed) |blk| block(&x, blk, 0);
}

fn headingSize(level: u8, zoom: f32) f32 {
    return zoom * @as(f32, switch (level) {
        1 => 18,
        2 => 16,
        3 => 14.5,
        else => 13,
    });
}

/// `.lineSpacing(2.5 * zoom)` as a multiple of `style`'s line.
fn spaced(c: *ui.Context, style: ui.TextStyle, zoom: f32) ui.TextStyle {
    var s = style;
    const lh = c.text.font(style).lineHeight();
    s.leading = (lh + 2.5 * zoom) / lh;
    return s;
}

fn block(x: *const Ctx, blk: markdown.Block, depth: usize) void {
    const c = x.c;
    const p = x.p;
    const z = x.o.zoom;
    switch (blk) {
        .heading => |h| rich(x, h.text, .{ .size = headingSize(h.level, z), .weight = .semibold, .color = p.ink, .wrap = true }, true),
        .paragraph => |t| rich(x, t, spaced(c, .{ .size = 13 * z, .color = p.ink, .wrap = true }, z), true),
        .list => |l| {
            ui.column(c, .{ .gap = 5 * z, .width = .fill });
            defer ui.end(c);
            for (l.items, 0..) |item, i| {
                ui.row(c, .{ .gap = 6, .width = .fill });
                defer ui.end(c);
                const bullets = [_][]const u8{ "•", "◦", "▪" };
                const marker = if (l.ordered) c.print("{d}.", .{l.start + @as(i64, @intCast(i))}) else bullets[@min(depth, 2)];
                // `.frame(minWidth: 14 * zoom, alignment: .trailing)`, on the first line's baseline.
                ui.column(c, .{ .min_width = 14 * z, .align_items = .end });
                ui.text(c, marker, spaced(c, .{ .size = 13 * z, .tabular = true, .color = p.muted }, z));
                ui.end(c);
                ui.column(c, .{ .gap = 6 * z, .grow = 1, .min_width = 0 });
                defer ui.end(c);
                for (item) |sub| block(x, sub, depth + 1);
            }
        },
        .quote => |inner| {
            // The VStack's muted foreground yields to each Text's own ink.
            ui.row(c, .{ .gap = 10, .width = .fill, .align_items = .stretch });
            defer ui.end(c);
            _ = c.leaf(.{ .width = .{ .px = 3 }, .background = p.faint }, .none, null);
            ui.column(c, .{ .gap = 6 * z, .grow = 1, .min_width = 0 });
            defer ui.end(c);
            for (inner) |sub| block(x, sub, depth + 1);
        },
        .table => |t| table(x, t.header, t.rows),
        .rule => {
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = p.hairline }, .none, null);
        },
        .code => |cb| if (std.mem.eql(u8, cb.language, "mermaid") and cb.closed)
            mermaidCodeBlock(x, cb.language, cb.text)
        else
            code.block(x, cb.language, cb.text, cb.closed),
    }
}

fn pictureKey(text: []const u8, dark: bool, zoom: f32) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(text);
    h.update(&.{@intFromBool(dark)});
    h.update(std.mem.asBytes(&zoom));
    return h.final();
}

fn cachedDiagram(st: *State, gpa: std.mem.Allocator, text: []const u8) ?mermaid.Diagram {
    const k = textKey(text);
    if (st.diagrams_cache.get(k)) |d| return d;
    if (st.diagrams_cache.count() >= 64) st.diagrams_cache.clearRetainingCapacity();
    const d = mermaid.diagram(st.arenaAlloc(gpa), text);
    st.diagrams_cache.put(gpa, k, d) catch {};
    return d;
}

fn mermaidCodeBlock(x: *const Ctx, language: []const u8, text: []const u8) void {
    const c = x.c;
    const p = x.p;
    const z = x.o.zoom;
    const peek_id = c.peekId(null);
    if (x.st.sources.contains(peek_id)) return code.block(x, language, text, true);
    const pkey = pictureKey(text, c.theme.dark, z);
    var png_bytes: ?[]const u8 = null;
    if (x.st.pictures.getPtr(pkey)) |pic| {
        pic.used = c.time;
        png_bytes = pic.bytes;
    } else if (cachedDiagram(x.st, x.b.gpa, text)) |d| {
        if (x.st.pictures.count() >= pictures_kept) x.st.forgetOldest(x.b.gpa, c.time);
        if (draw.png(x.b.gpa, d, p, z)) |bytes| {
            x.st.pictures.put(x.b.gpa, pkey, .{ .bytes = bytes, .used = c.time }) catch {
                x.b.gpa.free(bytes);
                return code.block(x, language, text, true);
            };
            png_bytes = bytes;
        } else |_| {}
    }
    const bytes = png_bytes orelse return code.block(x, language, text, true);

    const i = c.open(.{ .gap = 8, .width = .fill, .padding = .all(10), .background = p.wash, .radius = 10, .border = p.hairline }, null);
    defer c.end();
    const id = c.node(i).id;
    const box = x.st.boxState(x.b.gpa, id);
    const box_it = c.interact(i, .{});
    if (box_it.hovered and c.input.zoom != 1.0) {
        box.scale = std.math.clamp(box.scale * c.input.zoom, 0.5, 4.0);
        c.changed = true;
    }
    ui.row(c, .{ .gap = 6, .width = .fill, .align_items = .center });
    ui.text(c, language, .{ .size = 11 * z, .color = p.muted });
    ui.spacer(c);
    if (!x.o.drawn) {
        if (controls.door(c, p, "minus.magnifyingglass", .{ .help = "Shrink diagram" }).clicked) {
            box.scale = std.math.clamp(box.scale - 0.25, 0.5, 4.0);
            c.changed = true;
        }
        const pct: u32 = @intFromFloat(@round(box.scale * 100.0));
        if (plate.quick(c, p, c.print("{d}%", .{pct}), null).clicked) {
            box.scale = 1.0;
            c.changed = true;
        }
        if (controls.door(c, p, "plus.magnifyingglass", .{ .help = "Stretch diagram" }).clicked) {
            box.scale = std.math.clamp(box.scale + 0.25, 0.5, 4.0);
            c.changed = true;
        }
    }
    if (controls.door(c, p, "chevron.left.forwardslash.chevron.right", .{ .help = "Show Code" }).clicked) {
        x.st.sources.put(x.b.gpa, id, {}) catch {};
        c.changed = true;
    }
    const until = x.st.copied.get(id);
    const copied = if (until) |u| c.time < u else false;
    if (until != null and !copied) _ = x.st.copied.remove(id);
    if (copied) c.frameIn(@floatCast(until.? - c.time));
    if (plate.quick(c, p, if (copied) "Copied" else "Copy", null).clicked) {
        nanoui.clipboard.writeText(text);
        x.st.copied.put(x.b.gpa, id, c.time + 1.5) catch {};
        c.frameIn(1.5);
        c.changed = true;
    }
    ui.end(c);
    if (!x.o.drawn) {
        const sc = c.open(.{ .direction = .row, .width = .fill, .scroll_x = true, .scroll_bar = true }, null);
        const sc_id = c.node(sc).id;
        const sc_it = c.interact(sc, .{});
        if (sc_it.pressed) {
            if (box.drag_start == 0) {
                box.drag_start = c.input.mouse.x;
                box.drag_base = c.scroll_x.get(sc_id) orelse 0;
            }
            c.setScroll(sc_id, .x, @max(0, box.drag_base - (c.input.mouse.x - box.drag_start)));
            c.cursor = .closed_hand;
            c.changed = true;
        } else {
            box.drag_start = 0;
            if (sc_it.hovered) c.cursor = .open_hand;
        }
        ui.row(c, .{ .width = .auto, .justify = .center });
        _ = ui.image(c, .{
            .key = c.print("mermaid-{x}", .{pkey}),
            .bytes = bytes,
            .max_width = std.math.inf(f32),
            .max_height = std.math.inf(f32),
            .radius = 0,
            .scale = 2.0 / box.scale,
        });
        ui.end(c);
        c.end();
        const bar = c.open(.{ .width = .fill, .height = .{ .px = 6 }, .align_items = .center, .justify = .center }, null);
        const bar_it = c.interact(bar, .{});
        c.addA11y(bar, .splitter, "Stretch diagram", "", false, true);
        if (bar_it.hovered or bar_it.pressed) c.cursor = .resize_up_down;
        if (bar_it.double_clicked) {
            box.scale = 1.0;
            c.changed = true;
        } else if (bar_it.pressed) {
            if (box.pan_x == 0) {
                box.pan_x = c.input.mouse.y;
                box.drag_base = box.scale;
            }
            box.scale = std.math.clamp(box.drag_base + (c.input.mouse.y - box.pan_x) / 160.0, 0.5, 4.0);
            c.changed = true;
        } else box.pan_x = 0;
        _ = c.leaf(.{ .width = .{ .px = 32 }, .height = .{ .px = 3 }, .radius = 1.5, .background = if (bar_it.hovered or bar_it.pressed) p.muted else p.hairline }, .none, null);
        c.end();
        return;
    }
    ui.row(c, .{ .width = .fill, .justify = .center });
    defer ui.end(c);
    _ = ui.image(c, .{
        .key = c.print("mermaid-{x}", .{pkey}),
        .bytes = bytes,
        .max_width = std.math.inf(f32),
        .max_height = std.math.inf(f32),
        .radius = 0,
        .scale = 2,
    });
}

/// `Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6)`:
/// the header semibold, a divider, the rows; each column as wide as its
/// widest cell. Padded 10 on a wash, scrolling sideways unless drawn.
fn table(x: *const Ctx, header: []const []const u8, rows: []const []const []const u8) void {
    const c = x.c;
    const p = x.p;
    const a = c.alloc();
    const z = x.o.zoom;
    const outer = c.open(.{ .gap = 6, .width = if (x.o.drawn) .auto else .fill, .padding = .all(10), .background = p.wash, .radius = 8, .border = p.hairline, .selectable = true }, null);
    defer c.end();
    const id = c.node(outer).id;
    const box = x.st.boxState(x.b.gpa, id);
    const head_style: ui.TextStyle = .{ .size = 12.5 * z, .weight = .semibold, .color = p.ink };
    const cell_style: ui.TextStyle = .{ .size = 12.5 * z, .color = p.ink };
    var columns = header.len;
    for (rows) |r| columns = @max(columns, r.len);
    const widths = a.alloc(f32, columns) catch return;
    @memset(widths, 0);
    const max_col: f32 = 280 * z * box.col_scale;
    for (header, 0..) |cell, i| widths[i] = @max(widths[i], @min(max_col, @ceil(measure(x, cell, head_style) * box.col_scale)));
    for (rows) |r| for (r, 0..) |cell, i| {
        widths[i] = @max(widths[i], @min(max_col, @ceil(measure(x, cell, cell_style) * box.col_scale)));
    };
    const gaps: f32 = 14 * @as(f32, @floatFromInt(columns -| 1));
    var natural: f32 = 0;
    for (widths) |w| natural += w;
    if (!x.o.drawn) if (c.rects.get(id)) |r| {
        const avail = @max(0, r.w - 20 - gaps);
        if (natural > 0 and natural < avail) {
            const stretch = avail / natural;
            for (widths) |*w| w.* = @round(w.* * stretch);
            natural = 0;
            for (widths) |w| natural += w;
        }
    };
    const total = natural + gaps;

    if (!x.o.drawn) {
        const sc = c.open(.{ .direction = .row, .width = .fill, .scroll_x = true, .scroll_bar = true }, null);
        const sc_id = c.node(sc).id;
        const sc_it = c.interact(sc, .{});
        if (sc_it.pressed and c.selection.hit == null and !c.selection.dragging) {
            if (box.drag_start == 0) {
                box.drag_start = c.input.mouse.x;
                box.drag_base = c.scroll_x.get(sc_id) orelse 0;
            }
            c.setScroll(sc_id, .x, @max(0, box.drag_base - (c.input.mouse.x - box.drag_start)));
            c.changed = true;
        } else box.drag_start = 0;
    }
    ui.column(c, .{ .gap = 6 });
    gridRow(x, header, widths, head_style);
    // `Divider()`: the system separator, not a Kea grey.
    _ = c.leaf(.{ .width = .{ .px = total }, .height = .{ .px = 1 }, .background = @import("../design/menu.zig").separatorColor(c.theme.dark) }, .none, null);
    for (rows) |r| gridRow(x, r, widths, cell_style);
    ui.end(c);
    if (!x.o.drawn) {
        c.end();
        const bar = c.open(.{ .width = .fill, .height = .{ .px = 6 }, .align_items = .center, .justify = .center }, null);
        const bar_it = c.interact(bar, .{});
        c.addA11y(bar, .splitter, "Stretch table", "", false, true);
        if (bar_it.hovered or bar_it.pressed) c.cursor = .resize_left_right;
        if (bar_it.double_clicked) {
            box.col_scale = 1.0;
            c.changed = true;
        } else if (bar_it.pressed) {
            if (box.pan_x == 0) {
                box.pan_x = c.input.mouse.x;
                box.drag_base = box.col_scale;
            }
            box.col_scale = std.math.clamp(box.drag_base + (c.input.mouse.x - box.pan_x) / 200.0, 0.6, 3.0);
            c.changed = true;
        } else box.pan_x = 0;
        _ = c.leaf(.{ .width = .{ .px = 32 }, .height = .{ .px = 3 }, .radius = 1.5, .background = if (bar_it.hovered or bar_it.pressed) p.muted else p.hairline }, .none, null);
        c.end();
    }
}

fn gridRow(x: *const Ctx, cells: []const []const u8, widths: []const f32, style: ui.TextStyle) void {
    const c = x.c;
    ui.row(c, .{ .gap = 14 });
    defer ui.end(c);
    var st = style;
    st.wrap = true;
    for (cells, 0..) |cell, i| {
        ui.column(c, .{ .width = .{ .px = widths[i] } });
        rich(x, cell, st, true);
        ui.end(c);
    }
}

/// The width of `src` shown on one line in `style`.
fn cachedShown(x: *const Ctx, src: []const u8) inline_.Shown {
    const k = textKey(src);
    if (x.st.inlines_cache.get(k)) |sh| return sh;
    if (!x.o.cache or x.st.inlines_cache.count() >= 4096) {
        return inline_.shown(x.c.alloc(), src) catch inline_.Shown{ .text = src, .runs = &.{}, .links = &.{} };
    }
    const sh = inline_.shown(x.st.arenaAlloc(x.b.gpa), src) catch return inline_.Shown{ .text = src, .runs = &.{}, .links = &.{} };
    x.st.inlines_cache.put(x.b.gpa, k, sh) catch {};
    return sh;
}

/// The width of `src` shown on one line in `style`.
fn measure(x: *const Ctx, src: []const u8, style: ui.TextStyle) f32 {
    const shown = cachedShown(x, src);
    const spans = toSpans(x, shown) catch return x.c.text.width(shown.text, style);
    var w: f32 = 0;
    var it: Segments = .{ .spans = spans, .end = shown.text.len };
    while (it.next()) |seg| w += x.c.text.width(shown.text[seg.start..seg.end], seg.style(style));
    return @ceil(w);
}

/// `Text(Markdown.shown(src))` in `style` (`selectable` as
/// `.textSelection(.enabled)`); its web links open in a new tab when clicked.
pub fn rich(x: *const Ctx, src: []const u8, style: ui.TextStyle, selectable: bool) void {
    const c = x.c;
    const shown = cachedShown(x, src);
    const spans = toSpans(x, shown) catch &.{};
    const i = c.leaf(.{ .width = if (style.wrap) .fill else .auto, .selectable = selectable }, .{ .text = .{ .str = shown.text, .style = style, .color = style.color orelse x.p.ink, .spans = spans } }, null);
    for (shown.links) |l| {
        if (opens(l.url)) return follow(x, i, shown, spans, style);
    }
}

/// Only web addresses open from an answer.
fn opens(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "https://") or std.ascii.startsWithIgnoreCase(url, "http://");
}

/// The pointer over the text `i`: a hand over a link, and a click on one
/// opens it in a new tab in front.
fn follow(x: *const Ctx, i: u32, shown: inline_.Shown, spans: []const ui.Span, style: ui.TextStyle) void {
    const c = x.c;
    const it = c.interact(i, .{});
    if (!it.hovered and !it.clicked) return;
    const r = it.rect orelse return;
    const at = byteAt(c, shown.text, spans, style, r, c.input.mouse);
    const url: ?[]const u8 = if (at) |k| for (shown.links) |l| {
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
        const w = c.text.width(piece, st);
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

        fn style(s: Seg, base: ui.TextStyle) ui.TextStyle {
            var st = base;
            const sp = s.span orelse return st;
            if (sp.weight) |w| st.weight = w;
            st.italic = st.italic or sp.italic;
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
        const seg: Seg = .{ .start = it.pos, .end = stop, .span = over };
        it.pos = stop;
        return seg;
    }
};

/// SwiftUI's look of each inline: strong bold, emphasis italic, code
/// monospaced on wash (the assignment's; Swift's has no fill), strikethrough
/// struck, a web link in the accent, underlined.
fn toSpans(x: *const Ctx, shown: inline_.Shown) ![]const ui.Span {
    if (shown.runs.len == 0) return &.{};
    const out = try x.c.alloc().alloc(ui.Span, shown.runs.len);
    for (shown.runs, out) |r, *sp| {
        const web = r.flags.link and for (shown.links) |l| {
            if (r.start >= l.start and r.end <= l.end) break opens(l.url);
        } else false;
        sp.* = .{
            .start = r.start,
            .end = r.end,
            .weight = if (r.flags.bold) .bold else null,
            .italic = r.flags.italic,
            .mono = r.flags.code,
            .background = if (r.flags.code) x.p.wash else null,
            .strike = r.flags.strike,
            .underline = web,
            .color = if (web) x.p.blue else null,
        };
    }
    return out;
}

test {
    _ = inline_;
    _ = code;
    _ = @import("mermaid/draw.zig");
}
