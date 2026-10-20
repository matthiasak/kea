//! Moving and sizing the floating window (Float.swift `Controls`): a press
//! drags it, or from its bottom-right corner stretches it at its shape; two
//! fingers push it along carrying the pointer — or, with Settings ›
//! General's flicks, send it to a corner, or into a side but for a sliver
//! — and a pinch sizes it about the pointer. Glides run on their own clock
//! at 120 a second: quick away and into a corner, a bounce back from a side.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const appkit = @import("../sys/appkit.zig");
const panel_mod = @import("float_panel.zig");
const Panel = panel_mod.Panel;

const CGRect = objc.CGRect;
const CGPoint = objc.CGPoint;

extern fn CGWarpMouseCursorPosition(point: CGPoint) i32;
extern fn CGAssociateMouseAndMouseCursorPosition(connected: u32) i32;

pub const Side = enum { left, right };
pub const Vec = struct { dx: f64 = 0, dy: f64 = 0 };

/// How much of it stays on screen, docked; how far the fingers go at the
/// side before letting go docks it; how much it gives while pulled there.
const sliver: f64 = 10;
const dock_at: f64 = 90;
const give: f64 = 0.35;

pub const State = struct {
    grabbing: bool = false,
    grab: CGPoint = .{ .x = 0, .y = 0 },
    origin: CGRect = .{},
    stretching: bool = false,
    ignoring_drag: bool = false,
    docked: ?Side = null,
    /// Where it was before it docked: where it goes back to.
    docked_from: ?CGPoint = null,
    pulling: ?Side = null,
    pull_from: CGPoint = .{ .x = 0, .y = 0 },
    swipe: Vec = .{},
    flicked: bool = false,
    /// For a wheel, which has no gesture to belong to: one flick a turn.
    last_wheel_flick: f64 = -100,
    pinching: f64 = 0,
    glide_from: CGPoint = .{ .x = 0, .y = 0 },
    glide_to: CGPoint = .{ .x = 0, .y = 0 },
    glide_elapsed: f64 = 0,
    glide_bounces: bool = false,
    gliding: bool = false,
    prev_after_frame_ctx: ?*anyopaque = null,
    prev_after_frame: ?*const fn (ctx: ?*anyopaque, s: *nanoui.Surface) bool = null,
};

/// Bumped to stop a pull's wait to settle.
var settles: usize = 0;

// MARK: where it goes (pure)

/// Where a flick sends a window of `frame`, a margin in from `area`'s
/// edges: a swipe clearly both ways takes it to the corner it points at; a
/// straighter one along its stronger direction, against the nearer edge.
pub fn corner(frame: CGRect, area: CGRect, way: Vec, margin: f64) CGPoint {
    const left = area.origin.x + margin;
    const right = area.origin.x + area.size.width - margin - frame.size.width;
    const bottom = area.origin.y + margin;
    const top = area.origin.y + area.size.height - margin - frame.size.height;
    const across = @abs(way.dx);
    const up = @abs(way.dy);
    const x = if (way.dx > 0) right else left;
    const y = if (way.dy > 0) top else bottom;
    if (@min(across, up) >= 0.4 * @max(across, up)) return .{ .x = x, .y = y };
    const mid_y = frame.origin.y + frame.size.height / 2;
    const mid_x = frame.origin.x + frame.size.width / 2;
    if (across >= up) return .{ .x = x, .y = if (mid_y > area.origin.y + area.size.height / 2) top else bottom };
    return .{ .x = if (mid_x > area.origin.x + area.size.width / 2) right else left, .y = y };
}

/// Where docking leaves it: off the side of `area`, but for a sliver.
pub fn docked(frame: CGRect, right: bool, area: CGRect) CGPoint {
    return .{ .x = if (right) area.origin.x + area.size.width - sliver else area.origin.x - frame.size.width + sliver, .y = frame.origin.y };
}

