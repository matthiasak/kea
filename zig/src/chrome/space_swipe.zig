//! Spaces paged through (SpaceSwipe.swift): two fingers sideways over the
//! column, or up and down over the strip, move the space on screen and the
//! next one together; a mouse wheel's notch brings one space. Past the
//! last space a new one is made in place. The trackpad's scroll events are
//! read before anything else sees them, by an `NSEvent` local monitor, and
//! only a gesture that starts over the tabs and sets off along the spaces'
//! axis is taken; everything else goes on as it would have.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const appkit = @import("../sys/appkit.zig");
const clock = ui.clock;

/// How long after a space comes before another can.
pub const rest: f64 = 0.4;
/// The slide to the next page.
pub const slide_duration: f32 = 0.22;

/// How far the fingers go for the next space: 50 points in the column; in
/// the bar, most of its height.
pub fn enough(b: *const Browser) f32 {
    return if (b.prefs.sidebar) 50 else metrics.strip * 0.6;
}

/// Where the space on screen is: one past the last while the card for a
/// new one is up.
pub fn here(b: *Browser) usize {
    return if (b.making_space) b.kea.spaces.value.len else b.kea.spaceIndex(b.space_id) orelse 0;
}

/// A slide under way: to `target`, the pages travelling to `to`.
pub const Slide = struct { target: usize, to: f32 };

/// The gesture, app-wide (`SpaceSwipe.shared`, on `Kea.swipe`).
pub const SpaceSwipe = struct {
    kea: ?*Kea = null,
    browser: ?*Browser = null,
    monitor: ?objc.Object = null,
    axis: enum { undecided, across, along } = .undecided,
    tracking: bool = false,
    gliding: bool = false,
    ignoring: bool = false,
    gathered: ui.Point = .{},
    notched: f64 = 0,
    resting: f64 = 0,

    /// Called by every window's tabs as they draw: the monitor, once. Which
    /// window a gesture is for is read from its events.
    pub fn start(s: *SpaceSwipe, b: *Browser) void {
        s.kea = b.kea;
        if (s.browser == null) s.browser = b;
        if (s.monitor != null or b.window == null) return;
        s.monitor = appkit.addLocalMonitor(appkit.mask.scroll_wheel, s, takesEvent);
    }

    pub fn stop(s: *SpaceSwipe) void {
        if (s.monitor) |m| appkit.removeMonitor(m);
        s.* = .{};
    }

    fn takesEvent(s: *SpaceSwipe, event: objc.Object) ?objc.Object {
        return if (s.takes(event)) null else event;
    }

    /// The window's browser, if it is still open.
    fn browserFor(s: *SpaceSwipe, window: ?objc.Object) ?*Browser {
        const kea = s.kea orelse return null;
        const w = window orelse return null;
        for (kea.browsers.items) |b| if (b.window) |bw| if (bw.nswindow == w) return b;
        return null;
    }

    fn live(s: *SpaceSwipe) ?*Browser {
        const kea = s.kea orelse return null;
        const b = s.browser orelse return null;
        return if (std.mem.indexOfScalar(*Browser, kea.browsers.items, b) != null) b else null;
    }

    fn overTabs(b: *Browser, event: objc.Object) bool {
        const window = objc.msg(?objc.Object, event, "window", .{}) orelse return false;
        const w = b.window orelse return false;
        if (window != w.nswindow) return false;
        const at = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
        const size = objc.msg(objc.CGRect, window, "frame", .{}).size;
        if (b.prefs.sidebar) return if (b.prefs.side_position == .right)
            at.x >= size.width - b.prefs.side_width
        else
            at.x < b.prefs.side_width;
        return at.y > size.height - metrics.strip;
    }

    /// True for an event the swipe keeps for itself.
    fn takes(s: *SpaceSwipe, event: objc.Object) bool {
        const phase = objc.msg(objc.NSUInteger, event, "phase", .{});
        const momentum = objc.msg(objc.NSUInteger, event, "momentumPhase", .{});
        const precise = objc.msg(objc.BOOL, event, "hasPreciseScrollingDeltas", .{});
        const starting = phase & 1 != 0;
        if (starting or !precise) if (s.browserFor(objc.msg(?objc.Object, event, "window", .{}))) |over| {
            s.browser = over;
        };
        const b = s.live() orelse return false;
        if (!b.prefs.uses_spaces or (b.folded and !b.peeking)) return false;
        const dx: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaX", .{}));
        const dy: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaY", .{}));
        if (!precise) {
            // A wheel's notch along the spaces' axis brings one space; a spin
            // of the wheel brings one, the next once it has rested.
            const step = if (b.prefs.sidebar) (if (@abs(dx) > @abs(dy)) dx else 0) else dy;
            if (step == 0 or !overTabs(b, event)) return false;
            const now = clock.now();
            const rested = now - s.notched > 0.3 and now > s.resting;
            s.notched = now;
            if (!rested) return true;
            const at = here(b);
            const target: isize = @as(isize, @intCast(at)) + @as(isize, if (step < 0) 1 else -1);
            if (target >= 0 and target <= b.kea.spaces.value.len) s.slideFrom(b, @intCast(target), at);
            return true;
        }
        if (momentum != 0) return s.gliding;
        // NSEventPhase: began 1, changed 4, ended 8, cancelled 16.
        if (starting) {
            s.gliding = false;
            s.ignoring = false;
            if (!overTabs(b, event)) {
                s.tracking = false;
                return false;
            }
            s.began();
            if (s.ignoring) return true;
            return s.moved(dx, dy);
        }
        if (phase & 4 != 0) {
            if (s.ignoring) return true;
            if (!s.tracking) return false;
            return s.moved(dx, dy);
        }
        if (phase & (8 | 16) != 0) {
            if (s.ignoring) {
                s.ignoring = false;
                s.gliding = true;
                return true;
            }
            if (!s.tracking) return false;
            const taken = s.axis == .across;
            s.ended(phase & 16 != 0);
            s.gliding = taken;
            return taken;
        }
        return false;
    }

    pub fn began(s: *SpaceSwipe) void {
        s.axis = .undecided;
        s.gathered = .{};
        // Just after a space came: the same hand's next stroke is let go by.
        s.ignoring = clock.now() <= s.resting;
        s.tracking = !s.ignoring;
    }

    /// True while the gesture is this one's to take.
    pub fn moved(s: *SpaceSwipe, dx: f32, dy: f32) bool {
        if (!s.tracking) return false;
        const b = s.live() orelse return false;
        const step = if (b.prefs.sidebar) dx else dy;
        const aside = if (b.prefs.sidebar) dy else dx;
        s.gathered.x += step;
        s.gathered.y += aside;
        if (s.axis == .undecided) {
            if (@abs(s.gathered.x) + @abs(s.gathered.y) <= 6) return false;
            s.axis = if (@abs(s.gathered.x) > @abs(s.gathered.y) * 1.5) .across else .along;
        }
        if (s.axis != .across) return false;
        b.spaces_ui.slide = null;
        b.spaces_ui.settling = false;
        b.swipe = resisted(b, s.gathered.x);
        b.redraw();
        return true;
    }

    pub fn ended(s: *SpaceSwipe, cancelled: bool) void {
        defer s.tracking = false;
        const b = s.live() orelse return;
        if (s.axis != .across) return;
        const travel = s.gathered.x;
        const at = here(b);
        // Fingers to the left, or up, bring what is next.
        const target: isize = if (cancelled or @abs(travel) < enough(b)) @intCast(at) else @as(isize, @intCast(at)) + @as(isize, if (travel < 0) 1 else -1);
        if (target == at or target < 0 or target > b.kea.spaces.value.len) {
            b.spaces_ui.settling = true;
            b.redraw();
            return;
        }
        s.slideFrom(b, @intCast(target), at);
    }

    fn slideFrom(s: *SpaceSwipe, b: *Browser, target: usize, from: usize) void {
        s.resting = clock.now() + rest;
        slide(b, target, from);
    }
};

