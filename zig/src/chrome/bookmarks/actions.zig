//! What the window does with its bookmarks (Browser.swift "bookmarks",
//! `openBookmarks`, `pickBookmark`): ⇧⌘B and the card, the button's list,
//! a bookmark picked, many opened at once.
const std = @import("std");
const nanoui = @import("nanoui");
const Browser = @import("../../model/browser.zig").Browser;
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const Bookmarks = bm.Bookmarks;
const Uuid = @import("../../data/json.zig").Uuid;
const browsers = @import("../../app/browsers.zig");
const state = @import("state.zig");
const ask = @import("ask.zig");

/// The page you are on is kept, wherever it is filed.
pub fn pageKept(b: *Browser) bool {
    const t = b.activeTab() orelse return false;
    return !t.isBlank() and b.bookmarks.contains(t.url());
}

/// The button's list or card is open (`bookmarksOpen`).
pub fn isOpen(b: *const Browser) bool {
    const o = b.overlay orelse return false;
    return o == .bookmarks_dropdown or o == .bookmark_card;
}

/// ⇧⌘B. The page you are on, at the end of the list, and the card off the
/// button to name it and file it — or the card for it, if it was kept
/// already. With the tabs folded away there is nothing to hang the card
/// from, and a word says what happened instead.
pub fn bookmarkCurrent(b: *Browser) void {
    const t = b.activeTab() orelse return;
    if (t.isBlank()) return;
    const kept = b.bookmarks.bookmarkFor(t.url());
    const id = if (kept) |k| k.id else b.bookmarks.add(t.url(), t.title()) orelse return;
    if (b.folded) return b.announce(if (kept == null) "Bookmarked" else "Already a bookmark");
    const s = &b.marks_ui;
    s.card = id;
    s.card_fresh = true;
    b.overlay = .bookmark_card;
    b.overlay_anchor = s.door;
    b.redraw();
}

/// The button: the list, never a card left from before.
pub fn toggleBookmarks(b: *Browser) void {
    if (isOpen(b)) {
        b.overlay = null;
        return b.redraw();
    }
    const s = &b.marks_ui;
    s.card = null;
    state.opening(b.gpa, &s.dropdown, b.bookmarks.roots);
    s.dropdown_height = listHeight(b.bookmarks.roots);
    b.overlay = .bookmarks_dropdown;
    b.overlay_anchor = s.door;
    b.redraw();
}

/// `BookmarksDropdown.listHeight`: as tall as the whole tree would be with
/// every folder open, up to 360, taken once as the list opens.
pub fn listHeight(roots: []const Bookmark) f32 {
    const most: f32 = 360;
    const line: f32 = 28;
    var lines: usize = 0;
    count(roots, &lines, @as(usize, @intFromFloat(most / line)) + 1);
    return @min(most, @as(f32, @floatFromInt(lines)) * line + 12);
}

fn count(nodes: []const Bookmark, lines: *usize, limit: usize) void {
    for (nodes) |n| {
        if (lines.* >= limit) return;
        lines.* += 1;
        if (!n.isFolder()) continue;
        const kids = n.kids();
        if (kids.len > 0) count(kids, lines, limit) else lines.* += 1;
    }
}

/// The keys held with the click that picked it.
pub const Held = struct { shift: bool = false, cmd: bool = false };

/// A bookmark picked from the button's list or the full one: either goes
/// as the page starts. A middle-click opens it in a new tab behind and
/// leaves the list open for the next; with ⇧ it goes to the new tab, and
/// the list closes.
pub fn pickBookmark(b: *Browser, url: []const u8, in_new_tab: bool, held: Held) void {
    const new_tab = in_new_tab or held.cmd;
    const foreground = !new_tab or held.shift;
    if (foreground) {
        b.bookmarking = false;
        if (isOpen(b)) b.overlay = null;
    }
    if (new_tab) {
        _ = b.open(url, .{ .foreground = foreground, .from = b.activeTab(), .may_wait = !foreground });
    } else b.visit(url, false);
    b.redraw();
}

/// Every page among `nodes`, folders opened, in order: background tabs
/// here, or a new window of their own. A great many ask first.
pub fn openBookmarks(b: *Browser, nodes: []const Bookmark, new_window: bool) void {
    const n = Bookmarks.count(nodes);
    if (n > 20) return ask.openMany(b, nodes, n, new_window);
    openNow(b, nodes, new_window);
}

pub fn openNow(b: *Browser, nodes: []const Bookmark, new_window: bool) void {
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const urls = Bookmarks.urls(arena.allocator(), nodes) catch return;
    if (urls.len == 0) return;
    if (new_window) {
        const made = browsers.open(b.kea, &.{ .id = Uuid.random(), .space = b.space_id }, null) catch return;
        made.visit(urls[0], false);
        for (urls[1..]) |u| _ = made.open(u, .{ .foreground = false, .at_end = true, .may_wait = true });
        return made.redraw();
    }
    for (urls) |u| _ = b.open(u, .{ .foreground = false, .at_end = true, .may_wait = true });
    b.redraw();
}

/// The addresses of every site among `nodes`, one to a line, on the pasteboard.
pub fn copy(b: *Browser, nodes: []const Bookmark) void {
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const urls = Bookmarks.urls(a, nodes) catch return;
    nanoui.clipboard.writeText(std.mem.join(a, "\n", urls) catch return);
}

/// The nodes for `ids`, those still here, topmost and in reading order. On `a`.
pub fn nodesOf(a: std.mem.Allocator, marks: *const Bookmarks, ids: []const Uuid) []const Bookmark {
    const tops = marks.topmost(a, ids) catch return &.{};
    var out: std.ArrayList(Bookmark) = .empty;
    for (tops) |id| if (marks.bookmark(id)) |n| out.append(a, n.*) catch {};
    return out.items;
}
