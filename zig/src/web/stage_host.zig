//! Hybrid StageHost: hosts the live `WKWebView` panes (one, or a pair's
//! two, plus a leaving one while it fades) and an optional Peek webview
//! inside a flipped `PageStageView` positioned directly behind
//! `NanoUIView` (`Surface`), and synchronizes their frames in
//! `after_frame` on the same run-loop turn. Pane `i` takes stage hole `i`;
//! the peek takes the hole after the panes'.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Surface = nanoui.Surface;
const page_view = @import("page_view.zig");
pub const PaneSlot = struct {
    webview: ?objc.Object = null,
    last_rect: ui.Rect = .{},
    corner_radius: f32 = 0,
    /// The last `setHidden:` sent, so each frame sends only changes.
    hidden: bool = false,
    /// The pane's opacity as the stage wants it (arriving or leaving), and
    /// the last `setAlphaValue:` sent.
    alpha: f32 = 1,
    applied_alpha: f32 = 1,
    held: bool = false,
    place_calls: usize = 0,

    fn setHidden(slot: *PaneSlot, wv: objc.Object, on: bool) bool {
        if (slot.hidden == on) return false;
        slot.hidden = on;
        objc.msg(void, wv, "setHidden:", .{on});
        return true;
    }

    fn place(slot: *PaneSlot, wv: objc.Object, holes: []const ui.Rect, i: usize, reduce_motion: bool) bool {
        if (i >= holes.len or holes[i].w <= 1 or holes[i].h <= 1) return slot.setHidden(wv, true);
        const r = holes[i];
        var changed = slot.setHidden(wv, false);
        const unpaid = page_view.unpainted(wv);
        if (unpaid) slot.held = true;
        const want: f32 = if (unpaid) 0 else slot.alpha;
        if (slot.applied_alpha != want) {
            const painted = slot.held and !unpaid and want > 0;
            if (!unpaid) slot.held = false;
            slot.applied_alpha = want;
            if (painted and !reduce_motion) fadeIn(wv, want) else objc.msg(void, wv, "setAlphaValue:", .{@as(f64, want)});
            changed = true;
        }
        if (rectsEq(slot.last_rect, r)) return changed;
        slot.last_rect = r;
        slot.place_calls += 1;
        objc.msg(void, wv, "setFrame:", .{objc.CGRect{
            .origin = .{ .x = r.x, .y = r.y },
            .size = .{ .width = r.w, .height = r.h },
        }});
        return true;
    }
};

