//! Bookmarks (`Bookmarks` in Bookmarks.swift, the model): folders and sites
//! in `bookmarks.json`, a plain array of the top level with each folder's
//! children inside it and every id kept. Every change builds the next tree
//! in a fresh arena and swaps it in whole (Swift's `commit`), so a pointer
//! read from here is good until the next change.
const std = @import("std");
const json = @import("json.zig");
const url = @import("url.zig");
const address = @import("../model/address.zig");
const Store = @import("store.zig").Store;
const Uuid = json.Uuid;

pub const Bookmark = struct {
    id: Uuid,
    title: []const u8,
    /// Null for a folder.
    url: ?[]const u8 = null,
    children: ?[]Bookmark = null,

    pub fn isFolder(b: Bookmark) bool {
        return b.url == null;
    }

    /// A site whose name was emptied: on the bar it is its icon alone.
    pub fn unnamed(b: Bookmark) bool {
        return !b.isFolder() and std.mem.trim(u8, b.title, " \t\r\n").len == 0;
    }

    /// What a list reads it as: its name, or its address as the field shows it. On `a`.
    pub fn label(b: Bookmark, a: std.mem.Allocator) ![]const u8 {
        if (!b.unnamed()) return b.title;
        return address.pretty(a, b.url.?);
    }

    /// A folder, with a fresh id; `inside` is taken as it is.
    pub fn folder(title: []const u8, inside: []Bookmark) Bookmark {
        return .{ .id = Uuid.random(), .title = title, .children = inside };
    }

    /// `nodes` deep-copied onto `a`, to be changed.
    pub fn copy(a: std.mem.Allocator, nodes: []const Bookmark) ![]Bookmark {
        const out = try a.alloc(Bookmark, nodes.len);
        for (out, nodes) |*o, n| o.* = try json.clone(a, n);
        return out;
    }

    fn kids(b: Bookmark) []Bookmark {
        return b.children orelse &.{};
    }
};

pub const SortKey = enum { name, site };
pub const Match = struct { node: *const Bookmark, path: []const []const u8 };
pub const Folder = struct { node: *const Bookmark, depth: usize };
pub const Taken = struct { added: usize = 0, already: usize = 0, ids: []const Uuid = &.{} };

