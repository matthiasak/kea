//! `BookmarkMenu` (Bookmarks.swift 1881-2125): the bookmarks as a menu — a
//! folder of the bookmarks bar opened at the pointer, and the menu bar's
//! Bookmarks menu. Only a folder's own items are made as it opens: its
//! folders fill themselves as they are reached (`on_open`), so 1,500
//! bookmarks cost nothing until looked at.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const objc = nanoui.objc;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../../model/browser.zig").Browser;
const Bookmark = @import("../../data/bookmarks.zig").Bookmark;
const Uuid = @import("../../data/json.zig").Uuid;
const Parts = @import("../../data/url.zig").Parts;
const tab_menu = @import("../tab_menu.zig");

/// A folder of the bar, opened as a menu at the pointer.
pub fn popUp(b: *Browser, c: *ui.Context, folder: Uuid) void {
    b.marks_ui.menu_for.set(b.gpa, &.{folder});
    tab_menu.later(b, c.input.mouse, 0, built);
}

fn built(a: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const ids = b.marks_ui.menu_for.items.items;
    if (ids.len == 0) return &.{};
    const folder = b.bookmarks.bookmark(ids[0]) orelse return &.{};
    return orEmpty(a, try items(a, b, folder.kids()));
}

/// A folder with nothing in it says so.
fn orEmpty(a: std.mem.Allocator, made: []const MenuItem) ![]const MenuItem {
    if (made.len > 0) return made;
    return a.dupe(MenuItem, &.{.{ .label = "Empty", .disabled = true }});
}

/// The menu's items for `nodes`, on `a` (which must outlive the menu: the
/// folders fill from it as they open). A folder is a submenu, filled when
/// it opens; a site opens in the tab you are on, wearing its icon. One
/// without a name reads as its address.
pub fn items(a: std.mem.Allocator, b: *Browser, nodes: []const Bookmark) ![]const MenuItem {
    var out: std.ArrayList(MenuItem) = .empty;
    for (nodes) |node| {
        if (node.isFolder()) {
            const lazy = try a.create(Lazy);
            lazy.* = .{ .a = a, .b = b, .id = node.id };
            try out.append(a, .{ .label = node.title, .image_symbol = "folder", .submenu = &.{}, .on_open = .of(lazy, Lazy.fill) });
            continue;
        }
        const u = node.url orelse continue;
        if (Parts.parse(u) == null) continue;
        const go = try a.create(Open);
        go.* = .{ .b = b, .url = try a.dupe(u8, u) };
        // ponytail: a site whose icon isn't kept yet has none here; Swift
        // draws the bar's letter in its place (P14).
        const png = if (b.kea.favicons.icon(u)) |ic| try a.dupe(u8, ic.png) else "";
        try out.append(a, .{ .label = try node.label(a), .image_png = png, .click = .of(go, Open.fire) });
    }
    return out.items;
}

/// A folder, opening: its items, made now.
const Lazy = struct {
    a: std.mem.Allocator,
    b: *Browser,
    id: Uuid,

    fn fill(self: *Lazy, item: *nanoui.menu.Item) void {
        const folder = self.b.bookmarks.bookmark(self.id) orelse return;
        const made = items(self.a, self.b, folder.kids()) catch return;
        item.setSubmenu(orEmpty(self.a, made) catch return) catch {};
    }
};

const Open = struct {
    b: *Browser,
    url: []const u8,

    fn fire(self: *Open, _: *nanoui.menu.Item) void {
        self.b.visit(self.url, commandHeld());
    }
};

/// `visit` reads the event that picked the item: ⌘ held opens a new tab.
fn commandHeld() bool {
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const ev = objc.msg(?objc.Object, app, "currentEvent", .{}) orelse return false;
    return objc.msg(objc.NSUInteger, ev, "modifierFlags", .{}) & (1 << 20) != 0;
}
