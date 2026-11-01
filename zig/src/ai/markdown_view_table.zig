//! An answer's Markdown table (markdown_view.zig): a flush editorial grid
//! fitted to the answer's width, its cells wrapped; sideways scrolling only past it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const view = @import("markdown_view.zig");
const rich = @import("markdown_view_rich.zig");
const theme = @import("markdown_theme.zig");

const col_gap = 16;

/// The header small and muted over a rule, the rows apart by hairline
/// rules (`tern`'s flush tables); each column as wide as its widest
/// cell, narrowed to fit while wrapped. No box: padded 10 sideways.
/// Selected, it copies as GFM: `| a | b |` rows, the header's `|---|` under it.
pub fn table(x: *const view.Ctx, header: []const []const u8, rows: []const []const []const u8, cp: rich.Copy) void {
    const c = x.c;
    const p = x.p;
    const a = c.alloc();
    const z = x.o.zoom;
    const th = theme.MdTheme.of(c.theme.dark, p);
    const outer = c.open(.{ .gap = 6, .width = if (x.o.drawn) .auto else .fill, .padding = .xy(10, 4), .selectable = true }, null);
    defer c.end();
    const id = c.node(outer).id;
    const box = x.st.boxState(x.b.gpa, id);
    const head_style: ui.TextStyle = .{ .size = 11.5 * z, .weight = .medium, .color = th.table_head };
    const cell_style: ui.TextStyle = .{ .size = 12.5 * z, .color = th.body };
    var columns = header.len;
    for (rows) |r| columns = @max(columns, r.len);
    const widths = a.alloc(f32, columns) catch return;
    @memset(widths, 0);
    const max_col: f32 = 280 * z * box.col_scale;
    for (header, 0..) |cell, i| widths[i] = @max(widths[i], @min(max_col, @ceil(rich.measure(x, cell, head_style) * box.col_scale)));
    for (rows) |r| for (r, 0..) |cell, i| {
        widths[i] = @max(widths[i], @min(max_col, @ceil(rich.measure(x, cell, cell_style) * box.col_scale)));
    };
    const gaps: f32 = col_gap * @as(f32, @floatFromInt(columns -| 1));
    const rect = c.rects.get(id);
    if (rect == null and !x.o.drawn) c.animationFrame();
    const avail: f32 = if (rect) |r| @max(0, r.w - 20 - gaps) else @max(160, x.b.prefs.chat_width - 72 - gaps);
    // Stretched by hand (`col_scale` past 1), the columns keep their widths.
    if (!x.o.drawn and box.wrapped and box.col_scale <= 1) fit(widths, avail, 48 * z);
    var natural: f32 = 0;
    for (widths) |w| natural += w;
    if (!x.o.drawn and rect != null and natural > 0 and natural < avail) {
        const stretch = avail / natural;
        for (widths) |*w| w.* = @floor(w.* * stretch);
        natural = 0;
        for (widths) |w| natural += w;
    }
    const total = natural + gaps;
    const scrolls = !x.o.drawn and (!box.wrapped or natural > avail + 1.5);

    if (scrolls) {
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
    ui.column(c, .{});
    var delim: std.ArrayList(u8) = .empty;
    delim.appendSlice(a, " |\n|") catch {};
    for (header) |_| delim.appendSlice(a, "---|") catch {};
    gridRow(x, header, widths, head_style, .{ .bottom = 7 * z }, .{ .prefix = c.print("{s}| ", .{cp.prefix}), .suffix = delim.items, .join = cp.join });
    rule(c, total, th.table_head_rule);
    for (rows, 0..) |r, k| {
        if (k > 0) rule(c, total, th.table_row_rule);
        gridRow(x, r, widths, cell_style, .{ .top = 7 * z, .bottom = 7 * z }, .{ .prefix = c.print("{s}| ", .{cp.prefix}), .suffix = " |" });
    }
    ui.end(c);
    if (scrolls) c.end();
    if (!x.o.drawn) {
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

/// Narrows `widths` in proportion until they add up to at most `avail`;
/// none below `min_col` (those already narrower stay as they are).
fn fit(widths: []f32, avail: f32, min_col: f32) void {
    // Each pass sets at least one column to `min_col`, or is the last.
    for (0..widths.len + 1) |_| {
        var fixed: f32 = 0;
        var flex: f32 = 0;
        for (widths) |w| if (w <= min_col) {
            fixed += w;
        } else {
            flex += w;
        };
        if (flex == 0) return;
        const k = (avail - fixed) / flex;
        if (k >= 1) return;
        var floored = false;
        for (widths) |*w| if (w.* > min_col and w.* * k <= min_col) {
            w.* = min_col;
            floored = true;
        };
        if (floored) continue;
        for (widths) |*w| if (w.* > min_col) {
            w.* = @floor(w.* * k);
        };
        return;
    }
}

test "a table's columns narrow in proportion, none under the least" {
    var w = [_]f32{ 300, 100, 20 };
    fit(&w, 220, 48);
    try std.testing.expectEqual(@as(f32, 20), w[2]);
    try std.testing.expect(w[0] + w[1] + w[2] <= 220);
    try std.testing.expect(w[0] > 2.5 * w[1] and w[1] >= 48);
    var v = [_]f32{ 400, 60 };
    fit(&v, 200, 48);
    try std.testing.expect(v[1] == 48 and v[0] >= 151 and v[0] + v[1] <= 200);
    var u = [_]f32{ 50, 60 };
    fit(&u, 200, 48);
    try std.testing.expectEqualSlices(f32, &.{ 50, 60 }, &u);
}

fn rule(c: *ui.Context, w: f32, color: ui.Color) void {
    _ = c.leaf(.{ .width = .{ .px = w }, .height = .{ .px = 1 }, .background = color }, .none, null);
}

/// A row's cells; `cp` copies the row, its cells apart by ` | `.
fn gridRow(x: *const view.Ctx, cells: []const []const u8, widths: []const f32, style: ui.TextStyle, pad: ui.Edges, cp: rich.Copy) void {
    const c = x.c;
    ui.row(c, .{ .gap = col_gap, .padding = pad, .align_items = .start });
    defer ui.end(c);
    var st = style;
    st.wrap = true;
    for (cells, 0..) |cell, i| {
        ui.column(c, .{ .width = .{ .px = widths[i] } });
        rich.rich(x, cell, st, true, .{
            .prefix = if (i == 0) cp.prefix else "",
            .suffix = if (i + 1 == cells.len) cp.suffix else "",
            .join = if (i == 0) cp.join else " | ",
        });
        ui.end(c);
    }
}
