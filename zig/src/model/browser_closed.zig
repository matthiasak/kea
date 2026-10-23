//! Browser.swift "tabs", the closing half (2678-2950): ⌘W, Close Other
//! Tabs, Clear, and ⇧⌘T bringing back a tab, a Clear's tabs or a closed
//! group (`ghosts`, twelve steps back, a batch counting as one).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const browsers = @import("../app/browsers.zig");
const TabGroup = @import("groups.zig").TabGroup;

/// A closed tab, newest last (`Browser.Ghost`); strings on `gpa`.
pub const Ghost = struct {
    id: Uuid,
    url: []u8,
    title: []u8,
    index: usize,
    group_id: ?Uuid,
    /// When it was closed (`ui.clock`), weighed against a window closed since.
    at: f64,
    /// The other page of the pair it was in, and whether it was on its left.
    partner: ?u64 = null,
    on_left: bool = false,
    /// The tab it was, for a pair closed together to find its other half.
    was: ?u64 = null,
    /// The Clear or Close Group it went with: one ⇧⌘T brings all of it back.
    batch: ?Uuid = null,
    /// Of a batch's tabs, the one you were on, which comes back in front.
    front: bool = false,

    pub fn deinit(g: Ghost, gpa: std.mem.Allocator) void {
        gpa.free(g.url);
        gpa.free(g.title);
    }
};

/// A group Close Group took, and where it was among the others.
pub const ClosedGroup = struct { group: TabGroup, at: usize };

/// The last Clear, and the empty tab it left in front.
pub const LastClear = struct { batch: Uuid, blank: ?u64 };

/// ⌘W, or the cross on the tab. A pin is put down, not closed; closing the
/// last tab leaves a blank one; closing that blank one closes the window.
pub fn close(self: *Browser, tab: *Tab) void {
    const index = self.indexOf(tab) orelse return;
    const pair = self.splitFor(tab);
    const partner = self.partnerOf(tab);
    const on_left = if (pair) |p| p.left() == tab.id else false;
    self.detachSplit(tab);

    if (tab.pin != null) {
        if (self.stage_host) |sh| if (tab.web) |wv| sh.forget(wv);
        tab.rest();
        // Ordinary tabs first, the most recently looked at.
        var any: ?*Tab = null;
        var loose: ?*Tab = null;
        for (self.tabs.items) |t| {
            if (t == tab or t.asleep()) continue;
            if (any == null or t.touched > any.?.touched) any = t;
            if (t.pin == null and (loose == null or t.touched > loose.?.touched)) loose = t;
        }
        if (loose orelse any) |back| @import("browser_tabs.zig").selectEx(self, back, false) else self.newTab();
        self.writeSession(true);
        return self.redraw();
    }

    if (self.tabs.items.len == 1) {
        if (tab.isBlank()) {
            if (self.window) |w| objc.msg(void, w.nswindow, "performClose:", .{@as(?objc.Object, null)});
            return;
        }
        remember(self, tab, 0, null, false);
        const group = tab.group_id;
        _ = self.tabs.orderedRemove(0);
        self.letGo(tab);
        self.active_id = 0;
        self.adopt(self.make("", false));
        self.removeEmptyGroup(group);
        self.rememberSession();
        return self.redraw();
    }

    remember(self, tab, index, if (partner) |p| p.id else null, on_left);
    const id = tab.id;
    const group = tab.group_id;
    _ = self.tabs.orderedRemove(index);
    self.letGo(tab);
    self.removeEmptyGroup(group);
    if (self.active_id == id) {
        // The neighbour on the right, or the last one: through select, so
        // one never built yet wakes.
        @import("browser_tabs.zig").selectEx(self, partner orelse self.tabs.items[@min(index, self.tabs.items.len - 1)], false);
    }
    self.rememberSession();
    self.redraw();
}

/// ⌘W: what is in front — a Peek, else the sheet up, else the tab
/// (`Browser.swift` `close()`).
pub fn closeFront(self: *Browser) void {
    if (self.peek_tab != null) return self.closePeek();
    if (@import("../chrome/sheet.zig").closePanel(self)) return;
    if (self.activeTab()) |t| self.close(t);
}

/// Everything but this one (and its pair's other page); pins are put down.
pub fn closeOthers(self: *Browser, keep: *Tab) void {
    @import("browser_tabs.zig").selectEx(self, keep, false);
    const partner = self.partnerOf(keep);
    var ids: std.ArrayList(u64) = .empty;
    defer ids.deinit(self.gpa);
    for (self.tabs.items) |t| if (t != keep and t != partner) ids.append(self.gpa, t.id) catch return;
    for (ids.items) |id| if (self.tabById(id)) |t| self.close(t);
    self.select(keep);
}

