//! Bookmarks brought in from another browser or another Mac
//! (Bookmarks.swift `take`, `takeNoting`, `withdraw`, `union`): merged
//! level by level, a folder into the folder of the same name, a page only
//! when its address isn't already at that level.
const std = @import("std");
const json = @import("json.zig");
const bm = @import("bookmarks.zig");
const Bookmarks = bm.Bookmarks;
const Bookmark = bm.Bookmark;
const Taken = bm.Taken;
const Uuid = json.Uuid;

const Counts = struct { added: usize = 0, already: usize = 0 };

/// Another browser's, kept apart in a folder of that browser's name unless
/// there was nothing here yet (or most of its pages are already at the top
/// level). Bringing them in again adds only what is new.
pub fn take(self: *Bookmarks, nodes: []const Bookmark, from: []const u8) Taken {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const t = takeNoting(self, scratch.allocator(), nodes, from);
    return .{ .added = t.added, .already = t.already };
}

/// The same, with every bookmark and folder it added (ids on `a`), so an
/// import can be taken back out exactly.
pub fn takeNoting(self: *Bookmarks, a: std.mem.Allocator, nodes: []const Bookmark, from: []const u8) Taken {
    if (nodes.len == 0) return .{};
    var w = self.begin() orelse return .{};
    const wa = w.allocator();
    const incoming = Bookmark.copy(wa, nodes) catch return dropped(&w);
    var counts: Counts = .{};
    var ids: std.ArrayList(Uuid) = .empty;
    if (self.roots.len == 0) {
        w.roots = incoming;
        counts.added = Bookmarks.count(incoming);
        ids.appendSlice(a, Bookmarks.ids(a, incoming) catch return dropped(&w)) catch return dropped(&w);
        self.store.setString(Bookmarks.top_key, from);
    } else if (intoTop(self, nodes, from)) {
        mergeInto(wa, incoming, &w.roots, &counts, a, &ids) catch return dropped(&w);
    } else {
        const at = for (w.roots, 0..) |r, i| {
            if (r.isFolder() and std.mem.eql(u8, r.title, from)) break i;
        } else null;
        var kids: []Bookmark = if (at) |i| w.roots[i].children orelse &.{} else &.{};
        mergeInto(wa, incoming, &kids, &counts, a, &ids) catch return dropped(&w);
        if (at) |i| {
            w.roots[i].children = kids;
        } else {
            const made = Bookmark.folder(wa.dupe(u8, from) catch return dropped(&w), kids);
            ids.append(a, made.id) catch return dropped(&w);
            _ = bm.place(wa, made, null, null, &w.roots) catch return dropped(&w);
        }
    }
    self.set(&w);
    return .{ .added = counts.added, .already = counts.already, .ids = ids.items };
}

fn dropped(w: anytype) Taken {
    w.drop();
    return .{};
}

/// Takes back out what an import added: every site among `ids` wherever it
/// now sits, then every folder among them left empty. Returns how many
/// sites went.
pub fn withdraw(self: *Bookmarks, ids: []const Uuid) usize {
    var w = self.begin() orelse return 0;
    var gone: usize = 0;
    strip(ids, &w.roots, &gone);
    self.set(&w);
    return gone;
}

fn strip(ours: []const Uuid, nodes: *[]Bookmark, gone: *usize) void {
    var keep: usize = 0;
    for (nodes.*) |b| {
        if (!b.isFolder() and bm.has(ours, b.id)) {
            gone.* += 1;
            continue;
        }
        var c = b;
        if (c.children) |*kids| {
            strip(ours, kids, gone);
            if (bm.has(ours, c.id) and kids.len == 0) continue;
        }
        nodes.*[keep] = c;
        keep += 1;
    }
    nodes.* = nodes.*[0..keep];
}

/// `local` merged into `remote`, on `a` (Sync).
pub fn @"union"(a: std.mem.Allocator, remote: []const Bookmark, local: []const Bookmark) ![]Bookmark {
    var nodes = try Bookmark.copy(a, remote);
    var counts: Counts = .{};
    try mergeInto(a, try json.clone(a, local), &nodes, &counts, a, null);
    return nodes;
}

/// Whether this browser's bookmarks belong at the top level: it filled it
/// the first time, or (from before that was noted) most of its pages are
/// already there.
fn intoTop(self: *Bookmarks, nodes: []const Bookmark, from: []const u8) bool {
    if (self.store.string(Bookmarks.top_key)) |top| {
        defer self.gpa.free(top);
        return std.mem.eql(u8, top, from);
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const theirs = Bookmarks.urls(scratch.allocator(), nodes) catch return false;
    if (theirs.len == 0) return false;
    var shared: usize = 0;
    for (theirs) |u| shared += @intFromBool(self.kept.contains(u));
    if (shared * 2 < theirs.len) return false;
    self.store.setString(Bookmarks.top_key, from);
    return true;
}

/// `incoming` (already on `wa`) into `nodes`, level by level.
fn mergeInto(wa: std.mem.Allocator, incoming: []const Bookmark, nodes: *[]Bookmark, counts: *Counts, a: std.mem.Allocator, ids: ?*std.ArrayList(Uuid)) !void {
    var list: std.ArrayList(Bookmark) = .empty;
    try list.appendSlice(wa, nodes.*);
    var folders: std.StringHashMapUnmanaged(usize) = .empty;
    var pages: std.StringHashMapUnmanaged(void) = .empty;
    for (list.items, 0..) |b, i| {
        if (b.isFolder()) {
            const gop = try folders.getOrPut(wa, b.title);
            if (!gop.found_existing) gop.value_ptr.* = i;
        } else try pages.put(wa, b.url.?, {});
    }
    for (incoming) |node| {
        if (node.isFolder()) {
            if (folders.get(node.title)) |at| {
                var kids: []Bookmark = list.items[at].children orelse &.{};
                try mergeInto(wa, node.children orelse &.{}, &kids, counts, a, ids);
                list.items[at].children = kids;
            } else {
                try folders.put(wa, node.title, list.items.len);
                try list.append(wa, node);
                counts.added += Bookmarks.count(&.{node});
                if (ids) |out| try out.appendSlice(a, try Bookmarks.ids(a, &.{node}));
            }
        } else if (pages.contains(node.url.?)) {
            counts.already += 1;
        } else {
            try pages.put(wa, node.url.?, {});
            try list.append(wa, node);
            counts.added += 1;
            if (ids) |out| try out.append(a, node.id);
        }
    }
    nodes.* = list.items;
}