/// Whether it can go into that side of `area`: not where another screen
/// carries on, where it would only slide onto that one.
pub fn dockable(frame: CGRect, right: bool, area: CGRect, screens: []const CGRect) bool {
    const beyond: CGRect = .{ .origin = .{ .x = if (right) area.origin.x + area.size.width else area.origin.x - frame.size.width, .y = frame.origin.y }, .size = frame.size };
    for (screens) |s| if (!contains(s, area) and intersects(s, beyond)) return false;
    return true;
}

fn contains(outer: CGRect, inner: CGRect) bool {
    return inner.origin.x >= outer.origin.x and inner.origin.y >= outer.origin.y and
        inner.origin.x + inner.size.width <= outer.origin.x + outer.size.width and
        inner.origin.y + inner.size.height <= outer.origin.y + outer.size.height;
}

fn intersects(a: CGRect, b: CGRect) bool {
    const r = intersection(a, b);
    return r.size.width > 0 and r.size.height > 0;
}

pub fn intersection(a: CGRect, b: CGRect) CGRect {
    const x0 = @max(a.origin.x, b.origin.x);
    const y0 = @max(a.origin.y, b.origin.y);
    const x1 = @min(a.origin.x + a.size.width, b.origin.x + b.size.width);
    const y1 = @min(a.origin.y + a.size.height, b.origin.y + b.size.height);
    if (x1 <= x0 or y1 <= y0) return .{};
    return .{ .origin = .{ .x = x0, .y = y0 }, .size = .{ .width = x1 - x0, .height = y1 - y0 } };
}

// MARK: screens

/// The main screen's usable part, or nothing.
pub fn mainVisible() CGRect {
    const main = objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return .{};
    return objc.msg(CGRect, main, "visibleFrame", .{});
}

/// The usable part of the screen the window is on.
fn areaOf(p: *const Panel) CGRect {
    const s = objc.msg(?objc.Object, p.ns(), "screen", .{}) orelse return mainVisible();
    return objc.msg(CGRect, s, "visibleFrame", .{});
}

fn frameOf(p: *const Panel) CGRect {
    return objc.msg(CGRect, p.ns(), "frame", .{});
}

fn setOrigin(p: *const Panel, at: CGPoint) void {
    objc.msg(void, p.ns(), "setFrameOrigin:", .{at});
}

/// The side the window is up against, if it can go into it.
fn against(p: *const Panel) ?Side {
    const f = frameOf(p);
    const a = areaOf(p);
    var screens: [16]CGRect = undefined;
    const all = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const n = @min(screens.len, objc.msg(objc.NSUInteger, all, "count", .{}));
    for (0..n) |i| screens[i] = objc.msg(CGRect, objc.msg(objc.Object, all, "objectAtIndex:", .{i}), "frame", .{});
    if (f.origin.x + f.size.width >= a.origin.x + a.size.width - 16 and dockable(f, true, a, screens[0..n])) return .right;
    if (f.origin.x <= a.origin.x + 16 and dockable(f, false, a, screens[0..n])) return .left;
    return null;
}

/// Clearly sideways, and at that side.
fn outward(way: Vec, side: Side) bool {
    return @abs(way.dx) > @abs(way.dy) * 1.2 and (if (side == .right) way.dx > 0 else way.dx < 0);
}

/// Back towards the middle from the side it is docked at.
fn inward(m: *const State, way: Vec) bool {
    const d = m.docked orelse return false;
    return @abs(way.dx) > @abs(way.dy) and (if (d == .right) way.dx < 0 else way.dx > 0);
}

// MARK: the pointer

/// A press anywhere but on a button: on a docked sliver it comes back;
/// otherwise held, it drags — from the corner, it stretches.
pub fn pointer(p: *Panel, c: *ui.Context, it: ui.Interaction) void {
    const m = &p.m;
    if (!it.pressed) {
        m.grabbing = false;
        return;
    }
    if (!m.grabbing) {
        m.grabbing = true;
        if (m.docked != null) {
            undock(p);
            m.ignoring_drag = true;
            return;
        }
        m.ignoring_drag = false;
        stopGlide(p);
        m.grab = appkit.mouseLocation();
        m.origin = frameOf(p);
        m.stretching = c.input.mouse.x > c.size.w - 22 and c.input.mouse.y > c.size.h - 22;
        return;
    }
    if (m.ignoring_drag) return;
    const now = appkit.mouseLocation();
    const dx = now.x - m.grab.x;
    const dy = now.y - m.grab.y;
    if (!m.stretching) return setOrigin(p, .{ .x = m.origin.origin.x + dx, .y = m.origin.origin.y + dy });
    resize(p, m.origin.size.width + dx, m.origin, null);
}

