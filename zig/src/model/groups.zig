//! Tab groups (`TabGroup.swift`, `TabGroups.swift`, Browser.swift
//! 3127-3254): named sections of ordinary tabs in one space's row. A tab's
//! own `group_id` says which; a group lasts as long as its tabs. With groups
//! on, the row is kept in the order it is shown: pins, each group's tabs in
//! the groups' order, then the tabs in none.
const std = @import("std");
const Browser = @import("browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const closed = @import("browser_closed.zig");

/// `TabGroup`, its name on the browser's `gpa`.
pub const TabGroup = struct {
    id: Uuid,
    name: []u8,
    collapsed: bool = false,
};

pub fn owned(gpa: std.mem.Allocator, id: Uuid, name: []const u8, collapsed: bool) TabGroup {
    return .{ .id = id, .name = gpa.dupe(u8, name) catch @panic("OOM"), .collapsed = collapsed };
}

pub fn freeGroups(gpa: std.mem.Allocator, list: *std.ArrayList(TabGroup)) void {
    for (list.items) |g| gpa.free(g.name);
    list.clearAndFree(gpa);
}

/// `TabGroup.number`: the number an extension knows the group by.
pub fn number(id: Uuid) u32 {
    const u = id.bytes;
    const n = @as(u32, u[0] & 0x7F) << 24 | @as(u32, u[1]) << 16 | @as(u32, u[2]) << 8 | u[3];
    return if (n == 0) 1 else n;
}

pub fn groupById(self: *Browser, id: Uuid) ?*TabGroup {
    for (self.tab_groups.items) |*g| if (g.id.eql(id)) return g;
    return null;
}

fn groupIndex(self: *Browser, id: Uuid) ?usize {
    for (self.tab_groups.items, 0..) |g, i| if (g.id.eql(id)) return i;
    return null;
}

/// A new group holding `tab`, its name up for editing. A tab that can't be
/// in one (a pin, a private one) leaves none behind.
pub fn addTabGroup(self: *Browser, tab: *Tab) Uuid {
    const id = Uuid.random();
    const name = std.fmt.allocPrint(self.gpa, "Group {d}", .{self.tab_groups.items.len + 1}) catch @panic("OOM");
    self.tab_groups.append(self.gpa, .{ .id = id, .name = name }) catch @panic("OOM");
    self.editing_group_id = id;
    self.moveToGroup(tab, id);
    self.removeEmptyGroup(id);
    self.writeSession(true);
    self.redraw();
    return id;
}

pub fn renameTabGroup(self: *Browser, id: Uuid, name: []const u8) void {
    const g = self.groupById(id) orelse return;
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return;
    const copy = self.gpa.dupe(u8, trimmed) catch return;
    self.gpa.free(g.name);
    g.name = copy;
    self.writeSession(true);
    self.redraw();
}

pub fn toggleTabGroup(self: *Browser, id: Uuid) void {
    const g = self.groupById(id) orelse return;
    g.collapsed = !g.collapsed;
    self.writeSession(true);
    self.redraw();
}

/// Ungroup Tabs: the tabs stay, loose.
pub fn removeTabGroup(self: *Browser, id: Uuid) void {
    const at = groupIndex(self, id) orelse return;
    for (self.tabs.items) |t| if (t.group_id != null and t.group_id.?.eql(id)) {
        t.group_id = null;
    };
    self.gpa.free(self.tab_groups.orderedRemove(at).name);
    self.arrangeGroupedTabs(null);
    if (self.editing_group_id != null and self.editing_group_id.?.eql(id)) self.editing_group_id = null;
    self.writeSession(true);
    self.redraw();
}

/// Close Group: the group and every tab in it, remembered together so one
/// ⇧⌘T brings the group back whole. The page on screen goes last.
pub fn closeTabGroup(self: *Browser, id: Uuid) void {
    const at = groupIndex(self, id) orelse return;
    const g = self.tab_groups.items[at];
    self.closed_groups.append(self.gpa, .{ .group = owned(self.gpa, g.id, g.name, g.collapsed), .at = at }) catch return;
    var going: std.ArrayList(u64) = .empty;
    defer going.deinit(self.gpa);
    for (self.tabs.items) |t| if (t.group_id != null and t.group_id.?.eql(id)) going.append(self.gpa, t.id) catch return;
    const was = self.active_id;
    const batch = closed.beginBatch(self);
    const visible = self.visibleTabIDs();
    for (going.items) |tid| if (tid != visible[0] and tid != visible[1]) if (self.tabById(tid)) |t| self.close(t);
    for (going.items) |tid| if (self.tabById(tid)) |t| self.close(t);
    closed.endBatch(self, batch, was);
    // The group goes with its last tab; an empty one goes here.
    if (groupIndex(self, id) != null) self.removeTabGroup(id);
    self.writeSession(true);
    self.redraw();
}

/// Into a group, or out of one with `id` null. Never a pin or a private tab.
pub fn moveToGroup(self: *Browser, tab: *Tab, id: ?Uuid) void {
    if (self.indexOf(tab) == null or tab.pin != null or tab.shy) return;
    if (id) |g| if (groupIndex(self, g) == null) return;
    const previous = tab.group_id;
    if (eqlOpt(previous, id)) return;
    // A pair is one place in the row: moved into a group or out of one,
    // both halves go, and stay a pair.
    const partner = self.partnerOf(tab);
    tab.group_id = id;
    if (partner) |p| p.group_id = id;
    self.removeEmptyGroup(previous);
    self.arrangeGroupedTabs(null);
    if (id) |g| if (self.groupById(g)) |group| {
        group.collapsed = false;
    };
    self.writeSession(true);
    self.redraw();
}

fn eqlOpt(a: ?Uuid, b: ?Uuid) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

/// Reordered among its peers in the section shown.
pub fn moveWithin(self: *Browser, tab: *Tab, group: ?Uuid, index: usize) void {
    const all = self.tabsIn(self.gpa, group) catch return;
    defer self.gpa.free(all);
    var peers: std.ArrayList(*Tab) = .empty;
    defer peers.deinit(self.gpa);
    for (all) |t| if (self.standsInRow(t)) peers.append(self.gpa, t) catch return;
    const from = std.mem.indexOfScalar(*Tab, peers.items, tab) orelse return;
    if (index >= peers.items.len or from == index) return;
    const destination = self.indexOf(peers.items[index]) orelse return;
    self.move(tab, destination);
}

pub fn moveTabGroup(self: *Browser, id: Uuid, index: usize) void {
    const from = groupIndex(self, id) orelse return;
    if (index >= self.tab_groups.items.len or from == index) return;
    const g = self.tab_groups.orderedRemove(from);
    self.tab_groups.insert(self.gpa, index, g) catch @panic("OOM");
    self.arrangeGroupedTabs(null);
    self.writeSession(true);
    self.redraw();
}

/// The row in the order it is shown: the pins, each group's tabs in the
/// groups' order, then the tabs in none. Nothing while groups are off.
/// `on`: the setting about to be, when it is changing.
pub fn arrangeGroupedTabs(self: *Browser, on: ?bool) void {
    if (!(on orelse self.prefs.uses_tab_groups)) return;
    const n = self.tabs.items.len;
    const order = self.gpa.alloc(*Tab, n) catch return;
    defer self.gpa.free(order);
    var k: usize = 0;
    for (self.tabs.items) |t| if (t.pin != null) {
        order[k] = t;
        k += 1;
    };
    for (self.tab_groups.items) |g| for (self.tabs.items) |t| if (self.groupOf(t)) |gid| if (gid.eql(g.id)) {
        order[k] = t;
        k += 1;
    };
    for (self.tabs.items) |t| if (t.pin == null and self.groupOf(t) == null) {
        order[k] = t;
        k += 1;
    };
    @memcpy(self.tabs.items, order[0..k]);
}

/// The group a tab is shown in: none for a pin, or for a group this space
/// doesn't have.
pub fn groupOf(self: *Browser, tab: *const Tab) ?Uuid {
    if (tab.pin != null) return null;
    const id = tab.group_id orelse return null;
    return if (self.groupById(id) != null) id else null;
}

/// A section's tabs (`group` null: the loose ones), on `gpa`.
pub fn tabsIn(self: *Browser, gpa: std.mem.Allocator, group: ?Uuid) ![]*Tab {
    var out: std.ArrayList(*Tab) = .empty;
    errdefer out.deinit(gpa);
    for (self.tabs.items) |t| if (t.pin == null and eqlOpt(self.groupOf(t), group)) try out.append(gpa, t);
    return out.toOwnedSlice(gpa);
}

/// A folded group shows its name alone — and the tab you are on, if it is
/// in there (a pair's, its first page). A pair's later page has no place.
pub fn visibleTabsIn(self: *Browser, gpa: std.mem.Allocator, group: TabGroup) ![]*Tab {
    const members = try self.tabsIn(gpa, group.id);
    defer gpa.free(members);
    const front = if (self.activeSplit()) |p| p.left() else self.active_id;
    var out: std.ArrayList(*Tab) = .empty;
    errdefer out.deinit(gpa);
    for (members) |t| if (self.standsInRow(t) and (!group.collapsed or t.id == front)) try out.append(gpa, t);
    return out.toOwnedSlice(gpa);
}

/// A group lasts as long as its tabs: the last one gone, it goes too.
pub fn removeEmptyGroup(self: *Browser, id: ?Uuid) void {
    const gid = id orelse return;
    for (self.tabs.items) |t| if (t.group_id != null and t.group_id.?.eql(gid)) return;
    const at = groupIndex(self, gid) orelse return;
    self.gpa.free(self.tab_groups.orderedRemove(at).name);
    if (self.editing_group_id != null and self.editing_group_id.?.eql(gid)) self.editing_group_id = null;
}
