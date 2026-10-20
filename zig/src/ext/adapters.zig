//! `ExtensionTab` and `ExtensionWindow` (Extensions.swift 1529-1684): what
//! WebKit is handed for a tab and a window. Each holds its tab by id (weak:
//! looked up again every call) or its browser (dropped by `forgetWindow`).
const std = @import("std");
const objc = @import("nanoui").objc;
const Extensions = @import("controller.zig").Extensions;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const ext = @import("ext.zig");
const fence = @import("controller_fence.zig");
const frames = @import("controller_delegate_frames.zig");
const browsers = @import("../app/browsers.zig");
const tab_state = @import("../web/tab_state.zig");
const dialogs = @import("../web/dialogs.zig");
const value = @import("value.zig");

/// What an adapter object points at.
const Ref = struct {
    owner: *Extensions,
    tab_id: u64 = 0,
    browser: ?*Browser = null,
};

const ns_not_found: objc.NSUInteger = @as(objc.NSUInteger, std.math.maxInt(objc.NSInteger));
const rect_null: objc.CGRect = .{ .origin = .{ .x = std.math.inf(f64), .y = std.math.inf(f64) } };

// MARK: lookups ExtController and the delegate use

/// `adapter(for:)`: the one `ExtensionTab` of `tab`, made once.
pub fn adapter(self: *Extensions, tab: *Tab) objc.Object {
    if (self.del.tabs.get(tab.id)) |o| return o;
    const o = make(self, tabClass(), .{ .owner = self, .tab_id = tab.id });
    self.del.tabs.put(self.gpa, tab.id, o) catch {};
    return o;
}

/// The adapter of a tab, if one was made (no making).
pub fn known(self: *Extensions, tab_id: u64) ?objc.Object {
    return self.del.tabs.get(tab_id);
}

/// `window(of:)`: the one `ExtensionWindow` of `browser`.
pub fn windowOf(self: *Extensions, browser: *Browser) objc.Object {
    if (self.del.windows.get(browser)) |o| return o;
    const o = make(self, windowClass(), .{ .owner = self, .browser = browser });
    self.del.windows.put(self.gpa, browser, o) catch {};
    return o;
}

/// `activeAdapter(of:)`: the adapter of the browser's tab in front.
pub fn activeAdapter(self: *Extensions, browser: *Browser) ?objc.Object {
    const t = browser.activeTab() orelse return null;
    return adapter(self, t);
}

pub fn forgetAdapter(self: *Extensions, tab_id: u64) void {
    const kv = self.del.tabs.fetchSwapRemove(tab_id) orelse return;
    unmake(self, kv.value);
}

pub fn forgetWindow(self: *Extensions, browser: *Browser) void {
    const kv = self.del.windows.fetchSwapRemove(browser) orelse return;
    unmake(self, kv.value);
}

/// Every adapter let go: the controller going. WebKit may still hold one;
/// with its pointer cleared it answers as a tab or window that is gone.
pub fn forgetAll(self: *Extensions) void {
    for (self.del.tabs.values()) |o| unmake(self, o);
    self.del.tabs.deinit(self.gpa);
    for (self.del.windows.values()) |o| unmake(self, o);
    self.del.windows.deinit(self.gpa);
}

fn make(self: *Extensions, class: objc.Class, ref: Ref) objc.Object {
    const o = objc.msg(objc.Object, objc.msg(objc.Object, class, "alloc", .{}), "init", .{});
    const r = self.gpa.create(Ref) catch @panic("OOM");
    r.* = ref;
    objc.setZig(o, r);
    return o;
}

fn unmake(self: *Extensions, o: objc.Object) void {
    if (objc.getZig(Ref, o)) |r| self.gpa.destroy(r);
    objc.setZig(o, null);
    objc.release(o);
}

fn findTab(r: *Ref) ?*Tab {
    for (r.owner.kea.browsers.items) |b| if (b.tabById(r.tab_id)) |t| return t;
    return null;
}

fn refOf(self: objc.Object) ?*Ref {
    return objc.getZig(Ref, self);
}

