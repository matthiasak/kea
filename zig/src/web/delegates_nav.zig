//! `KeaZigWebDelegate`: Browser's `WKNavigationDelegate` (Browser.swift
//! 4184-4955) — which navigations go ahead, where links that ask for a new
//! tab go, what a commit, a finish and a failure do to the tab, History's
//! one visit per load — plus the tab's events reaching its window
//! (`prepare`, 3759-3868). One delegate per tab; its window is `tab.browser`.
//! The UI half (dialogs, new windows, crashes) is `delegates_ui.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const tab_mod = @import("tab.zig");
const Tab = tab_mod.Tab;
const Browser = @import("../model/browser.zig").Browser;
const Parts = @import("../data/url.zig").Parts;
const address = @import("../model/address.zig");
const app_name = @import("../app/kea.zig").app_name;
const config = @import("config.zig");
const page_view = @import("page_view.zig");
const state = @import("tab_state.zig");
const scripts = @import("tab_scripts.zig");
const dialogs = @import("dialogs.zig");
const ui_half = @import("delegates_ui.zig");

pub const Change = enum { address, title, state };

fn class() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigWebDelegate",
        .protocols = &.{ "WKNavigationDelegate", "WKUIDelegate", "WKScriptMessageHandler" },
        .methods = &([_]objc.Method{
            .{ .name = "webView:decidePolicyForNavigationAction:preferences:decisionHandler:", .imp = &decideAction, .types = "v@:@@@@?" },
            .{ .name = "webView:decidePolicyForNavigationResponse:decisionHandler:", .imp = &decideResponse, .types = "v@:@@@?" },
            .{ .name = "webView:navigationAction:didBecomeDownload:", .imp = &becameDownload, .types = "v@:@@@" },
            .{ .name = "webView:navigationResponse:didBecomeDownload:", .imp = &becameDownload, .types = "v@:@@@" },
            .{ .name = "_webView:contextMenuDidCreateDownload:", .imp = &menuDownload, .types = "v@:@@" },
            .{ .name = "_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:", .imp = &@import("downloads_keep.zig").saveDataToFile, .types = "v@:@@@@@" },
            .{ .name = "webView:didCommitNavigation:", .imp = &didCommit, .types = "v@:@@" },
            .{ .name = "_webView:renderingProgressDidChange:", .imp = &renderingProgress, .types = "v@:@Q" },
            .{ .name = "webView:didFinishNavigation:", .imp = &didFinish, .types = "v@:@@" },
            .{ .name = "webView:didFailNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
            .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
            .{ .name = "userContentController:didReceiveScriptMessage:", .imp = &didReceiveMessage, .types = "v@:@@" },
        } ++ ui_half.methods),
    });
}

/// A tab's delegate, retained (+1); it hears for `t` until `discard`.
pub fn makeDelegate(t: *Tab) objc.Object {
    const d = objc.msg(objc.Object, class(), "new", .{});
    objc.setZig(d, t);
    return d;
}

pub fn tabOf(delegate: objc.Object) ?*Tab {
    return objc.getZig(Tab, delegate);
}

// MARK: the tab's events, heard by its window (`prepare`)

/// What a tab says changed: anywhere a tab lands is remembered for next
/// launch; its title, once it settles, goes into History; the window
/// draws again.
pub fn tabChanged(b: *Browser, t: *Tab, what: Change) void {
    switch (what) {
        .address => if (!b.restoring and b.indexOf(t) != null) b.rememberSession(),
        .title => if (t.page_title.len > 0) retitle(t),
        .state => {},
    }
    b.redraw();
    // A small window's page draws in that window (Little.swift).
    @import("little.zig").changed(t);
}

/// `throttle(for: 2, latest: true)` on the title, with the address it was
/// the title of.
fn retitle(t: *Tab) void {
    const now = nanoui.ui.clock.now();
    if (now - t.retitled_at >= 2) return retitleNow(t);
    if (t.retitle_due) return;
    t.retitle_due = true;
    t.after(2 - (now - t.retitled_at), retitleFired, 0);
}

