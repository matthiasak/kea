//! `ExtensionPopup` (ExtensionPopup.swift): an extension's popup page, in a
//! small window of Kea's own hanging from its button — the page loaded in
//! a view built from the extension's configuration, which talks to its
//! worker where WebKit's own popover sometimes doesn't. Sized the way Chrome
//! sizes a popup (25…800 × 25…600), measured while still the 25-point square
//! and unseen, then followed as it grows; window.close(), a link out of it,
//! a press on its button or anywhere else closes it. The hooks the
//! controller calls (`del.on_popup`, `del.popup_closes`,
//! `answer.popup_client`) are set by `install`. The page's window and tab
//! for WebKit: `popup_page.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Kea = @import("../app/kea.zig").Kea;
const palette = @import("../design/palette.zig");
const StageHost = @import("../web/stage_host.zig").StageHost;
const controller = @import("controller.zig");
const Extensions = controller.Extensions;
const buttons = @import("controller_buttons.zig");
const answer = @import("shims/answer.zig");
const popup_page = @import("popup_page.zig");
const CGRect = objc.CGRect;
const CGSize = objc.CGSize;

const heap = std.heap.c_allocator;

pub const Popup = struct {
    serial: u64,
    owner: u64,
    kea: *Kea,
    window: *nanoui.Window = undefined,
    host: ?*StageHost = null,
    /// Retained.
    web: objc.Object,
    /// The `PopupPage` WebKit was told of (retained).
    page: ?objc.Object = null,
    id: []u8,
    /// The extension's own button it hangs from, when it does (window
    /// coordinates, top left).
    button: ?struct { window: objc.Object, rect: CGRect } = null,
    /// Where it hangs from, on screen, and which way.
    spot: CGRect = .{},
    trailing: bool = false,
    size: CGSize,
    ready: bool = false,
    shown: bool = false,
    measuring: bool = false,
    ticks: u32 = 0,
    was_key: bool = false,
    applied: ?ui.Color = null,
};

var current: ?*Popup = null;
var serials: u64 = 0;
/// Each extension's popup size, so the next opening starts there.
var last_size: std.StringHashMapUnmanaged(CGSize) = .empty;
/// The popup a press on its own button just closed, and when.
var closed_by_button: ?struct { id: [64]u8, len: usize, at: f64 } = null;

/// The popup up now, for tests.
pub fn up() ?*Popup {
    return current;
}

/// The controller's hooks: shown from a press, closed by one, listed to its worker.
pub fn install(e: *Extensions) void {
    e.del.on_popup = onPopup;
    e.del.popup_closes = closes;
    e.answer.popup_client = client;
}

fn onPopup(e: *Extensions, url: []const u8, context: objc.Object, anchor: []const u8) void {
    show(e, url, context, anchor);
}

/// The popup as its extension's worker finds it in clients.matchAll().
fn client(_: *Extensions, id: []const u8) ?answer.PopupClient {
    const p = current orelse return null;
    if (!std.mem.eql(u8, p.id, id)) return null;
    const u = objc.msg(?objc.Object, p.web, "URL", .{}) orelse return null;
    const visible = p.window.isVisible();
    return .{ .url = objc.fromNSString(objc.msg(objc.Object, u, "absoluteString", .{})), .visible = visible, .focused = visible and p.window.isFocused() };
}

/// A press on the button of an extension whose popup is up closes it, as in
/// Chrome — whether it is still there or went on this click's mouse-down.
fn closes(_: *Extensions, id: []const u8) bool {
    defer closed_by_button = null;
    if (current) |p| if (std.mem.eql(u8, p.id, id)) {
        close();
        return true;
    };
    const was = closed_by_button orelse return false;
    return std.mem.eql(u8, was.id[0..was.len], id) and ui.clock.now() - was.at < 1.5;
}

fn px(v: f32) ui.Length {
    return .{ .px = v };
}

