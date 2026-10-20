//! The column of tabs, or the strip across the top, folded away with ⌘S
//! (Fold.swift). Folded, the page takes the whole window; the pointer
//! resting against the column's edge, or the window's top for the strip,
//! slides it out over the page, and it goes again a moment after the
//! pointer leaves it. The traffic lights ride with it. A column folded for
//! good (`sidebar.hides`) and the strip wait for the pointer to settle on
//! the edge; just past the column's edge counts as the edge, if the
//! pointer came off the window to get there.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const presence = @import("presence.zig").presence;
const lights = @import("lights.zig");
const side_bar = @import("side_bar.zig");
const tab_bar = @import("tab_bar.zig");
const appkit = @import("../sys/appkit.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// How near the edge the pointer has to be.
pub const edge: f32 = 6;
/// How far past the window's edge, on the column's side, still counts.
pub const overshoot: f32 = 48;
/// The grace before the column goes back in.
pub const grace: f64 = 0.3;
/// In full screen, the corner where macOS brings the window's buttons down.
pub const full_screen_corner: f32 = 60;
/// The band along the top that is the title bar over the page.
pub const top: f32 = 8;
/// How long the pointer rests on the edge before the column comes, when
/// it waits at all.
pub const dwell: f64 = 0.15;

/// What the fold keeps between frames (on `Browser.fold`).
pub const State = struct {
    /// The column coming out once the pointer has settled (`arriving`),
    /// and going back in after the grace (`leaving`): when, in `c.time`;
    /// asked for from outside a frame, stamped on the next one.
    arriving: ?f64 = null,
    arrive_asked: bool = false,
    leaving: ?f64 = null,
    leave_asked: bool = false,
    /// The pointer is over the column.
    inside: bool = false,
    /// `Pointer.crossing`: over the window, or just off the column's edge from it.
    crossing: bool = false,
    local: ?objc.Object = null,
    global: ?objc.Object = null,
    accepted: bool = false,
    /// The prefs the fold follows changes of.
    seen: ?struct { sidebar: bool, right: bool, hides: bool, width: f32 } = null,
    /// The lights as last set: hidden, which way, how far.
    lights: ?struct { off: bool, sidebar: bool, right: bool, width: f32, full: bool } = null,
    /// An address was being typed into a tab last frame: done with, and
    /// the pointer elsewhere, the column goes the way it would have.
    editing: bool = false,
};

/// ⌘S: the column, or the strip, out of the way or back.
pub fn toggleFold(b: *Browser) void {
    b.peeking = false;
    b.folded = !b.folded;
    b.redraw();
}

/// Folded, and not taken over by a page filling the screen.
fn folding(b: *const Browser) bool {
    return b.folded;
}

fn onRight(b: *const Browser) bool {
    return b.prefs.sidebar and b.prefs.side_position == .right;
}

/// A popover opened from the column, still open — an extension's popup
/// too, or it is left hanging from nothing: it holds the column out.
fn holding(b: *const Browser) bool {
    if (@import("../ext/popup.zig").up() != null) return true;
    const o = b.overlay orelse return false;
    return o == .bookmarks_dropdown or o == .bookmark_card or o == .extension_menu;
}

fn fullScreen(b: *const Browser) bool {
    const w = b.window orelse return false;
    return w.isFullScreen();
}

/// Over the window, after everything but the bars: the band to drag the
/// window by, and the column or strip while it is out.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    follows(b);
    const st = &b.fold;
    const now = c.time;
    // Asked for between frames: from now.
    if (st.arrive_asked) {
        st.arrive_asked = false;
        st.arriving = now + dwell;
    }
    if (st.leave_asked) {
        st.leave_asked = false;
        if (st.leaving == null) st.leaving = now + grace;
    }
    if (st.arriving) |at| {
        if (now >= at) {
            st.arriving = null;
            peek(b, true);
        } else c.frameIn(@floatCast(at - now));
    }
    if (st.leaving) |at| {
        if (now >= at) {
            st.leaving = null;
            if (!holding(b) and b.editing_tab == null) b.peeking = false;
        } else c.frameIn(@floatCast(at - now));
    }
    const editing = b.editing_tab != null;
    if (st.editing and !editing and !st.inside and b.peeking) peek(b, false);
    st.editing = editing;
    watch(b);
    hideLights(b, c.reduce_motion);

    const side = b.prefs.sidebar;
    // The band too thin to be in a page's way that stands in for the title bar.
    if (side or folding(b)) lights.dragStrip(b, c, .{ .absolute = true, .width = .fill, .height = px(top) }, .zoom);

    const id = std.hash.Wyhash.hash(0, "kea.fold");
    const right = onRight(b);
    if (side) {
        const w = b.prefs.side_width;
        const t = presence(c, id, folding(b) and b.peeking, motion.glide, motion.glide) orelse return;
        const at = if (right) c.size.w - w + (1 - t) * w else -(1 - t) * w;
        castShadow(c, p, .{ .x = at, .y = 0, .w = w, .h = c.size.h }, t, 0);
        side_bar.sideBar(b, c, p, true, at);
    } else {
        const t = presence(c, id ^ 1, folding(b) and b.peeking, motion.glide, motion.glide) orelse return;
        const y = -(1 - t) * metrics.strip;
        castShadow(c, p, .{ .x = 0, .y = y, .w = c.size.w, .h = metrics.strip }, t, 4);
        // The row has no ground of its own: out over the page it brings the window's.
        _ = c.open(.{ .absolute = true, .offset = .{ .y = y }, .width = .fill, .height = px(metrics.strip), .background = p.ground }, "fold-strip");
        tab_bar.tabBar(b, c, p);
        c.end();
    }
}