fn retitleFired(t: *Tab, _: usize) void {
    t.retitle_due = false;
    retitleNow(t);
}

fn retitleNow(t: *Tab) void {
    t.retitled_at = nanoui.ui.clock.now();
    const b = t.browser orelse return;
    if (t.shy or t.page_title.len == 0) return;
    const page = t.address orelse return;
    b.history.retitle(page, t.page_title);
}

/// `onKeys`: with two pages up, the keys going to the other one make it
/// the focused page.
pub fn pageTookKeys(b: *Browser, t: *Tab) void {
    const p = b.activeSplit() orelse return;
    if (!p.contains(t.id) or b.active_id == t.id) return;
    b.focusPane(t);
}

var zoom_shown: i64 = -1;

/// `onZoom`: the zoom read-out, rewritten while it changes.
// ponytail: one read-out for the app; Swift keeps `zoomShown` per window.
pub fn zoomed(b: *Browser, value: f64) void {
    const percent: i64 = @intFromFloat(@round(value * 100));
    if (percent == zoom_shown) return;
    zoom_shown = percent;
    var buf: [16]u8 = undefined;
    b.announce(std.fmt.bufPrint(&buf, "{d}%", .{percent}) catch return);
}

// MARK: deciding

/// `WKNavigationActionPolicy`.
const cancel: objc.NSInteger = 0;
const allow: objc.NSInteger = 1;
const download: objc.NSInteger = 2;

const shift: objc.NSUInteger = 1 << 17;
const control: objc.NSUInteger = 1 << 18;
const option: objc.NSUInteger = 1 << 19;
const command: objc.NSUInteger = 1 << 20;

/// `WKNavigationTypeLinkActivated`.
const link_activated: objc.NSInteger = 0;

fn isMainTarget(action: objc.Object) bool {
    const frame = objc.msg(?objc.Object, action, "targetFrame", .{}) orelse return true;
    return objc.msg(objc.BOOL, frame, "isMainFrame", .{});
}

fn requestUrl(holder: objc.Object) ?objc.Object {
    return objc.msg(?objc.Object, objc.msg(objc.Object, holder, "request", .{}), "URL", .{});
}

fn decideAction(self: objc.Object, _: objc.SEL, wv: objc.Object, action: objc.Object, prefs: objc.Object, handler: *const anyopaque) callconv(.c) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const policy = decide(self, wv, action);
    if (policy == allow and isMainTarget(action)) if (tabOf(self)) |t| if (requestUrl(action)) |u| {
        const shy = t.shy or !objc.msg(objc.BOOL, objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "websiteDataStore", .{}), "isPersistent", .{});
        const host = objc.fromNSString(objc.msg(?objc.Object, u, "host", .{}));
        config.applyAutoplay(&t.kea.store, prefs, host, shy);
        // The next document's hidden things, and the blocker for where it goes.
        @import("curtain_js.zig").navigating(t, wv, objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{})));
    };
    dialogs.call(handler, .{ policy, prefs });
}

