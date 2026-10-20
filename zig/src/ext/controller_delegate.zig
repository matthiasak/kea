//! WebKit asks, the browser answers (Extensions.swift 1328-1528): the
//! `WKWebExtensionControllerDelegate`, an NSObject whose zig pointer is the
//! `Extensions`. Windows and tabs WebKit asks for, opening them, options
//! pages, the three permission prompts, the button's popup, and messages to
//! the app or to a native host.
const std = @import("std");
const objc = @import("nanoui").objc;
const Extensions = @import("controller.zig").Extensions;
const ext = @import("ext.zig");
const value = @import("value.zig");
const fence = @import("controller_fence.zig");
const asking = @import("controller_asking.zig");
const buttons = @import("controller_buttons.zig");
const adapters = @import("adapters.zig");
const frames = @import("controller_delegate_frames.zig");
const windows = @import("controller_delegate_windows.zig");
const answer = @import("shims/answer.zig");
const application = @import("shims/install.zig").application;
const native = @import("native.zig");
const socket = @import("socket.zig");
const dialogs = @import("../web/dialogs.zig");

pub const mayOpen = frames.mayOpen;
pub const onScreen = frames.onScreen;
pub const popupFrame = frames.popupFrame;

const C = objc.Object;
const Sel = objc.SEL;
const H = *const anyopaque;

/// Makes the delegate, points it at `self`, and sets it on the controller.
pub fn attach(self: *Extensions) void {
    const cls = objc.defineClass(.{
        .name = "KeaZigExtensionsDelegate",
        .protocols = &.{"WKWebExtensionControllerDelegate"},
        .methods = &.{
            .{ .name = "webExtensionController:openWindowsForExtensionContext:", .imp = &openWindows, .types = "@@:@@" },
            .{ .name = "webExtensionController:focusedWindowForExtensionContext:", .imp = &focusedWindow, .types = "@@:@@" },
            .{ .name = "webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:", .imp = &windows.openNewTab, .types = "v@:@@@@?" },
            .{ .name = "webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:", .imp = &windows.openNewWindow, .types = "v@:@@@@?" },
            .{ .name = "webExtensionController:openOptionsPageForExtensionContext:completionHandler:", .imp = &openOptions, .types = "v@:@@@?" },
            .{ .name = "webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:", .imp = &promptPermissions, .types = "v@:@@@@@?" },
            .{ .name = "webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:", .imp = &promptURLs, .types = "v@:@@@@@?" },
            .{ .name = "webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:", .imp = &promptPatterns, .types = "v@:@@@@@?" },
            .{ .name = "webExtensionController:didUpdateAction:forExtensionContext:", .imp = &didUpdateAction, .types = "v@:@@@" },
            .{ .name = "webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:", .imp = &presentPopup, .types = "v@:@@@@?" },
            .{ .name = "webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:", .imp = &sendMessage, .types = "v@:@@@@@?" },
            .{ .name = "webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:", .imp = &connect, .types = "v@:@@@@?" },
        },
    });
    const d = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
    objc.setZig(d, self);
    self.delegate = d;
    objc.msg(void, self.controller, "setDelegate:", .{d});
}

pub fn owner(d: objc.Object) ?*Extensions {
    return objc.getZig(Extensions, d);
}

fn idOf(context: C) []const u8 {
    return objc.fromNSString(objc.msg(objc.Object, context, "uniqueIdentifier", .{}));
}

/// Every window, oldest first — the order Security's shim counts on.
fn openWindows(d: objc.Object, _: Sel, _: C, _: C) callconv(.c) objc.Object {
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    const self = owner(d) orelse return arr;
    for (self.kea.browsers.items) |b| objc.msg(void, arr, "addObject:", .{adapters.windowOf(self, b)});
    return arr;
}

fn focusedWindow(d: objc.Object, _: Sel, _: C, _: C) callconv(.c) ?objc.Object {
    const self = owner(d) orelse return null;
    return adapters.windowOf(self, self.browser() orelse return null);
}

fn openOptions(d: objc.Object, _: Sel, _: C, context: C, h: H) callconv(.c) void {
    defer dialogs.call(h, .{@as(?objc.Object, null)});
    const self = owner(d) orelse return;
    const url = objc.msg(?objc.Object, context, "optionsPageURL", .{}) orelse return;
    const b = self.browser() orelse return;
    _ = b.open(objc.fromNSString(objc.msg(objc.Object, url, "absoluteString", .{})), .{ .foreground = true });
}

// MARK: the three prompts

