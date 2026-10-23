//! Where you have been, so the field can finish the address for you
//! (`History.swift`): `history.json`, a plain array of `Visit`, written
//! 1.5 s after a visit at most 2000 strong, best-scored first.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("json.zig");
const Store = @import("store.zig").Store;
const url_mod = @import("url.zig");
const text_mod = @import("history_text.zig");
const Parts = url_mod.Parts;

pub const Visit = text_mod.Visit;
pub const PageText = text_mod.PageText;
pub const Suggestion = text_mod.Suggestion;
pub const Trace = text_mod.Trace;
pub const identity = text_mod.identity;
pub const kept = text_mod.kept;
pub const rank = text_mod.rank;
pub const score = text_mod.score;
const most_visits = text_mod.most_visits;

pub const file_name = "history.json";
/// What the file keeps at most.
pub const cap = 2000;

const Entry = struct {
    /// Strings on the history's gpa; the map key is `visit.key`.
    visit: Visit,
    /// Null until indexed (see `ensureIndexed`).
    text: ?PageText = null,
};

/// A coalesced save in flight; `history` is cleared when a write overtakes it.
const Pending = struct { history: ?*History };

/// Every `[]const u8` this hands out borrows from the history and holds
/// until it next changes.
pub const History = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    visits: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// Hosts (without www) with indexed pages, counted.
    visited_hosts: std.StringHashMapUnmanaged(u32) = .empty,
    indexed: bool = true,
    saving: ?*Pending = null,
    /// `recent()`; its addresses are owned here.
    recent_cache: ?[]Trace = null,
    /// Goes up with every change: lists drawn from the history (the
    /// History panel) know when to work themselves out again.
    generation: u64 = 0,

    /// In place, since a save in flight points back here; loads the file.
    pub fn init(self: *History, gpa: std.mem.Allocator, store: *Store) void {
        self.* = .{ .gpa = gpa, .store = store };
        self.load();
    }

    pub fn deinit(self: *History) void {
        if (self.saving) |p| p.history = null;
        self.clear();
        self.visits.deinit(self.gpa);
        self.visited_hosts.deinit(self.gpa);
    }

    fn clear(self: *History) void {
        self.changed();
        for (self.visits.values()) |e| self.freeEntry(e);
        self.visits.clearRetainingCapacity();
        var it = self.visited_hosts.keyIterator();
        while (it.next()) |h| self.gpa.free(h.*);
        self.visited_hosts.clearRetainingCapacity();
    }

    fn freeEntry(self: *History, e: Entry) void {
        self.gpa.free(e.visit.url);
        self.gpa.free(e.visit.key);
        self.gpa.free(e.visit.title);
        if (e.text) |t| t.deinit(self.gpa);
    }

    /// Swift's `visits` `didSet`.
    fn changed(self: *History) void {
        self.generation +%= 1;
        const cache = self.recent_cache orelse return;
        for (cache) |t| self.gpa.free(t.address);
        self.gpa.free(cache);
        self.recent_cache = null;
    }

    fn dupe(self: *History, s: []const u8) ![]u8 {
        return self.gpa.dupe(u8, s);
    }

    fn replace(self: *History, field: *[]const u8, s: []const u8) !void {
        const copy = try self.dupe(s);
        self.gpa.free(field.*);
        field.* = copy;
    }

    fn put(self: *History, v: Visit) !*Entry {
        const owned: Visit = .{ .url = try self.dupe(v.url), .key = try self.dupe(v.key), .title = try self.dupe(v.title), .count = v.count, .last = v.last };
        const gop = try self.visits.getOrPut(self.gpa, owned.key);
        gop.value_ptr.* = .{ .visit = owned };
        return gop.value_ptr;
    }

    fn drop(self: *History, key: []const u8) void {
        const kv = self.visits.fetchSwapRemove(key) orelse return;
        self.forgetText(kv.value.text);
        self.freeEntry(.{ .visit = kv.value.visit });
    }

    /// Builds the search index the first time something needs it.
    pub fn ensureIndexed(self: *History) void {
        if (self.indexed) return;
        self.indexed = true;
        self.rehomeCredits() catch {};
        for (self.visits.values()) |*e| self.remember(e, null);
    }

    fn remember(self: *History, e: *Entry, page: ?[]const u8) void {
        var t = (text_mod.pageText(self.gpa, page orelse e.visit.url) catch null) orelse return;
        const title = url_mod.lower(self.gpa, e.visit.title) catch {
            t.deinit(self.gpa);
            return;
        };
        self.gpa.free(t.title);
        t.title = title;
        self.forgetText(e.text);
        e.text = t;
        if (t.host.len == 0) return;
        const gop = self.visited_hosts.getOrPut(self.gpa, t.host) catch return;
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.key_ptr.* = self.dupe(t.host) catch {
                self.visited_hosts.removeByPtr(gop.key_ptr);
                return;
            };
            gop.value_ptr.* = 1;
        }
    }

    /// Releases `text`'s host; frees `text`.
    fn forgetText(self: *History, text: ?PageText) void {
        const t = text orelse return;
        defer t.deinit(self.gpa);
        if (t.host.len == 0) return;
        const kv = self.visited_hosts.getEntry(t.host) orelse return;
        kv.value_ptr.* -= 1;
        if (kv.value_ptr.* > 0) return;
        const owned = kv.key_ptr.*;
        self.visited_hosts.removeByPtr(kv.key_ptr);
        self.gpa.free(owned);
    }

    fn setTitle(self: *History, e: *Entry, title: []const u8) !void {
        const low: ?[]u8 = if (e.text != null) try url_mod.lower(self.gpa, title) else null;
        errdefer if (low) |l| self.gpa.free(l);
        try self.replace(&e.visit.title, title);
        if (e.text) |*t| {
            self.gpa.free(t.title);
            t.title = low.?;
        }
    }

    // MARK: - writing

    pub fn record(self: *History, page: []const u8, title: []const u8) void {
        self.recordAt(page, title, json.now()) catch {};
    }

    fn recordAt(self: *History, raw_in: []const u8, title_in: []const u8, now: json.SwiftDate) !void {
        const raw = try self.dupe(raw_in);
        defer self.gpa.free(raw);
        const title = try self.dupe(title_in);
        defer self.gpa.free(title);
        self.ensureIndexed();
        if (!text_mod.isWeb(raw)) return;
        const page = try kept(self.gpa, raw) orelse return;
        defer self.gpa.free(page);
        const key = try identity(self.gpa, page);
        defer self.gpa.free(key);
        if (key.len == 0) return;
        self.changed();

        // Reading a deep page is also another visit to the site, so three
        // letters offer the front page rather than last week's article.
        if (!text_mod.isHomePath(Parts.parse(page).?.path)) {
            if (try text_mod.homepage(self.gpa, page)) |home_url| {
                defer self.gpa.free(home_url);
                const root = try identity(self.gpa, home_url);
                defer self.gpa.free(root);
                const home = self.visits.getPtr(root) orelse
                    try self.put(.{ .url = home_url, .key = root, .title = "", .count = 0, .last = now });
                home.visit.count = @min(most_visits, home.visit.count + 1);
                home.visit.last = now;
                self.remember(home, home_url);
            }
        }

        if (self.visits.getPtr(key)) |seen| {
            seen.visit.count = @min(most_visits, seen.visit.count + 1);
            seen.visit.last = now;
            try self.replace(&seen.visit.url, page);
            if (title.len > 0) try self.replace(&seen.visit.title, title);
            self.remember(seen, page);
        } else {
            const e = try self.put(.{ .url = page, .key = key, .title = title, .count = 1, .last = now });
            self.remember(e, page);
        }
        self.save();
    }

    /// Somewhere another browser has been, counted as it was counted there.
    /// Call `settle` after a batch.
    pub fn take(self: *History, raw: []const u8, title: []const u8, count: i64, last: json.SwiftDate) void {
        self.takeVisit(raw, title, count, last) catch {};
    }

    fn takeVisit(self: *History, raw_in: []const u8, title_in: []const u8, count: i64, last: json.SwiftDate) !void {
        const raw = try self.dupe(raw_in);
        defer self.gpa.free(raw);
        const title = try self.dupe(title_in);
        defer self.gpa.free(title);
        self.ensureIndexed();
        if (!text_mod.isWeb(raw)) return;
        const page = try kept(self.gpa, raw) orelse return;
        defer self.gpa.free(page);
        const key = try identity(self.gpa, page);
        defer self.gpa.free(key);
        if (key.len == 0) return;
        self.changed();
        if (self.visits.getPtr(key)) |seen| {
            // The larger of the two, not their sum: the same browser brought
            // in again must not count every visit twice.
            seen.visit.count = @min(most_visits, @max(seen.visit.count, count));
            if (last > seen.visit.last) seen.visit.last = last;
            if (seen.visit.title.len == 0) try self.setTitle(seen, title);
        } else {
            const e = try self.put(.{ .url = page, .key = key, .title = title, .count = @min(@max(count, 0), most_visits), .last = last });
            self.remember(e, page);
        }
    }

    /// After a batch of `take`s.
    pub fn settle(self: *History) void {
        self.save();
    }

    /// A page's title usually lands a beat after the page does.
    pub fn retitle(self: *History, page: []const u8, title: []const u8) void {
        if (title.len == 0) return;
        const key = identity(self.gpa, page) catch return;
        defer self.gpa.free(key);
        const seen = self.visits.getPtr(key) orelse return;
        if (std.mem.eql(u8, seen.visit.title, title)) return;
        self.changed();
        self.setTitle(seen, title) catch return;
        self.save();
    }

    /// The best `cap` by score, ordered by key; on `alloc`, strings borrowed.
    pub fn exported(self: *History, alloc: std.mem.Allocator) ![]Visit {
        self.ensureIndexed();
        const list = try self.best(alloc, json.now());
        std.mem.sort(Visit, list, {}, struct {
            fn lt(_: void, a: Visit, b: Visit) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lt);
        return list;
    }

    /// Visits from another Mac, kept where they say more than ours.
    pub fn absorb(self: *History, list: []const Visit) void {
        self.ensureIndexed();
        var any = false;
        for (list) |v| {
            if (self.visits.get(v.key)) |e| {
                const seen = e.visit;
                if (seen.count >= v.count and seen.last >= v.last and (seen.title.len > 0 or v.title.len == 0)) continue;
            }
            if (Parts.parse(v.url) == null) continue;
            self.take(v.url, v.title, v.count, v.last);
            any = true;
        }
        if (any) self.save();
    }

    /// Every visit last made at or before `date`.
    pub fn forgetBefore(self: *History, date: json.SwiftDate) void {
        self.ensureIndexed();
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(self.gpa);
        for (self.visits.values()) |e| if (e.visit.last <= date) keys.append(self.gpa, e.visit.key) catch return;
        if (keys.items.len == 0) return;
        self.changed();
        for (keys.items) |key| self.drop(key);
        self.save();
    }

    /// `key`, if it was last visited at or before `date`.
    pub fn forgetKeyBefore(self: *History, key: []const u8, date: json.SwiftDate) void {
        self.ensureIndexed();
        const e = self.visits.get(key) orelse return;
        if (e.visit.last <= date) self.forget(key);
    }

    /// Everything.
    pub fn forgetAll(self: *History) void {
        self.indexed = true;
        self.clear();
        self.save();
    }

    pub fn forget(self: *History, key: []const u8) void {
        self.ensureIndexed();
        self.changed();
        self.drop(key);
        self.save();
    }

    pub const everything = @import("history_read.zig").everything;
    pub const recent = @import("history_read.zig").recent;
    pub const suggestions = @import("history_read.zig").suggestions;
    pub const completion = @import("history_read.zig").completion;

    // MARK: - the file

    fn load(self: *History) void {
        const parsed = self.store.load([]Visit, file_name) orelse return;
        defer parsed.deinit();
        var cleaned = false;
        for (parsed.value) |saved| {
            self.loadOne(saved, &cleaned) catch return;
        }
        self.indexed = false;
        // And written without names and passwords now, not at the next visit.
        if (cleaned) self.save();
    }

    fn loadOne(self: *History, saved: Visit, cleaned: *bool) !void {
        var v = saved;
        // A count edited by hand is held to a sane range, so adding can't overflow.
        v.count = @min(@max(v.count, 0), most_visits);
        var page: ?[]u8 = null;
        var key: ?[]u8 = null;
        defer if (page) |p| self.gpa.free(p);
        defer if (key) |k_| self.gpa.free(k_);
        if (Parts.parse(v.url) != null) {
            page = try kept(self.gpa, v.url);
            if (!std.mem.eql(u8, page.?, v.url)) {
                v.url = page.?;
                cleaned.* = true;
            }
            key = try identity(self.gpa, saved.url);
            v.key = key.?;
        }
        // Keys written by an older Kea can meet under the new rule: merged.
        if (self.visits.getPtr(v.key)) |e| try self.merge(&e.visit, v) else _ = try self.put(v);
    }

    /// The same page twice: visits added up, the latest date, a title if
    /// either had one. `b` is borrowed.
    fn merge(self: *History, a: *Visit, b: Visit) !void {
        const a_newer = a.last >= b.last;
        const sum = std.math.add(i64, a.count, b.count) catch most_visits;
        if (!a_newer) {
            try self.replace(&a.url, b.url);
            if (b.title.len > 0) try self.replace(&a.title, b.title);
            a.last = b.last;
        } else if (a.title.len == 0) try self.replace(&a.title, b.title);
        a.count = @min(most_visits, sum);
    }

    /// Before 1.0.4, every deep page also credited https:// and its host
    /// without www, whatever the page was on. Such a credit, with no title and
    /// nothing else on its own origin, moves to the front door its pages used.
    fn rehomeCredits(self: *History) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // Visits per front door, by host without www, from the deeper pages.
        var doors: std.StringHashMapUnmanaged(std.StringArrayHashMapUnmanaged(i64)) = .empty;
        for (self.visits.values()) |e| {
            const p = Parts.parse(e.visit.url) orelse continue;
            const host = p.hostName() orelse continue;
            if (text_mod.isHomePath(p.path)) continue;
            const home = try text_mod.homepage(a, e.visit.url) orelse continue;
            const low = try url_mod.lower(a, host);
            const bare = if (std.mem.startsWith(u8, low, "www.")) low[4..] else low;
            const gop = try doors.getOrPut(a, bare);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const door = try gop.value_ptr.getOrPut(a, try identity(a, home));
            if (!door.found_existing) door.value_ptr.* = 0;
            door.value_ptr.* +|= e.visit.count;
        }
        const keys = try a.alloc([]const u8, self.visits.count());
        for (self.visits.keys(), keys) |key, *o| o.* = try a.dupe(u8, key);
        for (keys) |key| {
            const credit = (self.visits.get(key) orelse continue).visit;
            if (credit.title.len != 0) continue;
            const p = Parts.parse(credit.url) orelse continue;
            if (!std.mem.eql(u8, p.scheme orelse "", "https") or p.port != null or p.query != null or !text_mod.isHomePath(p.path)) continue;
            const host = try url_mod.lower(a, p.hostName() orelse continue);
            if (std.mem.startsWith(u8, host, "www.")) continue;
            const used = doors.get(host) orelse continue;
            if (used.contains(key)) continue;
            // The most used, and of those the first by name.
            var door: []const u8 = "";
            var most: i64 = -1;
            var it = used.iterator();
            while (it.next()) |d| if (d.value_ptr.* > most or (d.value_ptr.* == most and std.mem.lessThan(u8, d.key_ptr.*, door))) {
                door = d.key_ptr.*;
                most = d.value_ptr.*;
            };
            if (Parts.parse(door) == null) continue;
            self.changed();
            const moved: Visit = .{ .url = door, .key = door, .title = "", .count = credit.count, .last = credit.last };
            self.drop(key);
            if (self.visits.getPtr(door)) |e| try self.merge(&e.visit, moved) else _ = try self.put(moved);
        }
    }

    /// Coalesced: a busy minute of browsing writes the file once, not
    /// thirty times, and never on the main thread.
    fn save(self: *History) void {
        if (self.saving != null) return;
        const p = std.heap.c_allocator.create(Pending) catch return self.write(false);
        p.* = .{ .history = self };
        self.saving = p;
        objc.dispatchAfter(1_500 * std.time.ns_per_ms, p, fire);
    }

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Pending = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(p);
        if (p.history) |h| h.write(false);
    }

    /// A visit still waiting out `save`'s moment, written now: for the way out.
    pub fn flush(self: *History) void {
        if (self.saving != null) self.write(true);
    }

    fn write(self: *History, now: bool) void {
        if (self.saving) |p| p.history = null;
        self.saving = null;
        // A cap, so the file can't grow without end: what goes is what has
        // been visited least and longest ago.
        const t = json.now();
        const list = self.best(self.gpa, t) catch return;
        defer self.gpa.free(list);
        self.store.save(file_name, list, now);
        if (self.visits.count() > cap + 128 and list.len == cap) {
            const cutoff = score(list[cap - 1], t);
            var i = self.visits.count();
            while (i > 0 and self.visits.count() > cap) {
                i -= 1;
                if (score(self.visits.values()[i].visit, t) < cutoff) self.drop(self.visits.keys()[i]);
            }
        }
    }

    /// Up to `cap` visits, best score first; on `alloc`, strings borrowed.
    fn best(self: *History, alloc: std.mem.Allocator, now: json.SwiftDate) ![]Visit {
        const list = try alloc.alloc(Visit, self.visits.count());
        for (self.visits.values(), list) |e, *v| v.* = e.visit;
        std.mem.sort(Visit, list, now, struct {
            fn gt(t: json.SwiftDate, a: Visit, b: Visit) bool {
                return score(a, t) > score(b, t);
            }
        }.gt);
        if (list.len <= cap) return list;
        return alloc.realloc(list, cap);
    }
};


