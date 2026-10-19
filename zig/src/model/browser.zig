//! Browser model: one window's row of tabs (`Browser.swift`), split across
//! a file per MARK section — `browser_tabs.zig` ("tabs"), `browser_closed.zig`
//! (closing and ⇧⌘T), `browser_rows.zig` ("this window's rows" and the
//! session), `browser_windows.zig` ("a tab to another window"), `pins.zig`,
//! `groups.zig` and `spaces.zig` — whose functions are this struct's methods
//! through the decls below. Also, for now: interim Split View
//! (`split_right_id`, `split_fraction`, `focused_pane`, replaced in P7), the
//! Bookmarks side panel, the Omnibox, Find on Page and `StageHost` sync.
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
const WindowRecord = @import("../data/windows_file.zig").WindowRecord;
const Tab = @import("../web/tab.zig").Tab;
const StageHost = @import("../web/stage_host.zig").StageHost;
const Lights = @import("../chrome/lights.zig").Lights;
const json = @import("../data/json.zig");
const Uuid = json.Uuid;
const overlays = @import("../chrome/overlays.zig");
const room = @import("../chrome/room.zig");
const EdgeDrag = @import("../chrome/panels.zig").EdgeDrag;
const tabs_ops = @import("browser_tabs.zig");
const closed_ops = @import("browser_closed.zig");
const rows_ops = @import("browser_rows.zig");
const windows_ops = @import("browser_windows.zig");
const pins_ops = @import("pins.zig");
const groups_ops = @import("groups.zig");
const spaces_ops = @import("spaces.zig");
const web_ops = @import("../web/delegates_nav.zig");
const sleep_ops = @import("../web/sleep.zig");

