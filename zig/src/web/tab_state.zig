//! What a tab keeps between pages (Tab.swift 397-425, 975-1340): sleeping
//! and waking with a picture over the stage, the load that checks it took,
//! coming back from a crash, per-site zoom and the reading meter.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const tab_mod = @import("tab.zig");
const Tab = tab_mod.Tab;
const Parts = @import("../data/url.zig").Parts;
const cg = @import("../sys/cg.zig");
const dispatch = @import("../sys/dispatch.zig");
// MARK: sleeping and waking

/// Sent somewhere new: nothing of where it was before to bring back.
pub fn forgetSleep(t: *Tab) void {
    if (t.memory) |m| objc.release(m);
    t.memory = null;
    t.own(&t.picture, null);
    t.own(&t.cover, null);
}

/// `wake()`: opened for the first time, or back from ⌘W or sleep.
/// Whether there was anything to wake.
pub fn wake(t: *Tab) bool {
    const target = t.pending orelse return false;
    t.pending = null;
    defer t.gpa.free(target);
    t.setFailure(null);
    t.reading = 0;
    t.reader = false;
    t.typing = false;
    const memory = t.memory;
    t.memory = null;
    defer if (memory) |m| objc.release(m);
    if (t.picture) |p| {
        t.own(&t.cover, null);
        t.cover = p;
        t.picture = null;
        t.cover_serial +%= 1;
        // Whatever happens to the page, the picture doesn't outstay it.
        t.after(4, uncoverFired, t.cover_serial);
    }
    t.own(&t.picture, null);
    t.build();
    loadAndVerify(t, target, memory, 0);
    t.changed(.state);
    return true;
}

/// `rest()`: ⌘W on a pin — the address kept, the page let go.
pub fn rest(t: *Tab) void {
    const address = t.address orelse return;
    t.own(&t.pending, address);
    forgetSleep(t);
    t.reading = 0;
    t.stale = false;
    t.pull = null;
    t.discard();
}

/// `sleep(picture:)`: its history and a picture stay, the view goes.
/// `picture` (JPEG) is the tab's from here.
pub fn sleep(t: *Tab, picture: ?[]u8) void {
    const address = t.address orelse {
        if (picture) |p| t.gpa.free(p);
        return;
    };
    const wv = t.web orelse {
        if (picture) |p| t.gpa.free(p);
        return;
    };
    if (t.memory) |m| objc.release(m);
    t.memory = if (objc.msg(?objc.Object, wv, "interactionState", .{})) |s| objc.retain(s) else null;
    t.own(&t.picture, null);
    t.picture = picture;
    t.own(&t.pending, address);
    t.stale = false;
    t.pull = null;
    t.discard();
}

/// `rehome(in:)`: WebKit binds the store when the view is made, so the
/// view is built again with the new space's.
pub fn rehome(t: *Tab, data_store: ?objc.Object) void {
    if (t.shy or t.data_store == data_store) return;
    if (t.web) |wv| {
        if (t.memory) |m| objc.release(m);
        t.memory = if (objc.msg(objc.BOOL, wv, "isLoading", .{})) null else if (objc.msg(?objc.Object, wv, "interactionState", .{})) |s| objc.retain(s) else null;
        if (t.pending == null) t.own(&t.pending, t.address orelse tab_mod.currentUrl(wv));
        t.own(&t.picture, null);
        t.own(&t.cover, null);
    }
    if (t.built) t.discard();
    t.data_store = data_store;
    if (t.configuration) |c| objc.release(c);
    t.configuration = null;
}

fn uncoverFired(t: *Tab, serial: usize) void {
    if (t.cover == null or t.cover_serial != serial) return;
    t.own(&t.cover, null);
    t.changed(.state);
}

/// `uncover(after:)`: the picture comes off once there is something
/// better under it.
pub fn uncover(t: *Tab, delay: f64) void {
    if (t.cover == null) return;
    if (delay <= 0) {
        t.own(&t.cover, null);
        return t.changed(.state);
    }
    t.after(delay, uncoverFired, t.cover_serial);
}

// MARK: a load that is checked

const Pending = struct { url: []u8, memory: ?objc.Object, tries: u8 };

