//! The extension's own pages and worker (ExtensionShims.swift 3607-3626,
//! 3661-3687, 3743-3793, 4104-4114): capture, offscreen, runtime.getContexts,
//! background.*, debug.error, clients.pages, identity.*.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");
const val = @import("../value.zig");
const ext = @import("../ext.zig");
const offscreen = @import("../offscreen.zig");
const capture = @import("../capture.zig");
const auth = @import("../auth.zig");
const Extensions = @import("../controller.zig").Extensions;

const Value = ans.Value;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    const first = c.first();
    if (eql(api, "capture.grant")) {
        capture.shared().grant(c.owner, c.context, c.later());
        return .later;
    }
    if (eql(api, "offscreen.createDocument")) {
        const path = ans.str(ans.field(first, "url")) orelse return c.fail("No page for the offscreen document", .{});
        const reasons = (try ans.allStrings(c.a, ans.field(first, "reasons"))) orelse &.{};
        offscreen.create(c.owner, path, reasons, c.context, c.later());
        return .later;
    }
    if (eql(api, "offscreen.closeDocument")) {
        offscreen.close(c.id);
        return ans.none;
    }
    if (eql(api, "offscreen.hasDocument")) return .{ .value = .{ .bool = offscreen.hasDocument(c.id) } };
    if (eql(api, "offscreen.sendMessage")) {
        const token = ans.str(first);
        if (c.args.len != 3 or token == null or c.args[2] != .object) return try c.give(.{ .handled = false });
        const pool = objc.Pool.push();
        defer pool.pop();
        const sender = val.toObject(c.args[2]) orelse return try c.give(.{ .handled = false });
        offscreen.send(c.owner, val.toObject(c.args[1]), sender, token.?, c.id, c.later());
        return .later;
    }
    if (eql(api, "runtime.getContexts")) return .{ .value = try contexts(c, first) };
    if (eql(api, "background.wake")) return wake(c);
    if (eql(api, "background.loadedBefore")) return .{ .value = .{ .bool = c.owner.loadedBefore(c.id) } };
    if (eql(api, "background.revive")) {
        c.owner.revive(c.id, "its worker stopped answering");
        return ans.none;
    }
    if (eql(api, "debug.error")) {
        c.owner.noteError(ans.str(first) orelse "?", c.id);
        return ans.none;
    }
    if (eql(api, "clients.pages")) return .{ .value = try pages(c) };
    if (eql(api, "identity.launchWebAuthFlow")) {
        const url = ans.str(ans.field(first, "url")) orelse return c.fail("No authorization url", .{});
        const pool = objc.Pool.push();
        defer pool.pop();
        // `URL(string:)`: nil for what isn't an address.
        if (objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) == null)
            return c.fail("No authorization url", .{});
        auth.run(url, c.id, c.browser, c.later());
        return .later;
    }
    if (eql(api, "identity.getProfileUserInfo")) return try c.give(.{ .email = "", .id = "" });
    if (eql(api, "identity.removeCachedAuthToken") or eql(api, "identity.clearAllCachedAuthTokens")) return ans.none;
    if (eql(api, "identity.getAuthToken"))
        return c.fail("getAuthToken needs a Google account signed into Chrome; this extension would need launchWebAuthFlow instead", .{});
    return null;
}

/// `absoluteString`, copied onto `a`.
fn text(a: std.mem.Allocator, url: objc.Object) ![]const u8 {
    return a.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{})));
}

// MARK: runtime.getContexts

const Found = struct {
    c: *ans.Call,
    types: ?[]const []const u8,
    urls: ?[]const []const u8,
    out: std.ArrayList(Value) = .empty,

    fn add(f: *Found, kind: []const u8, url: ?objc.Object) !void {
        const a = f.c.a;
        if (f.types) |t| if (!ans.contains(t, kind)) return;
        const address = if (url) |u| try text(a, u) else "";
        if (f.urls) |u| if (!ans.contains(u, address)) return;
        const origin = if (url) |u| try std.fmt.allocPrint(a, "{s}://{s}", .{
            objc.fromNSString(objc.msg(?objc.Object, u, "scheme", .{})),
            objc.fromNSString(objc.msg(?objc.Object, u, "host", .{})),
        }) else "";
        try f.out.append(a, try f.c.of(.{
            .contextType = kind,
            .contextId = try std.fmt.allocPrint(a, "{s}-{s}", .{ f.c.id, kind }),
            .tabId = -1,
            .windowId = -1,
            .frameId = @as(i64, if (eql(kind, "BACKGROUND")) -1 else 0),
            .documentUrl = address,
            .documentOrigin = origin,
            .incognito = false,
        }));
    }
};

