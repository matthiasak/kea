//! ⌘F's page side (PageFind.swift) and the window's find state
//! (Browser.swift 349-532). The page's matches are counted and selected by
//! one script in Kea's world (`js/page_find_*.js`, verbatim, given its words
//! as arguments, never as source); a PDF falls back to WebKit's own find.
//! One question to the page at a time: letters typed while it answers wait,
//! and only the last is asked next. Answers for an older search are dropped.
//!
//! API: `find(b, query, opts)` looks from the first match, `step(b, ±1)`
//! moves, `clear(b)` ends it; the answer lands in `b.finder.result`
//! (`{index, count}`, one-based) a moment later.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Tab = @import("tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;
const config = @import("config.zig");

const script = @embedFile("js/page_find_a.js") ++ "\n" ++ @embedFile("js/page_find_b.js");

/// Matches measured at a time; Safari stops counting at the same number.
pub const limit = 1000;

pub const Result = struct {
    count: ?usize = null,
    /// One-based, as shown in the find bar.
    index: ?usize = null,
    /// More matches than `count` may follow.
    more: bool = false,
    found: bool = false,
    native_fallback: bool = false,
    whole_words_available: bool = true,
    available: bool = true,
    stale: bool = false,
};

const empty: Result = .{ .count = 0 };
const unavailable: Result = .{ .available = false };
const stale: Result = .{ .available = false, .stale = true };

pub const Options = struct { case: bool = false, words: bool = false };

/// The page a search is out on: its tab, and the view it was asked of.
const Web = struct { serial: u64, view: objc.Object };

/// `Browser.finder`.
pub const Find = struct {
    /// The bar is open (`finding`).
    finding: bool = false,
    /// What is looked for (`needle`, on the browser's `gpa`).
    needle: []u8 = &.{},
    match_case: bool = false,
    whole_words: bool = false,
    /// The page doesn't hold what was asked for.
    missed: bool = false,
    /// Goes up when the bar should take the keys (`findFocus`), and the
    /// last one the bar acted on.
    focus: u32 = 0,
    shown_focus: u32 = 0,
    result: ?Result = null,

    /// `PageFind.newestGeneration`.
    newest: u64 = 0,
    /// `findSpec`: the tab and the words, null when nothing is asked.
    spec_tab: ?u64 = null,
    spec_case: bool = false,
    spec_words: bool = false,
    spec_query: []u8 = &.{},
    web: ?Web = null,
    generation: u64 = 0,
    asking: ?u64 = null,
    asked: u64 = 0,
    fresh: bool = false,
    steps: i64 = 0,

    pub fn deinit(self: *Find, gpa: std.mem.Allocator) void {
        gpa.free(self.needle);
        gpa.free(self.spec_query);
    }

    /// A question out, or one waiting to be asked (`findBusy`).
    pub fn busy(self: *const Find) bool {
        return self.asking != null or self.fresh or self.steps != 0;
    }
};

fn blank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n").len == 0;
}

/// The view `w` names, if its tab is alive and still shows it.
fn viewOf(w: Web) ?*Tab {
    const t = Tab.alive(w.serial) orelse return null;
    return if (t.web == w.view) t else null;
}

// MARK: the window's half

/// `findStatus`: "3 of 17", "No matches", … or null with nothing asked.
pub fn status(b: *const Browser, buf: []u8) ?[]const u8 {
    const f = &b.finder;
    if (blank(f.needle)) return null;
    const r = f.result orelse return null;
    if (!r.available) return "Search unavailable";
    if (r.native_fallback) {
        if (f.whole_words and !r.whole_words_available) return "Whole words unavailable";
        return if (r.found) "Match found" else "No matches";
    }
    const index = r.index orelse return "No matches";
    const count = r.count orelse return "No matches";
    if (count == 0) return "No matches";
    return std.fmt.bufPrint(buf, "{d} of {d}{s}", .{ index, count, if (r.more) "+" else "" }) catch "No matches";
}

/// ⌘F.
pub fn openFind(b: *Browser) void {
    const t = b.activeTab() orelse return;
    if (t.isBlank()) return;
    b.finder.finding = true;
    b.finder.focus +%= 1;
    b.redraw();
}

