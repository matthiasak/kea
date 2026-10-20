//! `KeaPageView`, a `WKWebView` that reads the two-finger swipe for
//! itself (`PageView`, Tab.swift 1509-2070): the link menu's renames and
//! its ⌥ alternate, "Search with <engine>", the mouse's back and forward
//! buttons, keys the page didn't use kept quiet, the first frame held back
//! so a fresh view never flashes white, and the smart-zoom double tap. The
//! swipe itself is in `swipe.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const tab_mod = @import("tab.zig");
const Tab = tab_mod.Tab;
const swipe = @import("swipe.zig");
const state = @import("tab_state.zig");
const engine = @import("../model/engine.zig");

/// What one view keeps, on `c_allocator`, for as long as it is built.
pub const Page = struct {
    serial: u64,
    /// `unpainted`: held out of sight until WebKit has drawn something.
    unpainted: bool = false,
    /// `handed`: keys lately given to the page (timestamp, code, type).
    handed: [32]Key = undefined,
    handed_len: usize = 0,
    /// WebKit's Open Link in New Window and Search, handed on.
    open_link: Action = .{},
    behind_since: ?f64 = null,
    web_search: Action = .{},
    selection: ?[]u8 = null,
    swipe: swipe.State = .{},

    fn tab(self: *const Page) ?*Tab {
        return Tab.alive(self.serial);
    }
};

const Key = struct { at: f64, code: u16, kind: objc.NSUInteger };
const Action = struct { target: ?objc.Object = null, action: ?objc.SEL = null };

fn class() objc.Class {
    return objc.defineClass(.{
        .name = "KeaPageView",
        .superclass = "WKWebView",
        .methods = &.{
            .{ .name = "willOpenMenu:withEvent:", .imp = &willOpenMenu, .types = "v@:@@" },
            .{ .name = "keaOpenLinkBehind:", .imp = &openLinkBehind, .types = "v@:@" },
            .{ .name = "keaSearchSelection:", .imp = &searchSelection, .types = "v@:@" },
            .{ .name = "becomeFirstResponder", .imp = &becomeFirstResponder, .types = "B@:" },
            .{ .name = "mouseDown:", .imp = &mouseDown, .types = "v@:@" },
            .{ .name = "otherMouseDown:", .imp = &otherMouseDown, .types = "v@:@" },
            .{ .name = "swipeWithEvent:", .imp = &swipeWithEvent, .types = "v@:@" },
            .{ .name = "keyDown:", .imp = &keyDown, .types = "v@:@" },
            .{ .name = "smartMagnifyWithEvent:", .imp = &smartMagnify, .types = "v@:@" },
            .{ .name = "scrollWheel:", .imp = &scrollWheel, .types = "v@:@" },
        },
    });
}

fn superclass() objc.Class {
    return objc.class("WKWebView");
}

/// A view for `t`, retained (+1), built with `configuration`.
pub fn make(configuration: objc.Object, t: *Tab) objc.Object {
    const rect: objc.CGRect = .{ .size = .{ .width = 800, .height = 600 } };
    const view = objc.msg(objc.Object, objc.msg(objc.Object, class(), "alloc", .{}), "initWithFrame:configuration:", .{ rect, configuration });
    const page = std.heap.c_allocator.create(Page) catch @panic("OOM");
    page.* = .{ .serial = t.serial };
    objc.setZig(view, page);
    t.page = page;
    return view;
}

/// The view let go: what it kept, freed.
pub fn forget(t: *Tab, wv: objc.Object) void {
    objc.setZig(wv, null);
    t.pull = null;
    if (t.page) |p| {
        swipe.reset(p);
        if (p.selection) |s| std.heap.c_allocator.free(s);
        std.heap.c_allocator.destroy(p);
    }
    t.page = null;
}

fn pageOf(view: objc.Object) ?*Page {
    return objc.getZig(Page, view);
}

// MARK: the page's own right-click menu