pub const Bookmarks = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    /// Owns `roots`.
    arena: std.heap.ArenaAllocator,
    roots: []Bookmark = &.{},
    /// Every address kept, for `contains`; keys point into `roots`.
    kept: std.StringHashMapUnmanaged(void) = .empty,
    /// Bumped on every change.
    revision: u64 = 0,

    pub const file = "bookmarks.json";
    /// Which browser filled the empty top level, the first time.
    pub const top_key = "bookmarks.top";

    pub fn init(gpa: std.mem.Allocator, store: *Store) Bookmarks {
        var self: Bookmarks = .{ .gpa = gpa, .store = store, .arena = .init(gpa) };
        if (store.load([]Bookmark, file)) |p| {
            defer p.deinit();
            self.roots = json.clone(self.arena.allocator(), p.value) catch &.{};
        }
        self.rekeep();
        return self;
    }

    pub fn deinit(self: *Bookmarks) void {
        self.kept.deinit(self.gpa);
        self.arena.deinit();
    }

    // MARK: reading

    pub fn isEmpty(self: *const Bookmarks) bool {
        return self.roots.len == 0;
    }

    /// How many sites, folders opened.
    pub fn count(nodes: []const Bookmark) usize {
        var n: usize = 0;
        for (nodes) |b| n += if (b.isFolder()) count(b.kids()) else 1;
        return n;
    }

    /// Every site's address, in order, folders opened. On `a`.
    pub fn urls(a: std.mem.Allocator, nodes: []const Bookmark) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        try collectUrls(a, nodes, &out);
        return out.items;
    }

    fn collectUrls(a: std.mem.Allocator, nodes: []const Bookmark, out: *std.ArrayList([]const u8)) !void {
        for (nodes) |b| if (b.isFolder()) try collectUrls(a, b.kids(), out) else try out.append(a, b.url.?);
    }

    /// Every id in a tree, folders and all. On `a`.
    pub fn ids(a: std.mem.Allocator, nodes: []const Bookmark) ![]Uuid {
        var out: std.ArrayList(Uuid) = .empty;
        try collectIds(a, nodes, &out);
        return out.items;
    }

    fn collectIds(a: std.mem.Allocator, nodes: []const Bookmark, out: *std.ArrayList(Uuid)) !void {
        for (nodes) |b| {
            try out.append(a, b.id);
            try collectIds(a, b.kids(), out);
        }
    }

    /// Every folder with how deep it sits, for "move to folder" lists. On `a`.
    pub fn folders(a: std.mem.Allocator, nodes: []const Bookmark) ![]Folder {
        var out: std.ArrayList(Folder) = .empty;
        try collectFolders(a, nodes, 0, &out);
        return out.items;
    }

    fn collectFolders(a: std.mem.Allocator, nodes: []const Bookmark, depth: usize, out: *std.ArrayList(Folder)) !void {
        for (nodes) |*b| if (b.isFolder()) {
            try out.append(a, .{ .node = b, .depth = depth });
            try collectFolders(a, b.kids(), depth + 1, out);
        };
    }

    /// Every site and folder whose title or address holds all the words,
    /// with the folders it sits in (chrome.bookmarks.search's rule). On `a`,
    /// meant to be an arena.
    pub fn matches(self: *const Bookmarks, a: std.mem.Allocator, text: []const u8) ![]Match {
        const lowered = try url.lower(a, text);
        var words: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, lowered, ' ');
        while (it.next()) |w| try words.append(a, w);
        var found: std.ArrayList(Match) = .empty;
        if (words.items.len == 0) return found.items;
        var path: std.ArrayList([]const u8) = .empty;
        try walkMatches(a, self.roots, words.items, &path, &found);
        return found.items;
    }

    fn walkMatches(a: std.mem.Allocator, nodes: []const Bookmark, words: []const []const u8, path: *std.ArrayList([]const u8), found: *std.ArrayList(Match)) !void {
        for (nodes) |*b| {
            const title = try url.lower(a, b.title);
            const addr = try url.lower(a, b.url orelse "");
            const all = for (words) |w| {
                if (std.mem.indexOf(u8, title, w) == null and std.mem.indexOf(u8, addr, w) == null) break false;
            } else true;
            if (all) try found.append(a, .{ .node = b, .path = try a.dupe([]const u8, path.items) });
            if (b.kids().len > 0) {
                try path.append(a, b.title);
                defer _ = path.pop();
                try walkMatches(a, b.kids(), words, path, found);
            }
        }
    }

    /// The folders `id` sits in, outermost first; empty at the top level,
    /// null when it isn't here. On `a`.
    pub fn pathTo(self: *const Bookmarks, a: std.mem.Allocator, id: Uuid) !?[]*const Bookmark {
        var above: std.ArrayList(*const Bookmark) = .empty;
        return if (try walkPath(a, self.roots, id, &above)) above.items else null;
    }

    fn walkPath(a: std.mem.Allocator, nodes: []const Bookmark, id: Uuid, above: *std.ArrayList(*const Bookmark)) !bool {
        for (nodes) |*b| {
            if (b.id.eql(id)) return true;
            if (b.children) |kids| {
                try above.append(a, b);
                if (try walkPath(a, kids, id, above)) return true;
                _ = above.pop();
            }
        }
        return false;
    }

    /// The folder `id` sits in, null at the top level (or when not here).
    pub fn parent(self: *const Bookmarks, id: Uuid) ?Uuid {
        return parentIn(self.roots, null, id) orelse null;
    }

    fn parentIn(nodes: []const Bookmark, holder: ?Uuid, id: Uuid) ??Uuid {
        for (nodes) |b| {
            if (b.id.eql(id)) return holder;
            if (b.children) |kids| if (parentIn(kids, b.id, id)) |found| return found;
        }
        return null;
    }

    /// The one kept for this address, wherever it is filed.
    pub fn bookmarkFor(self: *const Bookmarks, address_: []const u8) ?*const Bookmark {
        return firstWhere(self.roots, address_, struct {
            fn f(want: []const u8, b: *const Bookmark) bool {
                return b.url != null and std.mem.eql(u8, b.url.?, want);
            }
        }.f);
    }

    pub fn bookmark(self: *const Bookmarks, id: Uuid) ?*const Bookmark {
        return find(self.roots, id);
    }

    pub fn contains(self: *const Bookmarks, address_: []const u8) bool {
        return self.kept.contains(address_);
    }

    /// `id` is `node` itself or somewhere inside it.
    pub fn holds(id: Uuid, node: *const Bookmark) bool {
        if (node.id.eql(id)) return true;
        for (node.kids()) |*k| if (holds(id, k)) return true;
        return false;
    }

    /// `ids` as they stand in the list, none inside another, in reading order. On `a`.
    pub fn topmost(self: *const Bookmarks, a: std.mem.Allocator, wanted: []const Uuid) ![]Uuid {
        var out: std.ArrayList(Uuid) = .empty;
        try walkTop(a, self.roots, wanted, &out);
        return out.items;
    }

    fn walkTop(a: std.mem.Allocator, nodes: []const Bookmark, wanted: []const Uuid, out: *std.ArrayList(Uuid)) !void {
        for (nodes) |b| if (has(wanted, b.id)) try out.append(a, b.id) else try walkTop(a, b.kids(), wanted, out);
    }

    /// Every site whose address is already kept above it in reading order;
    /// the first of each stays. On `a`.
    pub fn duplicates(self: *const Bookmarks, a: std.mem.Allocator) ![]Uuid {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var extra: std.ArrayList(Uuid) = .empty;
        try walkDupes(a, self.roots, &seen, &extra);
        return extra.items;
    }

    fn walkDupes(a: std.mem.Allocator, nodes: []const Bookmark, seen: *std.StringHashMapUnmanaged(void), extra: *std.ArrayList(Uuid)) !void {
        for (nodes) |b| {
            if (b.url) |u| if ((try seen.getOrPut(a, u)).found_existing) try extra.append(a, b.id);
            try walkDupes(a, b.kids(), seen, extra);
        }
    }

    // MARK: changing

    /// The page at the end of the list, unless already kept; its id.
    pub fn add(self: *Bookmarks, address_: []const u8, title: []const u8) ?Uuid {
        if (self.contains(address_)) return null;
        var w = self.begin() orelse return null;
        const a = w.allocator();
        const made = json.clone(a, Bookmark{
            .id = Uuid.random(),
            .title = if (title.len == 0) address.pretty(a, address_) catch return w.none() else title,
            .url = address_,
        }) catch return w.none();
        _ = place(a, made, null, null, &w.roots) catch return w.none();
        self.commit(&w);
        return made.id;
    }

    /// Every one at once, a folder with all it holds.
    pub fn remove(self: *Bookmarks, gone: []const Uuid) void {
        if (gone.len == 0) return;
        var w = self.begin() orelse return;
        prune(gone, &w.roots);
        self.commit(&w);
    }

    /// Takes bookmarks and whole folders out of wherever they sit and puts
    /// them, in reading order, into `into` (the top level for null) from
    /// `at` among what is there, or at the end. `at` counts the list as it
    /// reads before the move. Moving a folder into itself is refused.
    pub fn move(self: *Bookmarks, moving: []const Uuid, into: ?Uuid, at: ?usize) void {
        var w = self.begin() orelse return;
        const a = w.allocator();
        const tops = self.topmost(a, moving) catch return w.drop();
        if (tops.len == 0) return w.drop();
        if (into) |f| for (tops) |id| if (holds(f, self.bookmark(id).?)) return w.drop();
        var start = at;
        if (at) |wanted| {
            var leaving: usize = 0;
            const sibs = siblings(self.roots, into);
            for (sibs[0..@min(wanted, sibs.len)]) |s| leaving += @intFromBool(has(tops, s.id));
            start = wanted - leaving;
        }
        var nodes = a.alloc(Bookmark, tops.len) catch return w.drop();
        for (tops, 0..) |id, i| nodes[i] = detach(id, &w.roots).?;
        for (nodes, 0..) |node, i| {
            const ok = place(a, node, into, if (start) |s| s + i else null, &w.roots) catch false;
            if (!ok) return w.drop();
        }
        self.commit(&w);
    }

    /// The ones in `ids` in a new folder where the first of them was; its id.
    pub fn group(self: *Bookmarks, grouped: []const Uuid, name: []const u8) ?Uuid {
        var w = self.begin() orelse return null;
        const a = w.allocator();
        const tops = self.topmost(a, grouped) catch return w.none();
        if (tops.len == 0) return w.none();
        const holder = self.parent(tops[0]);
        const at = for (siblings(self.roots, holder), 0..) |s, i| {
            if (s.id.eql(tops[0])) break i;
        } else return w.none();
        const nodes = a.alloc(Bookmark, tops.len) catch return w.none();
        for (tops, 0..) |id, i| nodes[i] = detach(id, &w.roots).?;
        const made = Bookmark.folder(a.dupe(u8, name) catch return w.none(), nodes);
        const ok = place(a, made, holder, at, &w.roots) catch false;
        if (!ok) return w.none();
        self.commit(&w);
        return made.id;
    }

    /// One folder's own list (the top level for null): folders first, each
    /// kind by name, or the sites by site and then name.
    pub fn sort(self: *Bookmarks, folder_id: ?Uuid, key: SortKey) void {
        var w = self.begin() orelse return;
        if (folder_id) |id| {
            if (findMut(w.roots, id)) |f| if (f.children) |kids| ordered(kids, key);
        } else ordered(w.roots, key);
        self.commit(&w);
    }

    /// The whole list at once (Organize with AI).
    pub fn replace(self: *Bookmarks, tree: []const Bookmark) void {
        var w = self.begin() orelse return;
        w.roots = Bookmark.copy(w.allocator(), tree) catch return w.drop();
        self.commit(&w);
    }

    /// `node` filed under `into` at `at`, or at the top level when there is
    /// no such folder (chrome.bookmarks.create).
    pub fn insert(self: *Bookmarks, node: Bookmark, into: ?Uuid, at: ?usize) void {
        var w = self.begin() orelse return;
        const a = w.allocator();
        const copy = json.clone(a, node) catch return w.drop();
        const placed = place(a, copy, into, at, &w.roots) catch return w.drop();
        if (!placed) _ = place(a, copy, null, at, &w.roots) catch return w.drop();
        self.commit(&w);
    }

    /// A new title, or address for a site (chrome.bookmarks.update, Rename…).
    pub fn update(self: *Bookmarks, id: Uuid, title: ?[]const u8, address_: ?[]const u8) void {
        var w = self.begin() orelse return;
        const b = findMut(w.roots, id) orelse return w.drop();
        if (title) |t| b.title = t;
        if (address_) |u| if (!b.isFolder()) {
            b.url = u;
        };
        // The new strings may be the caller's: owned by the new tree.
        b.* = json.clone(w.allocator(), b.*) catch return w.drop();
        self.commit(&w);
    }

    // MARK: inside

    /// The next tree, being built (here and in bookmarks_merge.zig).
    pub const Work = struct {
        arena: std.heap.ArenaAllocator,
        roots: []Bookmark,

        pub fn allocator(w: *Work) std.mem.Allocator {
            return w.arena.allocator();
        }

        pub fn drop(w: *Work) void {
            w.arena.deinit();
        }

        pub fn none(w: *Work) ?Uuid {
            w.drop();
            return null;
        }
    };

    /// The tree copied into a fresh arena, to be changed and committed.
    pub fn begin(self: *Bookmarks) ?Work {
        var w: Work = .{ .arena = .init(self.gpa), .roots = &.{} };
        w.roots = json.clone(w.allocator(), self.roots) catch {
            w.drop();
            return null;
        };
        return w;
    }

    /// The changed tree kept and saved, or dropped when nothing changed.
    fn commit(self: *Bookmarks, w: *Work) void {
        if (same(w.roots, self.roots)) return w.drop();
        self.set(w);
    }

    /// The tree swapped in and saved, changed or not (imports).
    pub fn set(self: *Bookmarks, w: *Work) void {
        self.arena.deinit();
        self.arena = w.arena;
        self.roots = w.roots;
        self.revision +%= 1;
        self.rekeep();
        self.store.save(file, self.roots, false);
    }

    fn rekeep(self: *Bookmarks) void {
        self.kept.clearRetainingCapacity();
        keepUrls(self, self.roots);
    }

    fn keepUrls(self: *Bookmarks, nodes: []const Bookmark) void {
        for (nodes) |b| {
            if (b.url) |u| self.kept.put(self.gpa, u, {}) catch {};
            keepUrls(self, b.kids());
        }
    }

    pub const merge = @import("bookmarks_merge.zig");
    pub const take = merge.take;
    pub const takeNoting = merge.takeNoting;
    pub const withdraw = merge.withdraw;
    pub const @"union" = merge.@"union";
};

