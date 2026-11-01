//! Tabs you aren't using, put to sleep (Sleep.swift): a tab left alone for
//! ten minutes (`sleep.after` seconds, for tests) gives its page back and
//! keeps its history and a picture (`tab_state.sleep`). Memory pressure
//! (a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source, `sys/dispatch.zig`)
//! shrinks the wait to five minutes, or to nothing when critical.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("tab.zig").Tab;
const state = @import("tab_state.zig");
const json = @import("../data/json.zig");
const dispatch = @import("../sys/dispatch.zig");

const Store = @import("../data/store.zig").Store;
const Parts = @import("../data/url.zig").Parts;

pub const awake_prefix = "awake.";

pub fn isKeptAwake(store: *const Store, host: []const u8) bool {
    if (host.len == 0) return false;
    var buf: [300]u8 = undefined;
    return store.bool(std.fmt.bufPrint(&buf, awake_prefix ++ "{s}", .{host}) catch return false) orelse false;
}

pub fn setKeptAwake(store: *const Store, keep: bool, host: []const u8) void {
    if (host.len == 0) return;
    var buf: [300]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, awake_prefix ++ "{s}", .{host}) catch return;
    if (keep) store.setBool(key, true) else store.remove(key);
}
/// What each window keeps: its timer, its memory-pressure source, until
/// when a critical warning lasts, and the sweep under way.
const Watch = struct {
    timer: objc.Object,
    pressure: ?*anyopaque,
    critical_until: f64 = 0,
    sweep: std.ArrayList(u64) = .empty,
    step: u32 = 0,
};

var watches: std.AutoHashMapUnmanaged(*Browser, Watch) = .empty;
const a = std.heap.c_allocator;

/// `Browser.sleepAfter`: ten minutes, or `sleep.after` in seconds.
pub fn sleepAfter(b: *const Browser) f64 {
    const set = b.store.double("sleep.after") orelse 0;
    return if (set > 0) set else @max(60, b.prefs.sleep_minutes * 60);
}

const pressure_warning = dispatch.pressure_warning;
const pressure_critical = dispatch.pressure_critical;

fn timerClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaSleepTimer",
        .methods = &.{.{ .name = "fire:", .imp = &fire, .types = "v@:@" }},
    });
}

fn fire(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const b = objc.getZig(Browser, self) orelse return;
    sleepIdle(b, null);
}

/// `watchForSleep`: started once per window.
pub fn watch(b: *Browser) void {
    if (b.kea.opts.headless or watches.contains(b)) return;
    const every = @min(60, @max(5, sleepAfter(b) / 4));
    const target = objc.msg(objc.Object, timerClass(), "new", .{});
    objc.setZig(target, b);
    defer objc.release(target);
    const timer = objc.msg(objc.Object, objc.class("NSTimer"), "timerWithTimeInterval:target:selector:userInfo:repeats:", .{
        every, target, objc.sel("fire:"), @as(?objc.Object, null), objc.YES,
    });
    objc.msg(void, timer, "setTolerance:", .{every / 4});
    const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "mainRunLoop", .{});
    objc.msg(void, loop, "addTimer:forMode:", .{ timer, objc.nsString("kCFRunLoopCommonModes") });
    const source = dispatch.dispatch_source_create(&dispatch._dispatch_source_type_memorypressure, 0, pressure_warning | pressure_critical, objc.mainQueue());
    if (source) |s| {
        dispatch.dispatch_set_context(s, b);
        dispatch.dispatch_source_set_event_handler_f(s, pressed);
        dispatch.dispatch_resume(s);
    }
    watches.put(a, b, .{ .timer = objc.retain(timer), .pressure = source }) catch {};
}

/// The window is going: its timer and source with it.
pub fn unwatch(b: *Browser) void {
    var w = (watches.fetchRemove(b) orelse return).value;
    objc.msg(void, w.timer, "invalidate", .{});
    objc.release(w.timer);
    if (w.pressure) |s| {
        dispatch.dispatch_source_cancel(s);
        dispatch.dispatch_release(s);
    }
    w.sweep.deinit(a);
}

fn pressed(ctx: ?*anyopaque) callconv(.c) void {
    const b: *Browser = @ptrCast(@alignCast(ctx orelse return));
    const w = watches.getPtr(b) orelse return;
    const event = if (w.pressure) |s| dispatch.dispatch_source_get_data(s) else 0;
    const critical = event & pressure_critical != 0;
    @import("../chrome/tab_switcher.zig").reset(b);
    if (critical) {
        w.critical_until = json.now() + 60;
        b.kea.favicons.trimMemory(b.kea);
        trimPictures(b, 0);
        sleepCritical(b);
    }
    sleepIdle(b, if (critical) 0 else 5 * 60);
}

fn sleepCritical(b: *Browser) void {
    if (!b.prefs.sleeps_tabs) return;
    const parked = b.parkedTabs(a) catch &.{};
    defer if (parked.len > 0) a.free(parked);
    var any = false;
    for ([_][]const *Tab{ b.tabs.items, parked }) |list| for (list) |t| {
        if (t.typing or awake(b, t) != null) continue;
        if (b.stage_host) |sh| if (t.web) |wv| sh.forget(wv);
        state.sleep(t, null);
        any = true;
    };
    if (any) b.redraw();
}

