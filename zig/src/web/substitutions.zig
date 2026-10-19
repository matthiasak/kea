//! The Mac's text substitutions inside pages, as in Safari (Substitutions.swift):
//! Text Replacement, Smart Quotes and Smart Dashes in Edit › Substitutions.
//! WebKit's text checker reads its switches once, from the app's standard
//! defaults; its own action for each flips it for every page and writes
//! the choice back there. Text replacement starts as the Mac has it, smart
//! quotes and dashes off. A test run writes its own suite instead.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../model/browser.zig").Browser;
const Prefs = @import("../data/prefs.zig").Prefs;

pub const Substitution = enum {
    quotes,
    dashes,
    replacement,

    pub fn title(s: Substitution) []const u8 {
        return switch (s) {
            .quotes => "Smart Quotes",
            .dashes => "Smart Dashes",
            .replacement => "Text Replacement",
        };
    }

    /// Where WebKit keeps it.
    pub fn key(s: Substitution) [:0]const u8 {
        return switch (s) {
            .quotes => "WebAutomaticQuoteSubstitutionEnabled",
            .dashes => "WebAutomaticDashSubstitutionEnabled",
            .replacement => "WebAutomaticTextReplacementEnabled",
        };
    }

    /// WebKit's own action for it, as Safari's menu sends it.
    pub fn action(s: Substitution) [:0]const u8 {
        return switch (s) {
            .quotes => "toggleAutomaticQuoteSubstitution:",
            .dashes => "toggleAutomaticDashSubstitution:",
            .replacement => "toggleAutomaticTextReplacement:",
        };
    }

    /// What the Mac says, for every app that hasn't been told otherwise.
    pub fn mac(s: Substitution) bool {
        const checker = objc.class("NSSpellChecker");
        return switch (s) {
            .quotes => objc.msg(objc.BOOL, checker, "isAutomaticQuoteSubstitutionEnabled", .{}),
            .dashes => objc.msg(objc.BOOL, checker, "isAutomaticDashSubstitutionEnabled", .{}),
            .replacement => objc.msg(objc.BOOL, checker, "isAutomaticTextReplacementEnabled", .{}),
        };
    }

    /// Where each starts when nothing was chosen in the menu.
    pub fn start(s: Substitution) bool {
        return if (s == .replacement) s.mac() else false;
    }

    /// Whether it's on in pages, asked of WebKit the way a menu's tick is;
    /// without a view yet, what WebKit will read.
    pub fn isOn(s: Substitution, prefs: *const Prefs, web: ?objc.Object) bool {
        const wv = web orelse return defaults(prefs).get(s);
        if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel(s.action())})) return defaults(prefs).get(s);
        const pool = objc.Pool.push();
        defer pool.pop();
        const item = objc.msg(objc.Object, objc.alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:", .{ objc.nsString(""), objc.sel(s.action()), objc.nsString("") });
        defer objc.release(item);
        _ = objc.msg(objc.BOOL, wv, "validateUserInterfaceItem:", .{item});
        return objc.msg(objc.NSInteger, item, "state", .{}) == 1;
    }

    /// Flipped for every page through WebKit's own action; without a view
    /// yet, written where WebKit will read it.
    pub fn toggle(s: Substitution, prefs: *const Prefs, web: ?objc.Object) void {
        if (web) |wv| if (objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel(s.action())})) {
            objc.msg(void, wv, s.action(), .{@as(?objc.Object, null)});
            return;
        };
        defaults(prefs).set(s, !s.isOn(prefs, null));
    }
};

/// The defaults WebKit reads: the app's standard ones, a test run's suite.
const Defaults = struct {
    d: objc.Object,

    fn get(self: Defaults, s: Substitution) bool {
        return objc.msg(objc.BOOL, self.d, "boolForKey:", .{objc.nsString(s.key())});
    }

    fn set(self: Defaults, s: Substitution, on: bool) void {
        objc.msg(void, self.d, "setBool:forKey:", .{ on, objc.nsString(s.key()) });
    }
};

fn defaults(prefs: *const Prefs) Defaults {
    if (prefs.opts.testing) return .{ .d = prefs.store.defaults };
    return .{ .d = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{}) };
}

/// Before the first web view: where each starts, registered — kept in
/// memory only, so a choice made in the menu stays the one that counts and
/// the Mac's setting is read afresh at each launch.
pub fn register(prefs: *const Prefs) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const start = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    for (std.enums.values(Substitution)) |s| {
        const on = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{s.start()});
        objc.msg(void, start, "setObject:forKey:", .{ on, objc.nsString(s.key()) });
    }
    objc.msg(void, defaults(prefs).d, "registerDefaults:", .{start});
}

/// `Browser.substitutes`: asked of the page in front.
pub fn substitutes(b: *Browser, s: Substitution) bool {
    return s.isOn(b.prefs, if (b.activeTab()) |t| t.web else null);
}

/// `Browser.toggleSubstitution`: sent to a page's view rather than to
/// whatever has the keyboard, so the address field having the caret
/// doesn't make it switch only that field.
pub fn toggleSubstitution(b: *Browser, s: Substitution) void {
    var web: ?objc.Object = if (b.activeTab()) |t| t.web else null;
    if (web == null) for (b.tabs.items) |t| if (t.web) |wv| {
        web = wv;
        break;
    };
    s.toggle(b.prefs, web);
    b.redraw();
}

/// The Mac's own panel of them, as Show Substitutions opens it in Safari.
pub fn showPanel() void {
    const checker = objc.msg(objc.Object, objc.class("NSSpellChecker"), "sharedSpellChecker", .{});
    objc.msg(void, objc.msg(objc.Object, checker, "substitutionsPanel", .{}), "orderFront:", .{@as(?objc.Object, null)});
}
