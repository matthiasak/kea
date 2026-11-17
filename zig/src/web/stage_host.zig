//! Hybrid StageHost: hosts the live `WKWebView` panes (one, or a pair's
//! two, plus a leaving one while it fades) and an optional Peek webview
//! inside a flipped `PageStageView` positioned directly behind
//! `NanoUIView` (`Surface`), and synchronizes their frames in
//! `after_frame` on the same run-loop turn. Pane `i` takes stage hole `i`;
//! the peek takes the hole after the panes'. The stage always covers the
//! window; on macOS each page sits in a box of its own in it
//! (`PaneSlot.container`), so a docked Web Inspector stays in its pane's hole.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Surface = nanoui.Surface;
const page_view = @import("page_view.zig");
const inspector = @import("inspector.zig");
const platform = @import("../sys/platform.zig");

const CATransform3D = extern struct {
    m11: f64, m12: f64, m13: f64, m14: f64,
    m21: f64, m22: f64, m23: f64, m24: f64,
    m31: f64, m32: f64, m33: f64, m34: f64,
    m41: f64, m42: f64, m43: f64, m44: f64,
};
extern "c" const CATransform3DIdentity: CATransform3D;
extern "c" fn CATransform3DMakeScale(sx: f64, sy: f64, sz: f64) CATransform3D;
extern "c" fn CATransform3DMakeTranslation(tx: f64, ty: f64, tz: f64) CATransform3D;
extern "c" fn CATransform3DConcat(a: CATransform3D, b: CATransform3D) CATransform3D;
pub const PaneSlot = struct {
    webview: ?objc.Object = null,
    /// macOS: the unflipped `NSView` in the stage that holds the page, owned
    /// here; it is what is placed, hidden and clipped. WebKit docks an
    /// inspector into the page's superview in AppKit's own coordinates:
    /// straight in the flipped stage that is above the page and out of its
    /// hole; in here it is below (or right of) it, inside the hole.
    container: ?objc.Object = null,
    /// The last `setAutoresizingMask:` sent to the page.
    applied_mask: objc.NSUInteger = std.math.maxInt(objc.NSUInteger),
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
    had_inspector: bool = false,

    fn setHidden(slot: *PaneSlot, view: objc.Object, on: bool) bool {
        if (slot.hidden == on) return false;
        slot.hidden = on;
        objc.msg(void, view, "setHidden:", .{on});
        return true;
    }

    /// `wv` onto `stage` (macOS: into the slot's box, made if it has none),
    /// shown, at `alpha`, its corners `radius`; under `below` when it is
    /// new to the stage, on top with none.
    fn adopt(slot: *PaneSlot, stage: objc.Object, wv: objc.Object, alpha: f32, radius: f32, below: ?objc.Object) void {
        var home = stage;
        if (comptime !platform.is_ios) {
            const box = slot.container orelse blk: {
                const v = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{}});
                objc.msg(void, v, "setWantsLayer:", .{objc.YES});
                slot.container = v;
                break :blk v;
            };
            if (objc.msg(?objc.Object, box, "superview", .{}) != stage) addBelow(stage, box, below);
            objc.msg(void, box, "setHidden:", .{objc.NO});
            home = box;
        }
        if (objc.msg(?objc.Object, wv, "superview", .{}) != home) addBelow(home, wv, if (home == stage) below else null);
        objc.msg(void, wv, "setHidden:", .{objc.NO});
        setAlpha(wv, alpha);
        // In its box the page is sized with it; straight in the stage, by `place`.
        const mask: objc.NSUInteger = if (comptime platform.is_ios) 0 else 2 | 16;
        if (slot.applied_mask != mask) {
            slot.applied_mask = mask;
            objc.msg(void, wv, "setAutoresizingMask:", .{mask});
        }
        slot.corner_radius = radius;
        applyCornerRadius(slot.container orelse wv, radius, false);
    }

    fn place(slot: *PaneSlot, wv: objc.Object, holes: []const ui.Rect, i: usize, reduce_motion: bool) bool {
        const box = slot.container orelse wv;
        if (i >= holes.len or holes[i].w <= 1 or holes[i].h <= 1) return slot.setHidden(box, true);
        const local = holes[i];
        var changed = slot.setHidden(box, false);
        const unpaid = page_view.unpainted(wv);
        if (unpaid) slot.held = true;
        const want: f32 = if (unpaid) 0 else slot.alpha;
        if (slot.applied_alpha != want) {
            const painted = slot.held and !unpaid and want > 0;
            if (!unpaid) slot.held = false;
            slot.applied_alpha = want;
            if (painted and !reduce_motion) fadeIn(wv, want) else setAlpha(wv, want);
            changed = true;
        }
        if (!rectsEq(slot.last_rect, local)) {
            slot.last_rect = local;
            slot.place_calls += 1;
            setFrame(box, local);
            changed = true;
        }
        if (comptime platform.is_ios) return changed;
        // An inspector docked beside the page: WebKit shares the box between
        // the two and AppKit sizes both with it, so the page is left alone.
        if (inspector.isAttachedFor(wv)) {
            if (!slot.had_inspector) applyCornerRadius(box, slot.corner_radius, true);
            slot.had_inspector = true;
            return changed;
        }
        // Otherwise the page fills its box: again at once when the inspector
        // closes or goes out into a window of its own.
        const fill: ui.Rect = .{ .w = local.w, .h = local.h };
        if (!slot.had_inspector and rectsEq(frameOf(wv), fill)) return changed;
        if (slot.had_inspector) applyCornerRadius(box, slot.corner_radius, false);
        slot.had_inspector = false;
        setFrame(wv, fill);
        return true;
    }
};

