//! chrome.bookmarks from Kea's own (ExtensionShims.swift 3433-3495), and
//! the tree as Chrome shapes it (4307-4343): "0" the root, "1" the bar,
//! which is Kea's top level; every other id the bookmark's UUID.
const std = @import("std");
const ans = @import("answer.zig");
const marks = @import("../../data/bookmarks.zig");
const url_mod = @import("../../data/url.zig");
const Uuid = @import("../../data/json.zig").Uuid;
const Bookmark = marks.Bookmark;
const Call = ans.Call;

/// A bookmark as Chrome describes one (`node`, `bar`, `root`).
pub const Node = struct {
    id: []const u8,
    parentId: ?[]const u8 = null,
    index: ?usize = null,
    title: []const u8,
    url: ?[]const u8 = null,
    dateAdded: i64 = 0,
    dateGroupModified: ?i64 = null,
    folderType: ?[]const u8 = null,
    syncing: bool = false,
    children: ?[]Node = null,
};

pub const Hit = struct { node: *const Bookmark, parent: []const u8, index: usize };

/// Every bookmark in reading order, with its parent's id and its place.
pub fn flat(a: std.mem.Allocator, nodes: []const Bookmark) ![]Hit {
    var out: std.ArrayList(Hit) = .empty;
    try walk(a, nodes, "1", &out);
    return out.items;
}

fn walk(a: std.mem.Allocator, nodes: []const Bookmark, parent: []const u8, out: *std.ArrayList(Hit)) !void {
    for (nodes, 0..) |*n, i| {
        try out.append(a, .{ .node = n, .parent = parent, .index = i });
        if (n.children) |kids| try walk(a, kids, try idOf(a, n.*), out);
    }
}

pub fn find(a: std.mem.Allocator, key: []const u8, nodes: []const Bookmark) !?Hit {
    for (try flat(a, nodes)) |h| if (std.mem.eql(u8, &h.node.id.string(), key)) return h;
    return null;
}

fn idOf(a: std.mem.Allocator, b: Bookmark) ![]const u8 {
    return a.dupe(u8, &b.id.string());
}

pub fn node(a: std.mem.Allocator, n: Bookmark, parent: []const u8, index: usize, deep: bool) std.mem.Allocator.Error!Node {
    var out: Node = .{ .id = try idOf(a, n), .parentId = parent, .index = index, .title = n.title, .url = n.url };
    if (n.isFolder()) {
        out.dateGroupModified = 0;
        if (deep) out.children = try nodesOf(a, n.kids(), out.id);
    }
    return out;
}

fn nodesOf(a: std.mem.Allocator, list: []const Bookmark, parent: []const u8) std.mem.Allocator.Error![]Node {
    const out = try a.alloc(Node, list.len);
    for (list, out, 0..) |n, *o, i| o.* = try node(a, n, parent, i, true);
    return out;
}

pub fn bar(a: std.mem.Allocator, roots: []const Bookmark, deep: bool) !Node {
    return .{
        .id = "1",
        .parentId = "0",
        .index = 0,
        .title = "Bookmarks",
        .folderType = "bookmarks-bar",
        .children = if (deep) try nodesOf(a, roots, "1") else null,
    };
}

pub fn root(a: std.mem.Allocator, roots: []const Bookmark) !Node {
    const kids = try a.alloc(Node, 1);
    kids[0] = try bar(a, roots, true);
    return .{ .id = "0", .title = "", .children = kids };
}

fn shallow(a: std.mem.Allocator, h: Hit) !Node {
    return node(a, h.node.*, h.parent, h.index, false);
}

/// `find(key).map { node(…, deep: false) }`, nil when gone.
fn found(c: *Call, key: []const u8) ans.Error!?ans.Out {
    const h = try find(c.a, key, c.browser.bookmarks.roots) orelse return ans.none;
    return c.give(try shallow(c.a, h));
}

fn uuid(c: *Call) ans.Error!Uuid {
    const key = ans.str(c.first()) orelse return c.fail("No such bookmark", .{});
    return Uuid.parse(key) catch c.fail("No such bookmark", .{});
}

/// `UUID(uuidString:)` of an optional string.
fn parseId(s: ?[]const u8) ?Uuid {
    return Uuid.parse(s orelse return null) catch null;
}

/// `as? Int` for an index into a list: negatives as the start.
fn place(v: ?std.json.Value) ?usize {
    const i = ans.int(v) orelse return null;
    return @intCast(@max(i, 0));
}

const no_nodes: []const Node = &.{};

