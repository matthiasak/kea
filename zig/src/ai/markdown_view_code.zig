//! `CodeBlock` (AIAssist.swift:1443-1507): a fenced block of an answer on
//! a recessed card — a header strip with its language and Copy over its
//! source, syntax-highlighted (markdown_theme.zig); for Mermaid a door
//! between the drawn diagram (mermaid/draw.zig, kept as a picture) and its
//! highlighted source (`Mermaid.highlighted`, Mermaid.swift:78-99).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const mermaid = @import("mermaid/mermaid.zig");
const draw = @import("mermaid/draw.zig");
const view = @import("markdown_view.zig");
const theme = @import("markdown_theme.zig");
const Copy = @import("markdown_view_rich.zig").Copy;

/// Drawn pictures kept per window; past it the one shown longest ago goes.
const pictures_kept = 24;

/// Selected, the source copies inside its fence (`cp` before it).
pub fn block(x: *const view.Ctx, language: []const u8, text: []const u8, closed: bool, cp: Copy) void {
    const c = x.c;
    const p = x.p;
    const z = x.o.zoom;
    const th = theme.MdTheme.of(c.theme.dark, p);
    const i = c.open(.{ .width = .fill, .background = th.code_block_bg, .radius = 10, .border = th.code_block_border }, null);
    defer c.end();
    const id = c.node(i).id;
    const box = x.st.boxState(x.b.gpa, id);
    const is_mermaid = std.mem.eql(u8, language, "mermaid");
    const source = x.st.sources.contains(id);
    const diagram = if (is_mermaid and closed and !source) mermaid.diagram(c.alloc(), text) else null;

    ui.row(c, .{ .gap = 6, .width = .fill, .align_items = .center, .padding = .{ .left = 12, .right = 6, .top = 4, .bottom = 4 } });
    ui.text(c, if (language.len == 0) "Code" else language, .{ .size = 11 * z, .mono = true, .color = p.muted });
    ui.spacer(c);
    if (!is_mermaid and !x.o.drawn and plate.quick(c, p, if (box.wrapped) "Unwrap" else "Wrap", null).clicked) {
        box.wrapped = !box.wrapped;
        c.changed = true;
    }
    if (is_mermaid) {
        const help = if (source) "Show Diagram" else "Show Code";
        if (controls.door(c, p, if (source) "point.3.connected.trianglepath.dotted" else "chevron.left.forwardslash.chevron.right", .{ .help = help }).clicked) {
            if (source) _ = x.st.sources.remove(id) else x.st.sources.put(x.b.gpa, id, {}) catch {};
            c.changed = true;
        }
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
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = th.code_block_border }, .none, null);
    // The source, the diagram and the stretch bar, under the strip.
    ui.column(c, .{ .gap = 8, .width = .fill, .padding = .all(10) });
    defer ui.end(c);

    if (diagram) |d| {
        // At 100% or less the diagram fits the box; zoomed in, it scrolls sideways.
        const zoomed = !x.o.drawn and box.scale > 1.0;
        const fit_w = if (c.rects.get(id)) |r| @max(80, r.w - 20) else std.math.inf(f32);
        if (zoomed) ui.row(c, .{ .width = .fill, .scroll_x = true, .scroll_bar = true });
        defer if (zoomed) ui.end(c);
        ui.row(c, .{ .width = if (zoomed) .auto else .fill, .justify = .center });
        defer ui.end(c);
        const bytes = picture(x, text, d) orelse return;
        _ = ui.image(c, .{
            .key = c.print("mermaid-{x}", .{pictureKey(text, c.theme.dark, z)}),
            .bytes = bytes,
            .max_width = if (zoomed or x.o.drawn) std.math.inf(f32) else fit_w,
            .max_height = std.math.inf(f32),
            .radius = 0,
            .scale = 2.0 / box.scale,
        });
        return;
    }
    const wrap_code = x.o.drawn or box.wrapped;
    if (!x.o.drawn) {
        _ = c.open(.{
            .direction = .column,
            .width = .fill,
            .max_height = if (box.height > 0) box.height else std.math.inf(f32),
            .scroll = box.height > 0,
            .scroll_x = !wrap_code,
            .scroll_bar = box.height > 0 or !wrap_code,
        }, null);
    }
    const shown = if (std.mem.indexOfScalar(u8, text, '\r') != null) lf(c.alloc(), text) catch text else text;
    const spans: []const ui.Span = (if (is_mermaid) highlighted(c.alloc(), p, shown) else theme.highlightCode(c.alloc(), &th, language, shown)) catch &.{};
    const style: ui.TextStyle = .{ .size = 12 * z, .mono = true, .color = th.body, .wrap = wrap_code, .line_height = 1.4 * 12 * z };
    // Mermaid's header line is 12 points whatever the zoom (`highlighted`):
    // zoomed, it is a line of its own between what comes before and after.
    const head: ?ui.Span = if (is_mermaid and z != 1) for (spans) |sp| {
        if (sp.weight != null) break sp;
    } else null else null;
    const parts = cut(c.alloc(), shown, spans, head) catch {
        if (!x.o.drawn) c.end();
        return;
    };
    ui.column(c, .{ .width = if (wrap_code) .fill else .auto, .selectable = true });
    var first = true;
    var last: usize = 0;
    for (parts, 0..) |part, k| if (part.text != null) {
        last = k;
    };
    const fence = c.print("{s}```{s}\n", .{ cp.prefix, language });
    for (parts, 0..) |part, k| if (part.text) |str| {
        var st = style;
        if (part.fixed) {
            st.size = 12;
            st.line_height = 1.4 * 12;
        }
        const tail = if (k == last and closed) "\n```" else "";
        if (wrap_code) {
            _ = c.leaf(.{ .width = .fill }, .{ .text = .{ .str = str, .style = st, .color = th.body, .spans = part.spans, .copy = .{ .src = str, .prefix = if (first) fence else "", .suffix = tail, .join = if (first) cp.join else "\n" } } }, null);
            first = false;
            continue;
        }
        // Unwrapped, a leaf a line: one unwrapped text is one line, its breaks unshown.
        var start: usize = 0;
        var lines = std.mem.splitScalar(u8, str, '\n');
        while (lines.next()) |line| {
            defer start += line.len + 1;
            const sp = within(c.alloc(), part.spans, @intCast(start), @intCast(start + line.len)) catch &.{};
            const end = lines.index == null;
            _ = c.leaf(.{ .width = .auto }, .{ .text = .{ .str = line, .style = st, .color = th.body, .spans = sp, .copy = .{ .src = line, .prefix = if (first) fence else "", .suffix = if (end) tail else "", .join = if (first) cp.join else "\n" } } }, null);
            first = false;
        }
    };
    ui.end(c);
    if (!x.o.drawn) {
        c.end();
        const bar = c.open(.{ .width = .fill, .height = .{ .px = 6 }, .align_items = .center, .justify = .center }, null);
        const bar_it = c.interact(bar, .{});
        c.addA11y(bar, .splitter, "Stretch code block", "", false, true);
        if (bar_it.hovered or bar_it.pressed) c.cursor = .resize_up_down;
        if (bar_it.double_clicked) {
            box.height = 0;
            c.changed = true;
        } else if (bar_it.pressed) {
            if (box.pan_x == 0) {
                box.pan_x = c.input.mouse.y;
                box.drag_base = if (box.height > 0) box.height else 140;
            }
            box.height = std.math.clamp(box.drag_base + (c.input.mouse.y - box.pan_x), 60, 1200);
            c.changed = true;
        } else box.pan_x = 0;
        _ = c.leaf(.{ .width = .{ .px = 32 }, .height = .{ .px = 3 }, .radius = 1.5, .background = if (bar_it.hovered or bar_it.pressed) p.muted else p.hairline }, .none, null);
        c.end();
    }
}