/// The tab and its window, when both still are.
fn tabAndBrowser(self: objc.Object) ?struct { r: *Ref, t: *Tab, b: ?*Browser } {
    const r = refOf(self) orelse return null;
    const t = findTab(r) orelse return null;
    return .{ .r = r, .t = t, .b = r.owner.browserOf(t) };
}

fn nsURL(s: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(s)});
}

fn finish(handler: *const anyopaque, err: ?[]const u8) void {
    if (err) |why| {
        const pool = objc.Pool.push();
        defer pool.pop();
        dialogs.call(handler, .{@as(?objc.Object, value.nsError(why))});
    } else dialogs.call(handler, .{@as(?objc.Object, null)});
}

// MARK: ExtensionTab

const C = objc.Object; // the WKWebExtensionContext argument
const Sel = objc.SEL;
const H = *const anyopaque; // completion handler

fn tabClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigExtensionTab",
        .protocols = &.{"WKWebExtensionTab"},
        .methods = &.{
            .{ .name = "windowForWebExtensionContext:", .imp = &tWindow, .types = "@@:@" },
            .{ .name = "indexInWindowForWebExtensionContext:", .imp = &tIndex, .types = "Q@:@" },
            .{ .name = "webViewForWebExtensionContext:", .imp = &tWebView, .types = "@@:@" },
            .{ .name = "titleForWebExtensionContext:", .imp = &tTitle, .types = "@@:@" },
            .{ .name = "urlForWebExtensionContext:", .imp = &tURL, .types = "@@:@" },
            .{ .name = "isLoadingCompleteForWebExtensionContext:", .imp = &tLoaded, .types = "B@:@" },
            .{ .name = "isSelectedForWebExtensionContext:", .imp = &tSelected, .types = "B@:@" },
            .{ .name = "isPinnedForWebExtensionContext:", .imp = &tPinned, .types = "B@:@" },
            .{ .name = "isPlayingAudioForWebExtensionContext:", .imp = &tAudio, .types = "B@:@" },
            .{ .name = "zoomFactorForWebExtensionContext:", .imp = &tZoom, .types = "d@:@" },
            .{ .name = "sizeForWebExtensionContext:", .imp = &tSize, .types = "{CGSize=dd}@:@" },
            .{ .name = "shouldGrantPermissionsOnUserGestureForWebExtensionContext:", .imp = &tGrant, .types = "B@:@" },
            .{ .name = "setPinned:forWebExtensionContext:completionHandler:", .imp = &tSetPinned, .types = "v@:B@@?" },
            .{ .name = "setZoomFactor:forWebExtensionContext:completionHandler:", .imp = &tSetZoom, .types = "v@:d@@?" },
            .{ .name = "loadURL:forWebExtensionContext:completionHandler:", .imp = &tLoad, .types = "v@:@@@?" },
            .{ .name = "reloadFromOrigin:forWebExtensionContext:completionHandler:", .imp = &tReload, .types = "v@:B@@?" },
            .{ .name = "goBackForWebExtensionContext:completionHandler:", .imp = &tBack, .types = "v@:@@?" },
            .{ .name = "goForwardForWebExtensionContext:completionHandler:", .imp = &tForward, .types = "v@:@@?" },
            .{ .name = "activateForWebExtensionContext:completionHandler:", .imp = &tActivate, .types = "v@:@@?" },
            .{ .name = "closeForWebExtensionContext:completionHandler:", .imp = &tClose, .types = "v@:@@?" },
            .{ .name = "takeSnapshotUsingConfiguration:forWebExtensionContext:completionHandler:", .imp = &tSnapshot, .types = "v@:@@@?" },
        },
    });
}

/// `sealed`: a tab showing another extension's page gives an extension
/// nothing of it — no view, no address, no picture.
fn sealed(t: *Tab, context: C) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const own = objc.fromNSString(objc.msg(objc.Object, context, "uniqueIdentifier", .{}));
    const built: ?[]const u8 = if (t.web) |w| if (objc.msg(?objc.Object, w, "URL", .{})) |u| objc.fromNSString(objc.msg(objc.Object, u, "absoluteString", .{})) else null else null;
    return fence.othersPage(built, own) or fence.othersPage(t.address, own);
}

