//! Browser.swift "this window's rows, wherever they are kept" (2203-2329),
//! the session written from them (`writeSession`, `rememberSession`), and
//! bringing a row back (`restoreSession`, `loadRow`, `restoreRow`,
//! `showRow`, 1648-1693 and 3560-3620). A row comes back asleep: only the
//! tab in front builds its page, and restoring writes and visits nothing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const json = @import("../data/json.zig");
const Uuid = json.Uuid;
const session_file = @import("../data/session.zig");
const Shape = session_file.Shape;
const browsers = @import("../app/browsers.zig");
const groups_ops = @import("groups.zig");
const TabGroup = groups_ops.TabGroup;
const Parked = @import("spaces.zig").Parked;
const split_ops = @import("split.zig");
const TabSplit = split_ops.TabSplit;

// MARK: where rows are kept

/// A space's row as saved: the session files' for the oldest window, this
/// window's own record for any other. The caller deinits it.
pub fn readRow(self: *Browser, space: Uuid) std.json.Parsed(Shape) {
    if (self.uses_files) return session_file.read(self.store, space);
    const key = space.string();
    if (self.record_rows.get(&key)) |bytes| if (json.decode(Shape, self.gpa, bytes)) |p| return p else |_| {};
    return json.decode(Shape, self.gpa, "{\"tabs\":[],\"active\":0}") catch @panic("OOM");
}

pub fn writeRow(self: *Browser, space: Uuid, shape: Shape, now: bool) void {
    if (self.uses_files) return session_file.write(self.store, space, shape, now);
    const bytes = json.encode(self.gpa, shape) catch return;
    const key = space.string();
    const gop = self.record_rows.getOrPut(self.gpa, &key) catch return self.gpa.free(bytes);
    if (gop.found_existing) self.gpa.free(gop.value_ptr.*) else gop.key_ptr.* = self.gpa.dupe(u8, &key) catch {
        self.record_rows.swapRemoveAt(gop.index);
        return self.gpa.free(bytes);
    };
    gop.value_ptr.* = bytes;
    if (now) browsers.save(self.kea, true) else browsers.saveSoon(self.kea);
}

/// Every row this window has, by space: the one on screen, the parked
/// ones, and those saved but not brought up this time. On `arena`.
pub fn allRows(self: *Browser, arena: std.mem.Allocator) !json.Map(Shape) {
    var rows: json.Map(Shape) = .{};
    for (self.kea.spaces.value) |sp| {
        const saved = self.readRow(sp.id);
        defer saved.deinit();
        if (saved.value.tabs.len == 0) continue;
        const key = sp.id.string();
        try rows.map.put(arena, try arena.dupe(u8, &key), try intoArena(arena, saved.value));
    }
    const here = self.space_id.string();
    const live = try self.session(arena, self.tabs.items, self.active_id, try groupsForSession(arena, self.tab_groups.items), self.splits.items);
    try rows.map.put(arena, try arena.dupe(u8, &here), live);
    for (self.parked.keys(), self.parked.values()) |id, *row| {
        const key = id.string();
        try rows.map.put(arena, try arena.dupe(u8, &key), try parkedShape(self, arena, id, row));
    }
    return rows;
}