pub fn show(e: *Extensions, url: []const u8, context: objc.Object, anchor_key: []const u8) void {
    close();
    const kea = e.kea;
    const app = kea.ui_app orelse return;
    if (kea.opts.headless) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const configuration = objc.msg(?objc.Object, context, "webViewConfiguration", .{}) orelse return;
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse return;
    const id = objc.fromNSString(objc.msg(objc.Object, context, "uniqueIdentifier", .{}));
    // Sized the way Chrome sizes a popup, unseen, while the window already
    // stands at the size this popup had last time.
    const web = objc.msg(objc.Object, objc.alloc("WKWebView"), "initWithFrame:configuration:", .{ CGRect{ .size = .{ .width = 25, .height = 25 } }, configuration });
    const d = popup_page.delegate();
    objc.msg(void, web, "setUIDelegate:", .{d});
    objc.msg(void, web, "setNavigationDelegate:", .{d});
    objc.msg(void, web, "setAlphaValue:", .{@as(f64, 0)});
    objc.msg(void, web, "loadRequest:", .{objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl})});

    const owned_id = heap.dupe(u8, id) catch return objc.release(web);
    const self = heap.create(Popup) catch {
        heap.free(owned_id);
        return objc.release(web);
    };
    serials += 1;
    self.* = .{
        .serial = serials,
        .owner = e.serial,
        .kea = kea,
        .web = web,
        .id = owned_id,
        .size = last_size.get(id) orelse .{ .width = 360, .height = 240 },
    };
    const hidden = kea.opts.hidden;
    const off: ?f64 = if (hidden) -20000 else null;
    self.window = app.newWindow(.{
        .width = self.size.width,
        .height = self.size.height,
        .min_width = 25,
        .min_height = 25,
        .resizable = false,
        .title_bar = .hidden,
        .visible = false,
        .x = off,
        .y = off,
        .kind = .panel,
        .on_close = .{ .ctx = self, .func = closed },
        .on_key = .{ .ctx = self, .func = keyChanged },
        .content = .{ .view = ui.View.init(self, view) },
    }) catch {
        objc.release(web);
        heap.free(self.id);
        heap.destroy(self);
        return;
    };
    current = self;
    const ns = self.window.nswindow;
    // A popover's frame: no buttons of its own, not dragged about.
    for (0..3) |i| if (objc.msg(?objc.Object, ns, "standardWindowButton:", .{@as(objc.NSUInteger, i)})) |btn| objc.msg(void, btn, "setHidden:", .{objc.YES});
    objc.msg(void, ns, "setMovable:", .{objc.NO});
    objc.msg(void, ns, "setHidesOnDeactivate:", .{objc.NO});
    if (self.window.surface) |s| {
        self.host = StageHost.create(heap, s) catch null;
        // In the window while unseen: WebKit suspends a page that is in none.
        if (self.host) |h| objc.msg(void, h.stage_view, "addSubview:", .{web});
    }
    self.ready = true;
    // WebKit hears of the popup as a page of the browser's window.
    self.page = popup_page.make(self);
    objc.msg(void, e.controller, "didOpenTab:", .{self.page.?});
    if (e.del.anchors.get(anchor_key)) |a| if (a.window) |w| if (std.mem.eql(u8, anchor_key, id)) {
        self.button = .{ .window = w, .rect = a.rect };
    };
    hangFrom(self, e, anchor_key);
    if (self.window.surface) |s| s.frame();
    // Never a test run's in front: a run started hidden stays off every screen.
    if (!hidden and kea.opts.root == null) objc.msg(void, ns, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    // Measured when the document is built or has loaded; a page slow to
    // do either is measured anyway after a moment, and shown regardless
    // a little later.
    objc.dispatchAfter(3 * std.time.ns_per_s, tick(self), measureLater);
    objc.dispatchAfter(5 * std.time.ns_per_s, tick(self), revealLater);
}

fn tick(self: *Popup) ?*anyopaque {
    return @ptrFromInt(self.serial);
}

fn mine(ctx: ?*anyopaque) ?*Popup {
    const p = current orelse return null;
    return if (p.serial == @intFromPtr(ctx)) p else null;
}

fn measureLater(ctx: ?*anyopaque) callconv(.c) void {
    const p = mine(ctx) orelse return;
    firstMeasure(p);
    follow(p);
}

fn revealLater(ctx: ?*anyopaque) callconv(.c) void {
    reveal(mine(ctx) orelse return);
}