fn tWindow(self: objc.Object, _: Sel, _: C) callconv(.c) ?objc.Object {
    const x = tabAndBrowser(self) orelse return null;
    return windowOf(x.r.owner, x.b orelse return null);
}

fn tIndex(self: objc.Object, _: Sel, _: C) callconv(.c) objc.NSUInteger {
    const x = tabAndBrowser(self) orelse return ns_not_found;
    const b = x.b orelse return ns_not_found;
    const owner = x.r.owner;
    const list = owner.visibleTabs(owner.gpa, b) catch return ns_not_found;
    defer owner.gpa.free(list);
    for (list, 0..) |t, i| if (t.id == x.t.id) return i;
    return ns_not_found;
}

fn tWebView(self: objc.Object, _: Sel, c: C) callconv(.c) ?objc.Object {
    const x = tabAndBrowser(self) orelse return null;
    return if (sealed(x.t, c)) null else x.t.web;
}

fn tTitle(self: objc.Object, _: Sel, _: C) callconv(.c) ?objc.Object {
    const x = tabAndBrowser(self) orelse return null;
    return objc.nsString(x.t.title());
}

fn tURL(self: objc.Object, _: Sel, c: C) callconv(.c) ?objc.Object {
    const x = tabAndBrowser(self) orelse return null;
    if (sealed(x.t, c)) return null;
    return nsURL(x.t.address orelse return null);
}

fn tLoaded(self: objc.Object, _: Sel, _: C) callconv(.c) bool {
    const x = tabAndBrowser(self) orelse return true;
    return !x.t.loading;
}

fn tSelected(self: objc.Object, _: Sel, _: C) callconv(.c) bool {
    const x = tabAndBrowser(self) orelse return false;
    const b = x.b orelse return false;
    return x.t.id == b.active_id;
}

fn tPinned(self: objc.Object, _: Sel, _: C) callconv(.c) bool {
    const x = tabAndBrowser(self) orelse return false;
    return x.t.pin != null;
}

fn tAudio(self: objc.Object, _: Sel, _: C) callconv(.c) bool {
    const x = tabAndBrowser(self) orelse return false;
    return x.t.noisy;
}

fn tZoom(self: objc.Object, _: Sel, _: C) callconv(.c) f64 {
    const x = tabAndBrowser(self) orelse return 1;
    const w = x.t.web orelse return 1;
    return objc.msg(f64, w, "pageZoom", .{});
}

fn tSize(self: objc.Object, _: Sel, _: C) callconv(.c) objc.CGSize {
    const x = tabAndBrowser(self) orelse return .{};
    const w = x.t.web orelse return .{};
    return objc.msg(objc.CGRect, w, "bounds", .{}).size;
}

fn tGrant(_: objc.Object, _: Sel, _: C) callconv(.c) bool {
    return true;
}

fn tSetPinned(self: objc.Object, _: Sel, pinned: bool, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    const x = tabAndBrowser(self) orelse return;
    const b = x.b orelse return;
    if (pinned and x.t.pin == null) b.pin(x.t, false);
    if (!pinned and x.t.pin != null) b.unpin(x.t);
}

fn tSetZoom(self: objc.Object, _: Sel, zoom: f64, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    const x = tabAndBrowser(self) orelse return;
    tab_state.magnify(x.t, zoom);
}

