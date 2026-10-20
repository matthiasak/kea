//! chrome.history, chrome.topSites, chrome.sessions and chrome.readingList
//! from Kea's own (ExtensionShims.swift 3497-3537, 3989-4022, `visit` 4345).
const std = @import("std");
const ans = @import("answer.zig");
const json = @import("../../data/json.zig");
const history_mod = @import("../../data/history.zig");
const Parts = @import("../../data/url.zig").Parts;
pub const Trace = history_mod.Trace;
const Call = ans.Call;

/// A history item as Chrome describes one.
pub const Item = struct {
    id: []const u8,
    url: []const u8,
    title: []const u8,
    lastVisitTime: f64,
    visitCount: i64,
    typedCount: i64 = 0,
};

/// A Swift date as JS milliseconds since 1970.
fn ms(d: json.SwiftDate) f64 {
    return json.toUnix(d) * 1000;
}

/// JS milliseconds as a Swift date.
fn date(milliseconds: f64) json.SwiftDate {
    return json.fromUnix(milliseconds / 1000);
}

pub fn visit(t: Trace) Item {
    return .{ .id = t.key, .url = t.url, .title = t.title, .lastVisitTime = ms(t.last), .visitCount = t.count };
}

fn everything(c: *Call, typed: []const u8) ![]Trace {
    return c.browser.history.everything(c.a, typed, std.math.maxInt(usize));
}

/// Each trace's key, copied: forgetting one frees the history's strings.
fn forgetWhere(c: *Call, comptime keep: anytype, ctx: anytype) !void {
    var keys: std.ArrayList([]const u8) = .empty;
    for (try everything(c, "")) |t| if (!keep(t, ctx)) try keys.append(c.a, try c.a.dupe(u8, t.key));
    // Other Macs forget them too (`Sync.historyForgot`), while each key lives.
    for (keys.items) |k| {
        c.browser.kea.sync.historyForgot(k);
        c.browser.history.forget(k);
    }
}

fn unixNow() i64 {
    return @intFromFloat(json.toUnix(json.now()));
}

