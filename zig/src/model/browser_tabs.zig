//! Browser.swift "tabs" (2330-3046, 3255-3480, 3740-3800): the row in the
//! order it is shown, opening, picking, moving, ⌘1–9 and ⌃Tab, and moving
//! a tab to another space. A pair's pages share one place (model/split.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const address = @import("address.zig");

// MARK: what the row shows

/// `displayedTabs`: one place per tab, a pair's at its first page. Valid
/// until the next call (it reuses `Browser.displayed`).
pub fn displayedTabs(self: *Browser) []*Tab {
    if (!self.prefs.split_view or self.splits.items.len == 0) return self.tabs.items;
    self.displayed.clearRetainingCapacity();
    for (self.tabs.items) |t| if (self.standsInRow(t)) self.displayed.append(self.gpa, t) catch @panic("OOM");
    return self.displayed.items;
}

/// `shownTabs`: the tabs as they are on screen — with groups on, not the
/// ones folded away. ⌘1–9 and ⌃Tab count these. On `gpa`, the caller's.
pub fn shownTabs(self: *Browser, gpa: std.mem.Allocator) ![]*Tab {
    if (!self.prefs.uses_tab_groups) return gpa.dupe(*Tab, self.displayedTabs());
    var out: std.ArrayList(*Tab) = .empty;
    errdefer out.deinit(gpa);
    for (self.displayedTabs()) |t| if (t.pin != null) try out.append(gpa, t);
    for (self.tab_groups.items) |g| {
        const shown = try self.visibleTabsIn(gpa, g);
        defer gpa.free(shown);
        try out.appendSlice(gpa, shown);
    }
    const loose = try self.tabsIn(gpa, null);
    defer gpa.free(loose);
    for (loose) |t| if (self.standsInRow(t)) try out.append(gpa, t);
    return out.toOwnedSlice(gpa);
}

/// `visibleTabIDs`: the page on screen, and its pair's other page.
pub fn visibleTabIDs(self: *Browser) [2]u64 {
    if (self.active_id == 0) return .{ 0, 0 };
    const p = self.activeSplit() orelse return .{ self.active_id, 0 };
    return p.tabs;
}

fn visible(self: *Browser, id: u64) bool {
    const ids = self.visibleTabIDs();
    return id != 0 and (ids[0] == id or ids[1] == id);
}

pub fn indexOf(self: *Browser, tab: *const Tab) ?usize {
    for (self.tabs.items, 0..) |t, i| if (t == tab) return i;
    return null;
}

// MARK: making tabs

/// `prepare`: the browser hears what the tab says (`tabChanged` and the
/// delegates in `web/delegates_*.zig`).
pub fn prepare(self: *Browser, t: *Tab) void {
    t.browser = self;
    t.favicons = self.kea.favicons;
}

/// A tab in this window's space, its page built: blank, or loading `url`.
pub fn make(self: *Browser, url: []const u8, shy: bool) *Tab {
    const store = if (shy) null else self.kea.dataStore(self.space_id);
    const t = Tab.create(self.gpa, self.kea.tabId(), shy, store, self.kea) catch @panic("OOM");
    // Heard before its first load, so the visit is the browser's to record.
    self.prepare(t);
    if (url.len > 0) t.go(url);
    return t;
}

/// A tab with its address and nothing fetched (`restore(url:title:name:)`),
/// in `space`.
pub fn makeAsleep(self: *Browser, url: []const u8, title: []const u8, name: ?[]const u8, space: Uuid) *Tab {
    const t = Tab.createAsleep(self.gpa, self.kea.tabId(), url, title, name, self.kea) catch @panic("OOM");
    t.data_store = self.kea.dataStore(space);
    self.prepare(t);
    return t;
}

/// At the end of the row, in front if nothing is.
pub fn adopt(self: *Browser, t: *Tab) void {
    self.tabs.append(self.gpa, t) catch @panic("OOM");
    if (self.active_id == 0) self.active_id = t.id;
    self.arrangeGroupedTabs(null);
}

/// `activeID`'s `didSet`: the tab just left is the tab just looked at, and
/// a question the new one asked in the background is asked now.
pub fn setActive(self: *Browser, id: u64) void {
    if (id == self.active_id) return;
    const old = self.active_id;
    if (self.tabById(old)) |left| left.touch();
    self.active_id = id;
    @import("split.zig").activeMoved(self, old, id);
    // The switcher's order, most recently used first.
    if (old != 0) @import("../chrome/tab_switcher.zig").leftTab(self, old);
    // What was found belongs to the page just left; the words go on.
    @import("../web/page_find.zig").invalidatePage(self, true);
    @import("../chrome/link_bubble.zig").dismiss(self);
    if (self.tabById(id)) |front| @import("../web/dialogs.zig").presentHeld(front);
    self.handOff();
}

