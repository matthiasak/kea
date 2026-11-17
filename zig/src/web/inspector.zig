//! The Web Inspector (Inspector.swift): WebKit's own, on the page in front —
//! ⌥⌘I (or F12) for the inspector, ⌥⌘J for the console, ⌥⌘C to pick an
//! element, ⌥⌘U for the page's source. The page in front is an extension's
//! popup, a small window, a Peek, the web side panel when it has the keys, or
//! the tab; a blank tab is given `about:blank` to be looked at. WebKit answers
//! for its inspector only through private names, so each is asked for before
//! it is used; a WebKit without them does nothing.
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../model/browser.zig").Browser;
const platform = @import("../sys/platform.zig");

/// Whether the keys were in an inspector when the click now being handled
/// came: AppKit hands them to the chrome's view before its `mouseDown:`, and
/// a click that no box takes hands them back (`keys.seen`, `omnibox.applyKeys`).
pub var had_keys_on_click: bool = false;

/// ⌥⌘I: the inspector, or put away if it is up.
pub fn toggleInspector(b: *Browser) void {
    if (of(b)) |up| if (asks(up, "isVisible")) return send(up, "close");
    const wv = ensureFront(b) orelse return;
    send(inspectorOf(wv) orelse return, "show");
    focusDocked(wv);
}

/// ⌥⌘J: the inspector, at its console.
pub fn showConsole(b: *Browser) void {
    const wv = ensureFront(b) orelse return;
    send(inspectorOf(wv) orelse return, "showConsole");
    focusDocked(wv);
}

/// ⌥⌘C: the inspector, and the next click on the page picks what it
/// shows. Again, and the picking stops.
pub fn inspectElement(b: *Browser) void {
    if (@import("float.zig").floating(b) != null) @import("float.zig").land(b);
    send(shown(ensureFront(b) orelse return) orelse return, "toggleElementSelection");
}

/// ⌥⌘U: the inspector, at the page's source. WebKit has no `showPageSource`:
/// the main frame's resource is it, the resources at large without one.
pub fn showPageSource(b: *Browser) void {
    if (comptime platform.is_ios) return;
    const wv = ensureFront(b) orelse return;
    const inspector = shown(wv) orelse return;
    defer focusDocked(wv);
    if (responds(wv, "_mainFrame") and responds(inspector, "showMainResourceForFrame:")) {
        if (objc.msg(?objc.Object, wv, "_mainFrame", .{})) |frame| return objc.msg(void, inspector, "showMainResourceForFrame:", .{frame});
    }
    send(inspector, "showResources");
}

/// The inspector, and its timeline recording started or stopped.
pub fn toggleProfiling(b: *Browser) void {
    send(shown(ensureFront(b) orelse return) orelse return, "togglePageProfiling");
}

/// The inspector, out into a window of its own or back beside its page.
pub fn toggleAttach(b: *Browser) void {
    const wv = ensureFront(b) orelse return;
    send(shown(wv) orelse return, if (isAttachedFor(wv)) "detach" else "attach");
}

/// The inspector of any web view (an extension's background page).
pub fn inspectWebView(web: ?objc.Object) void {
    send(inspectorOf(web orelse return) orelse return, "show");
}

/// `WKWebView.inspectable`, where WebKit has it.
pub fn inspectable(web: objc.Object) void {
    if (responds(web, "setInspectable:")) objc.msg(void, web, "setInspectable:", .{objc.YES});
}

/// Whether there is a page in front that Web Inspector can open on: a blank
/// tab counts, it is given one when asked.
pub fn canInspect(b: *Browser) bool {
    if (comptime platform.is_ios) return false;
    if (b.kea.opts.headless) return false;
    return frontExisting(b) != null or b.activeTab() != null;
}

/// Whether `web`'s own Web Inspector is currently open (`isVisible`).
pub fn isVisibleFor(web: ?objc.Object) bool {
    const insp = inspectorOf(web orelse return false) orelse return false;
    return asks(insp, "isVisible");
}

/// The view WebKit shows `web`'s inspector in (`WKInspectorWKWebView`), once
/// it has one.
pub fn inspectorWebViewFor(web: ?objc.Object) ?objc.Object {
    if (comptime platform.is_ios) return null;
    const insp = inspectorOf(web orelse return null) orelse return null;
    if (!responds(insp, "inspectorWebView")) return null;
    return objc.msg(?objc.Object, insp, "inspectorWebView", .{});
}

/// Whether `web`'s inspector is open and docked beside it. `_WKInspector`
/// has no `isAttached`: docked, its view sits in the page's window; out on
/// its own, in a `_WKInspectorWindow`.
pub fn isAttachedFor(web: ?objc.Object) bool {
    if (comptime platform.is_ios) return false;
    const wv = web orelse return false;
    // Asked first: closed (every frame of most pages) nothing more is.
    if (!isVisibleFor(wv)) return false;
    const iwv = inspectorWebViewFor(wv) orelse return false;
    if (objc.msg(?objc.Object, iwv, "superview", .{}) == null) return false;
    const window = objc.msg(?objc.Object, iwv, "window", .{}) orelse return false;
    return window == objc.msg(?objc.Object, wv, "window", .{});
}