const Part = struct { text: ?[]const u8 = null, spans: []const ui.Span = &.{}, fixed: bool = false };

/// The source as the lines before the header, the header, and the lines
/// after it, each with its own spans (rebased); all of it as one without
/// a header to set apart.
fn cut(a: std.mem.Allocator, text: []const u8, spans: []const ui.Span, head: ?ui.Span) ![3]Part {
    const h = head orelse return .{ .{ .text = text, .spans = spans }, .{}, .{} };
    var out: [3]Part = .{ .{}, .{ .text = text[h.start..h.end], .fixed = true }, .{} };
    var one = try a.alloc(ui.Span, 1);
    one[0] = h;
    one[0].start = 0;
    one[0].end = h.end - h.start;
    out[1].spans = one;
    // Less the line break either side of the header.
    if (h.start > 0) out[0] = .{ .text = text[0 .. h.start - 1], .spans = try within(a, spans, 0, h.start - 1) };
    if (h.end < text.len) out[2] = .{ .text = text[h.end + 1 ..], .spans = try within(a, spans, h.end + 1, @intCast(text.len)) };
    return out;
}

/// The spans wholly between `from` and `to`, counted from `from`.
fn within(a: std.mem.Allocator, spans: []const ui.Span, from: u32, to: u32) ![]const ui.Span {
    var out: std.ArrayList(ui.Span) = .empty;
    for (spans) |sp| if (sp.start >= from and sp.end <= to) {
        var s = sp;
        s.start -= from;
        s.end -= from;
        try out.append(a, s);
    };
    return out.items;
}