fn tLoad(self: objc.Object, _: Sel, url: objc.Object, _: C, h: H) callconv(.c) void {
    const x = tabAndBrowser(self) orelse return finish(h, null);
    const pool = objc.Pool.push();
    defer pool.pop();
    const asked = objc.fromNSString(objc.msg(objc.Object, url, "absoluteString", .{}));
    if (frames.mayOpen(asked)) |why| return finish(h, why);
    const gpa = x.r.owner.gpa;
    const target = ext.current(gpa, asked) catch return finish(h, null);
    defer if (target.ptr != asked.ptr) gpa.free(target);
    // A website's tab sent to one of an extension's own pages (1Password,
    // after a sign-in) can only be served from a view built from that
    // extension's configuration: the tab is swapped for one that is.
    const here: ?[]const u8 = if (x.t.web) |w| if (objc.msg(?objc.Object, w, "URL", .{})) |u| objc.fromNSString(objc.msg(objc.Object, u, "absoluteString", .{})) else x.t.address else x.t.address;
    if (std.mem.startsWith(u8, target, ext.scheme ++ "://")) if (x.b) |b| {
        const there = ext.idOf(target);
        const same = if (here) |hh| std.mem.startsWith(u8, hh, ext.scheme ++ "://") and eqlOpt(ext.idOf(hh), there) else false;
        if (!same) {
            @import("../model/browser_ext.zig").replace(b, x.t, target);
            return finish(h, null);
        }
    };
    x.t.go(target);
    finish(h, null);
}

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn tReload(self: objc.Object, _: Sel, from_origin: bool, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    if (tabAndBrowser(self)) |x| x.t.reload(from_origin);
}

fn tBack(self: objc.Object, _: Sel, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    if (tabAndBrowser(self)) |x| x.t.goBack();
}

fn tForward(self: objc.Object, _: Sel, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    if (tabAndBrowser(self)) |x| x.t.goForward();
}

/// `activateForExtension`: a tab already on screen in the pair stays put.
fn tActivate(self: objc.Object, _: Sel, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    const x = tabAndBrowser(self) orelse return;
    const b = x.b orelse return;
    if (b.activeSplit()) |pair| if (pair.contains(x.t.id)) return;
    b.select(x.t);
}

fn tClose(self: objc.Object, _: Sel, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    const x = tabAndBrowser(self) orelse return;
    if (x.b) |b| b.close(x.t);
}

/// WebKit's own snapshot, its `(NSImage, NSError)` completion passed on.
fn tSnapshot(self: objc.Object, _: Sel, configuration: objc.Object, c: C, h: H) callconv(.c) void {
    const x = tabAndBrowser(self) orelse return dialogs.call(h, .{ @as(?objc.Object, null), @as(?objc.Object, null) });
    const web = x.t.web orelse return dialogs.call(h, .{ @as(?objc.Object, null), @as(?objc.Object, null) });
    if (sealed(x.t, c)) return dialogs.call(h, .{ @as(?objc.Object, null), @as(?objc.Object, null) });
    objc.msg(void, web, "takeSnapshotWithConfiguration:completionHandler:", .{ configuration, h });
}

// MARK: ExtensionWindow

fn windowClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigExtensionWindow",
        .protocols = &.{"WKWebExtensionWindow"},
        .methods = &.{
            .{ .name = "tabsForWebExtensionContext:", .imp = &wTabs, .types = "@@:@" },
            .{ .name = "activeTabForWebExtensionContext:", .imp = &wActive, .types = "@@:@" },
            .{ .name = "windowTypeForWebExtensionContext:", .imp = &wType, .types = "q@:@" },
            .{ .name = "isPrivateForWebExtensionContext:", .imp = &wPrivate, .types = "B@:@" },
            .{ .name = "windowStateForWebExtensionContext:", .imp = &wState, .types = "q@:@" },
            .{ .name = "frameForWebExtensionContext:", .imp = &wFrame, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:@" },
            .{ .name = "screenFrameForWebExtensionContext:", .imp = &wScreenFrame, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:@" },
            .{ .name = "focusForWebExtensionContext:completionHandler:", .imp = &wFocus, .types = "v@:@@?" },
            .{ .name = "closeForWebExtensionContext:completionHandler:", .imp = &wClose, .types = "v@:@@?" },
            .{ .name = "setFrame:forWebExtensionContext:completionHandler:", .imp = &wSetFrame, .types = "v@:{CGRect={CGPoint=dd}{CGSize=dd}}@@?" },
        },
    });
}