/// The window's spot: its own button when on screen, else the puzzle
/// button; with neither (the column or the strip folded away), where the
/// buttons would be — the column's foot, or the strip's far end.
fn hangFrom(self: *Popup, e: *Extensions, anchor_key: []const u8) void {
    if (self.kea.opts.hidden) return;
    const b = e.browser();
    self.trailing = if (b) |x| x.prefs.sidebar else false;
    if (e.del.anchors.get(anchor_key)) |a| if (a.window) |w| {
        self.spot = onScreen(w, a.rect);
        return place(self);
    };
    const w = (b orelse return).window orelse return;
    const content = objc.msg(objc.CGRect, objc.msg(objc.Object, w.nswindow, "contentView", .{}), "bounds", .{});
    const spot: CGRect = if (self.trailing)
        .{ .origin = .{ .x = 24, .y = content.size.height - 24 }, .size = .{ .width = 1, .height = 1 } }
    else
        .{ .origin = .{ .x = content.size.width - 60, .y = 40 }, .size = .{ .width = 1, .height = 1 } };
    self.spot = onScreen(w.nswindow, spot);
    place(self);
}

/// A rect of a window's view (top left) on screen (bottom left).
fn onScreen(window: objc.Object, r: CGRect) CGRect {
    const h = objc.msg(objc.CGRect, objc.msg(objc.Object, window, "contentView", .{}), "bounds", .{}).size.height;
    const in_window: CGRect = .{ .origin = .{ .x = r.origin.x, .y = h - r.origin.y - r.size.height }, .size = r.size };
    return objc.msg(CGRect, window, "convertRectToScreen:", .{in_window});
}

/// Under its spot, centred on it, or out to its right from the column;
/// kept on the screen.
fn place(self: *Popup) void {
    if (self.kea.opts.hidden) return;
    const s = self.spot;
    const size = self.size;
    const gap: f64 = 6;
    var frame: CGRect = .{ .size = size };
    if (self.trailing) {
        frame.origin = .{ .x = s.origin.x + s.size.width + gap, .y = s.origin.y + s.size.height / 2 - size.height / 2 };
    } else {
        frame.origin = .{ .x = s.origin.x + s.size.width / 2 - size.width / 2, .y = s.origin.y - gap - size.height };
    }
    const ns = self.window.nswindow;
    const screen = objc.msg(?objc.Object, ns, "screen", .{}) orelse objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{});
    if (screen) |sc| {
        const v = objc.msg(CGRect, sc, "visibleFrame", .{});
        frame.origin.x = @max(v.origin.x, @min(frame.origin.x, v.origin.x + v.size.width - size.width));
        frame.origin.y = @max(v.origin.y, @min(frame.origin.y, v.origin.y + v.size.height - size.height));
    }
    objc.msg(void, ns, "setFrame:display:", .{ frame, objc.YES });
}

fn view(self: *Popup, c: *ui.Context) void {
    c.hand_cursor = false;
    if (!self.ready) return;
    const p = palette.get(c.theme.dark);
    if (self.applied == null or !std.meta.eql(self.applied.?, p.ground)) {
        self.applied = p.ground;
        const g = p.ground;
        const color = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ @as(f64, g.r), @as(f64, g.g), @as(f64, g.b), @as(f64, 1) });
        objc.msg(void, self.window.nswindow, "setBackgroundColor:", .{color});
    }
    const page = c.open(.{ .width = .fill, .height = .fill }, "kea.popup.page");
    c.addStageHoleNode(page);
    c.end();
}

/// The page, at the window's size, in view.
fn reveal(self: *Popup) void {
    if (self.shown) return;
    self.shown = true;
    if (self.host) |h| h.setPage(self.web, false);
    _ = objc.msg(objc.BOOL, self.window.nswindow, "makeFirstResponder:", .{self.web});
    // Faded in over 0.12 s, as Swift's `web.animator().alphaValue = 1`
    // (the stage shows a new page at once: from nothing again).
    objc.msg(void, self.web, "setAlphaValue:", .{@as(f64, 0)});
    const ctx = objc.class("NSAnimationContext");
    objc.msg(void, ctx, "beginGrouping", .{});
    objc.msg(void, objc.msg(objc.Object, ctx, "currentContext", .{}), "setDuration:", .{@as(f64, 0.12)});
    objc.msg(void, objc.msg(objc.Object, self.web, "animator", .{}), "setAlphaValue:", .{@as(f64, 1)});
    objc.msg(void, ctx, "endGrouping", .{});
    if (self.window.surface) |s| s.frame();
}

fn apply(self: *Popup, size: CGSize) void {
    if (@abs(size.width - self.size.width) > 1 or @abs(size.height - self.size.height) > 1) {
        self.size = size;
        if (self.kea.opts.hidden) self.window.setSize(size.width, size.height) else place(self);
    }
    const key = heap.dupe(u8, self.id) catch return reveal(self);
    const got = last_size.getOrPut(heap, key) catch {
        heap.free(key);
        return reveal(self);
    };
    if (got.found_existing) heap.free(key);
    got.value_ptr.* = size;
    reveal(self);
}