// ponytail: id sets are slices scanned linearly, O(n·m); a hash set if a
// manager selection of thousands ever feels slow.
pub fn has(set: []const Uuid, id: Uuid) bool {
    for (set) |x| if (x.eql(id)) return true;
    return false;
}

fn same(a: []const Bookmark, b: []const Bookmark) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.id.eql(y.id) or !std.mem.eql(u8, x.title, y.title)) return false;
        if ((x.url == null) != (y.url == null) or (x.url != null and !std.mem.eql(u8, x.url.?, y.url.?))) return false;
        if ((x.children == null) != (y.children == null)) return false;
        if (x.children != null and !same(x.children.?, y.children.?)) return false;
    }
    return true;
}

fn firstWhere(nodes: []const Bookmark, ctx: []const u8, comptime f: fn ([]const u8, *const Bookmark) bool) ?*const Bookmark {
    for (nodes) |*b| {
        if (f(ctx, b)) return b;
        if (firstWhere(b.kids(), ctx, f)) |found| return found;
    }
    return null;
}

fn find(nodes: []const Bookmark, id: Uuid) ?*const Bookmark {
    for (nodes) |*b| {
        if (b.id.eql(id)) return b;
        if (find(b.kids(), id)) |found| return found;
    }
    return null;
}

fn findMut(nodes: []Bookmark, id: Uuid) ?*Bookmark {
    for (nodes) |*b| {
        if (b.id.eql(id)) return b;
        if (b.children) |kids| if (findMut(kids, id)) |found| return found;
    }
    return null;
}

