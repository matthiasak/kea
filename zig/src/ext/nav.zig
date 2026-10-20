//! The extension half of the nav delegate's decisions (Browser.swift
//! 4231-4261, 4320-4360, 4810/4819/4848): an extension's OAuth sign-in
//! coming back, a website returning to a public extension page, and an
//! extension's page sending its own tab to a website. All of it only with
//! the controller there (`kea.ext`).
const std = @import("std");
const objc = @import("nanoui").objc;
const ext = @import("ext.zig");
const value = @import("value.zig");
const auth = @import("auth.zig");
const redirect = @import("redirect.zig");
const controller = @import("controller.zig");
const Tab = @import("../web/tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;
const delegates = @import("../web/delegates_nav.zig");

/// Before anything else is decided (4231-4238): the address is the
/// sign-in's answer, handed to the extension and never loaded.
pub fn signIn(t: *Tab, url: []const u8, main_frame: bool) bool {
    if (controller.of(t.kea) == null) return false;
    const b = t.browser orelse return false;
    return auth.intercept(url, b, t) or auth.handOver(url, main_frame, t);
}

/// After the 0.0.0.0 rewrite (4246-4261): a website returning to a public
/// extension page needs another view; an extension's page going to a
/// website does too. Both swap the tab where it stands (`Browser.replace`).
pub fn returning(t: *Tab, wv: objc.Object, action: objc.Object, url: []const u8, web: bool, main_target: bool) bool {
    if (controller.of(t.kea) == null) return false;
    // `routeExtensionReturn`.
    if (t.ext_return.source(t.gpa, action)) |source| {
        defer t.gpa.free(source);
        const target = ext.current(t.gpa, url) catch return false;
        defer if (target.ptr != url.ptr) t.gpa.free(target);
        if (std.mem.startsWith(u8, target, ext.scheme ++ ":") and handOverReturn(t, wv, target, source)) return true;
    }
    if (web and main_target) if (objc.msg(?objc.Object, wv, "URL", .{})) |here| {
        if (std.mem.eql(u8, objc.fromNSString(objc.msg(?objc.Object, here, "scheme", .{})), ext.scheme)) {
            later(t, null, url, null);
            return true;
        }
    };
    return false;
}

/// `handOverExtensionReturn`: only to a page the extension's manifest
/// exposes to `source`, swapped in on the next turn if nothing moved since.
fn handOverReturn(t: *Tab, wv: objc.Object, target: []const u8, source: []const u8) bool {
    if (t.shy) return false;
    const owner = controller.of(t.kea) orelse return false;
    const pool = objc.Pool.push();
    defer pool.pop();
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(target)}) orelse return false;
    const context = objc.msg(?objc.Object, owner.controller, "extensionContextForURL:", .{nsurl}) orelse return false;
    if (!objc.msg(objc.BOOL, context, "isLoaded", .{}) or objc.msg(?objc.Object, context, "webViewConfiguration", .{}) == null) return false;
    const manifest = value.toJson(t.gpa, objc.msg(?objc.Object, objc.msg(objc.Object, context, "webExtension", .{}), "manifest", .{})) orelse return false;
    defer manifest.deinit();
    if (!redirect.allows(target, source, manifest.value)) return false;
    later(t, wv, target, t.ext_return.revision);
    return true;
}

/// `DispatchQueue.main.async { replace(tab, going: url) }`, if the tab and
/// its view are still the ones (and, for a return, nothing moved since).
const Later = struct {
    serial: u64,
    view: ?usize,
    revision: ?u64,
    url: [:0]u8,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Later = @ptrCast(@alignCast(ctx.?));
        defer {
            std.heap.c_allocator.free(l.url);
            std.heap.c_allocator.destroy(l);
        }
        const t = Tab.alive(l.serial) orelse return;
        if (l.view) |v| if (@intFromPtr(t.web orelse return) != v) return;
        if (l.revision) |r| if (t.ext_return.revision != r) return;
        const b = t.browser orelse return;
        @import("../model/browser_ext.zig").replace(b, t, l.url);
    }
};

fn later(t: *Tab, wv: ?objc.Object, url: []const u8, revision: ?u64) void {
    const c = std.heap.c_allocator;
    const l = c.create(Later) catch return;
    l.* = .{ .serial = t.serial, .view = if (wv) |v| @intFromPtr(v) else null, .revision = revision, .url = c.dupeSentinel(u8, url, 0) catch return c.destroy(l) };
    objc.dispatchMain(l, Later.run);
}

// MARK: the delegate methods (KeaWebDelegate)

pub const methods = [_]objc.Method{
    .{ .name = "webView:didStartProvisionalNavigation:", .imp = &didStartProvisional, .types = "v@:@@" },
    .{ .name = "webView:didReceiveServerRedirectForProvisionalNavigation:", .imp = &didRedirect, .types = "v@:@@" },
};

fn didStartProvisional(self: objc.Object, _: objc.SEL, wv: objc.Object, navigation: ?objc.Object) callconv(.c) void {
    const t = delegates.tabOf(self) orelse return;
    const n = navigation orelse return;
    if (controller.of(t.kea) == null) return;
    t.ext_return.started(t.gpa, n, objc.msg(?objc.Object, wv, "URL", .{}));
}

fn didRedirect(self: objc.Object, _: objc.SEL, wv: objc.Object, navigation: ?objc.Object) callconv(.c) void {
    const t = delegates.tabOf(self) orelse return;
    const n = navigation orelse return;
    if (controller.of(t.kea) == null) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const r = t.ext_return.redirected(t.gpa, n, objc.msg(?objc.Object, wv, "URL", .{})) orelse return;
    defer r.deinit(t.gpa);
    const target = ext.current(t.gpa, r.target) catch return;
    defer if (target.ptr != r.target.ptr) t.gpa.free(target);
    if (handOverReturn(t, wv, target, r.source)) objc.msg(void, wv, "stopLoading", .{});
}

/// didCommit (4847-4848, with `Tab.didCommit`'s held address) and
/// didFail/didFailProvisional (4810, 4819).
pub fn ended(t: *Tab, wv: objc.Object, navigation: ?objc.Object, committed: bool) void {
    if (committed) {
        const pool = objc.Pool.push();
        defer pool.pop();
        auth.arrived(t, @import("../web/tab.zig").currentUrl(wv));
    }
    if (controller.of(t.kea) == null) return;
    t.ext_return.finished(t.gpa, navigation);
}
