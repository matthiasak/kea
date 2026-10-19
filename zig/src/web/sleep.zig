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
    return if (set > 0) set else 10 * 60;
}

const pressure_warning = dispatch.pressure_warning;
const pressure_critical = dispatch.pressure_critical;

fn timerClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigSleepTimer",
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
    if (critical) {
        w.critical_until = json.now() + 60;
        @import("../chrome/tab_switcher.zig").reset(b);
    }
    sleepIdle(b, if (critical) 0 else 5 * 60);
}

/// `sleepIdle(within:)`: every tab gone long enough without a look, the
/// one left longest first.
pub fn sleepIdle(b: *Browser, within: ?f64) void {
    if (!b.prefs.sleeps_tabs) return;
    const wait = within orelse sleepAfter(b);
    const now = json.now();
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
    if (t.asleep()) return "already asleep";
    if (t.web == null) return "no page";
    if (t.loading) return "still loading";
    if (t.noisy) return "playing sound";
    if (t.floating) return "its video is out";
    if (t.recording) return "on a call";
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

const Ask = struct { done: ?DoneWith, arg: usize };

fn sleepWith(b: *Browser, t: *Tab, done: ?DoneWith, arg: usize) void {
    if (awake(b, t)) |reason| return if (done) |d| d(b, reason, arg);
    const ask = a.create(Ask) catch return;
    ask.* = .{ .done = done, .arg = arg };
    state.unsaved(t, typedAnswer, @intFromPtr(ask));
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
    state.snapshot(t, pictured, arg);
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
