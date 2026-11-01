//! The Web Inspector (Inspector.swift): WebKit's own, on the page in front —
//! ⌥⌘I (or F12) for the inspector, ⌥⌘J for the console, ⌥⌘C to pick an
//! element, ⌥⌘U for the page's source. The page in front is an extension's
//! popup, a small window, a Peek, the web side panel when it has the keys, or
//! the tab. WebKit answers for its inspector only through private names, so
//! each is asked for before it is used; a WebKit without them does nothing.
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../model/browser.zig").Browser;

/// ⌥⌘I: the inspector, or put away if it is up.
pub fn toggleInspector(b: *Browser) void {
    const inspector = of(b) orelse return;
    send(inspector, if (asks(inspector, "isVisible")) "close" else "show");
}

/// ⌥⌘J: the inspector, at its console.
pub fn showConsole(b: *Browser) void {
    send(of(b) orelse return, "showConsole");
}

/// ⌥⌘C: the inspector, and the next click on the page picks what it
/// shows. Again, and the picking stops.
pub fn inspectElement(b: *Browser) void {
    const inspector = of(b) orelse return;
    if (!asks(inspector, "isVisible")) send(inspector, "show");
    send(inspector, "toggleElementSelection");
}

/// ⌥⌘U: the inspector, at the page's source.
pub fn showPageSource(b: *Browser) void {
    const inspector = of(b) orelse return;
    if (!asks(inspector, "isVisible")) send(inspector, "show");
    send(inspector, "showPageSource");
}

/// The inspector of any web view (an extension's background page).
pub fn inspectWebView(web: ?objc.Object) void {
    send(inspectorOf(web orelse return) orelse return, "show");
}

/// `WKWebView.inspectable`, where WebKit has it.
pub fn inspectable(web: objc.Object) void {
    if (responds(web, "setInspectable:")) objc.msg(void, web, "setInspectable:", .{objc.YES});
}

/// The inspector of the page in front — none for a blank tab, which has no
/// page to look at.
fn of(b: *Browser) ?objc.Object {
    return inspectorOf(front(b) orelse return null);
}

fn front(b: *Browser) ?objc.Object {
    if (@import("../ext/popup.zig").currentWebView()) |wv| return wv;
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const key = objc.msg(?objc.Object, app, "keyWindow", .{});
    if (@import("little.zig").owning(key)) |l| if (l.tab.web) |wv| return wv;
    if (b.peek_tab) |pt| if (pt.web) |wv| return wv;
    if (b.web_panel_tab) |wt| if (wt.web) |wv| if (b.expanded_panel == .web or hasKeys(key, wv)) return wv;
    const tab = b.activeTab() orelse return null;
    if (tab.isBlank()) return null;
    return tab.web;
}

/// Whether the key window's first responder is inside `web`.
fn hasKeys(key: ?objc.Object, web: objc.Object) bool {
    const r = objc.msg(?objc.Object, key orelse return false, "firstResponder", .{}) orelse return false;
    return responds(r, "isDescendantOf:") and objc.msg(objc.BOOL, r, "isDescendantOf:", .{web});
}

fn inspectorOf(web: objc.Object) ?objc.Object {
    if (!responds(web, "_inspector")) return null;
    return objc.msg(?objc.Object, web, "_inspector", .{});
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
