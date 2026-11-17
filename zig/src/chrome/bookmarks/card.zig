//! `BookmarkCard` (Bookmarks.swift 1267-1392): what ⇧⌘B opens off the
//! button — the page just kept, or kept before, with its name to change
//! and a folder to file it in. Each change is kept as it is made, so Done,
//! Return, Esc and a click elsewhere all only close it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../../model/browser.zig").Browser;
const bm = @import("../../data/bookmarks.zig");
const Bookmarks = bm.Bookmarks;
const Uuid = @import("../../data/json.zig").Uuid;
const address = @import("../../model/address.zig");
const Palette = @import("../../design/palette.zig").Palette;
const controls = @import("../controls.zig");
const plate = @import("../controls_plate.zig");
const tab_menu = @import("../tab_menu.zig");
const row_menu = @import("outline_menu.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.marks_ui;
    const id = s.card orelse return close(b);
    const node = b.bookmarks.bookmark(id) orelse return close(b);
    ui.column(c, .{ .width = px(304), .padding = .all(14), .gap = 12 });
    defer ui.end(c);
    ui.text(c, "Bookmarked", .{ .size = 13, .weight = .semibold, .color = p.ink });

    ui.column(c, .{ .width = .fill, .gap = 8 });
    line(c, p, "Name");
    ui.column(c, .{ .grow = 1, .padding = .xy(8, 5), .radius = 8, .background = p.wash });
    if (s.card_fresh) {
        s.card_fresh = false;
        s.card_title.set(node.title);
        // The keys to the name, as the card appears.
        ui.focusNext(c, true);
    }
    // Emptied, the field shows what the lists will read.
    if (s.card_title.text().len == 0)
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 8, .y = 5 } }, .{ .text = .{ .str = address.pretty(c.alloc(), node.url orelse "") catch "", .style = .{ .size = 12.5 }, .color = p.muted.alpha(0.7) } }, null);
    const r = ui.textField(c, &s.card_title, .{ .bare = true, .size = 12.5, .width = .fill, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
    ui.end(c);
    ui.end(c);
    if (r.changed) rename(b, id, s.card_title.text());
    if (r.submitted) close(b);
    const live = b.bookmarks.bookmark(id) orelse {
        ui.end(c);
        return close(b);
    };
    const path = (b.bookmarks.pathTo(c.alloc(), id) catch null) orelse &.{};
    if (path.len == 0) {
        if (Bookmarks.cat.norm(live.category)) |raw_cat| {
            const cat = c.alloc().dupe(u8, raw_cat) catch raw_cat;
            line(c, p, "Category");
            categoryRow(b, c, p, id, cat);
            ui.end(c);
        }
    }
    line(c, p, "Folder");
    folder(b, c, p, path);
    ui.end(c);
    ui.end(c);

    ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
    defer ui.end(c);
    if (plate.quick(c, p, "Remove", p.red.alpha(0.75)).clicked) {
        close(b);
        b.bookmarks.remove(&.{id});
    }
    ui.spacer(c);
    if (controls.pill(c, p, "Done", .{ .filled = true }).clicked) close(b);
}

/// A name on the left, 54 wide, the control after it; close with `ui.end`.
fn line(c: *ui.Context, p: *const Palette, name: []const u8) void {
    ui.row(c, .{ .width = .fill, .gap = 10, .align_items = .center });
    ui.column(c, .{ .width = px(54) });
    ui.text(c, name, .{ .size = 11.5, .color = p.muted });
    ui.end(c);
}

/// An empty name is kept as empty: the bookmarks bar then shows the
/// bookmark's icon alone, as Chrome's and Safari's do.
pub fn rename(b: *Browser, id: Uuid, typed: []const u8) void {
    const name = std.mem.trim(u8, typed, " \t\r\n");
    const now = b.bookmarks.bookmark(id) orelse return;
    if (std.mem.eql(u8, name, now.title)) return;
    b.bookmarks.update(id, name, null);
}

fn close(b: *Browser) void {
    if (b.overlay) |o| if (o == .bookmark_card) {
        b.overlay = null;
    };
    b.redraw();
}

/// Where it is filed, opening every other folder to file it in.
fn folder(b: *Browser, c: *ui.Context, p: *const Palette, path: []const *const bm.Bookmark) void {
    const here = if (path.len > 0) path[path.len - 1].title else "Top Level";
    const i = c.open(.{ .direction = .row, .grow = 1, .gap = 6, .padding = .xy(8, 5), .radius = 8, .background = p.wash, .align_items = .center, .control = true }, null);
    const it = c.interact(i, .{});
    c.addA11y(i, .menu_button, "Folder", here, false, true);
    ui.icon(c, "folder", .{ .size = 10.5, .color = p.muted });
    ui.text(c, here, .{ .size = 12.5, .color = p.ink, .truncate = .ellipsis });
    _ = c.leaf(.{ .grow = 1, .min_width = 4 }, .none, null);
    ui.icon(c, "chevron.up.chevron.down", .{ .size = 8.5, .weight = .semibold, .color = p.muted });
    c.end();
    if (it.clicked) if (it.rect) |r| tab_menu.later(b, .{ .x = r.x, .y = r.y + r.h }, 0, folderMenu);
}

fn folderMenu(a: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const id = b.marks_ui.card orelse return &.{};
    return folderItems(a, b, id);
}

/// "Top Level", every folder, and New Folder….
pub fn folderItems(a: std.mem.Allocator, b: *Browser, id: Uuid) ![]const MenuItem {
    const ids = try a.dupe(Uuid, &.{id});
    var out: std.ArrayList(MenuItem) = .empty;
    try out.append(a, try row_menu.item(a, b, "Top Level", .move, ids, null, .dropdown));
    const folders = b.bookmarks.cachedFolders();
    if (folders.len > 0) try out.append(a, .separator);
    for (folders) |f| try out.append(a, try row_menu.item(a, b, try row_menu.indented(a, f), .move, ids, f.node.id, .dropdown));
    try out.append(a, .separator);
    try out.append(a, try row_menu.item(a, b, "New Folder\u{2026}", .card_folder, ids, null, .dropdown));
    return out.items;
}

fn categoryRow(b: *Browser, c: *ui.Context, p: *const Palette, id: Uuid, cat: []const u8) void {
    _ = c.open(.{ .direction = .row, .grow = 1, .gap = 6, .padding = .xy(8, 5), .radius = 8, .background = p.wash, .align_items = .center }, null);
    defer c.end();
    const pick = c.open(.{ .direction = .row, .grow = 1, .min_width = 0, .gap = 6, .align_items = .center, .control = true }, null);
    const it = c.interact(pick, .{});
    c.addA11y(pick, .menu_button, "Category", cat, false, true);
    ui.icon(c, "tag", .{ .size = 10.5, .color = p.muted });
    ui.text(c, cat, .{ .size = 12.5, .color = p.ink, .truncate = .ellipsis });
    _ = c.leaf(.{ .grow = 1, .min_width = 2 }, .none, null);
    c.end();
    if (it.clicked) if (it.rect) |rect| tab_menu.later(b, .{ .x = rect.x, .y = rect.y + rect.h }, 0, categoryMenu);

    const clr = c.open(.{ .width = px(16), .height = px(16), .radius = 8, .align_items = .center, .justify = .center, .control = true }, null);
    const cit = c.interact(clr, .{});
    c.help(clr, "Clear Category");
    c.addA11y(clr, .button, "Clear Category", "", false, true);
    ui.icon(c, "xmark", .{ .size = 8.5, .weight = .semibold, .color = if (cit.hovered) p.ink else p.muted });
    c.end();
    if (cit.clicked) {
        Bookmarks.cat.setCategory(b.bookmarks, id, null);
        b.redraw();
    }
}

const CategoryPick = struct {
    b: *Browser,
    id: Uuid,
    cat: ?[]const u8,

    fn fire(self: *@This(), _: *nanoui.menu.Item) void {
        Bookmarks.cat.setCategory(self.b.bookmarks, self.id, self.cat);
        self.b.redraw();
    }
};

fn categoryItem(a: std.mem.Allocator, b: *Browser, id: Uuid, label: []const u8, cat: ?[]const u8, checked: bool) !MenuItem {
    const pick = try a.create(CategoryPick);
    pick.* = .{ .b = b, .id = id, .cat = cat };
    return .{ .label = label, .checked = checked, .click = .of(pick, CategoryPick.fire) };
}

fn categoryMenu(a: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const id = b.marks_ui.card orelse return &.{};
    const node = b.bookmarks.bookmark(id) orelse return &.{};
    const current = Bookmarks.cat.norm(node.category);
    const groups = try Bookmarks.cat.orderedGroups(a, b.bookmarks.roots);
    var out: std.ArrayList(MenuItem) = .empty;
    for (groups) |g| {
        const cat = try a.dupe(u8, g.category);
        try out.append(a, try categoryItem(a, b, id, cat, cat, Bookmarks.cat.optEq(current, cat)));
    }
    if (groups.len > 0) try out.append(a, .separator);
    try out.append(a, try categoryItem(a, b, id, "Clear Category", null, false));
    return out.items;
}