/// `sleepIdle(within:)`: every tab gone long enough without a look, the
/// one left longest first.
pub fn sleepIdle(b: *Browser, within: ?f64) void {
    const now = json.now();
    if (b.prefs.closes_tabs) {
        const close_after = @max(60, b.prefs.close_hours * 3600);
        var to_close: std.ArrayList(*Tab) = .empty;
        defer to_close.deinit(a);
        for (b.tabs.items) |t| {
            // A saved pair is spared even while Split View is off.
            if (t.pin != null or t.group_id != null or t.name != null or t.shy or b.savedSplit(t.id)) continue;
            if (now - t.touched_at < close_after) continue;
            const why = awake(b, t);
            // Headless tabs never build a page: one with somewhere to be counts as idle.
            const pageless = b.kea.opts.headless and why != null and std.mem.eql(u8, why.?, "no page") and (t.pending != null or !t.isBlank());
            if (why == null or pageless or std.mem.eql(u8, why.?, "already asleep")) to_close.append(a, t) catch {};
        }
        for (to_close.items) |t| if (b.tabs.items.len > 1) b.close(t);
    }
    trimPictures(b, max_kept_pictures);
    @import("../chrome/tab_switcher.zig").dropIdlePictures(b);
    if (!b.prefs.sleeps_tabs) return;
    const wait = within orelse sleepAfter(b);
    const parked = b.parkedTabs(a) catch return;
    defer a.free(parked);
    var idle: std.ArrayList(*Tab) = .empty;
    defer idle.deinit(a);
    for ([_][]const *Tab{ b.tabs.items, parked }) |list| for (list) |t| {
        if (now - t.touched_at >= wait and awake(b, t) == null) idle.append(a, t) catch return;
    };
    std.mem.sort(*Tab, idle.items, {}, struct {
        fn lt(_: void, x: *Tab, y: *Tab) bool {
            return x.touched_at < y.touched_at;
        }
    }.lt);
    const w = watches.getPtr(b) orelse return;
    w.sweep.clearRetainingCapacity();
    // Last first, so `pop` takes the oldest.
    var i = idle.items.len;
    while (i > 0) {
        i -= 1;
        w.sweep.append(a, idle.items[i].serial) catch return;
    }
    w.step +%= 1;
    sweep(b, w);
}

/// Slept tabs whose pictures stay: each is a JPEG of up to 1280 points wide,
/// and a tab waking without one only shows its page a moment later.
pub const max_kept_pictures: usize = 16;

/// Every slept tab's picture past the `keep` looked at last, let go; its
/// address and history (`pending`, `memory`) stay.
pub fn trimPictures(b: *Browser, keep: usize) void {
    const parked = b.parkedTabs(a) catch &.{};
    defer if (parked.len > 0) a.free(parked);
    var held: std.ArrayList(*Tab) = .empty;
    defer held.deinit(a);
    for ([_][]const *Tab{ b.tabs.items, parked }) |list| for (list) |t| {
        if (t.asleep() and t.picture != null) held.append(a, t) catch return;
    };
    if (held.items.len <= keep) return;
    std.mem.sort(*Tab, held.items, {}, struct {
        fn newer(_: void, x: *Tab, y: *Tab) bool {
            return x.touched_at > y.touched_at;
        }
    }.newer);
    for (held.items[keep..]) |t| t.own(&t.picture, null);
}

/// One at a time: the next after this one has slept, or 3 s, whichever
/// comes first.
fn sweep(b: *Browser, w: *Watch) void {
    while (w.sweep.pop()) |serial| {
        const t = Tab.alive(serial) orelse continue;
        w.step +%= 1;
        const step = w.step;
        const later = a.create(Later) catch return;
        later.* = .{ .b = b, .step = step };
        objc.dispatchAfter(3 * std.time.ns_per_s, later, timedOut);
        return sleepWith(b, t, swept, step);
    }
}

const Later = struct { b: *Browser, step: u32 };

fn timedOut(ctx: ?*anyopaque) callconv(.c) void {
    const l: *Later = @ptrCast(@alignCast(ctx orelse return));
    defer a.destroy(l);
    next(l.b, l.step);
}

fn swept(b: *Browser, _: []const u8, step: usize) void {
    next(b, @intCast(step));
}

fn next(b: *Browser, step: u32) void {
    const w = watches.getPtr(b) orelse return;
    if (w.step != step) return;
    w.step +%= 1;
    sweep(b, w);
}

