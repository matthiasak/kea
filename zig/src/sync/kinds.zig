//! What each kind holds, read from this Mac and put back from another's
//! (`Kind`, `bools`, `portable`, `records`, `apply`, `removeRecord`,
//! `applyHistory` in Sync.swift). Main thread only.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const core = @import("core.zig");
const Sync = @import("sync.zig").Sync;
const prefs_mod = @import("../data/prefs.zig");
const Bookmark = @import("../data/bookmarks.zig").Bookmark;
const bookmarks_merge = @import("../data/bookmarks_merge.zig");
const spaces = @import("../data/spaces.zig");
const pins_mod = @import("../data/pins.zig");
const Visit = @import("../data/history.zig").Visit;
const Chats = @import("../data/chats_store.zig").Chats;
const browsers = @import("../app/browsers.zig");
const Parts = @import("../data/url.zig").Parts;

const SwiftDate = json.SwiftDate;
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    bookmarks,
    places,
    settings,
    chats,
    history,
    tabs,

    pub fn title(self: Kind) []const u8 {
        return switch (self) {
            .bookmarks => "Bookmarks",
            .places => "Pins and spaces",
            .settings => "Settings",
            .chats => "Ubi Chat chats",
            .history => "History",
            .tabs => "Open tabs",
        };
    }
};

/// The kinds kept as records weighed one by one (`recordKinds`).
pub const record_kinds = [_]Kind{ .bookmarks, .places, .settings, .chats };

/// Settings that are switches (`Sync.bools`'s keys), sorted.
pub const bools = [_][]const u8{
    "ai",            "autoscroll",       "bookmarks.bar",  "bookmarks.sidebar", "commandbar",
    "downloads.ask", "downloads.button", "float.away",     "float.flicks",      "float.leave",
    "handoff",       "kea.facts",        "links.little",   "links.peek",        "links.show",
    "media.click",   "passwords.fill",   "passwords.save", "pins.list",         "search.sites",
    "shield",        "sidebar",          "sidebar.hides",  "spaces",            "splitView",
    "swipe.history", "tabs.groups",      "tabs.lazy",      "tabs.reading",      "tabs.sleep",
    "toolbar.left",
};

/// Every setting that goes to your other Macs (`Sync.portable`), besides
/// each site's `zoom.<host>`. Anything else never syncs: widths, panels'
/// places, welcomed, downloads folder, passwords and passkeys, sync's own.
pub const portable = bools ++ [_][]const u8{
    "look",            "sidebar.position", "glyph",       "search.engine", "search.custom",
    "search.keywords", "pageZoom",         "ai.provider", "ai.models",     "shortcuts",
};

pub const SyncTab = struct { url: []const u8, title: []const u8 };
pub const TabsDoc = struct { name: []const u8, at: SwiftDate, windows: []const []const SyncTab };
pub const HistoryDoc = struct { visits: []const Visit, cleared: ?SwiftDate = null, forgot: json.Map(SwiftDate) = .{} };
pub const SentTab = struct { url: []const u8, title: []const u8, from: []const u8, at: SwiftDate };

/// http or https: what another Mac can open.
pub fn webAddress(url: []const u8) bool {
    const p = Parts.parse(url) orelse return false;
    const s = p.scheme orelse return false;
    return std.ascii.eqlIgnoreCase(s, "http") or std.ascii.eqlIgnoreCase(s, "https");
}

// MARK: this Mac's records

pub fn records(s: *Sync, kind: Kind, a: Allocator) !core.Records {
    const kea = s.kea;
    var out: core.Records = .empty;
    switch (kind) {
        // ponytail: the bookmark tree is one record; per-node merge if edits on two Macs within 30 s get lost
        .bookmarks => try out.put(a, "tree", try json.encodeSorted(a, kea.bookmarks.roots)),
        .places => {
            const list = try a.dupe(spaces.Space, kea.spaces.value);
            for (list) |*sp| sp.downloads = null;
            try out.put(a, "spaces", try json.encodeSorted(a, list));
            kea.pins.load();
            var map: json.Map([]const pins_mod.PinDef) = .{};
            var it = kea.pins.by_space.iterator();
            while (it.next()) |e| try map.map.put(a, try a.dupe(u8, &e.key_ptr.string()), try json.clone(a, e.value_ptr.defs));
            try out.put(a, "pins", try json.encodeSorted(a, map));
        },
        .settings => try settingsRecords(s, a, &out),
        .chats => if (s.chats) |c| {
            kea.store.disk.drain();
            for (c.index) |entry| {
                var buf: [64]u8 = undefined;
                const bytes = kea.store.readFile(Chats.fileName(&buf, entry.id)) orelse continue;
                defer kea.gpa.free(bytes);
                try out.put(a, try a.dupe(u8, &entry.id.string()), try a.dupe(u8, bytes));
            }
        },
        .history, .tabs => {},
    }
    return out;
}

