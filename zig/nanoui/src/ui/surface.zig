//! The connection between a window and its native UI: an NSView hosting
//! the Metal layer, drawing frames on demand (its events: surface_events.zig).
//! Nothing polls: a frame runs on input, on resize, or while an animation
//! moves, at most every display refresh.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");
const metal = @import("metal.zig");
const text = @import("text.zig");
const frame_mod = @import("frame.zig");
const textinput = @import("textinput.zig");
const Theme = @import("theme.zig").Theme;
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const ui = @import("ui.zig");
const Window = @import("../window.zig").Window;
const a11y = @import("a11y.zig");
const events = @import("surface_events.zig");
const frame_log_mod = @import("frame_log.zig");
pub const FrameLog = frame_log_mod.FrameLog;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: *Window,
    nsview: objc.Object,
    tracking: ?objc.Object = null,
    renderer: metal.Renderer,
    text: text.TextSystem,
    /// Built with `-Dportable=true`: the atlas nanoui rasterized, uploaded.
    atlas_texture: ?objc.Object = null,
    atlas_generation: u64 = std.math.maxInt(u64),
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(metal.Instance) = .empty,
    pasted: std.ArrayList(u8) = .empty,
    text_queue: textinput.Queue,
    size: types.Size = .{},
    scale: f32 = 2,
    last_frame_time: f64 = 0,
    start_time: f64 = 0,
    tick_scheduled: bool = false,
    /// Paces animation frames at the display's refresh (CADisplayLink).
    display_link: ?objc.Object = null,
    /// The pace asked of the link: 0 is the display's.
    link_fps: f32 = 0,
    /// A frame was wanted while the window was hidden: run it once visible.
    pending: bool = false,
    dead: bool = false,
    cursor: ctx_mod.Cursor = .arrow,
    theme_override: ?Theme = null,
    transparent: bool = false,
    after_frame_ctx: ?*anyopaque = null,
    after_frame: ?*const fn (ctx: ?*anyopaque, s: *Surface) void = null,
    a11y_cache: std.AutoHashMapUnmanaged(u64, objc.Object) = .empty,
    /// Behind a stage (`attachBackdrop`): every frame presents in the
    /// Core Animation transaction that moves the pages, so they never part.
    hosted: bool = false,
    /// The focused box after the last frame, and the tooltip shown.
    last_focus: u64 = 0,
    tip: ?[]const u8 = null,
    frame_log: ?FrameLog = null,
    frame_kind: frame_log_mod.Kind = .input,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        errdefer gpa.destroy(self);
        var renderer = try metal.Renderer.init();
        errdefer renderer.deinit();

        const view_class = objc.defineClass(.{
            .name = "NanoUIView",
            .superclass = "NSView",
            .protocols = &.{"NSTextInputClient"},
            .methods = &events.methods,
        });
        const content = objc.msg(objc.Object, window.nswindow, "contentView", .{});
        const bounds = objc.msg(objc.CGRect, content, "bounds", .{});
        const nsview = objc.msg(objc.Object, objc.msg(objc.Object, view_class, "alloc", .{}), "initWithFrame:", .{bounds});

        self.* = .{
            .gpa = gpa,
            .window = window,
            .nsview = nsview,
            .renderer = renderer,
            .text = if (text.portable) .init(gpa) else .init(gpa, renderer.device),
            .ctx = undefined,
            .view = view,
            .text_queue = .init(gpa),
            .theme_override = theme_override,
            // Before anything can run a frame: setContentView: resizes the view.
            .start_time = cf.CACurrentMediaTime(),
        };
        self.ctx = .init(gpa, &self.text);
        if (getenv("NANOUI_FRAMES")) |raw| {
            const p = std.mem.span(raw);
            if (p.len > 0) self.frame_log = FrameLog.init(gpa, p) catch null;
        }
        objc.setZig(nsview, self);
        // A layer-hosting view: the Metal layer is ours.
        objc.msg(void, nsview, "setLayer:", .{renderer.layer});
        objc.msg(void, nsview, "setWantsLayer:", .{objc.YES});
        objc.msg(void, window.nswindow, "setContentView:", .{nsview});
        objc.msg(void, window.nswindow, "setAcceptsMouseMovedEvents:", .{objc.YES});
        _ = objc.msg(objc.BOOL, window.nswindow, "makeFirstResponder:", .{nsview});
        {
            const pool = objc.Pool.push();
            defer pool.pop();
            const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
            for (events.drag_types) |t| objc.msg(void, arr, "addObject:", .{objc.nsString(t)});
            objc.msg(void, nsview, "registerForDraggedTypes:", .{arr});
        }
        if (objc.msg(objc.BOOL, nsview, "respondsToSelector:", .{objc.sel("displayLinkWithTarget:selector:")})) {
            const link = objc.retain(objc.msg(objc.Object, nsview, "displayLinkWithTarget:selector:", .{ nsview, objc.sel("displayLinkFired:") }));
            objc.msg(void, link, "setPaused:", .{objc.YES});
            const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "mainRunLoop", .{});
            objc.msg(void, link, "addToRunLoop:forMode:", .{ loop, NSRunLoopCommonModes });
            self.display_link = link;
        }
        // Pictures go straight to the GPU: no copy of their atlas in memory.
        self.text.images.sink = .{ .ctx = &self.renderer, .upload = @import("metal.zig").Renderer.uploadImage };
        self.updateGeometry();
        self.frame();
        return self;
    }

    pub fn destroy(self: *Surface) void {
        objc.setZig(self.nsview, null);
        if (self.display_link) |link| {
            // The link retains its target, the view: break the cycle.
            objc.msg(void, link, "invalidate", .{});
            objc.release(link);
        }
        if (self.tracking) |t| objc.release(t);
        a11y.clearCache(self);
        objc.release(self.nsview);
        self.instances.deinit(self.gpa);
        self.pasted.deinit(self.gpa);
        if (self.tip) |t| self.gpa.free(t);
        self.text_queue.deinit(self.gpa);
        self.ctx.deinit();
        self.text.deinit();
        if (self.atlas_texture) |t| objc.release(t);
        self.renderer.deinit();
        if (self.frame_log) |*fl| fl.deinit();
        if (self.tick_scheduled) self.dead = true else self.gpa.destroy(self);
    }

    pub fn recordFrames(self: *Surface, gpa: std.mem.Allocator) !*FrameLog {
        if (self.frame_log == null) {
            self.frame_log = try FrameLog.init(gpa, null);
        }
        return &self.frame_log.?;
    }

    pub fn updateGeometry(self: *Surface) void {
        const b = objc.msg(objc.CGRect, self.nsview, "bounds", .{});
        self.size = .{ .w = @floatCast(b.size.width), .h = @floatCast(b.size.height) };
        self.scale = @floatCast(objc.msg(f64, self.window.nswindow, "backingScaleFactor", .{}));
        self.text.setScale(self.scale);
        self.renderer.resize(self.size, self.scale);
    }

    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        const appearance = objc.msg(objc.Object, self.nsview, "effectiveAppearance", .{});
        const name = objc.fromNSString(objc.msg(?objc.Object, appearance, "name", .{}));
        return if (std.mem.indexOf(u8, name, "Dark") != null) Theme.dark_theme else Theme.light;
    }

    /// Builds, lays out, paints and draws one frame.
    /// The atlas texture the renderer samples: CoreText's, or the one
    /// nanoui's own text rasterized into memory, uploaded when it changed.
    fn atlasTexture(self: *Surface) objc.Object {
        if (!text.portable) return self.text.texture();
        const a = &self.text.atlas;
        const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
        const side: usize = a.size;
        if (self.atlas_texture) |t| if (objc.msg(objc.NSUInteger, t, "width", .{}) != side) {
            objc.release(t);
            self.atlas_texture = null;
        };
        if (self.atlas_texture == null) {
            const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
                @as(objc.NSUInteger, 10), side, side, objc.NO, // R8Unorm
            });
            self.atlas_texture = objc.msg(objc.Object, self.renderer.device, "newTextureWithDescriptor:", .{desc});
            self.atlas_generation = std.math.maxInt(u64);
        }
        const t = self.atlas_texture.?;
        if (self.atlas_generation != a.generation) {
            objc.msg(void, t, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                Region{ .x = 0, .y = 0, .z = 0, .w = side, .h = side, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, a.pixels.ptr), side,
            });
            self.atlas_generation = a.generation;
        }
        return t;
    }

    pub fn frame(self: *Surface) void {
        const vis = self.visible();
        self.pending = !vis;
        const pool = objc.Pool.push();
        defer pool.pop();
        const c = &self.ctx;
        const now = cf.CACurrentMediaTime();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        self.ctx.transparent_root = self.transparent;
        c.reduce_motion = objc.msg(objc.BOOL, objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "accessibilityDisplayShouldReduceMotion", .{});
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        const t_af0 = if (self.frame_log != null) cf.CACurrentMediaTime() else 0;
        if (self.after_frame) |af| af(self.after_frame_ctx, self);
        const after_frame_ms = if (self.frame_log != null) (cf.CACurrentMediaTime() - t_af0) * 1000 else 0;
        self.afterFocus();
        if (!vis and self.ctx.frame > 1) {
            self.setPaced(false);
            return;
        }
        self.renderer.syncImages(&self.text.images);
        const clear = if (self.transparent) types.Color.transparent else c.theme.background;
        if (self.frame_log) |*fl| {
            const dur: f64 = if (self.display_link) |l| objc.msg(f64, l, "duration", .{}) else 1.0 / 60.0;
            const interval_ms: f64 = if (fl.last_t > 0) (now - fl.last_t) * 1000 else 0;
            fl.last_t = now;
            const atlas_reset = self.text.atlas.reset_during_frame or self.text.images.reset_during_frame;
            const idx = fl.append(.{
                .t = now,
                .kind = self.frame_kind,
                .interval_ms = interval_ms,
                .duration = if (dur > 0) dur else 1.0 / 60.0,
                .dt = dt,
                .build_ms = c.stats.build_ms,
                .layout_ms = c.stats.layout_ms,
                .paint_ms = c.stats.paint_ms,
                .after_frame_ms = after_frame_ms,
                .drawable_wait_ms = 0,
                .encode_ms = 0,
                .sync = self.renderer.live_resize,
                .nodes = c.stats.nodes,
                .instances = c.stats.instances,
                .atlas_reset = atlas_reset,
                .animating = c.animating,
            });
            const ds = self.renderer.drawLogged(self.instances.items, self.atlasTexture(), self.size, clear, fl, idx);
            fl.setDraw(idx, ds.drawable_wait_ms, ds.encode_ms, ds.sync);
        } else {
            self.renderer.draw(self.instances.items, self.atlasTexture(), self.size, clear);
        }
        self.updateCursor();
        const more = c.animating or r.hot_changed;
        if (self.display_link != null) {
            // Something changes now and then: the link, at that pace.
            self.setRate(if (more) null else c.frame_in);
            self.setPaced(more or c.frame_in != null);
        } else if (more or c.frame_in != null) self.scheduleTick();
        if (!c.animating) self.last_frame_time = 0;
    }

    pub fn setTransparent(self: *Surface, on: bool) void {
        self.transparent = on;
        self.ctx.transparent_root = on;
        self.renderer.setOpaque(!on);
    }

    /// Places `stage_view` behind `self.nsview` inside a flipped host contentView,
    /// enabling transparent viewport holes over live WKWebView panes.
    pub fn attachBackdrop(self: *Surface, stage_view: objc.Object) void {
        const host_class = objc.defineClass(.{
            .name = "NanoUIHostView",
            .superclass = "NSView",
            .methods = &.{.{ .name = "isFlipped", .imp = &events.yes, .types = "c@:" }},
        });
        const b = objc.msg(objc.CGRect, self.nsview, "bounds", .{});
        const host = objc.msg(objc.Object, objc.msg(objc.Object, host_class, "alloc", .{}), "initWithFrame:", .{b});
        objc.msg(void, host, "setWantsLayer:", .{objc.YES});
        objc.msg(void, host, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
        objc.msg(void, self.nsview, "retain", .{});
        defer objc.msg(void, self.nsview, "release", .{});
        objc.msg(void, self.window.nswindow, "setContentView:", .{host});
        objc.msg(void, stage_view, "setFrame:", .{b});
        objc.msg(void, stage_view, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
        objc.msg(void, self.nsview, "setFrame:", .{b});
        objc.msg(void, self.nsview, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
        objc.msg(void, host, "addSubview:", .{stage_view});
        objc.msg(void, host, "addSubview:", .{self.nsview});
        objc.release(host);
        self.setTransparent(true);
        self.hosted = true;
        self.renderer.setLiveResize(true);
    }

    /// Draws a frame at the display's next refresh: for changes from
    /// outside the view (a process's output, a network reply).
    pub fn requestFrame(self: *Surface) void {
        if (self.display_link != null) {
            self.setRate(null);
            self.setPaced(true);
        } else self.scheduleTick();
    }

    /// The display link's pace: the display's (null), or one frame every
    /// `seconds`.
    fn setRate(self: *Surface, seconds: ?f32) void {
        const link = self.display_link orelse return;
        const fps: f32 = if (seconds) |s| std.math.clamp(1 / @max(s, 0.001), 1, 60) else 0;
        if (fps == self.link_fps) return;
        self.link_fps = fps;
        const Range = extern struct { minimum: f32, maximum: f32, preferred: f32 };
        const range: Range = if (fps == 0) .{ .minimum = 0, .maximum = 0, .preferred = 0 } else .{ .minimum = fps, .maximum = fps, .preferred = fps };
        objc.msg(void, link, "setPreferredFrameRateRange:", .{range});
    }

    fn visible(self: *Surface) bool {
        return objc.msg(objc.NSUInteger, self.window.nswindow, "occlusionState", .{}) & 2 != 0;
    }

    fn setPaced(self: *Surface, on: bool) void {
        if (self.display_link) |link| objc.msg(void, link, "setPaused:", .{!on});
    }

    /// The window was shown, uncovered or covered.
    pub fn occlusionChanged(self: *Surface) void {
        if (self.visible() and self.pending) self.frame();
    }

    pub fn updateCursor(self: *Surface) void {
        if (self.transparent and self.ctx.inStageHoleAt(self.ctx.input.mouse)) return;
        const want: ctx_mod.Cursor = self.ctx.cursor orelse if (self.ctx.cursor_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
        if (want == self.cursor) return;
        self.cursor = want;
        const name: [:0]const u8 = switch (want) {
            .arrow => "arrowCursor",
            .hand => "pointingHandCursor",
            .text => "IBeamCursor",
            .resize_left_right => "resizeLeftRightCursor",
            .resize_up_down => "resizeUpDownCursor",
            .open_hand => "openHandCursor",
            .closed_hand => "closedHandCursor",
            .not_allowed => "operationNotAllowedCursor",
            .crosshair => "crosshairCursor",
        };
        objc.msg(void, objc.msg(objc.Object, objc.class("NSCursor"), name, .{}), "set", .{});
    }

    /// After a frame: a box newly focused takes the keyboard for the view
    /// (`focusNext` while a page had it), and the hot box's help shows.
    fn afterFocus(self: *Surface) void {
        const c = &self.ctx;
        if (c.focus != 0 and c.focus != self.last_focus) {
            const first = objc.msg(?objc.Object, self.window.nswindow, "firstResponder", .{});
            if (first == null or first.? != self.nsview) _ = objc.msg(objc.BOOL, self.window.nswindow, "makeFirstResponder:", .{self.nsview});
        }
        self.last_focus = c.focus;
        self.refreshTip();
    }

    /// Shows the help under the pointer: after a frame, and on a move
    /// within one box onto a marker with its own.
    pub fn refreshTip(self: *Surface) void {
        const tip = self.ctx.hotHelp();
        const same = if (tip) |t| (if (self.tip) |old| std.mem.eql(u8, t, old) else false) else self.tip == null;
        if (same) return;
        if (self.tip) |old| self.gpa.free(old);
        self.tip = if (tip) |t| self.gpa.dupe(u8, t) catch null else null;
        objc.msg(void, self.nsview, "setToolTip:", .{if (self.tip) |t| objc.nsString(t) else @as(?objc.Object, null)});
    }

    fn scheduleTick(self: *Surface) void {
        if (self.tick_scheduled) return;
        self.tick_scheduled = true;
        objc.dispatchAfter(std.time.ns_per_s / 120, self, tick);
    }

    fn tick(ptr: ?*anyopaque) callconv(.c) void {
        const self: *Surface = @ptrCast(@alignCast(ptr));
        self.tick_scheduled = false;
        if (self.dead) return self.gpa.destroy(self);
        self.frame();
    }

    /// A point in the window's coordinates, in the view's (flipped) points.
    pub fn toView(self: *Surface, p: objc.CGPoint) types.Point {
        const local = objc.msg(objc.CGPoint, self.nsview, "convertPoint:fromView:", .{ p, @as(?objc.Object, null) });
        return .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
    }
};

// The run loop knows its common modes by this object, not by its name.
extern "c" const NSRunLoopCommonModes: objc.Object;
