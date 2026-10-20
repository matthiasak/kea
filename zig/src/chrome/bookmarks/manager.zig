//! `BookmarksPanel` (Bookmarks.swift 1582-1879): the full list, for putting
//! it in order, finding one, or bringing more in — a sheet (`chrome/sheet.zig`,
//! `bookmarking`). Rows are picked, ⇧ for a run and ⌘ one more; what is
//! picked is opened, moved, grouped, copied or removed at once; ⌘Z and ⇧⌘Z
//! undo and redo what was done here, while it is open.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../../model/browser.zig").Browser;
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const Bookmarks = bm.Bookmarks;
const Uuid = @import("../../data/json.zig").Uuid;
const Palette = @import("../../design/palette.zig").Palette;
const motion = @import("../../design/motion.zig");
const controls = @import("../controls.zig");
const plate = @import("../controls_plate.zig");
const sheet = @import("../sheet.zig");
const tab_menu = @import("../tab_menu.zig");
const state = @import("state.zig");
const actions = @import("actions.zig");
const ask = @import("ask.zig");
const outline = @import("outline.zig");
const row_menu = @import("outline_menu.zig");
const files = @import("files.zig");
const found = @import("manager_found.zig");
const proposal = @import("proposal.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

const scroll_key = "bm.manager.scroll";

/// Each frame, before anything else is drawn: the manager's start and end
/// (its undo, its picks). Its keys come from the key monitor (`take`).
pub fn frame(b: *Browser) void {
    const s = &b.marks_ui;
    if (b.bookmarking and !s.manager_seen) {
        s.manager_seen = true;
        s.hunt_focus = true;
        b.bookmarks.startUndo();
    } else if (!b.bookmarking and s.manager_seen) {
        // What was done here can't be undone from a page's text field.
        s.manager_seen = false;
        b.bookmarks.stopUndo();
        s.picks.reset(b.gpa);
    }
    if (!b.bookmarking) return;
    proposal.frame(b);
    // A row taken away, by anything, is no longer picked.
    if (s.revision != b.bookmarks.revision) {
        s.revision = b.bookmarks.revision;
        var i: usize = s.picks.ids.items.items.len;
        while (i > 0) {
            i -= 1;
            if (b.bookmarks.bookmark(s.picks.ids.items.items[i]) == null) _ = s.picks.ids.items.swapRemove(i);
        }
    }
}

/// `BookmarksPanel.take`, from the key monitor while the manager is up and
/// nothing is typed in its search: ⌘A picks every row shown, ⌘Z and ⇧⌘Z
/// undo and redo, ⌫ or ⌦ (alone or with ⌘) removes what is picked and
/// Return opens it. Whether the key was used.
pub fn take(b: *Browser, event: nanoui.objc.Object) bool {
    const objc = nanoui.objc;
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{}) & ((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20));
    const command: objc.NSUInteger = 1 << 20;
    const code = objc.msg(u16, event, "keyCode", .{});
    const pool = objc.Pool.push();
    defer pool.pop();
    const chars = objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{});
    const key = if (chars) |str| objc.fromNSString(objc.msg(objc.Object, str, "lowercaseString", .{})) else "";
    const s = &b.marks_ui;
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = actions.nodesOf(a, b.bookmarks, s.picks.ids.items.items);
    if (flags == command and std.mem.eql(u8, key, "a")) {
        s.picks.ids.set(b.gpa, state.visible(a, b.bookmarks.roots, &s.picks.expanded) catch return true);
    } else if (flags == command and std.mem.eql(u8, key, "z")) {
        _ = b.bookmarks.undo();
    } else if (flags == command | (1 << 17) and std.mem.eql(u8, key, "z")) {
        _ = b.bookmarks.redo();
    } else if ((code == 51 or code == 117) and flags & ~command == 0 and nodes.len > 0) {
        ask.remove(b, nodes);
    } else if (code == 36 and nodes.len > 0) {
        if (nodes.len == 1 and nodes[0].url != null)
            actions.pickBookmark(b, nodes[0].url.?, false, .{})
        else
            actions.openBookmarks(b, nodes, false);
    } else return false;
    b.redraw();
    return true;
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.marks_ui;
    const picks = &s.picks;
    // The wash lasts 1.4 s from the frame that first draws it.
    if (picks.shown != null and picks.shown_until == 0) picks.shown_until = c.time + 1.4;
    if (picks.shown != null and c.time >= picks.shown_until) picks.shown = null;
    if (picks.shown != null) c.frameIn(@floatCast(picks.shown_until - c.time));

    var pl = plate.plate(c, p, "Bookmarks", 600);
    if (pl.closed) sheet.close(b, .bookmarking);
    ui.column(c, .{ .width = .fill, .gap = 14 });
    if (s.hunt_focus) {
        s.hunt_focus = false;
        ui.focusNext(c, false);
    }
    const hunted = plate.hunt(c, p, &picks.query, "Search bookmarks");
    if (hunted.submitted) openFirst(b, c);
    if (picks.organizing) |says| {
        proposal.asking(b, c, p, says);
    } else if (picks.proposal == null and picks.ids.items.items.len > 0) bar(b, c, p);
    const room = switchBegin(b, c);
    if (picks.proposal) |pr| {
        proposal.view(b, c, p, pr);
    } else if (b.bookmarks.isEmpty()) {
        plate.cardBox(c, p);
        plate.nothing(c, p, "Nothing pocketed yet. Add this page with \u{21E7}\u{2318}B, or bring yours in below.");
        ui.end(c);
    } else if (picks.query.text().len > 0) {
        found.view(b, c, p);
    } else tree(b, c, p);
    switchEnd(b, c, room);
    ui.end(c);

    pl.foot(c, p);
    foot(b, c, p);
    pl.end(c);
}

