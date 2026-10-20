//! What WebKit sees of an extension's popup (ExtensionPopup.swift:41-58,
//! 335-390): its page, in the browser's window but not among its tabs
//! (`PopupPage`, where Chrome puts a popup too), and the delegate of its
//! view — a camera or microphone asked on the front window's bar, screen
//! recording only through KeaZig's own call, window.close() and links out.
const std = @import("std");
const objc = @import("nanoui").objc;
const popup = @import("popup.zig");
const Popup = popup.Popup;
const controller = @import("controller.zig");
const adapters = @import("adapters.zig");
const capture = @import("capture.zig");
const frames = @import("controller_delegate_frames.zig");
const dialogs = @import("../web/dialogs.zig");
const browsers = @import("../app/browsers.zig");

const C = objc.Object;
const Sel = objc.SEL;
const H = *const anyopaque;

var shared: ?objc.Object = null;

/// The one delegate every popup's view has (it finds its popup by view).
pub fn delegate() objc.Object {
    if (shared) |d| return d;
    const cls = objc.defineClass(.{
        .name = "KeaZigPopupDelegate",
        .protocols = &.{ "WKUIDelegate", "WKNavigationDelegate" },
        .methods = &.{
            .{ .name = "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:", .imp = &askedForCapture, .types = "v@:@@@q@?" },
            .{ .name = capture.display_selector, .imp = &capture.displayCapture, .types = "v@:@@@B@?" },
            .{ .name = "webViewDidClose:", .imp = &didClose, .types = "v@:@" },
            .{ .name = "webView:didFinishNavigation:", .imp = &didFinish, .types = "v@:@@" },
            .{ .name = "_webView:navigationDidFinishDocumentLoad:", .imp = &documentLoaded, .types = "v@:@@" },
            .{ .name = "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", .imp = &createWebView, .types = "@@:@@@@" },
        },
    });
    shared = objc.msg(objc.Object, cls, "new", .{});
    return shared.?;
}

/// The popup asking for the camera or microphone: asked on the bar of the
/// window in front, named as the extension and remembered for it, as for
/// any of its pages — never WebKit's own dialog, never without asking.
fn askedForCapture(_: C, sel: Sel, wv: C, origin: C, frame: C, kind: objc.NSInteger, decide: H) callconv(.c) void {
    const deny: objc.NSInteger = 2;
    const p = popup.of(wv) orelse return dialogs.call(decide, .{deny});
    const b = browsers.acting(p.kea) orelse return dialogs.call(decide, .{deny});
    const tab = b.activeTab() orelse return dialogs.call(decide, .{deny});
    const d = tab.delegate orelse return dialogs.call(decide, .{deny});
    @import("../web/delegates_ui.zig").askedForCapture(d, sel, wv, origin, frame, kind, decide);
}

fn didClose(_: C, _: Sel, wv: C) callconv(.c) void {
    if (popup.of(wv) != null) popup.close();
}

fn didFinish(_: C, _: Sel, wv: C, _: ?C) callconv(.c) void {
    if (popup.of(wv)) |p| popup.follow(p);
}

/// The document is built — DOMContentLoaded, the moment Chrome sizes a popup.
fn documentLoaded(_: C, _: Sel, wv: C, _: ?C) callconv(.c) void {
    if (popup.of(wv)) |p| popup.firstMeasure(p);
}

/// A link that asks for a new window becomes a tab, and the popup goes —
/// never a file on this Mac, never javascript: (as tabs.create).
fn createWebView(_: C, _: Sel, wv: C, _: C, action: C, _: C) callconv(.c) ?objc.Object {
    const p = popup.of(wv) orelse return null;
    const request = objc.msg(objc.Object, action, "request", .{});
    if (objc.msg(?objc.Object, request, "URL", .{})) |u| {
        const url = objc.fromNSString(objc.msg(objc.Object, u, "absoluteString", .{}));
        if (frames.mayOpen(url) == null) if (browsers.acting(p.kea)) |b| {
            _ = b.open(url, .{ .foreground = true });
        };
    }
    popup.close();
    return null;
}

// MARK: PopupPage

fn pageClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigPopupPage",
        .protocols = &.{"WKWebExtensionTab"},
        .methods = &.{
            .{ .name = "windowForWebExtensionContext:", .imp = &pWindow, .types = "@@:@" },
            .{ .name = "indexInWindowForWebExtensionContext:", .imp = &pIndex, .types = "Q@:@" },
            .{ .name = "webViewForWebExtensionContext:", .imp = &pWeb, .types = "@@:@" },
            .{ .name = "titleForWebExtensionContext:", .imp = &pTitle, .types = "@@:@" },
            .{ .name = "urlForWebExtensionContext:", .imp = &pURL, .types = "@@:@" },
            .{ .name = "isLoadingCompleteForWebExtensionContext:", .imp = &pLoaded, .types = "B@:@" },
            .{ .name = "isSelectedForWebExtensionContext:", .imp = &pSelected, .types = "B@:@" },
            .{ .name = "closeForWebExtensionContext:completionHandler:", .imp = &pClose, .types = "v@:@@?" },
        },
    });
}

/// The page of `p`, retained; `drop` lets it go.
pub fn make(p: *Popup) objc.Object {
    const o = objc.msg(objc.Object, objc.msg(objc.Object, pageClass(), "alloc", .{}), "init", .{});
    objc.setZig(o, p);
    return o;
}

/// WebKit may still hold it: with its popup cleared it answers as gone.
pub fn drop(o: objc.Object) void {
    objc.setZig(o, null);
    objc.release(o);
}

fn of(self: C) ?*Popup {
    return objc.getZig(Popup, self);
}

fn pWindow(self: C, _: Sel, _: C) callconv(.c) ?objc.Object {
    const p = of(self) orelse return null;
    const e = controller.alive(p.owner) orelse return null;
    return adapters.windowOf(e, e.browser() orelse return null);
}

fn pIndex(_: C, _: Sel, _: C) callconv(.c) objc.NSUInteger {
    return @intCast(std.math.maxInt(objc.NSInteger));
}

fn pWeb(self: C, _: Sel, _: C) callconv(.c) ?objc.Object {
    return if (of(self)) |p| p.web else null;
}

fn pTitle(self: C, _: Sel, _: C) callconv(.c) ?objc.Object {
    const p = of(self) orelse return null;
    return objc.msg(?objc.Object, p.web, "title", .{});
}

fn pURL(self: C, _: Sel, _: C) callconv(.c) ?objc.Object {
    const p = of(self) orelse return null;
    return objc.msg(?objc.Object, p.web, "URL", .{});
}

fn pLoaded(self: C, _: Sel, _: C) callconv(.c) bool {
    const p = of(self) orelse return true;
    return !objc.msg(objc.BOOL, p.web, "isLoading", .{});
}

fn pSelected(_: C, _: Sel, _: C) callconv(.c) bool {
    return false;
}

fn pClose(self: C, _: Sel, _: C, h: H) callconv(.c) void {
    if (of(self) != null) popup.close();
    dialogs.call(h, .{@as(?objc.Object, null)});
}