/// A prompt's answer: the set WebKit offered (or a filtered one), given on
/// yes; an empty one on no.
const Prompt = struct {
    reply: value.Reply,
    granted: objc.Object,
    /// Fenced again once granted (match patterns).
    fence_context: ?objc.Object = null,

    fn done(ctx: *anyopaque, yes: bool) void {
        const p: *Prompt = @ptrCast(@alignCast(ctx));
        const pool = objc.Pool.push();
        defer pool.pop();
        p.reply.ok(if (yes) p.granted else objc.msg(objc.Object, objc.class("NSSet"), "set", .{}));
        if (p.fence_context) |c| {
            // Given only once this returns: fenced again right after.
            if (yes) objc.dispatchMain(c, fenceLater) else objc.release(c);
        }
        objc.release(p.granted);
        std.heap.c_allocator.destroy(p);
    }

    fn fenceLater(c: ?*anyopaque) callconv(.c) void {
        const context: objc.Object = @ptrCast(c.?);
        fence.fence(context);
        objc.release(context);
    }
};

fn emptyReply(h: H) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    value.Reply.take(h).ok(objc.msg(objc.Object, objc.class("NSSet"), "set", .{}));
}

fn sortedJoined(gpa: std.mem.Allocator, items: []const []const u8) ![]u8 {
    const copy = try gpa.dupe([]const u8, items);
    defer gpa.free(copy);
    std.mem.sort([]const u8, copy, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return std.mem.join(gpa, ", ", copy);
}

fn strings(gpa: std.mem.Allocator, set: objc.Object, comptime field: ?[:0]const u8) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    const arr = objc.msg(objc.Object, set, "allObjects", .{});
    for (0..objc.msg(objc.NSUInteger, arr, "count", .{})) |i| {
        var o: ?objc.Object = objc.msg(objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (field) |f| o = objc.msg(?objc.Object, o.?, f, .{});
        try out.append(gpa, objc.fromNSString(o orelse continue));
    }
    return out;
}

fn promptPermissions(d: objc.Object, _: Sel, _: C, permissions: objc.Object, _: ?objc.Object, context: C, h: H) callconv(.c) void {
    const self = owner(d) orelse return emptyReply(h);
    const pool = objc.Pool.push();
    defer pool.pop();
    var names = strings(self.gpa, permissions, null) catch return emptyReply(h);
    defer names.deinit(self.gpa);
    const detail = sortedJoined(self.gpa, names.items) catch return emptyReply(h);
    defer self.gpa.free(detail);
    const p = std.heap.c_allocator.create(Prompt) catch return emptyReply(h);
    p.* = .{ .reply = value.Reply.take(h), .granted = objc.retain(permissions) };
    asking.ask(self, "asks for more access", detail, context, p, Prompt.done);
}

/// Never asked: Chrome gives an extension the sites its manifest names,
/// the page it was clicked on, and what permissions.request got — so
/// neither does Kea. Noted for the bench.
fn promptURLs(d: objc.Object, _: Sel, _: C, urls: objc.Object, _: ?objc.Object, context: C, h: H) callconv(.c) void {
    defer emptyReply(h);
    const self = owner(d) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    var hosts = strings(self.gpa, urls, "host") catch return;
    defer hosts.deinit(self.gpa);
    // Swift's Set: each host once.
    var unique: std.ArrayList([]const u8) = .empty;
    defer unique.deinit(self.gpa);
    for (hosts.items) |host| {
        for (unique.items) |u| {
            if (std.mem.eql(u8, u, host)) break;
        } else unique.append(self.gpa, host) catch return;
    }
    const joined = sortedJoined(self.gpa, unique.items) catch return;
    defer self.gpa.free(joined);
    const found = objc.msg(objc.Object, context, "webExtension", .{});
    const name = if (objc.msg(?objc.Object, found, "displayName", .{})) |n| objc.fromNSString(n) else "?";
    const line = std.fmt.allocPrint(self.gpa, "(refused) {s} → {s}", .{ name, joined }) catch return;
    self.del.asked.append(self.gpa, line) catch self.gpa.free(line);
}

fn promptPatterns(d: objc.Object, _: Sel, _: C, patterns: objc.Object, _: ?objc.Object, context: C, h: H) callconv(.c) void {
    const self = owner(d) orelse return emptyReply(h);
    const pool = objc.Pool.push();
    defer pool.pop();
    // Extension pages and files are never given, so never asked about.
    const wanted = objc.msg(objc.Object, objc.class("NSMutableSet"), "set", .{});
    var all = false;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.gpa);
    const arr = objc.msg(objc.Object, patterns, "allObjects", .{});
    for (0..objc.msg(objc.NSUInteger, arr, "count", .{})) |i| {
        const p = objc.msg(objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (fence.withheld(p)) continue;
        objc.msg(void, wanted, "addObject:", .{p});
        if (objc.msg(objc.BOOL, p, "matchesAllHosts", .{}) or objc.msg(objc.BOOL, p, "matchesAllURLs", .{})) all = true;
        names.append(self.gpa, objc.fromNSString(objc.msg(objc.Object, p, "string", .{}))) catch return emptyReply(h);
    }
    if (names.items.len == 0) return emptyReply(h);
    const what = if (all) self.gpa.dupe(u8, "every website") catch return emptyReply(h) else sortedJoined(self.gpa, names.items) catch return emptyReply(h);
    defer self.gpa.free(what);
    const question = std.fmt.allocPrint(self.gpa, "wants to read and change {s}", .{what}) catch return emptyReply(h);
    defer self.gpa.free(question);
    const p = std.heap.c_allocator.create(Prompt) catch return emptyReply(h);
    p.* = .{ .reply = value.Reply.take(h), .granted = objc.retain(wanted), .fence_context = objc.retain(context) };
    asking.ask(self, question, "Until you remove the extension.", context, p, Prompt.done);
}

// MARK: the button

fn didUpdateAction(d: objc.Object, _: Sel, _: C, _: objc.Object, _: C) callconv(.c) void {
    const self = owner(d) orelse return;
    self.actions_changed += 1;
    for (self.kea.browsers.items) |b| b.redraw();
}

/// The popup page, in a popover of the browser's own (the UI wave's
/// ExtensionPopup): WebKit's view is only asked which page it would show.
fn presentPopup(d: objc.Object, _: Sel, _: C, action: objc.Object, context: C, h: H) callconv(.c) void {
    defer dialogs.call(h, .{@as(?objc.Object, null)});
    const self = owner(d) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    var url: ?[]u8 = null;
    if (objc.msg(?objc.Object, action, "popupWebView", .{})) |web| if (objc.msg(?objc.Object, web, "URL", .{})) |u| {
        url = self.gpa.dupe(u8, objc.fromNSString(objc.msg(objc.Object, u, "absoluteString", .{}))) catch null;
    };
    if (url == null) url = fence.popupURL(self.gpa, context);
    objc.msg(void, action, "closePopup", .{});
    const u = url orelse return;
    defer self.gpa.free(u);
    buttons.showPopup(self, u, context, idOf(context));
}

// MARK: messages

/// `runtime.sendNativeMessage`: to "kea" (or nobody named), the APIs this
/// app answers; to anything else, a Chrome native host on this Mac.
fn sendMessage(d: objc.Object, _: Sel, _: C, message: objc.Object, app: ?objc.Object, context: C, h: H) callconv(.c) void {
    const reply = value.Reply.take(h);
    const self = owner(d) orelse return reply.fail("Extensions are gone.");
    const pool = objc.Pool.push();
    defer pool.pop();
    const host = if (app) |a| objc.fromNSString(a) else null;
    if (host == null or std.mem.eql(u8, host.?, application)) return answer.answer(self, message, context, reply);
    // WebKit's nativeMessaging is granted to all, for the line to Kea; an
    // app on this Mac only to one whose manifest asks for it, as in Chrome.
    if (!asksForNative(self, context)) return reply.fail(native.permission_refused);
    native.send(message, host.?, idOf(context), reply);
}

fn connect(d: objc.Object, _: Sel, _: C, port: objc.Object, context: C, h: H) callconv(.c) void {
    const done = value.Done.take(h);
    const self = owner(d) orelse return done.ok();
    const pool = objc.Pool.push();
    defer pool.pop();
    const app = if (objc.msg(?objc.Object, port, "applicationIdentifier", .{})) |a| objc.fromNSString(a) else "";
    if (std.mem.eql(u8, app, socket.name)) {
        socket.connect(port, idOf(context));
        return done.ok();
    }
    // The port a worker's shim opens only to find what ports share.
    if (std.mem.eql(u8, app, application)) return done.ok();
    if (!asksForNative(self, context)) return done.fail(native.permission_refused);
    native.connect(port, idOf(context)) catch |e| return done.fail(native.refused(e));
    done.ok();
}

fn asksForNative(self: *Extensions, context: C) bool {
    const folder = self.folderFor(idOf(context)) catch return false;
    defer self.gpa.free(folder);
    return fence.asksForNative(self.gpa, context, folder);
}