/// A tab's page off the stage, then the tab gone (`tab.close()`).
pub fn letGo(self: *Browser, t: *Tab) void {
    if (self.stage_host) |sh| if (t.web) |wv| sh.forget(wv);
    if (self.editing_pin == t.id) self.editing_pin = null;
    if (self.editing_tab == t.id) self.cancelTabEdit();
    t.destroy();
}

pub const OpenOptions = struct {
    foreground: bool,
    /// At the end of the row rather than beside the tab in front.
    at_end: bool = false,
    /// The tab it was opened out of: a private one's opens private, and a
    /// grouped one's joins its group.
    from: ?*Tab = null,
    /// Opened behind by hand: with Load background tabs when you go to
    /// them on, it loads nothing until it is gone to.
    may_wait: bool = false,
};

/// `open(_:foreground:atEnd:from:mayWait:)`: a link opened from a page lands
/// next to the page it came from.
pub fn open(self: *Browser, url: []const u8, o: OpenOptions) *Tab {
    const shy = if (o.from) |s| s.shy else false;
    const t = if (o.may_wait and !o.foreground and self.prefs.lazy_tabs) blk: {
        const asleep = self.makeAsleep(url, "", null, self.space_id);
        asleep.shy = shy;
        break :blk asleep;
    } else self.make(url, shy);
    if (self.prefs.uses_tab_groups and !t.shy) if (o.from) |s| {
        t.group_id = s.group_id;
    };
    self.tabs.insert(self.gpa, if (o.at_end) self.tabs.items.len else self.placeForNew(), t) catch @panic("OOM");
    self.arrangeGroupedTabs(null);
    if (o.foreground) {
        self.setActive(t.id);
        self.setEditing(false);
        self.setTyped("");
    }
    self.rememberSession();
    self.redraw();
    return t;
}

/// ⌘T. On a private tab a private one; never two empty tabs: one already
/// in the row comes to its end and is the one opened.
pub fn newTab(self: *Browser) void {
    if (self.tabById(self.active_id)) |a| if (a.shy) return self.newShyTab();
    var i = self.tabs.items.len;
    while (i > 0) {
        i -= 1;
        const blank = self.tabs.items[i];
        if (!blank.isBlank() or blank.shy or self.inSplit(blank)) continue;
        if (i != self.tabs.items.len - 1) self.move(blank, self.tabs.items.len - 1);
        self.setActive(blank.id);
        self.freshField(blank);
        self.rememberSession();
        return self.redraw();
    }
    const t = self.make("", false);
    self.adopt(t);
    self.setActive(t.id);
    self.freshField(t);
    self.rememberSession();
    self.redraw();
}

/// ⌘⇧N. A tab that keeps nothing; never two empty ones.
pub fn newShyTab(self: *Browser) void {
    var i = self.tabs.items.len;
    while (i > 0) {
        i -= 1;
        const blank = self.tabs.items[i];
        if (!blank.isBlank() or !blank.shy) continue;
        if (i != self.tabs.items.len - 1) self.move(blank, self.tabs.items.len - 1);
        self.setActive(blank.id);
        self.freshField(blank);
        return self.redraw();
    }
    const t = self.make("", true);
    self.adopt(t);
    self.setActive(t.id);
    self.freshField(t);
    self.announce("A tab that keeps nothing");
}

/// ⌘D. The same page, beside itself.
pub fn duplicate(self: *Browser) void {
    const a = self.tabById(self.active_id) orelse return;
    if (a.isBlank()) return;
    var buf: [2048]u8 = undefined;
    const url = buf[0..a.url().len];
    @memcpy(url, a.url());
    _ = self.open(url, .{ .foreground = true, .from = a });
}

/// A link from another app: a blank tab takes it, otherwise a tab of its own.
pub fn arrive(self: *Browser, url: []const u8) void {
    if (self.tabById(self.active_id)) |a| if (a.isBlank() and self.omni.typed.items.len == 0) {
        a.go(url);
        self.setEditing(false);
        return self.redraw();
    };
    _ = self.open(url, .{ .foreground = true });
}

/// A bookmark: into the tab you are on — into a new one with ⌘ held
/// (`apart`; Swift reads the current event's modifiers).
pub fn visit(self: *Browser, url: []const u8, apart: bool) void {
    const a = self.tabById(self.active_id);
    if (a != null and !apart) {
        a.?.go(url);
        self.setEditing(false);
        self.setTyped("");
        return self.redraw();
    }
    _ = self.open(url, .{ .foreground = true, .from = a });
}

