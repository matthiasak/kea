//! The floating window (Float.swift `Float`): a borderless panel above every
//! window, on every Space, that takes clicks without bringing the app
//! forward, holding the page through its own `StageHost`. Its controls —
//! close, back to the tab, ⟲15, play/pause, 15⟳ and a progress line — show
//! only while the pointer is over it; every other press, drag, two-finger
//! swipe and pinch moves or sizes the window (`float_moves.zig`). A hidden
//! run's sits off every screen and is never remembered (`benchAway`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Kea = @import("../app/kea.zig").Kea;
const StageHost = @import("stage_host.zig").StageHost;
const appkit = @import("../sys/appkit.zig");
const moves = @import("float_moves.zig");

const gpa = std.heap.c_allocator;
const CGRect = objc.CGRect;
const CGPoint = objc.CGPoint;

extern fn NSStringFromRect(rect: CGRect) objc.Object;
extern fn NSRectFromString(string: objc.Object) CGRect;

/// What the buttons and the ticker ask of the window whose video it is.
pub const Calls = struct {
    ctx: *anyopaque,
    close: *const fn (*anyopaque) void,
    back: *const fn (*anyopaque) void,
    skip: *const fn (*anyopaque, f64) void,
    progress: *const fn (*anyopaque) void,
    play_pause: *const fn (*anyopaque) void,
};

pub const Panel = struct {
    kea: *Kea,
    window: *nanoui.Window,
    host: ?*StageHost = null,
    /// The page, its tab's (not retained).
    page: objc.Object,
    /// The wash at the top and bottom (`scrim`), retained.
    scrim: objc.Object,
    watch: objc.Object,
    monitor: ?objc.Object = null,
    calls: Calls,
    playing: bool = true,
    /// Nought to one, the hairline along the bottom edge.
    progress: f64 = 0,
    /// The pointer is over the window: the controls are up.
    near: bool = false,
    /// `drop` let go of the page before the window closed.
    dropping: bool = false,
    released: bool = false,
    /// What the hidden and the moved window needs (`float_moves.zig`).
    m: moves.State = .{},

    pub fn ns(p: *const Panel) objc.Object {
        return p.window.nswindow;
    }

    pub fn hidden(p: *const Panel) bool {
        return p.kea.opts.hidden;
    }

    /// Where the window is, or was before it was docked at a side.
    pub fn restingFrame(p: *const Panel) CGRect {
        var f = objc.msg(CGRect, p.ns(), "frame", .{});
        if (p.m.docked_from) |home| f.origin = home;
        return f;
    }
};

var current: ?*Panel = null;
/// Bumped as a window goes, so its ticker stops.
var ticks: usize = 0;

pub fn showing() bool {
    return current != null;
}

pub fn currentPanel() ?*Panel {
    return current;
}

const size: objc.CGSize = .{ .width = 440, .height = 247 };
pub const min_size: objc.CGSize = .{ .width = 260, .height = 146 };

