//! The column's and the panels' `EdgeHandle` (SidePanels.swift:16-184),
//! the Bookmarks side panel, the address field over the page and the find
//! pill: what the window shows until P6 and P8 port Omnibox, Find and
//! SidePanels in full. Colours and sizes from `design/`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Bookmark = @import("../data/bookmarks.zig").Bookmark;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const card = @import("../design/card.zig");
const controls = @import("controls.zig");
const plate = @import("controls_plate.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// An edge being pulled: where the press was and the width then, so the
/// width follows the pointer's travel from there (`EdgeStripView`).
pub const EdgeDrag = struct { id: u64, x: f32, width: f32 };

/// `EdgeHandle`: 9 points over the inner edge of a column `x` from its
/// start, setting prefs `field` within `min…max` as it is pulled, back to
/// `standard` on a double click.
pub fn edgeHandle(b: *Browser, c: *ui.Context, p: *const Palette, comptime field: []const u8, min: f32, max: f32, standard: f32, grows_right: bool, x: f32) void {
    const width = @field(b.prefs.*, field);
    const i = c.open(.{ .absolute = true, .offset = .{ .x = x }, .width = px(9), .height = .fill, .align_items = .center, .justify = .center }, field ++ ".edge");
    const it = c.interact(i, .{});
    c.addA11y(i, .splitter, "Column width", c.print("{d}", .{@round(width)}), false, true);
    if (it.hovered or it.pressed) c.cursor = .resize_left_right;
    if (it.hovered and c.input.pressed) b.edge_drag = .{ .id = it.id, .x = c.input.mouse.x, .width = width };
    if (it.double_clicked) {
        b.edge_drag = null;
        b.prefs.set(field, standard);
        c.changed = true;
    } else if (it.pressed) if (b.edge_drag) |d| if (d.id == it.id) {
        const dx = c.input.mouse.x - d.x;
        const next = std.math.clamp(@round(d.width + if (grows_right) dx else -dx), min, max);
        if (@abs(width - next) >= 0.5) {
            // ponytail: written to defaults when the drag ends, not every frame as
            // Swift's didSet does: a defaults write costs ~1 ms of each drag frame.
            @field(b.prefs.*, field) = next;
            c.changed = true;
        }
    };
    if (!c.input.down) if (b.edge_drag) |d| if (d.id == it.id) {
        b.edge_drag = null;
        if (width != d.width) b.prefs.set(field, width);
    };
    _ = c.leaf(.{ .width = px(2), .height = .fill, .background = if (it.hovered or it.pressed) p.muted else ui.Color.transparent }, .none, null);
    c.end();
}

pub fn marksPanel(b: *Browser, c: *ui.Context, p: *const Palette, on_left: bool, width: ?f32) void {
    const outer = c.open(.{ .width = if (width) |w| px(w) else .fill, .max_width = 760, .height = .fill, .background = p.ground }, "marks-panel");
    defer c.end();
    _ = c.interact(outer, .{});
    defer if (width) |w| {
        // The hairline and the edge on the side the page is, over the panel.
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = if (on_left) w - 1 else 0 }, .width = px(1), .height = .fill, .background = p.hairline }, .none, null);
        edgeHandle(b, c, p, "marks_width", metrics.side_min, metrics.side_max, metrics.side, on_left, if (on_left) w - 9 else 0);
    };
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(12), .gap = 8 });
    defer ui.end(c);
    ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 2 });
    ui.text(c, "Bookmarks", .{ .size = 13, .weight = .semibold, .color = p.ink });
    ui.spacer(c);
    if (controls.door(c, p, "arrow.left.and.right", .{ .help = "Move to Other Side" }).clicked) {
        b.prefs.set("marks_side", if (on_left) .right else .left);
    }
    if (controls.door(c, p, if (width == null) "arrow.down.right.and.arrow.up.left" else "arrow.up.left.and.arrow.down.right", .{ .help = "Expand" }).clicked) {
        b.marks_expanded = !b.marks_expanded;
    }
    if (controls.door(c, p, "xmark", .{ .help = "Close" }).clicked) {
        b.marks_open = false;
        b.marks_expanded = false;
        b.syncStageHost();
    }
    ui.end(c);

    _ = plate.hunt(c, p, &b.marks_filter_buf, "Search bookmarks");
    ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 2, .scroll_bar = false });
    const q = b.marks_filter_buf.text();
    if (std.mem.trim(u8, q, " ").len == 0) {
        var idx: usize = 0;
        markRows(b, c, p, b.bookmarks.roots, &idx);
    } else for (b.bookmarks.matches(c.alloc(), q) catch &.{}, 0..) |m, idx| markRow(b, c, p, m.node, idx);
    ui.end(c);
}

