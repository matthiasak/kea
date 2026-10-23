//! Undo for the bookmarks while the manager is open (`Bookmarks.undo`, the
//! window's UndoManager in Swift): every change keeps the tree before it,
//! undoing puts that back as a change of its own, so it can be redone.
// ponytail: snapshot undo restores the whole tree, so it also reverts an
// extension's or import's change made after the undone one, as Swift's does.
const std = @import("std");
const bm = @import("bookmarks.zig");
const Bookmarks = bm.Bookmarks;
const Bookmark = bm.Bookmark;

const Snapshot = struct { arena: std.heap.ArenaAllocator, roots: []Bookmark };

pub const History = struct {
    /// The manager is open: changes can be undone.
    on: bool = false,
    undos: std.ArrayList(Snapshot) = .empty,
    redos: std.ArrayList(Snapshot) = .empty,
    replaying: enum { none, undo, redo } = .none,

    pub fn deinit(h: *History, gpa: std.mem.Allocator) void {
        drop(&h.undos);
        drop(&h.redos);
        h.undos.deinit(gpa);
        h.redos.deinit(gpa);
    }
};

fn drop(list: *std.ArrayList(Snapshot)) void {
    for (list.items) |*s| s.arena.deinit();
    list.clearRetainingCapacity();
}

/// The tree being replaced (from `Bookmarks.set`): kept to go back to while
/// undo is on, freed otherwise.
pub fn retire(self: *Bookmarks) void {
    const h = &self.history;
    if (!h.on) return self.arena.deinit();
    const old: Snapshot = .{ .arena = self.arena, .roots = self.roots };
    const into = switch (h.replaying) {
        .none, .redo => &h.undos,
        .undo => &h.redos,
    };
    // A new change: what was undone can't be redone any more.
    if (h.replaying == .none) drop(&h.redos);
    if (into.items.len >= 32) {
        var oldest = into.orderedRemove(0);
        oldest.arena.deinit();
    }
    into.append(self.gpa, old) catch {
        var lost = old;
        lost.arena.deinit();
    };
}

pub fn start(self: *Bookmarks) void {
    self.history.on = true;
}

/// The manager closed: what was done there can't be undone from elsewhere.
pub fn stop(self: *Bookmarks) void {
    const h = &self.history;
    h.on = false;
    drop(&h.undos);
    drop(&h.redos);
}

pub fn undo(self: *Bookmarks) bool {
    return replay(self, .undo);
}

pub fn redo(self: *Bookmarks) bool {
    return replay(self, .redo);
}

fn replay(self: *Bookmarks, how: @TypeOf(self.history.replaying)) bool {
    const h = &self.history;
    const s = (if (how == .undo) h.undos.pop() else h.redos.pop()) orelse return false;
    h.replaying = how;
    defer h.replaying = .none;
    var w: Bookmarks.Work = .{ .arena = s.arena, .roots = s.roots };
    self.set(&w);
    return true;
}
