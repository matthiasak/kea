//! The traffic lights (`Lights.swift`), where a Mac app with a toolbar has
//! them — set in from the corner and centred in the strip's height — without
//! the toolbar, whose rounder corners Kea doesn't want. AppKit lays its title
//! bar out again whenever it sees fit (a resize, full screen, the window
//! becoming key), so every time it does, the buttons are put back.
//!
//! And the resting ones (`RestingLights`, Stage.swift; `measureLights`,
//! App.swift): the three as they look while the app isn't the one in use,
//! drawn in `Palette.resting` exactly over the real ones, since macOS's own
//! come out nearly white on a light window.
//!
//! And `DragStrip` (Stage.swift): the empty chrome the window is moved by.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const metrics = @import("../design/metrics.zig");
const palette = @import("../design/palette.zig");
const Prefs = @import("../data/prefs.zig").Prefs;
const Browser = @import("../model/browser.zig").Browser;

const CGRect = objc.CGRect;
const CGPoint = objc.CGPoint;
const CGSize = objc.CGSize;

/// `DragStrip`: empty chrome that moves the window. A double click opens a
/// new tab where the strip is an empty tab row (`onDoubleClick`), and
/// otherwise does what a title bar's does (System Settings › Desktop &
/// Dock): minimize, nothing, or fill the screen.
pub fn dragStrip(b: *Browser, c: *ui.Context, style: ui.Style, on_double: enum { zoom, new_tab }) void {
    var s = style;
    s.window_drag = true;
    const i = c.open(s, null);
    c.end();
    const it = c.interact(i, .{});
    if (!it.double_clicked) return;
    switch (on_double) {
        .new_tab => b.newTab(),
        .zoom => if (b.window) |w| switch (titleBarAction()) {
            .minimize => w.minimize(),
            .none => {},
            .zoom => w.zoom(),
        },
    }
}

pub const TitleBarAction = enum { minimize, none, zoom };

/// `AppleActionOnDoubleClick`: unset means the default, which fills the screen.
pub fn titleBarActionFor(value: ?[]const u8) TitleBarAction {
    const v = value orelse return .zoom;
    if (std.mem.eql(u8, v, "Minimize")) return .minimize;
    if (std.mem.eql(u8, v, "None")) return .none;
    return .zoom;
}

fn titleBarAction() TitleBarAction {
    const pool = objc.Pool.push();
    defer pool.pop();
    const defaults = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
    const s = objc.msg(?objc.Object, defaults, "stringForKey:", .{objc.nsString("AppleActionOnDoubleClick")}) orelse return .zoom;
    const utf8 = objc.msg(?[*:0]const u8, s, "UTF8String", .{}) orelse return .zoom;
    return titleBarActionFor(std.mem.span(utf8));
}

test "a title bar's double click follows AppleActionOnDoubleClick" {
    try std.testing.expectEqual(TitleBarAction.zoom, titleBarActionFor(null));
    try std.testing.expectEqual(TitleBarAction.minimize, titleBarActionFor("Minimize"));
    try std.testing.expectEqual(TitleBarAction.none, titleBarActionFor("None"));
    try std.testing.expectEqual(TitleBarAction.zoom, titleBarActionFor("Maximize"));
}

/// Where the close button's centre goes, from the window's top-left: where a
/// unified toolbar put it, which `metrics.lights` and `side_lights` measure from.
pub const centre: CGPoint = .{ .x = 26, .y = 26 };

// MARK: placement (pure)

/// AppKit's own spacing, read once from its first layout: read on every pass
/// it was caught halfway through AppKit's own re-layout and the three closed up.
pub fn keptSpacing(measured: f64) f64 {
    return if (measured >= 16 and measured <= 32) measured else 20;
}

/// The close button's centre x: past a column on the right, else the corner's.
pub fn centreX(side_right: bool, window_width: f64, side_width: f64) f64 {
    return if (side_right) window_width - side_width + centre.x else centre.x;
}

