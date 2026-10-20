//! Browser model: one window's row of tabs (`Browser.swift`), split across
//! a file per MARK section — `browser_tabs.zig` ("tabs"), `browser_closed.zig`
//! (closing and ⇧⌘T), `browser_rows.zig` ("this window's rows" and the
//! session), `browser_windows.zig` ("a tab to another window"), `pins.zig`,
//! `groups.zig`, `spaces.zig` and `omni.zig` (guessing, the address field and
//! the address in the tab) — whose functions are this struct's methods
//! through the decls below; `split.zig` (Split View's pairs) too. Also, for
//! now: the Bookmarks side panel, Find on Page and `StageHost` sync.
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
const side_panels = @import("../chrome/side_panels.zig");
const tabs_ops = @import("browser_tabs.zig");
const closed_ops = @import("browser_closed.zig");
const rows_ops = @import("browser_rows.zig");
const windows_ops = @import("browser_windows.zig");
const pins_ops = @import("pins.zig");
const groups_ops = @import("groups.zig");
const spaces_ops = @import("spaces.zig");
const web_ops = @import("../web/delegates_nav.zig");
const sleep_ops = @import("../web/sleep.zig");
const downloads_ops = @import("../web/downloads_keep.zig");
const handoff_ops = @import("../app/handoff.zig");
const omni_ops = @import("omni.zig");
const marks_ops = @import("../chrome/bookmarks/actions.zig");
const split_ops = @import("split.zig");
const clear_ops = @import("browser_clear.zig");
const chat_ops = @import("browser_chat.zig");