/// Esc, or the bar's close: the page's own selection back, and the keys.
pub fn closeFind(b: *Browser) void {
    const f = &b.finder;
    if (!f.finding and f.needle.len == 0 and f.result == null) return;
    resetFindState(b);
    // The keyboard back to the page, as in Safari.
    if (b.activeTab()) |t| if (t.web) |wv| if (objc.msg(?objc.Object, wv, "window", .{})) |window| {
        const first = objc.msg(?objc.Object, window, "firstResponder", .{});
        const nsview = if (b.window) |w| if (w.surface) |s| s.nsview else null else null;
        if (first == null or first.? == window or first == nsview or objc.msg(objc.BOOL, first.?, "isKindOfClass:", .{objc.class("NSText")}))
            _ = objc.msg(objc.BOOL, window, "makeFirstResponder:", .{wv});
    };
    b.redraw();
}

/// The words typed (the `needle` didSet): a change looks again.
pub fn setNeedle(b: *Browser, text: []const u8) void {
    if (std.mem.eql(u8, b.finder.needle, text)) return;
    const copy = b.gpa.dupe(u8, text) catch return;
    b.gpa.free(b.finder.needle);
    b.finder.needle = copy;
    look(b, true);
}

pub fn setMatchCase(b: *Browser, on: bool) void {
    if (b.finder.match_case == on) return;
    b.finder.match_case = on;
    look(b, true);
}

pub fn setWholeWords(b: *Browser, on: bool) void {
    if (b.finder.whole_words == on) return;
    b.finder.whole_words = on;
    look(b, true);
}

/// `query` looked for on the front page, from its first match.
pub fn find(b: *Browser, query: []const u8, opts: Options) void {
    const copy = b.gpa.dupe(u8, query) catch return;
    b.gpa.free(b.finder.needle);
    b.finder.needle = copy;
    b.finder.match_case = opts.case;
    b.finder.whole_words = opts.words;
    look(b, true);
}

/// Next (+1) or Previous (−1).
pub fn step(b: *Browser, by: i8) void {
    look(b, by >= 0);
}

pub fn clear(b: *Browser) void {
    closeFind(b);
}

/// `look(forward:)`: the same words again are a step; new ones a new search.
pub fn look(b: *Browser, forward: bool) void {
    const f = &b.finder;
    const t = b.activeTab() orelse {
        f.missed = false;
        f.result = null;
        return;
    };
    // The front tab changed without `setActive` (a swap, a close, a space),
    // or the page asked is gone: what was asked of it is dropped, not waited on.
    if (f.spec_tab) |id| if (id != t.id or (f.web != null and viewOf(f.web.?) == null)) invalidatePage(b, false);
    if (blank(f.needle)) {
        f.missed = false;
        f.result = null;
        if (f.spec_tab == null and f.web == null) return;
        const w = f.web;
        forgetFind(b);
        if (w) |web| clearOn(b, web) else if (t.web) |wv| clearOn(b, .{ .serial = t.serial, .view = wv });
        return;
    }
    const wv = t.web orelse return;
    const same = f.spec_tab == t.id and std.mem.eql(u8, f.spec_query, f.needle) and f.spec_case == f.match_case and
        f.spec_words == f.whole_words and f.web != null and f.web.?.view == wv;
    if (!same) {
        const copy = b.gpa.dupe(u8, f.needle) catch return;
        b.gpa.free(f.spec_query);
        f.spec_query = copy;
        f.generation +%= 1;
        f.spec_tab = t.id;
        f.spec_case = f.match_case;
        f.spec_words = f.whole_words;
        f.web = .{ .serial = t.serial, .view = wv };
        f.fresh = true;
        f.steps = 0;
    } else f.steps += if (forward) 1 else -1;
    askFind(b);
}

/// Sends what is waiting, unless a question is still out: its answer
/// sends the next one.
fn askFind(b: *Browser) void {
    const f = &b.finder;
    if (f.asking != null or !(f.fresh or f.steps != 0)) return;
    const spec_tab = f.spec_tab orelse return;
    const w = f.web orelse return;
    f.asked +%= 1;
    const asking = f.asked;
    f.asking = asking;
    f.fresh = false;
    const steps = f.steps;
    f.steps = 0;
    const t = viewOf(w) orelse return dropAsk(b, asking);
    if (b.active_id != spec_tab or t.id != spec_tab) return dropAsk(b, asking);
    update(b, t, .{ .b = b, .serial = t.serial, .view = w.view, .asking = asking, .generation = f.generation, .steps = steps, .match_case = f.spec_case, .whole_words = f.spec_words }, f.spec_query);
}

