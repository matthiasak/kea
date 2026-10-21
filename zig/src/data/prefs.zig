//! Everything there is to set (`Preferences` and `Widths` in Prefs.swift),
//! one defaults key per field, written through on every `set`. No
//! `@Published` invalidation: nanoui reads the fields directly each frame.
//! Not ported: `bench`/`benchRefused` (Bench.swift isn't).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Store = @import("store.zig").Store;
const keywords_file = @import("keywords.zig");
pub const Keyword = keywords_file.Keyword;
pub const Engine = @import("../model/engine.zig").Engine;

/// `SidebarPosition`.
pub const SidePosition = enum { left, right };
/// `Look` (Design.swift).
pub const Look = enum { light, dark, system };
/// `Glyph`.
pub const Glyph = enum { letters, icons };

pub const ReaderTheme = enum { auto, light, sepia, dark };
pub const ReaderWidth = enum { narrow, medium, wide };
// ponytail: Design.swift `Metrics` widths, here until design/metrics.zig (P3) holds them.
pub const side_std: f32 = 232;
pub const side_min: f32 = 176;
pub const side_max: f32 = 440;
pub const chat_std: f32 = 380;
pub const chat_min: f32 = 300;
pub const chat_max: f32 = 720;

/// `AIProvider.custom.home`.
const custom_server = "http://127.0.0.1:8080/v1/";

/// Field → defaults key, for every field `set` writes through.
pub const keys = .{
    .navigation_left = "toolbar.left",
    .look = "look",
    .sidebar = "sidebar",
    .side_position = "sidebar.position",
    .side_hides = "sidebar.hides",
    .side_width = "sidebar.width",
    .chat_width = "ai.width",
    .marks_width = "bookmarks.width",
    .glyph = "glyph",
    .engine = "search.engine",
    .custom_engine = "search.custom",
    .sleeps_tabs = "tabs.sleep",
    .site_notifications = "notifications.ask",
    .lazy_tabs = "tabs.lazy",
    .starts_fresh = "start.fresh",
    .searches_sites = "search.sites",
    .shows_reading = "tabs.reading",
    .shielded = "shield",
    .keeps_sign_ins = "sites.keep",
    .extensions_in_private = "extensions.private",
    .passkeys = "passkeys",
    .downloads = "downloads",
    .asks_where_to_save = "downloads.ask",
    .saves_passwords = "passwords.save",
    .fills_passwords = "passwords.fill",
    .welcomed = "welcomed",
    .autocorrect = "autocorrect",
    .page_zoom = "pageZoom",
    .reader_theme = "reader.theme",
    .reader_size = "reader.size",
    .reader_width = "reader.width",
    .auto_scroll = "autoscroll",
    .fast_pages = "pages.120",
    .peeks_links = "links.peek",
    .little_links = "links.little",
    .always_shows_downloads = "downloads.button",
    .bookmarks_bar = "bookmarks.bar",
    .bookmarks_sidebar = "bookmarks.sidebar",
    .chat_zoom = "ai.zoom",
    .chat_side = "ai.side",
    .marks_side = "bookmarks.side",
    .chat_popped = "ai.popped",
    .marks_popped = "bookmarks.popped",
    .handoff = "handoff",
    .shows_links = "links.show",
    .holds_history = "swipe.history",
    .float_flicks = "float.flicks",
    .kea_facts = "kea.facts",
    .floats_away = "float.away",
    .waits_for_play = "media.click",
    .floats_on_leave = "float.leave",
    .uses_spaces = "spaces",
    .uses_tab_groups = "tabs.groups",
    .lists_pins = "pins.list",
    .ai = "ai",
    .ai_provider = "ai.provider",
    .ai_server = "ai.server",
    .split_view = "splitView",
    .command_bar = "commandbar",
};

pub const InitOptions = struct {
    /// `Store.testing`: downloads go to `<root>/Downloads`, and WebKit's
    /// autocorrect key goes to the suite, never the user's standard defaults.
    testing: bool = false,
    /// The running `NSApp`, which `look` is applied to; null in headless tests.
    app: ?objc.Object = null,
};

