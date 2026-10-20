//! What a right-click on a row of the bookmarks offers (`BookmarkOutline.
//! actions`), and the "Move to" list it shares with the manager and the
//! card (`moveItems`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../../model/browser.zig").Browser;
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const Bookmarks = bm.Bookmarks;
const Uuid = @import("../../data/json.zig").Uuid;
const Parts = @import("../../data/url.zig").Parts;
const tab_menu = @import("../tab_menu.zig");
const state = @import("state.zig");
const actions = @import("actions.zig");
const ask = @import("ask.zig");

/// One item's work, on the rows it was opened for.
pub const Pick = struct {
    b: *Browser,
    what: What,
    ids: []const Uuid,
    to: ?Uuid = null,
    list: state.List = .dropdown,

    pub const What = enum { open, open_tab, open_tabs, open_window, group, copy, move, remove, rename, new_inside, sort_name, sort_site, edit, new_folder_top, card_folder, dupes, organize };

    pub fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const b = self.b;
        var arena = std.heap.ArenaAllocator.init(b.gpa);
        defer arena.deinit();
        const nodes = actions.nodesOf(arena.allocator(), b.bookmarks, self.ids);
        const first: ?Bookmark = if (nodes.len > 0) nodes[0] else null;
        const held: actions.Held = .{};
        switch (self.what) {
            .open => if (first) |n| if (n.url) |u| actions.pickBookmark(b, u, false, held),
            .open_tab => if (first) |n| if (n.url) |u| actions.pickBookmark(b, u, true, held),
            .open_tabs => actions.openBookmarks(b, nodes, false),
            .open_window => actions.openBookmarks(b, nodes, true),
            .group => ask.group(b, self.ids, self.list),
            .copy => actions.copy(b, nodes),
            .move => b.bookmarks.move(self.ids, self.to, null),
            .remove => ask.remove(b, nodes),
            .rename => if (first) |n| ask.rename(b, n),
            .new_inside => if (first) |n| ask.newFolder(b, n.id, self.list),
            .sort_name => b.bookmarks.sort(self.to, .name),
            .sort_site => b.bookmarks.sort(self.to, .site),
            .edit => if (first) |n| ask.edit(b, n),
            .new_folder_top => ask.newFolder(b, null, null),
            .card_folder => if (self.ids.len > 0) ask.cardFolder(b, self.ids[0]),
            .dupes => ask.duplicates(b),
            .organize => @import("proposal.zig").organizeBookmarks(b),
        }
        b.redraw();
    }
};

/// An item doing `what` to `ids`, on `a`.
pub fn item(a: std.mem.Allocator, b: *Browser, label: []const u8, what: Pick.What, ids: []const Uuid, to: ?Uuid, list: state.List) !MenuItem {
    const pick = try a.create(Pick);
    pick.* = .{ .b = b, .what = what, .ids = ids, .to = to, .list = list };
    return .{ .label = label, .click = .of(pick, Pick.fire) };
}

/// The rows' menu where the pointer is: every row picked, if this is one of
/// several, and otherwise this row alone.
pub fn popup(b: *Browser, c: *ui.Context, use: anytype, id: Uuid) void {
    const s = &b.marks_ui;
    s.menu_list = use.list;
    s.menu_for.set(b.gpa, &.{id});
    if (use.picks and s.picks.ids.has(id)) {
        const tops = b.bookmarks.topmost(c.alloc(), s.picks.ids.items.items) catch &.{};
        var here: usize = 0;
        for (tops) |t| here += @intFromBool(b.bookmarks.bookmark(t) != null);
        if (here > 1) s.menu_for.set(b.gpa, tops);
    }
    tab_menu.later(b, c.input.mouse, 0, built);
}

fn built(a: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const s = &b.marks_ui;
    const ids = try a.dupe(Uuid, s.menu_for.items.items);
    return items(a, b, ids, s.menu_list);
}