/// A deep copy on `arena`.
fn intoArena(arena: std.mem.Allocator, value: Shape) !Shape {
    const bytes = try json.encode(arena, value);
    return std.json.parseFromSliceLeaky(Shape, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// The oldest window closed: this one is the oldest now, and its rows go
/// into the session files, every space's — an empty row where it has none.
pub fn becomePrimary(self: *Browser) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const rows = self.allRows(arena.allocator()) catch return;
    self.uses_files = true;
    for (self.kea.spaces.value) |sp| {
        const key = sp.id.string();
        session_file.write(self.store, sp.id, rows.map.get(&key) orelse .{ .tabs = &.{}, .active = 0 }, true);
    }
    for (self.record_rows.keys(), self.record_rows.values()) |k, v| {
        self.gpa.free(k);
        self.gpa.free(v);
    }
    self.record_rows.clearRetainingCapacity();
    self.store.setString("space.current", &self.space_id.string());
}

// MARK: the session

/// Whether a tab goes into the session: not a private one, and only with
/// a web address.
fn kept(t: *const Tab) bool {
    return !t.shy and std.mem.startsWith(u8, t.url(), "http");
}

pub fn groupsForSession(arena: std.mem.Allocator, list: []const TabGroup) ![]session_file.TabGroup {
    const out = try arena.alloc(session_file.TabGroup, list.len);
    for (list, out) |g, *o| o.* = .{ .id = g.id, .name = g.name, .collapsed = g.collapsed };
    return out;
}

/// A row as `Session.Shape`, on `arena`, its strings the tabs'. `active`
/// is the one in front or, when that one isn't kept, the kept one just
/// before it; only groups with a kept tab, and only pairs whole in the file.
pub fn session(self: *Browser, arena: std.mem.Allocator, tabs: []const *Tab, active: u64, groups: ?[]const session_file.TabGroup, splits: []const TabSplit) !Shape {
    _ = self;
    var entries: std.ArrayList(session_file.Entry) = .empty;
    var indices: std.AutoHashMapUnmanaged(u64, i64) = .empty;
    var front: i64 = 0;
    for (tabs) |t| {
        if (!kept(t)) continue;
        if (t.id == active) front = @intCast(entries.items.len);
        try indices.put(arena, t.id, @intCast(entries.items.len));
        const pinned = t.pin != null;
        try entries.append(arena, .{
            .url = t.url(),
            .title = t.title(),
            .pin = t.pin,
            .name = t.name,
            .home = if (pinned) t.home else null,
            .groupID = t.group_id,
            .pinID = if (pinned) t.pin_id else null,
            .listed = if (pinned and t.listed) true else null,
        });
    }
    if (active != 0 and !indices.contains(active)) for (tabs, 0..) |t, at| if (t.id == active) {
        var before: i64 = 0;
        for (tabs[0..at]) |b| before += @intFromBool(kept(b));
        front = @max(0, before - 1);
        break;
    };
    var kept_groups: ?[]session_file.TabGroup = null;
    if (groups) |list| {
        var out: std.ArrayList(session_file.TabGroup) = .empty;
        for (list) |g| for (entries.items) |e| if (e.groupID != null and e.groupID.?.eql(g.id)) {
            try out.append(arena, g);
            break;
        };
        kept_groups = out.items;
    }
    // Only a pair whole in the file: one with an empty page, or a private
    // one, isn't written, and its other page comes back alone.
    var saved: std.ArrayList(session_file.Split) = .empty;
    for (splits) |p| if (indices.get(p.left())) |l| if (indices.get(p.right())) |r| if (r == l + 1) {
        try saved.append(arena, .{
            .tabs = try arena.dupe(i64, &.{ l, r }),
            .axis = p.axis,
            .sizes = try arena.dupe(f64, &p.sizes),
            .focused = if (p.focused) |f| indices.get(f) else null,
        });
    };
    return .{ .tabs = entries.items, .active = front, .groups = kept_groups, .splits = saved.items };
}

/// Written for the next launch: the pins as they are here, for the other
/// windows, then the row. Nothing while restoring.
pub fn writeSession(self: *Browser, now: bool) void {
    if (self.restoring) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const mine = @import("pins.zig").pinDefs(self, a, self.tabs.items) catch return;
    if (self.kea.pins.set(self.space_id, mine)) self.kea.pinsChanged(self, self.space_id);
    const shape = self.session(a, self.tabs.items, self.active_id, groupsForSession(a, self.tab_groups.items) catch return, self.splits.items) catch return;
    self.writeRow(self.space_id, shape, now);
}

/// Another space's row. Its groups are the ones in its own file, the only
/// place a space off screen keeps them, when the row doesn't hold them.
pub fn writeParked(self: *Browser, now: bool, space: Uuid, row: *const Parked) void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const shape = parkedShape(self, arena.allocator(), space, row) catch return;
    self.writeRow(space, shape, now);
}

fn parkedShape(self: *Browser, arena: std.mem.Allocator, space: Uuid, row: *const Parked) !Shape {
    const groups: ?[]const session_file.TabGroup = if (row.groups) |g| try groupsForSession(arena, g.items) else blk: {
        const saved = self.readRow(space);
        defer saved.deinit();
        break :blk if (saved.value.groups) |g| (try intoArena(arena, .{ .tabs = &.{}, .active = 0, .groups = g })).groups else null;
    };
    return self.session(arena, row.tabs.items, row.active, groups, row.splits.items);
}

/// `rememberSession`: written a moment from now, once for many changes.
pub fn rememberSession(self: *Browser) void {
    if (self.remembering != null or self.restoring) return;
    // ponytail: c_allocator, so a tick that fires after its browser has gone frees itself.
    const t = std.heap.c_allocator.create(Tick) catch return;
    t.* = .{ .browser = self };
    self.remembering = t;
    objc.dispatchAfter(1200 * std.time.ns_per_ms, t, Tick.fire);
}

pub const Tick = struct {
    browser: ?*Browser,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const t: *Tick = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(t);
        const b = t.browser orelse return;
        b.remembering = null;
        b.writeSession(false);
    }
};

/// Quitting: written now, on this thread.
pub fn flushSession(self: *Browser) void {
    self.writeSession(true);
}

// MARK: bringing a row back

