//! `BookmarksDropdown` (Bookmarks.swift 1394-1503): the button's list — the
//! tree, and the two things that aren't in it.
const ui = @import("nanoui").ui;
const Browser = @import("../../model/browser.zig").Browser;
const Palette = @import("../../design/palette.zig").Palette;
const motion = @import("../../design/motion.zig");
const sheet = @import("../sheet.zig");
const actions = @import("actions.zig");
const outline = @import("outline.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.column(c, .{ .width = px(280) });
    defer ui.end(c);
    if (b.bookmarks.isEmpty()) {
        ui.column(c, .{ .width = .fill, .padding = .all(14) });
        ui.text(c, "No bookmarks yet \u{2014} nothing pocketed", .{ .size = 12.5, .color = p.muted, .wrap = true });
        ui.end(c);
    } else {
        // Its height taken once, as it opened: a folder opened in it scrolls.
        ui.scroll(c, .{ .width = .fill, .height = px(b.marks_ui.dropdown_height), .padding = .all(6), .scroll_bar = false });
        outline.view(b, c, p, .{ .list = .dropdown });
        ui.end(c);
    }
    _ = c.leaf(.{ .width = .fill, .height = px(1), .background = p.hairline }, .none, null);
    ui.column(c, .{ .width = .fill, .gap = 1, .padding = .all(6) });
    defer ui.end(c);
    const kept = actions.pageKept(b);
    if (foot(c, p, if (kept) "bookmark.fill" else "bookmark", if (kept) "Edit This Bookmark\u{2026}" else "Add This Page")) actions.bookmarkCurrent(b);
    if (foot(c, p, null, "Manage Bookmarks\u{2026}")) {
        b.overlay = null;
        sheet.show(b, .bookmarking);
    }
}

/// One of the two lines under the tree.
fn foot(c: *ui.Context, p: *const Palette, symbol: ?[]const u8, title: []const u8) bool {
    const i = c.open(.{ .direction = .row, .gap = 8, .padding = .xy(10, 6), .width = .fill, .radius = 8, .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, title, "", false, true);
    c.node(i).style.background = p.wash.alpha(motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0));
    if (symbol) |s|
        ui.icon(c, s, .{ .size = 11, .frame = 14, .color = p.muted })
    else
        _ = c.leaf(.{ .width = px(14) }, .none, null);
    ui.text(c, title, .{ .size = 12.5, .color = p.ink });
    ui.spacer(c);
    return it.clicked;
}
