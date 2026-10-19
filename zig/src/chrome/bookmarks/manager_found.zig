//! What the manager's search finds (`BookmarksPanel.found`): flat, each with
//! the folders it is in. A click picks, a double click opens it (or shows a
//! folder in the tree); nothing here is carried — order is the tree's.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../../model/browser.zig").Browser;
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const Uuid = @import("../../data/json.zig").Uuid;
const Parts = @import("../../data/url.zig").Parts;
const Palette = @import("../../design/palette.zig").Palette;
const motion = @import("../../design/motion.zig");
const plate = @import("../controls_plate.zig");
const tab_menu = @import("../tab_menu.zig");
const actions = @import("actions.zig");
const outline = @import("outline.zig");
const manager = @import("manager.zig");

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const hits = b.bookmarks.matches(c.alloc(), b.marks_ui.picks.query.text()) catch &.{};
    if (hits.len == 0) {
        plate.cardBox(c, p);
        plate.nothing(c, p, "Nothing matches. The kea checked under every rock.");
        ui.end(c);
        return;
    }
    const order = c.alloc().alloc(Uuid, hits.len) catch return;
    for (hits, order) |h, *o| o.* = h.node.id;
    ui.scroll(c, .{ .width = .fill, .max_height = 440, .scroll_bar = false, .padding = .{ .bottom = 2 } });
    plate.cardBox(c, p);
    for (hits, 0..) |h, i| {
        if (i > 0) plate.rule(c, p, 40);
        row(b, c, p, h, order);
    }
    ui.end(c);
    ui.end(c);
}

fn row(b: *Browser, c: *ui.Context, p: *const Palette, hit: bm.Match, order: []const Uuid) void {
    const node = hit.node;
    const picks = &b.marks_ui.picks;
    const i = c.open(.{ .direction = .row, .gap = 10, .padding = .xy(14, 9), .width = .fill, .align_items = .center, .control = true }, outline.rowKey(c, .manager, node.id));
    const it = c.interact(i, .{});
    const label = node.label(c.alloc()) catch node.title;
    c.addA11y(i, .row, label, "", picks.ids.has(node.id), true);
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = if (picks.ids.has(node.id)) p.hover else p.hover.alpha(h);
    if (node.isFolder()) outline.folderMark(c, p, 16, 9.5) else outline.siteMark(b, c, p, node, 16);
    ui.column(c, .{ .gap = 2, .grow = 1, .min_width = 0 });
    ui.text(c, label, .{ .size = 13, .color = if (node.unnamed()) p.muted else p.ink, .truncate = true });
    ui.text(c, whereabouts(c, hit), .{ .size = 11.5, .color = p.muted, .truncate = true });
    ui.end(c);
    var showing = false;
    if (it.hovered) showing = plate.quick(c, p, "Show in Folder", null).clicked;
    c.end();
    if (showing) return manager.show(b, node.*);
    if (it.right_clicked) {
        b.marks_ui.menu_for.set(b.gpa, &.{node.id});
        tab_menu.later(b, c.input.mouse, 0, menu);
    }
    if (!it.clicked) return;
    if (it.double_clicked) {
        if (node.url) |u| actions.pickBookmark(b, u, false, .{}) else manager.show(b, node.*);
    } else picks.click(b.gpa, node.id, c.input.shift, c.input.cmd, order);
    c.changed = true;
}

/// The folders it is in, then the site.
fn whereabouts(c: *ui.Context, hit: bm.Match) []const u8 {
    const folders = if (hit.path.len == 0) "Top level" else std.mem.join(c.alloc(), " \u{203A} ", hit.path) catch "";
    const host = if (Parts.parse(hit.node.url orelse "")) |parts| parts.hostName() orelse return folders else return folders;
    return c.print("{s}  \u{00B7}  {s}", .{ folders, host });
}

const Act = struct {
    b: *Browser,
    id: Uuid,
    open: bool,

    fn fire(self: *Act, _: *nanoui.menu.Item) void {
        const node = self.b.bookmarks.bookmark(self.id) orelse return;
        if (self.open) {
            if (node.url) |u| actions.pickBookmark(self.b, u, false, .{});
        } else manager.show(self.b, node.*);
    }
};

fn menu(a: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const ids = b.marks_ui.menu_for.items.items;
    if (ids.len == 0) return &.{};
    const node = b.bookmarks.bookmark(ids[0]) orelse return &.{};
    var out: std.ArrayList(MenuItem) = .empty;
    if (node.url != null) {
        const o = try a.create(Act);
        o.* = .{ .b = b, .id = node.id, .open = true };
        try out.append(a, .{ .label = "Open", .click = .of(o, Act.fire) });
    }
    const s = try a.create(Act);
    s.* = .{ .b = b, .id = node.id, .open = false };
    try out.append(a, .{ .label = "Show in Folder", .click = .of(s, Act.fire) });
    return out.items;
}
