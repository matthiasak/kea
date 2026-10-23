//! `KeaObserver`: KVO on a tab's page (Tab.swift 654-692 `watch`,
//! `AudioWatch` 1391-1423, the capture states RecordingIndicator reads).
//! Removed before the view is let go (`discard`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Tab = @import("tab.zig").Tab;
const currentUrl = @import("tab.zig").currentUrl;
const Parts = @import("../data/url.zig").Parts;

const keys = [_][:0]const u8{ "title", "URL", "loading", "canGoBack", "canGoForward" };
const capture_keys = [_][:0]const u8{ "cameraCaptureState", "microphoneCaptureState" };
/// `AudioWatch.key`, outside the public framework: asked for first.
const audio = "_isPlayingAudio";

fn class() objc.Class {
    return objc.defineClass(.{
        .name = "KeaObserver",
        .methods = &.{
            .{ .name = "observeValueForKeyPath:ofObject:change:context:", .imp = &observe, .types = "v@:@@@^v" },
        },
    });
}

fn hearsAudio(wv: objc.Object) bool {
    return objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel(audio)});
}

/// Starts watching `wv` for `t`; the observer, retained.
pub fn watch(t: *Tab, wv: objc.Object) objc.Object {
    const o = objc.msg(objc.Object, class(), "new", .{});
    objc.setZig(o, t);
    for (keys) |k| objc.msg(void, wv, "addObserver:forKeyPath:options:context:", .{ o, objc.nsString(k), @as(objc.NSUInteger, 1), @as(?*anyopaque, null) });
    t.observes_capture = t.kea.ext == null;
    if (t.observes_capture) {
        for (capture_keys) |k| objc.msg(void, wv, "addObserver:forKeyPath:options:context:", .{ o, objc.nsString(k), @as(objc.NSUInteger, 1), @as(?*anyopaque, null) });
    }
    if (hearsAudio(wv)) objc.msg(void, wv, "addObserver:forKeyPath:options:context:", .{ o, objc.nsString(audio), @as(objc.NSUInteger, 1), @as(?*anyopaque, null) });
    return o;
}

pub fn stop(o: objc.Object, web: ?objc.Object, watched_capture: bool) void {
    objc.setZig(o, null);
    if (web) |wv| {
        const pool = objc.Pool.push();
        defer pool.pop();
        for (keys) |k| objc.msg(void, wv, "removeObserver:forKeyPath:", .{ o, objc.nsString(k) });
        if (watched_capture) {
            for (capture_keys) |k| objc.msg(void, wv, "removeObserver:forKeyPath:", .{ o, objc.nsString(k) });
        }
        if (hearsAudio(wv)) objc.msg(void, wv, "removeObserver:forKeyPath:", .{ o, objc.nsString(audio) });
    }
    objc.release(o);
}

fn flag(wv: objc.Object, sel: [:0]const u8) bool {
    return objc.msg(objc.BOOL, wv, sel, .{});
}

fn observe(self: objc.Object, _: objc.SEL, path: ?objc.Object, object: ?objc.Object, change: ?objc.Object, _: ?*anyopaque) callconv(.c) void {
    const t = objc.getZig(Tab, self) orelse return;
    const wv = t.web orelse return;
    if (object != wv) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const key = objc.fromNSString(path);
    if (std.mem.eql(u8, key, "title")) {
        const next = objc.fromNSString(objc.msg(?objc.Object, wv, "title", .{}));
        if (std.mem.eql(u8, t.page_title, next)) return;
        t.setTitle(next);
        return t.changed(.title);
    }
    if (std.mem.eql(u8, key, "URL")) return moved(t, wv);
    if (std.mem.eql(u8, key, "loading")) {
        const next = flag(wv, "isLoading");
        if (t.loading == next) return;
        t.loading = next;
    } else if (std.mem.eql(u8, key, "canGoBack")) {
        const next = flag(wv, "canGoBack");
        if (t.can_go_back == next) return;
        t.can_go_back = next;
    } else if (std.mem.eql(u8, key, "canGoForward")) {
        const next = flag(wv, "canGoForward");
        if (t.can_go_forward == next) return;
        t.can_go_forward = next;
    } else if (std.mem.eql(u8, key, audio)) {
        const new = if (change) |c| objc.msg(?objc.Object, c, "objectForKey:", .{objc.nsString("new")}) else null;
        const next = if (new) |n| objc.msg(objc.BOOL, n, "respondsToSelector:", .{objc.sel("boolValue")}) and objc.msg(objc.BOOL, n, "boolValue", .{}) else false;
        if (t.noisy == next) return;
        t.noisy = next;
    }
    // The capture states: the row's recording mark is an extension's
    // (ext/capture_watch.zig `marks`, RecordingIndicator.update); a page's
    // own call keeps it awake (sleep.zig) and only redraws here.
    t.changed(.state);
}

/// The URL observer: about:blank is never a destination; within the same
/// origin the page on screen is the one at the new address.
fn moved(t: *Tab, wv: objc.Object) void {
    const fresh = currentUrl(wv) orelse return;
    if (fresh.len == 0 or std.mem.eql(u8, fresh, "about:blank")) return;
    // The page under a held address coming back is no move (ext/auth.zig).
    if (@import("../ext/auth.zig").heldStays(t, fresh)) return;
    var committed_changed = false;
    if (t.committed) |now| if (sameOrigin(now, fresh) and !std.mem.eql(u8, now, fresh)) {
        t.own(&t.committed, fresh);
        committed_changed = true;
    };
    if (!committed_changed and t.address != null and std.mem.eql(u8, t.address.?, fresh)) return;
    t.own(&t.address, fresh);
    t.changed(.address);
}

fn sameOrigin(a: []const u8, b: []const u8) bool {
    const pa = Parts.parse(a) orelse return false;
    const pb = Parts.parse(b) orelse return false;
    return std.ascii.eqlIgnoreCase(pa.scheme orelse "", pb.scheme orelse "") and
        std.ascii.eqlIgnoreCase(pa.hostName() orelse "", pb.hostName() orelse "") and
        std.mem.eql(u8, pa.port orelse "", pb.port orelse "");
}
