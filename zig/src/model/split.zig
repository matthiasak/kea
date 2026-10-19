//! Split View's pairs (`Split.swift`, Browser.swift 93-133 and 2332-2516):
//! tabs shown side by side, sharing one place in the row — the first is
//! the pair's place, the other follows it. `active_id` is the page with
//! the keys; the pair it is in, while Split View is on, is `activeSplit`.
//! Turned off, pairs are kept, as groups are, and nothing acts on them.
const std = @import("std");
const Browser = @import("browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const Axis = @import("../data/session.zig").Axis;
const float = @import("../web/float.zig");
const dialogs = @import("../web/dialogs.zig");

/// `TabSplit`. ponytail: two pages, as Split View shows; a saved pair of
/// more is dropped on restore (`restoreRow`) — widen `tabs` if a third comes.
pub const TabSplit = struct {
    id: Uuid,
    /// In the order they are shown.
    tabs: [2]u64,
    axis: Axis = .horizontal,
    /// Each page's share of the stage, adding up to 1.
    sizes: [2]f64 = .{ 0.5, 0.5 },
    /// The page last focused, to come back to.
    focused: ?u64 = null,

    pub fn make(tabs: [2]u64, sizes: ?[]const f64, focused: ?u64) TabSplit {
        var s: TabSplit = .{ .id = Uuid.random(), .tabs = tabs };
        if (focused) |f| if (s.contains(f)) {
            s.focused = f;
        };
        if (sizes) |z| if (z.len == 2) {
            s.sizes = clamp(z[0]);
        };
        return s;
    }

    pub fn left(s: TabSplit) u64 {
        return s.tabs[0];
    }

    pub fn right(s: TabSplit) u64 {
        return s.tabs[1];
    }

    /// The first page's share.
    pub fn fraction(s: TabSplit) f64 {
        return s.sizes[0];
    }

    pub fn contains(s: TabSplit, id: u64) bool {
        return s.tabs[0] == id or s.tabs[1] == id;
    }

    /// The other page.
    pub fn partner(s: TabSplit, id: u64) ?u64 {
        if (s.tabs[0] == id) return s.tabs[1];
        if (s.tabs[1] == id) return s.tabs[0];
        return null;
    }

    pub fn replace(s: *TabSplit, old: u64, new: u64) void {
        for (&s.tabs) |*t| if (t.* == old) {
            t.* = new;
        };
        if (s.focused == old) s.focused = new;
    }

    /// No page narrower than a fifth of the stage; shares adding up to 1.
    pub fn clamp(first: f64) [2]f64 {
        const f = std.math.clamp(if (std.math.isFinite(first)) first else 0.5, 0.2, 0.8);
        return .{ f, 1 - f };
    }
};

// MARK: which pair

/// The pair holding `id`, Split View on or off.
fn at(self: *const Browser, id: u64) ?usize {
    for (self.splits.items, 0..) |s, i| if (s.contains(id)) return i;
    return null;
}

/// `split(for:)`: the pair a tab is in, while Split View is on.
pub fn splitFor(self: *Browser, tab: *const Tab) ?TabSplit {
    if (!self.prefs.split_view) return null;
    return self.splits.items[at(self, tab.id) orelse return null];
}

/// The pair the page with the keys is in.
pub fn activeSplit(self: *Browser) ?TabSplit {
    if (!self.prefs.split_view or self.active_id == 0) return null;
    return self.splits.items[at(self, self.active_id) orelse return null];
}

pub fn inSplit(self: *Browser, tab: *const Tab) bool {
    return self.splitFor(tab) != null;
}

/// The pair's other page.
pub fn partnerOf(self: *Browser, tab: *const Tab) ?*Tab {
    const s = self.splitFor(tab) orelse return null;
    return self.tabById(s.partner(tab.id) orelse return null);
}

/// `standsInRow`: any tab but a pair's later page, which shares the first's place.
pub fn standsInRow(self: *Browser, tab: *const Tab) bool {
    const s = self.splitFor(tab) orelse return true;
    return s.left() == tab.id;
}

/// `entry`: where a key that picks a place lands — a pair's page that had
/// the keys last, not always its first.
pub fn entry(self: *Browser, tab: *Tab) *Tab {
    const s = self.splitFor(tab) orelse return tab;
    if (s.left() != tab.id) return tab;
    return self.tabById(s.focused orelse return tab) orelse tab;
}

/// `Browser.holds`: all its tabs in `row`, next to each other in its
/// order, none pinned, of one kind and one group.
pub fn holds(split: TabSplit, row: []const *Tab) bool {
    var places: [2]usize = undefined;
    for (split.tabs, &places) |id, *p| {
        p.* = for (row, 0..) |t, i| {
            if (t.id == id) break i;
        } else return false;
    }
    if (places[1] != places[0] + 1) return false;
    const a = row[places[0]];
    const b = row[places[1]];
    if (a.pin != null or b.pin != null or a.shy != b.shy) return false;
    if (a.group_id == null or b.group_id == null) return a.group_id == null and b.group_id == null;
    return a.group_id.?.eql(b.group_id.?);
}

/// A pin can be split with: its page goes into the pair as a tab of its
/// own, the pin stays where it is (`splittable`).
pub fn canSplit(self: *Browser, first: *const Tab, second: *const Tab) bool {
    return self.prefs.split_view and first.id != second.id and first.shy == second.shy and
        self.indexOf(first) != null and self.indexOf(second) != null;
}

/// Zen's rule: a pin never goes into a pair — its page does, as a new tab
/// at the row's end. Anything else is itself.
fn splittable(self: *Browser, tab: *Tab) *Tab {
    if (tab.pin == null) return tab;
    const url = tab.address orelse tab.home orelse return tab;
    const copy = self.make(url, false);
    self.tabs.append(self.gpa, copy) catch @panic("OOM");
    return copy;
}

// MARK: making and unmaking pairs

/// `dragged` beside `target`, on its left or right; `dragged` gets the keys.
pub fn pair(self: *Browser, dragged_in: *Tab, target_in: *Tab, on_left: bool) void {
    if (!self.canSplit(dragged_in, target_in)) return;
    if (dragged_in.floating or target_in.floating) float.land(self);
    const dragged = splittable(self, dragged_in);
    const target = splittable(self, target_in);
    self.detachSplit(dragged);
    self.detachSplit(target);
    const old_group = dragged.group_id;
    dragged.group_id = target.group_id;
    _ = self.tabs.orderedRemove(self.indexOf(dragged).?);
    const index = self.indexOf(target).?;
    self.tabs.insert(self.gpa, if (on_left) index else index + 1, dragged) catch @panic("OOM");
    const l = if (on_left) dragged else target;
    const r = if (on_left) target else dragged;
    self.splits.append(self.gpa, TabSplit.make(.{ l.id, r.id }, null, dragged.id)) catch @panic("OOM");
    self.arrangeGroupedTabs(null);
    self.removeEmptyGroup(old_group);
    self.focusPane(dragged);
    for ([_]*Tab{ l, r }) |pane| if (!pane.isBlank()) {
        if (!pane.wake()) pane.revive();
    };
    self.rememberSession();
    self.redraw();
}

/// ⌘\ (`startSplit`): an empty page beside the one on screen, with the
/// field up in it; in a pair already, the keys go to its right page.
pub fn startSplit(self: *Browser) void {
    if (!self.prefs.split_view) return;
    const shown = self.tabById(self.active_id) orelse return;
    if (self.activeSplit()) |p| {
        if (self.tabById(p.right())) |r| self.focusPane(r);
        return;
    }
    if (shown.floating) float.land(self);
    const current = splittable(self, shown);
    const index = self.indexOf(current) orelse return;
    // ponytail: a private pair's empty page gets a private store of its own, not its partner's.
    const right = self.make("", current.shy);
    right.group_id = current.group_id;
    self.splits.append(self.gpa, TabSplit.make(.{ current.id, right.id }, null, right.id)) catch @panic("OOM");
    self.tabs.insert(self.gpa, index + 1, right) catch @panic("OOM");
    self.focusPane(right);
    self.setEditing(true);
    self.setTyped("");
    self.askFocus();
    self.rememberSession();
    self.redraw();
}

pub fn detachSplit(self: *Browser, tab: *const Tab) void {
    const i = at(self, tab.id) orelse return;
    _ = self.splits.orderedRemove(i);
    self.rememberSession();
    self.redraw();
}

/// The divider let go of, or moved by a key or VoiceOver.
pub fn setSplitFraction(self: *Browser, id: Uuid, fraction: f64) void {
    if (!std.math.isFinite(fraction)) return;
    for (self.splits.items) |*s| if (s.id.eql(id)) {
        const sizes = TabSplit.clamp(fraction);
        if (std.mem.eql(f64, &s.sizes, &sizes)) return;
        s.sizes = sizes;
        self.rememberSession();
        return self.redraw();
    };
}

/// The keys to `tab`: within the pair on screen a focus change, which
/// puts the field and the tab's address away; anything else is `select`.
pub fn focusPane(self: *Browser, tab: *Tab) void {
    if (self.indexOf(tab) == null) return;
    const mine = self.splitFor(tab);
    const front = self.activeSplit();
    if (mine == null or front == null or !mine.?.id.eql(front.?.id)) return self.select(tab);
    if (self.active_id == tab.id) return;
    if (comptime @hasDecl(Browser, "closePeek")) if (self.peek_tab != null) self.closePeek();
    self.cancelTabEdit();
    self.summoning = false;
    self.setEditing(false);
    self.setTyped("");
    self.setActive(tab.id);
    tab.touch();
    self.rememberSession();
    self.redraw();
}

/// ⌃⌘← and ⌃⌘→: the page on that side.
pub fn focusPaneSide(self: *Browser, on_left: bool) void {
    const p = self.activeSplit() orelse return;
    self.focusPane(self.tabById(if (on_left) p.left() else p.right()) orelse return);
}

pub fn focusOtherPane(self: *Browser) void {
    const p = self.activeSplit() orelse return;
    self.focusPane(self.tabById(p.partner(self.active_id) orelse return) orelse return);
}

/// The tab menu's Open in Split View: beside the page on screen; asked of
/// that page itself, an empty page beside it.
pub fn openInSplit(self: *Browser, tab: *Tab) void {
    if (!self.prefs.split_view) return;
    const current = self.tabById(self.active_id) orelse return;
    if (tab.id == current.id) return self.startSplit();
    if (self.splitFor(tab)) |s| if (s.contains(current.id)) return self.focusPane(tab);
    if (!self.canSplit(tab, current)) return;
    self.pair(tab, current, false);
}

/// The divider's menu › Swap Pages: the pages, their shares and their places.
pub fn swapSplit(self: *Browser) void {
    const p = self.activeSplit() orelse return;
    const i = at(self, p.left()).?;
    const l = self.tabById(p.left()) orelse return;
    const r = self.tabById(p.right()) orelse return;
    const start = self.indexOf(l) orelse return;
    std.mem.swap(u64, &self.splits.items[i].tabs[0], &self.splits.items[i].tabs[1]);
    std.mem.swap(f64, &self.splits.items[i].sizes[0], &self.splits.items[i].sizes[1]);
    _ = self.tabs.orderedRemove(self.indexOf(l).?);
    _ = self.tabs.orderedRemove(self.indexOf(r).?);
    const place = @min(start, self.tabs.items.len);
    self.tabs.insertSlice(self.gpa, place, &.{ r, l }) catch @panic("OOM");
    self.rememberSession();
    self.redraw();
}

/// Even Out, or a double click on the divider.
pub fn evenSplit(self: *Browser) void {
    const p = self.activeSplit() orelse return;
    self.setSplitFraction(p.id, 0.5);
}

/// Close Both.
pub fn closeSplit(self: *Browser) void {
    const p = self.activeSplit() orelse return;
    for (p.tabs) |id| if (self.tabById(id)) |t| self.close(t);
}

/// An empty page of a pair given an open tab: the tab takes its place
/// and the empty one goes (`fill`).
pub fn fill(self: *Browser, blank: *Tab, tab_in: *Tab) void {
    const s = self.splitFor(blank) orelse return;
    if (!blank.isBlank() or tab_in.id == blank.id or s.contains(tab_in.id) or tab_in.shy != blank.shy) return;
    if (self.indexOf(blank) == null) return;
    const tab = splittable(self, tab_in);
    self.detachSplit(tab);
    const old_group = tab.group_id;
    tab.group_id = blank.group_id;
    _ = self.tabs.orderedRemove(self.indexOf(tab).?);
    self.tabs.items[self.indexOf(blank).?] = tab;
    replaceSplitMember(self, blank.id, tab.id);
    self.arrangeGroupedTabs(null);
    self.removeEmptyGroup(old_group);
    self.letGo(blank);
    self.setActive(tab.id);
    self.setEditing(false);
    self.setTyped("");
    if (!tab.wake()) tab.revive();
    self.rememberSession();
    self.redraw();
}

pub fn replaceSplitMember(self: *Browser, old: u64, new: u64) void {
    const i = at(self, old) orelse return;
    self.splits.items[i].replace(old, new);
}

/// `activeID.didSet`, the pair's part: leaving a pair touches its other
/// page too; arriving in one makes this its page to come back to.
pub fn activeMoved(self: *Browser, old: u64, id: u64) void {
    if (!self.prefs.split_view) return;
    if (at(self, old)) |i| {
        const s = self.splits.items[i];
        if (!s.contains(id)) if (self.tabById(s.partner(old).?)) |p| p.touch();
    }
    if (at(self, id)) |i| self.splits.items[i].focused = id;
}

/// The pairs as `prefs.split_view` changes (Browser.follow): off, what a
/// page asked over its pane is dismissed; back on, pairs that came apart
/// meanwhile go, here and in the other spaces' rows.
pub fn splitViewChanged(self: *Browser, on: bool) void {
    defer self.redraw();
    if (!on) {
        for (self.tabs.items) |t| {
            var i: usize = 0;
            while (i < t.questions.items.len) {
                const a = t.questions.items[i];
                if (a.pane) dialogs.answer(a, false, null) else i += 1;
            }
        }
        return;
    }
    keepHolding(&self.splits, self.tabs.items);
    for (self.parked.values()) |*row| keepHolding(&row.splits, row.tabs.items);
    self.writeSession(true);
}

/// Only the pairs that still hold in `row`.
pub fn keepHolding(list: *std.ArrayList(TabSplit), row: []const *Tab) void {
    var k: usize = 0;
    for (list.items) |s| if (holds(s, row)) {
        list.items[k] = s;
        k += 1;
    };
    list.shrinkRetainingCapacity(k);
}

/// Pairs with a page no longer in `row` go (`pinsChanged`).
pub fn keepWhole(list: *std.ArrayList(TabSplit), row: []const *Tab) void {
    var k: usize = 0;
    for (list.items) |s| {
        var whole = true;
        for (s.tabs) |id| whole = whole and for (row) |t| {
            if (t.id == id) break true;
        } else false;
        if (!whole) continue;
        list.items[k] = s;
        k += 1;
    }
    list.shrinkRetainingCapacity(k);
}

test "clamp keeps a fifth and adds to one" {
    try std.testing.expectEqual([2]f64{ 0.2, 0.8 }, TabSplit.clamp(0.05));
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), TabSplit.clamp(0.95)[1], 1e-12);
    try std.testing.expectEqual([2]f64{ 0.5, 0.5 }, TabSplit.clamp(std.math.nan(f64)));
    var s = TabSplit.make(.{ 1, 2 }, &.{ 0.3, 0.7 }, 9);
    try std.testing.expectEqual(@as(?u64, null), s.focused);
    try std.testing.expectEqual(@as(?u64, 1), s.partner(2));
    s.replace(2, 3);
    try std.testing.expect(s.contains(3) and !s.contains(2));
}