/// What a folder holds, or the top level for null.
fn siblings(roots: []const Bookmark, folder_id: ?Uuid) []const Bookmark {
    const id = folder_id orelse return roots;
    return (find(roots, id) orelse return &.{}).kids();
}

fn prune(gone: []const Uuid, nodes: *[]Bookmark) void {
    var keep: usize = 0;
    for (nodes.*) |b| {
        if (has(gone, b.id)) continue;
        nodes.*[keep] = b;
        if (nodes.*[keep].children) |*kids| prune(gone, kids);
        keep += 1;
    }
    nodes.* = nodes.*[0..keep];
}

/// `id` taken out of wherever it sits.
pub fn detach(id: Uuid, nodes: *[]Bookmark) ?Bookmark {
    for (nodes.*, 0..) |*b, i| {
        if (b.id.eql(id)) {
            const out = b.*;
            std.mem.copyForwards(Bookmark, nodes.*[i..], nodes.*[i + 1 ..]);
            nodes.* = nodes.*[0 .. nodes.len - 1];
            return out;
        }
        if (b.children) |*kids| if (detach(id, kids)) |found| return found;
    }
    return null;
}

/// `node` into the folder `into` (the top level for null) at `at`,
/// clamped, or at the end; false when there is no such folder.
pub fn place(a: std.mem.Allocator, node: Bookmark, into: ?Uuid, at: ?usize, nodes: *[]Bookmark) !bool {
    const id = into orelse {
        nodes.* = try insertAt(a, nodes.*, node, at);
        return true;
    };
    for (nodes.*) |*b| {
        if (b.id.eql(id) and b.isFolder()) {
            b.children = try insertAt(a, b.kids(), node, at);
            return true;
        }
        if (b.children) |*kids| if (try place(a, node, into, at, kids)) return true;
    }
    return false;
}