fn dropAsk(b: *Browser, asking: u64) void {
    if (b.finder.asking == asking) b.finder.asking = null;
}

/// The page's answer for question `q`.
fn answered(q: *const Asked, r: Result) void {
    const b = q.b;
    const f = &b.finder;
    if (f.asking != q.asking) return;
    f.asking = null;
    const front = b.activeTab();
    if (!r.stale and f.generation == q.generation and f.spec_tab != null and b.active_id == f.spec_tab.? and
        front != null and front.?.web == q.view)
    {
        f.result = r;
        f.missed = r.available and !r.found and (!r.native_fallback or !q.whole_words or r.whole_words_available);
        b.redraw();
    }
    askFind(b);
}

/// Nothing asked or waiting any more; whatever answer is out is dropped.
fn forgetFind(b: *Browser) void {
    const f = &b.finder;
    f.generation +%= 1;
    f.spec_tab = null;
    f.web = null;
    f.asking = null;
    f.fresh = false;
    f.steps = 0;
}

fn clearOn(b: *Browser, w: Web) void {
    const t = viewOf(w) orelse return;
    b.finder.newest = @max(b.finder.newest, b.finder.generation);
    ask(t, "", false, false, 0, b.finder.generation, null);
}

fn resetFindState(b: *Browser) void {
    const f = &b.finder;
    const w = f.web;
    forgetFind(b);
    f.finding = false;
    b.gpa.free(f.needle);
    f.needle = &.{};
    f.match_case = false;
    f.whole_words = false;
    f.result = null;
    f.missed = false;
    if (w) |web| clearOn(b, web);
}

/// A tab or document changed under an open bar: what was typed stays,
/// every answer tied to the page that left goes.
pub fn invalidatePage(b: *Browser, retry: bool) void {
    const f = &b.finder;
    const w = f.web;
    forgetFind(b);
    f.result = null;
    f.missed = false;
    if (w) |web| clearOn(b, web);
    if (!retry or !f.finding or blank(f.needle)) return;
    const t = b.activeTab() orelse return;
    if (t.loading or t.isBlank()) return;
    look(b, true);
}

/// `didFinish`: the bar still open over a page that just came in.
pub fn arrived(t: *Tab) void {
    const b = t.browser orelse return;
    const f = &b.finder;
    if (t.id == b.active_id and f.finding and f.spec_tab == null and !blank(f.needle)) look(b, true);
}

// MARK: the page's half (`PageFind.update`)

const Asked = struct {
    b: *Browser,
    serial: u64,
    view: objc.Object,
    asking: u64,
    generation: u64,
    steps: i64,
    match_case: bool,
    whole_words: bool,
};

const Pending = struct {
    q: ?Asked,
    serial: u64,
    generation: u64,
};
const AnswerBlock = objc.Block(Pending, &.{ ?objc.Object, ?objc.Object });
const FoundBlock = objc.Block(Pending, &.{objc.Object});
const ca = std.heap.c_allocator;

fn update(b: *Browser, t: *Tab, q: Asked, query: []const u8) void {
    const f = &b.finder;
    if (q.generation < f.newest) return answered(&q, stale);
    f.newest = @max(f.newest, q.generation);
    if (blank(query)) {
        ask(t, "", false, false, 0, q.generation, null);
        return answered(&q, if (q.generation >= f.newest) empty else stale);
    }
    ask(t, query, q.match_case, q.whole_words, q.steps, q.generation, q);
}

/// `callAsyncJavaScript` with the words as arguments, in Kea's world.
fn ask(t: *Tab, query: []const u8, match_case: bool, whole_words: bool, steps: i64, generation: u64, q: ?Asked) void {
    const wv = t.web orelse return if (q) |a| answered(&a, unavailable);
    const pool = objc.Pool.push();
    defer pool.pop();
    const n = objc.class("NSNumber");
    var keys = [_]objc.Object{
        objc.nsString("query"), objc.nsString("matchCase"), objc.nsString("wholeWords"),
        objc.nsString("steps"), objc.nsString("limit"),     objc.nsString("generation"),
    };
    var values = [_]objc.Object{
        objc.nsString(query),
        objc.msg(objc.Object, n, "numberWithBool:", .{match_case}),
        objc.msg(objc.Object, n, "numberWithBool:", .{whole_words}),
        objc.msg(objc.Object, n, "numberWithLongLong:", .{@as(c_longlong, steps)}),
        objc.msg(objc.Object, n, "numberWithLongLong:", .{@as(c_longlong, limit)}),
        objc.msg(objc.Object, n, "numberWithUnsignedLongLong:", .{@as(c_ulonglong, generation)}),
    };
    const args = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, keys.len) });
    const p = ca.create(Pending) catch return;
    p.* = .{ .q = q, .serial = t.serial, .generation = generation };
    var block = AnswerBlock.init(p, evaluated);
    objc.msg(void, wv, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", .{
        objc.nsString(script), args, @as(?objc.Object, null), config.world(), @as(*anyopaque, @ptrCast(&block)),
    });
}

