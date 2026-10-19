//! Browser's `WKUIDelegate` and the rest of WebKit's questions (Browser.swift
//! 4363-4447, 4657-4710, 4823-4839; Dialogs.swift 128-379): a link that asks
//! for a new window gets a tab, alert/confirm/prompt and file choosing go
//! through `dialogs.zig`, sign-ins and bad certificates are asked about,
//! another app's address is handed off, the camera and microphone are
//! answered from what was remembered, and a page whose process went away
//! comes back.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const tab_mod = @import("tab.zig");
const Tab = tab_mod.Tab;
const Browser = @import("../model/browser.zig").Browser;
const Parts = @import("../data/url.zig").Parts;
const app_name = @import("../app/kea.zig").app_name;
const nav = @import("delegates_nav.zig");
const page_view = @import("page_view.zig");
const state = @import("tab_state.zig");
const dialogs = @import("dialogs.zig");

pub const methods = [_]objc.Method{
    .{ .name = "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", .imp = &createWebView, .types = "@@:@@@@" },
    .{ .name = "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:", .imp = &runAlert, .types = "v@:@@@@?" },
    .{ .name = "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:", .imp = &runConfirm, .types = "v@:@@@@?" },
    .{ .name = "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:", .imp = &runPrompt, .types = "v@:@@@@@?" },
    .{ .name = "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:", .imp = &runOpenPanel, .types = "v@:@@@@?" },
    .{ .name = "webView:didReceiveAuthenticationChallenge:completionHandler:", .imp = &challenged, .types = "v@:@@@?" },
    .{ .name = "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:", .imp = &askedForCapture, .types = "v@:@@@q@?" },
    .{ .name = "_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:", .imp = &@import("notifications.zig").asked, .types = "v@:@@@?" },
    .{ .name = "webViewDidClose:", .imp = &didClose, .types = "v@:@" },
    .{ .name = "webViewWebContentProcessDidTerminate:", .imp = &didTerminate, .types = "v@:@" },
};

fn originHost(frame: objc.Object) []const u8 {
    const origin = objc.msg(objc.Object, frame, "securityOrigin", .{});
    return objc.fromNSString(objc.msg(?objc.Object, origin, "host", .{}));
}

// MARK: a new window

/// A link that asks for a new window gets a new tab, built with the
/// configuration WebKit hands over — with a controller of its own, so the
/// opened tab never claims its opener's handlers.
fn createWebView(self: objc.Object, _: objc.SEL, wv: objc.Object, configuration: objc.Object, action: objc.Object, features: objc.Object) callconv(.c) ?objc.Object {
    const source = nav.tabOf(self) orelse return null;
    const b = source.browser orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ucc = objc.new("WKUserContentController");
    defer objc.release(ucc);
    objc.msg(void, configuration, "setUserContentController:", .{ucc});
    const t = Tab.createWith(b.gpa, b.kea.tabId(), source.shy, configuration, b.kea) catch return null;
    const toolbars = objc.msg(?objc.Object, features, "toolbarsVisibility", .{});
    t.popup = objc.msg(?objc.Object, features, "width", .{}) != null or objc.msg(?objc.Object, features, "height", .{}) != null or
        (toolbars != null and !objc.msg(objc.BOOL, toolbars.?, "boolValue", .{}));
    t.opener = source.id;
    b.prepare(t);
    // The link menu's Open Link in New Tab: behind this tab.
    if (page_view.takeBehind(wv)) {
        if (b.prefs.uses_tab_groups and !t.shy) t.group_id = source.group_id;
        b.tabs.insert(b.gpa, b.placeForNew(), t) catch @panic("OOM");
        b.arrangeGroupedTabs(null);
    } else {
        b.adopt(t);
        b.setActive(t.id);
        b.setEditing(false);
    }
    if (objc.msg(?objc.Object, objc.msg(objc.Object, action, "request", .{}), "URL", .{})) |u|
        t.setAddressOptimistically(objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{})));
    b.rememberSession();
    b.redraw();
    return t.web;
}