/// `FoldShadow`: cast from a ground laid behind, full while out, nothing
/// once gone.
// ponytail: nanoui shadows have no x offset; the column's ±4 pt lean is dropped.
fn castShadow(c: *ui.Context, p: *const Palette, r: ui.Rect, strength: f32, y: f32) void {
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = r.x, .y = r.y },
        .width = px(r.w),
        .height = px(r.h),
        .background = p.ground,
        .shadow = .{ .color = ui.Color.black.alpha(0.14 * std.math.clamp(strength, 0, 1)), .blur = 40, .y = y },
    }, .none, null);
}

/// What the fold follows: back to the strip and to the column again, the
/// column comes back as it rests; a change of side or of `sidebar.hides`.
fn follows(b: *Browser) void {
    const st = &b.fold;
    const now: @TypeOf(st.seen.?) = .{ .sidebar = b.prefs.sidebar, .right = b.prefs.side_position == .right, .hides = b.prefs.side_hides, .width = b.prefs.side_width };
    const was = st.seen orelse {
        st.seen = now;
        return;
    };
    st.seen = now;
    if (was.sidebar != now.sidebar) {
        resetPending(b);
        b.folded = now.sidebar and now.hides;
        b.peeking = false;
    } else if (was.hides != now.hides) {
        resetPending(b);
        if (now.sidebar) {
            b.peeking = false;
            b.folded = now.hides;
        }
    } else if (was.right != now.right) {
        resetPending(b);
        b.peeking = false;
    }
}

fn resetPending(b: *Browser) void {
    const st = &b.fold;
    st.arriving = null;
    st.arrive_asked = false;
    st.leaving = null;
    st.leave_asked = false;
    st.inside = false;
}

// MARK: the pointer

/// Watched only while something is folded; the rest of the time no move of
/// it costs anything (`Pointer.start`/`stop`).
fn watch(b: *Browser) void {
    if (folding(b)) start(b) else stop(b);
}

fn start(b: *Browser) void {
    const st = &b.fold;
    if (st.local != null) return;
    const w = b.window orelse return;
    st.crossing = false;
    st.accepted = objc.msg(objc.BOOL, w.nswindow, "acceptsMouseMovedEvents", .{});
    objc.msg(void, w.nswindow, "setAcceptsMouseMovedEvents:", .{objc.YES});
    const events = appkit.mask.mouse_moved | appkit.mask.left_mouse_dragged;
    st.local = appkit.addLocalMonitor(events, b, localMoved);
    st.global = appkit.addGlobalMonitor(events, b, globalMoved);
}

/// The browser is going, or nothing is folded: the monitors go.
pub fn stop(b: *Browser) void {
    const st = &b.fold;
    if (st.local == null and st.global == null) return;
    if (st.local) |m| appkit.removeMonitor(m);
    if (st.global) |m| appkit.removeMonitor(m);
    st.local = null;
    st.global = null;
    if (b.window) |w| objc.msg(void, w.nswindow, "setAcceptsMouseMovedEvents:", .{st.accepted});
}

fn localMoved(b: *Browser, event: objc.Object) ?objc.Object {
    follow(b);
    return event;
}

fn globalMoved(b: *Browser, _: objc.Object) void {
    follow(b);
}

/// From the pointer's actual place, on every move.
fn follow(b: *Browser) void {
    const w = b.window orelse return pass(b);
    const ns = w.nswindow;
    if (!folding(b) or !objc.msg(objc.BOOL, ns, "isVisible", .{})) return pass(b);
    const screen = appkit.mouseLocation();
    const inv = objc.msg(objc.CGPoint, ns, "convertPointFromScreen:", .{screen});
    const size = objc.msg(objc.CGRect, ns, "frame", .{}).size;
    const top_number = appkit.windowNumberAt(screen);
    const own_number = objc.msg(objc.NSInteger, ns, "windowNumber", .{});
    followAt(b, .{
        .point = .{ .x = @floatCast(inv.x), .y = @floatCast(size.height - inv.y) },
        .size = .{ .w = @floatCast(size.width), .h = @floatCast(size.height) },
        .on_window = top_number == own_number,
        .on_own_panel = top_number != own_number and appkit.ownWindowNumbered(top_number),
        .on_screen = appkit.onVisibleScreen(screen),
        .full_screen = fullScreen(b),
    });
    b.redraw();
}