fn numberAt(d: objc.Object, key: []const u8) ?objc.Object {
    const v = objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString(key)}) orelse return null;
    return if (objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSNumber")})) v else null;
}

/// The question's window, if its tab is alive and still in it.
fn windowOf(p: *const Pending) ?*const Asked {
    const q = if (p.q) |*a| a else return null;
    const t = Tab.alive(p.serial) orelse return null;
    return if (t.browser == q.b) q else null;
}

fn evaluated(p: *Pending, value: ?objc.Object, err: ?objc.Object) void {
    const q = windowOf(p) orelse return ca.destroy(p);
    const newest = q.b.finder.newest;
    if (p.generation < newest) return finish(p, stale);
    if (err != null) return finish(p, unavailable);
    const d = value orelse return finish(p, unavailable);
    if (!objc.msg(objc.BOOL, d, "isKindOfClass:", .{objc.class("NSDictionary")})) return finish(p, unavailable);
    const s = objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString("status")}) orelse return finish(p, unavailable);
    if (!objc.msg(objc.BOOL, s, "isKindOfClass:", .{objc.class("NSString")})) return finish(p, unavailable);
    const said = objc.fromNSString(s);
    if (std.mem.eql(u8, said, "stale")) return finish(p, stale);
    if (std.mem.eql(u8, said, "pdf")) {
        if (q.whole_words) return finish(p, .{ .native_fallback = true, .whole_words_available = false });
        return nativeFind(p, q);
    }
    const count = numberAt(d, "count") orelse return finish(p, unavailable);
    const index = numberAt(d, "index") orelse return finish(p, unavailable);
    if (!std.mem.eql(u8, said, "ok")) return finish(p, unavailable);
    const c: usize = @intCast(@max(0, objc.msg(objc.NSInteger, count, "integerValue", .{})));
    const i: usize = @intCast(@max(0, objc.msg(objc.NSInteger, index, "integerValue", .{})));
    const more = if (numberAt(d, "more")) |m| objc.msg(objc.BOOL, m, "boolValue", .{}) else false;
    finish(p, .{ .count = c, .index = if (i == 0) null else i, .more = more, .found = c > 0 });
}

fn finish(p: *Pending, r: Result) void {
    defer ca.destroy(p);
    const q = windowOf(p) orelse return;
    answered(q, r);
}

/// A PDF: WebKit's own find, which says only whether there is a match.
fn nativeFind(p: *Pending, q: *const Asked) void {
    const t = Tab.alive(p.serial) orelse return ca.destroy(p);
    const wv = t.web orelse return finish(p, unavailable);
    const b = q.b;
    const words = viewQuery(b) orelse return finish(p, unavailable);
    const cfg = objc.msg(objc.Object, objc.class("WKFindConfiguration"), "new", .{});
    defer objc.release(cfg);
    objc.msg(void, cfg, "setBackwards:", .{q.steps < 0});
    objc.msg(void, cfg, "setCaseSensitive:", .{q.match_case});
    objc.msg(void, cfg, "setWraps:", .{objc.YES});
    var block = FoundBlock.init(p, foundNative);
    objc.msg(void, wv, "findString:withConfiguration:completionHandler:", .{ objc.nsString(words), cfg, @as(*anyopaque, @ptrCast(&block)) });
}

/// The words of the search the question belongs to.
fn viewQuery(b: *Browser) ?[]const u8 {
    return if (b.finder.spec_tab != null) b.finder.spec_query else null;
}

fn foundNative(p: *Pending, result: objc.Object) void {
    const q = windowOf(p) orelse return ca.destroy(p);
    if (p.generation < q.b.finder.newest) return finish(p, stale);
    const found = objc.msg(objc.BOOL, result, "matchFound", .{});
    finish(p, .{ .found = found, .native_fallback = true, .whole_words_available = false });
}
