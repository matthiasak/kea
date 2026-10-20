//! What the window keeps for the bookmarks between frames: the folders
//! open in each list, the manager's picks (`BookmarkPicks`), the card off
//! the button, a row being carried, and where the button is.
const std = @import("std");
const ui = @import("nanoui").ui;
const json = @import("../../data/json.zig");
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const organize = @import("../../ai/organize.zig");
const Uuid = json.Uuid;

/// A set of ids, in no order (on the window's allocator).
pub const Ids = struct {
    items: std.ArrayList(Uuid) = .empty,

    pub fn has(s: *const Ids, id: Uuid) bool {
        return bm.has(s.items.items, id);
    }

    pub fn put(s: *Ids, gpa: std.mem.Allocator, id: Uuid) void {
        if (!s.has(id)) s.items.append(gpa, id) catch {};
    }

    pub fn remove(s: *Ids, id: Uuid) void {
        for (s.items.items, 0..) |x, i| if (x.eql(id)) {
            _ = s.items.swapRemove(i);
            return;
        };
    }

    pub fn toggle(s: *Ids, gpa: std.mem.Allocator, id: Uuid) void {
        if (s.has(id)) s.remove(id) else s.put(gpa, id);
    }

    pub fn set(s: *Ids, gpa: std.mem.Allocator, ids: []const Uuid) void {
        s.items.clearRetainingCapacity();
        s.items.appendSlice(gpa, ids) catch {};
    }

    pub fn clear(s: *Ids) void {
        s.items.clearRetainingCapacity();
    }

    pub fn deinit(s: *Ids, gpa: std.mem.Allocator) void {
        s.items.deinit(gpa);
    }
};

/// Which list is drawn: each keeps its own open folders.
pub const List = enum { dropdown, sidebar, manager };

/// Where a carried row would land: above, into or below row `id` (null:
/// past the last row), and the move that makes.
pub const Zone = enum { before, into, after };
pub const Aim = struct {
    id: ?Uuid,
    zone: Zone,
    /// Drawn one deeper: below an open folder is its first child's place.
    depth: usize = 0,
    into: ?Uuid,
    at: ?usize,
};

pub const Drag = struct {
    /// The row pressed, and where, until it is carried or let go.
    pressed: ?Uuid = null,
    origin: ui.Point = .{},
    list: List = .dropdown,
    /// The rows carried (the whole selection when the pressed row is in it).
    carrying: Ids = .{},
    aimed: ?Aim = null,
    /// A closed folder held over opens after a moment.
    spring_since: f64 = 0,
};

/// `BookmarkPicks`: what the manager has picked, what it looks for, which
/// folders are open, and the row a search last showed.
pub const Picks = struct {
    ids: Ids = .{},
    query: ui.TextBuffer = .{},
    expanded: Ids = .{},
    anchor: ?Uuid = null,
    shown: ?Uuid = null,
    shown_until: f64 = 0,
    /// To scroll to `shown` once its row is laid out (`outline` notes where).
    reveal: bool = false,
    shown_rect: ?ui.Rect = null,
    /// The AI's proposal for the list, shown in place of it until applied
    /// or discarded; what the manager says while it is asked (gpa), and the run.
    proposal: ?*organize.Proposal = null,
    organizing: ?[]u8 = null,
    organize_task: ?*organize.Organizing = null,
    /// Apply, Discard or Stop pressed: done as the next frame starts, since
    /// this frame's text still points into what they free.
    pressed: enum { none, apply, discard, stop } = .none,

    /// A click on a row: ⇧ takes the rows from the last one clicked to this
    /// one, ⌘ adds it or takes it away, a plain click is that row alone.
    /// `order` is the rows as they read.
    pub fn click(self: *Picks, gpa: std.mem.Allocator, id: Uuid, shift: bool, cmd: bool, order: []const Uuid) void {
        if (shift) if (self.anchor) |anchor| if (indexOf(order, anchor)) |from| if (indexOf(order, id)) |to| {
            self.ids.set(gpa, order[@min(from, to) .. @max(from, to) + 1]);
            return;
        };
        if (cmd) {
            self.ids.toggle(gpa, id);
        } else {
            self.ids.set(gpa, &.{id});
        }
        self.anchor = id;
    }

    pub fn reset(self: *Picks, gpa: std.mem.Allocator) void {
        self.ids.clear();
        self.query.clear();
        self.expanded.clear();
        self.anchor = null;
        self.shown = null;
        self.stopOrganizing(gpa);
        self.dropProposal();
    }

    /// The run stopped (its answer never comes) and its words gone.
    pub fn stopOrganizing(self: *Picks, gpa: std.mem.Allocator) void {
        if (self.organize_task) |o| {
            // A run still waiting on its key frees itself later: its hold
            // moves off this window, which may be gone by then.
            self.organize_task = null;
            o.slot = &orphan;
            o.cancel();
        }
        if (self.organizing) |s| gpa.free(s);
        self.organizing = null;
    }

    pub fn dropProposal(self: *Picks) void {
        if (self.proposal) |p| p.destroy();
        self.proposal = null;
    }

    fn deinit(self: *Picks, gpa: std.mem.Allocator) void {
        self.stopOrganizing(gpa);
        self.dropProposal();
        self.ids.deinit(gpa);
        self.expanded.deinit(gpa);
        self.query.deinit();
    }
};