/// Pending loads live on `c_allocator`: the timer may outlive the tab.
fn dropPending(arg: usize) void {
    const p: *Pending = @ptrFromInt(arg);
    if (p.memory) |m| objc.release(m);
    std.heap.c_allocator.free(p.url);
    std.heap.c_allocator.destroy(p);
}

fn retryLoad(t: *Tab, arg: usize) void {
    const p: *Pending = @ptrFromInt(arg);
    defer dropPending(arg);
    loadAndVerify(t, p.url, p.memory, p.tries);
}

/// `loadAndVerify`: waits (≤ 50 × 20 ms) for the stage to take the view,
/// loads, then asks again 1.5 s later in case WebKit dropped it.
pub fn loadAndVerify(t: *Tab, target: []const u8, memory: ?objc.Object, tries: u8) void {
    const wv = t.web orelse return;
    if (objc.msg(?objc.Object, wv, "window", .{}) == null and tries < 50) {
        const ca = std.heap.c_allocator;
        const p = ca.create(Pending) catch return;
        p.* = .{ .url = ca.dupe(u8, target) catch return ca.destroy(p), .memory = if (memory) |m| objc.retain(m) else null, .tries = tries + 1 };
        return t.afterOwned(0.02, retryLoad, @intFromPtr(p), dropPending);
    }
    if (memory != null and !std.mem.startsWith(u8, target, "file:")) {
        objc.msg(void, wv, "setInteractionState:", .{memory.?});
    } else tab_mod.open(wv, target);
    t.after(1.5, verify, 0);
}

fn verify(t: *Tab, _: usize) void {
    const wv = t.web orelse return;
    const address = t.address orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (tab_mod.currentUrl(wv)) |u| if (std.mem.eql(u8, u, "about:blank")) return tab_mod.open(wv, address);
    t.evaluate("document.readyState", .page, reopenIfDead, 0);
}

/// `WKErrorWebContentProcessTerminated` (2) in `WKErrorDomain`.
fn processGone(err: ?objc.Object) bool {
    const e = err orelse return false;
    return objc.msg(objc.NSInteger, e, "code", .{}) == 2 and
        std.mem.eql(u8, objc.fromNSString(objc.msg(?objc.Object, e, "domain", .{})), "WKErrorDomain");
}

fn reopenIfDead(t: *Tab, _: ?objc.Object, err: ?objc.Object, _: usize) void {
    if (!processGone(err)) return;
    if (t.web) |wv| if (t.address) |a| tab_mod.open(wv, a);
}

fn recoverIfDead(t: *Tab, _: ?objc.Object, err: ?objc.Object, _: usize) void {
    if (processGone(err)) recoverFromCrash(t);
}

/// `recoverFromCrash`: the address asked for again, checked.
pub fn recoverFromCrash(t: *Tab) void {
    const address = t.address orelse return;
    t.setFailure(null);
    const copy = t.gpa.dupe(u8, address) catch return;
    defer t.gpa.free(copy);
    loadAndVerify(t, copy, null, 0);
}

/// `revive()`: coming back to a tab whose page may have gone white.
pub fn revive(t: *Tab) void {
    if (t.stale) {
        t.stale = false;
        return recoverFromCrash(t);
    }
    if (t.isBlank() or t.pending != null or t.loading or t.failure != null) return;
    if (t.hollow()) {
        if (t.web) |wv| tab_mod.open(wv, t.address.?);
        return;
    }
    t.evaluate("document.readyState", .page, recoverIfDead, 0);
}

// MARK: zoom

/// `Tab.defaultZoom`: Settings › General › Page zoom.
pub fn defaultZoom(t: *const Tab) f64 {
    return t.kea.store.double("pageZoom") orelse 1;
}

fn zoomKey(buf: []u8, t: *const Tab) ?[]const u8 {
    const p = Parts.parse(t.url()) orelse return null;
    const host = p.hostName() orelse return null;
    if (host.len == 0) return null;
    return std.fmt.bufPrint(buf, "zoom.{s}", .{host}) catch null;
}

/// `rememberZoom`: kept for the site; at the usual size, nothing kept.
pub fn rememberZoom(t: *Tab) void {
    if (t.shy) return;
    var buf: [300]u8 = undefined;
    const key = zoomKey(&buf, t) orelse return;
    if (@abs(t.zoom - defaultZoom(t)) < 0.01) t.kea.store.remove(key) else t.kea.store.setDouble(key, t.zoom);
}