fn findItem(menu: objc.Object, identifier: []const u8) ?struct { item: objc.Object, index: objc.NSInteger } {
    const items = objc.msg(objc.Object, menu, "itemArray", .{});
    const n = objc.msg(objc.NSUInteger, items, "count", .{});
    for (0..n) |i| {
        const item = objc.msg(objc.Object, items, "objectAtIndex:", .{i});
        const id = objc.msg(?objc.Object, item, "identifier", .{});
        if (std.mem.eql(u8, objc.fromNSString(id), identifier)) return .{ .item = item, .index = @intCast(i) };
    }
    return null;
}

fn willOpenMenu(self: objc.Object, _: objc.SEL, menu: objc.Object, event: objc.Object) callconv(.c) void {
    objc.msgSuper(void, self, superclass(), "willOpenMenu:withEvent:", .{ menu, event });
    const page = pageOf(self) orelse return;
    const t = page.tab() orelse return;
    // A new window's page arrives as a new tab, so the item says so: behind
    // this one, as a ⌘-click's goes; with ⌥ held, one that goes to it.
    if (findItem(menu, "WKMenuItemIdentifierOpenLinkInNewWindow")) |found| {
        if (objc.msg(?objc.Object, found.item, "copy", .{})) |front| {
            objc.msg(void, front, "setTitle:", .{objc.nsString("Open Link in New Tab and Go to It")});
            objc.msg(void, front, "setKeyEquivalentModifierMask:", .{@as(objc.NSUInteger, 1 << 19)});
            objc.msg(void, front, "setAlternate:", .{objc.YES});
            objc.msg(void, menu, "insertItem:atIndex:", .{ front, found.index + 1 });
            objc.release(front);
        }
        page.open_link = .{ .target = objc.msg(?objc.Object, found.item, "target", .{}), .action = objc.msg(?objc.SEL, found.item, "action", .{}) };
        objc.msg(void, found.item, "setTitle:", .{objc.nsString("Open Link in New Tab")});
        objc.msg(void, found.item, "setKeyEquivalentModifierMask:", .{@as(objc.NSUInteger, 0)});
        objc.msg(void, found.item, "setTarget:", .{self});
        objc.msg(void, found.item, "setAction:", .{objc.sel("keaOpenLinkBehind:")});
    }
    if (findItem(menu, "WKMenuItemIdentifierSearchWeb")) |found| {
        const b = t.browser orelse return;
        const name = b.prefs.engine.name(t.gpa, b.prefs.custom_engine) catch return;
        defer t.gpa.free(name);
        page.web_search = .{ .target = objc.msg(?objc.Object, found.item, "target", .{}), .action = objc.msg(?objc.SEL, found.item, "action", .{}) };
        if (page.selection) |s| std.heap.c_allocator.free(s);
        page.selection = null;
        t.evaluate(@embedFile("js/selected.js"), .client, readSelection, 0);
        var buf: [200]u8 = undefined;
        objc.msg(void, found.item, "setTitle:", .{objc.nsString(std.fmt.bufPrint(&buf, "Search with {s}", .{name}) catch "Search")});
        objc.msg(void, found.item, "setTarget:", .{self});
        objc.msg(void, found.item, "setAction:", .{objc.sel("keaSearchSelection:")});
    }
}

fn readSelection(t: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const page = t.page orelse return;
    const text = if (value) |v| (if (objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) objc.fromNSString(v) else "") else "";
    page.selection = std.heap.c_allocator.dupe(u8, text) catch null;
}

fn nsapp() objc.Object {
    return objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
}

fn openLinkBehind(self: objc.Object, _: objc.SEL, item: objc.Object) callconv(.c) void {
    const page = pageOf(self) orelse return;
    const action = page.open_link.action orelse return;
    page.behind_since = ui.clock.now();
    _ = objc.msg(objc.BOOL, nsapp(), "sendAction:to:from:", .{ action, page.open_link.target, item });
}

/// `takeBehind`: whether the tab being made now is the menu's, to stay
/// behind; the mark lasts a second and is used up.
pub fn takeBehind(view: objc.Object) bool {
    const page = pageOf(view) orelse return false;
    defer page.behind_since = null;
    const since = page.behind_since orelse return false;
    return ui.clock.now() - since < 1;
}