/// `lift`: the page out of its window and into a new floating one, at
/// the place and size it had last if a screen still shows it.
pub fn lift(kea: *Kea, page: objc.Object, calls: Calls) void {
    if (current != null) return;
    const app = kea.ui_app orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const screen = moves.mainVisible();
    var spot = remembered(kea) orelse CGRect{
        .origin = .{ .x = screen.origin.x + screen.size.width - size.width - 24, .y = screen.origin.y + 24 },
        .size = size,
    };
    if (kea.opts.hidden) spot.origin = .{ .x = -20000, .y = -20000 };

    const p = gpa.create(Panel) catch return;
    const win = app.newWindow(.{
        .width = spot.size.width,
        .height = spot.size.height,
        .min_width = min_size.width,
        .min_height = min_size.height,
        .visible = false,
        .kind = .panel,
        .floating = true,
        .all_spaces = true,
        .non_activating = true,
        // Titled, so it becomes key (gestures reach it), its bar out of sight.
        .title_bar = .hidden,
        .on_close = .{ .ctx = p, .func = closed },
        .content = .{ .view = ui.View.init(p, view) },
    }) catch return gpa.destroy(p);
    const w = win.nswindow;
    p.* = .{ .kea = kea, .window = win, .page = page, .scrim = makeScrim(), .watch = objc.msg(objc.Object, watchClass(), "new", .{}), .calls = calls };
    current = p;
    // Swift's is a borderless panel subclass that may become key; a titled
    // panel already may, so its bar and buttons are only put out of sight.
    for (0..3) |i| if (objc.msg(?objc.Object, w, "standardWindowButton:", .{@as(objc.NSUInteger, i)})) |light|
        objc.msg(void, light, "setHidden:", .{objc.YES});
    objc.msg(void, w, "setFrame:display:", .{ spot, objc.NO });
    objc.msg(void, w, "setBackgroundColor:", .{objc.msg(objc.Object, objc.class("NSColor"), "clearColor", .{})});
    objc.msg(void, w, "setOpaque:", .{objc.NO});
    // No shadow: without one the video goes straight to the display.
    objc.msg(void, w, "setHasShadow:", .{objc.NO});
    objc.msg(void, w, "setCanHide:", .{!kea.opts.hidden});
    objc.msg(void, w, "setAspectRatio:", .{size});
    objc.msg(void, w, "setMinSize:", .{min_size});
    // The ground: black, its corners round, the page and the controls in it.
    const content = objc.msg(objc.Object, w, "contentView", .{});
    objc.msg(void, content, "setWantsLayer:", .{objc.YES});
    if (objc.msg(?objc.Object, content, "layer", .{})) |layer| {
        objc.msg(void, layer, "setBackgroundColor:", .{objc.msg(?*anyopaque, objc.msg(objc.Object, objc.class("NSColor"), "blackColor", .{}), "CGColor", .{})});
        objc.msg(void, layer, "setCornerRadius:", .{@as(f64, 14)});
        objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    }

    // WebKit's own pinch would zoom the page instead of sizing the window.
    objc.msg(void, page, "setAllowsMagnification:", .{objc.NO});
    if (win.surface) |s| {
        const host = StageHost.create(gpa, s) catch null;
        p.host = host;
        if (host) |h| {
            h.setPage(page, false);
            if (objc.msg(?objc.Object, h.stage_view, "layer", .{})) |layer| {
                objc.msg(void, p.scrim, "setFrame:", .{objc.msg(CGRect, layer, "bounds", .{})});
                objc.msg(void, layer, "addSublayer:", .{p.scrim});
            }
        }
        s.frame();
    }
    // Kept once a move or a resize is over, and as the app quits with it open.
    objc.setZig(p.watch, p);
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    objc.msg(void, center, "addObserver:selector:name:object:", .{ p.watch, objc.sel("keep:"), objc.nsString("NSWindowDidEndLiveResizeNotification"), w });
    objc.msg(void, center, "addObserver:selector:name:object:", .{ p.watch, objc.sel("keep:"), objc.nsString("NSApplicationWillTerminateNotification"), app.nsapp });
    // Two fingers and a pinch are the window's, never the page's.
    p.monitor = appkit.addLocalMonitor((1 << 22) | (1 << 30), p, moves.event);
    if (!kea.opts.hidden) objc.msg(void, w, "orderFrontRegardless", .{});
    ticks +%= 1;
    objc.dispatchAfter(std.time.ns_per_s / 2, @ptrFromInt(ticks), tick);
}

/// Puts the page down and closes; whoever owns the page takes it back on
/// their next layout.
pub fn drop() void {
    const p = current orelse return;
    p.dropping = true;
    release(p);
    p.window.close();
}

/// The page let go and everything listening stopped, once.
fn release(p: *Panel) void {
    if (p.released) return;
    p.released = true;
    remember(p.kea, p.restingFrame());
    ticks +%= 1;
    moves.stopGlide(p);
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    objc.msg(void, center, "removeObserver:", .{p.watch});
    objc.setZig(p.watch, null);
    if (p.monitor) |m| appkit.removeMonitor(m);
    p.monitor = null;
    objc.msg(void, p.page, "setAllowsMagnification:", .{objc.YES});
    if (p.host) |h| h.forget(p.page);
    objc.msg(void, p.scrim, "removeFromSuperlayer", .{});
}

/// The window is going (`on_close`): its stage with it. Closed some other
/// way than `drop` — the app quitting — the window whose video it was
/// still lands it.
fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    release(p);
    if (p.host) |h| h.destroy();
    objc.release(p.scrim);
    objc.release(p.watch);
    if (current == p) current = null;
    const calls = p.calls;
    const dropping = p.dropping;
    gpa.destroy(p);
    if (!dropping) calls.close(calls.ctx);
}