/// The row the space on screen had last time, or one empty tab; the pins
/// are every window's, so a window new to this space has them too.
pub fn restoreSession(self: *Browser) void {
    self.restoring = true;
    defer self.restoring = false;
    const saved = self.readRow(self.space_id);
    defer saved.deinit();
    groups_ops.freeGroups(self.gpa, &self.tab_groups);
    if (saved.value.groups) |list| for (list) |g| for (saved.value.tabs) |e| if (e.groupID != null and e.groupID.?.eql(g.id)) {
        self.tab_groups.append(self.gpa, groups_ops.owned(self.gpa, g.id, g.name, g.collapsed)) catch @panic("OOM");
        break;
    };
    var restored = restoreRow(self, saved.value, self.space_id, self.tab_groups.items);
    self.tabs.appendSlice(self.gpa, restored.tabs.items) catch @panic("OOM");
    restored.tabs.deinit(self.gpa);
    self.splits.deinit(self.gpa);
    self.splits = restored.splits;
    self.arrangeGroupedTabs(null);
    // No tab in front (a fresh start): an empty one beside the pins.
    var front: ?*Tab = null;
    if (saved.value.tabs.len > 0 and saved.value.active >= 0) {
        front = self.tabById(restored.active);
        if (front == null) for (self.tabs.items) |t| if (t.pin == null) {
            front = t;
            break;
        };
        if (front == null and self.tabs.items.len > 0) front = self.tabs.items[0];
    }
    const first = front orelse {
        const t = self.make("", false);
        self.adopt(t);
        self.active_id = t.id;
        return;
    };
    self.active_id = first.id;
    // Only the ones you were looking at actually load.
    for (self.visibleTabIDs()) |id| if (self.tabById(id)) |t| {
        _ = t.wake();
    };
}

/// A space's row as its session left it, made without touching the one
/// on screen: tabs with an address and no page yet.
pub fn loadRow(self: *Browser, space: Uuid) Parked {
    const saved = self.readRow(space);
    defer saved.deinit();
    const list: []const session_file.TabGroup = saved.value.groups orelse &.{};
    var restored = restoreRow(self, saved.value, space, list);
    if (restored.active == 0 and restored.tabs.items.len > 0) restored.active = restored.tabs.items[0].id;
    if (saved.value.groups) |g| {
        var owned: std.ArrayList(TabGroup) = .empty;
        for (g) |x| owned.append(self.gpa, groups_ops.owned(self.gpa, x.id, x.name, x.collapsed)) catch @panic("OOM");
        restored.groups = owned;
    }
    return restored;
}

fn restoreRow(self: *Browser, saved: Shape, space: Uuid, groups: anytype) Parked {
    var row: std.ArrayList(*Tab) = .empty;
    const by_saved = self.gpa.alloc(?*Tab, saved.tabs.len) catch @panic("OOM");
    defer self.gpa.free(by_saved);
    for (saved.tabs, by_saved) |e, *place| {
        place.* = null;
        // An empty page is never written; early Split View wrote one.
        if (e.url.len == 0 or std.mem.eql(u8, e.url, "about:blank")) continue;
        const t = self.makeAsleep(e.url, e.title, e.name, space);
        t.own(&t.pin, e.pin);
        if (e.pin != null) {
            t.pin_id = e.pinID;
            t.listed = e.listed == true;
            // The page it was pinned at, or where it was when it came back.
            t.own(&t.home, e.home orelse e.url);
        }
        if (e.pin == null) if (e.groupID) |gid| for (groups) |g| if (g.id.eql(gid)) {
            t.group_id = gid;
            break;
        };
        row.append(self.gpa, t) catch @panic("OOM");
        place.* = t;
    }
    const said: ?*Tab = if (saved.active >= 0 and saved.active < by_saved.len) by_saved[@intCast(saved.active)] else null;
    self.reconcilePins(&row, space);
    // Pairs, whether Split View is on or not: off, they wait, as groups
    // do. Each tab in one pair at most, and only a pair that still holds.
    var splits: std.ArrayList(TabSplit) = .empty;
    for (saved.splits) |s| {
        if (s.tabs.len != 2) continue;
        const l = slot(by_saved, s.tabs[0]) orelse continue;
        const r = slot(by_saved, s.tabs[1]) orelse continue;
        const taken = for (splits.items) |p| {
            if (p.contains(l.id) or p.contains(r.id)) break true;
        } else false;
        if (taken) continue;
        const focused = if (s.focused) |f| if (slot(by_saved, f)) |t| t.id else null else null;
        var p = TabSplit.make(.{ l.id, r.id }, s.sizes, focused);
        p.axis = s.axis;
        if (!split_ops.holds(p, row.items)) continue;
        splits.append(self.gpa, p) catch @panic("OOM");
    }
    var active: u64 = 0;
    if (said) |t| if (std.mem.indexOfScalar(*Tab, row.items, t) != null) {
        active = t.id;
    };
    return .{ .tabs = row, .active = active, .splits = splits };
}

fn slot(by_saved: []const ?*Tab, i: i64) ?*Tab {
    if (i < 0 or i >= by_saved.len) return null;
    return by_saved[@intCast(i)];
}

/// Another space's row put on screen in place of this one; `row` and
/// `splits` are moved in.
pub fn showRow(self: *Browser, row: std.ArrayList(*Tab), active: u64, splits: std.ArrayList(TabSplit)) void {
    self.tabs.deinit(self.gpa);
    self.tabs = row;
    self.splits.deinit(self.gpa);
    self.splits = splits;
    self.active_id = if (active != 0) active else if (row.items.len > 0) row.items[0].id else 0;
    self.arrangeGroupedTabs(null);
    // A question its page asked while the space was away (`activeID.didSet`).
    if (self.tabById(self.active_id)) |front| @import("../web/dialogs.zig").presentHeld(front);
}