pub const Prefs = struct {
    gpa: std.mem.Allocator,
    store: *const Store,
    opts: InitOptions,

    navigation_left: bool = false,
    look: Look = .system,
    sidebar: bool = false,
    side_position: SidePosition = .left,
    side_hides: bool = false,
    side_width: f32 = side_std,
    chat_width: f32 = chat_std,
    marks_width: f32 = side_std,
    glyph: Glyph = .letters,
    engine: Engine = .google,
    custom_engine: []u8 = &.{},
    /// `search.keywords`; replace through `setKeywords`.
    keywords: []Keyword = &.{},
    sleeps_tabs: bool = true,
    site_notifications: bool = true,
    lazy_tabs: bool = true,
    starts_fresh: bool = false,
    searches_sites: bool = false,
    shows_reading: bool = true,
    shielded: bool = true,
    keeps_sign_ins: bool = false,
    extensions_in_private: bool = false,
    passkeys: bool = false,
    /// Signed with the browser passkey entitlement; fixed for the process.
    passkeys_possible: bool = false,
    downloads: []u8 = &.{},
    asks_where_to_save: bool = false,
    saves_passwords: bool = true,
    fills_passwords: bool = true,
    welcomed: bool = false,
    autocorrect: bool = false,
    page_zoom: f64 = 1,
    reader_theme: ReaderTheme = .auto,
    reader_size: f64 = 18,
    reader_width: ReaderWidth = .medium,
    auto_scroll: bool = false,
    fast_pages: bool = false,
    peeks_links: bool = true,
    little_links: bool = false,
    always_shows_downloads: bool = false,
    bookmarks_bar: bool = false,
    bookmarks_sidebar: bool = false,
    chat_zoom: f64 = 1,
    /// null: away from the tab column.
    chat_side: ?SidePosition = null,
    marks_side: ?SidePosition = null,
    chat_popped: bool = false,
    marks_popped: bool = false,
    handoff: bool = true,
    shows_links: bool = true,
    holds_history: bool = false,
    float_flicks: bool = true,
    kea_facts: bool = true,
    floats_away: bool = false,
    waits_for_play: bool = false,
    floats_on_leave: bool = true,
    uses_spaces: bool = false,
    uses_tab_groups: bool = false,
    lists_pins: bool = false,
    ai: bool = true,
    /// An `AIProvider.id`; resolved against the catalog by its users.
    ai_provider: ?[]u8 = null,
    ai_server: []u8 = &.{},
    /// `ai.models`: provider id → model, where it isn't the default.
    ai_models: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    split_view: bool = false,
    command_bar: bool = false,

    /// `Preferences.init`, in Swift's order.
    pub fn init(gpa: std.mem.Allocator, store: *const Store, opts: InitOptions) Prefs {
        var p: Prefs = .{ .gpa = gpa, .store = store, .opts = opts };
        inline for (@typeInfo(@TypeOf(keys)).@"struct".field_names) |name| p.read(name);
        // Before the first window, and not deferred.
        if (opts.app) |app| objc.msg(void, app, "setAppearance:", .{appearance(p.look)});
        if (store.bool("sidebar") == null) {
            const manner = store.string("manner");
            defer if (manner) |m| gpa.free(m);
            p.sidebar = if (manner) |m| std.mem.eql(u8, m, "side") else false;
        }
        p.keywords = keywords_file.load(gpa, store) catch &.{};
        p.side_width = std.math.clamp(p.side_width, side_min, side_max);
        p.chat_width = std.math.clamp(p.chat_width, chat_min, chat_max);
        p.marks_width = std.math.clamp(p.marks_width, side_min, side_max);
        // A choice made while passkeys couldn't work is not a choice about them.
        const entitled = entitledToPasskeys();
        p.passkeys_possible = entitled;
        if (entitled and !(store.bool("passkeys.entitled") orelse false)) {
            p.passkeys = true;
            store.setBool("passkeys", true);
        } else {
            p.passkeys = store.bool("passkeys") orelse entitled;
        }
        store.setBool("passkeys.entitled", entitled);
        p.downloads = p.downloadsFolder() catch &.{};
        p.welcomed = (store.bool("welcomed") orelse false) or store.hasKey("glyph");
        if (p.ai_server.len == 0 and !store.hasKey("ai.server")) p.ai_server = gpa.dupe(u8, custom_server) catch &.{};
        p.readModels();
        store.remove("inspector");
        p.autocorrect = store.bool("autocorrect") orelse spellingCorrection();
        // Before the first web view exists: WebKit reads it once.
        p.tellWebKit(p.autocorrect);
        @import("../web/substitutions.zig").register(&p);
        p.chat_zoom = std.math.clamp(p.chat_zoom, 0.5, 2);
        p.reader_size = std.math.clamp(p.reader_size, 14, 26);
        inline for (.{ "mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open" }) |k| store.remove(k);
        return p;
    }

    pub fn deinit(self: *Prefs) void {
        self.gpa.free(self.custom_engine);
        self.gpa.free(self.downloads);
        self.gpa.free(self.ai_server);
        if (self.ai_provider) |s| self.gpa.free(s);
        keywords_file.freeList(self.gpa, self.keywords);
        self.freeModels();
    }

    /// The type `set` takes for `field`: strings by borrowed slice.
    pub fn Arg(comptime field: []const u8) type {
        return switch (@FieldType(Prefs, field)) {
            []u8 => []const u8,
            ?[]u8 => ?[]const u8,
            else => |T| T,
        };
    }

    /// Sets `field` and writes it through to its defaults key (`didSet`).
    pub fn set(self: *Prefs, comptime field: []const u8, value: Arg(field)) void {
        const T = @FieldType(Prefs, field);
        if (T == []u8) {
            const copy = self.gpa.dupe(u8, value) catch return;
            self.gpa.free(@field(self, field));
            @field(self, field) = copy;
        } else if (T == ?[]u8) {
            const copy = if (value) |v| (self.gpa.dupe(u8, v) catch return) else null;
            if (@field(self, field)) |old| self.gpa.free(old);
            @field(self, field) = copy;
        } else @field(self, field) = value;
        self.write(field);
        if (comptime std.mem.eql(u8, field, "look")) if (self.opts.app != null) applySoon(value);
        if (comptime std.mem.eql(u8, field, "autocorrect")) self.tellWebKit(value);
    }

    /// `setChatZoom`: tenths, 0.5…2.
    pub fn setChatZoom(self: *Prefs, value: f64) void {
        self.set("chat_zoom", std.math.clamp(@round(value * 10) / 10, 0.5, 2));
    }

    pub fn setKeywords(self: *Prefs, list: []const Keyword) void {
        keywords_file.save(self.gpa, self.store, list);
        const fresh = keywords_file.load(self.gpa, self.store) catch return;
        keywords_file.freeList(self.gpa, self.keywords);
        self.keywords = fresh;
    }

    /// `aiModel(for:)`: the chosen model, else the provider's `suggested`.
    pub fn aiModel(self: *const Prefs, provider_id: []const u8, suggested: []const u8) []const u8 {
        const chosen = std.mem.trim(u8, self.ai_models.get(provider_id) orelse "", " \t\r\n");
        return if (chosen.len == 0) suggested else chosen;
    }

    /// `setAIModel`: a model's name and nothing that isn't one.
    pub fn setAIModel(self: *Prefs, model: []const u8, provider_id: []const u8) void {
        const name = std.mem.trim(u8, model, " \t\r\n");
        if (name.len > 0 and !isModelName(name)) return;
        const value = self.gpa.dupe(u8, name) catch return;
        const entry = self.ai_models.getOrPut(self.gpa, provider_id) catch return self.gpa.free(value);
        if (entry.found_existing) self.gpa.free(entry.value_ptr.*) else entry.key_ptr.* = self.gpa.dupe(u8, provider_id) catch {
            _ = self.ai_models.orderedRemove(provider_id);
            return self.gpa.free(value);
        };
        entry.value_ptr.* = value;
        self.writeModels();
    }

    pub fn isModelName(name: []const u8) bool {
        for ([_][]const u8{ "sk-", "AIza", "AQ.", "gsk_", "hf_" }) |prefix| if (std.mem.startsWith(u8, name, prefix)) return false;
        if (name.len > 100) return false;
        for (name) |ch| switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', ':', '/', '@', '-' => {},
            else => return false,
        };
        return true;
    }

    /// `showsPinRows`.
    pub fn showsPinRows(self: *const Prefs) bool {
        return self.lists_pins and self.sidebar;
    }

    pub fn effectiveChatSide(self: *const Prefs) SidePosition {
        if (self.chat_side) |s| return s;
        return if (self.sidebar and self.side_position == .right) .left else .right;
    }

    /// `Browser.panelOnLeft(.bookmarks)`: as Ubi Chat, away from the tab column.
    pub fn effectiveMarksSide(self: *const Prefs) SidePosition {
        if (self.marks_side) |s| return s;
        return if (self.sidebar and self.side_position == .right) .left else .right;
    }

    // MARK: reading and writing one key

    fn read(self: *Prefs, comptime field: []const u8) void {
        const key = @field(keys, field);
        const s = self.store;
        const T = @FieldType(Prefs, field);
        switch (@typeInfo(T)) {
            .bool => if (s.bool(key)) |v| {
                @field(self, field) = v;
            },
            .float => if (s.double(key)) |v| {
                @field(self, field) = @floatCast(v);
            },
            .@"enum" => if (s.string(key)) |v| {
                defer self.gpa.free(v);
                if (std.meta.stringToEnum(T, v)) |e| @field(self, field) = e;
            },
            .optional => |o| if (s.string(key)) |v| {
                if (o.child == []u8) {
                    @field(self, field) = v;
                } else {
                    defer self.gpa.free(v);
                    @field(self, field) = std.meta.stringToEnum(o.child, v);
                }
            },
            .pointer => if (s.string(key)) |v| {
                @field(self, field) = v;
            },
            else => @compileError("no defaults reading for " ++ field),
        }
    }

    fn write(self: *Prefs, comptime field: []const u8) void {
        const key = @field(keys, field);
        const s = self.store;
        const v = @field(self, field);
        switch (@typeInfo(@TypeOf(v))) {
            .bool => s.setBool(key, v),
            .float => s.setDouble(key, v),
            .@"enum" => s.setString(key, @tagName(v)),
            .optional => |o| if (v) |x| s.setString(key, if (o.child == []u8) x else @tagName(x)) else s.remove(key),
            .pointer => s.setString(key, v),
            else => @compileError("no defaults writing for " ++ field),
        }
    }

    // MARK: side effects

    /// The test folder's Downloads (created), the saved one, or ~/Downloads.
    fn downloadsFolder(self: *Prefs) ![]u8 {
        if (self.opts.testing) {
            self.gpa.free(self.downloads);
            return self.store.folderFor("Downloads");
        }
        if (self.downloads.len > 0) return self.downloads;
        const pool = objc.Pool.push();
        defer pool.pop();
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        // NSDownloadsDirectory, NSUserDomainMask
        const urls = objc.msg(objc.Object, fm, "URLsForDirectory:inDomains:", .{ @as(objc.NSUInteger, 15), @as(objc.NSUInteger, 1) });
        const url = objc.msg(?objc.Object, urls, "firstObject", .{}) orelse return error.NoDownloads;
        return self.gpa.dupe(u8, objc.fromNSString(objc.msg(objc.Object, url, "path", .{})));
    }

    /// `ai.models` as `[String: String]`; anything else reads as empty.
    fn readModels(self: *Prefs) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const dict = objc.msg(?objc.Object, self.store.defaults, "dictionaryForKey:", .{objc.nsString("ai.models")}) orelse return;
        const all = objc.msg(objc.Object, dict, "allKeys", .{});
        const n = objc.msg(objc.NSUInteger, all, "count", .{});
        const string_class = objc.class("NSString");
        for (0..n) |i| {
            const k = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
            const v = objc.msg(objc.Object, dict, "objectForKey:", .{k});
            if (!objc.msg(objc.BOOL, k, "isKindOfClass:", .{string_class}) or !objc.msg(objc.BOOL, v, "isKindOfClass:", .{string_class})) {
                self.freeModels();
                return;
            }
            const key = self.gpa.dupe(u8, objc.fromNSString(k)) catch return;
            const value = self.gpa.dupe(u8, objc.fromNSString(v)) catch return self.gpa.free(key);
            self.ai_models.put(self.gpa, key, value) catch {
                self.gpa.free(key);
                self.gpa.free(value);
            };
        }
    }

    fn writeModels(self: *Prefs) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const dict = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
        var it = self.ai_models.iterator();
        while (it.next()) |e| objc.msg(void, dict, "setObject:forKey:", .{ objc.nsString(e.value_ptr.*), objc.nsString(e.key_ptr.*) });
        objc.msg(void, self.store.defaults, "setObject:forKey:", .{ dict, objc.nsString("ai.models") });
    }

    fn freeModels(self: *Prefs) void {
        var it = self.ai_models.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.ai_models.deinit(self.gpa);
        self.ai_models = .empty;
    }

    /// WebKit's text checker reads the app's standard defaults; a test run
    /// writes its suite instead.
    fn tellWebKit(self: *const Prefs, on: bool) void {
        const key = "WebAutomaticSpellingCorrectionEnabled";
        if (self.opts.testing) return self.store.setBool(key, on);
        const pool = objc.Pool.push();
        defer pool.pop();
        const standard = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
        objc.msg(void, standard, "setBool:forKey:", .{ on, objc.nsString(key) });
    }

    /// `Look.apply`: on the next turn of the run loop, never mid-frame.
    fn applySoon(look: Look) void {
        objc.dispatchMain(@ptrFromInt(@as(usize, @intFromEnum(look)) + 1), applyNow);
    }

    fn applyNow(ctx: ?*anyopaque) callconv(.c) void {
        const look: Look = @enumFromInt(@intFromPtr(ctx) - 1);
        const pool = objc.Pool.push();
        defer pool.pop();
        const app = objc.msg(?objc.Object, objc.class("NSApplication"), "sharedApplication", .{}) orelse return;
        const wanted = appearance(look);
        const current = objc.msg(?objc.Object, app, "appearance", .{});
        if (current == wanted) return;
        if (current != null and wanted != null and objc.msg(objc.BOOL, objc.msg(objc.Object, current.?, "name", .{}), "isEqualToString:", .{objc.msg(objc.Object, wanted.?, "name", .{})})) return;
        objc.msg(void, app, "setAppearance:", .{wanted});
        const wins = objc.msg(?objc.Object, app, "windows", .{}) orelse return;
        const sel = objc.sel("viewDidChangeEffectiveAppearance");
        for (0..objc.msg(objc.NSUInteger, wins, "count", .{})) |i| {
            const w = objc.msg(objc.Object, wins, "objectAtIndex:", .{i});
            const cv = objc.msg(?objc.Object, w, "contentView", .{}) orelse continue;
            objc.msg(void, cv, "viewDidChangeEffectiveAppearance", .{});
            if (objc.msg(?objc.Object, cv, "subviews", .{})) |subs| {
                for (0..objc.msg(objc.NSUInteger, subs, "count", .{})) |j| {
                    const sub = objc.msg(objc.Object, subs, "objectAtIndex:", .{j});
                    if (objc.msg(objc.BOOL, sub, "respondsToSelector:", .{sel}))
                        objc.msg(void, sub, "viewDidChangeEffectiveAppearance", .{});
                }
            }
        }
    }
};