/// The most panes a stage is asked for (a pair's two and one leaving), with
/// room: the slots as they were are set aside on the stack (`setPanes`).
const max_panes = 8;

pub const StageHost = struct {
    gpa: std.mem.Allocator,
    surface: *Surface,
    stage_view: objc.Object,
    slots: std.ArrayList(PaneSlot) = .empty,
    peek_slot: PaneSlot = .{},
    web_panel_slot: PaneSlot = .{},
    card_radius: f32 = 10,
    dirty: bool = false,
    last_holes: [8]ui.Rect = undefined,
    last_hole_count: usize = 0,
    /// The stage's frame: the whole surface, always.
    stage_bounds: ui.Rect = .{},
    on_rects_ctx: ?*anyopaque = null,
    on_rects: ?*const fn (ctx: ?*anyopaque, holes: []const ui.Rect) void = null,

    pub fn create(gpa: std.mem.Allocator, surface: *Surface) !*StageHost {
        const self = try gpa.create(StageHost);
        errdefer gpa.destroy(self);

        const stage_class = objc.defineClass(.{
            .name = "KeaStageView",
            .superclass = if (comptime platform.is_ios) "UIView" else "NSView",
            .methods = if (comptime platform.is_ios) &.{} else &.{
                .{ .name = "isFlipped", .imp = &yes, .types = "c@:" },
            },
        });
        const b = objc.msg(objc.CGRect, platform.nativeView(surface).?, "bounds", .{});
        const stage_view = objc.msg(objc.Object, objc.msg(objc.Object, stage_class, "alloc", .{}), "initWithFrame:", .{b});
        if (comptime !platform.is_ios) objc.msg(void, stage_view, "setWantsLayer:", .{objc.YES});
        self.* = .{
            .gpa = gpa,
            .surface = surface,
            .stage_view = stage_view,
            .stage_bounds = .{ .x = @floatCast(b.origin.x), .y = @floatCast(b.origin.y), .w = @floatCast(b.size.width), .h = @floatCast(b.size.height) },
        };
        surface.attachBackdrop(stage_view);
        surface.after_frame_ctx = self;
        surface.after_frame = onAfterFrame;
        return self;
    }

    pub fn destroy(self: *StageHost) void {
        self.surface.after_frame = null;
        self.surface.after_frame_ctx = null;
        for (self.slots.items) |*slot| self.vacate(slot);
        self.vacate(&self.peek_slot);
        self.vacate(&self.web_panel_slot);
        self.slots.deinit(self.gpa);
        objc.release(self.stage_view);
        self.gpa.destroy(self);
    }

    /// The panes' pages in hole order (null: a pane with nothing to show),
    /// each at its opacity; corners the card's when `framed`.
    pub fn setPanes(self: *StageHost, all_pages: []const ?objc.Object, all_alphas: []const f32, framed: bool) void {
        self.card_radius = if (framed) 10 else 0;
        const pages = all_pages[0..@min(all_pages.len, max_panes)];
        const alphas = all_alphas[0..pages.len];
        // A page no pane holds any more leaves the stage.
        var prior: [max_panes]?objc.Object = @splat(null);
        for (self.slots.items, 0..) |*slot, i| {
            prior[i] = slot.webview;
            if (slot.webview) |old| if (std.mem.indexOfScalar(?objc.Object, pages, old) == null) self.vacate(slot);
        }
        // The slots as they were, set aside: each page that stays is found in
        // them and takes its whole slot — its box with it — to its new place,
        // so a pair swapped, made or closed to one re-parents nothing (a
        // re-parented page loses the keys, and its docked inspector) and no
        // two pages are ever given one box.
        const had = self.slots.items.len;
        var was: [max_panes]PaneSlot = undefined;
        @memcpy(was[0..had], self.slots.items);
        while (self.slots.items.len < pages.len) self.slots.append(self.gpa, .{}) catch return;
        self.slots.shrinkRetainingCapacity(pages.len);
        for (self.slots.items, pages, alphas, 0..) |*slot, page, alpha, i| {
            const from: ?usize = if (page) |wv| for (was[0..had], 0..) |w, j| {
                if (w.webview == wv) break j;
            } else null else null;
            if (from) |j| {
                slot.* = was[j];
                was[j] = .{};
                slot.alpha = alpha;
            } else {
                const unpaid = if (page) |wv| page_view.unpainted(wv) else false;
                const init_alpha: f32 = if (unpaid) 0 else alpha;
                slot.* = .{ .webview = page, .corner_radius = self.card_radius, .alpha = alpha, .applied_alpha = init_alpha, .held = unpaid };
                if (page) |wv| slot.adopt(self.stage_view, wv, init_alpha, self.card_radius, self.overPanes(was[0..had]));
            }
            const wv = page orelse continue;
            if (slot.corner_radius != self.card_radius) {
                slot.corner_radius = self.card_radius;
                applyCornerRadius(slot.container orelse wv, self.card_radius, slot.had_inspector);
                self.dirty = true;
            }
            // Where it was: nothing more to do.
            if (from != null and from.? == i) continue;
            self.dirty = true;
            if (i < self.last_hole_count) _ = slot.place(wv, self.last_holes[0..self.last_hole_count], i, self.surface.reduce_motion);
            if (prior[i] != null and self.surface.visible()) animateSwitch(wv, self.surface.reduce_motion);
        }
        // Every page that stays has taken its slot: a box left behind is empty.
        for (was[0..had]) |*w| self.unbox(w);
        // The web side panel's corners are the cards'.
        const side = &self.web_panel_slot;
        if (side.webview) |wv| if (side.corner_radius != self.card_radius) {
            side.corner_radius = self.card_radius;
            applyCornerRadius(side.container orelse wv, self.card_radius, side.had_inspector);
            self.dirty = true;
        };
    }

    /// The lowest view on the stage that is no pane's (the Peek, the web side
    /// panel, a stage picture): a pane new to the stage goes in under it, so
    /// above the panes already there and below all that covers them. `was`:
    /// the slots set aside while the panes are dealt out.
    fn overPanes(self: *const StageHost, was: []const PaneSlot) ?objc.Object {
        const subs = objc.msg(?objc.Object, self.stage_view, "subviews", .{}) orelse return null;
        const n = objc.msg(objc.NSUInteger, subs, "count", .{});
        var i: objc.NSUInteger = 0;
        next: while (i < n) : (i += 1) {
            const v = objc.msg(objc.Object, subs, "objectAtIndex:", .{i});
            for ([_][]const PaneSlot{ self.slots.items, was }) |set| for (set) |sl| {
                if (sl.container == v or sl.webview == v) continue :next;
            };
            return v;
        }
        return null;
    }

    /// One page alone (the floating and little windows' stages).
    pub fn setPage(self: *StageHost, page: ?objc.Object, framed: bool) void {
        self.setPanes(&.{page}, &.{1}, framed);
    }

    /// Drops every slot holding `webview` (its tab is about to free it).
    pub fn forget(self: *StageHost, webview: objc.Object) void {
        for (self.slots.items) |*slot| {
            if (slot.webview == webview) self.vacate(slot);
        }
        if (self.peek_slot.webview == webview) self.vacate(&self.peek_slot);
        if (self.web_panel_slot.webview == webview) self.vacate(&self.web_panel_slot);
        // One put straight in the stage (an extension's popup, not yet shown).
        if (objc.msg(?objc.Object, webview, "superview", .{}) == self.stage_view) self.takeOff(webview);
    }

    pub fn holds(self: *const StageHost, webview: objc.Object) bool {
        for (self.slots.items) |slot| if (slot.webview == webview) return true;
        return self.peek_slot.webview == webview or self.web_panel_slot.webview == webview;
    }

    /// The view that stands for `wv` in `stage_view`, whose frame is its
    /// place there — its box on macOS, `wv` itself on iOS; null when `wv`
    /// is none or not on this stage.
    pub fn boxOf(self: *const StageHost, wv: ?objc.Object) ?objc.Object {
        const w = wv orelse return null;
        const home = objc.msg(?objc.Object, w, "superview", .{}) orelse return null;
        if (comptime platform.is_ios) return if (home == self.stage_view) w else null;
        for (self.slots.items) |slot| if (slot.container == home) return home;
        return if (self.peek_slot.container == home or self.web_panel_slot.container == home) home else null;
    }

    pub fn setPeek(self: *StageHost, webview: ?objc.Object) void {
        self.setAside(&self.peek_slot, webview, 12);
    }

    pub fn setWebPanel(self: *StageHost, webview: ?objc.Object) void {
        self.setAside(&self.web_panel_slot, webview, self.card_radius);
    }

    /// The Peek's page or the web side panel's into its own slot.
    fn setAside(self: *StageHost, slot: *PaneSlot, webview: ?objc.Object, radius: f32) void {
        if (slot.webview == webview) return;
        self.vacate(slot);
        const unpaid = if (webview) |wv| page_view.unpainted(wv) else false;
        const init_alpha: f32 = if (unpaid) 0 else 1;
        slot.* = .{ .webview = webview, .applied_alpha = init_alpha, .held = unpaid };
        self.dirty = true;
        if (webview) |wv| slot.adopt(self.stage_view, wv, init_alpha, radius, null);
    }

    /// Empties `slot`: its page off the stage unless something else has taken
    /// it since, an inspector docked in its box closed first, the box freed.
    fn vacate(self: *StageHost, slot: *PaneSlot) void {
        if (slot.webview) |wv| {
            if (comptime !platform.is_ios) {
                if (slot.container) |box| if (inspector.inspectorWebViewFor(wv)) |iwv| {
                    if (objc.msg(?objc.Object, iwv, "superview", .{}) == box) {
                        if (objc.msg(?objc.Object, wv, "_inspector", .{})) |insp| {
                            if (objc.msg(objc.BOOL, insp, "respondsToSelector:", .{objc.sel("close")})) objc.msg(void, insp, "close", .{});
                        }
                    }
                };
            }
            const home: ?objc.Object = if (comptime platform.is_ios) self.stage_view else slot.container;
            if (home != null and objc.msg(?objc.Object, wv, "superview", .{}) == home) self.takeOff(wv);
        }
        self.unbox(slot);
        slot.* = .{};
    }

    fn takeOff(self: *StageHost, wv: objc.Object) void {
        objc.msg(void, wv, "setHidden:", .{objc.YES});
        objc.msg(void, wv, "removeFromSuperview", .{});
        self.dirty = true;
    }

    /// Frees `slot`'s box (macOS), the one retain it was made with.
    fn unbox(self: *StageHost, slot: *PaneSlot) void {
        const box = slot.container orelse return;
        slot.container = null;
        objc.msg(void, box, "removeFromSuperview", .{});
        objc.release(box);
        self.dirty = true;
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
        const want_sb: ui.Rect = .{ .w = s.size.w, .h = s.size.h };
        if (!rectsEq(self.stage_bounds, want_sb)) {
            self.stage_bounds = want_sb;
            setFrame(self.stage_view, want_sb);
            changed = true;
        }
        for (self.slots.items, 0..) |*slot, i| {
            const wv = slot.webview orelse continue;
            if (slot.place(wv, holes, i, s.reduce_motion)) changed = true;
        }
        // The peek's hole is drawn after the panes'.
        var next_hole = self.slots.items.len;
        if (self.peek_slot.webview) |wv| {
            if (self.peek_slot.place(wv, holes, next_hole, s.reduce_motion)) changed = true;
            next_hole += 1;
        }
        if (self.web_panel_slot.webview) |wv| {
            if (self.web_panel_slot.place(wv, holes, next_hole, s.reduce_motion)) changed = true;
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

fn setAlpha(wv: objc.Object, alpha: f32) void {
    objc.msg(void, wv, if (comptime platform.is_ios) "setAlpha:" else "setAlphaValue:", .{@as(f64, alpha)});
}

fn fadeIn(wv: objc.Object, alpha: f32) void {
    if (comptime platform.is_ios) return setAlpha(wv, alpha);
    const pool = objc.Pool.push();
    defer pool.pop();
    var f: Fade = .{ .wv = wv, .alpha = alpha };
    var block = objc.Block(Fade, &.{objc.Object}).init(&f, runFade);
    objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:", .{@as(*anyopaque, @ptrCast(&block))});
}

fn animateSwitch(wv: objc.Object, reduce_motion: bool) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const layer = objc.msg(?objc.Object, wv, "layer", .{}) orelse return;
    const timing = objc.msg(objc.Object, objc.class("CAMediaTimingFunction"), "functionWithControlPoints::::", .{ @as(f32, 0.2), @as(f32, 0.9), @as(f32, 0.3), @as(f32, 1.0) });
    const dur: f64 = if (reduce_motion) 0.12 else 0.22;
    const op = objc.msg(objc.Object, objc.class("CABasicAnimation"), "animationWithKeyPath:", .{objc.nsString("opacity")});
    objc.msg(void, op, "setFromValue:", .{objc.msg(objc.Object, objc.class("NSNumber"), "numberWithDouble:", .{@as(f64, 0)})});
    objc.msg(void, op, "setToValue:", .{objc.msg(objc.Object, objc.class("NSNumber"), "numberWithDouble:", .{@as(f64, 1)})});
    objc.msg(void, op, "setDuration:", .{dur});
    objc.msg(void, op, "setTimingFunction:", .{timing});
    objc.msg(void, layer, "addAnimation:forKey:", .{ op, objc.nsString("kea.page.opacity") });
    if (reduce_motion) return;
    const bounds = objc.msg(objc.CGRect, wv, "bounds", .{});
    const w = bounds.size.width;
    const h = bounds.size.height;
    const from_tf = CATransform3DConcat(CATransform3DMakeScale(0.985, 0.985, 1), CATransform3DMakeTranslation(w * 0.0075, h * 0.0075, 0));
    const tr = objc.msg(objc.Object, objc.class("CABasicAnimation"), "animationWithKeyPath:", .{objc.nsString("transform")});
    objc.msg(void, tr, "setFromValue:", .{objc.msg(objc.Object, objc.class("NSValue"), "valueWithCATransform3D:", .{from_tf})});
    objc.msg(void, tr, "setToValue:", .{objc.msg(objc.Object, objc.class("NSValue"), "valueWithCATransform3D:", .{CATransform3DIdentity})});
    objc.msg(void, tr, "setDuration:", .{dur});
    objc.msg(void, tr, "setTimingFunction:", .{timing});
    objc.msg(void, layer, "addAnimation:forKey:", .{ tr, objc.nsString("kea.page.transform") });
}

/// `view` into `stage` just under `below`; on top with none.
fn addBelow(stage: objc.Object, view: objc.Object, below: ?objc.Object) void {
    const b = below orelse return objc.msg(void, stage, "addSubview:", .{view});
    if (comptime platform.is_ios) return objc.msg(void, stage, "insertSubview:belowSubview:", .{ view, b });
    // `NSWindowBelow`.
    objc.msg(void, stage, "addSubview:positioned:relativeTo:", .{ view, @as(objc.NSInteger, -1), b });
}

fn rectsEq(a: ui.Rect, b: ui.Rect) bool {
    return @abs(a.x - b.x) < 0.25 and @abs(a.y - b.y) < 0.25 and @abs(a.w - b.w) < 0.25 and @abs(a.h - b.h) < 0.25;
}

fn frameOf(view: objc.Object) ui.Rect {
    const f = objc.msg(objc.CGRect, view, "frame", .{});
    return .{ .x = @floatCast(f.origin.x), .y = @floatCast(f.origin.y), .w = @floatCast(f.size.width), .h = @floatCast(f.size.height) };
}

fn setFrame(view: objc.Object, r: ui.Rect) void {
    objc.msg(void, view, "setFrame:", .{objc.CGRect{
        .origin = .{ .x = r.x, .y = r.y },
        .size = .{ .width = r.w, .height = r.h },
    }});
}

/// Clips to the bounds for round corners, and for a docked inspector,
/// which must never spill out of its pane.
fn applyCornerRadius(view: objc.Object, radius: f32, docked: bool) void {
    if (comptime !platform.is_ios) objc.msg(void, view, "setWantsLayer:", .{objc.YES});
    if (objc.msg(?objc.Object, view, "layer", .{})) |layer| {
        objc.msg(void, layer, "setCornerRadius:", .{@as(f64, radius)});
        objc.msg(void, layer, "setCornerCurve:", .{objc.nsString("continuous")});
        objc.msg(void, layer, "setMasksToBounds:", .{if (radius > 0 or docked) objc.YES else objc.NO});
    }
}

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}