/// `awake(because:)`: why a tab has to stay awake, or null.
pub fn awake(b: *Browser, t: *Tab) ?[]const u8 {
    const ids = b.visibleTabIDs();
    if (t.id == ids[0] or t.id == ids[1]) return "on screen";
    const critical_until = if (watches.get(b)) |w| w.critical_until else 0;
    if (t.pin != null and json.now() >= critical_until) return "pinned";
    if (t.isBlank()) return "blank";
    if (Parts.parse(t.url())) |p| if (p.hostName()) |h| if (isKeptAwake(&b.kea.store, h)) return "kept awake for this site";
    if (t.asleep()) return "already asleep";
    if (t.web == null) return "no page";
    if (t.loading) return "still loading";
    if (t.noisy) return "playing sound";
    if (t.floating) return "its video is out";
    // WKMediaCaptureStateNone = 0.
    if (objc.msg(objc.NSInteger, t.web.?, "cameraCaptureState", .{}) != 0 or
        objc.msg(objc.NSInteger, t.web.?, "microphoneCaptureState", .{}) != 0) return "on a call";
    if (b.kea.ext != null and @import("../ext/capture.zig").screen(t.web.?)) return "recording the screen";
    if (@import("downloads.zig").busy(b.kea, t.web.?)) return "downloading";
    if (t.held.items.len > 0 or t.questions.items.len > 0) return "a question waiting";
    // A sign-in window hands its answer back to the page that opened it.
    if (b.activeTab()) |front| if (front.opener == t.id) return "the page on screen came from it";
    if (b.partnerOf(b.tabById(b.active_id) orelse t)) |other| if (other.opener == t.id) return "the page on screen came from it";
    return null;
}

pub const Done = *const fn (b: *Browser, outcome: []const u8) void;
const DoneWith = *const fn (b: *Browser, outcome: []const u8, arg: usize) void;

/// `sleep(_:done:)`: asks whether the page holds anything typed, pictures
/// it, then lets it go — looking again at each step.
pub fn sleep(b: *Browser, t: *Tab, done: ?Done) void {
    sleepWith(b, t, if (done) |_| relay else null, if (done) |d| @intFromPtr(d) else 0);
}

fn relay(b: *Browser, outcome: []const u8, arg: usize) void {
    const d: Done = @ptrFromInt(arg);
    d(b, outcome);
}

const Ask = struct { b: *Browser, done: ?DoneWith, arg: usize };

fn dropAsk(arg: usize) void {
    const ask: *Ask = @ptrFromInt(arg);
    defer a.destroy(ask);
    if (ask.done) |d| if (watches.contains(ask.b)) d(ask.b, "closed", ask.arg);
}

fn sleepWith(b: *Browser, t: *Tab, done: ?DoneWith, arg: usize) void {
    if (awake(b, t)) |reason| return if (done) |d| d(b, reason, arg);
    const ask = a.create(Ask) catch return;
    ask.* = .{ .b = b, .done = done, .arg = arg };
    state.unsavedOwned(t, typedAnswer, @intFromPtr(ask), dropAsk);
}

fn finish(t: *Tab, ask: *Ask, outcome: []const u8) void {
    defer a.destroy(ask);
    const b = t.browser orelse return;
    if (ask.done) |d| d(b, outcome, ask.arg);
}

fn typedAnswer(t: *Tab, typed: bool, _: ?[]u8, arg: usize) void {
    const ask: *Ask = @ptrFromInt(arg);
    if (typed) return finish(t, ask, "holding something typed");
    const b = t.browser orelse return a.destroy(ask);
    if (awake(b, t)) |reason| return finish(t, ask, reason);
    state.snapshotWidthOwned(t, @min(1280, @max(1, b.active_page_frame.w)), pictured, arg, dropAsk);
}

fn pictured(t: *Tab, _: bool, picture: ?[]u8, arg: usize) void {
    const ask: *Ask = @ptrFromInt(arg);
    const b = t.browser orelse {
        if (picture) |p| t.gpa.free(p);
        return a.destroy(ask);
    };
    if (awake(b, t)) |reason| {
        if (picture) |p| t.gpa.free(p);
        return finish(t, ask, reason);
    }
    if (b.stage_host) |sh| if (t.web) |wv| sh.forget(wv);
    state.sleep(t, picture);
    b.redraw();
    finish(t, ask, "asleep");
}

/// `sleepOthers`: puts every other tab in this Space that can sleep to sleep.
// ponytail: covers this Space only; other Spaces' tabs sleep on their own timer.
pub fn sleepOthers(b: *Browser) void {
    const vis = b.visibleTabIDs();
    const parked = b.parkedTabs(a) catch &.{};
    defer if (parked.len > 0) a.free(parked);
    var count: usize = 0;
    for ([_][]const *Tab{ b.tabs.items, parked }) |list| for (list) |t| {
        if (t.id == b.active_id or t.id == vis[0] or t.id == vis[1]) continue;
        if (b.awake(t) != null) continue;
        b.sleep(t, null);
        count += 1;
    };
    if (count == 0) return b.announce("No other tabs to put to sleep");
    var buf: [64]u8 = undefined;
    const msg = if (count == 1) "1 tab put to sleep" else std.fmt.bufPrint(&buf, "{d} tabs put to sleep", .{count}) catch "Tabs put to sleep";
    b.announce(msg);
}
