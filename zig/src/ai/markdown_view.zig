//! `AnswerView` (AIAssist.swift:1325-1441): an answer's Markdown, block by
//! block — headings, paragraphs, lists, quotes, tables
//! (markdown_view_table.zig), rules, code (`CodeBlock`,
//! markdown_view_code.zig) and display math (markdown_view_math.zig) —
//! its inlines from markdown_view_rich.zig. Text selects, as
//! `.textSelection(.enabled)`, and copies as the Markdown it came from.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const markdown = @import("markdown.zig");
const inline_ = @import("markdown_inline.zig");
const code = @import("markdown_view_code.zig");
const table = @import("markdown_view_table.zig");
const mermaid = @import("mermaid/mermaid.zig");
const draw = @import("mermaid/draw.zig");
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const theme = @import("markdown_theme.zig");
const rich_ = @import("markdown_view_rich.zig");
const math_view = @import("markdown_view_math.zig");
const math_layout = @import("math/layout.zig");
const stream = @import("markdown_stream.zig");
const presence = @import("../chrome/presence.zig");
const motion = @import("../design/motion.zig");

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
    /// Laid-out formulas (in `cache_arena`), by TeX, style, size and zoom.
    math_cache: std.AutoHashMapUnmanaged(u64, math_layout.Box) = .empty,
    /// How much of each streaming answer is shown, by `Options.stream_id`.
    streams: std.AutoHashMapUnmanaged(u64, stream.Cursor) = .empty,

    pub const Picture = struct { bytes: []u8, used: f64 };
    pub const BoxState = struct {
        scale: f32 = 1.0,
        height: f32 = 0,
        pan_x: f32 = 0,
        wrapped: bool = true,
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
        s.math_cache.deinit(gpa);
        s.streams.deinit(gpa);
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
        s.math_cache.clearRetainingCapacity();
        s.streams.clearRetainingCapacity();
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

/// `stream_id`: the answer is still coming in, paced out and its unfinished tail
/// parsed each frame (markdown_stream.zig); null draws it whole at once.
pub const Options = struct { zoom: f32 = 1, drawn: bool = false, cache: bool = true, stream_id: ?u64 = null };

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
pub fn answer(b: *Browser, c: *ui.Context, p: *const Palette, st: *State, full: []const u8, o: Options) void {
    var x: Ctx = .{ .b = b, .c = c, .p = p, .st = st, .o = o };
    ui.column(c, .{ .gap = 10 * o.zoom, .width = .fill });
    defer ui.end(c);
    const sid = o.stream_id orelse {
        const parsed = cachedBlocks(st, b.gpa, full, o.cache, c.alloc()) orelse return;
        for (parsed) |blk| block(&x, blk, 0, .{ .join = "\n\n" });
        return;
    };
    // The finished blocks parsed once and kept; only the tail each frame, as it will look done.
    const text = stream.visibleSlice(st, b.gpa, c, sid, full);
    const cut = stream.splitSettled(text);
    x.o.stream_id = null;
    x.o.cache = true;
    const settled = cachedBlocks(st, b.gpa, text[0..cut], true, c.alloc()) orelse &.{};
    var tail_x = x;
    tail_x.o = o;
    tail_x.o.cache = false;
    const tail_src = stream.stabilizeTail(c.alloc(), text[cut..]) catch text[cut..];
    const tail = markdown.blocks(c.alloc(), tail_src) catch &.{};
    for (0..settled.len + tail.len) |i| {
        // Each block arriving fades up into place.
        const fresh = i >= settled.len;
        const v = std.math.clamp(presence.presenceFrom(c, sid ^ (i + 1), if (fresh) 0 else 1, true, motion.settle, null) orelse 1, 0, 1);
        ui.column(c, .{ .width = .fill, .opacity = 0.18 + 0.82 * v, .offset = .{ .y = (1 - v) * 5 } });
        defer ui.end(c);
        if (fresh) block(&tail_x, tail[i - settled.len], 0, .{ .join = "\n\n" }) else block(&x, settled[i], 0, .{ .join = "\n\n" });
    }
}

fn headingSize(level: u8, zoom: f32) f32 {
    return zoom * @as(f32, switch (level) {
        1 => 18,
        2 => 16,
        3 => 14.5,
        else => 13,
    });
}

/// `.lineSpacing(3.6 * zoom)` as a multiple of `style`'s line: airy prose.
fn spaced(c: *ui.Context, style: ui.TextStyle, zoom: f32) ui.TextStyle {
    var s = style;
    const lh = c.text.font(style).lineHeight();
    s.leading = (lh + 3.6 * zoom) / lh;
    return s;
}

/// One block, copied with `cp` (a list item's marker, a quote's `> `).
fn block(x: *const Ctx, blk: markdown.Block, depth: usize, cp: rich_.Copy) void {
    const c = x.c;
    const p = x.p;
    const z = x.o.zoom;
    const th = theme.MdTheme.of(c.theme.dark, p);
    switch (blk) {
        .heading => |h| rich_.rich(x, h.text, .{ .size = headingSize(h.level, z), .weight = .semibold, .color = th.strong, .wrap = true }, true, .{ .prefix = c.print("{s}{s} ", .{ cp.prefix, "######"[0..h.level] }), .join = cp.join }),
        .paragraph => |t| rich_.rich(x, t, spaced(c, .{ .size = 13 * z, .color = th.body, .wrap = true }, z), true, cp),
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
                // Copied as written: `1. ` or `- ` before the item, its later blocks indented under it.
                const lead = c.print("{s}{s} ", .{ cp.prefix, if (l.ordered) marker else "-" });
                const indent: []const u8 = blk: {
                    const s = c.alloc().alloc(u8, lead.len) catch break :blk "";
                    @memset(s, ' ');
                    break :blk s;
                };
                for (item, 0..) |sub, k| block(x, sub, depth + 1, .{
                    .prefix = if (k == 0) lead else indent,
                    .join = if (k == 0 and i == 0) cp.join else "\n",
                });
            }
        },
        .quote => |inner| {
            // The VStack's muted foreground yields to each Text's own ink.
            ui.row(c, .{ .gap = 10, .width = .fill, .align_items = .stretch, .background = th.quote_bg, .radius = 4, .padding = .{ .right = 10, .top = 6 * z, .bottom = 6 * z } });
            defer ui.end(c);
            _ = c.leaf(.{ .width = .{ .px = 3 }, .radius = 1.5, .background = th.quote_bar }, .none, null);
            ui.column(c, .{ .gap = 6 * z, .grow = 1, .min_width = 0 });
            defer ui.end(c);
            const lead = c.print("{s}> ", .{cp.prefix});
            for (inner, 0..) |sub, k| block(x, sub, depth + 1, .{ .prefix = lead, .join = if (k == 0) cp.join else "\n>\n" });
        },
        .table => |t| table.table(x, t.header, t.rows, cp),
        .rule => {
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = p.hairline }, .none, null);
        },
        .math => |m| math_view.displayBlock(x, m.text, m.raw, cp),
        .code => |cb| if (std.mem.eql(u8, cb.language, "mermaid") and cb.closed)
            mermaidCodeBlock(x, cb.language, cb.text)
        else
            code.block(x, cb.language, cb.text, cb.closed, cp),
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
    if (x.st.sources.contains(peek_id)) return code.block(x, language, text, true, .{});
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
                return code.block(x, language, text, true, .{});
            };
            png_bytes = bytes;
        } else |_| {}
    }
    const bytes = png_bytes orelse return code.block(x, language, text, true, .{});

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
        x.b.kea.writeClipboard(text);
        x.st.copied.put(x.b.gpa, id, c.time + 1.5) catch {};
        c.frameIn(1.5);
        c.changed = true;
    }
    ui.end(c);
    if (!x.o.drawn) {
        // At 100% or less the diagram fits the box; zoomed in, it scrolls sideways.
        const zoomed = box.scale > 1.0;
        const fit_w = if (c.rects.get(id)) |r| @max(80, r.w - 20) else std.math.inf(f32);
        if (fit_w == std.math.inf(f32)) c.animationFrame();
        const sc = c.open(.{ .direction = .row, .width = .fill, .scroll_x = zoomed, .scroll_bar = zoomed }, null);
        const sc_id = c.node(sc).id;
        const sc_it = c.interact(sc, .{});
        if (zoomed and sc_it.pressed) {
            if (box.drag_start == 0) {
                box.drag_start = c.input.mouse.x;
                box.drag_base = c.scroll_x.get(sc_id) orelse 0;
            }
            c.setScroll(sc_id, .x, @max(0, box.drag_base - (c.input.mouse.x - box.drag_start)));
            c.cursor = .closed_hand;
            c.changed = true;
        } else {
            box.drag_start = 0;
            if (zoomed and sc_it.hovered) c.cursor = .open_hand;
        }
        ui.row(c, .{ .width = if (zoomed) .auto else .fill, .justify = .center });
        _ = ui.image(c, .{
            .key = c.print("mermaid-{x}", .{pkey}),
            .bytes = bytes,
            .max_width = if (zoomed) std.math.inf(f32) else fit_w,
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

test {
    _ = inline_;
    _ = code;
    _ = table;
    _ = theme;
    _ = rich_;
    _ = stream;
    _ = math_view;
    _ = @import("mermaid/draw.zig");
}