/// `.animation(Motion.settle, value: picks.query.isEmpty)`: going from the
/// tree to what was found, or back, the new list fades in and the room
/// springs from the old one's height to its own. Returns the room's box
/// and the list's; draw the list, then `switchEnd`.
fn switchBegin(b: *Browser, c: *ui.Context) [2]u32 {
    const s = &b.marks_ui;
    const room = c.open(.{ .width = .fill, .clip = true }, "kea.marks.room");
    const inner = c.open(.{ .width = .fill, .direction = .column }, "inner");
    const hunting = s.picks.query.text().len > 0;
    if (hunting != s.hunting_was) {
        s.hunting_was = hunting;
        // Only a list already on screen moves: the sheet arriving doesn't.
        if (c.rects.get(c.node(inner).id)) |r| {
            s.switch_gen +%= 1;
            s.switch_from = r.h;
            s.switching = true;
        }
    }
    return .{ room, inner };
}

fn switchEnd(b: *Browser, c: *ui.Context, boxes: [2]u32) void {
    const s = &b.marks_ui;
    c.end();
    c.end();
    if (!s.switching) return;
    const id = c.node(boxes[0]).id;
    const now = if (c.rects.get(c.node(boxes[1]).id)) |r| r.h else s.switch_from;
    const fade = ui.springFrom(c, id, s.switch_gen *% 2, 0, 1, motion.settle);
    const h = ui.springFrom(c, id, s.switch_gen *% 2 +% 1, s.switch_from, now, motion.settle);
    // The list laid out at its own height, over a room of the spring's.
    c.node(boxes[0]).style.height = .{ .px = @max(0, h) };
    c.node(boxes[1]).style.absolute = true;
    c.node(boxes[1]).style.opacity = std.math.clamp(fade, 0, 1);
    if (@abs(h - now) < 0.5 and @abs(fade - 1) < 0.001) s.switching = false;
}

fn tree(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const picks = &b.marks_ui.picks;
    const si = c.open(.{ .width = .fill, .max_height = 440, .scroll = true, .direction = .column, .scroll_bar = false, .padding = .{ .bottom = 2 } }, scroll_key);
    const sid = c.node(si).id;
    plate.cardBox(c, p);
    ui.column(c, .{ .width = .fill, .padding = .xy(6, 6) });
    outline.view(b, c, p, .{ .list = .manager, .picks = true, .shown = picks.shown });
    ui.end(c);
    ui.end(c);
    c.end();
    // A bookmark found is shown where it lives, which may be below what
    // shows: scrolled to the middle once its row is laid out.
    if (!picks.reveal) return;
    if (picks.shown == null) {
        picks.reveal = false;
        return;
    }
    const sr = c.rects.get(sid) orelse return c.animationFrame();
    const row = picks.shown_rect orelse return c.animationFrame();
    picks.reveal = false;
    const now = c.scroll.get(sid) orelse 0;
    c.setScroll(sid, .y, now + (row.y + row.h / 2) - (sr.y + sr.h / 2));
}