/// `decide`: links the window has no business showing are handed to
/// whoever owns them.
fn decide(self: objc.Object, wv: objc.Object, action: objc.Object) objc.NSInteger {
    if (objc.msg(objc.BOOL, action, "shouldPerformDownload", .{})) return download;
    const u = requestUrl(action) orelse return allow;
    const url = objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
    const scheme_raw = objc.fromNSString(objc.msg(?objc.Object, u, "scheme", .{}));
    if (scheme_raw.len == 0) return allow;
    var scheme_buf: [64]u8 = undefined;
    const scheme = std.ascii.lowerString(&scheme_buf, scheme_raw[0..@min(scheme_raw.len, scheme_buf.len)]);
    const t = tabOf(self) orelse return allow;
    const b = t.browser;
    const main = objc.msg(?objc.Object, action, "targetFrame", .{}) != null and isMainTarget(action);
    // 0.0.0.0, as a dev server prints it: this Mac, as localhost.
    if (main) if (address.reachable(t.gpa, url) catch null) |local| {
        defer t.gpa.free(local);
        tab_mod.open(wv, local);
        return cancel;
    };
    const kind = objc.msg(objc.NSInteger, action, "navigationType", .{});
    const flags = objc.msg(objc.NSUInteger, action, "modifierFlags", .{});
    const web = std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https");
    // A middle-click's link was opened by MiddleRelay already.
    if (kind == link_activated and objc.msg(objc.NSInteger, action, "buttonNumber", .{}) == 4) return cancel;
    if (b) |br| {
        // Shift-click, when Settings says so: a peek at the link (P7).
        if (@hasDecl(Browser, "peek")) if (br.prefs.peeks_links and kind == link_activated and web and
            flags & (shift | command | option | control) == shift and br.peek_tab == null)
        {
            br.peek(url, t);
            return cancel;
        };
        // ⌘-click opens beside this tab and leaves you here; ⌘⇧ goes with it.
        if (kind == link_activated and web and flags & command != 0) {
            _ = br.open(url, .{ .foreground = flags & shift != 0, .from = t, .may_wait = true });
            return cancel;
        }
    }
    const allowed = [_][]const u8{ "http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension" };
    for (allowed) |s| if (std.mem.eql(u8, scheme, s)) return allow;
    // The e2e runner's own pages.
    if (t.kea.opts.scheme_handler != null and std.mem.eql(u8, scheme, "kea-test")) return allow;
    ui_half.handOff(t, wv, u, scheme, action);
    return cancel;
}

/// `WKNavigationResponsePolicy`: anything the window can't show is kept.
fn decideResponse(_: objc.Object, _: objc.SEL, _: objc.Object, response: objc.Object, handler: *const anyopaque) callconv(.c) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const r = objc.msg(objc.Object, response, "response", .{});
    if (objc.msg(objc.BOOL, r, "isKindOfClass:", .{objc.class("NSHTTPURLResponse")})) {
        const status = objc.msg(objc.NSInteger, r, "statusCode", .{});
        if (status >= 300 and status <= 399) return dialogs.call(handler, .{allow});
        const disposition = objc.fromNSString(objc.msg(?objc.Object, r, "valueForHTTPHeaderField:", .{objc.nsString("Content-Disposition")}));
        if (std.ascii.startsWithIgnoreCase(std.mem.trim(u8, disposition, " "), "attachment")) return dialogs.call(handler, .{download});
    }
    dialogs.call(handler, .{if (objc.msg(objc.BOOL, response, "canShowMIMEType", .{})) allow else download});
}

/// The file goes to the window's downloads (P5.5 `keep`), and a tab that
/// showed nothing but it lets go (`dropEmpty`).
fn becameDownload(self: objc.Object, _: objc.SEL, wv: objc.Object, _: objc.Object, dl: objc.Object) callconv(.c) void {
    const t = tabOf(self) orelse return;
    const b = t.browser orelse return;
    if (@hasDecl(Browser, "keep")) b.keep(dl, wv);
    dropEmpty(b, t);
}

fn menuDownload(self: objc.Object, _: objc.SEL, wv: objc.Object, dl: objc.Object) callconv(.c) void {
    const t = tabOf(self) orelse return;
    const b = t.browser orelse return;
    if (@hasDecl(Browser, "keep")) b.keep(dl, wv);
}

/// `dropEmpty`: a tab whose first page was a file forgets the address;
/// opened by a page's link, it closes and you are back on that page.
fn dropEmpty(b: *Browser, t: *Tab) void {
    if (t.committed != null or t.pin != null) return;
    t.forget();
    const opener = t.opener orelse return;
    if (b.tabs.items.len <= 1 or b.indexOf(t) == null) return;
    if (t.id == b.active_id) if (b.tabById(opener)) |home| b.select(home);
    b.close(t);
}

// MARK: arriving