/// `Look.appearance`: nil follows the Mac.
fn appearance(look: Look) ?objc.Object {
    const name = switch (look) {
        .light => "NSAppearanceNameAqua",
        .dark => "NSAppearanceNameDarkAqua",
        .system => return null,
    };
    return objc.msg(?objc.Object, objc.class("NSAppearance"), "appearanceNamed:", .{objc.nsString(name)});
}

fn spellingCorrection() bool {
    return objc.msg(objc.BOOL, objc.class("NSSpellChecker"), "isAutomaticSpellingCorrectionEnabled", .{});
}

extern "c" fn SecTaskCreateFromSelf(allocator: ?*anyopaque) ?*anyopaque;
extern "c" fn SecTaskCopyValueForEntitlement(task: *anyopaque, entitlement: objc.Object, err: ?*?*anyopaque) ?objc.Object;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" const kCFBooleanTrue: objc.Object;

/// `entitledToPasskeys`: asked of the running process's own signature.
fn entitledToPasskeys() bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const task = SecTaskCreateFromSelf(null) orelse return false;
    defer CFRelease(task);
    const value = SecTaskCopyValueForEntitlement(task, objc.nsString("com.apple.developer.web-browser.public-key-credential"), null) orelse return false;
    defer CFRelease(value);
    return value == kCFBooleanTrue;
}

test {
    _ = @import("prefs_test.zig");
}
