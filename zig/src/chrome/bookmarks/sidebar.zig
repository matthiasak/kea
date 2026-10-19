//! `BookmarksSidebar` (Bookmarks.swift 1505-1580): the bookmarks in a column
//! of their own beside the page — the dropdown's tree, a click opening a
//! page, a drag putting it in order. The frame, its edge and its header's
//! doors are the side panels' (`side_panels.zig`); this is what is in it.
const ui = @import("nanoui").ui;
const Browser = @import("../../model/browser.zig").Browser;
const Palette = @import("../../design/palette.zig").Palette;
const plate = @import("../controls_plate.zig");
const sheet = @import("../sheet.zig");
const state = @import("state.zig");
const outline = @import("outline.zig");

/// The header's lead: its name, and Manage.
pub fn headerLead(b: *Browser, c: *ui.Context, p: *const Palette) void {
    // Narrow, the name gives way first, as SwiftUI shrinks a Text.
    ui.text(c, "Bookmarks", .{ .size = 12, .weight = .semibold, .color = p.muted, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 0 }, .none, null);
    if (plate.quick(c, p, "Manage", null).clicked) sheet.show(b, .bookmarking);
}

/// Under the header, filling the rest: the tree, or a word when there is none.
pub fn content(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.marks_ui;
    // Opened as the list first shows (`@State` initial value).
    if (!s.sidebar_ready) {
        s.sidebar_ready = true;
        state.opening(b.gpa, &s.sidebar, b.bookmarks.roots);
    }
    if (b.bookmarks.isEmpty()) {
        ui.column(c, .{ .width = .fill, .padding = .all(12) });
        ui.text(c, "No bookmarks yet. Pocket this page with \u{21E7}\u{2318}B.", .{ .size = 12, .color = p.muted, .wrap = true });
        ui.end(c);
        return;
    }
    ui.scroll(c, .{ .width = .fill, .grow = 1, .padding = .all(6) });
    outline.view(b, c, p, .{ .list = .sidebar });
    ui.end(c);
}