// MARK: picking

/// `select(_:floatPrevious:)`. Within the pair on screen, a focus change;
/// otherwise its folded group opens and a page asleep wakes.
pub fn select(self: *Browser, tab: *Tab) void {
    if (self.splitFor(tab)) |s| if (self.activeSplit()) |front| if (s.id.eql(front.id) and self.active_id != tab.id) {
        return self.focusPane(tab);
    };
    if (self.prefs.uses_tab_groups) if (tab.group_id) |gid| if (self.groupById(gid)) |g| if (g.collapsed) {
        g.collapsed = false;
        self.writeSession(true);
    };
    // A peek is over the tab it was opened from; another tab puts it away.
    if (self.peek_tab != null and tab.id != self.active_id) self.closePeek();
    // Its words were a draft for the blank tab it was typed on, unless ⌘K's.
    if (tab.id != self.active_id and !self.summoning) if (self.tabById(self.active_id)) |here| if (here.isBlank()) {
        here.own(&here.draft, self.omni.typed.items);
    };
    self.cancelTabEdit();
    self.summoning = false;
    if (tab.id == self.active_id) return self.redraw();
    // The tab whose video is out comes home first; the one left may float.
    @import("../web/float.zig").selecting(self, tab);
    self.setActive(tab.id);
    tab.touch();
    // A tab brought back from last time opens the moment you look at it.
    if (!tab.wake()) tab.revive();
    if (self.activeSplit()) |p| if (self.tabById(p.partner(tab.id).?)) |other| {
        if (!other.isBlank() and !other.wake()) other.revive();
    };
    self.rememberSession();
    self.setEditing(false);
    self.setTyped(if (tab.isBlank()) tab.draft orelse "" else "");
    self.redraw();
}

/// ⌘1–8: the tab in that place on screen — a pair's page that had the keys last.
pub fn selectIndex(self: *Browser, index: usize) void {
    const shown = self.shownTabs(self.gpa) catch return;
    defer self.gpa.free(shown);
    if (index < shown.len) self.select(self.entry(shown[index]));
}

/// ⌃Tab, ⌃⇧Tab: the next tab on screen, round to the first again. It walks
/// the whole row from the tab you are on, so it finds its way out even
/// from one the row doesn't show.
pub fn step(self: *Browser, direction: isize) void {
    const shown = self.shownTabs(self.gpa) catch return;
    defer self.gpa.free(shown);
    const anchor = self.tabById(if (self.activeSplit()) |p| p.left() else self.active_id) orelse return;
    const has_anchor = std.mem.indexOfScalar(*Tab, shown, anchor) != null;
    if (!(shown.len > 1 or (shown.len == 1 and !has_anchor))) return;
    const here: isize = @intCast(self.indexOf(anchor) orelse return);
    const n: isize = @intCast(self.tabs.items.len);
    var k: isize = 1;
    while (k < n) : (k += 1) {
        const next = self.tabs.items[@intCast(@mod(here + direction * k, n))];
        if (std.mem.indexOfScalar(*Tab, shown, next) != null) return self.select(self.entry(next));
    }
}

// MARK: moving

/// Dragged from one place in the row to another.
pub fn move(self: *Browser, tab: *Tab, index: usize) void {
    if (index >= self.tabs.items.len) return;
    const target = self.tabs.items[index];
    // A pair stands in the row as its first page.
    const rep = if (self.splitFor(target)) |p| self.tabById(p.left()) orelse target else target;
    const destination = std.mem.indexOfScalar(*Tab, self.displayedTabs(), rep) orelse return;
    self.moveDisplayedTab(tab, destination);
}