/// Keeps the shape: a video window that can be squashed shows bars.
fn resize(p: *Panel, width: f64, was: CGRect, anchor: ?CGPoint) void {
    if (was.size.width <= 0) return;
    const screen_w = mainVisible().size.width;
    const limit = if (screen_w > 0) screen_w else 1600;
    const wide = @min(@max(panel_mod.min_size.width, width), limit * 0.85);
    const tall = wide * was.size.height / was.size.width;
    const spot: CGPoint = if (anchor) |a| .{
        .x = a.x - (a.x - was.origin.x) / was.size.width * wide,
        .y = a.y - (a.y - was.origin.y) / was.size.height * tall,
    } else .{ .x = was.origin.x, .y = was.origin.y + was.size.height - tall };
    objc.msg(void, p.ns(), "setFrame:display:", .{ CGRect{ .origin = spot, .size = .{ .width = wide, .height = tall } }, objc.NO });
}

// MARK: two fingers and a pinch (the panel's local monitor)

pub fn event(p: *Panel, ev: objc.Object) ?objc.Object {
    if (objc.msg(?objc.Object, ev, "window", .{}) != p.ns()) return ev;
    switch (objc.msg(objc.NSUInteger, ev, "type", .{})) {
        22 => scrollWheel(p, ev),
        30 => magnify(p, ev),
        else => return ev,
    }
    return null;
}

/// Two fingers move the window, the pointer carried with it so it never
/// falls out of the window mid-gesture.
fn scrollWheel(p: *Panel, ev: objc.Object) void {
    // Only while fingers are actually down: never the glide after them.
    if (objc.msg(objc.NSUInteger, ev, "momentumPhase", .{}) != 0) return;
    if (p.kea.prefs.float_flicks) return flickWheel(p, ev);
    if (p.m.docked != null) return undock(p);
    const dx = objc.msg(f64, ev, "scrollingDeltaX", .{});
    const dy = objc.msg(f64, ev, "scrollingDeltaY", .{});
    if (dx == 0 and dy == 0) return;
    const spot = frameOf(p).origin;
    setOrigin(p, .{ .x = spot.x + dx, .y = spot.y - dy });
    // Never the real pointer of a run that is hidden.
    if (p.hidden()) return;
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    if (objc.msg(objc.NSUInteger, screens, "count", .{}) == 0) return;
    const ground = objc.msg(CGRect, objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)}), "frame", .{});
    const mouse = appkit.mouseLocation();
    _ = CGWarpMouseCursorPosition(.{ .x = mouse.x + dx, .y = ground.size.height - (mouse.y - dy) });
    _ = CGAssociateMouseAndMouseCursorPosition(1);
}