/// Button `index`'s origin in a title bar `bar_height` tall (AppKit, y up).
pub fn origin(index: usize, centre_x: f64, spacing: f64, size: CGSize, bar_height: f64) CGPoint {
    return .{
        .x = centre_x - size.width / 2 + @as(f64, @floatFromInt(index)) * spacing,
        .y = bar_height - centre.y - size.height / 2,
    };
}

/// The title-bar container as tall as the strip, along the window's top
/// edge; null when it already is.
pub fn containerFrame(frame: CGRect, window_height: f64) ?CGRect {
    const height: f64 = metrics.strip;
    if (frame.size.height == height and frame.origin.y + frame.size.height == window_height) return null;
    var f = frame;
    f.size.height = height;
    f.origin.y = window_height - height;
    return f;
}

/// Full screen keeps its title bar in a window of its own, laid out by macOS.
pub fn placeable(style_mask: objc.NSUInteger) bool {
    return style_mask & (1 << 14) == 0;
}

// MARK: one window's lights

pub const Lights = struct {
    gpa: std.mem.Allocator,
    window: objc.Object,
    prefs: *const Prefs,
    observer: objc.Object,
    resting: ?objc.Object = null,
    spots: [3]CGRect = @splat(.{}),
    spacing: f64,
    placing: bool = false,
    /// The centre x last placed at, so a column moved re-places once.
    placed_x: f64 = -1,

    /// Starts looking after `window`'s lights (`Lights.keep` + `dress`).
    pub fn keep(gpa: std.mem.Allocator, window: objc.Object, prefs: *const Prefs) !*Lights {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try gpa.create(Lights);
        const b = buttons(window);
        const measured = if (b[0] != null and b[1] != null) frameOf(b[1].?).origin.x - frameOf(b[0].?).origin.x else 0;
        self.* = .{
            .gpa = gpa,
            .window = window,
            .prefs = prefs,
            .observer = objc.msg(objc.Object, observerClass(), "new", .{}),
            .spacing = keptSpacing(measured),
        };
        objc.setZig(self.observer, self);
        const center = notificationCenter();
        for ([_][]const u8{
            "NSWindowDidResizeNotification",         "NSWindowDidEndLiveResizeNotification",
            "NSWindowDidBecomeKeyNotification",      "NSWindowDidResignKeyNotification",
            "NSWindowDidExitFullScreenNotification", "NSWindowDidChangeScreenNotification",
        }) |name| observe(center, self.observer, name, window);
        // The title bar's own views moving is the surest sign AppKit has just
        // laid them out again.
        if (b[0]) |close| if (superview(close)) |bar| if (superview(bar)) |container| {
            for ([_]?objc.Object{ container, bar, b[0], b[1], b[2] }) |v| if (v) |view| {
                objc.msg(void, view, "setPostsFrameChangedNotifications:", .{objc.YES});
                observe(center, self.observer, "NSViewFrameDidChangeNotification", view);
            };
            // The content view fills the window, title bar included, and Core
            // Animation drew it over the buttons: told directly (`dress`).
            if (objc.msg(?objc.Object, window, "contentView", .{})) |content| if (superview(content)) |frame| {
                objc.msg(void, frame, "addSubview:positioned:relativeTo:", .{ container, @as(objc.NSInteger, 1), content });
                objc.msg(void, container, "setWantsLayer:", .{objc.YES});
                if (objc.msg(?objc.Object, container, "layer", .{})) |layer| objc.msg(void, layer, "setZPosition:", .{@as(f64, 10)});
            };
        };
        self.place();
        return self;
    }

    pub fn drop(self: *Lights) void {
        objc.msg(void, notificationCenter(), "removeObserver:", .{self.observer});
        objc.setZig(self.observer, null);
        objc.release(self.observer);
        if (self.resting) |v| {
            objc.setZig(v, null);
            objc.msg(void, v, "removeFromSuperview", .{});
            objc.release(v);
        }
        self.gpa.destroy(self);
    }

    /// The column moved or changed sides (`Lights.refresh` on the sidebar's
    /// prefs): placed again when the centre it wants differs.
    pub fn follow(self: *Lights) void {
        if (self.wantX() != self.placed_x) self.place();
    }

    /// The app came forward (true) or stepped away: the resting circles go
    /// off or on, over the buttons where they are now.
    pub fn appActive(self: *Lights, active: bool) void {
        self.measure();
        if (self.resting) |v| objc.msg(void, v, "setHidden:", .{active});
    }

    fn wantX(self: *const Lights) f64 {
        const p = self.prefs;
        return centreX(p.sidebar and p.side_position == .right, frameOf(self.window).size.width, p.side_width);
    }

    fn place(self: *Lights) void {
        if (self.placing or !placeable(objc.msg(objc.NSUInteger, self.window, "styleMask", .{}))) return;
        const b = buttons(self.window);
        for (b) |x| if (x == null) return;
        const bar = superview(b[0].?) orelse return;
        const container = superview(bar) orelse return;
        self.placing = true;
        defer self.placing = false;
        // A title bar as tall as the strip, so the buttons can sit lower in it.
        if (containerFrame(frameOf(container), frameOf(self.window).size.height)) |f| objc.msg(void, container, "setFrame:", .{f});
        // Only the row moves; the spacing is AppKit's, from its first layout.
        const x = self.wantX();
        self.placed_x = x;
        const bar_height = objc.msg(CGRect, bar, "bounds", .{}).size.height;
        for (b, 0..) |button, i| {
            const f = frameOf(button.?);
            const o = origin(i, x, self.spacing, f.size, bar_height);
            if (f.origin.x != o.x or f.origin.y != o.y) objc.msg(void, button.?, "setFrameOrigin:", .{o});
        }
        self.measure();
    }

    /// `measureLights`: the resting circles in the title bar, over the buttons.
    fn measure(self: *Lights) void {
        const b = buttons(self.window);
        const close = b[0] orelse return;
        const titlebar = superview(close) orelse return;
        const view = self.resting orelse blk: {
            const v = objc.msg(objc.Object, objc.msg(objc.Object, restingClass(), "alloc", .{}), "initWithFrame:", .{CGRect{}});
            objc.setZig(v, self);
            self.resting = v;
            break :blk v;
        };
        if (superview(view) != titlebar) {
            objc.msg(void, view, "setFrame:", .{objc.msg(CGRect, titlebar, "bounds", .{})});
            objc.msg(void, view, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)}); // width, height
            objc.msg(void, titlebar, "addSubview:positioned:relativeTo:", .{ view, @as(objc.NSInteger, 1), @as(?objc.Object, null) });
        }
        var spots = self.spots;
        for (b, 0..) |button, i| if (button) |v| {
            spots[i] = objc.msg(CGRect, v, "convertRect:toView:", .{ objc.msg(CGRect, v, "bounds", .{}), titlebar });
        };
        if (!std.mem.eql(u8, std.mem.asBytes(&spots), std.mem.asBytes(&self.spots))) {
            self.spots = spots;
            objc.msg(void, view, "setNeedsDisplay:", .{objc.YES});
        }
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        objc.msg(void, view, "setHidden:", .{objc.msg(objc.BOOL, nsapp, "isActive", .{})});
    }
};