/// `moveDisplayedTab`: among the row's places; a pin among pins, a tab
/// among tabs; a pair moves whole and steps over a pair whole.
pub fn moveDisplayedTab(self: *Browser, tab: *Tab, index: usize) void {
    const shown = self.displayedTabs();
    if (index >= shown.len) return;
    const pair = self.splitFor(tab);
    const representative = self.tabById(if (pair) |p| p.left() else tab.id) orelse return;
    const from = std.mem.indexOfScalar(*Tab, shown, representative) orelse return;
    if (from == index) return;
    const anchor = shown[index];
    var moving_buf: [2]*Tab = undefined;
    var moving: []*Tab = moving_buf[0..1];
    moving_buf[0] = tab;
    if (pair) |p| {
        moving_buf = .{ self.tabById(p.left()) orelse return, self.tabById(p.right()) orelse return };
        moving = moving_buf[0..2];
        // In the row's order, whichever page was carried.
        if (self.indexOf(moving_buf[0]).? > self.indexOf(moving_buf[1]).?) std.mem.swap(*Tab, &moving_buf[0], &moving_buf[1]);
    }
    for (moving) |m| if ((m.pin == null) != (anchor.pin == null)) return;
    if (!joins(self, tab, anchor)) return;
    for (moving) |m| _ = self.tabs.orderedRemove(self.indexOf(m).?);
    const target = self.indexOf(anchor).?;
    const size: usize = if (self.splitFor(anchor) == null) 1 else 2;
    self.tabs.insertSlice(self.gpa, if (from < index) target + size else target, moving) catch @panic("OOM");
    self.arrangeGroupedTabs(null);
    self.rememberSession();
    self.redraw();
}

/// Whether a pin carried onto another may land there: with the rows shown,
/// a square among squares and a row among rows; with them off, it becomes
/// the kind it landed among.
fn joins(self: *Browser, tab: *Tab, anchor: *const Tab) bool {
    if (tab.pin == null or anchor.pin == null or tab.listed == anchor.listed) return true;
    if (self.prefs.showsPinRows()) return false;
    tab.listed = anchor.listed;
    return true;
}

/// Let go in the strip: before `target` (a pair's, before its first page),
/// taking its group, or with none at the end of its kind; out of its pair.
pub fn dropTabIntoStrip(self: *Browser, tab: *Tab, before: ?*Tab) void {
    const source = self.indexOf(tab) orelse return;
    if (before) |target| {
        if (target == tab) return;
        const target_index = self.indexOf(target) orelse return;
        if (self.partnerOf(tab) == target) return;
        if ((tab.pin == null) != (target.pin == null) or !joins(self, tab, target)) return;
        const start = if (self.splitFor(target)) |p| (if (self.tabById(p.left())) |l| self.indexOf(l).? else target_index) else target_index;
        self.detachSplit(tab);
        const previous = tab.group_id;
        tab.group_id = target.group_id;
        _ = self.tabs.orderedRemove(source);
        self.tabs.insert(self.gpa, if (source < start) start - 1 else start, tab) catch @panic("OOM");
        self.removeEmptyGroup(previous);
    } else {
        self.detachSplit(tab);
        _ = self.tabs.orderedRemove(source);
        var place = self.tabs.items.len;
        if (tab.pin != null) {
            place = 0;
            for (self.tabs.items) |t| {
                if (t.pin != null and (tab.listed or !t.listed)) place += 1;
            }
        }
        self.tabs.insert(self.gpa, place, tab) catch @panic("OOM");
    }
    self.arrangeGroupedTabs(null);
    self.rememberSession();
    self.redraw();
}

/// Where a new tab goes: beside the tab you are on (past its pair), but
/// never among the pins.
pub fn placeForNew(self: *Browser) usize {
    const here = self.indexOf(self.tabById(self.active_id) orelse return self.tabs.items.len).?;
    var after = here;
    if (self.activeSplit()) |p| if (self.tabById(p.right())) |r| {
        after = self.indexOf(r).?;
    };
    return @max(after + 1, self.pinnedCount());
}

/// A tab made outside the row — a peek being kept — put in it at `index`,
/// never between a pair's pages (`safeInsertionIndex`).
pub fn insert(self: *Browser, tab: *Tab, index: usize) void {
    self.prepare(tab);
    var at = @min(index, self.tabs.items.len);
    if (at < self.tabs.items.len and !self.standsInRow(self.tabs.items[at])) at += 1;
    self.tabs.insert(self.gpa, at, tab) catch @panic("OOM");
    self.arrangeGroupedTabs(null);
    self.rememberSession();
}

// MARK: a tab to another space