/// The page in front's inspector: up, docked, picking an element, recording.
/// Asked every frame (the HUD), so none of them wakes a blank tab.
pub fn isVisible(b: *Browser) bool {
    return isVisibleFor(frontExisting(b));
}

pub fn isAttached(b: *Browser) bool {
    return isAttachedFor(frontExisting(b));
}

pub fn isPickingElement(b: *Browser) bool {
    return asks(of(b) orelse return false, "isElementSelectionActive");
}

pub fn isProfiling(b: *Browser) bool {
    return asks(of(b) orelse return false, "isProfilingPage");
}

/// The inspector of the page in front — none for a blank tab, which has no
/// page to look at yet.
fn of(b: *Browser) ?objc.Object {
    return inspectorOf(frontExisting(b) orelse return null);
}

/// `wv`'s inspector, shown if it wasn't.
fn shown(wv: objc.Object) ?objc.Object {
    const inspector = inspectorOf(wv) orelse return null;
    if (!asks(inspector, "isVisible")) send(inspector, "show");
    return inspector;
}

/// The page in front as it is: none for a blank tab. Changes nothing.
fn frontExisting(b: *Browser) ?objc.Object {
    if (@import("../ext/popup.zig").currentWebView()) |wv| return wv;
    if (comptime !platform.is_ios) {
        const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        const key = objc.msg(?objc.Object, app, "keyWindow", .{});
        if (@import("little.zig").owning(key)) |l| if (l.tab.web) |wv| return wv;
        if (b.peek_tab) |pt| if (pt.web) |wv| return wv;
        if (b.web_panel_tab) |wt| if (wt.web) |wv| if (b.expanded_panel == .web or hasKeys(key, wv)) return wv;
    } else {
        if (b.peek_tab) |pt| if (pt.web) |wv| return wv;
        if (b.web_panel_tab) |wt| if (wt.web) |wv| if (b.expanded_panel == .web) return wv;
    }
    const tab = b.activeTab() orelse return null;
    if (tab.isBlank()) return null;
    return tab.web;
}

/// The page in front, a blank tab sent to `about:blank` to have one: the
/// inspector opens on a page. Only a blank tab is sent anywhere — one with
/// an address and no page (asleep) keeps its address and gets no inspector.
fn ensureFront(b: *Browser) ?objc.Object {
    if (frontExisting(b)) |wv| return wv;
    if (comptime platform.is_ios) return null;
    if (b.kea.opts.headless) return null;
    const tab = b.activeTab() orelse return null;
    if (!tab.isBlank()) return null;
    tab.go("about:blank");
    // On the stage and in its hole before WebKit is asked: it docks the
    // inspector into the page's superview, and only beside a page of some
    // size. Asked from inside a frame (the HUD) `frame` does nothing, and
    // the stage takes the page into the blank pane's hole itself.
    if (b.window) |w| if (w.surface) |s| s.frame();
    b.syncStageHost();
    return tab.web;
}

/// Whether the key window's first responder is inside `web`.
fn hasKeys(key: ?objc.Object, web: objc.Object) bool {
    const r = objc.msg(?objc.Object, key orelse return false, "firstResponder", .{}) orelse return false;
    return responds(r, "isDescendantOf:") and objc.msg(objc.BOOL, r, "isDescendantOf:", .{web});
}

fn inspectorOf(web: objc.Object) ?objc.Object {
    if (comptime platform.is_ios) return null;
    if (!responds(web, "_inspector")) return null;
    return objc.msg(?objc.Object, web, "_inspector", .{});
}

/// The keys to `wv`'s inspector when it is docked in the page's window: a
/// click on the chrome (the HUD's Console) leaves them in the tools.
fn focusDocked(wv: objc.Object) void {
    if (comptime platform.is_ios) return;
    if (!isAttachedFor(wv)) return;
    const iwv = inspectorWebViewFor(wv) orelse return;
    const win = objc.msg(?objc.Object, wv, "window", .{}) orelse return;
    _ = objc.msg(objc.BOOL, win, "makeFirstResponder:", .{iwv});
}

fn responds(o: objc.Object, name: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "respondsToSelector:", .{objc.sel(name)});
}

fn send(inspector: objc.Object, name: [:0]const u8) void {
    if (responds(inspector, name)) objc.msg(void, inspector, name, .{});
}

fn asks(inspector: objc.Object, name: [:0]const u8) bool {
    return responds(inspector, name) and objc.msg(objc.BOOL, inspector, name, .{});
}
