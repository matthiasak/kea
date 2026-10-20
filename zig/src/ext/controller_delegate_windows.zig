//! tabs.create and windows.create (Extensions.swift 1351-1411): into Kea's
//! own rows and windows.
const std = @import("std");
const objc = @import("nanoui").objc;
const Extensions = @import("controller.zig").Extensions;
const ext = @import("ext.zig");
const value = @import("value.zig");
const adapters = @import("adapters.zig");
const frames = @import("controller_delegate_frames.zig");
const browsers = @import("../app/browsers.zig");
const WindowRecord = @import("../data/windows_file.zig").WindowRecord;
const Uuid = @import("../data/json.zig").Uuid;

const C = objc.Object;
const Sel = objc.SEL;
const H = *const anyopaque;

fn owner(d: objc.Object) ?*Extensions {
    return objc.getZig(Extensions, d);
}

fn absolute(url: objc.Object) []const u8 {
    return objc.fromNSString(objc.msg(objc.Object, url, "absoluteString", .{}));
}

/// tabs.create: in the window asked for, or the one in front.
pub fn openNewTab(d: objc.Object, _: Sel, _: C, configuration: objc.Object, _: C, h: H) callconv(.c) void {
    const reply = value.Reply.take(h);
    const self = owner(d) orelse return reply.ok(null);
    const pool = objc.Pool.push();
    defer pool.pop();
    const asked_window = objc.msg(?objc.Object, configuration, "window", .{});
    const mine = if (asked_window) |w| (if (isWindow(w)) adapters.browserOfWindow(w) else null) else null;
    const b = mine orelse self.browser() orelse return reply.ok(null);
    const url = if (objc.msg(?objc.Object, configuration, "url", .{})) |u| absolute(u) else "about:blank";
    if (frames.mayOpen(url)) |why| return reply.fail(why);
    const tab = b.open(url, .{ .foreground = objc.msg(objc.BOOL, configuration, "shouldBeActive", .{}), .at_end = true });
    if (objc.msg(objc.BOOL, configuration, "shouldBePinned", .{})) b.pin(tab, false);
    reply.ok(adapters.adapter(self, tab));
}

fn isWindow(o: objc.Object) bool {
    return objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class("KeaExtensionWindow")});
}

const popup_type: objc.NSInteger = 1;

/// windows.create: a window of its own with the pages asked for, in the
/// space of the window in front. A popup-type one is a small window of the
/// page (a password manager's vault, a sign-in).
pub fn openNewWindow(d: objc.Object, _: Sel, _: C, configuration: objc.Object, context: C, h: H) callconv(.c) void {
    const reply = value.Reply.take(h);
    const self = owner(d) orelse return reply.ok(null);
    const pool = objc.Pool.push();
    defer pool.pop();
    // A private window made as a normal one would put its pages in the
    // normal store and History: refused, as Chrome refuses without incognito.
    if (objc.msg(objc.BOOL, configuration, "shouldBePrivate", .{}))
        return reply.fail("Private windows can't be opened by extensions.");
    const urls = objc.msg(objc.Object, configuration, "tabURLs", .{});
    const n = objc.msg(objc.NSUInteger, urls, "count", .{});
    for (0..n) |i| if (frames.mayOpen(absolute(at(urls, i)))) |why| return reply.fail(why);
    const popup = objc.msg(objc.NSInteger, configuration, "windowType", .{}) == popup_type;
    // A popup has no address bar: a website, or this extension's own page.
    // Not data: or blob:, which name no site, nor another extension's.
    const own_id = objc.fromNSString(objc.msg(objc.Object, context, "uniqueIdentifier", .{}));
    if (popup) for (0..n) |i| {
        const u = at(urls, i);
        const scheme = objc.fromNSString(objc.msg(?objc.Object, u, "scheme", .{}));
        const host = objc.fromNSString(objc.msg(?objc.Object, u, "host", .{}));
        const own = (std.ascii.eqlIgnoreCase(scheme, ext.scheme) or std.ascii.eqlIgnoreCase(scheme, ext.former_scheme)) and std.ascii.eqlIgnoreCase(host, own_id);
        const web = std.ascii.eqlIgnoreCase(scheme, "https") or std.ascii.eqlIgnoreCase(scheme, "http");
        if (!(web or own or std.mem.eql(u8, absolute(u), "about:blank")))
            return reply.fail("A popup window shows a website or the extension's own page.");
    };

    // The frame asked for, when it is one (unset parts come as NaN, and
    // AppKit traps on a frame made of them).
    const front = self.browser();
    const asked = objc.msg(objc.CGRect, configuration, "frame", .{});
    var frame: ?objc.CGRect = if (frames.usable(asked)) frames.onScreen(asked) else null;
    if (frame == null and popup) if (screenOf(front)) |screen| {
        frame = frames.popupFrame(asked, screen);
    };

    const record: WindowRecord = .{ .id = Uuid.random(), .space = if (front) |f| f.space_id else Uuid.first };
    // The key it is listed under, else WebKit's own id.
    var key: []const u8 = own_id;
    for (self.contexts.keys(), self.contexts.values()) |k, v| if (v == context) {
        key = k;
        break;
    };
    const made = if (popup) browsers.openPopup(self.kea, &record, frame, key) else browsers.open(self.kea, &record, frame);
    const fresh = made catch return reply.fail("The window couldn't be opened.");
    for (0..n) |i| _ = fresh.open(absolute(at(urls, i)), .{ .foreground = i == 0, .at_end = true });
    // The empty tab a new window starts with goes once there are pages.
    if (n > 0) {
        var i: usize = fresh.tabs.items.len;
        while (i > 0) {
            i -= 1;
            if (i < fresh.tabs.items.len and fresh.tabs.items[i].isBlank()) fresh.close(fresh.tabs.items[i]);
        }
    }
    if (!objc.msg(objc.BOOL, configuration, "shouldBeFocused", .{})) if (browsers.acting(self.kea)) |f| if (f.window) |w| {
        objc.msg(void, w.nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    };
    reply.ok(adapters.windowOf(self, fresh));
}

fn at(arr: objc.Object, i: usize) objc.Object {
    return objc.msg(objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
}

/// The front window's screen's visible frame, else the main screen's.
fn screenOf(front: anytype) ?objc.CGRect {
    const screen = blk: {
        if (front) |f| if (f.window) |w| if (objc.msg(?objc.Object, w.nswindow, "screen", .{})) |s| break :blk s;
        break :blk objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return null;
    };
    return objc.msg(objc.CGRect, screen, "visibleFrame", .{});
}