pub const TabSplit = split_ops.TabSplit;
pub const TabGroup = groups_ops.TabGroup;
pub const Ghost = closed_ops.Ghost;
pub const Parked = spaces_ops.Parked;
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
    ext: @import("browser_ext.zig").State = .{},

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

    // Split View's pairs (model/split.zig), kept with Split View off too;
    // and `displayedTabs`' row, made again each time it is asked for.
    splits: std.ArrayList(TabSplit) = .empty,
    displayed: std.ArrayList(*Tab) = .empty,

    // The side panels (chrome/side_panels.zig): the one let out over the
    // page (`expandedPanel`), the last one let out while it fades, a header
    // being carried.
    expanded_panel: ?side_panels.SidePanel = null,
    let_out: ?side_panels.SidePanel = null,
    header_drag: ?side_panels.HeaderDrag = null,

    // The address field (model/omni.zig): raised over a page (`editing`),
    // what it thinks you mean, the site in it, ⌘K's switcher, and what was
    // asked of the view (`refusals` shakes it, `focus_request` focuses it).
    editing: bool = false,
    omni: omni_ops.Omni,
    site_chip: ?SearchSite = null,
    refusals: u32 = 0,
    focus_request: u32 = 0,
    summoning: bool = false,
    cycling: bool = false,
    /// The address (or, renaming, the name) typed into the tab itself.
    editing_tab: ?u64 = null,
    tab_draft: ui.TextBuffer = .{},
    renaming_tab: bool = false,
    /// That field's box, last frame (what the site card hangs from).
    tab_field_rect: ui.Rect = .{},
    /// The fields' own state across frames (chrome/omnibox.zig, tab_address.zig).
    omnibox: @import("../chrome/omnibox.zig").State = .{},
    tab_field: @import("../chrome/tab_address.zig").State = .{},

    // Find on page (web/page_find.zig) and its bar (chrome/find_bar.zig).
    finder: @import("../web/page_find.zig").Find = .{},
    find_bar: @import("../chrome/find_bar.zig").State = .{},

    // Taking things off pages (web/curtain_js.zig): pointing, what a
    // private tab hid on its page only, and the list of what is hidden
    // here (`reviewing`, chrome/hidden_panel.zig — set it through `setReviewing`).
    veiling: bool = false,
    passing_veils: @import("../web/curtain_js.zig").Passing = .empty,
    reviewing: bool = false,
    hidden_panel: @import("../chrome/hidden_panel.zig").State = .{},

    // The sheets over the window (chrome/sheet.zig), one at a time: open them with `sheet.show`.
    // Settings (`tuning`), the bookmarks manager, History, Downloads, Passwords (`managing`), Bring
    // things over (`bringing_in`, import/bring.zig); and the Welcome over everything (`welcoming`).
    tuning: bool = false,
    bookmarking: bool = false,
    recalling: bool = false,
    hoarding: bool = false,
    managing: bool = false,
    bringing_in: ?[]const u8 = null,
    importing: @import("../import/bring.zig").State = .{},
    welcoming: bool = false,
    sheet: @import("../chrome/sheet.zig").State = .{},
    settings: @import("../chrome/settings/frame.zig").State = .{},
    welcome: @import("../chrome/welcome.zig").State = .{},
    /// The bookmarks' lists, picks, card and button (chrome/bookmarks/).
    marks_ui: @import("../chrome/bookmarks/state.zig").State = .{},
    /// History's hunt, mode and list (chrome/history_panel.zig).
    recall: @import("../chrome/history_panel.zig").State = .{},

    // The bars (chrome/bars.zig): a line that rises from the bottom, says
    // one thing and leaves (`announcement`, on `gpa`, until `announced_until`
    // on `ui.clock`); the file it is about (`announcedFile`), shown in the
    // Finder when pressed; and a page asking on the bar (`asking`).
    announcement: ?[]u8 = null,
    announced_until: f64 = 0,
    announced_file: ?[]u8 = null,
    asking: ?@import("../web/dialogs.zig").Asking = null,

    // The page with the keys' hole from the last frame, and the stage's own
    // state across frames (chrome/split_stage.zig).
    active_page_frame: ui.Rect = .{},
    stage: @import("../chrome/split_stage.zig").State = .{},

    // The window (ContentView): what is open over it, the ground last
    // given to its NSWindow, the room the page leaves, an edge being pulled.
    overlay: ?overlays.Overlay = null,
    overlay_anchor: ui.Rect = .{},
    applied_ground: ?ui.Color = null,
    room: room.State = .{},
    edge_drag: ?side_panels.EdgeDrag = null,
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
    /// The site card under the tab's address (SiteCard.swift).
    site_card: @import("../chrome/site_card.zig").State = .{},
    /// Where the link under the pointer goes (StatusLine.swift `LinkStatus`).
    link_status: @import("../chrome/link_bubble.zig").Status = .{},
    /// The page in front, offered to other devices (Sharing.swift `handoffActivity`).
    handoff_activity: ?objc.Object = null,
    /// A link's page, peeked at over this one (chrome/peek.zig), and the
    /// layer's state; ⌃Tab's switcher (chrome/tab_switcher.zig).
    peek_tab: ?*Tab = null,
    peek_ui: @import("../chrome/peek.zig").State = .{},
    switcher: @import("../chrome/tab_switcher.zig").TabSwitcher = .{},
    /// Ubi Chat, while open (`assisting`), and its panel's state.
    assisting: ?*@import("../ai/assistant.zig").Assistant = null,
    chat: @import("../ai/chat_view.zig").State = .{},
    /// The keychain's offer, the accounts under a sign-in box, the Passwords list (passwords/browser_passwords.zig).
    passwords: @import("../passwords/browser_passwords.zig").State,

    // MARK: peek and ⌃Tab's switcher (chrome/peek.zig, chrome/tab_switcher.zig)
    pub const peek = @import("../chrome/peek.zig").peek;
    pub const closePeek = @import("../chrome/peek.zig").closePeek;
    pub const keepPeek = @import("../chrome/peek.zig").keepPeek;
    pub const switchTabs = @import("../chrome/tab_switcher.zig").switchTabs;
    pub const commitTabSwitch = @import("../chrome/tab_switcher.zig").commitTabSwitch;

    // MARK: bookmarks (chrome/bookmarks/actions.zig)
    pub const bookmarkCurrent = marks_ops.bookmarkCurrent;
    pub const toggleBookmarks = marks_ops.toggleBookmarks;
    pub const pickBookmark = marks_ops.pickBookmark;
    pub const openBookmarks = marks_ops.openBookmarks;
    pub const pageKept = marks_ops.pageKept;
    pub const importFile = @import("../chrome/bookmarks/files.zig").importFile;

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

    // MARK: Split View (split.zig)
    pub const splitFor = split_ops.splitFor;
    pub const activeSplit = split_ops.activeSplit;
    pub const inSplit = split_ops.inSplit;
    pub const partnerOf = split_ops.partnerOf;
    pub const standsInRow = split_ops.standsInRow;
    pub const entry = split_ops.entry;
    pub const canSplit = split_ops.canSplit;
    pub const pair = split_ops.pair;
    pub const startSplit = split_ops.startSplit;
    pub const detachSplit = split_ops.detachSplit;
    pub const setSplitFraction = split_ops.setSplitFraction;
    pub const focusPane = split_ops.focusPane;
    pub const focusPaneSide = split_ops.focusPaneSide;
    pub const focusOtherPane = split_ops.focusOtherPane;
    pub const openInSplit = split_ops.openInSplit;
    pub const swapSplit = split_ops.swapSplit;
    pub const evenSplit = split_ops.evenSplit;
    pub const closeSplit = split_ops.closeSplit;
    pub const fill = split_ops.fill;
    pub const splitViewChanged = split_ops.splitViewChanged;

    // MARK: tabs, again (browser_tabs.zig)
    pub const letGo = tabs_ops.letGo;
    pub const take = tabs_ops.take;
    pub const copyAddress = tabs_ops.copyAddress;
    pub const copyMarkdownLink = tabs_ops.copyMarkdownLink;
    pub const pasteAndGo = tabs_ops.pasteAndGo;
    pub const pauseMedia = tabs_ops.pauseMedia;

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

    // MARK: downloads (web/downloads_keep.zig)
    pub const keep = downloads_ops.keep;
    pub const pauseDownload = downloads_ops.pauseDownload;
    pub const resumeDownload = downloads_ops.resumeDownload;
    pub const retryDownload = downloads_ops.retryDownload;
    pub const cancelDownload = downloads_ops.cancelDownload;
    pub const downloadsFolder = downloads_ops.downloadsFolder;

    // MARK: elsewhere (app/handoff.zig)
    pub const handOff = handoff_ops.handOff;
    pub const share = handoff_ops.share;
    pub const printPage = handoff_ops.printPage;

    // MARK: the address field (omni.zig)
    pub const setTyped = omni_ops.setTyped;
    pub const setEditing = omni_ops.setEditing;
    pub const setChip = omni_ops.setChip;
    pub const fieldShowing = omni_ops.fieldShowing;
    pub const askFocus = omni_ops.askFocus;
    pub const searchURL = omni_ops.searchURL;
    pub const destination = omni_ops.destination;
    pub const guess = omni_ops.guess;
    pub const stepSummon = omni_ops.stepSummon;
    pub const landSummon = omni_ops.landSummon;
    pub const summon = omni_ops.summon;
    pub const takeOffer = omni_ops.takeOffer;
    pub const stopCompleting = omni_ops.stopCompleting;
    pub const lockSiteOffer = omni_ops.lockSiteOffer;
    pub const walk = omni_ops.walk;
    pub const edit = omni_ops.edit;
    pub const dismiss = omni_ops.dismiss;
    pub const submit = omni_ops.submit;
    pub const freshField = omni_ops.freshField;
    pub const beginTabEdit = omni_ops.beginTabEdit;
    pub const beginTabRename = omni_ops.beginTabRename;
    pub const commitTabEdit = omni_ops.commitTabEdit;
    pub const cancelTabEdit = omni_ops.cancelTabEdit;
    pub const finishTabEdit = omni_ops.finishTabEdit;

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
            .omni = omni_ops.Omni.init(kea.gpa),
            .passwords = .{ .accounts = .{ .gpa = kea.gpa } },
            // The first window of the run, until the Welcome has been seen.
            .welcoming = kea.browsers.items.len == 0 and !kea.prefs.welcomed,
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
        @import("browser_ext.zig").destroy(self);
        if (self.remembering) |t| t.browser = null;
        sleep_ops.unwatch(self);
        self.kea.fetches.unbind(self);
        chat_ops.deinit(self);
        @import("../import/bring.zig").deinit(self);
        self.hush();
        // A page still waiting on the bar is refused, never left holding.
        if (self.asking) |a| {
            self.asking = null;
            @import("../web/dialogs.zig").answer(a.ask, false, null);
        }
        if (self.peek_tab) |t| self.letGo(t);
        self.peek_tab = null;
        if (self.stage_host) |sh| sh.destroy();
        if (self.lights) |l| l.drop();
        for (self.tabs.items) |t| t.destroy();
        self.tabs.deinit(self.gpa);
        self.splits.deinit(self.gpa);
        self.displayed.deinit(self.gpa);
        self.stage.deinit(self.gpa);
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
        self.omni.deinit(self.gpa);
        self.tab_draft.deinit();
        self.omnibox.deinit(self.gpa);
        self.settings.deinit(self.gpa);
        self.find_bar.deinit();
        self.recall.deinit();
        self.finder.deinit(self.gpa);
        @import("../web/curtain_js.zig").deinit(self);
        self.strip.deinit(self.gpa);
        @import("../chrome/fold.zig").stop(self);
        self.column.deinit(self.gpa);
        self.spaces_ui.deinit();
        // The manager going with its window: what it did can't be undone elsewhere.
        if (self.marks_ui.manager_seen) self.bookmarks.stopUndo();
        self.marks_ui.deinit(self.gpa);
        self.link_status.deinit(self.gpa);
        self.switcher.deinit(self.gpa);
        self.passwords.deinit(self.gpa);
        handoff_ops.forget(self);
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
        // The panes' holes come first, in the stage's order.
        const panes = self.stage.shown();
        for (panes, 0..) |pane, i| if (i < holes.len and pane.tab == self.active_id) {
            self.active_page_frame = holes[i];
            return;
        };
        if (holes.len >= 1) self.active_page_frame = holes[0];
    }

    pub fn redraw(self: *Browser) void {
        if (self.kea.ext) |e| e.follow(self);
        const w = self.window orelse return;
        self.syncStageHost();
        if (w.surface) |s| s.requestFrame();
    }

    /// Each pane's page into its slot, in the order the stage last drew
    /// their holes (chrome/split_stage.zig): none for a page out in the
    /// floating window (`PaneStage.page`).
    pub fn syncStageHost(self: *Browser) void {
        const sh = self.stage_host orelse return;
        // Two panes and one leaving (split_stage.State.panes): with Peek's, nanoui's 4 holes.
        var pages: [3]?objc.Object = .{ null, null, null };
        var alphas: [3]f32 = .{ 1, 1, 1 };
        const panes = self.stage.shown();
        for (panes, 0..) |pane, i| {
            alphas[i] = pane.alpha;
            const t = self.tabById(pane.tab) orelse continue;
            pages[i] = if (t.floating) null else t.web;
        }
        // The page's corners are the card's (`Page(corner: cards ? cardRadius : 0)`).
        sh.setPanes(pages[0..panes.len], alphas[0..panes.len], self.prefs.sidebar and self.ext.popup == null);
    }

    /// The page with the keys (`active`).
    pub fn activeTab(self: *Browser) ?*Tab {
        return self.tabById(self.active_id);
    }

    pub fn tabById(self: *Browser, id: u64) ?*Tab {
        for (self.tabs.items) |t| if (t.id == id) return t;
        return null;
    }

    // MARK: announcements (chrome/bars.zig)
    pub const announce = @import("../chrome/bars.zig").announce;
    pub const announceFile = @import("../chrome/bars.zig").announceFile;
    pub const hush = @import("../chrome/bars.zig").hush;

    // MARK: Ubi Chat (browser_chat.zig)
    pub const toggleChat = chat_ops.toggleChat;
    pub const openChat = chat_ops.openChat;
    pub const summarizePage = chat_ops.summarizePage;
    pub const closeAssistant = chat_ops.closeAssistant;

    // MARK: what is kept, and getting rid of it (browser_clear.zig)
    pub const clearHistory = clear_ops.clearHistory;
    pub const clearSites = clear_ops.clearSites;
    pub const clearCache = clear_ops.clearCache;
};