/// Every half second: a window no longer holding the page goes, and the
/// line along the bottom is asked for.
fn tick(ctx: ?*anyopaque) callconv(.c) void {
    if (@intFromPtr(ctx) != ticks) return;
    const p = current orelse return;
    const host = p.host orelse return;
    if (objc.msg(?objc.Object, p.page, "superview", .{}) != host.stage_view) return p.calls.close(p.calls.ctx);
    p.calls.progress(p.calls.ctx);
    objc.dispatchAfter(std.time.ns_per_s / 2, @ptrFromInt(ticks), tick);
}

/// What `where_` found.
pub fn progressed(through: f64, playing: bool) void {
    const p = current orelse return;
    const clamped = std.math.clamp(through, 0, 1);
    const changed = p.playing != playing or @abs(p.progress - clamped) >= 0.002;
    p.progress = clamped;
    p.playing = playing;
    if (changed) p.window.redraw();
}

/// What play/pause left it as.
pub fn played(playing: bool) void {
    const p = current orelse return;
    p.playing = playing;
    p.window.redraw();
}

// MARK: remembered

/// The window's last place and size, given back only while a screen still
/// shows most of it (`float.frame`).
fn remembered(kea: *Kea) ?CGRect {
    const text = kea.store.string("float.frame") orelse return null;
    defer kea.store.gpa.free(text);
    const frame = NSRectFromString(objc.nsString(text));
    if (frame.size.width <= 100) return null;
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    for (0..objc.msg(objc.NSUInteger, screens, "count", .{})) |i| {
        const seen = moves.intersection(objc.msg(CGRect, objc.msg(objc.Object, screens, "objectAtIndex:", .{i}), "visibleFrame", .{}), frame);
        if (seen.size.width * seen.size.height > 0.6 * frame.size.width * frame.size.height) return frame;
    }
    return null;
}

fn remember(kea: *Kea, frame: CGRect) void {
    if (kea.opts.hidden) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    kea.store.setString("float.frame", objc.fromNSString(NSStringFromRect(frame)));
}

fn keep(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const p = objc.getZig(Panel, self) orelse return;
    remember(p.kea, p.restingFrame());
}

fn watchClass() objc.Class {
    return objc.defineClass(.{ .name = "KeaFloatWatch", .methods = &.{.{ .name = "keep:", .imp = &keep, .types = "v@:@" }} });
}

/// A wash at the top and bottom, so white buttons hold against a bright
/// frame of film without covering it; faded in with the controls.
fn makeScrim() objc.Object {
    const layer = objc.msg(objc.Object, objc.class("CAGradientLayer"), "new", .{});
    const colors = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for ([_]f64{ 0.45, 0, 0, 0.5 }) |a| {
        const c = objc.msg(objc.Object, objc.class("NSColor"), "colorWithWhite:alpha:", .{ @as(f64, 0), a });
        objc.msg(void, colors, "addObject:", .{objc.msg(objc.Object, c, "CGColor", .{})});
    }
    objc.msg(void, layer, "setColors:", .{colors});
    const locations = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for ([_]f64{ 0, 0.28, 0.66, 1 }) |l| objc.msg(void, locations, "addObject:", .{objc.msg(objc.Object, objc.class("NSNumber"), "numberWithDouble:", .{l})});
    objc.msg(void, layer, "setLocations:", .{locations});
    // As in Swift's unflipped view, the first colour at the bottom of this
    // flipped stage.
    objc.msg(void, layer, "setStartPoint:", .{CGPoint{ .x = 0.5, .y = 1 }});
    objc.msg(void, layer, "setEndPoint:", .{CGPoint{ .x = 0.5, .y = 0 }});
    objc.msg(void, layer, "setOpacity:", .{@as(f32, 0)});
    // kCALayerWidthSizable | kCALayerHeightSizable.
    objc.msg(void, layer, "setAutoresizingMask:", .{@as(c_uint, 2 | 16)});
    objc.msg(void, layer, "setZPosition:", .{@as(f64, 1)});
    return layer;
}