// MARK: alert, confirm, prompt

/// `paneAsking`: a page of the pair on screen asks over its own pane.
fn inPane(t: *Tab) bool {
    const b = t.browser orelse return false;
    return b.prefs.split_view and b.inSplit(t);
}

fn question(self: objc.Object, kind: dialogs.Kind, frame: objc.Object, message: ?objc.Object, default_text: ?objc.Object, completion: *const anyopaque) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const t = nav.tabOf(self) orelse return answerNow(kind, completion);
    const a = dialogs.make(t, kind, originHost(frame), objc.fromNSString(message), completion) orelse return answerNow(kind, completion);
    if (kind == .prompt) a.input.set(objc.fromNSString(default_text));
    if (inPane(t)) {
        a.pane = true;
        t.questions.append(t.gpa, a) catch return dialogs.answer(a, false, null);
        return t.changed(.state);
    }
    dialogs.ask(t, a);
}

/// Nobody to ask: answered as dismissed, as WebKit wants every one answered.
fn answerNow(kind: dialogs.Kind, completion: *const anyopaque) void {
    switch (kind) {
        .alert => dialogs.call(completion, .{}),
        .confirm => dialogs.call(completion, .{false}),
        else => dialogs.call(completion, .{@as(?objc.Object, null)}),
    }
}

fn runAlert(self: objc.Object, _: objc.SEL, _: objc.Object, msg: ?objc.Object, frame: objc.Object, comp: *const anyopaque) callconv(.c) void {
    question(self, .alert, frame, msg, null, comp);
}

fn runConfirm(self: objc.Object, _: objc.SEL, _: objc.Object, msg: ?objc.Object, frame: objc.Object, comp: *const anyopaque) callconv(.c) void {
    question(self, .confirm, frame, msg, null, comp);
}

fn runPrompt(self: objc.Object, _: objc.SEL, _: objc.Object, prompt: ?objc.Object, def: ?objc.Object, frame: objc.Object, comp: *const anyopaque) callconv(.c) void {
    question(self, .prompt, frame, prompt, def, comp);
}

/// A file input: over its own page only. A hidden run never shows the
/// panel and answers as cancelled.
fn runOpenPanel(self: objc.Object, _: objc.SEL, _: objc.Object, params: objc.Object, frame: objc.Object, comp: *const anyopaque) callconv(.c) void {
    const t = nav.tabOf(self) orelse return dialogs.call(comp, .{@as(?objc.Object, null)});
    if (t.kea.opts.hidden) return dialogs.call(comp, .{@as(?objc.Object, null)});
    const a = dialogs.make(t, .open_panel, originHost(frame), "", comp) orelse return dialogs.call(comp, .{@as(?objc.Object, null)});
    a.subject = objc.retain(params);
    dialogs.ask(t, a);
}

// MARK: who you are, who the site is