/// The window's browser and owner, while both are.
pub fn browserOfWindow(self: objc.Object) ?*Browser {
    const r = refOf(self) orelse return null;
    return r.browser;
}

fn nsWindow(self: objc.Object) ?objc.Object {
    const b = browserOfWindow(self) orelse return null;
    const w = b.window orelse return null;
    return w.nswindow;
}

fn wTabs(self: objc.Object, _: Sel, _: C) callconv(.c) objc.Object {
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    const r = refOf(self) orelse return arr;
    const b = r.browser orelse return arr;
    const list = r.owner.visibleTabs(r.owner.gpa, b) catch return arr;
    defer r.owner.gpa.free(list);
    for (list) |t| objc.msg(void, arr, "addObject:", .{adapter(r.owner, t)});
    return arr;
}

fn wActive(self: objc.Object, _: Sel, _: C) callconv(.c) ?objc.Object {
    const r = refOf(self) orelse return null;
    return activeAdapter(r.owner, r.browser orelse return null);
}

fn wType(self: objc.Object, _: Sel, _: C) callconv(.c) objc.NSInteger {
    const b = browserOfWindow(self) orelse return 0;
    return if (b.ext.popup != null) 1 else 0; // .popup : .normal
}

fn wPrivate(_: objc.Object, _: Sel, _: C) callconv(.c) bool {
    return false;
}

/// normal 0, minimized 1, maximized 2, fullscreen 3.
fn wState(self: objc.Object, _: Sel, _: C) callconv(.c) objc.NSInteger {
    const w = nsWindow(self) orelse return 0;
    if (objc.msg(objc.BOOL, w, "isMiniaturized", .{})) return 1;
    const full_screen: objc.NSUInteger = 1 << 14;
    if (objc.msg(objc.NSUInteger, w, "styleMask", .{}) & full_screen != 0) return 3;
    return if (objc.msg(objc.BOOL, w, "isZoomed", .{})) 2 else 0;
}

fn wFrame(self: objc.Object, _: Sel, _: C) callconv(.c) objc.CGRect {
    const w = nsWindow(self) orelse return rect_null;
    return objc.msg(objc.CGRect, w, "frame", .{});
}

fn wScreenFrame(self: objc.Object, _: Sel, _: C) callconv(.c) objc.CGRect {
    const screen = if (nsWindow(self)) |w| objc.msg(?objc.Object, w, "screen", .{}) else null;
    const s = screen orelse objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return rect_null;
    return objc.msg(objc.CGRect, s, "frame", .{});
}

fn wFocus(self: objc.Object, _: Sel, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    if (browserOfWindow(self)) |b| browsers.show(b);
}

/// windows.remove.
fn wClose(self: objc.Object, _: Sel, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    if (nsWindow(self)) |w| objc.msg(void, w, "performClose:", .{@as(?objc.Object, null)});
}

/// windows.update with a position or size: unset parts come as NaN and stay,
/// never below the window's smallest size, kept on screen.
fn wSetFrame(self: objc.Object, _: Sel, frame: objc.CGRect, _: C, h: H) callconv(.c) void {
    defer finish(h, null);
    const w = nsWindow(self) orelse return;
    const now = objc.msg(objc.CGRect, w, "frame", .{});
    const min = objc.msg(objc.CGSize, w, "minSize", .{});
    const next: objc.CGRect = .{
        .origin = .{ .x = orNow(frame.origin.x, now.origin.x), .y = orNow(frame.origin.y, now.origin.y) },
        .size = .{
            .width = @max(min.width, orNow(frame.size.width, now.size.width)),
            .height = @max(min.height, orNow(frame.size.height, now.size.height)),
        },
    };
    objc.msg(void, w, "setFrame:display:animate:", .{ frames.onScreen(next), objc.YES, objc.NO });
}

fn orNow(v: f64, current: f64) f64 {
    return if (std.math.isFinite(v)) v else current;
}