fn buttons(window: objc.Object) [3]?objc.Object {
    var out: [3]?objc.Object = undefined;
    for (&out, 0..) |*b, i| b.* = objc.msg(?objc.Object, window, "standardWindowButton:", .{@as(objc.NSUInteger, i)});
    return out;
}

fn superview(v: objc.Object) ?objc.Object {
    return objc.msg(?objc.Object, v, "superview", .{});
}

fn frameOf(v: objc.Object) CGRect {
    return objc.msg(CGRect, v, "frame", .{});
}

fn notificationCenter() objc.Object {
    return objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
}

fn observe(center: objc.Object, observer: objc.Object, name: []const u8, object: objc.Object) void {
    objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("place:"), objc.nsString(name), object });
}

fn observerClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigLights",
        .methods = &.{.{ .name = "place:", .imp = &placeNote, .types = "v@:@" }},
    });
}

fn placeNote(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const l = objc.getZig(Lights, self_obj) orelse return;
    l.place();
}

fn restingClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigRestingLights",
        .superclass = "NSView",
        .methods = &.{
            .{ .name = "drawRect:", .imp = &drawResting, .types = "v@:{CGRect={CGPoint=dd}{CGSize=dd}}" },
            .{ .name = "hitTest:", .imp = &hitNothing, .types = "@@:{CGPoint=dd}" },
        },
    });
}