fn challenged(self: objc.Object, _: objc.SEL, _: objc.Object, challenge: objc.Object, comp: *const anyopaque) callconv(.c) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const space = objc.msg(objc.Object, challenge, "protectionSpace", .{});
    const method = objc.fromNSString(objc.msg(?objc.Object, space, "authenticationMethod", .{}));
    const default_handling: objc.NSInteger = 1;
    const cancel: objc.NSInteger = 2;
    const none: ?objc.Object = null;
    const t = nav.tabOf(self) orelse return dialogs.call(comp, .{ default_handling, none });
    var host_buf: [256]u8 = undefined;
    const raw_host = objc.fromNSString(objc.msg(?objc.Object, space, "host", .{}));
    const host = std.ascii.lowerString(&host_buf, raw_host[0..@min(raw_host.len, host_buf.len)]);
    if (std.mem.eql(u8, method, "NSURLAuthenticationMethodServerTrust")) {
        if (objc.msg(?objc.Object, space, "serverTrust", .{}) == null or dialogs.trusted(challenge))
            return dialogs.call(comp, .{ default_handling, none });
        if (dialogs.isLoopback(host) or dialogs.isExcused(host)) {
            const trust = objc.msg(objc.Object, space, "serverTrust", .{});
            return dialogs.call(comp, .{ @as(objc.NSInteger, 0), objc.msg(objc.Object, objc.class("NSURLCredential"), "credentialForTrust:", .{trust}) });
        }
        // Only the page asked for is worth a question.
        const page = Parts.parse(t.address orelse t.pending orelse "") orelse return dialogs.call(comp, .{ default_handling, none });
        if (!std.ascii.eqlIgnoreCase(page.hostName() orelse "", host)) return dialogs.call(comp, .{ default_handling, none });
        const a = dialogs.make(t, .trust, host, "", comp) orelse return dialogs.call(comp, .{ cancel, none });
        a.subject = objc.retain(challenge);
        return dialogs.ask(t, a);
    }
    if (std.mem.eql(u8, method, "NSURLAuthenticationMethodHTTPBasic") or std.mem.eql(u8, method, "NSURLAuthenticationMethodHTTPDigest") or
        std.mem.eql(u8, method, "NSURLAuthenticationMethodNTLM"))
    {
        const failures = objc.msg(objc.NSInteger, challenge, "previousFailureCount", .{});
        if (failures >= 2) return dialogs.call(comp, .{ cancel, none });
        var buf: [400]u8 = undefined;
        const realm = objc.fromNSString(objc.msg(?objc.Object, space, "realm", .{}));
        const said = if (realm.len > 0) std.fmt.bufPrint(&buf, "\u{201C}{s}\u{201D}", .{realm}) catch "" else "The site wants a name and a password.";
        var msg_buf: [480]u8 = undefined;
        const info = if (failures > 0) std.fmt.bufPrint(&msg_buf, "{s}\nThat wasn't accepted — try again.", .{said}) catch said else said;
        const a = dialogs.make(t, .sign_in, raw_host, info, comp) orelse return dialogs.call(comp, .{ cancel, none });
        a.subject = objc.retain(challenge);
        return dialogs.ask(t, a);
    }
    dialogs.call(comp, .{ default_handling, none });
}

/// `handOff`: an address for another app — asked about, as in Safari,
/// unless it is a mail or phone link you just clicked.
pub fn handOff(t: *Tab, wv: objc.Object, url: objc.Object, scheme: []const u8, action: objc.Object) void {
    const clicked = objc.msg(objc.NSInteger, action, "navigationType", .{}) == 0;
    const source = objc.msg(?objc.Object, action, "sourceFrame", .{});
    const top_url = tab_mod.currentUrl(wv) orelse "";
    const top = if (Parts.parse(top_url)) |p| p.hostName() orelse "" else "";
    const asker = if (source) |s| originHost(s) else "";
    const own_site = (source != null and objc.msg(objc.BOOL, source.?, "isMainFrame", .{})) or
        (top.len > 0 and asker.len > 0 and dialogs.sameSite(asker, top));
    const target = objc.msg(?objc.Object, action, "targetFrame", .{});
    if (!((target != null and objc.msg(objc.BOOL, target.?, "isMainFrame", .{})) or clicked or own_site)) return;
    const workspace = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const app = objc.msg(?objc.Object, workspace, "URLForApplicationToOpenURL:", .{url}) orelse return;
    // A hidden run never shows the question.
    if (t.kea.opts.hidden) return;
    if (clicked and (std.mem.eql(u8, scheme, "mailto") or std.mem.eql(u8, scheme, "tel"))) {
        _ = objc.msg(objc.BOOL, workspace, "openURL:", .{url});
        return;
    }
    const manager = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const shown = objc.fromNSString(objc.msg(?objc.Object, manager, "displayNameAtPath:", .{objc.msg(objc.Object, app, "path", .{})}));
    const name = if (std.mem.endsWith(u8, shown, ".app")) shown[0 .. shown.len - 4] else shown;
    const a = dialogs.make(t, .hand_off, top, name, null) orelse return;
    a.subject = objc.retain(url);
    dialogs.ask(t, a);
}