fn searchSelection(self: objc.Object, _: objc.SEL, item: objc.Object) callconv(.c) void {
    const page = pageOf(self) orelse return;
    defer if (page.selection) |s| {
        std.heap.c_allocator.free(s);
        page.selection = null;
    };
    const selection = page.selection orelse "";
    if (selection.len == 0) {
        if (page.web_search.action) |a| _ = objc.msg(objc.BOOL, nsapp(), "sendAction:to:from:", .{ a, page.web_search.target, item });
        return;
    }
    const words = std.mem.trim(u8, selection, " \t\r\n");
    if (words.len == 0) return;
    const t = page.tab() orelse return;
    const b = t.browser orelse return;
    const target = engine.url(t.gpa, words, b.prefs.engine.template(b.prefs.custom_engine)) catch return orelse return;
    defer t.gpa.free(target);
    _ = b.open(target, .{ .foreground = true, .from = t });
}

// MARK: pointer and keys

fn becomeFirstResponder(self: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const took = objc.msgSuper(objc.BOOL, self, superclass(), "becomeFirstResponder", .{});
    if (took) if (pageOf(self)) |page| if (page.tab()) |t| if (t.browser) |b| b.pageTookKeys(t);
    return took;
}

fn mouseDown(self: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    touched(self);
    objc.msgSuper(void, self, superclass(), "mouseDown:", .{event});
}

/// `onTouch`: the picture of a tab waking never stands in the way.
pub fn touched(view: objc.Object) void {
    const page = pageOf(view) orelse return;
    const t = page.tab() orelse return;
    state.uncover(t, 0);
}

/// Mouse buttons 3 and 4: back and forward (X11's order).
fn otherMouseDown(self: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    switch (objc.msg(objc.NSInteger, event, "buttonNumber", .{})) {
        3 => if (objc.msg(objc.BOOL, self, "canGoBack", .{})) {
            _ = objc.msg(?objc.Object, self, "goBack", .{});
            return;
        },
        4 => if (objc.msg(objc.BOOL, self, "canGoForward", .{})) {
            _ = objc.msg(?objc.Object, self, "goForward", .{});
            return;
        },
        else => {},
    }
    objc.msgSuper(void, self, superclass(), "otherMouseDown:", .{event});
}

/// Logi Options+ sends back and forward as a swipe.
fn swipeWithEvent(self: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const dx = objc.msg(f64, event, "deltaX", .{});
    if (dx > 0 and objc.msg(objc.BOOL, self, "canGoBack", .{})) {
        _ = objc.msg(?objc.Object, self, "goBack", .{});
    } else if (dx < 0 and objc.msg(objc.BOOL, self, "canGoForward", .{})) {
        _ = objc.msg(?objc.Object, self, "goForward", .{});
    } else objc.msgSuper(void, self, superclass(), "swipeWithEvent:", .{event});
}

fn keyOf(event: objc.Object) Key {
    return .{
        .at = objc.msg(f64, event, "timestamp", .{}),
        .code = objc.msg(u16, event, "keyCode", .{}),
        .kind = objc.msg(objc.NSUInteger, event, "type", .{}),
    };
}

/// Keys the page didn't use come back up the responder chain, where the
/// Mac would beep: the latest 32 handed over, none older than 2 s, are
/// recognised and kept quiet.
fn keyDown(self: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const page = pageOf(self) orelse return objc.msgSuper(void, self, superclass(), "keyDown:", .{event});
    const k = keyOf(event);
    for (page.handed[0..page.handed_len], 0..) |h, i| {
        if (h.at == k.at and h.code == k.code and h.kind == k.kind) {
            std.mem.copyForwards(Key, page.handed[i .. page.handed_len - 1], page.handed[i + 1 .. page.handed_len]);
            page.handed_len -= 1;
            return;
        }
    }
    var kept: usize = 0;
    for (page.handed[0..page.handed_len]) |h| if (k.at - h.at <= 2) {
        page.handed[kept] = h;
        kept += 1;
    };
    if (kept == page.handed.len) {
        std.mem.copyForwards(Key, page.handed[0 .. kept - 1], page.handed[1..kept]);
        kept -= 1;
    }
    page.handed[kept] = k;
    page.handed_len = kept + 1;
    objc.msgSuper(void, self, superclass(), "keyDown:", .{event});
}

