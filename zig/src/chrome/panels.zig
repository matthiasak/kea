//! The Bookmarks side panel, 9 pt `EdgeHandle` drag strips, the floating
//! opaque Omnibox dropdown (with Gaussian shadow), and FindBar.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Bookmark = @import("../data/bookmarks.zig").Bookmark;
const Palette = @import("window_view.zig").Palette;

pub fn drawEdgeHandle(b: *Browser, c: *ui.Context, pal: Palette, width_ptr: *f32, min_w: f32, max_w: f32, std_w: f32, grows_right: bool, name: []const u8) void {
    const idx = c.open(.{ .width = .{ .px = 9 }, .height = .fill, .align_items = .center, .justify = .center }, name);
    const it = c.interact(idx, .{});
    c.addA11y(idx, .splitter, name, "", false, true);
    if (it.hovered or it.pressed) c.cursor = .resize_left_right;
    if (it.double_clicked) {
        width_ptr.* = std_w;
        c.changed = true;
        b.syncStageHost();
    } else if (it.pressed) {
        if (it.rect) |r| {
            const dx = c.input.mouse.x - (r.x + r.w * 0.5);
            const delta = if (grows_right) dx else -dx;
            const next = std.math.clamp(width_ptr.* + delta, min_w, max_w);
            if (@abs(next - width_ptr.*) > 0.25) {
                width_ptr.* = next;
                c.changed = true;
            }
        }
    }
    _ = c.leaf(.{
        .width = .{ .px = 2 },
        .height = .fill,
        .background = if (it.hovered or it.pressed) pal.muted else ui.Color.transparent,
    }, .none, null);
    c.end();
}

pub fn drawMarksPanel(b: *Browser, c: *ui.Context, pal: Palette, on_left: bool) void {
    if (!on_left) drawEdgeHandle(b, c, pal, &b.prefs.marks_width, 176, 420, 260, false, "marks-edge");
    ui.column(c, .{
        .width = .{ .px = b.prefs.marks_width },
        .height = .fill,
        .background = pal.ground,
        .border = pal.hairline,
        .padding = .all(12),
        .gap = 8,
    });
    {
        ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 4 });
        ui.text(c, "Bookmarks", .{ .size = 14, .weight = .semibold, .color = pal.ink });
        ui.spacer(c);
        if (ui.button(c, "", .{ .variant = .ghost, .icon = "arrow.left.and.right", .size = 12 }).clicked) {
            const cur = b.prefs.effectiveMarksSide();
            b.prefs.set("marks_side", if (cur == .left) .right else .left);
        }
        if (ui.button(c, "", .{ .variant = .ghost, .icon = "arrow.up.left.and.arrow.down.right", .size = 12 }).clicked) {
            b.marks_expanded = !b.marks_expanded;
        }
        if (ui.button(c, "", .{ .variant = .ghost, .icon = "xmark", .size = 12 }).clicked) {
            b.marks_open = false;
            b.syncStageHost();
        }
        ui.end(c);

        _ = ui.textField(c, &b.marks_filter_buf, .{ .placeholder = "Search bookmarks", .width = .fill });
        ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 4 });
        const q = b.marks_filter_buf.text();
        if (std.mem.trim(u8, q, " ").len == 0) {
            var idx: usize = 0;
            drawMarkRows(b, c, b.bookmarks.roots, &idx);
        } else for (b.bookmarks.matches(c.alloc(), q) catch &.{}, 0..) |m, idx| drawMarkRow(b, c, m.node, idx);
        ui.end(c);
    }
    ui.end(c);
    if (on_left) drawEdgeHandle(b, c, pal, &b.prefs.marks_width, 176, 420, 260, true, "marks-edge");
}

/// Every site and folder, folders opened, as one list.
fn drawMarkRows(b: *Browser, c: *ui.Context, nodes: []const Bookmark, idx: *usize) void {
    for (nodes) |*bm| {
        drawMarkRow(b, c, bm, idx.*);
        idx.* += 1;
        drawMarkRows(b, c, bm.children orelse &.{}, idx);
    }
}

fn drawMarkRow(b: *Browser, c: *ui.Context, bm: *const Bookmark, idx: usize) void {
    ui.key(c, c.print("bm-side-{d}", .{idx}));
    if (ui.button(c, bm.title, .{ .width = .fill, .variant = .ghost, .size = 12.5, .icon = "bookmark" }).clicked) {
        if (bm.url) |u| b.goUrl(u);
    }
}

pub fn drawOmniboxOverlay(b: *Browser, c: *ui.Context, pal: Palette) void {
    const box_it = ui.pressable(c, .{
        .direction = .column,
        .width = .{ .px = 480 },
        .padding = .all(12),
        .radius = 14,
        .background = pal.ground,
        .border = pal.hairline,
        .shadow = .{ .color = .{ .a = 0.16 }, .blur = 28, .y = 8 },
        .gap = 8,
    }, null);
    _ = box_it;
    defer ui.end(c);

    ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 6 });
    if (b.omni_chip) |chip| {
        ui.badge(c, chip.name, pal.accent);
    }
    const res = ui.textField(c, &b.omni_buf, .{ .placeholder = "Search or enter address", .width = .fill });
    if (res.changed) b.updateOmniTyped(b.omni_buf.text());
    if (res.submitted) b.navigateInput(b.omni_buf.text());
    ui.end(c);

    if (b.omni_offer_len > 0) {
        const off = b.omni_offer[0..b.omni_offer_len];
        if (ui.button(c, off, .{ .width = .fill, .variant = .ghost, .icon = "globe", .size = 13 }).clicked) {
            b.navigateInput(off);
        }
    }

    const sugs = b.history.suggestions(c.alloc(), b.omni_buf.text(), 5) catch &.{};
    for (sugs, 0..) |sg, idx| {
        ui.key(c, c.print("omni-sug-{d}", .{idx}));
        if (ui.button(c, if (sg.title.len > 0) sg.title else sg.url, .{ .width = .fill, .variant = .ghost, .icon = "clock", .size = 12.5 }).clicked) {
            b.goUrl(sg.url);
        }
    }
}

pub fn drawFindBar(b: *Browser, c: *ui.Context, pal: Palette) void {
    ui.row(c, .{
        .width = .fill,
        .height = .{ .px = 36 },
        .padding = .xy(12, 4),
        .background = pal.ground,
        .border = pal.hairline,
        .align_items = .center,
        .gap = 8,
    });
    defer ui.end(c);
    _ = ui.textField(c, &b.find_buf, .{ .placeholder = "Find on page", .width = .{ .px = 240 } });
    if (ui.button(c, "", .{ .variant = .ghost, .icon = "xmark", .size = 12 }).clicked) {
        b.find_open = false;
    }
}
