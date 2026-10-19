//! Browser model: one window's `Tab` list, Split View (`split_right_id`,
//! `split_fraction`, `focused_pane`), the Bookmarks side panel, Omnibox
//! autocomplete/chip/suggestions, Find on Page, and `StageHost` sync. The
//! stores it reads (`prefs`, `history`, `bookmarks`) are shared on `Kea`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Kea = @import("../app/kea.zig").Kea;
const Store = @import("../data/store.zig").Store;
const Prefs = @import("../data/prefs.zig").Prefs;
const History = @import("../data/history.zig").History;
const Bookmarks = @import("../data/bookmarks.zig").Bookmarks;
const SearchSite = @import("../data/site_search.zig").SearchSite;
const Parts = @import("../data/url.zig").Parts;
const Tab = @import("../web/tab.zig").Tab;
const StageHost = @import("../web/stage_host.zig").StageHost;
const Lights = @import("../chrome/lights.zig").Lights;
const browsers = @import("../app/browsers.zig");
const session = @import("../data/session.zig");
const Uuid = @import("../data/json.zig").Uuid;
const overlays = @import("../chrome/overlays.zig");
const room = @import("../chrome/room.zig");
const EdgeDrag = @import("../chrome/panels.zig").EdgeDrag;

pub const PaneFocus = enum { left, right };

pub const ClosedTab = struct {
    url: [2048]u8 = undefined,
    url_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    /// When it closed (`ui.clock`), weighed against a closed window's for ⇧⌘T.
    at: f64 = 0,
};

