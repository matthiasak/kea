//! Two fingers sideways means back or forward (Swipe.swift, and PageView's
//! "two fingers sideways", Tab.swift 1733-2068): a disc comes in from the
//! edge, armed past 70 pt (or a flick of 30 within 0.25 s); held while armed
//! with Settings › Hold a swipe on, the pages that way in a list. The page
//! is asked (`swipe_watch.js`) whether the swipe is its own.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Page = @import("page_view.zig").Page;
const Tab = @import("tab.zig").Tab;

/// A page in the list a held swipe shows.
pub const Stop = struct { title: []u8, url: []u8 };

/// Where a sideways swipe has got to, for the disc.
pub const Pull = struct {
    back: bool,
    travel: f64,
    armed: bool,
    going: bool,
    /// Held once armed: the pages that way, top to bottom (empty: the disc).
    stops: []const Stop = &.{},
    picked: usize = 0,
};

const Axis = enum { across, down };

pub const State = struct {
    sideways: f64 = 0,
    gathered_x: f64 = 0,
    gathered_y: f64 = 0,
    axis: ?Axis = null,
    back: bool = true,
    free: ?bool = null,
    asked: ?f64 = null,
    spent: bool = false,
    armed_now: bool = false,
    showing: bool = false,
    going: bool = false,
    pulls: u32 = 0,
    holding: u32 = 0,
    held: bool = false,
    stops: [8]Stop = undefined,
    items: [8]objc.Object = undefined,
    stops_len: usize = 0,
    picked: usize = 0,
    climbed: f64 = 0,
};

const hold: f64 = 0.45;
const step: f64 = 22;
const arm: f64 = 70;
const flick: f64 = 30;
const flick_time: f64 = 0.25;
const show: f64 = 6;

pub const phase_began: objc.NSUInteger = 1;
pub const phase_changed: objc.NSUInteger = 4;
pub const phase_ended: objc.NSUInteger = 8;
pub const phase_cancelled: objc.NSUInteger = 16;
pub const phase_may_begin: objc.NSUInteger = 32;

/// `Swipe.calm`: no rubber-banding at the top and bottom; left and right
/// keep theirs (`_WKRectEdge` bits for CGRectMinXEdge and MaxXEdge).
pub fn calm(wv: objc.Object) void {
    if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_setRubberBandingEnabled:")})) return;
    objc.msg(void, wv, "_setRubberBandingEnabled:", .{@as(objc.NSUInteger, (1 << 0) | (1 << 2))});
}

fn clearList(s: *State) void {
    for (s.stops[0..s.stops_len], s.items[0..s.stops_len]) |stop, item| {
        std.heap.c_allocator.free(stop.title);
        std.heap.c_allocator.free(stop.url);
        objc.release(item);
    }
    s.stops_len = 0;
}

/// The view let go mid-gesture.
pub fn reset(page: *Page) void {
    clearList(&page.swipe);
    page.swipe.held = false;
}

fn haptic(pattern: objc.NSInteger) void {
    const performer = objc.msg(objc.Object, objc.class("NSHapticFeedbackManager"), "defaultPerformer", .{});
    objc.msg(void, performer, "performFeedbackPattern:performanceTime:", .{ pattern, @as(objc.NSUInteger, 1) });
}
const alignment: objc.NSInteger = 1;
const level_change: objc.NSInteger = 2;

pub fn wheel(page: *Page, wv: objc.Object, event: objc.Object) void {
    const s = &page.swipe;
    // Only a live trackpad gesture: not its glide, not a mouse wheel.
    if (objc.msg(objc.NSUInteger, event, "momentumPhase", .{}) != 0) return;
    const phase = objc.msg(objc.NSUInteger, event, "phase", .{});
    if (phase == phase_may_begin or phase == phase_began) {
        clearList(s);
        s.* = .{ .pulls = s.pulls + 1, .going = s.going, .holding = s.holding +% 1 };
        if (s.going) {
            s.going = false;
            tell(page, null);
        }
    } else if (phase == phase_changed) {
        if (s.spent) return;
        const dx = objc.msg(f64, event, "scrollingDeltaX", .{});
        if (s.axis == null) {
            s.gathered_x += @abs(dx);
            s.gathered_y += @abs(objc.msg(f64, event, "scrollingDeltaY", .{}));
            s.sideways += dx;
            if (s.gathered_x + s.gathered_y <= 6) return;
            s.axis = if (s.gathered_x > s.gathered_y * 1.3) .across else .down;
            if (s.axis == .down) {
                s.spent = true;
                return;
            }
            s.back = s.sideways > 0;
            if (!objc.msg(objc.BOOL, wv, if (s.back) "canGoBack" else "canGoForward", .{})) {
                s.spent = true;
                return;
            }
            s.asked = ui.clock.now();
            return say(page, wv);
        }
        s.sideways += dx;
        if (s.stops_len > 0) climb(s, event);
        say(page, wv);
    } else if (phase == phase_ended) {
        release(page, wv);
    } else if (phase == phase_cancelled) {
        s.spent = true;
        settle(page, null);
    }
}