fn fadeScrim(p: *Panel, to: f32) void {
    const tx = objc.class("CATransaction");
    objc.msg(void, tx, "begin", .{});
    objc.msg(void, tx, "setAnimationDuration:", .{@as(f64, 0.16)});
    objc.msg(void, p.scrim, "setOpacity:", .{to});
    objc.msg(void, tx, "commit", .{});
}

// MARK: the controls

fn px(v: f32) ui.Length {
    return .{ .px = v };
}

const glass = ui.Color.white.mix(ui.Color.black, 0.9).alpha(0.55);

fn view(p: *Panel, c: *ui.Context) void {
    // Drawn first inside `newWindow`, before the panel is filled in.
    if (current != p) return;
    const root = c.open(.{ .width = .fill, .height = .fill }, "kea.float");
    defer c.end();
    c.addStageHoleNode(root);
    // Everything reaches this layer: the page under it never sees a press.
    const it = c.interact(root, .{});
    c.cursor_hand = false;
    c.hand_cursor = false;
    // The stretch corner's cursor rect (Float.swift `resetCursorRects`):
    // followed move by move while the pointer is over the panel.
    c.wants_moves = it.hovered;
    const m = c.input.mouse;
    if (it.hovered and m.x > c.size.w - 22 and m.y > c.size.h - 22) c.cursor = .crosshair;
    if (it.hovered != p.near) {
        p.near = it.hovered;
        fadeScrim(p, if (p.near) 1 else 0);
    }
    const fade = ui.tween(c, it.id, 0, if (p.near) 1 else 0, 0.16, .ease_in_out);
    moves.pointer(p, c, it);
    if (fade <= 0) return;
    const w = c.size.w;
    const h = c.size.h;
    const mid_x = w / 2;
    const mid_y = h / 2;
    // Out of the frame: either closes the window this frame is drawing.
    if (button(c, p, "xmark", 11, 30, 14, 14, fade)) objc.dispatchMain(p, pressedClose);
    if (button(c, p, "arrow.up.forward", 12, 30, w - 44, 14, fade)) objc.dispatchMain(p, pressedReturn);
    if (button(c, p, "gobackward.15", 15, 38, mid_x - 25 - 54, mid_y - 19, fade)) p.calls.skip(p.calls.ctx, -15);
    if (button(c, p, if (p.playing) "pause.fill" else "play.fill", 17, 50, mid_x - 25, mid_y - 25, fade)) {
        p.playing = !p.playing;
        p.calls.play_pause(p.calls.ctx);
    }
    if (button(c, p, "goforward.15", 15, 38, mid_x + 25 + 16, mid_y - 19, fade)) p.calls.skip(p.calls.ctx, 15);
    // How far through, along the bottom edge: quiet enough to ignore.
    _ = c.open(.{ .absolute = true, .offset = .{ .y = h - 3 }, .width = px(w), .height = px(3), .background = ui.Color.white.alpha(0.22), .opacity = fade }, null);
    _ = c.leaf(.{ .width = px(w * @as(f32, @floatCast(p.progress))), .height = .fill, .background = ui.Color.white.alpha(0.85) }, .none, null);
    c.end();
}

fn pressedClose(ctx: ?*anyopaque) callconv(.c) void {
    const p = current orelse return;
    if (@as(?*anyopaque, p) == ctx) p.calls.close(p.calls.ctx);
}

fn pressedReturn(ctx: ?*anyopaque) callconv(.c) void {
    const p = current orelse return;
    if (@as(?*anyopaque, p) == ctx) p.calls.back(p.calls.ctx);
}

/// A round button of `side` points with its symbol, at (x, y) from the
/// top left; it answers only while the controls are up.
fn button(c: *ui.Context, p: *Panel, symbol: []const u8, symbol_size: f32, side: f32, x: f32, y: f32, fade: f32) bool {
    const i = c.open(.{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = px(side),
        .height = px(side),
        .radius = side / 2,
        .corner_circular = true,
        .background = glass,
        .opacity = fade,
        .align_items = .center,
        .justify = .center,
    }, null);
    defer c.end();
    ui.icon(c, symbol, .{ .size = symbol_size, .weight = .medium, .color = ui.Color.white });
    if (!p.near) return false;
    return c.interact(i, .{}).clicked;
}