pub fn run(c: *Call) ans.Error!?ans.Out {
    const eql = std.mem.eql;
    const api = c.api;
    const a = c.a;
    const first = c.first();
    const history = c.browser.history;

    if (eql(u8, api, "history.search")) {
        const text = ans.str(ans.field(first, "text")) orelse "";
        const start = if (ans.num(ans.field(first, "startTime"))) |t| date(t) else json.now() - 24 * 3600;
        const end = if (ans.num(ans.field(first, "endTime"))) |t| date(t) else std.math.inf(f64);
        const limit: usize = @intCast(@max(ans.int(ans.field(first, "maxResults")) orelse 100, 0));
        // `everything` is newest first already.
        var out: std.ArrayList(Item) = .empty;
        for (try everything(c, text)) |t| {
            if (out.items.len == limit) break;
            if (t.last >= start and t.last <= end) try out.append(a, visit(t));
        }
        return c.give(out.items);
    } else if (eql(u8, api, "history.getVisits")) {
        const want = ans.str(ans.field(first, "url")) orelse "";
        const Visit = struct { id: []const u8, visitId: []const u8 = "1", visitTime: f64, referringVisitId: []const u8 = "0", transition: []const u8 = "link" };
        var out: std.ArrayList(Visit) = .empty;
        for (try everything(c, "")) |t| if (eql(u8, t.url, want)) try out.append(a, .{ .id = t.key, .visitTime = ms(t.last) });
        return c.give(out.items);
    } else if (eql(u8, api, "history.addUrl")) {
        if (ans.str(ans.field(first, "url"))) |u| if (Parts.parse(u) != null) history.record(u, "");
        return ans.none;
    } else if (eql(u8, api, "history.deleteUrl")) {
        const want = ans.str(ans.field(first, "url")) orelse "";
        try forgetWhere(c, struct {
            fn keep(t: Trace, w: []const u8) bool {
                return !std.mem.eql(u8, t.url, w);
            }
        }.keep, want);
        return ans.none;
    } else if (eql(u8, api, "history.deleteRange")) {
        const range = [2]f64{ date(ans.num(ans.field(first, "startTime")) orelse 0), date(ans.num(ans.field(first, "endTime")) orelse 0) };
        try forgetWhere(c, struct {
            fn keep(t: Trace, r: [2]f64) bool {
                return !(t.last >= r[0] and t.last <= r[1]);
            }
        }.keep, range);
        return ans.none;
    } else if (eql(u8, api, "history.deleteAll")) {
        c.browser.kea.sync.historyCleared();
        history.forgetAll();
        return ans.none;
    }

    // MARK: sessions — the tabs you closed
    else if (eql(u8, api, "sessions.getRecentlyClosed")) {
        const limit: usize = @intCast(@max(ans.int(ans.field(first, "maxResults")) orelse 25, 0));
        const Closed = struct {
            sessionId: []const u8,
            url: []const u8,
            title: []const u8,
            index: usize,
            windowId: i64 = 1,
            active: bool = false,
            pinned: bool = false,
            highlighted: bool = false,
            incognito: bool = false,
            selected: bool = false,
            discarded: bool = false,
            autoDiscardable: bool = true,
            groupId: i64 = -1,
        };
        const Session = struct { lastModified: i64, tab: Closed };
        const ghosts = c.browser.ghosts.items;
        var out: std.ArrayList(Session) = .empty;
        var i = ghosts.len;
        while (i > 0 and out.items.len < limit) {
            i -= 1;
            const g = ghosts[i];
            try out.append(a, .{ .lastModified = unixNow(), .tab = .{ .sessionId = try a.dupe(u8, &g.id.string()), .url = g.url, .title = g.title, .index = g.index } });
        }
        return c.give(out.items);
    } else if (eql(u8, api, "sessions.getDevices")) {
        return c.give(no_items);
    } else if (eql(u8, api, "sessions.restore")) {
        const ghosts = c.browser.ghosts.items;
        const at: ?usize = if (ans.str(first)) |key| for (ghosts, 0..) |g, i| {
            if (eql(u8, &g.id.string(), key)) break i;
        } else null else null;
        const which = at orelse (if (ghosts.len > 0) ghosts.len - 1 else return c.fail("Nothing to restore", .{}));
        const g = ghosts[which];
        // Copied before it comes back: reopening frees the ghost.
        const Back = struct { url: []const u8, title: []const u8, index: usize, windowId: i64 = 1 };
        const out = try c.of(.{ .lastModified = unixNow(), .tab = Back{ .url = g.url, .title = g.title, .index = g.index } });
        c.browser.reopenGhost(which);
        return .{ .value = out };
    }

    // MARK: top sites — the most visited in history
    else if (eql(u8, api, "topSites.get")) {
        const Site = struct { url: []const u8, title: []const u8, count: usize = 0 };
        var visits: std.StringArrayHashMapUnmanaged(Site) = .empty;
        for (try everything(c, "")) |t| {
            const host = (Parts.parse(t.url) orelse continue).hostName() orelse continue;
            const gop = try visits.getOrPut(a, host);
            if (!gop.found_existing) gop.value_ptr.* = .{ .url = t.url, .title = t.title };
            gop.value_ptr.count += 1;
        }
        const sites = visits.values();
        std.mem.sort(Site, sites, {}, struct {
            fn more(_: void, x: Site, y: Site) bool {
                return x.count > y.count;
            }
        }.more);
        const Top = struct { url: []const u8, title: []const u8 };
        const out = try a.alloc(Top, @min(sites.len, 10));
        for (out, sites[0..out.len]) |*o, s| o.* = .{ .url = s.url, .title = s.title };
        return c.give(out);
    }

    // MARK: reading list — none kept
    else if (eql(u8, api, "readingList.query")) {
        return c.give(no_items);
    } else if (eql(u8, api, "readingList.addEntry") or eql(u8, api, "readingList.removeEntry") or eql(u8, api, "readingList.updateEntry")) {
        return c.fail(ans.app_name ++ " has no reading list", .{});
    }
    return null;
}

const no_items: []const Item = &.{};