/// `move(_:toSpace:)`: out of this row and into the space's, reopening with
/// its sign-ins. Swift first asks when the page has unsaved form entries;
/// that needs the form relay, which arrives with P10.
pub fn moveToSpace(self: *Browser, tab: *Tab, id: Uuid) void {
    if (!self.prefs.uses_spaces or id.eql(self.space_id)) return;
    const at = self.kea.spaceIndex(id) orelse return;
    const index = self.indexOf(tab) orelse return;
    const partner = self.partnerOf(tab);
    self.detachSplit(tab);
    if (self.active_id == tab.id) {
        if (partner) |p| {
            self.select(p);
        } else if (self.tabs.items.len > 1) {
            self.select(self.tabs.items[if (index == self.tabs.items.len - 1) index - 1 else index + 1]);
        } else self.active_id = 0;
    }
    _ = self.tabs.orderedRemove(index);
    self.removeEmptyGroup(tab.group_id);
    if (self.tabs.items.len == 0) self.adopt(self.make("", false));
    if (self.active_id == 0) self.active_id = self.tabs.items[0].id;
    if (self.stage_host) |sh| if (tab.web) |wv| sh.forget(wv);
    tab.rehome(self.kea.dataStore(id));
    // Its group stays behind: the space it goes to has groups of its own.
    tab.group_id = null;
    if (!self.parked.contains(id)) {
        const fresh = self.loadRow(id);
        self.parked.put(self.gpa, id, fresh) catch @panic("OOM");
    }
    const row = self.parked.getPtr(id).?;
    var place = row.tabs.items.len;
    if (tab.pin != null) for (row.tabs.items, 0..) |t, i| if (t.pin == null) {
        place = i;
        break;
    };
    row.tabs.insert(self.gpa, place, tab) catch @panic("OOM");
    if (row.active == 0) row.active = tab.id;
    self.writeSession(true);
    self.writeParked(true, id, row);
    const said = std.fmt.allocPrint(self.gpa, "Moved to {s}", .{self.kea.spaces.value[at].name}) catch return self.redraw();
    defer self.gpa.free(said);
    self.announce(said);
    self.redraw();
}

// MARK: links dragged in, and the address copied

/// A page decides what a link dragged out of it carries: never script,
/// nor an extension's page, which would open with that extension's powers.
fn refused(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    const scheme = url[0..colon];
    for ([_][]const u8{ "javascript", "chrome-extension", "webkit-extension" }) |s| {
        if (std.ascii.eqlIgnoreCase(scheme, s)) return true;
    }
    return false;
}

/// `take(_:)`: links, or text that reads as an address, dropped on the
/// strip or the column, each opened in front. True when it held any.
pub fn take(self: *Browser, drop: nanoui.ui.Drop) bool {
    for (drop.urls) |u| if (!refused(u)) {
        _ = self.open(u, .{ .foreground = true });
    };
    if (drop.urls.len > 0) return true;
    if (drop.text.len == 0) return false;
    const u = address.url(self.gpa, drop.text) catch return true;
    if (u) |owned| {
        defer self.gpa.free(owned);
        if (!refused(owned)) _ = self.open(owned, .{ .foreground = true });
    }
    return true;
}

/// ⌘⇧C. The address, in the clipboard, and a line that says as much.
pub fn copyAddress(self: *Browser) void {
    const t = self.activeTab() orelse return;
    if (t.isBlank()) return;
    nanoui.clipboard.writeText(t.url());
    self.announce("Address copied");
}

/// A title that links: backslashes first, so the ones added next aren't
/// doubled, then both brackets, either of which would break the link.
pub fn copyMarkdownLink(self: *Browser) void {
    const t = self.activeTab() orelse return;
    if (t.isBlank()) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.gpa);
    out.append(self.gpa, '[') catch return;
    for (t.label()) |ch| {
        if (ch == '\\' or ch == '[' or ch == ']') out.append(self.gpa, '\\') catch return;
        out.append(self.gpa, ch) catch return;
    }
    out.print(self.gpa, "]({s})", .{t.url()}) catch return;
    nanoui.clipboard.writeText(out.items);
    self.announce("Link copied");
}

/// ⌘⇧V, when nothing is being typed. What is in the clipboard, if it is a
/// place — or a search — in the tab you're on.
pub fn pasteAndGo(self: *Browser) void {
    const text = (nanoui.clipboard.readText(self.gpa) catch null) orelse {
        self.refusals += 1;
        return self.redraw();
    };
    defer self.gpa.free(text);
    const url = self.destination(self.gpa, std.mem.trim(u8, text, " \t\r\n")) orelse {
        self.refusals += 1;
        return self.redraw();
    };
    defer self.gpa.free(url);
    const t = self.activeTab() orelse (if (self.tabs.items.len > 0) self.tabs.items[0] else return);
    t.go(url);
    self.setEditing(false);
    self.omni.typed.clearRetainingCapacity();
    self.redraw();
}

/// ⌘⇧M. Whatever is making noise in this tab stops making noise.
pub fn pauseMedia(self: *Browser) void {
    const t = self.activeTab() orelse return;
    if (t.web) |wv| objc.msg(void, wv, "pauseAllMediaPlaybackWithCompletionHandler:", .{@as(?*anyopaque, null)});
    self.announce("Paused");
}