/// `applyRememberedZoom`: on commit, before a frame at the wrong size.
pub fn applyRememberedZoom(t: *Tab) void {
    const wv = t.web orelse return;
    var buf: [300]u8 = undefined;
    const key = zoomKey(&buf, t) orelse return;
    const kept = t.kea.store.double(key) orelse defaultZoom(t);
    if (@abs(kept - objc.msg(f64, wv, "pageZoom", .{})) <= 0.004) return;
    objc.msg(void, wv, "setPageZoom:", .{kept});
    t.zoom = kept;
}

/// `magnify(to:)`: between two fifths and three times. A tab with no page
/// built yet (or headless) keeps it for the site, as one built would.
pub fn magnify(t: *Tab, value: f64) void {
    const wanted = @min(3, @max(0.4, value));
    if (@abs(wanted - pageZoom(t)) <= 0.004) return;
    if (t.web) |wv| objc.msg(void, wv, "setPageZoom:", .{wanted});
    t.zoom = wanted;
    rememberZoom(t);
    if (t.browser) |b| b.zoomed(wanted);
}

fn pageZoom(t: *const Tab) f64 {
    const wv = t.web orelse return t.zoom;
    return objc.msg(f64, wv, "pageZoom", .{});
}

/// ⌘+ and ⌘- (`magnify(by:)`).
pub fn magnifyBy(t: *Tab, factor: f64) void {
    magnify(t, pageZoom(t) * factor);
}

/// ⌘0: both kinds of zoom back to where every site starts.
pub fn resetZoom(t: *Tab) void {
    magnify(t, defaultZoom(t));
    const wv = t.web orelse return;
    if (objc.msg(f64, wv, "magnification", .{}) == 1) return;
    objc.msg(void, wv, "setMagnification:", .{@as(f64, 1)});
    if (t.browser) |b| b.zoomed(1);
}

// MARK: reading, pictures, what was typed

fn isVisible(t: *const Tab) bool {
    const b = t.browser orelse return false;
    const ids = b.visibleTabIDs();
    return t.id != 0 and (ids[0] == t.id or ids[1] == t.id);
}

fn fireReading(t: *Tab, _: usize) void {
    t.reading_pending = false;
    t.reading_drawn_at = ui.clock.now();
    if (t.browser) |b| if (b.prefs.shows_reading and isVisible(t)) t.changed(.state);
}

/// `scrolled(to:of:)`: throttled to >= 0.5 % changes and at most 10 Hz while `shows_reading` is on.
pub fn scrolled(t: *Tab, y: f64, ceiling: f64) void {
    const raw: f32 = if (ceiling > 0) @floatCast(@min(1, @max(0, y / ceiling))) else 0;
    const shows = if (t.browser) |b| b.prefs.shows_reading else false;
    const fraction: f32 = if (shows) @round(raw * 1000) / 1000 else @round(raw * 100) / 100;
    const prev_reading = t.reading;
    if (fraction == prev_reading) return;
    if (shows and @abs(fraction - prev_reading) < 0.005 and fraction != 0 and fraction != 1) return;
    t.reading = fraction;
    if (!shows or !isVisible(t)) return;
    const now = ui.clock.now();
    if (now - t.reading_drawn_at >= 0.1) {
        t.reading_drawn_at = now;
        t.changed(.state);
    } else if (!t.reading_pending) {
        t.reading_pending = true;
        t.after(0.1, fireReading, 0);
    }
}

pub const Done = *const fn (t: *Tab, value: bool, picture: ?[]u8, arg: usize) void;

const Snap = struct {
    serial: u64,
    done: Done,
    arg: usize,
    cgimage: ?cg.Image = null,
    bytes: ?[]u8 = null,
};
const SnapBlock = objc.Block(Snap, &.{ ?objc.Object, ?objc.Object });

extern "c" const kCGImageDestinationLossyCompressionQuality: cg.CFStringRef;
extern "c" fn CGImageRetain(image: cg.Image) cg.Image;