/// Arc's Clear: every tab that comes and goes closed, remembered as one,
/// so a single ⇧⌘T puts them all back. Pins and grouped tabs stay.
pub fn clearTabs(self: *Browser) void {
    var going: std.ArrayList(u64) = .empty;
    defer going.deinit(self.gpa);
    for (self.tabs.items) |t| if (t.pin == null and self.groupOf(t) == null) going.append(self.gpa, t.id) catch return;
    if (going.items.len == 0) return;
    const was = self.active_id;
    const batch = beginBatch(self);
    clear(self, going.items, batch);
    endBatch(self, batch, was);
}

/// `closingTogether`: the tabs closed next are one batch.
pub fn beginBatch(self: *Browser) Uuid {
    const batch = Uuid.random();
    self.batching = batch;
    return batch;
}

pub fn endBatch(self: *Browser, batch: Uuid, was: u64) void {
    self.batching = null;
    var i = self.ghosts.items.len;
    while (i > 0) {
        i -= 1;
        const g = &self.ghosts.items[i];
        if (g.batch != null and g.batch.?.eql(batch) and g.was == was) {
            g.front = true;
            return;
        }
    }
}

/// The page on screen goes last, once an empty tab has taken its place.
fn clear(self: *Browser, going: []const u64, batch: Uuid) void {
    self.last_clear = .{ .batch = batch, .blank = null };
    var on_screen: [2]u64 = .{ 0, 0 };
    var shown: usize = 0;
    const visible = self.visibleTabIDs();
    for (going) |id| {
        if (id == visible[0] or id == visible[1]) {
            on_screen[shown] = id;
            shown += 1;
        } else if (self.tabById(id)) |t| self.close(t);
    }
    if (shown == 0) return;
    if (shown == 1) if (self.tabById(on_screen[0])) |t| if (t.isBlank()) return;
    var had: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer had.deinit(self.gpa);
    for (self.tabs.items) |t| had.put(self.gpa, t.id, {}) catch return;
    self.newTab();
    self.last_clear = .{ .batch = batch, .blank = if (had.contains(self.active_id)) null else self.active_id };
    for (on_screen[0..shown]) |id| if (id != self.active_id) if (self.tabById(id)) |t| self.close(t);
}

/// Kept for ⇧⌘T: twelve steps back, a batch counting as one.
fn remember(self: *Browser, tab: *Tab, index: usize, partner: ?u64, on_left: bool) void {
    if (tab.shy or tab.isBlank()) return;
    const url = self.gpa.dupe(u8, tab.url()) catch return;
    const title = self.gpa.dupe(u8, tab.title()) catch return self.gpa.free(url);
    self.ghosts.append(self.gpa, .{
        .id = Uuid.random(),
        .url = url,
        .title = title,
        .index = index,
        .group_id = tab.group_id,
        .at = ui.clock.now(),
        .partner = partner,
        .on_left = on_left,
        .was = tab.id,
        .batch = self.batching,
    }) catch {
        self.gpa.free(url);
        self.gpa.free(title);
        return;
    };
    if (steps(self) > 12) {
        const oldest = self.ghosts.items[0];
        if (oldest.batch) |b| dropBatch(self, b) else self.ghosts.orderedRemove(0).deinit(self.gpa);
    }
    // A closed group is kept while a tab it held can still come back.
    var i: usize = 0;
    while (i < self.closed_groups.items.len) {
        const id = self.closed_groups.items[i].group.id;
        const held = for (self.ghosts.items) |g| {
            if (g.group_id != null and g.group_id.?.eql(id)) break true;
        } else false;
        if (held) i += 1 else self.gpa.free(self.closed_groups.orderedRemove(i).group.name);
    }
}

fn steps(self: *Browser) usize {
    var n: usize = 0;
    for (self.ghosts.items, 0..) |g, i| {
        const b = g.batch orelse {
            n += 1;
            continue;
        };
        const seen = for (self.ghosts.items[0..i]) |e| {
            if (e.batch != null and e.batch.?.eql(b)) break true;
        } else false;
        if (!seen) n += 1;
    }
    return n;
}

fn dropBatch(self: *Browser, batch: Uuid) void {
    var i: usize = 0;
    while (i < self.ghosts.items.len) {
        const g = self.ghosts.items[i];
        if (g.batch != null and g.batch.?.eql(batch)) self.ghosts.orderedRemove(i).deinit(self.gpa) else i += 1;
    }
}

/// When the newest ghost was closed; -inf with none.
pub fn lastGhostAt(self: *Browser) f64 {
    const last = self.ghosts.getLastOrNull() orelse return -std.math.inf(f64);
    return last.at;
}

/// ⇧⌘T. A window closed after the last tab was comes back first, as in
/// Safari and Chrome; otherwise the newest tab, or its whole batch.
pub fn reopen(self: *Browser) void {
    if (browsers.lastClosedAt(self.kea)) |at| if (at > self.lastGhostAt() and browsers.reopenClosedWindow(self.kea)) return;
    const last = self.ghosts.getLastOrNull() orelse return;
    if (last.batch) |b| reopenBatch(self, b) else self.reopenGhost(self.ghosts.items.len - 1);
}