pub fn run(c: *Call) ans.Error!?ans.Out {
    if (!std.mem.startsWith(u8, c.api, "bookmarks.")) return null;
    const api = c.api["bookmarks.".len..];
    const a = c.a;
    const marks_ = c.browser.bookmarks;
    const roots = marks_.roots;
    const eql = std.mem.eql;

    if (eql(u8, api, "getTree")) {
        return c.give(.{try root(a, roots)});
    } else if (eql(u8, api, "getSubTree")) {
        const key = ans.str(c.first()) orelse return c.give(no_nodes);
        if (eql(u8, key, "0")) return c.give(.{try root(a, roots)});
        if (eql(u8, key, "1")) return c.give(.{try bar(a, roots, true)});
        const h = try find(a, key, roots) orelse return c.give(no_nodes);
        return c.give(.{try node(a, h.node.*, h.parent, h.index, true)});
    } else if (eql(u8, api, "getChildren")) {
        const key = ans.str(c.first()) orelse "1";
        if (eql(u8, key, "0")) return c.give(.{try bar(a, roots, false)});
        const kids = if (eql(u8, key, "1")) roots else if (try find(a, key, roots)) |h| h.node.kids() else &.{};
        const out = try a.alloc(Node, kids.len);
        for (kids, out, 0..) |n, *o, i| o.* = try node(a, n, key, i, false);
        return c.give(out);
    } else if (eql(u8, api, "get")) {
        const keys = try ans.allStrings(a, c.first()) orelse if (ans.str(c.first())) |s| try a.dupe([]const u8, &.{s}) else &.{};
        var out: std.ArrayList(Node) = .empty;
        for (keys) |key| if (try find(a, key, roots)) |h| try out.append(a, try shallow(a, h));
        return c.give(out.items);
    } else if (eql(u8, api, "getRecent")) {
        const count: usize = @intCast(@max(ans.int(c.first()) orelse 10, 0));
        var sites: std.ArrayList(Hit) = .empty;
        for (try flat(a, roots)) |h| if (!h.node.isFolder()) try sites.append(a, h);
        const last = sites.items[sites.items.len - @min(count, sites.items.len) ..];
        const out = try a.alloc(Node, last.len);
        for (out, 0..) |*o, i| o.* = try shallow(a, last[last.len - 1 - i]);
        return c.give(out);
    } else if (eql(u8, api, "search")) {
        const first = c.first();
        const query = ans.str(first) orelse ans.str(ans.field(first, "query")) orelse "";
        const want_url = ans.str(ans.field(first, "url"));
        const want_title = ans.str(ans.field(first, "title"));
        const low = try url_mod.lower(a, query);
        var out: std.ArrayList(Node) = .empty;
        for (try flat(a, roots)) |h| {
            const n = h.node;
            if (want_url) |u| if (n.url == null or !eql(u8, n.url.?, u)) continue;
            if (want_title) |t| if (!eql(u8, n.title, t)) continue;
            const hay = try url_mod.lower(a, try std.mem.concat(a, u8, &.{ n.title, " ", n.url orelse "" }));
            var words = std.mem.tokenizeScalar(u8, low, ' ');
            const all = while (words.next()) |w| {
                if (std.mem.indexOf(u8, hay, w) == null) break false;
            } else true;
            if (all) try out.append(a, try shallow(a, h));
        }
        return c.give(out.items);
    } else if (eql(u8, api, "create")) {
        const spec = c.first();
        const title = ans.str(ans.field(spec, "title")) orelse "";
        const made: Bookmark = if (ans.str(ans.field(spec, "url"))) |u|
            .{ .id = Uuid.random(), .title = title, .url = u }
        else
            .{ .id = Uuid.random(), .title = title, .children = &.{} };
        marks_.insert(made, parseId(ans.str(ans.field(spec, "parentId"))), place(ans.field(spec, "index")));
        return found(c, try idOf(a, made));
    } else if (eql(u8, api, "update")) {
        const id = try uuid(c);
        const changes = c.arg(1);
        marks_.update(id, ans.str(ans.field(changes, "title")), ans.str(ans.field(changes, "url")));
        return found(c, ans.str(c.first()).?);
    } else if (eql(u8, api, "move")) {
        const id = try uuid(c);
        const spec = c.arg(1);
        // No parent named keeps it in the folder it is in, as in Chrome;
        // "1", the bar, is the top level.
        const target = if (ans.str(ans.field(spec, "parentId"))) |p| parseId(p) else marks_.parent(id);
        marks_.move(&.{id}, target, place(ans.field(spec, "index")));
        return found(c, ans.str(c.first()).?);
    } else if (eql(u8, api, "remove") or eql(u8, api, "removeTree")) {
        marks_.remove(&.{try uuid(c)});
        return ans.none;
    }
    return null;
}
