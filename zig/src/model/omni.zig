//! The address field's model (`Browser.swift`): `Omni` (296-330), "guessing"
//! and "the address field" (3873-4163), and "the address, in the tab itself"
//! (1300-1369). Its functions are `Browser`'s methods through the decls there.
//! Swift's `didSet`s are the setters here: `setTyped` guesses again, as
//! `Omni.typed` does; `setEditing(false)` takes the site chip away.
const std = @import("std");
const Browser = @import("browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const SearchSite = @import("../data/site_search.zig").SearchSite;
const history_text = @import("../data/history_text.zig");
const Suggestion = history_text.Suggestion;
const keywords = @import("../data/keywords.zig");
const Parts = @import("../data/url.zig").Parts;
const address = @import("address.zig");
const engine = @import("engine.zig");
const Command = @import("commands_address.zig").Command;
const commands = @import("commands_address.zig");

/// A row of the list (`Suggestion`), its strings in `Omni.arena`.
pub const Offer = struct {
    key: []const u8,
    title: []const u8,
    url: []const u8,
    kind: Kind,
    /// A page already open: naming it goes back to it.
    tab: ?u64 = null,
    command: ?Command = null,

    pub const Kind = enum { open, visited, known, search, command };
};

pub const Omni = struct {
    /// What was typed, on the browser's gpa.
    typed: std.ArrayList(u8) = .empty,
    site_offer: ?SearchSite = null,
    offers: []const Offer = &.{},
    /// The rest of the best match, after what was typed.
    ending: ?[]const u8 = null,
    /// The row Return goes to with none picked.
    landing: ?usize = null,
    picked: ?usize = null,
    /// Holds `offers`, their strings and `ending`: each guess starts it over.
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Omni {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(o: *Omni, gpa: std.mem.Allocator) void {
        o.typed.deinit(gpa);
        o.arena.deinit();
    }

    /// The picked row's key, or what was typed and its ending; on `a`.
    pub fn completed(o: *const Omni, a: std.mem.Allocator) []const u8 {
        if (o.picked) |p| if (p < o.offers.len) return o.offers[p].key;
        const e = o.ending orelse return o.typed.items;
        return std.mem.concat(a, u8, &.{ o.typed.items, e }) catch o.typed.items;
    }
};

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

/// `Omni.typed`'s `didSet`: what is offered follows what is typed.
pub fn setTyped(self: *Browser, text: []const u8) void {
    self.omni.typed.clearRetainingCapacity();
    self.omni.typed.appendSlice(self.gpa, text) catch @panic("OOM");
    self.guess();
}

/// `editing`'s `didSet`: the field put away takes its chip with it.
pub fn setEditing(self: *Browser, on: bool) void {
    self.editing = on;
    if (!on and self.site_chip != null) self.setChip(null);
}

/// `siteChip`'s `didSet`.
pub fn setChip(self: *Browser, site: ?SearchSite) void {
    const same = if (self.site_chip) |a| (if (site) |b| std.mem.eql(u8, a.host, b.host) and std.mem.eql(u8, a.template, b.template) else false) else site == null;
    self.site_chip = site;
    if (!same) self.guess();
}

/// `fieldShowing`: raised, or standing on a tab with nowhere to be yet.
pub fn fieldShowing(self: *Browser) bool {
    return self.editing or if (self.activeTab()) |t| t.isBlank() else true;
}

/// Put the cursor back in the field, from wherever asked.
pub fn askFocus(self: *Browser) void {
    self.focus_request +%= 1;
    self.redraw();
}

/// The default engine's search for `text`, on `gpa`.
pub fn searchURL(self: *Browser, gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    return engine.url(gpa, text, self.prefs.engine.template(self.prefs.custom_engine)) catch null;
}

/// Where Return takes `typed`, on `gpa`: the chip's site, an address, a
/// keyword's site, else the engine.
pub fn destination(self: *Browser, gpa: std.mem.Allocator, typed: []const u8) ?[]u8 {
    if (self.site_chip) |site| return engine.url(gpa, typed, site.template) catch null;
    if (address.url(gpa, typed) catch null) |u| return u;
    if (keywords.match(typed, self.prefs.keywords)) |m| if (engine.url(gpa, m.words, m.keyword.template) catch null) |u| return u;
    return self.searchURL(gpa, typed);
}

// MARK: - guessing

/// ⌘K again, with ⌘ still down: one step further down the list.
pub fn stepSummon(self: *Browser) void {
    self.cycling = true;
    self.walk(1);
}

/// ⌘ let go of: take whatever the walk landed on.
pub fn landSummon(self: *Browser) void {
    if (!self.cycling) return;
    self.cycling = false;
    if (self.omni.picked == null) return;
    self.submit(false, false);
}

/// ⌘K. Only what is open, nothing else.
pub fn summon(self: *Browser) void {
    self.cancelTabEdit();
    self.summoning = true;
    self.setTyped("");
    self.setEditing(true);
    self.askFocus();
}

fn asSuggestion(o: Offer) Suggestion {
    return .{ .key = o.key, .title = o.title, .url = o.url, .kind = switch (o.kind) {
        .open => .open,
        .visited => .visited,
        .known => .known,
        .search, .command => .search,
    } };
}

/// The row Return goes to with none picked, as `submit` decides it.
fn landing(self: *Browser) ?usize {
    const o = &self.omni;
    const a = o.arena.allocator();
    if (o.offers.len > 0 and o.offers[0].kind == .command) return 0;
    if (o.ending) |ending| {
        for (o.offers, 0..) |offer, i| {
            const rest = (self.history.completion(o.typed.items, &.{asSuggestion(offer)}) catch null) orelse continue;
            if (std.mem.eql(u8, rest, ending)) return i;
        }
        return null;
    }
    const target = self.destination(a, o.typed.items) orelse return null;
    const aim = history_text.identity(a, target) catch return null;
    for (o.offers, 0..) |offer, i| {
        const id = history_text.identity(a, offer.url) catch continue;
        if (std.mem.eql(u8, id, aim)) return i;
    }
    return null;
}

pub fn guess(self: *Browser) void {
    const o = &self.omni;
    _ = o.arena.reset(.retain_capacity);
    const a = o.arena.allocator();
    o.offers = &.{};
    o.ending = null;
    const typed = o.typed.items;

    if (self.summoning) {
        o.offers = openPages(self, a, typed);
        o.landing = null;
        o.site_offer = null;
        // The most recent page is already chosen: ⌘K then Return is the gesture.
        o.picked = if (o.offers.len == 0) null else 0;
        return;
    }

    // A site in the field: only its search, for what is typed after it.
    if (self.site_chip) |site| {
        o.site_offer = null;
        o.picked = null;
        const words = trimmed(typed);
        if (words.len > 0) if (engine.url(a, words, site.template) catch null) |u| {
            const one = a.alloc(Offer, 1) catch @panic("OOM");
            one[0] = .{ .key = a.dupe(u8, words) catch @panic("OOM"), .title = site.name, .url = u, .kind = .search };
            o.offers = one;
        };
        o.landing = landing(self);
        return;
    }

    if (trimmed(typed).len == 0) {
        o.landing = null;
        o.picked = null;
        o.site_offer = null;
        return;
    }
    // "red": Reddit's search, a Tab away.
    o.site_offer = if (self.prefs.searches_sites) self.kea.site_search.match(typed) else null;

    // Three places and, if it can't be a place, a search. No open pages: ⌘K
    // exists for those.
    var list: std.ArrayList(Offer) = .empty;
    const found = self.history.suggestions(a, typed, 3) catch &.{};
    for (found) |s| list.append(a, .{
        .key = a.dupe(u8, s.key) catch @panic("OOM"),
        .title = a.dupe(u8, s.title) catch @panic("OOM"),
        .url = a.dupe(u8, s.url) catch @panic("OOM"),
        .kind = switch (s.kind) {
            .open => .open,
            .visited => .visited,
            .known => .known,
            .search => .search,
        },
    }) catch @panic("OOM");
    // Last in the list, and only when what was typed cannot be a place.
    if ((address.url(a, typed) catch null) == null) {
        const asked: ?Offer = blk: {
            if (keywords.match(typed, self.prefs.keywords)) |m| if (engine.url(a, m.words, m.keyword.template) catch null) |u|
                break :blk .{ .key = a.dupe(u8, typed) catch @panic("OOM"), .title = m.keyword.name(a) catch "", .url = u, .kind = .search };
            const u = self.searchURL(a, typed) orelse break :blk null;
            break :blk .{ .key = a.dupe(u8, typed) catch @panic("OOM"), .title = self.prefs.engine.name(a, self.prefs.custom_engine) catch "", .url = u, .kind = .search };
        };
        if (asked) |s| list.append(a, s) catch @panic("OOM");
    }
    // First, not last: typing "settings" to reach Settings is the point.
    const command = if (self.prefs.command_bar) commands.matching(typed, self) else null;
    if (command) |cmd| list.insert(a, 0, .{ .key = cmd.title(), .title = "", .url = "about:blank", .kind = .command, .command = cmd }) catch @panic("OOM");
    o.offers = list.items;
    // Neither an open page nor a command has an address to complete
    // towards; with a command on top there is no ending at all.
    if (command == null) {
        var places: std.ArrayList(Suggestion) = .empty;
        for (o.offers) |offer| if (offer.kind != .open and offer.kind != .command) places.append(a, asSuggestion(offer)) catch @panic("OOM");
        o.ending = self.history.completion(typed, places.items) catch null;
    }
    // A picked row stops being the right row the moment the question changes.
    o.picked = null;
    o.landing = landing(self);
}

/// What is open, most recently looked at first, filtered by every word
/// typed in its label or address: six on an empty field, else three.
fn openPages(self: *Browser, a: std.mem.Allocator, typed: []const u8) []const Offer {
    const low = std.ascii.allocLowerString(a, typed) catch return &.{};
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, low, ' ');
    while (it.next()) |w| words.append(a, w) catch return &.{};
    var found: std.ArrayList(*Tab) = .empty;
    for (self.tabs.items) |t| {
        if (t.id == self.active_id or t.isBlank()) continue;
        const label = std.ascii.allocLowerString(a, t.label()) catch continue;
        const pretty = address.pretty(a, t.url()) catch continue;
        const where = std.ascii.allocLowerString(a, pretty) catch continue;
        const all = for (words.items) |w| {
            if (std.mem.indexOf(u8, label, w) == null and std.mem.indexOf(u8, where, w) == null) break false;
        } else true;
        if (all) found.append(a, t) catch break;
    }
    std.mem.sort(*Tab, found.items, {}, struct {
        fn newer(_: void, x: *Tab, y: *Tab) bool {
            return x.touched > y.touched;
        }
    }.newer);
    const n = @min(found.items.len, if (words.items.len == 0) @as(usize, 6) else 3);
    const out = a.alloc(Offer, n) catch return &.{};
    for (found.items[0..n], out) |t, *offer| offer.* = .{
        .key = a.dupe(u8, t.label()) catch "",
        .title = address.pretty(a, t.url()) catch "",
        .url = a.dupe(u8, t.url()) catch "",
        .kind = .open,
        .tab = t.id,
    };
    return out;
}

/// A row clicked: taken directly, apart from the keyboard's pick.
pub fn takeOffer(self: *Browser, offer: Offer) void {
    self.summoning = false;
    if (offer.command) |cmd| {
        cmd.run(self);
    } else if (if (offer.tab) |id| self.tabById(id) else null) |t| {
        if (fillsPane(self, t, false)) |blank| return self.fill(blank, t);
        self.select(t);
    } else if (self.activeTab() orelse if (self.tabs.items.len > 0) self.tabs.items[0] else null) |t| {
        t.go(offer.url);
    }
    self.setEditing(false);
    self.setTyped("");
    self.omni.picked = null;
    self.redraw();
}

/// A backspace means the ending was not wanted: not put back on this keystroke.
pub fn stopCompleting(self: *Browser) void {
    self.omni.ending = null;
    self.omni.landing = landing(self);
}

/// Tab with a site offered: the site goes into the field as a chip, and
/// what was typed to name it is let go. True when it did.
pub fn lockSiteOffer(self: *Browser) bool {
    if (!self.prefs.searches_sites or self.site_chip != null) return false;
    const site = self.omni.site_offer orelse return false;
    self.omni.site_offer = null;
    self.setTyped("");
    self.setChip(site);
    self.redraw();
    return true;
}

/// The arrow keys walk the list; walking off either end lets go of it.
pub fn walk(self: *Browser, step: i32) void {
    const o = &self.omni;
    const count: i64 = @intCast(o.offers.len);
    if (count == 0) return;
    if (o.picked) |here| {
        const next = @as(i64, @intCast(here)) + step;
        o.picked = if (next < 0 or next >= count) null else @intCast(next);
    } else {
        o.picked = if (step > 0) 0 else @intCast(count - 1);
    }
    self.redraw();
}

// MARK: - the address field

/// ⌘L. The current address comes up selected, never with a name and
/// password in it.
pub fn edit(self: *Browser) void {
    self.summoning = false;
    var made: ?[]u8 = null;
    defer if (made) |m| self.gpa.free(m);
    var text: []const u8 = "";
    if (self.activeTab()) |t| if (t.address) |page| {
        text = page;
        if (Parts.parse(page)) |parts| if (parts.user != null or parts.password != null) {
            var bare = parts;
            bare.user = null;
            bare.password = null;
            made = bare.string(self.gpa) catch null;
            text = made orelse "";
        };
    };
    self.setTyped(text);
    self.setEditing(true);
    self.askFocus();
}

pub fn dismiss(self: *Browser) void {
    self.summoning = false;
    self.cycling = false;
    defer self.redraw();
    // Esc with a site in the field: the site goes, the field stays.
    if (self.site_chip != null) return self.setChip(null);
    const t = self.activeTab() orelse return;
    // Esc on the empty page of a pair: the page isn't wanted after all.
    if (t.isBlank() and self.inSplit(t)) {
        self.setEditing(false);
        self.setTyped("");
        return self.close(t);
    }
    // A blank tab has nothing behind the field to go back to.
    if (t.isBlank()) return;
    self.setEditing(false);
    self.setTyped("");
}

/// Return. A picked row wins, then what the field was finishing, then what
/// was typed; if none is a place, the field says so (`refusals`). `aside`
/// (⌘Return) opens it in a new tab, behind unless `front` (⇧⌘Return).
pub fn submit(self: *Browser, aside: bool, front: bool) void {
    const o = &self.omni;
    defer self.redraw();
    const picked: ?Offer = if (o.picked) |p| (if (p < o.offers.len) o.offers[p] else null) else null;
    // A page already open is switched to, not opened again.
    if (picked) |pk| if (if (pk.tab) |id| self.tabById(id) else null) |t| {
        self.summoning = false;
        // From the empty page of a pair: that tab comes into the pair.
        if (fillsPane(self, t, aside)) |blank| return self.fill(blank, t);
        self.select(t);
        self.setEditing(false);
        self.setTyped("");
        return;
    };
    // The switcher still takes an address typed into it.
    if (self.summoning) {
        self.summoning = false;
        if (trimmed(o.typed.items).len == 0) return self.setEditing(false);
    }
    // A command is only ever on top, and there it is what Return does.
    const chosen: ?Offer = picked orelse if (o.offers.len > 0) o.offers[0] else null;
    if (chosen) |ch| if (ch.command) |cmd| {
        cmd.run(self);
        self.setEditing(false);
        self.setTyped("");
        self.omni.picked = null;
        return;
    };
    const gpa = self.gpa;
    const target: ?[]u8 = if (picked) |pk|
        gpa.dupe(u8, pk.url) catch null
    else if (o.ending) |ending| blk: {
        const whole = std.mem.concat(gpa, u8, &.{ o.typed.items, ending }) catch break :blk null;
        defer gpa.free(whole);
        break :blk address.url(gpa, whole) catch null;
    } else self.destination(gpa, o.typed.items);
    const url = target orelse {
        self.refusals +%= 1;
        return;
    };
    defer gpa.free(url);
    if (aside) {
        // Behind the page by hand, as a ⌘-clicked link: it may wait to load.
        _ = self.open(url, .{ .foreground = front, .from = self.activeTab(), .may_wait = true });
    } else if (self.activeTab() orelse if (self.tabs.items.len > 0) self.tabs.items[0] else null) |t| {
        t.go(url);
    }
    self.setEditing(false);
    self.setTyped("");
}

/// The empty page of a pair in front that `tab` would come into.
fn fillsPane(self: *Browser, tab: *Tab, aside: bool) ?*Tab {
    const blank = self.activeTab() orelse return null;
    if (aside or !blank.isBlank() or tab.shy != blank.shy) return null;
    _ = self.splitFor(blank) orelse return null;
    if (self.splitFor(tab)) |s| if (s.contains(blank.id)) return null;
    return blank;
}

/// What a new tab, or the empty one ⌘T came back to, starts the field with.
pub fn freshField(self: *Browser, blank: *Tab) void {
    self.summoning = false;
    self.setTyped("");
    blank.own(&blank.draft, null);
    self.setEditing(false);
    self.askFocus();
}

// MARK: - the address, in the tab itself

/// Clicking the tab you are on turns it into its address, short form.
pub fn beginTabEdit(self: *Browser, tab: *Tab) void {
    const page = tab.address orelse return self.edit();
    self.renaming_tab = false;
    const short = address.editable(self.gpa, page) catch return;
    defer self.gpa.free(short);
    self.tab_draft.set(short);
    self.editing_tab = tab.id;
    self.redraw();
}

/// Rename: the name it wears arrives selected; emptied, the page's own
/// title comes back.
pub fn beginTabRename(self: *Browser, tab: *Tab) void {
    self.renaming_tab = true;
    self.tab_draft.set(tab.label());
    self.editing_tab = tab.id;
    self.redraw();
}

pub fn commitTabEdit(self: *Browser) void {
    const tab = self.tabById(self.editing_tab orelse return) orelse return;
    defer self.redraw();
    if (self.renaming_tab) {
        const typed = std.mem.trim(u8, self.tab_draft.text(), " \t\r\n");
        tab.setName(if (typed.len == 0) null else typed);
        self.cancelTabEdit();
        self.writeSession(true);
        return;
    }
    // Stay put and say so, rather than quietly throwing the edit away.
    const url = self.destination(self.gpa, self.tab_draft.text()) orelse {
        self.refusals +%= 1;
        return;
    };
    defer self.gpa.free(url);
    self.editing_tab = null;
    tab.go(url);
}

pub fn cancelTabEdit(self: *Browser) void {
    if (self.editing_tab == null and !self.renaming_tab and self.tab_draft.text().len == 0) return;
    self.editing_tab = null;
    self.renaming_tab = false;
    self.tab_draft.clear();
    self.redraw();
}

/// A click elsewhere: what was typed is kept, as Return keeps it; an
/// address left as it was loads nothing again, an empty field is let go.
pub fn finishTabEdit(self: *Browser) void {
    const tab = self.tabById(self.editing_tab orelse return) orelse return;
    if (self.renaming_tab) return self.commitTabEdit();
    const gpa = self.gpa;
    const draft = std.mem.trim(u8, self.tab_draft.text(), " \t\r\n");
    const same = if (tab.address) |page| blk: {
        const short = address.editable(gpa, page) catch break :blk false;
        defer gpa.free(short);
        break :blk std.mem.eql(u8, short, draft);
    } else false;
    const goes = if (self.destination(gpa, draft)) |u| blk: {
        gpa.free(u);
        break :blk true;
    } else false;
    if (draft.len == 0 or same or !goes) return self.cancelTabEdit();
    self.commitTabEdit();
}