/// What ⇧⌘T brings back, for its menu items.
pub fn reopenTitle(self: *Browser, buf: []u8) []const u8 {
    const last = self.ghosts.getLastOrNull() orelse return "Reopen Closed Tab";
    const batch = last.batch orelse return "Reopen Closed Tab";
    if ((browsers.lastClosedAt(self.kea) orelse -std.math.inf(f64)) > last.at) return "Reopen Closed Tab";
    if (last.group_id) |id| {
        const closed = for (self.closed_groups.items) |g| {
            if (g.group.id.eql(id)) break true;
        } else false;
        if (closed or self.groupById(id) != null) return "Reopen Closed Group";
    }
    var count: usize = 0;
    for (self.ghosts.items) |g| if (g.batch != null and g.batch.?.eql(batch)) {
        count += 1;
    };
    if (count == 1) return "Reopen Cleared Tab";
    return std.fmt.bufPrint(buf, "Reopen {d} Cleared Tabs", .{count}) catch "Reopen Cleared Tabs";
}

/// One of them by place in `ghosts`, from ⇧⌘T or the History menu: in
/// front, at the place it left, back into its pair if that page is alone.
pub fn reopenGhost(self: *Browser, at: usize) void {
    if (at >= self.ghosts.items.len) return;
    const ghost = self.ghosts.orderedRemove(at);
    defer ghost.deinit(self.gpa);
    const t = self.make(ghost.url, false);
    const group = regroup(self, ghost);
    t.group_id = group.id;
    self.insert(t, ghost.index);
    self.setActive(t.id);
    self.setEditing(false);
    self.setTyped("");
    // Back into its pair, if the page it was beside is still alone.
    if (ghost.partner) |pid| if (self.tabById(pid)) |partner| if (self.splitFor(partner) == null and self.canSplit(t, partner)) {
        self.pair(t, partner, ghost.on_left);
    };
    self.rememberSession();
    self.redraw();
}

/// A whole Clear or Close Group back, each tab at its place, asleep but
/// for the one you were on; the empty tab Clear left goes.
fn reopenBatch(self: *Browser, batch: Uuid) void {
    var members: std.ArrayList(Ghost) = .empty;
    defer {
        for (members.items) |g| g.deinit(self.gpa);
        members.deinit(self.gpa);
    }
    var i: usize = 0;
    while (i < self.ghosts.items.len) {
        const g = self.ghosts.items[i];
        if (g.batch != null and g.batch.?.eql(batch)) {
            members.append(self.gpa, self.ghosts.orderedRemove(i)) catch @panic("OOM");
        } else i += 1;
    }
    var front: ?*Tab = null;
    var regrouped = false;
    // The tab each ghost was, and the one it is now.
    var back: std.AutoHashMapUnmanaged(u64, *Tab) = .empty;
    defer back.deinit(self.gpa);
    var k = members.items.len;
    while (k > 0) {
        k -= 1;
        const ghost = members.items[k];
        const t = self.makeAsleep(ghost.url, ghost.title, null, self.space_id);
        const group = regroup(self, ghost);
        t.group_id = group.id;
        regrouped = regrouped or group.back;
        self.insert(t, ghost.index);
        if (ghost.was) |was| back.put(self.gpa, was, t) catch {};
        if (ghost.front) front = t;
        // A pair cleared together: its other half came back just before,
        // beside it already. Made a pair again as it stands, not through
        // pair(), which would take the focus and wake both pages.
        if (ghost.partner) |id| if (back.get(id)) |partner| if (self.splitFor(partner) == null and self.canSplit(t, partner)) {
            const p = @import("split.zig").TabSplit.make(if (ghost.on_left) .{ t.id, partner.id } else .{ partner.id, t.id }, null, t.id);
            if (@import("split.zig").holds(p, self.tabs.items)) self.splits.append(self.gpa, p) catch {};
        };
    }
    if (regrouped) self.arrangeGroupedTabs(null);
    if (front) |t| self.select(t);
    if (self.last_clear) |c| if (c.batch.eql(batch)) {
        if (c.blank) |id| if (self.tabById(id)) |blank| if (blank.isBlank() and self.active_id != id) self.close(blank);
        self.last_clear = null;
    };
    self.rememberSession();
    self.redraw();
}

/// The group a tab coming back goes into: its own, while groups are on —
/// one Close Group took comes back first, opened, where it was.
fn regroup(self: *Browser, ghost: Ghost) struct { id: ?Uuid, back: bool } {
    if (!self.prefs.uses_tab_groups) return .{ .id = null, .back = false };
    const gid = ghost.group_id orelse return .{ .id = null, .back = false };
    var back = false;
    if (self.groupById(gid) == null) for (self.closed_groups.items, 0..) |c, i| if (c.group.id.eql(gid)) {
        var group = self.closed_groups.orderedRemove(i);
        group.group.collapsed = false;
        self.tab_groups.insert(self.gpa, @min(group.at, self.tab_groups.items.len), group.group) catch @panic("OOM");
        back = true;
        break;
    };
    return .{ .id = if (self.groupById(gid) != null) gid else null, .back = back };
}