/// `actions(for:)`: what the menu holds for `ids`, in Swift's order.
pub fn items(a: std.mem.Allocator, b: *Browser, ids: []const Uuid, list: state.List) ![]const MenuItem {
    var out: std.ArrayList(MenuItem) = .empty;
    const nodes = actions.nodesOf(a, b.bookmarks, ids);
    if (nodes.len == 0) return out.items;
    if (nodes.len > 1) {
        try out.append(a, try item(a, b, try std.fmt.allocPrint(a, "Open {d} in New Tabs", .{nodes.len}), .open_tabs, ids, null, list));
        try out.append(a, try item(a, b, "Open in New Window", .open_window, ids, null, list));
        try out.append(a, .separator);
        try out.append(a, try item(a, b, "New Folder with Selection\u{2026}", .group, ids, null, list));
        try out.append(a, try item(a, b, "Copy Addresses", .copy, ids, null, list));
        try out.append(a, .{ .label = "Move to", .submenu = try moveItems(a, b, ids) });
        try out.append(a, .separator);
        try out.append(a, try item(a, b, try std.fmt.allocPrint(a, "Remove {d} Items", .{nodes.len}), .remove, ids, null, list));
        return out.items;
    }
    const node = nodes[0];
    if (node.isFolder()) {
        if (Bookmarks.count(node.kids()) > 0) {
            try out.append(a, try item(a, b, "Open All in New Tabs", .open_tabs, ids, null, list));
            try out.append(a, try item(a, b, "Open All in New Window", .open_window, ids, null, list));
            try out.append(a, .separator);
        }
        try out.append(a, try item(a, b, "Rename\u{2026}", .rename, ids, null, list));
        try out.append(a, try item(a, b, "New Folder Inside\u{2026}", .new_inside, ids, null, list));
        const sort = try a.alloc(MenuItem, 2);
        sort[0] = try item(a, b, "By Name", .sort_name, ids, node.id, list);
        sort[1] = try item(a, b, "By Site", .sort_site, ids, node.id, list);
        try out.append(a, .{ .label = "Sort", .submenu = sort });
    } else {
        if (node.url != null and Parts.parse(node.url.?) != null) {
            try out.append(a, try item(a, b, "Open", .open, ids, null, list));
            try out.append(a, try item(a, b, "Open in New Tab", .open_tab, ids, null, list));
            try out.append(a, try item(a, b, "Open in New Window", .open_window, ids, null, list));
            try out.append(a, .separator);
        }
        try out.append(a, try item(a, b, "Edit\u{2026}", .edit, ids, null, list));
        try out.append(a, try item(a, b, "Copy Address", .copy, ids, null, list));
    }
    try out.append(a, .{ .label = "Move to", .submenu = try moveItems(a, b, ids) });
    try out.append(a, .separator);
    try out.append(a, try item(a, b, "Remove", .remove, ids, null, list));
    return out.items;
}

/// The "Move to" list: the top level and every folder the rows can go
/// into, none inside what is being moved, each indented by its depth.
pub fn moveItems(a: std.mem.Allocator, b: *Browser, ids: []const Uuid) ![]const MenuItem {
    var out: std.ArrayList(MenuItem) = .empty;
    try out.append(a, try item(a, b, "Top Level", .move, ids, null, .dropdown));
    const nodes = actions.nodesOf(a, b.bookmarks, ids);
    var first = true;
    for (try Bookmarks.folders(a, b.bookmarks.roots)) |f| {
        const inside = for (nodes) |*n| {
            if (Bookmarks.holds(f.node.id, n)) break true;
        } else false;
        if (inside) continue;
        if (first) try out.append(a, .separator);
        first = false;
        try out.append(a, try item(a, b, try indented(a, f), .move, ids, f.node.id, .dropdown));
    }
    return out.items;
}

/// `String(repeating: "   ", count: depth) + title`.
pub fn indented(a: std.mem.Allocator, f: bm.Folder) ![]const u8 {
    var s: std.ArrayList(u8) = .empty;
    try s.appendNTimes(a, ' ', 3 * f.depth);
    try s.appendSlice(a, f.node.title);
    return s.items;
}
