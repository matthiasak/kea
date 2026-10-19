//! Preferences backed by `NSUserDefaults` (the app's standard defaults, or
//! the `Kea.Options.suite` a test passes). No `@Published` invalidation
//! cascades: `nanoui` reads fields directly during each immediate-mode frame.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Store = @import("store.zig").Store;

pub const SidePosition = enum {
    left,
    right,

    pub fn fromStr(s: []const u8) ?SidePosition {
        if (std.mem.eql(u8, s, "right")) return .right;
        if (std.mem.eql(u8, s, "left")) return .left;
        return null;
    }

    pub fn asStr(self: SidePosition) []const u8 {
        return if (self == .right) "right" else "left";
    }
};

pub const Look = enum {
    system,
    light,
    dark,
};

pub const Prefs = struct {
    defaults: objc.Object,
    welcomed: bool = false,
    sidebar: bool = false,
    side_position: SidePosition = .left,
    side_hides: bool = false,
    side_width: f32 = 220,
    chat_width: f32 = 360,
    marks_width: f32 = 260,
    chat_side: ?SidePosition = null,
    marks_side: ?SidePosition = null,
    chat_popped: bool = false,
    marks_popped: bool = false,
    split_view: bool = true,
    uses_spaces: bool = true,
    shows_bookmarks_bar: bool = false,
    search_suggestions: bool = true,
    searches_sites: bool = true,
    look: Look = .system,

    pub fn init(store: *const Store) Prefs {
        const pool = objc.Pool.push();
        defer pool.pop();
        const defaults = if (store.suite) |suite|
            objc.msg(objc.Object, objc.alloc("NSUserDefaults"), "initWithSuiteName:", .{objc.nsString(suite)})
        else
            objc.retain(objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{}));

        var p: Prefs = .{ .defaults = defaults };
        p.reload();
        return p;
    }

    pub fn deinit(self: *Prefs) void {
        objc.release(self.defaults);
    }

    pub fn reload(self: *Prefs) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.welcomed = self.getBool("welcomed", false);
        self.sidebar = self.getBool("sidebar", false);
        if (self.getStr("sidebar.position")) |s| {
            self.side_position = SidePosition.fromStr(s) orelse .left;
        }
        self.side_hides = self.getBool("sidebar.hides", false);
        self.side_width = std.math.clamp(self.getFloat("sidebar.width", 220), 176, 360);
        self.chat_width = std.math.clamp(self.getFloat("ai.width", 360), 280, 720);
        self.marks_width = std.math.clamp(self.getFloat("bookmarks.width", 260), 176, 420);
        self.chat_side = if (self.getStr("ai.side")) |s| SidePosition.fromStr(s) else null;
        self.marks_side = if (self.getStr("bookmarks.side")) |s| SidePosition.fromStr(s) else null;
        self.chat_popped = self.getBool("ai.popped", false);
        self.marks_popped = self.getBool("bookmarks.popped", false);
        self.split_view = self.getBool("split.enabled", true);
        self.uses_spaces = self.getBool("spaces", true);
        self.shows_bookmarks_bar = self.getBool("bookmarks.bar", false);
        self.search_suggestions = self.getBool("search.suggestions", true);
        self.searches_sites = self.getBool("search.sites", true);
    }

    pub fn effectiveChatSide(self: *const Prefs) SidePosition {
        if (self.chat_side) |s| return s;
        return if (self.sidebar and self.side_position == .right) .left else .right;
    }

    pub fn effectiveMarksSide(self: *const Prefs) SidePosition {
        if (self.marks_side) |s| return s;
        return if (self.sidebar and self.side_position == .left) .right else .left;
    }

    pub fn setSideWidth(self: *Prefs, w: f32) void {
        self.side_width = std.math.clamp(w, 176, 360);
        self.setFloat("sidebar.width", self.side_width);
    }

    pub fn setChatWidth(self: *Prefs, w: f32) void {
        self.chat_width = std.math.clamp(w, 280, 720);
        self.setFloat("ai.width", self.chat_width);
    }

    pub fn setMarksWidth(self: *Prefs, w: f32) void {
        self.marks_width = std.math.clamp(w, 176, 420);
        self.setFloat("bookmarks.width", self.marks_width);
    }

    pub fn setSidebar(self: *Prefs, on: bool) void {
        self.sidebar = on;
        self.setBool("sidebar", on);
    }

    pub fn setSidePosition(self: *Prefs, pos: SidePosition) void {
        self.side_position = pos;
        self.setStr("sidebar.position", pos.asStr());
    }

    pub fn setChatSide(self: *Prefs, pos: ?SidePosition) void {
        self.chat_side = pos;
        if (pos) |p| self.setStr("ai.side", p.asStr()) else self.removeKey("ai.side");
    }

    pub fn setMarksSide(self: *Prefs, pos: ?SidePosition) void {
        self.marks_side = pos;
        if (pos) |p| self.setStr("bookmarks.side", p.asStr()) else self.removeKey("bookmarks.side");
    }

    pub fn setChatPopped(self: *Prefs, on: bool) void {
        self.chat_popped = on;
        self.setBool("ai.popped", on);
    }

    pub fn setMarksPopped(self: *Prefs, on: bool) void {
        self.marks_popped = on;
        self.setBool("bookmarks.popped", on);
    }

    pub fn setSplitView(self: *Prefs, on: bool) void {
        self.split_view = on;
        self.setBool("split.enabled", on);
    }

    fn hasKey(self: *const Prefs, key: []const u8) bool {
        return objc.msg(?objc.Object, self.defaults, "objectForKey:", .{objc.nsString(key)}) != null;
    }

    pub fn getBool(self: *const Prefs, key: []const u8, default: bool) bool {
        if (!self.hasKey(key)) return default;
        return objc.msg(objc.BOOL, self.defaults, "boolForKey:", .{objc.nsString(key)});
    }

    pub fn getFloat(self: *const Prefs, key: []const u8, default: f32) f32 {
        if (!self.hasKey(key)) return default;
        return @floatCast(objc.msg(f64, self.defaults, "doubleForKey:", .{objc.nsString(key)}));
    }

    pub fn getStr(self: *const Prefs, key: []const u8) ?[]const u8 {
        const obj = objc.msg(?objc.Object, self.defaults, "stringForKey:", .{objc.nsString(key)}) orelse return null;
        return objc.fromNSString(obj);
    }

    pub fn setBool(self: *Prefs, key: []const u8, val: bool) void {
        objc.msg(void, self.defaults, "setBool:forKey:", .{ if (val) objc.YES else objc.NO, objc.nsString(key) });
    }

    pub fn setFloat(self: *Prefs, key: []const u8, val: f32) void {
        objc.msg(void, self.defaults, "setDouble:forKey:", .{ @as(f64, val), objc.nsString(key) });
    }

    pub fn setStr(self: *Prefs, key: []const u8, val: []const u8) void {
        objc.msg(void, self.defaults, "setObject:forKey:", .{ objc.nsString(val), objc.nsString(key) });
    }

    pub fn removeKey(self: *Prefs, key: []const u8) void {
        objc.msg(void, self.defaults, "removeObjectForKey:", .{objc.nsString(key)});
    }
};