pub const PaneFocus = enum { left, right };
pub const TabGroup = groups_ops.TabGroup;
pub const Ghost = closed_ops.Ghost;
pub const Parked = spaces_ops.Parked;
pub const Pair = rows_ops.Pair;
pub const OpenOptions = tabs_ops.OpenOptions;

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
    /// A window other than the oldest: its rows by space (`record.rows`),
    /// each the encoded `Session.Shape`, keys and bytes on `gpa`.
    record_rows: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    /// The last window, closed with the app running: kept, tabs and all.
    shut: bool = false,

    // Shared with every window, owned by `kea`.
    store: *Store,
    prefs: *Prefs,
    history: *History,
    bookmarks: *Bookmarks,

    /// The row, in the order it is shown (`arrangeGroupedTabs`).
    tabs: std.ArrayList(*Tab) = .empty,
    /// 0: none.
    active_id: u64 = 0,
    /// Restoring the session: nothing is written, nothing visited.
    restoring: bool = false,

    // Groups (`tabGroups`, `editingGroupID`) and the pin being relettered.
    tab_groups: std.ArrayList(TabGroup) = .empty,
    editing_group_id: ?Uuid = null,
    editing_pin: ?u64 = null,

    // Closed tabs, newest last (`ghosts`), and what Clear and Close Group keep.
    ghosts: std.ArrayList(Ghost) = .empty,
    closed_groups: std.ArrayList(closed_ops.ClosedGroup) = .empty,
    batching: ?Uuid = null,
    last_clear: ?closed_ops.LastClear = null,
    /// `rememberSession`'s wait, while one is under way.
    remembering: ?*rows_ops.Tick = null,

    // Spaces: the one on screen, the others' rows, and which way the last
    // change went.
    space_id: Uuid = Uuid.first,
    parked: std.AutoArrayHashMapUnmanaged(Uuid, Parked) = .empty,
    space_step: i8 = 1,
    making_space: bool = false,
    /// A tab being sent into the space being made, from its menu.
    after_space_created: ?u64 = null,

    // Split View state (interim, P7)
    split_right_id: ?u64 = null,
    split_fraction: f32 = 0.5,
    focused_pane: PaneFocus = .left,
    /// A pair kept while not in front — restored with another tab in front —
    /// so the session keeps it, as Swift's `splits` do whatever is in front.
    kept_pair: ?Pair = null,

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
    /// The strip's own state across frames (tab_bar.zig), and the tab
    /// carried along the strip or the column (tab_drag.zig).
    strip: @import("../chrome/tab_bar.zig").Strip = .{},
    carry: @import("../chrome/tab_drag.zig").State = .{},
    /// The column folded away with ⌘S, and out over the page (Fold.swift).
    folded: bool = false,
    peeking: bool = false,
    /// The spaces' pages moved by two fingers or a slide (`SwipeOffset`).
    swipe: f32 = 0,
    /// The column's, the fold's and the spaces' own state across frames.
    column: @import("../chrome/side_bar.zig").State = .{},
    fold: @import("../chrome/fold.zig").State = .{},
    spaces_ui: @import("../chrome/spaces_view.zig").State = .{},

    // MARK: tabs (browser_tabs.zig)
    pub const displayedTabs = tabs_ops.displayedTabs;
    pub const shownTabs = tabs_ops.shownTabs;
    pub const visibleTabIDs = tabs_ops.visibleTabIDs;
    pub const open = tabs_ops.open;
    pub const newTab = tabs_ops.newTab;
    pub const newShyTab = tabs_ops.newShyTab;
    pub const select = tabs_ops.select;
    pub const selectIndex = tabs_ops.selectIndex;
    pub const step = tabs_ops.step;
    pub const move = tabs_ops.move;
    pub const moveDisplayedTab = tabs_ops.moveDisplayedTab;
    pub const dropTabIntoStrip = tabs_ops.dropTabIntoStrip;
    pub const placeForNew = tabs_ops.placeForNew;
    pub const insert = tabs_ops.insert;
    pub const duplicate = tabs_ops.duplicate;
    pub const arrive = tabs_ops.arrive;
    pub const visit = tabs_ops.visit;
    pub const moveToSpace = tabs_ops.moveToSpace;
    pub const prepare = tabs_ops.prepare;
    pub const make = tabs_ops.make;
    pub const makeAsleep = tabs_ops.makeAsleep;
    pub const adopt = tabs_ops.adopt;
    pub const setActive = tabs_ops.setActive;
    pub const indexOf = tabs_ops.indexOf;
    pub const inSplit = tabs_ops.inSplit;
    pub const partnerOf = tabs_ops.partnerOf;
    pub const detachSplit = tabs_ops.detachSplit;
    pub const letGo = tabs_ops.letGo;
    pub const take = tabs_ops.take;
    pub const copyAddress = tabs_ops.copyAddress;
    pub const copyMarkdownLink = tabs_ops.copyMarkdownLink;

    // MARK: closing and coming back (browser_closed.zig)
    pub const close = closed_ops.close;
    pub const closeFront = closed_ops.closeFront;
    pub const closeOthers = closed_ops.closeOthers;
    pub const clearTabs = closed_ops.clearTabs;
    pub const reopen = closed_ops.reopen;
    pub const reopenGhost = closed_ops.reopenGhost;
    pub const reopenTitle = closed_ops.reopenTitle;
    pub const lastGhostAt = closed_ops.lastGhostAt;

    // MARK: this window's rows (browser_rows.zig)
    pub const readRow = rows_ops.readRow;
    pub const writeRow = rows_ops.writeRow;
    pub const allRows = rows_ops.allRows;
    pub const becomePrimary = rows_ops.becomePrimary;
    pub const session = rows_ops.session;
    pub const writeSession = rows_ops.writeSession;
    pub const writeParked = rows_ops.writeParked;
    pub const rememberSession = rows_ops.rememberSession;
    pub const flushSession = rows_ops.flushSession;
    pub const restoreSession = rows_ops.restoreSession;
    pub const loadRow = rows_ops.loadRow;
    pub const showRow = rows_ops.showRow;
    pub const currentPair = rows_ops.currentPair;
    pub const applyPair = rows_ops.applyPair;

    // MARK: a tab to another window (browser_windows.zig)
    pub const moveToWindow = windows_ops.moveToWindow;
    pub const dragOut = windows_ops.dragOut;
    pub const receive = windows_ops.receive;

    // MARK: pinning, and pins the same in every window (pins.zig)
    pub const pinnedCount = pins_ops.pinnedCount;
    pub const squarePins = pins_ops.squarePins;
    pub const listedPins = pins_ops.listedPins;
    pub const pin = pins_ops.pin;
    pub const setListed = pins_ops.setListed;
    pub const goHome = pins_ops.goHome;
    pub const editLetter = pins_ops.editLetter;
    pub const letter = pins_ops.letter;
    pub const endPinEdit = pins_ops.endPinEdit;
    pub const unpin = pins_ops.unpin;
    pub const reconcilePins = pins_ops.reconcilePins;
    pub const pinsChanged = pins_ops.pinsChanged;

    // MARK: groups (groups.zig)
    pub const addTabGroup = groups_ops.addTabGroup;
    pub const renameTabGroup = groups_ops.renameTabGroup;
    pub const toggleTabGroup = groups_ops.toggleTabGroup;
    pub const removeTabGroup = groups_ops.removeTabGroup;
    pub const closeTabGroup = groups_ops.closeTabGroup;
    pub const moveToGroup = groups_ops.moveToGroup;
    pub const moveWithin = groups_ops.moveWithin;
    pub const moveTabGroup = groups_ops.moveTabGroup;
    pub const arrangeGroupedTabs = groups_ops.arrangeGroupedTabs;
    pub const groupOf = groups_ops.groupOf;
    pub const tabsIn = groups_ops.tabsIn;
    pub const visibleTabsIn = groups_ops.visibleTabsIn;
    pub const removeEmptyGroup = groups_ops.removeEmptyGroup;
    pub const groupById = groups_ops.groupById;

    // MARK: spaces (spaces.zig)
    pub const space = spaces_ops.space;
    pub const switchSpace = spaces_ops.switchSpace;
    pub const switchSpaceIndex = spaces_ops.switchSpaceIndex;
    pub const preloadSpaces = spaces_ops.preloadSpaces;
    pub const freeIcon = spaces_ops.freeIcon;
    pub const addSpace = spaces_ops.addSpace;
    pub const moveSpace = spaces_ops.moveSpace;
    pub const renameSpace = spaces_ops.renameSpace;
    pub const setSpaceIcon = spaces_ops.setSpaceIcon;
    pub const setSpaceDownloads = spaces_ops.setSpaceDownloads;
    pub const deleteSpace = spaces_ops.deleteSpace;
    pub const leaveSpaces = spaces_ops.leaveSpaces;
    pub const forgetSpace = spaces_ops.forgetSpace;
    pub const parkedTabs = spaces_ops.parkedTabs;

    // MARK: what its pages say (web/delegates_nav.zig, web/sleep.zig)
    pub const tabChanged = web_ops.tabChanged;
    pub const pageTookKeys = web_ops.pageTookKeys;
    pub const zoomed = web_ops.zoomed;
    pub const awake = sleep_ops.awake;
    pub const sleep = sleep_ops.sleep;
    pub const sleepIdle = sleep_ops.sleepIdle;

    /// `record` null: the oldest window, its tabs from the session files.
    /// Otherwise another window's, from `windows.json`, ⇧⌘T or new (empty).
    pub fn create(kea: *Kea, record: ?*const WindowRecord) !*Browser {
        const self = try kea.gpa.create(Browser);
        self.* = .{
            .kea = kea,
            .gpa = kea.gpa,
            .store = &kea.store,
            .prefs = &kea.prefs,
            .history = &kea.history,
            .bookmarks = &kea.bookmarks,
            .record_id = if (record) |r| r.id else Uuid.random(),
            .uses_files = record == null,
            // Asked to stay out of the way: it starts that way (see Fold.swift).
            .folded = kea.prefs.sidebar and kea.prefs.side_hides,
        };
        if (record) |r| {
            var it = r.rows.map.iterator();
            while (it.next()) |e| {
                const key = try self.gpa.dupe(u8, e.key_ptr.*);
                const bytes = try json.encode(self.gpa, e.value_ptr.*);
                try self.record_rows.put(self.gpa, key, bytes);
            }
            // Another window: the space it showed.
            if (self.prefs.uses_spaces and kea.spaceIndex(r.space) != null) self.space_id = r.space;
        } else if (self.prefs.uses_spaces) {
            // The space you were in, when there are spaces.
            if (self.store.string("space.current")) |s| {
                defer self.gpa.free(s);
                if (Uuid.parse(s)) |last| {
                    if (kea.spaceIndex(last) != null) self.space_id = last;
                } else |_| {}
            }
        }
        self.restoreSession();
        sleep_ops.watch(self);
        return self;
    }

    /// Its tabs let go, and every other space's (`closeAll`); what's kept
    /// was written by whoever closed it.
    pub fn destroy(self: *Browser) void {
        if (self.remembering) |t| t.browser = null;
        sleep_ops.unwatch(self);
        if (self.stage_host) |sh| sh.destroy();
        if (self.lights) |l| l.drop();
        for (self.tabs.items) |t| t.destroy();
        self.tabs.deinit(self.gpa);
        for (self.parked.values()) |*row| row.deinit(self.gpa);
        self.parked.deinit(self.gpa);
        for (self.ghosts.items) |g| g.deinit(self.gpa);
        self.ghosts.deinit(self.gpa);
        for (self.closed_groups.items) |g| self.gpa.free(g.group.name);
        self.closed_groups.deinit(self.gpa);
        groups_ops.freeGroups(self.gpa, &self.tab_groups);
        for (self.record_rows.keys(), self.record_rows.values()) |k, v| {
            self.gpa.free(k);
            self.gpa.free(v);
        }
        self.record_rows.deinit(self.gpa);
        self.marks_filter_buf.deinit();
        self.omni_buf.deinit();
        self.find_buf.deinit();
        self.strip.deinit(self.gpa);
        @import("../chrome/fold.zig").stop(self);
        self.column.deinit(self.gpa);
        self.spaces_ui.deinit();
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
        @import("../chrome/fold.zig").stop(self);
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

    /// The page with the keys: the focused pane's.
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

    /// Interim Split View: `right_id` beside the tab in front, next to it in
    /// the row, as `pair` puts it (P7 ports `TabSplit`).
    pub fn pairSplit(self: *Browser, right_id: u64) void {
        if (!self.prefs.split_view or right_id == self.active_id) return;
        const right = self.tabById(right_id) orelse return;
        const from = self.indexOf(right).?;
        _ = self.tabs.orderedRemove(from);
        const left = self.indexOf(self.tabById(self.active_id) orelse return).?;
        self.tabs.insert(self.gpa, left + 1, right) catch @panic("OOM");
        self.split_right_id = right_id;
        self.kept_pair = null;
        self.split_fraction = 0.5;
        self.rememberSession();
        self.redraw();
    }

    pub fn swapSplit(self: *Browser) void {
        const rid = self.split_right_id orelse return;
        self.split_right_id = self.active_id;
        self.active_id = rid;
        self.split_fraction = 1.0 - self.split_fraction;
        if (self.tabById(rid)) |front| @import("../web/dialogs.zig").presentHeld(front);
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
        const t = self.activeTab() orelse self.open(target_url, .{ .foreground = true });
        t.go(target_url);
        self.omni_buf.set(target_url);
        // The visit is recorded when the page finishes (`didFinish`).
        self.rememberSession();
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
};

fn resolveAddress(buf: *[2048]u8, input: []const u8) []const u8 {
    if (std.mem.indexOf(u8, input, "://") != null or std.mem.startsWith(u8, input, "about:")) return input;
    if (std.mem.indexOfScalar(u8, input, ' ') == null and (std.mem.indexOfScalar(u8, input, '.') != null or std.mem.startsWith(u8, input, "localhost"))) {
        const scheme = if (std.mem.startsWith(u8, input, "localhost") or std.mem.startsWith(u8, input, "127.0.0.1")) "http://" else "https://";
        return std.fmt.bufPrint(buf, "{s}{s}", .{ scheme, input }) catch input;
    }
    return std.fmt.bufPrint(buf, "https://duckduckgo.com/?q={s}", .{input}) catch input;
}