/// NSEventPhase: began 1, ended 8, cancelled 16.
fn flickWheel(p: *Panel, ev: objc.Object) void {
    const m = &p.m;
    const sign: f64 = if (objc.msg(objc.BOOL, ev, "isDirectionInvertedFromDevice", .{})) 1 else -1;
    const step: Vec = .{ .dx = sign * objc.msg(f64, ev, "scrollingDeltaX", .{}), .dy = -sign * objc.msg(f64, ev, "scrollingDeltaY", .{}) };
    const phase = objc.msg(objc.NSUInteger, ev, "phase", .{});
    if (phase == 0) {
        // A mouse's wheel: every turn is a flick, a moment apart.
        const now = nanoui.ui.clock.now();
        if (now - m.last_wheel_flick <= 0.4 or (step.dx == 0 and step.dy == 0)) return;
        m.last_wheel_flick = now;
        if (m.docked != null) {
            if (inward(m, step)) undock(p);
        } else if (against(p)) |side| {
            if (outward(step, side)) dock(p, side, null) else flick(p, step);
        } else flick(p, step);
        return;
    }
    if (phase & 1 != 0) {
        m.swipe = .{};
        m.flicked = false;
        m.pulling = null;
        m.pull_from = frameOf(p).origin;
    }
    m.swipe.dx += step.dx;
    m.swipe.dy += step.dy;
    const lifted = phase & (8 | 16) != 0;
    // Docked: a swipe back towards the middle brings it out.
    if (m.docked != null) {
        if (!m.flicked and inward(m, m.swipe) and (@abs(m.swipe.dx) > 24 or lifted)) {
            m.flicked = true;
            undock(p);
        }
        if (lifted) {
            m.swipe = .{};
            m.flicked = false;
        }
        return;
    }
    // Against a side and swiped at it: it gives, heavily, and on lifting
    // goes into the side or springs back out.
    if (m.pulling == null and !m.flicked) if (against(p)) |side| if (outward(m.swipe, side) and @abs(m.swipe.dx) > 6) {
        m.pulling = side;
        stopGlide(p);
    };
    if (m.pulling != null) {
        setOrigin(p, .{ .x = m.pull_from.x + m.swipe.dx * give, .y = m.pull_from.y });
        // If nothing more comes, the pull is over anyway.
        settles +%= 1;
        objc.dispatchAfter(std.time.ns_per_s / 5, @ptrFromInt(settles), settleFired);
        if (lifted) letGo(p);
        return;
    }
    // Read from the whole swipe as the fingers lift; a long one doesn't wait.
    const length = std.math.hypot(m.swipe.dx, m.swipe.dy);
    if (!m.flicked and (length > 120 or (lifted and length > 20))) {
        m.flicked = true;
        flick(p, m.swipe);
    }
    if (lifted) {
        m.swipe = .{};
        m.flicked = false;
    }
}

fn settleFired(ctx: ?*anyopaque) callconv(.c) void {
    if (@intFromPtr(ctx) != settles) return;
    const p = current() orelse return;
    letGo(p);
}

fn current() ?*Panel {
    return panel_mod.currentPanel();
}

/// A pull at a side over: into the side, or back out.
fn letGo(p: *Panel) void {
    const m = &p.m;
    settles +%= 1;
    const side = m.pulling orelse return;
    if (outward(m.swipe, side) and @abs(m.swipe.dx) >= dock_at) dock(p, side, m.pull_from) else glide(p, m.pull_from, true);
    m.pulling = null;
    m.swipe = .{};
    m.flicked = false;
}

fn dock(p: *Panel, side: Side, from: ?CGPoint) void {
    p.m.docked_from = from orelse frameOf(p).origin;
    p.m.docked = side;
    glide(p, docked(frameOf(p), side == .right, areaOf(p)), false);
}

fn undock(p: *Panel) void {
    const back = p.m.docked_from orelse frameOf(p).origin;
    p.m.docked = null;
    p.m.docked_from = null;
    glide(p, back, true);
}

fn flick(p: *Panel, way: Vec) void {
    const target = corner(frameOf(p), areaOf(p), way, 12);
    const at = frameOf(p).origin;
    if (target.x == at.x and target.y == at.y) return;
    glide(p, target, false);
}

/// A pinch sizes it about the pointer, in steps of a fiftieth.
fn magnify(p: *Panel, ev: objc.Object) void {
    if (objc.msg(objc.NSUInteger, ev, "phase", .{}) == 1) p.m.pinching = 0;
    p.m.pinching += objc.msg(f64, ev, "magnification", .{});
    if (@abs(p.m.pinching) <= 0.02) return;
    const by = p.m.pinching;
    p.m.pinching = 0;
    const was = frameOf(p);
    resize(p, was.size.width * (1 + by), was, appkit.mouseLocation());
}

// MARK: the glide

fn glide(p: *Panel, to: CGPoint, bouncing: bool) void {
    const m = &p.m;
    m.glide_bounces = bouncing;
    m.glide_from = frameOf(p).origin;
    m.glide_to = to;
    m.glide_elapsed = 0;
    if (p.window.surface) |s| {
        if (s.visible()) {
            m.gliding = true;
            if (s.after_frame != glideAfterFrame) {
                m.prev_after_frame_ctx = s.after_frame_ctx;
                m.prev_after_frame = s.after_frame;
                s.after_frame_ctx = p;
                s.after_frame = glideAfterFrame;
            }
            s.requestFrame();
            return;
        }
    }
    m.gliding = false;
    setOrigin(p, to);
}