// MARK: measuring

/// Chrome's size for the popup (Blink's auto-size), worked out in the page
/// while its view is still the 25-point square (ExtensionPopup.preferred).
const preferred =
    \\() => {
    \\  const d = document.documentElement;
    \\  if (!d) return null;
    \\  const m = window.__keaSizing || (window.__keaSizing = {});
    \\  const saved = d.getAttribute("style");
    \\  const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
    \\  const box = d.getBoundingClientRect();
    \\  let w;
    \\  if (Math.abs(box.width - innerWidth) > 1) w = m.w = box.width;
    \\  else if (m.w && Math.abs(m.w - innerWidth) <= 1) w = m.w;
    \\  else {
    \\    d.style.setProperty("width", "min-content", "important");
    \\    const narrowest = d.getBoundingClientRect().width;
    \\    back();
    \\    w = narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
    \\  }
    \\  w = Math.min(800, Math.max(25, Math.ceil(w)));
    \\  d.style.setProperty("width", w + "px", "important");
    \\  let h = d.getBoundingClientRect().height;
    \\  if (Math.abs(h - innerHeight) > 1) m.h = h;
    \\  else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
    \\  else {
    \\    d.style.setProperty("height", "auto", "important");
    \\    d.style.setProperty("min-height", "0", "important");
    \\    h = d.getBoundingClientRect().height;
    \\  }
    \\  back();
    \\  return [w, Math.min(600, Math.max(25, Math.ceil(h)))];
    \\}
;

/// How far the page reaches (ExtensionPopup.reach).
const reach =
    \\((key) => {
    \\  const d = document.documentElement;
    \\  if (!d) return null;
    \\  if (key === "height") return d.scrollHeight;
    \\  const own = d.getBoundingClientRect().width;
    \\  if (own > innerWidth + 1) return own;
    \\  const saved = d.getAttribute("style");
    \\  d.style.setProperty("width", "min-content", "important");
    \\  const narrowest = d.getBoundingClientRect().width;
    \\  saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
    \\  return narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
    \\})
;

const measure_js = "(" ++ preferred ++ ")()";
const grow_js = "[" ++ reach ++ "('width'), (() => { const d = document.documentElement; return d && d.scrollHeight > d.clientHeight ? d.scrollHeight : 0; })(), (() => { const m = window.__keaSizing || (window.__keaSizing = {}), w = document.documentElement.getBoundingClientRect().width; if (Math.abs(w - innerWidth) > 1) return m.w = w; return m.w && Math.abs(m.w - innerWidth) <= 1 ? m.w : 0; })()]";

const Kind = enum { first, follow, grow };
const Said = objc.Block(u8, &.{ ?objc.Object, ?objc.Object });

fn eval(self: *Popup, js: []const u8, comptime kind: Kind) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    var block = Said.init(@ptrFromInt(self.serial), struct {
        fn f(ctx: *u8, result: ?objc.Object, _: ?objc.Object) void {
            const p = mine(ctx) orelse return;
            var n: [3]f64 = undefined;
            const got = numbers(result, &n) orelse return;
            switch (kind) {
                .first => if (got == 2 and !p.shown) apply(p, .{ .width = n[0], .height = n[1] }),
                .follow => if (got == 2) {
                    if (@abs(n[0] - p.size.width) > 2 or @abs(n[1] - p.size.height) > 2) apply(p, .{ .width = n[0], .height = n[1] });
                },
                .grow => if (got == 3) {
                    const now = p.size;
                    const width = if (n[2] > 0) @max(25, @ceil(n[2])) else @max(now.width, n[0]);
                    const wanted: CGSize = .{ .width = @min(800, width), .height = @min(600, @max(now.height, n[1])) };
                    if (wanted.width != now.width or wanted.height != now.height) apply(p, wanted);
                },
            }
        }
    }.f);
    objc.msg(void, self.web, "evaluateJavaScript:completionHandler:", .{ objc.nsString(js), @as(*anyopaque, @ptrCast(&block)) });
}

