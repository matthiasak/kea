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

    fn setHidden(slot: *PaneSlot, wv: objc.Object, on: bool) void {
        if (slot.hidden == on) return;
        slot.hidden = on;
        objc.msg(void, wv, "setHidden:", .{on});
    }

    fn place(slot: *PaneSlot, wv: objc.Object, holes: []const ui.Rect, i: usize) void {
        if (i >= holes.len or holes[i].w <= 1 or holes[i].h <= 1) return slot.setHidden(wv, true);
        const r = holes[i];
        slot.setHidden(wv, false);
        if (slot.applied_alpha != slot.alpha) {
            slot.applied_alpha = slot.alpha;
            objc.msg(void, wv, "setAlphaValue:", .{@as(f64, slot.alpha)});
        }
        if (rectsEq(slot.last_rect, r)) return;
        slot.last_rect = r;
        objc.msg(void, wv, "setFrame:", .{objc.CGRect{
            .origin = .{ .x = r.x, .y = r.y },
            .size = .{ .width = r.w, .height = r.h },
        }});
    }
};

pub const StageHost = struct {
    gpa: std.mem.Allocator,
    surface: *Surface,
    stage_view: objc.Object,
    slots: std.ArrayList(PaneSlot) = .empty,
    peek_slot: PaneSlot = .{},
    card_radius: f32 = 10,
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
        for (self.slots.items, pages, alphas) |*slot, page, alpha| {
            if (slot.webview != page) {
                slot.* = .{ .webview = page, .corner_radius = self.card_radius };
                if (page) |wv| {
                    const sup = objc.msg(?objc.Object, wv, "superview", .{});
                    if (sup != self.stage_view) objc.msg(void, self.stage_view, "addSubview:", .{wv});
                    objc.msg(void, wv, "setHidden:", .{objc.NO});
                    objc.msg(void, wv, "setAlphaValue:", .{@as(f64, 1)});
                    applyCornerRadius(wv, self.card_radius);
                }
            } else if (page) |wv| if (slot.corner_radius != self.card_radius) {
                slot.corner_radius = self.card_radius;
                applyCornerRadius(wv, self.card_radius);
            };
            slot.alpha = alpha;
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

    pub fn setPeek(self: *StageHost, webview: ?objc.Object) void {
        if (self.peek_slot.webview == webview) return;
        if (self.peek_slot.webview) |old| self.detach(old);
        self.peek_slot = .{ .webview = webview };
        if (webview) |wv| {
            objc.msg(void, self.stage_view, "addSubview:", .{wv});
            objc.msg(void, wv, "setHidden:", .{objc.NO});
            applyCornerRadius(wv, 12);
        }
    }

    fn detach(self: *const StageHost, wv: objc.Object) void {
        if (objc.msg(?objc.Object, wv, "superview", .{}) == self.stage_view) {
            objc.msg(void, wv, "removeFromSuperview", .{});
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

    fn onAfterFrame(ctx: ?*anyopaque, s: *Surface) void {
        const self: *StageHost = @ptrCast(@alignCast(ctx));
        const holes = s.ctx.stage_rects[0..s.ctx.stage_count];
        if (self.on_rects) |cb| cb(self.on_rects_ctx, holes);
        const n = self.slots.items.len;
        for (self.slots.items, 0..) |*slot, i| {
            const wv = slot.webview orelse continue;
            slot.place(wv, holes, i);
        }
        // The peek's hole is drawn after the panes'.
        if (self.peek_slot.webview) |wv| self.peek_slot.place(wv, if (holes.len > n) holes else &.{}, n);
    }
};

fn rectsEq(a: ui.Rect, b: ui.Rect) bool {
    return @abs(a.x - b.x) < 0.25 and @abs(a.y - b.y) < 0.25 and @abs(a.w - b.w) < 0.25 and @abs(a.h - b.h) < 0.25;
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}