fn contexts(c: *ans.Call, first: ?Value) ans.Error!Value {
    const filter: Value = if (ans.isObject(first)) first.? else .{ .object = .empty };
    var f: Found = .{
        .c = c,
        .types = try ans.allStrings(c.a, ans.field(filter, "contextTypes")),
        .urls = try ans.allStrings(c.a, ans.field(filter, "documentUrls")),
    };
    const pool = objc.Pool.push();
    defer pool.pop();
    if (objc.msg(objc.BOOL, c.webExtension(), "hasBackgroundContent", .{})) {
        const bg = ans.field(c.manifest(), "background");
        const script = ans.str(ans.field(bg, "service_worker")) orelse ans.str(ans.field(bg, "page"));
        const url: ?objc.Object = if (script) |s|
            objc.msg(objc.Object, objc.msg(objc.Object, c.context, "baseURL", .{}), "URLByAppendingPathComponent:", .{objc.nsString(s)})
        else
            null;
        try f.add("BACKGROUND", url);
    }
    if (c.owner.answer.popup_client) |hook| if (hook(c.owner, c.id)) |p| {
        const u = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(p.url)});
        try f.add("POPUP", u);
    };
    const docs = offscreen.contexts(c.id, val.toObject(filter));
    if (val.toJson(c.a, docs)) |parsed| for (ans.list(parsed.value) orelse &.{}) |x| try f.out.append(c.a, x);
    return .{ .array = .fromOwnedSlice(c.a, f.out.items) };
}

// MARK: clients.pages

fn pages(c: *ans.Call) ans.Error!Value {
    const Page = struct { id: []const u8, url: []const u8, visible: bool, focused: bool };
    var out: std.ArrayList(Page) = .empty;
    const a = c.a;
    if (c.owner.answer.popup_client) |hook| if (hook(c.owner, c.id)) |p|
        try out.append(a, .{ .id = "popup", .url = try a.dupe(u8, p.url), .visible = p.visible, .focused = p.focused });
    const pool = objc.Pool.push();
    defer pool.pop();
    for (c.browser.tabs.items) |tab| {
        const web = tab.web orelse continue;
        const u = objc.msg(?objc.Object, web, "URL", .{}) orelse continue;
        const address = try text(a, u);
        const host = ext.idOf(address) orelse continue;
        if (!eql(host, c.id)) continue;
        const window = objc.msg(?objc.Object, web, "window", .{});
        const visible = if (window) |w| (objc.msg(objc.NSUInteger, w, "occlusionState", .{}) & 2) != 0 else false; // NSWindowOcclusionStateVisible
        const shown = tab.id == c.browser.active_id and visible;
        const key = if (window) |w| objc.msg(objc.BOOL, w, "isKeyWindow", .{}) else false;
        try out.append(a, .{ .id = try std.fmt.allocPrint(a, "{d}", .{tab.id}), .url = address, .visible = shown, .focused = shown and key });
    }
    if (offscreen.url(c.id)) |u| try out.append(a, .{ .id = "offscreen", .url = try text(a, u), .visible = false, .focused = false });
    return c.of(out.items);
}

// MARK: background.wake

/// One `background.wake`: up to three starts, each failed by WebKit's error
/// or eight seconds of silence, 400 ms apart; then the extension afresh.
const Wake = struct {
    owner: *Extensions,
    context: objc.Object, // retained
    pending: *ans.Pending,
    id: []const u8, // on pending's arena
    attempt: u8 = 0,

    fn start(w: *Wake) void {
        const t = w.owner.gpa.create(Try) catch return w.done(false);
        t.* = .{ .wake = w, .gpa = w.owner.gpa };
        const pool = objc.Pool.push();
        defer pool.pop();
        var block = objc.Block(Try, &.{?objc.Object}).init(t, Try.loaded);
        objc.msg(void, w.context, "loadBackgroundContentWithCompletionHandler:", .{&block});
        objc.dispatchAfter(8 * std.time.ns_per_s, t, Try.timedOut);
    }

    fn failed(w: *Wake) void {
        w.attempt += 1;
        if (w.attempt >= 3) return w.done(true);
        objc.dispatchAfter(400 * std.time.ns_per_ms, w, again);
    }

    fn again(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Wake = @ptrCast(@alignCast(ctx.?));
        w.start();
    }

    fn done(w: *Wake, revive: bool) void {
        if (revive) w.owner.revive(w.id, "its worker wouldn't start");
        objc.release(w.context);
        const gpa = w.owner.gpa;
        w.pending.value(.null);
        gpa.destroy(w);
    }
};

/// One start: WebKit's callback and the timer race; the first one counts,
/// the last one out frees it.
// ponytail: a WebKit callback that never comes leaves this Try (a few bytes) behind.
const Try = struct {
    wake: *Wake,
    gpa: std.mem.Allocator,
    finished: bool = false,
    left: u8 = 2,

    fn settle(t: *Try, ok: bool) void {
        const w = t.wake;
        const first = !t.finished;
        t.finished = true;
        t.left -= 1;
        if (t.left == 0) t.gpa.destroy(t);
        if (!first) return;
        if (ok) w.done(false) else w.failed();
    }

    fn loaded(t: *Try, err: ?objc.Object) void {
        t.settle(err == null);
    }

    fn timedOut(ctx: ?*anyopaque) callconv(.c) void {
        const t: *Try = @ptrCast(@alignCast(ctx.?));
        t.settle(false);
    }
};

fn wake(c: *ans.Call) ans.Error!?ans.Out {
    if (!objc.msg(objc.BOOL, c.webExtension(), "hasBackgroundContent", .{})) return ans.none;
    const w = try c.owner.gpa.create(Wake);
    w.* = .{ .owner = c.owner, .context = objc.retain(c.context), .pending = c.pending, .id = c.id };
    w.start();
    return .later;
}
