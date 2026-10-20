//! The offscreen document's view delegate and the extension's tab adapter
//! (ExtensionOffscreen.swift 196-283): `KeaOffscreen`, conforming to
//! WKNavigationDelegate, WKUIDelegate and WKWebExtensionTab.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const config = @import("../web/config.zig");
const dialogs = @import("../web/dialogs.zig");
const capture = @import("capture.zig");
const off = @import("offscreen.zig");
const Document = off.Document;
const alive = off.alive;
const closeWith = off.closeWith;
const ready = off.ready;
const int = off.int;
const nsField = off.nsField;
const Closed = off.Closed;

// MARK: the view's delegate, and the extension's tab adapter

pub fn class() objc.Class {
    return objc.defineClass(.{
        .name = "KeaOffscreen",
        .protocols = &.{ "WKNavigationDelegate", "WKUIDelegate", "WKWebExtensionTab" },
        .methods = &.{
            .{ .name = "webView:didFinishNavigation:", .imp = &didFinish, .types = "v@:@@" },
            .{ .name = "webView:decidePolicyForNavigationAction:decisionHandler:", .imp = &decideAction, .types = "v@:@@@?" },
            .{ .name = "webView:decidePolicyForNavigationResponse:decisionHandler:", .imp = &decideResponse, .types = "v@:@@@?" },
            .{ .name = "webView:didFailNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
            .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
            .{ .name = "webViewWebContentProcessDidTerminate:", .imp = &terminated, .types = "v@:@" },
            .{ .name = "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:", .imp = &askedForCapture, .types = "v@:@@@q@?" },
            .{ .name = capture.display_selector, .imp = &capture.displayCapture, .types = "v@:@@@B@?" },
            .{ .name = "windowForWebExtensionContext:", .imp = &noObject, .types = "@@:@" },
            .{ .name = "indexInWindowForWebExtensionContext:", .imp = &notFound, .types = "Q@:@" },
            .{ .name = "webViewForWebExtensionContext:", .imp = &webFor, .types = "@@:@" },
            .{ .name = "titleForWebExtensionContext:", .imp = &titleFor, .types = "@@:@" },
            .{ .name = "urlForWebExtensionContext:", .imp = &urlFor, .types = "@@:@" },
            .{ .name = "isLoadingCompleteForWebExtensionContext:", .imp = &loadedFor, .types = "B@:@" },
            .{ .name = "isSelectedForWebExtensionContext:", .imp = &no, .types = "B@:@" },
            .{ .name = "closeForWebExtensionContext:completionHandler:", .imp = &closeFor, .types = "v@:@@?" },
        },
    });
}

fn docOf(self: objc.Object) ?*Document {
    const d = objc.getZig(Document, self) orelse return null;
    return if (d.closed) null else d;
}

const Current = struct { serial: u64 };
const CurrentBlock = objc.Block(Current, &.{ ?objc.Object, ?objc.Object });

fn didFinish(self: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    const doc = docOf(self) orelse return;
    if (doc.ready) return;
    const ctx = std.heap.c_allocator.create(Current) catch return;
    ctx.* = .{ .serial = doc.serial };
    const pool = objc.Pool.push();
    defer pool.pop();
    // The native method: the popup shim hides current tabs with no index.
    // An id tells this page from a visible tab at the same address, and from
    // a previous document.
    var block = CurrentBlock.init(ctx, current);
    objc.msg(void, doc.web, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", .{
        objc.nsString("return (await Object.getPrototypeOf(chrome.tabs).getCurrent.call(chrome.tabs)).id;"),
        @as(?objc.Object, null),
        @as(?objc.Object, null),
        config.pageWorld(),
        @as(*anyopaque, @ptrCast(&block)),
    });
}

fn current(ctx: *Current, result: ?objc.Object, err: ?objc.Object) void {
    defer std.heap.c_allocator.destroy(ctx);
    const doc = alive(ctx.serial) orelse return;
    if (doc.closed) return;
    if (err) |e| return closeWith(doc, nsField(e, "localizedDescription"));
    const id = int(result) orelse return closeWith(doc, "The offscreen document has no page identifier.");
    doc.tab_id = id;
    doc.ready = true;
    ready(doc);
}