// MARK: the first frame

/// `_WKRenderingProgressEventFirstVisuallyNonEmptyLayout`.
pub const first_frame: objc.NSUInteger = 1 << 1;

/// `holdForFirstFrame`: unseen until WebKit says something is drawn.
pub fn holdForFirstFrame(t: *Tab) void {
    const wv = t.web orelse return;
    const page = t.page orelse return;
    if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_setObservedRenderingProgressEvents:")})) return;
    objc.msg(void, wv, "_setObservedRenderingProgressEvents:", .{first_frame});
    page.unpainted = true;
    objc.msg(void, wv, "setAlphaValue:", .{@as(f64, 0)});
}

/// `showFirstFrame`: in, the page is there.
pub fn showFirstFrame(view: objc.Object) void {
    const page = pageOf(view) orelse return;
    if (!page.unpainted) return;
    page.unpainted = false;
    if (page.tab()) |t| if (t.browser) |b| if (b.stage_host) |sh| if (sh.holds(view)) return b.redraw();
    objc.msg(void, view, "setAlphaValue:", .{@as(f64, 1)});
}

pub fn unpainted(view: objc.Object) bool {
    const page = pageOf(view) orelse return false;
    return page.unpainted;
}

// MARK: two fingers

/// The page's word on whether a sideways swipe is its own (`answer(free:)`).
pub fn answer(t: *Tab, free: bool) void {
    const page = t.page orelse return;
    const wv = t.web orelse return;
    swipe.answer(page, wv, free);
}

fn scrollWheel(self: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    touched(self);
    const page = pageOf(self) orelse return objc.msgSuper(void, self, superclass(), "scrollWheel:", .{event});
    // The page gets every event first, except up and down while the list
    // is open; the gesture's end still reaches it.
    const phase = objc.msg(objc.NSUInteger, event, "phase", .{});
    if (page.swipe.stops_len == 0 or phase == swipe.phase_ended or phase == swipe.phase_cancelled)
        objc.msgSuper(void, self, superclass(), "scrollWheel:", .{event});
    swipe.wheel(page, self, event);
}

/// Two fingers tapped twice: the block under them fills the width.
fn smartMagnify(self: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    if (!objc.msg(objc.BOOL, self, "allowsMagnification", .{})) return objc.msgSuper(void, self, superclass(), "smartMagnifyWithEvent:", .{event});
    const page = pageOf(self) orelse return;
    const t = page.tab() orelse return;
    const at = objc.msg(objc.CGPoint, self, "convertPoint:fromView:", .{ objc.msg(objc.CGPoint, event, "locationInWindow", .{}), @as(?objc.Object, null) });
    const scale = objc.msg(f64, self, "magnification", .{});
    const width = objc.msg(objc.CGRect, self, "bounds", .{}).size.width;
    var buf: [2400]u8 = undefined;
    const js = std.fmt.bufPrint(&buf, @embedFile("js/smart_zoom.js"), .{ at.x, at.y, scale, width }) catch return;
    smart_point = at;
    t.evaluate(js, .page, zoomed, 0);
}

var smart_point: objc.CGPoint = .{};

fn zoomed(t: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const wv = t.web orelse return;
    const v = value orelse return;
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) return;
    const Smart = struct { scale: f64, x: f64, y: f64 };
    const parsed = std.json.parseFromSlice(Smart, t.gpa, objc.fromNSString(v), .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    objc.msg(void, wv, "setMagnification:centeredAtPoint:", .{ parsed.value.scale, smart_point });
    var buf: [96]u8 = undefined;
    t.evaluate(std.fmt.bufPrint(&buf, "window.scrollTo({d}, {d})", .{ parsed.value.x, parsed.value.y }) catch return, .page, null, 0);
}