/// Every site and folder, folders opened, as one list.
fn markRows(b: *Browser, c: *ui.Context, p: *const Palette, nodes: []const Bookmark, idx: *usize) void {
    for (nodes) |*bm| {
        markRow(b, c, p, bm, idx.*);
        idx.* += 1;
        markRows(b, c, p, bm.children orelse &.{}, idx);
    }
}

fn markRow(b: *Browser, c: *ui.Context, p: *const Palette, bm: *const Bookmark, idx: usize) void {
    ui.key(c, c.print("bm-side-{d}", .{idx}));
    if (listRow(c, p, if (bm.children != null) "folder" else "bookmark", bm.title, 28).clicked) {
        if (bm.url) |u| b.goUrl(u);
    }
}

/// A line of a list: a symbol and a title, the hover's grey under it.
fn listRow(c: *ui.Context, p: *const Palette, icon: []const u8, title: []const u8, height: f32) ui.Interaction {
    const i = c.open(.{ .direction = .row, .gap = 8, .padding = .xy(8, 0), .width = .fill, .height = px(height), .align_items = .center, .radius = 7, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, title, "", false, true);
    if (it.hovered) c.node(i).style.background = p.hover;
    ui.icon(c, icon, .{ .size = 11, .frame = 15, .color = p.muted });
    ui.text(c, title, .{ .size = 12.5, .color = p.ink, .truncate = true });
    return it;
}

/// The address field over `area` (the page's part of the window), its
/// suggestions under it.
pub fn omnibox(b: *Browser, c: *ui.Context, p: *const Palette, area: ui.Rect) void {
    const w = @min(metrics.field_width, area.w - 28);
    const i = c.open(.{
        .absolute = true,
        .offset = .{ .x = area.x + (area.w - w) / 2, .y = area.y + area.h / 2 - 60 - 25 },
        .width = px(w),
        .padding = .xy(22, 14),
        .radius = 14,
        .background = p.ground,
        .border = p.hairline,
        .shadow = knockout(card.swiftShadow(0.06, 24, 8)),
        .gap = 8,
    }, "omnibox");
    defer c.end();
    _ = c.interact(i, .{});

    ui.row(c, .{ .width = .fill, .height = px(22), .align_items = .center, .gap = 6 });
    if (b.omni_chip) |chip| {
        _ = controls.pill(c, p, chip.name, .{});
    }
    ui.column(c, .{ .grow = 1 });
    if (b.omni_buf.text().len == 0)
        _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = "Enter a web address", .style = .{ .size = 15.5 }, .color = p.ink.alpha(0.3) } }, null);
    const res = ui.textField(c, &b.omni_buf, .{ .bare = true, .size = 15.5, .width = .fill, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
    ui.end(c);
    if (res.changed) b.updateOmniTyped(b.omni_buf.text());
    if (res.submitted) b.navigateInput(b.omni_buf.text());
    ui.end(c);

    if (b.omni_offer_len > 0) {
        const off = b.omni_offer[0..b.omni_offer_len];
        if (listRow(c, p, "globe", off, 32).clicked) b.navigateInput(off);
    }
    const sugs = b.history.suggestions(c.alloc(), b.omni_buf.text(), 5) catch &.{};
    for (sugs, 0..) |sg, idx| {
        ui.key(c, c.print("omni-sug-{d}", .{idx}));
        if (listRow(c, p, "clock", if (sg.title.len > 0) sg.title else sg.url, 32).clicked) b.goUrl(sg.url);
    }
}

/// The find pill, at the page's top trailing corner.
pub fn findBar(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.row(c, .{ .absolute = true, .width = .fill, .justify = .end, .padding = .{ .top = 12, .right = 14 } });
    defer ui.end(c);
    const i = c.open(.{
        .direction = .row,
        .padding = .xy(12, 6),
        .radius = controls.capsule,
        .background = p.ground,
        .border = p.hairline,
        .shadow = knockout(card.swiftShadow(0.08, 10, 3)),
        .align_items = .center,
        .gap = 8,
    }, "find-bar");
    defer c.end();
    _ = c.interact(i, .{});
    ui.column(c, .{ .width = px(150) });
    if (b.find_buf.text().len == 0)
        _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = "Find on page", .style = .{ .size = 13 }, .color = p.muted } }, null);
    _ = ui.textField(c, &b.find_buf, .{ .bare = true, .size = 13, .width = .fill, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
    ui.end(c);
    if (controls.door(c, p, "xmark", .{ .help = "Done   esc" }).clicked) b.find_open = false;
}

fn knockout(s: ui.Shadow) ui.Shadow {
    var k = s;
    k.knockout = true;
    return k;
}