/// The document itself stays on the extension's own pages; its frames may
/// go anywhere. Nothing is saved from it. (WKNavigationActionPolicy:
/// cancel 0, allow 1.)
fn decideAction(self: objc.Object, _: objc.SEL, _: objc.Object, action: objc.Object, decide: *const anyopaque) callconv(.c) void {
    const cancel: objc.NSInteger = 0;
    const allow: objc.NSInteger = 1;
    const doc = objc.getZig(Document, self) orelse return dialogs.call(decide, .{cancel});
    if (objc.msg(objc.BOOL, action, "respondsToSelector:", .{objc.sel("shouldPerformDownload")}) and
        objc.msg(objc.BOOL, action, "shouldPerformDownload", .{})) return dialogs.call(decide, .{cancel});
    if (objc.msg(?objc.Object, action, "targetFrame", .{})) |frame|
        if (!objc.msg(objc.BOOL, frame, "isMainFrame", .{})) return dialogs.call(decide, .{allow});
    const to = objc.msg(?objc.Object, objc.msg(objc.Object, action, "request", .{}), "URL", .{}) orelse return dialogs.call(decide, .{cancel});
    const same = std.mem.eql(u8, nsField(to, "scheme"), nsField(doc.url, "scheme")) and std.mem.eql(u8, nsField(to, "host"), nsField(doc.url, "host"));
    dialogs.call(decide, .{if (same) allow else cancel});
}

fn decideResponse(_: objc.Object, _: objc.SEL, _: objc.Object, response: objc.Object, decide: *const anyopaque) callconv(.c) void {
    const shows = objc.msg(objc.BOOL, response, "canShowMIMEType", .{});
    dialogs.call(decide, .{@as(objc.NSInteger, if (shows) 1 else 0)});
}

/// Only its first page failing ends it.
fn didFail(self: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object, err: objc.Object) callconv(.c) void {
    const doc = docOf(self) orelse return;
    if (doc.ready) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    closeWith(doc, nsField(err, "localizedDescription"));
}

fn terminated(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const doc = docOf(self) orelse return;
    closeWith(doc, "The offscreen document's web process exited.");
}

/// The camera or the microphone: asked on the bar of the window in front,
/// naming the extension — only for a document made to record. Anything else
/// is refused (WKPermissionDecisionDeny = 2).
fn askedForCapture(self: objc.Object, sel: objc.SEL, wv: objc.Object, origin: objc.Object, frame: objc.Object, kind: objc.NSInteger, decide: *const anyopaque) callconv(.c) void {
    const deny: objc.NSInteger = 2;
    const doc = docOf(self) orelse return dialogs.call(decide, .{deny});
    if (!doc.records()) return dialogs.call(decide, .{deny});
    const browser = doc.owner.browser() orelse return dialogs.call(decide, .{deny});
    const tab = browser.activeTab() orelse return dialogs.call(decide, .{deny});
    const delegate = tab.delegate orelse return dialogs.call(decide, .{deny});
    @import("../web/delegates_ui.zig").askedForCapture(delegate, sel, wv, origin, frame, kind, decide);
}

fn noObject(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) ?objc.Object {
    return null;
}

fn notFound(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.NSUInteger {
    return @intCast(std.math.maxInt(objc.NSInteger));
}

fn webFor(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) ?objc.Object {
    return if (docOf(self)) |d| d.web else null;
}

fn titleFor(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) ?objc.Object {
    return if (docOf(self)) |d| objc.msg(?objc.Object, d.web, "title", .{}) else null;
}

fn urlFor(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) ?objc.Object {
    return if (docOf(self)) |d| objc.msg(?objc.Object, d.web, "URL", .{}) else null;
}

fn loadedFor(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.BOOL {
    const d = docOf(self) orelse return objc.YES;
    return !objc.msg(objc.BOOL, d.web, "isLoading", .{});
}

fn no(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.BOOL {
    return objc.NO;
}

fn closeFor(self: objc.Object, _: objc.SEL, _: objc.Object, done: *const anyopaque) callconv(.c) void {
    if (docOf(self)) |d| closeWith(d, Closed);
    dialogs.call(done, .{@as(?objc.Object, null)});
}