/// Return in the search: the first site found.
fn openFirst(b: *Browser, c: *ui.Context) void {
    const hits = b.bookmarks.matches(c.alloc(), b.marks_ui.picks.query.text()) catch return;
    for (hits) |h| if (h.node.url) |u| return actions.pickBookmark(b, u, false, .{});
}

/// Back to the tree, opened down to it, and it washed a moment. A folder
/// is shown open.
pub fn show(b: *Browser, node: Bookmark) void {
    const picks = &b.marks_ui.picks;
    picks.query.clear();
    ask.openTo(b, .manager, node.id);
    if (!node.isFolder()) picks.expanded.remove(node.id);
    picks.shown = node.id;
    picks.shown_until = 0;
    picks.shown_rect = null;
    picks.reveal = true;
    b.redraw();
}

/// What is picked, and what can be done with all of it at once.
fn bar(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.marks_ui;
    const ids = b.bookmarks.topmost(c.alloc(), s.picks.ids.items.items) catch return;
    const nodes = actions.nodesOf(c.alloc(), b.bookmarks, ids);
    ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
    defer ui.end(c);
    // The pills keep their size; the count gives way first, as SwiftUI shrinks a Text.
    ui.text(c, c.print("{d} selected", .{s.picks.ids.items.items.len}), .{ .size = 12, .color = p.muted, .truncate = true });
    ui.spacer(c);
    if (controls.pill(c, p, "Open in Tabs", .{}).clicked) actions.openBookmarks(b, nodes, false);
    if (controls.pill(c, p, "New Window", .{}).clicked) actions.openBookmarks(b, nodes, true);
    pillMenu(b, c, p, "Move to", moveMenu);
    if (controls.pill(c, p, "Group\u{2026}", .{}).clicked) ask.group(b, ids, .manager);
    if (controls.pill(c, p, "Copy", .{}).clicked) actions.copy(b, nodes);
    if (controls.pill(c, p, "Remove", .{ .tint = p.red.alpha(0.75) }).clicked) ask.remove(b, nodes);
    if (plate.quick(c, p, "Clear", null).clicked) s.picks.ids.clear();
}

fn foot(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
    defer ui.end(c);
    ui.text(c, "Bring in from", .{ .size = 12, .color = p.muted });
    if (controls.pill(c, p, "Bring in\u{2026}", .{}).clicked) {
        sheet.close(b, .bookmarking);
        sheet.show(b, .bringing);
    }
    if (controls.pill(c, p, "File\u{2026}", .{}).clicked) files.importFile(b);
    ui.spacer(c);
    if (controls.pill(c, p, "New Folder\u{2026}", .{}).clicked) ask.newFolder(b, null, null);
    pillMenu(b, c, p, "Organize", organizeMenu);
    const n = Bookmarks.count(b.bookmarks.roots);
    ui.text(c, if (n == 1) "1 bookmark" else c.print("{d} bookmarks", .{n}), .{ .size = 12, .color = p.muted });
}

/// A menu that looks like a Pill, opening under it.
fn pillMenu(b: *Browser, c: *ui.Context, p: *const Palette, title: []const u8, build: tab_menu.Build) void {
    const it = controls.pill(c, p, title, .{});
    if (it.clicked) if (it.rect) |r| tab_menu.later(b, .{ .x = r.x, .y = r.y + r.h }, 0, build);
}

fn moveMenu(a: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const ids = try b.bookmarks.topmost(a, b.marks_ui.picks.ids.items.items);
    return row_menu.moveItems(a, b, ids);
}

fn organizeMenu(a: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    var out: std.ArrayList(MenuItem) = .empty;
    try out.append(a, try row_menu.item(a, b, "Sort Top Level by Name", .sort_name, &.{}, null, .manager));
    try out.append(a, try row_menu.item(a, b, "Sort Top Level by Site", .sort_site, &.{}, null, .manager));
    try out.append(a, .separator);
    try out.append(a, try row_menu.item(a, b, "Remove Duplicates\u{2026}", .dupes, &.{}, null, .manager));
    try out.append(a, .separator);
    var ai = try row_menu.item(a, b, "Organize with AI\u{2026}", .organize, &.{}, null, .manager);
    ai.disabled = b.marks_ui.picks.organizing != null;
    try out.append(a, ai);
    return out.items;
}