/// `["v": value]` as a binary property list, per portable key that is set.
fn settingsRecords(s: *Sync, a: Allocator, out: *core.Records) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const d = s.kea.store.defaults;
    var keys: std.ArrayList([]const u8) = .empty;
    try keys.appendSlice(a, &portable);
    var zooms: std.ArrayList([]const u8) = .empty;
    const all = objc.msg(objc.Object, objc.msg(objc.Object, d, "dictionaryRepresentation", .{}), "allKeys", .{});
    const n = objc.msg(objc.NSUInteger, all, "count", .{});
    for (0..n) |i| {
        const k = objc.fromNSString(objc.msg(objc.Object, all, "objectAtIndex:", .{@as(objc.NSUInteger, i)}));
        if (std.mem.startsWith(u8, k, "zoom.")) try zooms.append(a, try a.dupe(u8, k));
    }
    std.mem.sort([]const u8, zooms.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try keys.appendSlice(a, zooms.items);
    for (keys.items) |k| {
        const v = objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString(k)}) orelse continue;
        const dict = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ v, objc.nsString("v") });
        // NSPropertyListBinaryFormat_v1_0
        const data = objc.msg(?objc.Object, objc.class("NSPropertyListSerialization"), "dataWithPropertyList:format:options:error:", .{
            dict, @as(objc.NSUInteger, 200), @as(objc.NSUInteger, 0), @as(?*anyopaque, null),
        }) orelse continue;
        try out.put(a, k, try copyData(a, data));
    }
}

fn copyData(a: Allocator, d: objc.Object) ![]u8 {
    const len = objc.msg(objc.NSUInteger, d, "length", .{});
    const out = try a.alloc(u8, len);
    if (len > 0) objc.msg(void, d, "getBytes:length:", .{ out.ptr, len });
    return out;
}

// MARK: another Mac's, put in place

pub fn apply(s: *Sync, kind: Kind, key: []const u8, data: []const u8, joining: bool, a: Allocator) !void {
    const kea = s.kea;
    switch (kind) {
        .bookmarks => {
            if (!std.mem.eql(u8, key, "tree")) return;
            const remote = json.decode([]Bookmark, a, data) catch return;
            kea.bookmarks.replace(if (joining) try bookmarks_merge.@"union"(a, remote.value, kea.bookmarks.roots) else remote.value);
        },
        .places => if (std.mem.eql(u8, key, "spaces")) {
            const remote = json.decode([]spaces.Space, a, data) catch return;
            var list: std.ArrayList(spaces.Space) = .empty;
            try list.appendSlice(a, remote.value);
            const local = kea.spaces.value;
            if (joining) for (local) |l| {
                for (remote.value) |r| {
                    if (r.id.eql(l.id)) break;
                } else try list.append(a, l);
            };
            for (list.items) |*sp| {
                sp.downloads = null;
                for (local) |l| if (l.id.eql(sp.id)) {
                    sp.downloads = l.downloads;
                };
            }
            spaces.write(kea, list.items);
        } else if (std.mem.eql(u8, key, "pins")) {
            const Entry = std.meta.Child(@typeInfo(@TypeOf(pins_mod.Pins.replaceAll)).@"fn".param_types[1].?);
            const raw = json.decode(json.Map([]pins_mod.PinDef), a, data) catch return;
            var map: std.ArrayList(Entry) = .empty;
            var it = raw.value.map.iterator();
            while (it.next()) |e| try map.append(a, .{ .space = json.Uuid.parse(e.key_ptr.*) catch continue, .defs = e.value_ptr.* });
            if (joining) {
                kea.pins.load();
                var mine = kea.pins.by_space.iterator();
                while (mine.next()) |e| {
                    // Copied: `replaceAll` lets go of what is here now.
                    const local = try json.clone(a, e.value_ptr.defs);
                    var at: ?usize = null;
                    for (map.items, 0..) |m, i| if (m.space.eql(e.key_ptr.*)) {
                        at = i;
                    };
                    var combined: std.ArrayList(pins_mod.PinDef) = .empty;
                    if (at) |i| try combined.appendSlice(a, map.items[i].defs);
                    const remote_count = combined.items.len;
                    for (local) |l| {
                        for (combined.items[0..remote_count]) |r| {
                            if (std.mem.eql(u8, r.home, l.home)) break;
                        } else try combined.append(a, l);
                    }
                    if (combined.items.len == 0) continue;
                    if (at) |i| map.items[i].defs = combined.items else try map.append(a, .{ .space = e.key_ptr.*, .defs = combined.items });
                }
            }
            kea.pins.replaceAll(map.items);
            for (kea.browsers.items) |b| b.pinsChanged(b.space_id);
        },
        .settings => applySetting(s, key, data),
        .chats => if (s.chats) |c| {
            const chat = json.decode(@import("../data/chats_store.zig").Chat, a, data) catch return;
            c.put(chat.value);
        },
        .history, .tabs => {},
    }
}