/// Nothing that way: the rows give a little, and come back.
fn resisted(b: *Browser, travel: f32) f32 {
    const at = here(b);
    const blocked = (travel > 0 and at == 0) or (travel < 0 and at == b.kea.spaces.value.len);
    return if (blocked) travel / 4 else travel;
}

/// The pages carry on the way the fingers went until the next one is
/// where this one was; then it becomes the one on screen, in the same
/// frame and without anything moving. One past the last is the new card.
pub fn slide(b: *Browser, target: usize, from: usize) void {
    if (b.making_space and target != b.kea.spaces.value.len) cancelSpaceCreation(b);
    const width = if (b.prefs.sidebar) b.prefs.side_width else metrics.strip;
    const away: f32 = if (target > from) -1 else 1;
    b.space_step = if (target > from) 1 else -1;
    b.kea.swipe.resting = clock.now() + rest;
    b.spaces_ui.settling = false;
    b.spaces_ui.slide = .{ .target = target, .to = away * width };
    b.redraw();
}

/// Each frame, first: the pages' offset (`Browser.swipe`), and the space
/// changed once a slide is over.
pub fn frame(b: *Browser, c: *ui.Context) void {
    const id = std.hash.Wyhash.hash(0, "kea.space.swipe");
    const st = &b.spaces_ui;
    if (!b.making_space) st.card_open = false;
    if (st.slide) |s| {
        const v = ui.tween(c, id, 0, s.to, slide_duration, .ease_out);
        b.swipe = v;
        if (v != s.to) return;
        st.slide = null;
        if (s.target == b.kea.spaces.value.len) {
            b.making_space = true;
        } else {
            b.making_space = false;
            b.switchSpace(b.kea.spaces.value[s.target].id);
        }
        b.swipe = ui.tween(c, id, 0, 0, 0, .linear);
        c.changed = true;
    } else if (st.settling) {
        b.swipe = motion.settleTo(c, id, 0, 0);
        if (b.swipe == 0) st.settling = false;
    } else {
        // Under the fingers exactly, or at rest.
        b.swipe = ui.tween(c, id, 0, b.swipe, 0, .linear);
    }
}

/// "New Space…": the card, where the next space would come in; a question
/// only while the tabs are folded out of sight.
pub fn askForSpace(b: *Browser) void {
    if (!b.folded or b.peeking) {
        b.kea.swipe.start(b);
        slide(b, b.kea.spaces.value.len, here(b));
    } else {
        @import("spaces_view.zig").ask(b, .new, b.space_id);
    }
}

pub fn cancelSpaceCreation(b: *Browser) void {
    b.after_space_created = null;
}
