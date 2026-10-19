//! `History.swift` "reading": the field's suggestions and completion, the
//! History window's list and the menu's recent places. Methods of `History`.
const std = @import("std");
const json = @import("json.zig");
const url_mod = @import("url.zig");
const text_mod = @import("history_text.zig");
const History = @import("history.zig").History;
const Parts = url_mod.Parts;
const Suggestion = text_mod.Suggestion;
const Trace = text_mod.Trace;
const Visit = text_mod.Visit;

/// Best matches first. A place you have been always beats a place the app
/// merely knows the name of; among those, often and lately beats once.
/// The list is on `alloc`; its strings borrow from the history.
pub fn suggestions(self: *History, alloc: std.mem.Allocator, typed: []const u8, limit: usize) ![]Suggestion {
    self.ensureIndexed();
    const needle = try text_mod.stripped(self.gpa, typed);
    defer self.gpa.free(needle);
    // An empty field proposes nothing.
    if (needle.len == 0) return &.{};
    const now = json.now();
    var top: Best = .{ .items = try alloc.alloc(Scored, limit + 1) };
    defer alloc.free(top.items);
    // Titles too, every word somewhere in one, from three letters up.
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(self.gpa);
    if (text_mod.chars(needle) >= 3) {
        var it = std.mem.tokenizeScalar(u8, needle, ' ');
        while (it.next()) |w| try words.append(self.gpa, w);
    }
    for (self.visits.values()) |e| {
        const text = e.text orelse continue;
        // How often and how lately, flattened.
        const standing = std.math.log1p(text_mod.score(e.visit, now));
        const s: f64 = if (text_mod.rank(text.searchable, needle)) |r|
            // The front door before the room inside it.
            r + 4 + standing + @as(f64, if (text.homepage) 1.5 else 0)
        else if (words.items.len > 0 and text.title.len > 0 and allIn(words.items, text.title))
            1 + 4 + standing
        else
            continue;
        if (!top.wants(s, text.address, limit) or Parts.parse(e.visit.url) == null) continue;
        top.add(.{ .key = text.address, .title = e.visit.title, .url = e.visit.url, .kind = .visited }, s, limit);
    }
    // Only where memory has nothing to offer.
    for (text_mod.known) |kn| {
        if (self.visited_hosts.contains(kn.host)) continue;
        const r = text_mod.rank(kn.host, needle) orelse continue;
        if (!top.wants(r, kn.host, limit)) continue;
        top.add(.{ .key = kn.host, .title = kn.title, .url = kn.url, .kind = .known }, r, limit);
    }
    const out = try alloc.alloc(Suggestion, top.len);
    for (top.items[0..top.len], out) |sc, *o| o.* = sc.s;
    return out;
}

const Scored = struct { s: Suggestion, score: f64 };

/// Only the best few are kept while scanning, in order.
const Best = struct {
    items: []Scored,
    len: usize = 0,

    /// Higher first, then the shorter key, then whichever came first.
    fn ahead(score: f64, key: []const u8, other: Scored) bool {
        return if (score == other.score) text_mod.chars(key) < text_mod.chars(other.s.key) else score > other.score;
    }

    fn wants(b: *const Best, score: f64, key: []const u8, limit: usize) bool {
        return !(b.len == limit and b.len > 0 and !ahead(score, key, b.items[b.len - 1]));
    }

    fn add(b: *Best, s: Suggestion, score: f64, limit: usize) void {
        var at: usize = b.len;
        for (b.items[0..b.len], 0..) |other, i| if (ahead(score, s.key, other)) {
            at = i;
            break;
        };
        std.mem.copyBackwards(Scored, b.items[at + 1 .. b.len + 1], b.items[at..b.len]);
        b.items[at] = .{ .s = s, .score = score };
        b.len = @min(b.len + 1, limit);
    }
};

fn allIn(words: []const []const u8, hay: []const u8) bool {
    for (words) |w| if (std.mem.indexOf(u8, hay, w) == null) return false;
    return true;
}

/// What the field draws after the caret: the rest of the best match (a
/// slice of its key), or null if it doesn't carry on from what was typed.
pub fn completion(self: *History, typed: []const u8, options: []const Suggestion) !?[]const u8 {
    return text_mod.completion(self.gpa, typed, options);
}

/// Everywhere you have been matching every word typed, newest first. On
/// `alloc`; strings borrowed.
pub fn everything(self: *History, alloc: std.mem.Allocator, typed: []const u8, limit: usize) ![]Trace {
    self.ensureIndexed();
    const low = try url_mod.lower(self.gpa, typed);
    defer self.gpa.free(low);
    var out: std.ArrayList(Trace) = .empty;
    errdefer out.deinit(alloc);
    for (self.visits.values()) |e| {
        // A front-door credit has no title of its own: a second copy of every line.
        if (e.visit.title.len == 0 and e.text != null and e.text.?.homepage) continue;
        var words = std.mem.tokenizeScalar(u8, low, ' ');
        const all = while (words.next()) |w| {
            const t = e.text orelse break false;
            if (std.mem.indexOf(u8, t.searchable, w) == null and std.mem.indexOf(u8, t.title, w) == null) break false;
        } else true;
        if (!all or Parts.parse(e.visit.url) == null) continue;
        try out.append(alloc, .{
            .key = e.visit.key,
            .address = if (e.text) |t| t.address else e.visit.key,
            .title = e.visit.title,
            .url = e.visit.url,
            .last = e.visit.last,
            .count = e.visit.count,
        });
    }
    std.mem.sort(Trace, out.items, {}, newer);
    if (out.items.len > limit) out.shrinkRetainingCapacity(limit);
    return out.toOwnedSlice(alloc);
}

fn newer(_: void, a: Trace, b: Trace) bool {
    return a.last > b.last;
}

/// The last eight places, newest first; worked out again only once the
/// history has changed, and without the index.
pub fn recent(self: *History) []const Trace {
    if (self.recent_cache) |c| return c;
    var top: [9]Visit = undefined;
    var n: usize = 0;
    for (self.visits.values()) |e| {
        const v = e.visit;
        if (v.title.len == 0 and isFrontDoor(v.url)) continue;
        if (n == 8 and v.last <= top[7].last) continue;
        var at = n;
        for (top[0..n], 0..) |t, i| if (v.last > t.last) {
            at = i;
            break;
        };
        std.mem.copyBackwards(Visit, top[at + 1 .. n + 1], top[at..n]);
        top[at] = v;
        n = @min(n + 1, 8);
    }
    var made: std.ArrayList(Trace) = .empty;
    for (top[0..n]) |v| {
        const t = (text_mod.pageText(self.gpa, v.url) catch null) orelse continue;
        defer self.gpa.free(t.searchable);
        defer self.gpa.free(t.host);
        defer self.gpa.free(t.title);
        made.append(self.gpa, .{ .key = v.key, .address = t.address, .title = v.title, .url = v.url, .last = v.last, .count = v.count }) catch {
            self.gpa.free(t.address);
            break;
        };
    }
    const list = made.toOwnedSlice(self.gpa) catch {
        for (made.items) |t| self.gpa.free(t.address);
        made.deinit(self.gpa);
        return &.{};
    };
    self.recent_cache = list;
    return list;
}

/// A site's front door: an address with no path but its slash.
fn isFrontDoor(page: []const u8) bool {
    const p = Parts.parse(page) orelse return false;
    return text_mod.isHomePath(p.path);
}
