//! Browser.swift "pinning" (1154-1299) and "pins, the same in every
//! window" (1917-2010). A pin is a tab with a letter, kept at the head of
//! the row — squares, then rows — put down by ⌘W rather than closed, and
//! the same in every window: what makes it a pin is `kea.pins`'s, each
//! window keeping its own tab for it. Arc's import (`takeArc`) comes with P11.
const std = @import("std");
const Browser = @import("browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const json = @import("../data/json.zig");
const Uuid = json.Uuid;
const PinDef = @import("../data/pins.zig").PinDef;
const rows = @import("browser_rows.zig");

pub fn pinnedCount(self: *Browser) usize {
    var n: usize = 0;
    for (self.tabs.items) |t| n += @intFromBool(t.pin != null);
    return n;
}

/// The pins drawn as squares: those not kept as rows, and every pin while
/// the rows are off. On `gpa`, the caller's.
pub fn squarePins(self: *Browser, gpa: std.mem.Allocator) ![]*Tab {
    var out: std.ArrayList(*Tab) = .empty;
    errdefer out.deinit(gpa);
    const rows_on = self.prefs.showsPinRows();
    for (self.tabs.items) |t| if (t.pin != null and !(t.listed and rows_on)) try out.append(gpa, t);
    return out.toOwnedSlice(gpa);
}

/// The pins kept as rows, under the squares; none while the rows are off.
pub fn listedPins(self: *Browser, gpa: std.mem.Allocator) ![]*Tab {
    var out: std.ArrayList(*Tab) = .empty;
    errdefer out.deinit(gpa);
    if (self.prefs.showsPinRows()) for (self.tabs.items) |t| if (t.pin != null and t.listed) try out.append(gpa, t);
    return out.toOwnedSlice(gpa);
}

/// Pinned at once, its letter guessed from the address; `listed`: as a row
/// under the squares. Never a private tab, nor one in a group.
pub fn pin(self: *Browser, tab: *Tab, listed: bool) void {
    defer self.redraw();
    if (tab.shy) return;
    self.detachSplit(tab);
    if (tab.pin == null) {
        const previous = tab.group_id;
        tab.group_id = null;
        self.removeEmptyGroup(previous);
        var buf: [4]u8 = undefined;
        tab.own(&tab.pin, tab.monogram(&buf));
        tab.own(&tab.home, tab.pending orelse tab.url());
        tab.listed = listed;
        settlePin(self, tab, false);
    }
    self.writeSession(true);
}

/// A square made a row, or a row a square: to the nearer end of its new kind.
pub fn setListed(self: *Browser, tab: *Tab, listed: bool) void {
    if (tab.pin == null or tab.listed == listed) return;
    if (self.editing_pin == tab.id) self.editing_pin = null;
    tab.listed = listed;
    settlePin(self, tab, listed);
    self.writeSession(true);
    self.redraw();
}

/// A pin put in its place: the squares, then the rows, then everything
/// else. `first`: at the head of its kind rather than the end.
fn settlePin(self: *Browser, tab: *Tab, first: bool) void {
    const here = self.indexOf(tab) orelse return;
    _ = self.tabs.orderedRemove(here);
    var squares: usize = 0;
    var pins: usize = 0;
    for (self.tabs.items) |t| if (t.pin != null) {
        pins += 1;
        squares += @intFromBool(!t.listed);
    };
    const at = if (tab.listed) (if (first) squares else pins) else squares;
    self.tabs.insert(self.gpa, at, tab) catch @panic("OOM");
    self.arrangeGroupedTabs(null);
}

/// A double-click on the pin you are on: back to the page it was pinned
/// at. Already there, it changes its letter.
pub fn goHome(self: *Browser, tab: *Tab) void {
    if (tab.pin == null) return;
    const home = tab.home orelse return self.editLetter(tab);
    if (samePage(home, tab.url())) return self.editLetter(tab);
    tab.go(home);
    self.rememberSession();
}

/// The same page, give or take a trailing slash.
pub fn samePage(one: []const u8, other: []const u8) bool {
    if (other.len == 0) return false;
    return std.mem.eql(u8, std.mem.trimEnd(u8, one, "/"), std.mem.trimEnd(u8, other, "/"));
}

/// Change Letter, or a double-click on the square itself.
pub fn editLetter(self: *Browser, tab: *Tab) void {
    if (tab.pin == null) return;
    self.editing_pin = tab.id;
    self.redraw();
}

/// Typed into the square: its first character, uppercased. Empty leaves
/// the letter as it was.
pub fn letter(self: *Browser, typed: []const u8, tab: *Tab) void {
    _ = self;
    const word = std.mem.trim(u8, typed, " \t\r\n");
    if (word.len == 0) return;
    const n = @min(word.len, std.unicode.utf8ByteSequenceLength(word[0]) catch 1);
    var buf: [4]u8 = undefined;
    @memcpy(buf[0..n], word[0..n]);
    // ponytail: ASCII uppercasing; Swift's uppercased() folds every script.
    if (n == 1) buf[0] = std.ascii.toUpper(buf[0]);
    tab.own(&tab.pin, buf[0..n]);
}

pub fn endPinEdit(self: *Browser) void {
    if (self.editing_pin == null) return;
    self.editing_pin = null;
    self.writeSession(true);
    self.redraw();
}

/// Back out of the pinned block, to the head of the loose tabs.
pub fn unpin(self: *Browser, tab: *Tab) void {
    if (self.editing_pin == tab.id) self.editing_pin = null;
    tab.own(&tab.pin, null);
    tab.own(&tab.home, null);
    tab.listed = false;
    tab.pin_id = null;
    if (self.indexOf(tab)) |here| {
        const home = self.pinnedCount();
        if (here != home) {
            _ = self.tabs.orderedRemove(here);
            self.tabs.insert(self.gpa, @min(home, self.tabs.items.len), tab) catch @panic("OOM");
        }
    }
    self.arrangeGroupedTabs(null);
    self.writeSession(true);
    self.rememberSession();
    self.redraw();
}

// MARK: the same in every window

/// What makes this row's pinned tabs pins, in their order; on `arena`.
pub fn pinDefs(self: *Browser, arena: std.mem.Allocator, row: []const *Tab) ![]PinDef {
    _ = self;
    var out: std.ArrayList(PinDef) = .empty;
    for (row) |t| {
        const letter_ = t.pin orelse continue;
        if (t.shy) continue;
        if (t.pin_id == null) t.pin_id = Uuid.random();
        try out.append(arena, .{
            .id = t.pin_id.?,
            .letter = letter_,
            .home = t.home orelse t.pending orelse t.url(),
            .title = t.title(),
            .name = t.name,
            .listed = if (t.listed) true else null,
        });
    }
    return out.items;
}

/// A row with the space's pins as they are now: this window's own tab for
/// each, relettered and in order, one made asleep for a pin new here, and
/// the tab of a pin taken away closed. A pin from before pins had ids is
/// matched by letter and page, then by place.
pub fn reconcilePins(self: *Browser, row: *std.ArrayList(*Tab), space: Uuid) void {
    const defs = self.kea.pins.defs(space);
    var pinned: std.ArrayList(*Tab) = .empty;
    defer pinned.deinit(self.gpa);
    var loose: std.ArrayList(*Tab) = .empty;
    defer loose.deinit(self.gpa);
    for (row.items) |t| (if (t.pin != null and !t.shy) pinned.append(self.gpa, t) else loose.append(self.gpa, t)) catch @panic("OOM");
    var out: std.ArrayList(*Tab) = .empty;
    for (defs) |def| {
        const found = find(pinned.items, def);
        const tab = if (found) |i| pinned.orderedRemove(i) else self.makeAsleep(if (def.home.len > 0) def.home else "about:blank", def.title, def.name, space);
        tab.pin_id = def.id;
        tab.own(&tab.pin, def.letter);
        tab.setName(def.name);
        tab.listed = def.listed == true;
        tab.own(&tab.home, def.home);
        out.append(self.gpa, tab) catch @panic("OOM");
    }
    for (pinned.items) |gone| self.letGo(gone);
    // In the order they were written; squares ahead of rows all the same.
    var tiered: std.ArrayList(*Tab) = .empty;
    for (out.items) |t| if (!t.listed) tiered.append(self.gpa, t) catch @panic("OOM");
    for (out.items) |t| if (t.listed) tiered.append(self.gpa, t) catch @panic("OOM");
    tiered.appendSlice(self.gpa, loose.items) catch @panic("OOM");
    out.deinit(self.gpa);
    row.deinit(self.gpa);
    row.* = tiered;
}

fn find(pinned: []const *Tab, def: PinDef) ?usize {
    for (pinned, 0..) |t, i| if (t.pin_id != null and t.pin_id.?.eql(def.id)) return i;
    for (pinned, 0..) |t, i| if (t.pin_id == null and std.mem.eql(u8, t.pin.?, def.letter) and
        std.mem.eql(u8, t.home orelse "", def.home)) return i;
    for (pinned, 0..) |t, i| if (t.pin_id == null) return i;
    return null;
}

/// Another window changed a space's pins: this window's row there follows.
pub fn pinsChanged(self: *Browser, space: Uuid) void {
    if (space.eql(self.space_id)) {
        self.reconcilePins(&self.tabs, space);
        self.arrangeGroupedTabs(null);
        if (self.tabById(self.active_id) == null) {
            self.active_id = 0;
            for (self.tabs.items) |t| if (t.pin == null) {
                self.active_id = t.id;
                break;
            };
            if (self.active_id == 0 and self.tabs.items.len > 0) self.active_id = self.tabs.items[0].id;
            if (self.active_id == 0) self.newTab();
        }
        @import("split.zig").keepWhole(&self.splits, self.tabs.items);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const groups = rows.groupsForSession(a, self.tab_groups.items) catch return;
        const shape = self.session(a, self.tabs.items, self.active_id, groups, self.splits.items) catch return;
        if (!self.restoring) self.writeRow(self.space_id, shape, false);
        return self.redraw();
    }
    const row = self.parked.getPtr(space) orelse return;
    self.reconcilePins(&row.tabs, space);
    @import("split.zig").keepWhole(&row.splits, row.tabs.items);
    if (!has(row.tabs.items, row.active)) row.active = if (row.tabs.items.len > 0) row.tabs.items[0].id else 0;
}

fn has(list: []const *Tab, id: u64) bool {
    for (list) |t| if (t.id == id) return true;
    return false;
}