fn isKind(v: objc.Object, comptime class: [:0]const u8) bool {
    return objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class(class)});
}

fn str(v: objc.Object) ?[]const u8 {
    return if (isKind(v, "NSString")) objc.fromNSString(v) else null;
}

fn setEnum(p: *prefs_mod.Prefs, comptime field: []const u8, v: objc.Object) void {
    const raw = str(v) orelse return;
    if (std.meta.stringToEnum(@FieldType(prefs_mod.Prefs, field), raw)) |e| p.set(field, e);
}

fn applySetting(s: *Sync, key: []const u8, data: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const kea = s.kea;
    const p = &kea.prefs;
    const nsdata = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ data.ptr, @as(objc.NSUInteger, data.len) });
    const plist = objc.msg(?objc.Object, objc.class("NSPropertyListSerialization"), "propertyListWithData:options:format:error:", .{
        nsdata, @as(objc.NSUInteger, 0), @as(?*anyopaque, null), @as(?*anyopaque, null),
    }) orelse return;
    if (!isKind(plist, "NSDictionary")) return;
    const v = objc.msg(?objc.Object, plist, "objectForKey:", .{objc.nsString("v")}) orelse return;

    for (bools) |b| if (std.mem.eql(u8, b, key)) {
        if (!isKind(v, "NSNumber")) return;
        const on = objc.msg(objc.BOOL, v, "boolValue", .{});
        inline for (@typeInfo(@TypeOf(prefs_mod.keys)).@"struct".field_names) |f| {
            if (@FieldType(prefs_mod.Prefs, f) == bool and std.mem.eql(u8, @field(prefs_mod.keys, f), key)) return p.set(f, on);
        }
        return;
    };
    if (std.mem.eql(u8, key, "look")) {
        setEnum(p, "look", v);
    } else if (std.mem.eql(u8, key, "sidebar.position")) {
        setEnum(p, "side_position", v);
    } else if (std.mem.eql(u8, key, "glyph")) {
        setEnum(p, "glyph", v);
    } else if (std.mem.eql(u8, key, "search.engine")) {
        setEnum(p, "engine", v);
    } else if (std.mem.eql(u8, key, "search.custom")) {
        if (str(v)) |t| p.set("custom_engine", t);
    } else if (std.mem.eql(u8, key, "search.keywords")) {
        if (!isKind(v, "NSData")) return;
        var arena: std.heap.ArenaAllocator = .init(kea.gpa);
        defer arena.deinit();
        const bytes = copyData(arena.allocator(), v) catch return;
        const list = json.decode([]prefs_mod.Keyword, arena.allocator(), bytes) catch return;
        p.setKeywords(list.value);
    } else if (std.mem.eql(u8, key, "pageZoom")) {
        if (isKind(v, "NSNumber")) p.set("page_zoom", objc.msg(f64, v, "doubleValue", .{}));
    } else if (std.mem.eql(u8, key, "ai.provider")) {
        // ponytail: any id is taken; check against `AIProvider.named` once ai/ has it.
        if (str(v)) |t| p.set("ai_provider", t);
    } else if (std.mem.eql(u8, key, "ai.models")) {
        if (!isKind(v, "NSDictionary")) return;
        const ids = objc.msg(objc.Object, v, "allKeys", .{});
        for (0..objc.msg(objc.NSUInteger, ids, "count", .{})) |i| {
            const id = objc.msg(objc.Object, ids, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
            const model = objc.msg(objc.Object, v, "objectForKey:", .{id});
            if (str(id)) |pid| if (str(model)) |m| p.setAIModel(m, pid);
        }
    } else if (std.mem.eql(u8, key, "shortcuts")) {
        if (!isKind(v, "NSData")) return;
        objc.msg(void, kea.store.defaults, "setObject:forKey:", .{ v, objc.nsString("shortcuts") });
        if (s.shortcuts_changed) |f| f(kea);
    } else if (std.mem.startsWith(u8, key, "zoom.")) {
        objc.msg(void, kea.store.defaults, "setObject:forKey:", .{ v, objc.nsString(key) });
    }
}

