//! Hybrid StageHost: hosts 1–2 live `WKWebView` panes (plus an optional Peek
//! webview) inside a flipped `PageStageView` positioned directly behind
//! `NanoUIView` (`Surface`), and synchronizes their frames in `after_frame`
//! on the same run-loop turn.
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

    fn setHidden(slot: *PaneSlot, wv: objc.Object, on: bool) void {
        if (slot.hidden == on) return;
        slot.hidden = on;
        objc.msg(void, wv, "setHidden:", .{on});
    }
};

pub const StageHost = struct {
    gpa: std.mem.Allocator,
    surface: *Surface,
    stage_view: objc.Object,
    slots: [2]PaneSlot = @splat(.{}),
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
        objc.release(self.stage_view);
        self.gpa.destroy(self);
    }

    /// Sets the active WKWebView(s) for the primary and optional secondary split pane.
    pub fn setPanes(self: *StageHost, primary: ?objc.Object, secondary: ?objc.Object, framed: bool) void {
        self.card_radius = if (framed) 10 else 0;
        self.updateSlot(0, primary);
        self.updateSlot(1, secondary);
    }

    /// Drops every slot holding `webview` (its tab is about to free it).
    pub fn forget(self: *StageHost, webview: objc.Object) void {
        for (&self.slots) |*slot| {
            if (slot.webview == webview) slot.* = .{};
        }
        if (self.peek_slot.webview == webview) self.peek_slot = .{};
        objc.msg(void, webview, "removeFromSuperview", .{});
    }

    pub fn setPeek(self: *StageHost, webview: ?objc.Object) void {
        if (self.peek_slot.webview == webview) return;
        if (self.peek_slot.webview) |old| objc.msg(void, old, "removeFromSuperview", .{});
        self.peek_slot.webview = webview;
        self.peek_slot.last_rect = .{};
        if (webview) |wv| {
            objc.msg(void, self.stage_view, "addSubview:", .{wv});
            objc.msg(void, wv, "setHidden:", .{objc.NO});
            self.peek_slot.hidden = false;
            applyCornerRadius(wv, 12);
        }
    }

    fn updateSlot(self: *StageHost, idx: usize, webview: ?objc.Object) void {
        const slot = &self.slots[idx];
        if (slot.webview == webview) {
            if (webview) |wv| {
                if (slot.corner_radius != self.card_radius) {
                    slot.corner_radius = self.card_radius;
                    applyCornerRadius(wv, self.card_radius);
                }
            }
            return;
        }
        if (slot.webview) |old| {
            // Only remove if the other slot isn't using it right now.
            const other = self.slots[1 - idx].webview;
            if (other != old) objc.msg(void, old, "removeFromSuperview", .{});
        }
        slot.webview = webview;
        slot.last_rect = .{};
        slot.corner_radius = self.card_radius;
        if (webview) |wv| {
            const sup = objc.msg(?objc.Object, wv, "superview", .{});
            if (sup != self.stage_view) objc.msg(void, self.stage_view, "addSubview:", .{wv});
            objc.msg(void, wv, "setHidden:", .{objc.NO});
            slot.hidden = false;
            applyCornerRadius(wv, self.card_radius);
        }
    }

    fn applyCornerRadius(wv: objc.Object, radius: f32) void {
        objc.msg(void, wv, "setWantsLayer:", .{objc.YES});
        if (objc.msg(?objc.Object, wv, "layer", .{})) |layer| {
            objc.msg(void, layer, "setCornerRadius:", .{@as(f64, radius)});
            objc.msg(void, layer, "setMasksToBounds:", .{if (radius > 0) objc.YES else objc.NO});
        }
    }

    fn onAfterFrame(ctx: ?*anyopaque, s: *Surface) void {
        const self: *StageHost = @ptrCast(@alignCast(ctx));
        const holes = s.ctx.stage_rects[0..s.ctx.stage_count];
        if (self.on_rects) |cb| cb(self.on_rects_ctx, holes);
        for (&self.slots, 0..) |*slot, i| {
            const wv = slot.webview orelse continue;
            if (i < holes.len and holes[i].w > 1 and holes[i].h > 1) {
                const r = holes[i];
                slot.setHidden(wv, false);
                if (!rectsEq(slot.last_rect, r)) {
                    slot.last_rect = r;
                    objc.msg(void, wv, "setFrame:", .{objc.CGRect{
                        .origin = .{ .x = r.x, .y = r.y },
                        .size = .{ .width = r.w, .height = r.h },
                    }});
                }
            } else {
                slot.setHidden(wv, true);
            }
        }
        if (self.peek_slot.webview) |wv| {
            if (holes.len >= 3) {
                const r = holes[2];
                self.peek_slot.setHidden(wv, false);
                if (!rectsEq(self.peek_slot.last_rect, r)) {
                    self.peek_slot.last_rect = r;
                    objc.msg(void, wv, "setFrame:", .{objc.CGRect{
                        .origin = .{ .x = r.x, .y = r.y },
                        .size = .{ .width = r.w, .height = r.h },
                    }});
                }
            } else {
                self.peek_slot.setHidden(wv, true);
            }
        }
    }

    fn rectsEq(a: ui.Rect, b: ui.Rect) bool {
        return @abs(a.x - b.x) < 0.25 and @abs(a.y - b.y) < 0.25 and @abs(a.w - b.w) < 0.25 and @abs(a.h - b.h) < 0.25;
    }
};

fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}