var orphan: ?*organize.Organizing = null;

fn indexOf(order: []const Uuid, id: Uuid) ?usize {
    for (order, 0..) |x, i| if (x.eql(id)) return i;
    return null;
}

pub const State = struct {
    /// The button, last drawn, and which way what hangs off it goes.
    door: ui.Rect = .{},
    door_edge: enum { below, trailing } = .below,
    /// The card for one bookmark (⇧⌘B) instead of the list: its id, its
    /// name being typed, and whether it has just appeared.
    card: ?Uuid = null,
    card_title: ui.TextBuffer = .{},
    card_fresh: bool = false,
    /// The folders open in the dropdown, and its height, both taken as it opens.
    dropdown: Ids = .{},
    dropdown_height: f32 = 0,
    sidebar: Ids = .{},
    sidebar_ready: bool = false,
    picks: Picks = .{},
    drag: Drag = .{},
    /// The rows a right-click acts on, and in which list.
    menu_for: Ids = .{},
    menu_list: List = .dropdown,
    /// The manager was up last frame (it starts and ends its undo), and the
    /// bookmarks it last saw (a row taken away is no longer picked).
    manager_seen: bool = false,
    revision: u64 = 0,
    /// The search takes the keys as the manager appears.
    hunt_focus: bool = false,
    /// The tree ⇄ search switch (`.animation(Motion.settle, value:
    /// picks.query.isEmpty)`): which it was, the room's height then, and
    /// whether the room is still springing to the new height.
    hunting_was: bool = false,
    switch_gen: u32 = 0,
    switch_from: f32 = 0,
    switching: bool = false,

    pub fn expanded(s: *State, list: List) *Ids {
        return switch (list) {
            .dropdown => &s.dropdown,
            .sidebar => &s.sidebar,
            .manager => &s.picks.expanded,
        };
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.card_title.deinit();
        s.dropdown.deinit(gpa);
        s.sidebar.deinit(gpa);
        s.picks.deinit(gpa);
        s.drag.carrying.deinit(gpa);
        s.menu_for.deinit(gpa);
    }
};

/// `BookmarksDropdown.opening`: a top level that is one folder and nothing
/// else opens with that folder open.
pub fn opening(gpa: std.mem.Allocator, ids: *Ids, roots: []const Bookmark) void {
    ids.clear();
    if (roots.len == 1 and roots[0].isFolder()) ids.put(gpa, roots[0].id);
}

/// `BookmarkOutline.visible`: the rows as they read, top to bottom. On `a`.
pub fn visible(a: std.mem.Allocator, roots: []const Bookmark, open: *const Ids) ![]Uuid {
    var out: std.ArrayList(Uuid) = .empty;
    try walk(a, roots, open, &out);
    return out.items;
}

fn walk(a: std.mem.Allocator, nodes: []const Bookmark, open: *const Ids, out: *std.ArrayList(Uuid)) !void {
    for (nodes) |n| {
        try out.append(a, n.id);
        if (n.isFolder() and open.has(n.id)) try walk(a, n.kids(), open, out);
    }
}
