//! Browser model: owns `Store`, `Prefs`, `History`, `Bookmarks`, `Tab` list,
//! Split View (`split_right_id`, `split_fraction`, `focused_pane`), SidePanels
//! (Ubi Chat & Bookmarks), Omnibox autocomplete/chip/suggestions, Find on Page,
//! and `StageHost` synchronization.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Store = @import("store.zig").Store;
const prefs_mod = @import("prefs.zig");
const Prefs = prefs_mod.Prefs;
const History = @import("history.zig").History;
const history_mod = @import("history.zig");
const Bookmarks = @import("bookmarks.zig").Bookmarks;
const SiteEntry = @import("bookmarks.zig").SiteEntry;
const Tab = @import("tab.zig").Tab;
const StageHost = @import("stage_host.zig").StageHost;

pub const PaneFocus = enum { left, right };
pub const PlateKind = enum { none, settings, bookmarks, history };

pub const ClosedTab = struct {
    url: [2048]u8 = undefined,
    url_len: usize = 0,
    title: [256]u8 = undefined,
    title_len: usize = 0,
};

pub const Browser = struct {
    gpa: std.mem.Allocator,
    app: *nanoui.App,
    window: ?*nanoui.Window = null,
    stage_host: ?*StageHost = null,

    store: Store,
    prefs: Prefs,
    history: History,
    bookmarks: Bookmarks,

    tabs: std.ArrayList(*Tab) = .empty,
    closed_tabs: std.ArrayList(ClosedTab) = .empty,
    next_tab_id: u64 = 1,
    active_id: u64 = 0,

    // Split View state
    split_right_id: ?u64 = null,
    split_fraction: f32 = 0.5,
    focused_pane: PaneFocus = .left,

    // Side Panels (Ubi Chat & Bookmarks)
    chat_open: bool = false,
    chat_expanded: bool = false,
    marks_open: bool = false,
    marks_expanded: bool = false,
    chat_buf: ui.TextBuffer = .{},
    marks_filter_buf: ui.TextBuffer = .{},

    // Omnibox state
    omni_open: bool = false,
    omni_buf: ui.TextBuffer = .{},
    omni_chip: ?SiteEntry = null,
    omni_selected: usize = 0,
    omni_offer: [256]u8 = undefined,
    omni_offer_len: usize = 0,
    omni_typed: [256]u8 = undefined,
    omni_typed_len: usize = 0,

    // Find in page state
    find_open: bool = false,
    find_buf: ui.TextBuffer = .{},
    find_matches: usize = 0,

    // Modal plate & Toast
    plate: PlateKind = .none,
    toast_buf: [256]u8 = undefined,
    toast_len: usize = 0,
    toast_until: f64 = 0,

    // Recorded geometry from last frame for `./bench` probe
    active_page_frame: ui.Rect = .{},
    left_pane_frame: ui.Rect = .{},
    right_pane_frame: ui.Rect = .{},

    pub fn create(gpa: std.mem.Allocator, app: *nanoui.App) !*Browser {
        const self = try gpa.create(Browser);
        errdefer gpa.destroy(self);

        var store = try Store.init(gpa);
        errdefer store.deinit();
        const prefs = Prefs.init(&store);

        self.* = .{
            .gpa = gpa,
            .app = app,
            .store = store,
            .prefs = prefs,
            .history = undefined,
            .bookmarks = undefined,
        };
        self.history = History.init(gpa, &self.store);
        self.bookmarks = Bookmarks.init(gpa, &self.store);

        self.restoreSession();
        if (self.tabs.items.len == 0) {
            _ = self.openTab("", true, false);
        }
        return self;
    }

    pub fn destroy(self: *Browser) void {
        self.saveSession();
        self.history.flush();
        if (self.stage_host) |sh| sh.destroy();
        for (self.tabs.items) |t| t.destroy();
        self.tabs.deinit(self.gpa);
        self.closed_tabs.deinit(self.gpa);
        self.bookmarks.deinit();
        self.history.deinit();
        self.prefs.deinit();
        self.store.deinit();
        self.gpa.destroy(self);
    }

    pub fn bindWindow(self: *Browser, w: *nanoui.Window) !void {
        self.window = w;
        if (w.surface) |s| {
            const sh = try StageHost.create(self.gpa, s);
            sh.on_rects_ctx = self;
            sh.on_rects = onStageRects;
            self.stage_host = sh;
            self.syncStageHost();
            s.frame();
        }
    }

    fn onStageRects(ctx: ?*anyopaque, holes: []const ui.Rect) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
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
        self.syncStageHost();
        if (self.window) |w| if (w.surface) |s| s.requestFrame();
    }

    pub fn syncStageHost(self: *Browser) void {
        const sh = self.stage_host orelse return;
        const primary = self.tabById(self.active_id);
        const secondary = if (self.prefs.split_view and self.split_right_id != null) self.tabById(self.split_right_id.?) else null;
        const framed = self.prefs.sidebar or self.chat_open or self.marks_open or secondary != null;
        sh.setPanes(if (primary) |p| p.webview else null, if (secondary) |s| s.webview else null, framed);
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

    pub fn tabByUuidOrShort(self: *Browser, needle: []const u8) ?*Tab {
        if (needle.len == 0) return self.activeTab();
        for (self.tabs.items) |t| {
            if (std.ascii.startsWithIgnoreCase(&t.uuid_str, needle) or std.ascii.endsWithIgnoreCase(&t.uuid_str, needle)) return t;
        }
        if (std.fmt.parseInt(u64, needle, 10) catch null) |num| {
            return self.tabById(num);
        }
        return null;
    }

    pub fn openTab(self: *Browser, initial_url: []const u8, foreground: bool, shy: bool) *Tab {
        const id = self.next_tab_id;
        self.next_tab_id += 1;
        const t = Tab.create(self.gpa, id, initial_url, shy) catch @panic("OOM");
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
            self.history.record(initial_url, t.title(), nowEpoch());
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
            self.closed_tabs.append(self.gpa, ct) catch {};
        }
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
        if (!t.shy) self.history.record(target_url, t.title(), nowEpoch());
        self.saveSession();
        self.redraw();
    }

    pub fn updateOmniTyped(self: *Browser, text: []const u8) void {
        self.omni_typed_len = @min(text.len, self.omni_typed.len);
        @memcpy(self.omni_typed[0..self.omni_typed_len], text[0..self.omni_typed_len]);

        // Check if user typed `<site> ` or `<site>\t` to activate a SiteSearch chip
        if (self.prefs.searches_sites and self.omni_chip == null and text.len >= 3 and (text[text.len - 1] == ' ' or text[text.len - 1] == '\t')) {
            const word = std.mem.trim(u8, text, " \t");
            if (self.bookmarks.matchSite(word)) |site| {
                self.omni_chip = site;
                self.omni_buf.clear();
                self.omni_typed_len = 0;
                self.omni_offer_len = 0;
                return;
            }
        }

        if (self.history.offer(text, nowEpoch())) |off| {
            self.omni_offer_len = @min(off.len, self.omni_offer.len);
            @memcpy(self.omni_offer[0..self.omni_offer_len], off[0..self.omni_offer_len]);
        } else {
            self.omni_offer_len = 0;
        }
    }

    pub fn announce(self: *Browser, msg: []const u8) void {
        self.toast_len = @min(msg.len, self.toast_buf.len);
        @memcpy(self.toast_buf[0..self.toast_len], msg[0..self.toast_len]);
        self.toast_until = ui.clock.now() + 2.5;
        if (self.window) |w| nanoui.a11y.announce(w.nswindow, msg);
        self.redraw();
    }

    pub fn saveSession(self: *Browser) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "{\"tabs\":[") catch return;
        for (self.tabs.items, 0..) |t, i| {
            if (t.shy) continue;
            if (i > 0) out.append(self.gpa, ',') catch return;
            const entry = std.fmt.allocPrint(self.gpa, "{{\"url\":\"{s}\",\"title\":\"{s}\",\"pinned\":{s}}}", .{
                t.url(),
                t.title(),
                if (t.pinned) "true" else "false",
            }) catch continue;
            defer self.gpa.free(entry);
            out.appendSlice(self.gpa, entry) catch return;
        }
        out.appendSlice(self.gpa, "]}") catch return;
        self.store.writeAtomic("session.json", out.items);
    }

    fn restoreSession(self: *Browser) void {
        const data = self.store.read("session.json") orelse return;
        defer self.gpa.free(data);
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, data, .{}) catch {
            self.store.quarantine("session.json");
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            self.store.quarantine("session.json");
            return;
        }
        const tabs_v = parsed.value.object.get("tabs") orelse return;
        if (tabs_v != .array) return;
        for (tabs_v.array.items) |item| {
            if (item != .object) continue;
            const u_v = item.object.get("url") orelse continue;
            if (u_v != .string) continue;
            const t = self.openTab(u_v.string, false, false);
            if (item.object.get("title")) |tv| if (tv == .string) t.setTitle(tv.string);
            if (item.object.get("pinned")) |pv| if (pv == .bool) {
                t.pinned = pv.bool;
            };
        }
    }

    fn onTabChanged(ctx: ?*anyopaque, tab: *Tab) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
        if (!tab.shy and tab.url().len > 0) {
            self.history.record(tab.url(), tab.title(), nowEpoch());
            if (tab.title().len > 0) self.history.retitle(tab.url(), tab.title());
        }
        self.redraw();
    }

    fn onTabRequestedNew(ctx: ?*anyopaque, target_url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
        _ = self.openTab(target_url, true, false);
    }

    fn onTabOpenSearch(ctx: ?*anyopaque, host: []const u8, title: []const u8, _: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
        if (host.len == 0) return;
        var tmpl_buf: [512]u8 = undefined;
        const tmpl = std.fmt.bufPrint(&tmpl_buf, "https://{s}/search?q=%s", .{host}) catch return;
        self.bookmarks.learnSite(host, if (title.len > 0) title else host, tmpl, true);
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

pub fn nowEpoch() f64 {
    return 1_760_000_000.0 + ui.clock.now();
}