test "take and record handle aliased entry slices without use-after-free" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer {
        store.disk.drain();
        store.deinit();
    }
    // Seed a legacy unindexed history file where ensureIndexed() -> rehomeCredits()
    // drops the bare-origin credit and merges into the www front door.
    const seed_json =
        \\[{"url":"https://news.site/","key":"https://news.site/","title":"","count":2,"last":780000000},
        \\ {"url":"https://www.news.site/story","key":"https://www.news.site/story","title":"Old Title","count":3,"last":781000000}]
    ;
    store.write(file_name, try gpa.dupe(u8, seed_json), true);
    var h: History = undefined;
    h.init(gpa, &store);
    defer h.deinit();
    try std.testing.expect(!h.indexed);
    const now = json.now();
    // Borrow slices directly from the unindexed entries before take() runs ensureIndexed() / replace().
    const credit = h.visits.get("https://news.site/").?.visit;
    h.take(credit.url, credit.title, 4, now);
    const rehomed = h.visits.get("https://news.site/") orelse return error.MissingCreditAfterTake;
    try std.testing.expectEqual(@as(i64, 4), rehomed.visit.count);
    try std.testing.expectEqualStrings("https://news.site/", rehomed.visit.url);
    const story = h.visits.get("https://www.news.site/story").?.visit;
    h.record(story.url, story.title);
    const after = h.visits.get("https://www.news.site/story").?.visit;
    try std.testing.expectEqualStrings("Old Title", after.title);
    try std.testing.expectEqual(@as(i64, 4), after.count);
}
test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(History);
    std.testing.refAllDecls(@import("history_read.zig"));
    std.testing.refAllDecls(text_mod);
    _ = @import("history_text.zig");
    _ = @import("history_read.zig");
    _ = @import("history_tests.zig");
}