pub fn stopGlide(p: *Panel) void {
    const m = &p.m;
    if (m.gliding) {
        m.gliding = false;
        if (p.window.surface) |s| {
            if (s.after_frame == glideAfterFrame) {
                s.after_frame_ctx = m.prev_after_frame_ctx;
                s.after_frame = m.prev_after_frame;
            }
        }
    }
}

fn stepGlide(p: *Panel, elapsed: f64) bool {
    const m = &p.m;
    const t = @max(0, elapsed);
    var done = false;
    const progress: f64 = if (m.glide_bounces) blk: {
        // Underdamped: past the place, and back to it.
        const omega: f64 = 16;
        const zeta: f64 = 0.5;
        const damped = omega * @sqrt(1 - zeta * zeta);
        done = t > 0.9;
        break :blk if (done) 1 else 1 - @exp(-zeta * omega * t) * (@cos(damped * t) + zeta / @sqrt(1 - zeta * zeta) * @sin(damped * t));
    } else blk: {
        const omega: f64 = 15;
        done = t > 0.6;
        break :blk if (done) 1 else 1 - (1 + omega * t) * @exp(-omega * t);
    };
    setOrigin(p, .{ .x = m.glide_from.x + (m.glide_to.x - m.glide_from.x) * progress, .y = m.glide_from.y + (m.glide_to.y - m.glide_from.y) * progress });
    return done;
}

fn glideAfterFrame(ctx: ?*anyopaque, s: *nanoui.Surface) bool {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    const m = &p.m;
    const changed = if (m.prev_after_frame) |af| af(m.prev_after_frame_ctx, s) else false;
    if (!m.gliding) return changed;
    m.glide_elapsed += @min(@as(f64, s.ctx.dt), 1.0 / 30.0);
    if (stepGlide(p, m.glide_elapsed)) {
        stopGlide(p);
    } else {
        s.ctx.animating = true;
    }
    return changed;
}

test "a flick goes to the corner it points at, or along its stronger way" {
    const area_: CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1000, .height = 800 } };
    const f: CGRect = .{ .origin = .{ .x = 100, .y = 100 }, .size = .{ .width = 200, .height = 100 } };
    const tr = corner(f, area_, .{ .dx = 10, .dy = 10 }, 12);
    try std.testing.expectEqual(@as(f64, 788), tr.x);
    try std.testing.expectEqual(@as(f64, 688), tr.y);
    // Straight right, low on the screen: the bottom right.
    const r = corner(f, area_, .{ .dx = 10, .dy = 1 }, 12);
    try std.testing.expectEqual(@as(f64, 788), r.x);
    try std.testing.expectEqual(@as(f64, 12), r.y);
    // Straight up, on the left: the top left.
    const u = corner(f, area_, .{ .dx = 0, .dy = 5 }, 12);
    try std.testing.expectEqual(@as(f64, 12), u.x);
    try std.testing.expectEqual(@as(f64, 688), u.y);
}

test "docked leaves a sliver, and not where another screen carries on" {
    const area_: CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1000, .height = 800 } };
    const f: CGRect = .{ .origin = .{ .x = 780, .y = 100 }, .size = .{ .width = 200, .height = 100 } };
    try std.testing.expectEqual(@as(f64, 990), docked(f, true, area_).x);
    try std.testing.expectEqual(@as(f64, -190), docked(f, false, area_).x);
    const right_screen: CGRect = .{ .origin = .{ .x = 1000, .y = 0 }, .size = .{ .width = 1000, .height = 800 } };
    try std.testing.expect(dockable(f, true, area_, &.{area_}));
    try std.testing.expect(!dockable(f, true, area_, &.{ area_, right_screen }));
    try std.testing.expect(dockable(f, false, area_, &.{ area_, right_screen }));
}
