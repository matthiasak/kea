//! `BookmarksBar` (BookmarksBar.swift): the top of the bookmarks in a thin
//! row above the page. A folder opens as a menu; more than the row holds
//! scrolls sideways. Off unless asked for; it goes with the tabs when they
//! fold away and when a video takes the screen (`Room.barShown`).
const ui = @import("nanoui").ui;
const Browser = @import("../../model/browser.zig").Browser;
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const Bookmarks = bm.Bookmarks;
const Palette = @import("../../design/palette.zig").Palette;
const motion = @import("../../design/motion.zig");
const outline = @import("outline.zig");
const actions = @import("actions.zig");
const menu = @import("menu.zig");
const outline_menu = @import("outline_menu.zig");

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
    _ = c.open(.{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = px(width),
        .height = px(height),
        .background = if (on_frame) p.frame else p.ground,
        .clip = true,
    }, "kea.bookmarks.bar.frame");
    defer c.end();
    const bar = c.open(.{
        .direction = .row,
        .width = .fill,
        .height = .fill,
        .padding = .xy(10, 0),
        .gap = 2,
        .align_items = .center,
        .scroll_x = true,
        .scroll_bar = false,
    }, "kea.bookmarks.bar");
    const bar_it = c.interact(bar, .{});
    var child_right_clicked = false;
    const roots = b.bookmarks.roots;
    var idx: usize = 0;
    while (idx < roots.len) {
        if (!roots[idx].isFolder()) if (Bookmarks.cat.norm(roots[idx].category)) |cat| {
            var end = idx + 1;
            while (end < roots.len and !roots[end].isFolder() and Bookmarks.cat.optEq(Bookmarks.cat.norm(roots[end].category), cat)) : (end += 1) {}
            _ = c.open(.{
                .direction = .row,
                .height = px(24),
                .padding = .{ .left = 7, .right = 3, .top = 1, .bottom = 1 },
                .gap = 1,
                .radius = 7,
                .align_items = .center,
                .background = if (on_frame) p.side_wash.alpha(0.75) else p.wash.alpha(0.85),
                .border = p.hairline.alpha(0.9),
                .border_width = 1,
            }, c.print("bm.bar.cat.{d}", .{idx}));
            ui.text(c, cat, .{ .size = 10.5, .weight = .semibold, .color = p.muted });
            _ = c.leaf(.{ .width = px(1), .height = px(11), .background = p.hairline }, .none, null);
            for (roots[idx..end]) |*node| {
                if (item(b, c, p, node, on_frame)) child_right_clicked = true;
            }
            c.end();
            if (end < roots.len) _ = c.leaf(.{ .width = px(4) }, .none, null);
            idx = end;
            continue;
        };
        if (item(b, c, p, &roots[idx], on_frame)) child_right_clicked = true;
        idx += 1;
    }
    c.end();
    if (!on_frame) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = height - 1 }, .width = .fill, .height = px(1), .background = p.hairline }, .none, null);
    if (bar_it.right_clicked and !child_right_clicked) outline_menu.barEmptyPopup(b, c.input.mouse);
}

/// One on the bar. A bookmark without a name is its icon alone, in a
/// square as tall as the others, its address on hover.
fn item(b: *Browser, c: *ui.Context, p: *const Palette, node: *const Bookmark, on_frame: bool) bool {
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
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    if (h > 0.001) c.node(i).style.background = (if (on_frame) p.side_hover else p.hover).alpha(h);
    if (node.isFolder())
        ui.icon(c, "folder", .{ .size = 10.5, .color = p.muted })
    else
        outline.siteMark(b, c, p, node, 13);
    if (!bare) {
        ui.column(c, .{ .max_width = 150 });
        ui.text(c, node.title, .{ .size = 12, .color = p.ink, .truncate = .ellipsis });
        ui.end(c);
    }
    if (node.isFolder()) ui.icon(c, "chevron.down", .{ .size = 7.5, .weight = .semibold, .color = p.faint });
    c.end();
    if (it.clicked) {
        if (node.isFolder()) menu.popUp(b, c, node.id) else if (node.url) |u| b.visit(u, c.input.cmd);
    }
    if (it.middle_clicked) if (node.url) |u| actions.pickBookmark(b, u, true, .{ .shift = c.input.shift });
    if (it.right_clicked) {
        outline_menu.popup(b, c, .{ .list = .dropdown, .picks = false }, node.id);
        return true;
    }
    return false;
}
