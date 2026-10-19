//! `BookmarksBar` (BookmarksBar.swift): the top of the bookmarks in a thin
//! row above the page. A folder opens as a menu; more than the row holds
//! scrolls sideways. Off unless asked for; it goes with the tabs when they
//! fold away and when a video takes the screen (`Room.barShown`).
const ui = @import("nanoui").ui;
const Browser = @import("../../model/browser.zig").Browser;
const Bookmark = @import("../../data/bookmarks.zig").Bookmark;
const Palette = @import("../../design/palette.zig").Palette;
const outline = @import("outline.zig");
const actions = @import("actions.zig");
const menu = @import("menu.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

pub const height: f32 = 30;

/// At (`x`, `y`), `width` wide. `on_frame`: on the window's ground above
/// the page's card, with the tabs down the side — the frame's colour and
/// no line of its own, the card's edge being the line.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, x: f32, y: f32, width: f32, on_frame: bool) void {
    ui.row(c, .{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = px(width),
        .height = px(height),
        .padding = .xy(10, 0),
        .gap = 2,
        .align_items = .center,
        .background = if (on_frame) p.frame else p.ground,
        .scroll_x = true,
        .scroll_bar = false,
    });
    defer ui.end(c);
    if (!on_frame) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = -10, .y = height - 1 }, .width = px(width), .height = px(1), .background = p.hairline }, .none, null);
    for (b.bookmarks.roots) |*node| item(b, c, p, node);
}

/// One on the bar. A bookmark without a name is its icon alone, in a
/// square as tall as the others, its address on hover.
fn item(b: *Browser, c: *ui.Context, p: *const Palette, node: *const Bookmark) void {
    const bare = node.unnamed();
    const i = c.open(.{
        .direction = .row,
        .gap = 6,
        .padding = .xy(if (bare) 0 else 8, 0),
        .min_width = if (bare) 22 else 0,
        .height = px(22),
        .radius = 6,
        .align_items = .center,
        .justify = .center,
        .control = true,
    }, c.print("bm.bar.{s}", .{&node.id.string()}));
    const it = c.interact(i, .{});
    c.help(i, node.url orelse node.title);
    c.addA11y(i, if (node.isFolder()) .menu_button else .button, if (bare) node.url.? else node.title, "", false, true);
    if (it.hovered) c.node(i).style.background = p.hover;
    if (node.isFolder())
        ui.icon(c, "folder", .{ .size = 10.5, .color = p.muted })
    else
        outline.siteMark(b, c, p, node, 13);
    if (!bare) {
        ui.column(c, .{ .max_width = 150 });
        ui.text(c, node.title, .{ .size = 12, .color = p.ink, .truncate = true });
        ui.end(c);
    }
    if (node.isFolder()) ui.icon(c, "chevron.down", .{ .size = 7.5, .weight = .semibold, .color = p.faint });
    c.end();
    if (it.clicked) {
        if (node.isFolder()) menu.popUp(b, c, node.id) else if (node.url) |u| b.visit(u, c.input.cmd);
    }
    if (it.middle_clicked) if (node.url) |u| actions.pickBookmark(b, u, true, .{ .shift = c.input.shift });
}