pub fn removeRecord(s: *Sync, kind: Kind, key: []const u8) void {
    switch (kind) {
        .settings => if (std.mem.startsWith(u8, key, "zoom.")) s.kea.store.remove(key),
        .chats => if (s.chats) |c| if (json.Uuid.parse(key)) |id| c.remove(id) else |_| {},
        .bookmarks, .places, .history, .tabs => {},
    }
}

/// Another Mac's clearing and forgetting, then its visits from after them.
pub fn applyHistory(s: *Sync, doc: HistoryDoc, a: Allocator) !void {
    s.applying = true;
    defer s.applying = false;
    const h = &s.kea.history;
    const st = &s.state.value;
    const sa = s.state.arena.allocator();
    if (doc.cleared) |c| if (c > (st.cleared orelse core.distant_past)) {
        h.forgetBefore(c);
        st.cleared = c;
    };
    var it = doc.forgot.map.iterator();
    while (it.next()) |e| if (e.value_ptr.* > (st.forgot.map.get(e.key_ptr.*) orelse core.distant_past)) {
        h.forgetKeyBefore(e.key_ptr.*, e.value_ptr.*);
        try core.putKey(sa, &st.forgot.map, e.key_ptr.*, e.value_ptr.*);
    };
    const cleared = st.cleared orelse core.distant_past;
    var allowed: std.ArrayList(Visit) = .empty;
    for (doc.visits) |v| if (v.last > cleared and v.last > (st.forgot.map.get(v.key) orelse core.distant_past)) try allowed.append(a, v);
    h.absorb(allowed.items);
}

/// This Mac's open pages, window by window, private and blank ones left out.
pub fn windows(s: *Sync, a: Allocator) ![]const []const SyncTab {
    var out: std.ArrayList([]const SyncTab) = .empty;
    for (s.kea.browsers.items) |b| {
        var list: std.ArrayList(SyncTab) = .empty;
        for (b.tabs.items) |t| {
            if (t.shy or t.isBlank() or !webAddress(t.url())) continue;
            try list.append(a, .{ .url = try a.dupe(u8, t.url()), .title = try a.dupe(u8, t.page_title) });
        }
        if (list.items.len > 0) try out.append(a, list.items);
    }
    return out.items;
}

/// A page sent from another Mac, opened behind at the end of a window.
pub fn openSent(s: *Sync, sent: SentTab) void {
    if (!webAddress(sent.url)) return;
    const b = browsers.ensureWindow(s.kea) orelse return;
    _ = b.open(sent.url, .{ .foreground = false, .at_end = true });
    const host = if (Parts.parse(sent.url)) |p| p.host orelse sent.url else sent.url;
    const label = if (sent.title.len == 0) host else sent.title;
    const line = std.fmt.allocPrint(s.gpa, "From {s}: {s}", .{ sent.from, label }) catch return b.announce(label);
    defer s.gpa.free(line);
    b.announce(line);
}