/// `answer(free:)`: the page has said whether the swipe would scroll.
pub fn answer(page: *Page, wv: objc.Object, yes: bool) void {
    const s = &page.swipe;
    if (s.axis == .down or s.spent) return;
    if (!yes) {
        s.free = false;
        s.spent = true;
        return settle(page, null);
    }
    if (s.free != null) return;
    s.free = true;
    say(page, wv);
}

fn travel(s: *const State) f64 {
    return @max(0, if (s.back) s.sideways else -s.sideways);
}

fn say(page: *Page, wv: objc.Object) void {
    const s = &page.swipe;
    // A page that never answers still has to be leavable by hand.
    if (s.free == null) if (s.asked) |at| if (ui.clock.now() - at > 0.18) {
        s.free = true;
    };
    if (s.free != true) return;
    const far = travel(s);
    if (far < show) {
        if (s.showing) settle(page, null);
        return;
    }
    const armed = far >= arm;
    const t = Tab.alive(page.serial);
    if (t != null and t.?.kea.prefs.holds_history and s.stops_len == 0 and armed != s.armed_now) {
        s.holding +%= 1;
        if (armed) t.?.after(hold, openListFired, s.holding);
    }
    if (armed != s.armed_now and s.stops_len == 0) haptic(if (armed) level_change else alignment);
    s.armed_now = armed;
    _ = wv;
    settle(page, .{ .back = s.back, .travel = far, .armed = armed, .going = false, .stops = s.stops[0..s.stops_len], .picked = s.picked });
}

fn openListFired(t: *Tab, holding: usize) void {
    const page = t.page orelse return;
    const wv = t.web orelse return;
    if (page.swipe.holding != holding) return;
    openList(page, wv);
}

/// Held long enough: up to 8 pages that way, the nearest picked.
fn openList(page: *Page, wv: objc.Object) void {
    const s = &page.swipe;
    if (s.spent or !s.armed_now or s.stops_len > 0) return;
    const list = objc.msg(objc.Object, wv, "backForwardList", .{});
    const items = objc.msg(objc.Object, list, if (s.back) "backList" else "forwardList", .{});
    const n = objc.msg(objc.NSUInteger, items, "count", .{});
    const take = @min(n, 8);
    if (take < 2) return;
    const from = if (s.back) n - take else 0;
    for (0..take) |i| {
        const item = objc.msg(objc.Object, items, "objectAtIndex:", .{from + i});
        const a = std.heap.c_allocator;
        const url = objc.fromNSString(objc.msg(?objc.Object, objc.msg(objc.Object, item, "URL", .{}), "absoluteString", .{}));
        s.stops[i] = .{
            .title = a.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, item, "title", .{}))) catch return clearList(s),
            .url = a.dupe(u8, url) catch return clearList(s),
        };
        s.items[i] = objc.retain(item);
        s.stops_len = i + 1;
    }
    s.picked = if (s.back) take - 1 else 0;
    s.climbed = 0;
    haptic(level_change);
    say(page, wv);
}

/// Through the list a step at a time, with the fingers.
fn climb(s: *State, event: objc.Object) void {
    const sign: f64 = if (objc.msg(objc.BOOL, event, "isDirectionInvertedFromDevice", .{})) 1 else -1;
    s.climbed += -sign * objc.msg(f64, event, "scrollingDeltaY", .{});
    var moved = false;
    while (s.climbed >= step and s.picked < s.stops_len - 1) {
        s.picked += 1;
        s.climbed -= step;
        moved = true;
    }
    while (s.climbed <= -step and s.picked > 0) {
        s.picked -= 1;
        s.climbed += step;
        moved = true;
    }
    s.climbed = @max(-step, @min(step, s.climbed));
    if (moved) haptic(alignment);
}

fn release(page: *Page, wv: objc.Object) void {
    const s = &page.swipe;
    defer s.spent = true;
    s.holding +%= 1;
    const far = travel(s);
    const flicked = !s.spent and s.free == true and far >= flick and
        (if (s.asked) |at| ui.clock.now() - at <= flick_time else false);
    if (s.spent or s.free != true or !(s.armed_now or flicked or s.stops_len > 0)) return settle(page, null);
    s.going = true;
    settle(page, .{ .back = s.back, .travel = far, .armed = true, .going = true, .stops = s.stops[0..s.stops_len], .picked = s.picked });
    if (s.stops_len > 0 and s.picked < s.stops_len) {
        _ = objc.msg(?objc.Object, wv, "goToBackForwardListItem:", .{s.items[s.picked]});
    } else if (s.back) {
        _ = objc.msg(?objc.Object, wv, "goBack", .{});
    } else _ = objc.msg(?objc.Object, wv, "goForward", .{});
    s.pulls += 1;
    if (Tab.alive(page.serial)) |t| t.after(0.32, gone, s.pulls);
}

fn gone(t: *Tab, pulls: usize) void {
    const page = t.page orelse return;
    if (page.swipe.pulls != pulls) return;
    page.swipe.going = false;
    settle(page, null);
}

fn settle(page: *Page, pull: ?Pull) void {
    const s = &page.swipe;
    if (pull == null) {
        s.holding +%= 1;
        clearList(s);
    }
    s.showing = pull != null;
    tell(page, pull);
}

fn tell(page: *Page, pull: ?Pull) void {
    const t = Tab.alive(page.serial) orelse return;
    t.pull = pull;
    t.changed(.state);
}
