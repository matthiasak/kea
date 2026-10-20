//! AppleScript, read-only, in Safari's words (Scripting.swift, Kea.sdef,
//! which `build.sh` puts in the app): a window's `tabs` and its
//! `current tab`, and each tab's `URL` and `name`. `count` is AppKit's own
//! `NSCountCommand`. Nothing here changes anything, runs anything in a
//! page, or opens or closes a tab. Private tabs are never shown to a
//! script: they are left out of the list, and a window whose tab in front
//! is private has no current tab (missing value).
//!
//! The sdef's `cocoa class` names: `ScriptTab` is defined here; the
//! `scriptTabs`/`scriptCurrentTab` keys are added to `NSWindow`.
const std = @import("std");
const objc = @import("nanoui").objc;
const Kea = @import("kea.zig").Kea;
const browsers = @import("browsers.zig");
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;

extern "c" fn class_addMethod(cls: objc.Class, name: objc.SEL, imp: *const anyopaque, types: [*:0]const u8) objc.BOOL;

/// The app a script asks (one `Kea` at a time per process).
var current: ?*Kea = null;

/// Scripts see `kea`'s windows from here on (`Kea.create`).
pub fn install(kea: *Kea) void {
    current = kea;
    _ = tabClass();
    const window = objc.class("NSWindow");
    // Added once; a second time is refused, which is fine.
    _ = class_addMethod(window, objc.sel("scriptTabs"), @ptrCast(&scriptTabs), "@@:");
    _ = class_addMethod(window, objc.sel("scriptCurrentTab"), @ptrCast(&scriptCurrentTab), "@@:");
}

/// `kea` is going (`Kea.destroy`).
pub fn uninstall(kea: *Kea) void {
    if (current == kea) current = null;
}

/// `ScriptTab`: a tab as a script sees it. It holds the tab's serial, so a
/// script keeping one after the tab went gets nothing, never freed memory.
pub fn tabClass() objc.Class {
    return objc.defineClass(.{
        .name = "ScriptTab",
        .methods = &.{
            .{ .name = "url", .imp = &tabUrl, .types = "@@:" },
            .{ .name = "name", .imp = &tabName, .types = "@@:" },
            .{ .name = "objectSpecifier", .imp = &tabSpecifier, .types = "@@:" },
        },
    });
}

fn tabOf(self: objc.Object) ?*Tab {
    const serial = @intFromPtr(objc.getZig(u8, self) orelse return null);
    return Tab.alive(serial);
}

fn browserOf(window: objc.Object) ?*Browser {
    return browsers.browserFor(current orelse return null, window);
}

/// The place of `t` among `b`'s tabs a script sees (`tab N of window …`).
fn shownIndex(b: *Browser, t: *Tab) ?usize {
    var n: usize = 0;
    for (b.tabs.items) |o| if (!o.shy) {
        if (o == t) return n;
        n += 1;
    };
    return null;
}

/// A `ScriptTab` for `t`, autoreleased.
fn scriptTab(t: *Tab) objc.Object {
    const s = objc.msg(objc.Object, tabClass(), "new", .{});
    objc.setZig(s, @ptrFromInt(t.serial));
    objc.autorelease(s);
    return s;
}

fn scriptTabs(window: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const list = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    const b = browserOf(window) orelse return list;
    for (b.tabs.items) |t| if (!t.shy) objc.msg(void, list, "addObject:", .{scriptTab(t)});
    return list;
}

/// The tab in front, unless it is private.
fn scriptCurrentTab(window: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const b = browserOf(window) orelse return null;
    const t = b.tabById(b.active_id) orelse return null;
    if (t.shy) return null;
    return scriptTab(t);
}

/// The page that is on screen, not an address typed, loading or held;
/// never a name or password written into the address (user:password@).
fn tabUrl(self: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const empty = objc.nsString("");
    const t = tabOf(self) orelse return empty;
    const page = t.committed orelse t.address orelse return empty;
    const parts = objc.msg(?objc.Object, objc.class("NSURLComponents"), "componentsWithString:", .{objc.nsString(page)}) orelse return objc.nsString(page);
    if (objc.msg(?objc.Object, parts, "user", .{}) == null and objc.msg(?objc.Object, parts, "password", .{}) == null) return objc.nsString(page);
    objc.msg(void, parts, "setUser:", .{@as(?objc.Object, null)});
    objc.msg(void, parts, "setPassword:", .{@as(?objc.Object, null)});
    const url = objc.msg(?objc.Object, parts, "URL", .{}) orelse return empty;
    return objc.msg(objc.Object, url, "absoluteString", .{});
}

/// That page's title. The tab's own is emptied as soon as a load starts;
/// the page's stays until the next one has arrived, as the address does.
fn tabName(self: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const t = tabOf(self) orelse return objc.nsString("");
    if (t.committed != null) if (t.web) |wv| return objc.msg(?objc.Object, wv, "title", .{}) orelse objc.nsString("");
    return objc.nsString(t.page_title);
}

/// `tab N of window id …`: without the window's id, a tab a script kept
/// hold of couldn't be found again.
fn tabSpecifier(self: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const t = tabOf(self) orelse return null;
    const b = t.browser orelse return null;
    const w = b.window orelse return null;
    const index = shownIndex(b, t) orelse return null;
    const container = objc.msg(?objc.Object, w.nswindow, "objectSpecifier", .{}) orelse return null;
    const description = objc.msg(?objc.Object, container, "keyClassDescription", .{}) orelse return null;
    const spec = objc.msg(objc.Object, objc.alloc("NSIndexSpecifier"), "initWithContainerClassDescription:containerSpecifier:key:index:", .{
        description, container, objc.nsString("scriptTabs"), @as(objc.NSInteger, @intCast(index)),
    });
    objc.autorelease(spec);
    return spec;
}