pub const Browser = struct {
    kea: *Kea,
    gpa: std.mem.Allocator,
    window: ?*nanoui.Window = null,
    stage_host: ?*StageHost = null,
    lights: ?*Lights = null,
    /// Its window's line in `windows.json` (`WindowRecord.id`).
    record_id: Uuid,
    /// The oldest window's rows live in the session files; any other's in
    /// its line of `windows.json` (`Browser.usesFiles`).
    uses_files: bool,
    /// The last window, closed with the app running: kept, tabs and all.
    shut: bool = false,

    // Shared with every window, owned by `kea`.
    store: *Store,
    prefs: *Prefs,
    history: *History,
    bookmarks: *Bookmarks,

    tabs: std.ArrayList(*Tab) = .empty,
    closed_tabs: std.ArrayList(ClosedTab) = .empty,
    next_tab_id: u64 = 1,
    active_id: u64 = 0,
    /// Restoring the session: nothing is written until it's done.
    restoring: bool = false,

    // Split View state
    split_right_id: ?u64 = null,
    split_fraction: f32 = 0.5,
    focused_pane: PaneFocus = .left,

    // Bookmarks side panel
    marks_open: bool = false,
    marks_expanded: bool = false,
    marks_filter_buf: ui.TextBuffer = .{},

    // Omnibox state
    omni_open: bool = false,
    omni_buf: ui.TextBuffer = .{},
    omni_chip: ?SearchSite = null,
    omni_selected: usize = 0,
    omni_offer: [256]u8 = undefined,
    omni_offer_len: usize = 0,
    omni_typed: [256]u8 = undefined,
    omni_typed_len: usize = 0,

    // Find in page state
    find_open: bool = false,
    find_buf: ui.TextBuffer = .{},
    find_matches: usize = 0,

    // Toast
    toast_buf: [256]u8 = undefined,
    toast_len: usize = 0,
    toast_until: f64 = 0,

    // Page holes from the last frame (the split divider drags against them).
    active_page_frame: ui.Rect = .{},
    left_pane_frame: ui.Rect = .{},
    right_pane_frame: ui.Rect = .{},

    // The window (ContentView): what is open over it, the ground last
    // given to its NSWindow, the room the page leaves, an edge being pulled.
    overlay: ?overlays.Overlay = null,
    overlay_anchor: ui.Rect = .{},
    applied_ground: ?ui.Color = null,
    room: room.State = .{},
    edge_drag: ?EdgeDrag = null,

    /// `rows` null: the oldest window, its tabs from the session files.
    /// Otherwise a window's own row (empty for a new window).
    pub fn create(kea: *Kea, rows: ?session.Shape) !*Browser {
        const self = try kea.gpa.create(Browser);
        self.* = .{
            .kea = kea,
            .gpa = kea.gpa,
            .store = &kea.store,
            .prefs = &kea.prefs,
            .history = &kea.history,
            .bookmarks = &kea.bookmarks,
            .record_id = Uuid.random(),
            .uses_files = rows == null,
        };
        if (rows) |shape| self.restoreSession(shape) else {
            const shape = session.read(self.store, Uuid.first);
            defer shape.deinit();
            self.restoreSession(shape.value);
        }
        if (self.tabs.items.len == 0) {
            _ = self.openTab("", true, false);
        }
        return self;
    }

    /// Its tabs let go; what's kept was written by whoever closed it.
    pub fn destroy(self: *Browser) void {
        if (self.stage_host) |sh| sh.destroy();
        if (self.lights) |l| l.drop();
        for (self.tabs.items) |t| t.destroy();
        self.tabs.deinit(self.gpa);
        self.closed_tabs.deinit(self.gpa);
        self.marks_filter_buf.deinit();
        self.omni_buf.deinit();
        self.find_buf.deinit();
        self.gpa.destroy(self);
    }

    pub fn bindWindow(self: *Browser, w: *nanoui.Window) !void {
        self.window = w;
        self.lights = try Lights.keep(self.gpa, w.nswindow, self.prefs);
        if (w.surface) |s| {
            const sh = try StageHost.create(self.gpa, s);
            sh.on_rects_ctx = self;
            sh.on_rects = onStageRects;
            self.stage_host = sh;
            self.syncStageHost();
            s.frame();
        }
    }

    /// The window is closing (`WindowOptions.on_close`): drop everything
    /// that points at it before nanoui frees its surface.
    pub fn unbindWindow(self: *Browser) void {
        if (self.stage_host) |sh| sh.destroy();
        self.stage_host = null;
        if (self.lights) |l| l.drop();
        self.lights = null;
        self.window = null;
    }

    fn onStageRects(ctx: ?*anyopaque, holes: []const ui.Rect) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
        // The column moved or changed sides: the lights follow it.
        if (self.lights) |l| l.follow();
        if (holes.len >= 1) {
            self.left_pane_frame = holes[0];
            if (self.focused_pane == .left or self.split_right_id == null) self.active_page_frame = holes[0];
        }
        if (holes.len >= 2) {
            self.right_pane_frame = holes[1];
            if (self.focused_pane == .right) self.active_page_frame = holes[1];
        }
    }

    pub fn redraw(self: *Browser) void {
        const w = self.window orelse return;
        self.syncStageHost();
        if (w.surface) |s| s.requestFrame();
    }

    pub fn syncStageHost(self: *Browser) void {
        const sh = self.stage_host orelse return;
        const primary = self.tabById(self.active_id);
        const secondary = if (self.prefs.split_view and self.split_right_id != null) self.tabById(self.split_right_id.?) else null;
        // The page's corners are the card's (`Page(corner: cards ? cardRadius : 0)`).
        const framed = self.prefs.sidebar;
        sh.setPanes(if (primary) |p| p.web else null, if (secondary) |s| s.web else null, framed);
    }

    pub fn activeTab(self: *Browser) ?*Tab {
        if (self.focused_pane == .right) {
            if (self.split_right_id) |rid| if (self.tabById(rid)) |rt| return rt;
        }
        return self.tabById(self.active_id);
    }

    pub fn tabById(self: *Browser, id: u64) ?*Tab {
        for (self.tabs.items) |t| if (t.id == id) return t;
        return null;
    }

    pub fn openTab(self: *Browser, initial_url: []const u8, foreground: bool, shy: bool) *Tab {
        const id = self.next_tab_id;
        self.next_tab_id += 1;
        const t = Tab.create(self.gpa, id, initial_url, shy, &self.kea.opts) catch @panic("OOM");
        t.browser_ctx = self;
        t.on_change = onTabChanged;
        t.on_new_tab = onTabRequestedNew;
        t.on_opensearch = onTabOpenSearch;
        self.tabs.append(self.gpa, t) catch @panic("OOM");
        if (foreground or self.active_id == 0) {
            self.active_id = id;
            self.focused_pane = .left;
        }
        if (initial_url.len > 0 and !shy) {
            self.history.record(initial_url, t.title());
        }
        self.saveSession();
        self.redraw();
        return t;
    }

    pub fn closeTab(self: *Browser, id: u64) void {
        var idx: ?usize = null;
        for (self.tabs.items, 0..) |t, i| {
            if (t.id == id) {
                idx = i;
                break;
            }
        }
        const i = idx orelse return;
        const t = self.tabs.orderedRemove(i);
        if (t.url().len > 0 and !t.shy) {
            var ct: ClosedTab = .{};
            ct.url_len = @min(t.url().len, ct.url.len);
            @memcpy(ct.url[0..ct.url_len], t.url()[0..ct.url_len]);
            ct.title_len = @min(t.title().len, ct.title.len);
            @memcpy(ct.title[0..ct.title_len], t.title()[0..ct.title_len]);
            ct.at = ui.clock.now();
            self.closed_tabs.append(self.gpa, ct) catch {};
        }
        if (self.stage_host) |sh| if (t.web) |wv| sh.forget(wv);
        t.destroy();

        if (self.split_right_id == id) {
            self.split_right_id = null;
            self.focused_pane = .left;
        }
        if (self.active_id == id) {
            if (self.split_right_id) |rid| {
                self.active_id = rid;
                self.split_right_id = null;
                self.focused_pane = .left;
            } else if (self.tabs.items.len > 0) {
                const next_i = @min(i, self.tabs.items.len - 1);
                self.active_id = self.tabs.items[next_i].id;
            } else {
                _ = self.openTab("", true, false);
            }
        }
        self.saveSession();
        self.redraw();
    }

    pub fn reopenClosedTab(self: *Browser) void {
        if (self.closed_tabs.items.len == 0) return;
        const ct = self.closed_tabs.pop().?;
        _ = self.openTab(ct.url[0..ct.url_len], true, false);
    }

    pub fn selectTab(self: *Browser, id: u64) void {
        if (self.split_right_id == id) {
            self.focused_pane = .right;
        } else if (self.active_id == id) {
            self.focused_pane = .left;
        } else if (self.focused_pane == .right and self.split_right_id != null) {
            self.split_right_id = id;
        } else {
            self.active_id = id;
        }
        if (self.activeTab()) |t| self.omni_buf.set(t.url());
        self.redraw();
    }

    pub fn stepTab(self: *Browser, delta: isize) void {
        const n = self.tabs.items.len;
        if (n <= 1) return;
        var cur: usize = 0;
        const cur_id = if (self.activeTab()) |t| t.id else self.active_id;
        for (self.tabs.items, 0..) |t, i| {
            if (t.id == cur_id) {
                cur = i;
                break;
            }
        }
        const next_idx: usize = @intCast(@mod(@as(isize, @intCast(cur)) + delta, @as(isize, @intCast(n))));
        self.selectTab(self.tabs.items[next_idx].id);
    }

    pub fn pairSplit(self: *Browser, right_id: u64) void {
        if (!self.prefs.split_view or right_id == self.active_id) return;
        if (self.tabById(right_id) == null) return;
        self.split_right_id = right_id;
        self.split_fraction = 0.5;
        self.redraw();
    }

    pub fn swapSplit(self: *Browser) void {
        const rid = self.split_right_id orelse return;
        self.split_right_id = self.active_id;
        self.active_id = rid;
        self.split_fraction = 1.0 - self.split_fraction;
        self.redraw();
    }

    pub fn evenSplit(self: *Browser) void {
        self.split_fraction = 0.5;
        self.redraw();
    }

    pub fn closeSplit(self: *Browser) void {
        self.split_right_id = null;
        self.focused_pane = .left;
        self.redraw();
    }

    pub fn navigateInput(self: *Browser, raw_in: []const u8) void {
        const trimmed = std.mem.trim(u8, raw_in, " \t\r\n");
        if (trimmed.len == 0) return;

        // If a SiteSearch chip is active, format its template with %s
        if (self.omni_chip) |chip| {
            self.omni_chip = null;
            var url_out: [2048]u8 = undefined;
            if (std.mem.indexOf(u8, chip.template, "%s")) |pos| {
                const full = std.fmt.bufPrint(&url_out, "{s}{s}{s}", .{
                    chip.template[0..pos],
                    trimmed,
                    chip.template[pos + 2 ..],
                }) catch trimmed;
                self.goUrl(full);
                return;
            }
        }

        // If an inline offer matches, take the offered host/URL
        const target = if (self.omni_offer_len > 0 and std.ascii.startsWithIgnoreCase(self.omni_offer[0..self.omni_offer_len], trimmed))
            self.omni_offer[0..self.omni_offer_len]
        else
            trimmed;

        var buf: [2048]u8 = undefined;
        const resolved = resolveAddress(&buf, target);
        self.goUrl(resolved);
    }

    pub fn goUrl(self: *Browser, target_url: []const u8) void {
        self.omni_open = false;
        self.omni_offer_len = 0;
        const t = self.activeTab() orelse self.openTab(target_url, true, false);
        t.load(target_url);
        self.omni_buf.set(target_url);
        if (!t.shy) self.history.record(target_url, t.title());
        self.saveSession();
        self.redraw();
    }

    pub fn updateOmniTyped(self: *Browser, text: []const u8) void {
        self.omni_typed_len = @min(text.len, self.omni_typed.len);
        @memcpy(self.omni_typed[0..self.omni_typed_len], text[0..self.omni_typed_len]);

        // Check if user typed `<site> ` or `<site>\t` to activate a SiteSearch chip
        if (self.prefs.searches_sites and self.omni_chip == null and text.len >= 3 and (text[text.len - 1] == ' ' or text[text.len - 1] == '\t')) {
            const word = std.mem.trim(u8, text, " \t");
            if (self.kea.site_search.match(word)) |site| {
                self.omni_chip = site;
                self.omni_buf.clear();
                self.omni_typed_len = 0;
                self.omni_offer_len = 0;
                return;
            }
        }

        // History's completion: what was typed, then the rest of the best match.
        self.omni_offer_len = 0;
        const sugs = self.history.suggestions(self.gpa, text, 5) catch return;
        defer self.gpa.free(sugs);
        const rest = (self.history.completion(text, sugs) catch null) orelse return;
        if (text.len + rest.len > self.omni_offer.len) return;
        @memcpy(self.omni_offer[0..text.len], text);
        @memcpy(self.omni_offer[text.len..][0..rest.len], rest);
        self.omni_offer_len = text.len + rest.len;
    }

    pub fn announce(self: *Browser, msg: []const u8) void {
        self.toast_len = @min(msg.len, self.toast_buf.len);
        @memcpy(self.toast_buf[0..self.toast_len], msg[0..self.toast_len]);
        self.toast_until = ui.clock.now() + 2.5;
        if (self.window) |w| nanoui.a11y.announce(w.nswindow, msg);
        self.redraw();
    }

    /// Kept for the next launch (`Session.write`), on the disk queue.
    pub fn saveSession(self: *Browser) void {
        self.writeSession(false);
    }

    /// Quitting: written now, on this thread.
    pub fn flushSession(self: *Browser) void {
        self.writeSession(true);
    }

    /// `Browser.session`: kept tabs only, `active` the one in front or, when
    /// that one isn't kept, the kept one just before it. Its strings are the
    /// tabs'; `entries` (on `gpa`) is the caller's to free.
    pub fn row(self: *Browser, gpa: std.mem.Allocator) !session.Shape {
        var entries: std.ArrayList(session.Entry) = .empty;
        errdefer entries.deinit(gpa);
        var active: i64 = 0;
        for (self.tabs.items) |t| {
            if (t.id == self.active_id) active = @max(0, @as(i64, @intCast(entries.items.len)) - @intFromBool(!kept(t)));
            if (!kept(t)) continue;
            try entries.append(gpa, .{
                .url = t.url(),
                .title = t.title(),
                // ponytail: letter from the title until P4 ports Tab.pin.
                .pin = if (t.pinned) monogram(t.title()) else null,
                .home = if (t.pinned) t.url() else null,
            });
        }
        return .{ .tabs = try entries.toOwnedSlice(gpa), .active = active };
    }

    /// `writeRow`: the session files for the oldest window, its line of
    /// `windows.json` for any other.
    fn writeSession(self: *Browser, now: bool) void {
        if (self.restoring) return;
        if (!self.uses_files) return if (now) browsers.save(self.kea, true) else browsers.saveSoon(self.kea);
        const shape = self.row(self.gpa) catch return;
        defer self.gpa.free(shape.tabs);
        session.write(self.store, Uuid.first, shape, now);
    }

    /// Not a private tab, and only with a web address (`Browser.kept`).
    fn kept(t: *const Tab) bool {
        return !t.shy and std.mem.startsWith(u8, t.url(), "http");
    }

    fn monogram(title: []const u8) []const u8 {
        const letters = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        for (title) |ch| if (std.mem.indexOfScalar(u8, letters, std.ascii.toUpper(ch))) |i| return letters[i .. i + 1];
        return "K";
    }

    fn restoreSession(self: *Browser, shape: session.Shape) void {
        self.restoring = true;
        defer self.restoring = false;
        for (shape.tabs, 0..) |e, i| {
            const t = self.openTab(e.url, i == shape.active, false);
            t.setTitle(e.title);
            t.pinned = e.pin != null;
        }
        // No tab in front (Start with a fresh window): an empty one beside the pins.
        if (shape.active < 0) _ = self.openTab("", true, false);
    }

    fn onTabChanged(ctx: ?*anyopaque, tab: *Tab) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
        if (!tab.shy and tab.url().len > 0) {
            self.history.record(tab.url(), tab.title());
            if (tab.title().len > 0) self.history.retitle(tab.url(), tab.title());
        }
        self.redraw();
    }

    fn onTabRequestedNew(ctx: ?*anyopaque, target_url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
        _ = self.openTab(target_url, true, false);
    }

    /// A site's own https home page that says where its search is: with
    /// Search a site on, never from a private tab (Browser.swift:4891-4900).
    fn onTabOpenSearch(ctx: ?*anyopaque, tab: *Tab, href: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
        if (tab.shy or !self.prefs.searches_sites) return;
        const page = tab.url();
        const p = Parts.parse(page) orelse return;
        if (!p.schemeIs("https") or !(p.path.len == 0 or std.mem.eql(u8, p.path, "/"))) return;
        _ = self.kea.site_search.learn(page, href);
    }
};

fn resolveAddress(buf: *[2048]u8, input: []const u8) []const u8 {
    if (std.mem.indexOf(u8, input, "://") != null or std.mem.startsWith(u8, input, "about:")) return input;
    if (std.mem.indexOfScalar(u8, input, ' ') == null and (std.mem.indexOfScalar(u8, input, '.') != null or std.mem.startsWith(u8, input, "localhost"))) {
        const scheme = if (std.mem.startsWith(u8, input, "localhost") or std.mem.startsWith(u8, input, "127.0.0.1")) "http://" else "https://";
        return std.fmt.bufPrint(buf, "{s}{s}", .{ scheme, input }) catch input;
    }
    return std.fmt.bufPrint(buf, "https://duckduckgo.com/?q={s}", .{input}) catch input;
}