fn didCommit(self: objc.Object, _: objc.SEL, wv: objc.Object, _: ?objc.Object) callconv(.c) void {
    const t = tabOf(self) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    // `didCommit()`: the page on screen is the new one.
    if (tab_mod.currentUrl(wv)) |u| if (u.len > 0 and !std.mem.eql(u8, u, "about:blank")) t.own(&t.committed, u);
    if (t.browser) |b| if (t.id == b.active_id) @import("../chrome/link_bubble.zig").dismiss(b);
    if (t.browser) |b| if (t.id == b.active_id) @import("page_find.zig").invalidatePage(b, false);
    t.setFailure(null);
    t.typing = false;
    state.applyRememberedZoom(t);
    state.uncover(t, 0.45);
    t.changed(.state);
}

fn renderingProgress(_: objc.Object, _: objc.SEL, wv: objc.Object, events: objc.NSUInteger) callconv(.c) void {
    if (events & page_view.first_frame != 0) page_view.showFirstFrame(wv);
}

fn didFinish(self: objc.Object, _: objc.SEL, wv: objc.Object, _: ?objc.Object) callconv(.c) void {
    // A page with nothing to lay out never has a first frame.
    page_view.showFirstFrame(wv);
    const t = tabOf(self) orelse return;
    const page = t.address orelse return;
    state.uncover(t, 0);
    // Asked whether or not the tab shows one: it may be turned on later.
    if (t.favicons) |f| f.fetch(t, false);
    // The find bar still open over a page that has just come in.
    @import("page_find.zig").arrived(t);
    const b = t.browser orelse return;
    if (t.shy or b.restoring) return;
    b.history.record(page, t.page_title);
    b.handOff();
    // A site's home page that says where its search is (OpenSearch).
    if (!b.prefs.searches_sites) return;
    const p = Parts.parse(page) orelse return;
    if (!std.ascii.eqlIgnoreCase(p.scheme orelse "", "https") or !(p.path.len == 0 or std.mem.eql(u8, p.path, "/"))) return;
    t.evaluate(@embedFile("js/opensearch_lookup.js"), .kea, learned, 0);
}

fn learned(t: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const v = value orelse return;
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) return;
    const b = t.browser orelse return;
    _ = b.kea.site_search.learn(t.url(), objc.fromNSString(v));
}

fn didFail(self: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object, err: objc.Object) callconv(.c) void {
    const t = tabOf(self) orelse return;
    state.uncover(t, 0);
    const code = objc.msg(objc.NSInteger, err, "code", .{});
    // Cancelled: a redirect, a stopped load, a second Return.
    if (code == -999) return;
    // A page that turned into a download ends with "frame load interrupted".
    if (code == 102 and std.mem.eql(u8, objc.fromNSString(objc.msg(?objc.Object, err, "domain", .{})), "WebKitErrorDomain")) return;
    var buf: [128]u8 = undefined;
    t.setFailure(message(&buf, code));
    t.changed(.state);
}

/// `message(for:)`, Kea the app named as `app_name`.
fn message(buf: []u8, code: objc.NSInteger) []const u8 {
    return switch (code) {
        -1003, -1006 => "Nothing lives at that address — not even a kea.",
        -1009, -1005 => std.fmt.bufPrint(buf, "No connection. {s} is grounded until the network's back.", .{app_name}) catch "",
        -1001 => std.fmt.bufPrint(buf, "The site took too long to answer, so {s} flew on.", .{app_name}) catch "",
        -1004 => std.fmt.bufPrint(buf, "The site refused the connection and shooed {s} away.", .{app_name}) catch "",
        -1200, -1202 => std.fmt.bufPrint(buf, "The connection isn't secure, so {s} won't land here.", .{app_name}) catch "",
        else => "The page didn't load. Not even a kea could pry it open.",
    };
}

fn didReceiveMessage(self: objc.Object, _: objc.SEL, _: objc.Object, msg: objc.Object) callconv(.c) void {
    const t = tabOf(self) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    scripts.received(t, msg);
}