/// Never in the way of a click: the real buttons are underneath.
fn hitNothing(_: objc.Object, _: objc.SEL, _: CGPoint) callconv(.c) ?objc.Object {
    return null;
}

fn drawResting(self_obj: objc.Object, _: objc.SEL, _: CGRect) callconv(.c) void {
    const l = objc.getZig(Lights, self_obj) orelse return;
    const c = palette.get(isDark(self_obj)).resting;
    const color = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, c.r), @as(f64, c.g), @as(f64, c.b), @as(f64, 1),
    });
    objc.msg(void, color, "setFill", .{});
    for (l.spots) |spot| {
        if (spot.size.width == 0) continue;
        objc.msg(void, objc.msg(objc.Object, objc.class("NSBezierPath"), "bezierPathWithOvalInRect:", .{spot}), "fill", .{});
    }
}

fn isDark(view: objc.Object) bool {
    const names = [_]objc.Object{ objc.nsString("NSAppearanceNameAqua"), objc.nsString("NSAppearanceNameDarkAqua") };
    const list = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObjects:count:", .{ &names, @as(objc.NSUInteger, names.len) });
    const appearance = objc.msg(objc.Object, view, "effectiveAppearance", .{});
    const best = objc.msg(?objc.Object, appearance, "bestMatchFromAppearancesWithNames:", .{list}) orelse return false;
    return objc.msg(objc.BOOL, best, "isEqualToString:", .{names[1]});
}

// MARK: tests

const testing = std.testing;

test "lights sit at the corner with the column on the left" {
    const x = centreX(false, 1440, 232);
    try testing.expectEqual(@as(f64, 26), x);
    // AppKit's 14 pt buttons, 20 apart, in the 52 pt bar.
    const s: CGSize = .{ .width = 14, .height = 16 };
    try testing.expectEqual(CGPoint{ .x = 19, .y = 18 }, origin(0, x, 20, s, 52));
    try testing.expectEqual(CGPoint{ .x = 39, .y = 18 }, origin(1, x, 20, s, 52));
    try testing.expectEqual(CGPoint{ .x = 59, .y = 18 }, origin(2, x, 20, s, 52));
}

test "lights move past a column on the right" {
    const x = centreX(true, 1440, 232);
    try testing.expectEqual(@as(f64, 1440 - 232 + 26), x);
    try testing.expectEqual(@as(f64, 1234 - 7 + 2 * 23), origin(2, x, 23, .{ .width = 14, .height = 16 }, 52).x);
}

test "lights leave full screen to macOS and keep a sane spacing" {
    try testing.expect(placeable(1 | 2 | 4 | 8 | (1 << 15)));
    try testing.expect(!placeable(1 | (1 << 14)));
    try testing.expectEqual(@as(f64, 23), keptSpacing(23));
    try testing.expectEqual(@as(f64, 20), keptSpacing(13));
    try testing.expectEqual(@as(f64, 20), keptSpacing(0));
}

test "title-bar container grows to the strip along the top" {
    const f = containerFrame(.{ .origin = .{ .y = 752 }, .size = .{ .width = 1180, .height = 28 } }, 780).?;
    try testing.expectEqual(@as(f64, 52), f.size.height);
    try testing.expectEqual(@as(f64, 728), f.origin.y);
    try testing.expect(containerFrame(f, 780) == null);
}