/// The page as it looks now, JPEG at quality 0.55 (`Tab.jpeg`).
fn jpeg(gpa: std.mem.Allocator, cgimage: cg.Image) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = cg.CFDataCreateMutable(null, 0) orelse return null;
    defer cg.CFRelease(data);
    const dest = cg.CGImageDestinationCreateWithData(data, @ptrCast(objc.nsString("public.jpeg")), 1, null) orelse return null;
    defer cg.CFRelease(dest);
    const quality = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithDouble:", .{@as(f64, 0.55)});
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ quality, @as(objc.Object, @ptrCast(@constCast(kCGImageDestinationLossyCompressionQuality))) });
    cg.CGImageDestinationAddImage(dest, cgimage, props);
    if (!cg.CGImageDestinationFinalize(dest)) return null;
    return gpa.dupe(u8, cg.CFDataGetBytePtr(data)[0..@intCast(cg.CFDataGetLength(data))]) catch null;
}

fn encodeBg(p: ?*anyopaque) callconv(.c) void {
    const s: *Snap = @ptrCast(@alignCast(p.?));
    if (s.cgimage) |img| {
        defer cg.CGImageRelease(img);
        s.bytes = jpeg(std.heap.c_allocator, img);
    }
    objc.dispatchMain(s, encodeFg);
}

fn encodeFg(p: ?*anyopaque) callconv(.c) void {
    const s: *Snap = @ptrCast(@alignCast(p.?));
    defer {
        if (s.bytes) |b| std.heap.c_allocator.free(b);
        std.heap.c_allocator.destroy(s);
    }
    const t = Tab.alive(s.serial) orelse return;
    const picture = if (s.bytes) |b| t.gpa.dupe(u8, b) catch null else null;
    s.done(t, picture != null, picture, s.arg);
}

fn snapped(s: *Snap, image: ?objc.Object, _: ?objc.Object) void {
    if (Tab.alive(s.serial) == null) return std.heap.c_allocator.destroy(s);
    if (image) |img| {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (objc.msg(?objc.Object, img, "CGImageForProposedRect:context:hints:", .{ @as(?*anyopaque, null), @as(?objc.Object, null), @as(?objc.Object, null) })) |raw| {
            s.cgimage = CGImageRetain(@ptrCast(raw));
            return dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(0x11, 0), s, encodeBg);
        }
    }
    defer std.heap.c_allocator.destroy(s);
    if (Tab.alive(s.serial)) |t| s.done(t, false, null, s.arg);
}
/// `snapshot`: drawn by the page's own process, so a view off screen can
/// still be pictured; null when there is nothing to draw.
pub fn snapshot(t: *Tab, done: Done, arg: usize) void {
    const wv = t.web orelse return done(t, false, null, arg);
    const s = std.heap.c_allocator.create(Snap) catch return done(t, false, null, arg);
    s.* = .{ .serial = t.serial, .done = done, .arg = arg };
    var block = SnapBlock.init(s, snapped);
    objc.msg(void, wv, "takeSnapshotWithConfiguration:completionHandler:", .{ @as(?objc.Object, null), @as(*anyopaque, @ptrCast(&block)) });
}

const Typed = struct { done: Done, arg: usize };

fn answeredUnsaved(t: *Tab, value: ?objc.Object, _: ?objc.Object, arg: usize) void {
    const ty: *Typed = @ptrFromInt(arg);
    defer std.heap.c_allocator.destroy(ty);
    const yes = if (value) |v| objc.msg(objc.BOOL, v, "respondsToSelector:", .{objc.sel("boolValue")}) and objc.msg(objc.BOOL, v, "boolValue", .{}) else false;
    ty.done(t, yes, null, ty.arg);
}

/// `unsaved`: whether the page holds something typed and not sent. A page
/// that can't answer holds nothing.
pub fn unsaved(t: *Tab, done: Done, arg: usize) void {
    if (t.web == null) return done(t, false, null, arg);
    const ty = std.heap.c_allocator.create(Typed) catch return done(t, false, null, arg);
    ty.* = .{ .done = done, .arg = arg };
    t.evaluate("!!(window.__keaForms && window.__keaForms.unsaved && window.__keaForms.unsaved())", .kea, answeredUnsaved, @intFromPtr(ty));
}