pub const StageHost = struct {
    gpa: std.mem.Allocator,
    surface: *Surface,
    stage_view: objc.Object,
    slots: std.ArrayList(PaneSlot) = .empty,
    peek_slot: PaneSlot = .{},
    card_radius: f32 = 10,
    dirty: bool = false,
    last_holes: [8]ui.Rect = undefined,
    last_hole_count: usize = 0,
    on_rects_ctx: ?*anyopaque = null,
    on_rects: ?*const fn (ctx: ?*anyopaque, holes: []const ui.Rect) void = null,

    pub fn create(gpa: std.mem.Allocator, surface: *Surface) !*StageHost {
        const self = try gpa.create(StageHost);
        errdefer gpa.destroy(self);

        const stage_class = objc.defineClass(.{
            .name = "KeaZigStageView",
            .superclass = "NSView",
            .methods = &.{
                .{ .name = "isFlipped", .imp = &yes, .types = "c@:" },
            },
        });
        const b = objc.msg(objc.CGRect, surface.nsview, "bounds", .{});
        const stage_view = objc.msg(objc.Object, objc.msg(objc.Object, stage_class, "alloc", .{}), "initWithFrame:", .{b});
        objc.msg(void, stage_view, "setWantsLayer:", .{objc.YES});
        objc.msg(void, stage_view, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});

        self.* = .{
            .gpa = gpa,
            .surface = surface,
            .stage_view = stage_view,
        };
        surface.attachBackdrop(stage_view);
        surface.after_frame_ctx = self;
        surface.after_frame = onAfterFrame;
        return self;
    }

    pub fn destroy(self: *StageHost) void {
        self.surface.after_frame = null;
        self.surface.after_frame_ctx = null;
        self.slots.deinit(self.gpa);
        objc.release(self.stage_view);
        self.gpa.destroy(self);
    }

    /// The panes' pages in hole order (null: a pane with nothing to show),
    /// each at its opacity; corners the card's when `framed`.
    pub fn setPanes(self: *StageHost, pages: []const ?objc.Object, alphas: []const f32, framed: bool) void {
        self.card_radius = if (framed) 10 else 0;
        // A page no pane holds any more leaves the stage.
        for (self.slots.items) |slot| if (slot.webview) |old| {
            if (std.mem.indexOfScalar(?objc.Object, pages, old) == null) self.detach(old);
        };
        self.slots.shrinkRetainingCapacity(@min(self.slots.items.len, pages.len));
        while (self.slots.items.len < pages.len) self.slots.append(self.gpa, .{}) catch return;
        for (self.slots.items, pages, alphas, 0..) |*slot, page, alpha, i| {
            slot.alpha = alpha;
            if (slot.webview != page) {
                const unpaid = if (page) |wv| page_view.unpainted(wv) else false;
                const init_alpha: f32 = if (unpaid) 0 else alpha;
                slot.* = .{ .webview = page, .corner_radius = self.card_radius, .alpha = alpha, .applied_alpha = init_alpha, .held = unpaid };
                self.dirty = true;
                if (page) |wv| {
                    const sup = objc.msg(?objc.Object, wv, "superview", .{});
                    if (sup != self.stage_view) objc.msg(void, self.stage_view, "addSubview:", .{wv});
                    objc.msg(void, wv, "setHidden:", .{objc.NO});
                    objc.msg(void, wv, "setAlphaValue:", .{@as(f64, init_alpha)});
                    if (i < self.last_hole_count) _ = slot.place(wv, self.last_holes[0..self.last_hole_count], i, self.surface.reduce_motion);
                    applyCornerRadius(wv, self.card_radius);
                }
            } else if (page) |wv| if (slot.corner_radius != self.card_radius) {
                slot.corner_radius = self.card_radius;
                applyCornerRadius(wv, self.card_radius);
                self.dirty = true;
            };
        }
    }

    /// One page alone (the floating and little windows' stages).
    pub fn setPage(self: *StageHost, page: ?objc.Object, framed: bool) void {
        self.setPanes(&.{page}, &.{1}, framed);
    }

    /// Drops every slot holding `webview` (its tab is about to free it).
    pub fn forget(self: *StageHost, webview: objc.Object) void {
        for (self.slots.items) |*slot| {
            if (slot.webview == webview) slot.* = .{};
        }
        if (self.peek_slot.webview == webview) self.peek_slot = .{};
        self.detach(webview);
    }

    pub fn holds(self: *const StageHost, webview: objc.Object) bool {
        for (self.slots.items) |slot| if (slot.webview == webview) return true;
        return self.peek_slot.webview == webview;
    }

    pub fn setPeek(self: *StageHost, webview: ?objc.Object) void {
        if (self.peek_slot.webview == webview) return;
        if (self.peek_slot.webview) |old| self.detach(old);
        const unpaid = if (webview) |wv| page_view.unpainted(wv) else false;
        const init_alpha: f32 = if (unpaid) 0 else 1;
        self.peek_slot = .{ .webview = webview, .applied_alpha = init_alpha, .held = unpaid };
        self.dirty = true;
        if (webview) |wv| {
            objc.msg(void, self.stage_view, "addSubview:", .{wv});
            objc.msg(void, wv, "setHidden:", .{objc.NO});
            objc.msg(void, wv, "setAlphaValue:", .{@as(f64, init_alpha)});
            applyCornerRadius(wv, 12);
        }
    }

    fn detach(self: *StageHost, wv: objc.Object) void {
        if (objc.msg(?objc.Object, wv, "superview", .{}) == self.stage_view) {
            objc.msg(void, wv, "removeFromSuperview", .{});
            self.dirty = true;
        }
    }

    fn applyCornerRadius(wv: objc.Object, radius: f32) void {
        objc.msg(void, wv, "setWantsLayer:", .{objc.YES});
        if (objc.msg(?objc.Object, wv, "layer", .{})) |layer| {
            objc.msg(void, layer, "setCornerRadius:", .{@as(f64, radius)});
            objc.msg(void, layer, "setCornerCurve:", .{objc.nsString("continuous")});
            objc.msg(void, layer, "setMasksToBounds:", .{if (radius > 0) objc.YES else objc.NO});
        }
    }

    fn onAfterFrame(ctx: ?*anyopaque, s: *Surface) bool {
        const self: *StageHost = @ptrCast(@alignCast(ctx));
        var changed = self.dirty;
        self.dirty = false;
        const holes = s.ctx.stage_rects[0..s.ctx.stage_count];
        const hc = @min(holes.len, self.last_holes.len);
        @memcpy(self.last_holes[0..hc], holes[0..hc]);
        self.last_hole_count = hc;
        if (self.on_rects) |cb| cb(self.on_rects_ctx, holes);
        const n = self.slots.items.len;
        for (self.slots.items, 0..) |*slot, i| {
            const wv = slot.webview orelse continue;
            if (slot.place(wv, holes, i, s.reduce_motion)) changed = true;
        }
        // The peek's hole is drawn after the panes'.
        if (self.peek_slot.webview) |wv| {
            if (self.peek_slot.place(wv, if (holes.len > n) holes else &.{}, n, s.reduce_motion)) changed = true;
        }
        return changed;
    }
};

const Fade = struct { wv: objc.Object, alpha: f32 };

fn runFade(f: *Fade, ctx: objc.Object) void {
    objc.msg(void, ctx, "setDuration:", .{@as(f64, 0.18)});
    const timing = objc.msg(objc.Object, objc.class("CAMediaTimingFunction"), "functionWithName:", .{objc.nsString("easeOut")});
    objc.msg(void, ctx, "setTimingFunction:", .{timing});
    const anim = objc.msg(objc.Object, f.wv, "animator", .{});
    objc.msg(void, anim, "setAlphaValue:", .{@as(f64, f.alpha)});
}

fn fadeIn(wv: objc.Object, alpha: f32) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    var f: Fade = .{ .wv = wv, .alpha = alpha };
    var block = objc.Block(Fade, &.{objc.Object}).init(&f, runFade);
    objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:", .{@as(*anyopaque, @ptrCast(&block))});
}

fn rectsEq(a: ui.Rect, b: ui.Rect) bool {
    return @abs(a.x - b.x) < 0.25 and @abs(a.y - b.y) < 0.25 and @abs(a.w - b.w) < 0.25 and @abs(a.h - b.h) < 0.25;
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}