/// An NSArray of numbers into `out`; how many there were.
fn numbers(result: ?objc.Object, out: *[3]f64) ?usize {
    const arr = result orelse return null;
    if (!objc.msg(objc.BOOL, arr, "isKindOfClass:", .{objc.class("NSArray")})) return null;
    const n = objc.msg(objc.NSUInteger, arr, "count", .{});
    if (n > out.len) return null;
    for (0..n) |i| {
        const v = objc.msg(objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSNumber")})) return null;
        out[i] = objc.msg(f64, v, "doubleValue", .{});
    }
    return n;
}

/// Measured while still the 25-point square and unseen, then shown at the size found.
pub fn firstMeasure(self: *Popup) void {
    if (self.shown) return;
    eval(self, measure_js, .first);
}

/// From the page's first load: sized, then followed as it grows, for as
/// long as it's open — for its first two seconds either way, after that
/// only growing, and after six seconds once a second.
pub fn follow(self: *Popup) void {
    if (self.measuring) return;
    if (!self.shown) firstMeasure(self);
    self.measuring = true;
    self.ticks = 0;
    objc.dispatchAfter(std.time.ns_per_s / 4, tick(self), grow);
}

fn grow(ctx: ?*anyopaque) callconv(.c) void {
    const p = mine(ctx) orelse return;
    objc.dispatchAfter(std.time.ns_per_s / 4, ctx, grow);
    if (!p.shown) return;
    p.ticks += 1;
    if (p.ticks <= 8) return eval(p, measure_js, .follow);
    if (p.ticks > 24 and p.ticks % 4 != 0) return;
    eval(p, grow_js, .grow);
}

// MARK: closing

/// Closed, and WebKit told its window and tab are gone.
pub fn close() void {
    const p = current orelse return;
    current = null;
    p.window.close();
}

/// The popup of `kea`'s, as it goes.
pub fn closeFor(kea: *Kea) void {
    if (current) |p| if (p.kea == kea) close();
}

/// The popup showing `web`, if one is up.
pub fn of(web: objc.Object) ?*Popup {
    const p = current orelse return null;
    return if (p.web == web) p else null;
}

/// Whether `window` is the extension popup's own panel.
pub fn owns(window: ?objc.Object) bool {
    const p = current orelse return false;
    const w = window orelse return false;
    return p.window.nswindow == w;
}

/// Transient, as a popover: it goes when anything else takes the keys. A
/// click on its own button that did it is remembered, so that press
/// doesn't open it again.
fn keyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
    const self: *Popup = @ptrCast(@alignCast(ctx));
    if (w.isFocused()) {
        self.was_key = true;
        return;
    }
    if (!self.was_key or current != self) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (self.button) |btn| if (objc.msg(?objc.Object, objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{}), "currentEvent", .{})) |ev| {
        const kind = objc.msg(objc.NSUInteger, ev, "type", .{});
        if ((kind == 1 or kind == 2) and objc.msg(?objc.Object, ev, "window", .{}) == btn.window) {
            const at = objc.msg(objc.CGPoint, ev, "locationInWindow", .{});
            const h = objc.msg(CGRect, objc.msg(objc.Object, btn.window, "contentView", .{}), "bounds", .{}).size.height;
            const r = btn.rect;
            const y = h - at.y;
            if (at.x >= r.origin.x and at.x <= r.origin.x + r.size.width and y >= r.origin.y and y <= r.origin.y + r.size.height and self.id.len <= 64) {
                closed_by_button = .{ .id = undefined, .len = self.id.len, .at = ui.clock.now() };
                @memcpy(closed_by_button.?.id[0..self.id.len], self.id);
            }
        }
    };
    close();
}

/// `windowWillClose`: everything the popup held let go.
fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
    const self: *Popup = @ptrCast(@alignCast(ctx));
    if (current == self) current = null;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (self.page) |page| {
        if (controller.alive(self.owner)) |e| {
            objc.msg(void, e.controller, "didCloseTab:windowIsClosing:", .{ page, objc.NO });
            @import("controller_delegate_state.zig").clearPopupRequest(e);
        }
        popup_page.drop(page);
    }
    if (self.host) |h| {
        h.forget(self.web);
        h.destroy();
    }
    objc.msg(void, self.web, "stopLoading", .{});
    objc.msg(void, self.web, "setUIDelegate:", .{@as(?objc.Object, null)});
    objc.msg(void, self.web, "setNavigationDelegate:", .{@as(?objc.Object, null)});
    objc.msg(void, self.web, "removeFromSuperview", .{});
    objc.release(self.web);
    heap.free(self.id);
    heap.destroy(self);
}