/// Where the pointer is, as the fold sees it: in window points from the
/// top left, and what is under it.
pub const Pointer = struct {
    point: ui.Point,
    size: ui.Size,
    /// This window is the one under the pointer.
    on_window: bool = true,
    /// One of this app's own windows is (a popover from the column).
    on_own_panel: bool = false,
    /// On a screen's visible part: not the Dock, not the menu bar.
    on_screen: bool = true,
    full_screen: bool = false,
};

/// Opens or closes the column from the pointer's place (`Fold.follow`).
pub fn followAt(b: *Browser, ptr: Pointer) void {
    const st = &b.fold;
    if (!folding(b)) return pass(b);
    const side = b.prefs.sidebar;
    const right = onRight(b);
    const x = ptr.point.x;
    const y = ptr.point.y;
    const size = ptr.size;
    const in_window = x >= 0 and x < size.w and y >= 0 and y < size.h;
    // From the column's edge for the column, from the top for the strip.
    const distance = if (side) (if (right) size.w - x else x) else y;
    // Just past the column's edge, beside the window, come off the window.
    const past = if (right) x - size.w else -x;
    const beside = side and past > 0 and past < overshoot and y >= 0 and y < size.h;
    const overshot = beside and st.crossing and ptr.on_screen;
    st.crossing = in_window or overshot;
    if (b.peeking) {
        pass(b);
        const reach = if (side) b.prefs.side_width else metrics.strip;
        const over = ptr.on_own_panel or holding(b) or overshot or (ptr.on_window and in_window and distance < reach);
        st.inside = over;
        peek(b, over);
    } else if (in_window and distance < edge and !(side and ptr.full_screen and y < full_screen_corner)) {
        // Another app's window over this one doesn't bring the column out.
        if (!ptr.on_window) return pass(b);
        if (st.arriving == null and !st.arrive_asked) arrive(b, false);
    } else if (overshot) {
        // The wait starts again with every move: the column comes once the
        // pointer stops.
        arrive(b, true);
    } else pass(b);
}

/// The pointer on the edge: out at once, or after the dwell when the
/// column is folded for good, always for the strip, and just past the edge.
fn arrive(b: *Browser, resting: bool) void {
    if (!(resting or !b.prefs.sidebar or b.prefs.side_hides)) return peek(b, true);
    pass(b);
    b.fold.arrive_asked = true;
}

/// The pointer crossed the edge without stopping.
fn pass(b: *Browser) void {
    b.fold.arriving = null;
    b.fold.arrive_asked = false;
}

/// Out at once; in only once the pointer has stayed away for the grace.
fn peek(b: *Browser, out: bool) void {
    const st = &b.fold;
    if (out) {
        st.leaving = null;
        st.leave_asked = false;
        if (b.peeking) return;
        b.peeking = true;
        b.redraw();
    } else if (st.leaving == null) {
        st.leave_asked = true;
        b.redraw();
    }
}

// MARK: the lights

/// The title bar's own view, which holds the three buttons and the resting
/// circles: hidden or slid away with the column.
fn hideLights(b: *Browser, reduced: bool) void {
    const w = b.window orelse return;
    const st = &b.fold;
    const want: @TypeOf(st.lights.?) = .{
        .off = b.folded and !b.peeking,
        .sidebar = b.prefs.sidebar,
        .right = onRight(b),
        .width = b.prefs.side_width,
        .full = fullScreen(b),
    };
    if (st.lights) |was| if (std.meta.eql(was, want)) return;
    const was = st.lights;
    st.lights = want;
    const close = objc.msg(?objc.Object, w.nswindow, "standardWindowButton:", .{@as(objc.NSUInteger, 0)}) orelse return;
    const bar = objc.msg(?objc.Object, close, "superview", .{}) orelse return;
    const layer = objc.msg(?objc.Object, bar, "layer", .{});
    if (want.full) {
        // In full screen the buttons are macOS's to show.
        if (layer) |l| objc.msg(void, l, "removeAnimationForKey:", .{objc.nsString("fold")});
        objc.msg(void, bar, "setHidden:", .{objc.NO});
        return;
    }
    // The column changed sides: an overtaken slide is let go.
    if (was) |prev| if (prev.right != want.right) {
        slides +%= 1;
        if (layer) |l| objc.msg(void, l, "removeAnimationForKey:", .{objc.nsString("fold")});
        objc.msg(void, bar, "setHidden:", .{want.off});
        return;
    };
    if (want.sidebar) slide(bar, want.off, want.width, false, want.right, reduced) else slide(bar, want.off, metrics.strip, true, false, reduced);
}