test "a zoomed mermaid source sets its header line apart" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = @import("../design/palette.zig").get(false);
    const src = "%% a note\ngraph TD\nA-->B\n%% end";
    const spans = try highlighted(a, p, src);
    const parts = try cut(a, src, spans, spans[1]);
    try std.testing.expectEqualStrings("%% a note", parts[0].text.?);
    try std.testing.expectEqualStrings("%% a note", parts[0].text.?[parts[0].spans[0].start..parts[0].spans[0].end]);
    try std.testing.expectEqualStrings("graph TD", parts[1].text.?);
    try std.testing.expect(parts[1].fixed and parts[1].spans[0].end == 8);
    try std.testing.expectEqualStrings("A-->B\n%% end", parts[2].text.?);
    try std.testing.expectEqualStrings("%% end", parts[2].text.?[parts[2].spans[0].start..parts[2].spans[0].end]);
}

fn pictureKey(text: []const u8, dark: bool, zoom: f32) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(text);
    h.update(&.{@intFromBool(dark)});
    h.update(std.mem.asBytes(&zoom));
    return h.final();
}

/// The diagram's PNG, drawn once for its source, look and zoom.
fn picture(x: *const view.Ctx, text: []const u8, d: mermaid.Diagram) ?[]const u8 {
    const st = x.st;
    const gpa = x.b.gpa;
    const k = pictureKey(text, x.c.theme.dark, x.o.zoom);
    if (st.pictures.getPtr(k)) |pic| {
        pic.used = x.c.time;
        return pic.bytes;
    }
    if (st.pictures.count() >= pictures_kept) st.forgetOldest(gpa, x.c.time);
    const bytes = draw.png(gpa, d, x.p, x.o.zoom) catch return null;
    st.pictures.put(gpa, k, .{ .bytes = bytes, .used = x.c.time }) catch {
        gpa.free(bytes);
        return null;
    };
    return bytes;
}

fn lf(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, text, "\r\n", "\n"), "\r", "\n");
}

/// `Mermaid.highlighted`: `%%` comments faint, the first line that says
/// something (not `---`) the header, in sunset and semibold; the rest ink.
// The header line's own size (12 points at any zoom) is `block`'s: spans carry no size.
pub fn highlighted(a: std.mem.Allocator, p: *const Palette, text: []const u8) ![]const ui.Span {
    var out: std.ArrayList(ui.Span) = .empty;
    var colored_header = false;
    var start: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        defer start += line.len + 1;
        const t = @import("whitespace.zig").trim(line);
        const end: u32 = @intCast(start + line.len);
        if (std.mem.startsWith(u8, t, "%%")) {
            try out.append(a, .{ .start = @intCast(start), .end = end, .color = p.faint });
        } else if (!colored_header and t.len > 0 and !std.mem.eql(u8, t, "---")) {
            try out.append(a, .{ .start = @intCast(start), .end = end, .color = p.sunset, .weight = .semibold });
            colored_header = true;
        }
    }
    return out.items;
}

test "mermaid highlighted: comments faint, the header sunset and semibold" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = @import("../design/palette.zig").get(false);
    const src = "%% a note\n---\n\ngraph TD\nA-->B\n%% end";
    const spans = try highlighted(arena.allocator(), p, src);
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqualStrings("%% a note", src[spans[0].start..spans[0].end]);
    try std.testing.expectEqualStrings("graph TD", src[spans[1].start..spans[1].end]);
    try std.testing.expectEqual(ui.Weight.semibold, spans[1].weight.?);
    try std.testing.expectEqualStrings("%% end", src[spans[2].start..spans[2].end]);
}