// MARK: the camera and microphone

/// Answered from what was remembered for the origin (`capture.<site>|<type>`),
/// never for a private tab; otherwise WebKit asks itself until the
/// capture bar arrives (P8.10).
fn askedForCapture(self: objc.Object, _: objc.SEL, wv: objc.Object, origin: objc.Object, frame: objc.Object, kind: objc.NSInteger, decide: *const anyopaque) callconv(.c) void {
    const prompt: objc.NSInteger = 0;
    const t = nav.tabOf(self) orelse return dialogs.call(decide, .{prompt});
    const pool = objc.Pool.push();
    defer pool.pop();
    const asker = objc.msg(objc.Object, frame, "securityOrigin", .{});
    const asker_scheme = objc.fromNSString(objc.msg(?objc.Object, asker, "protocol", .{}));
    var site_buf: [320]u8 = undefined;
    const site = if (std.ascii.eqlIgnoreCase(asker_scheme, "chrome-extension") or std.ascii.eqlIgnoreCase(asker_scheme, "webkit-extension"))
        std.fmt.bufPrint(&site_buf, "{s}://{s}", .{ asker_scheme, originHost(frame) }) catch return dialogs.call(decide, .{prompt})
    else blk: {
        const host = objc.fromNSString(objc.msg(?objc.Object, origin, "host", .{}));
        if (host.len == 0) break :blk if (Parts.parse(t.url())) |p| p.hostName() orelse "This page" else "This page";
        const scheme = objc.fromNSString(objc.msg(?objc.Object, origin, "protocol", .{}));
        const port = objc.msg(objc.NSInteger, origin, "port", .{});
        break :blk if (port == 0)
            std.fmt.bufPrint(&site_buf, "{s}://{s}", .{ scheme, host }) catch return dialogs.call(decide, .{prompt})
        else
            std.fmt.bufPrint(&site_buf, "{s}://{s}:{d}", .{ scheme, host, port }) catch return dialogs.call(decide, .{prompt});
    };
    const store = objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "websiteDataStore", .{});
    const shy = t.shy or !objc.msg(objc.BOOL, store, "isPersistent", .{});
    var key_buf: [360]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "capture.{s}|{d}", .{ site, kind }) catch return dialogs.call(decide, .{prompt});
    if (!shy) if (t.kea.store.bool(key)) |remembered| return dialogs.call(decide, .{@as(objc.NSInteger, if (remembered) 1 else 2)});
    dialogs.call(decide, .{prompt});
}

// MARK: a page closing itself, a page whose process went away

/// `webViewDidClose`: a sign-in window done — back to whoever opened it.
fn didClose(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const t = nav.tabOf(self) orelse return;
    const b = t.browser orelse return;
    if (b.indexOf(t) == null) return;
    if (t.opener) |id| if (b.tabById(id)) |home| b.select(home);
    t.own(&t.pin, null);
    b.close(t);
}

/// In front of you: straight back. Three in twenty seconds is a page that
/// kills its own process; behind another tab, the moment you come back.
fn didTerminate(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const t = nav.tabOf(self) orelse return;
    const b = t.browser orelse return;
    while (t.questions.items.len > 0) dialogs.answer(t.questions.items[0], false, null);
    if (t.id == b.active_id and !t.isBlank()) {
        const now = @import("../data/json.zig").now();
        var kept: usize = 0;
        for (t.crashes.items) |at| if (now - at < 20) {
            t.crashes.items[kept] = at;
            kept += 1;
        };
        t.crashes.shrinkRetainingCapacity(kept);
        t.crashes.append(t.gpa, now) catch {};
        if (t.crashes.items.len >= 3) {
            var buf: [96]u8 = undefined;
            t.setFailure(std.fmt.bufPrint(&buf, "This page keeps crashing, so {s} stopped reloading it.", .{app_name}) catch "");
            t.changed(.state);
        } else state.recoverFromCrash(t);
    } else t.stale = true;
}