/// Bumped by every slide, so one that was overtaken doesn't hide the
/// lights on its way out.
var slides: u32 = 0;

const Done = struct {
    bar: objc.Object,
    off: bool,
    turn: u32,

    fn finish(self: *Done) void {
        defer std.heap.c_allocator.destroy(self);
        defer objc.release(self.bar);
        if (self.turn != slides) return;
        if (objc.msg(?objc.Object, self.bar, "layer", .{})) |l| objc.msg(void, l, "removeAnimationForKey:", .{objc.nsString("fold")});
        objc.msg(void, self.bar, "setHidden:", .{self.off});
    }
};

/// `Fold.slide`: in from the chosen edge and back off it, on the column's
/// own spring (`Motion.glide` as a CASpringAnimation), from wherever the
/// lights are when the pointer turns back halfway. `up`: off the top edge.
fn slide(bar: objc.Object, off: bool, by: f32, up: bool, right: bool, reduced: bool) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    slides +%= 1;
    const turn = slides;
    const fold = objc.nsString("fold");
    const layer = objc.msg(?objc.Object, bar, "layer", .{}) orelse return objc.msg(void, bar, "setHidden:", .{off});
    if (reduced) {
        objc.msg(void, layer, "removeAnimationForKey:", .{fold});
        return objc.msg(void, bar, "setHidden:", .{off});
    }
    const path = if (up) "transform.translation.y" else "transform.translation.x";
    const other = if (up) "transform.translation.x" else "transform.translation.y";
    const flipped = if (objc.msg(?objc.Object, bar, "superview", .{})) |s| objc.msg(objc.BOOL, s, "isFlipped", .{}) else false;
    const width: f64 = by;
    const gone: f64 = if (up) (if (flipped) -width else width) else if (right) width else -width;
    // A slide still running on the other axis is let go.
    if (objc.msg(?objc.Object, layer, "animationForKey:", .{fold})) |running| {
        const key = objc.msg(?objc.Object, running, "keyPath", .{});
        if (key != null and objc.msg(objc.BOOL, key.?, "isEqualToString:", .{objc.nsString(other)}))
            objc.msg(void, layer, "removeAnimationForKey:", .{fold});
    }
    const still = objc.msg(?objc.Object, layer, "animationForKey:", .{fold}) != null;
    const from: f64 = if (still) blk: {
        const pres = objc.msg(?objc.Object, layer, "presentationLayer", .{}) orelse break :blk 0;
        const v = objc.msg(?objc.Object, pres, "valueForKeyPath:", .{objc.nsString(path)}) orelse break :blk 0;
        break :blk objc.msg(f64, v, "doubleValue", .{});
    } else if (objc.msg(objc.BOOL, bar, "isHidden", .{})) gone else 0;
    const to: f64 = if (off) gone else 0;
    if (from == to) {
        objc.msg(void, layer, "removeAnimationForKey:", .{fold});
        return objc.msg(void, bar, "setHidden:", .{off});
    }
    const spring = objc.msg(objc.Object, objc.class("CASpringAnimation"), "animationWithKeyPath:", .{objc.nsString(path)});
    const response: f64 = motion.glide.response;
    objc.msg(void, spring, "setMass:", .{@as(f64, 1)});
    objc.msg(void, spring, "setStiffness:", .{std.math.pow(f64, 2 * std.math.pi / response, 2)});
    objc.msg(void, spring, "setDamping:", .{4 * std.math.pi * @as(f64, motion.glide.damping) / response});
    objc.msg(void, spring, "setFromValue:", .{objc.msg(objc.Object, objc.class("NSNumber"), "numberWithDouble:", .{from})});
    objc.msg(void, spring, "setToValue:", .{objc.msg(objc.Object, objc.class("NSNumber"), "numberWithDouble:", .{to})});
    objc.msg(void, spring, "setDuration:", .{objc.msg(f64, spring, "settlingDuration", .{})});
    objc.msg(void, spring, "setFillMode:", .{objc.nsString("forwards")});
    objc.msg(void, spring, "setRemovedOnCompletion:", .{objc.NO});
    objc.msg(void, bar, "setHidden:", .{objc.NO});
    const done = std.heap.c_allocator.create(Done) catch return;
    done.* = .{ .bar = objc.retain(bar), .off = off, .turn = turn };
    const tx = objc.class("CATransaction");
    objc.msg(void, tx, "begin", .{});
    var block = objc.Block(Done, &.{}).init(done, Done.finish);
    objc.msg(void, tx, "setCompletionBlock:", .{&block});
    objc.msg(void, layer, "addAnimation:forKey:", .{ spring, fold });
    objc.msg(void, tx, "commit", .{});
}