fn insertAt(a: std.mem.Allocator, list: []const Bookmark, node: Bookmark, at: ?usize) ![]Bookmark {
    const i = @min(at orelse list.len, list.len);
    const out = try a.alloc(Bookmark, list.len + 1);
    @memcpy(out[0..i], list[0..i]);
    out[i] = node;
    @memcpy(out[i + 1 ..], list[i..]);
    return out;
}

fn ordered(list: []Bookmark, key: SortKey) void {
    std.mem.sort(Bookmark, list, key, before);
}

/// Folders first by name; sites by name, or by site then name.
fn before(key: SortKey, x: Bookmark, y: Bookmark) bool {
    if (x.isFolder() != y.isFolder()) return x.isFolder();
    if (!x.isFolder() and key == .site) {
        const sx = siteOf(x);
        const sy = siteOf(y);
        if (!std.ascii.eqlIgnoreCase(sx, sy)) return json.keyOrder(sx, sy) == .lt;
    }
    return json.keyOrder(x.title, y.title) == .lt;
}

/// Its host without www, as `sort(by: .site)` reads it.
fn siteOf(b: Bookmark) []const u8 {
    const h = (url.Parts.parse(b.url orelse return "") orelse return "").hostName() orelse return "";
    return if (std.ascii.startsWithIgnoreCase(h, "www.")) h[4..] else h;
}

test {
    _ = @import("bookmarks_tests.zig");
}
