//! Stage pictures (`PaneStage.pictures` in PaneStage.swift:744-821, and
//! `Tab.cover` in Stage.swift:33-44): `NSImageView` subviews inside
//! `StageHost.stage_view`, above the `WKWebView` slots and below the Metal
//! `NanoUIView` (`Surface.nsview`). Core Animation drives their frame and
//! opacity transitions through `animator`, so moving pictures cost zero Zig
//! frames.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;

pub const Curve = enum {
    glide,
    ease_out,
    linear,
};

pub const Entry = struct {
    key: u64,
    view: objc.Object,
    serial: usize,
    tag: u32 = 0,
    fading_out: bool = false,
};

var next_serial: usize = 0;

pub const StagePictures = struct {
    entries: std.ArrayList(Entry) = .empty,
    stage_view: ?objc.Object = null,

    pub fn deinit(self: *StagePictures, gpa: std.mem.Allocator) void {
        self.clear();
        self.entries.deinit(gpa);
    }

    pub fn prune(self: *StagePictures) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const v = self.entries.items[i].view;
            if (objc.msg(?objc.Object, v, "superview", .{}) == null) {
                _ = self.entries.orderedRemove(i);
                objc.release(v);
            } else {
                i += 1;
            }
        }
    }

    pub fn clear(self: *StagePictures) void {
        for (self.entries.items) |e| {
            objc.setZig(e.view, @as(?*anyopaque, null));
            if (objc.msg(?objc.Object, e.view, "layer", .{})) |l| objc.msg(void, l, "removeAllAnimations", .{});
            objc.msg(void, e.view, "removeFromSuperview", .{});
            objc.release(e.view);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn clearMoves(self: *StagePictures) void {
        self.prune();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (!isCoverKey(self.entries.items[i].key)) {
                const e = self.entries.orderedRemove(i);
                objc.setZig(e.view, @as(?*anyopaque, null));
                if (objc.msg(?objc.Object, e.view, "layer", .{})) |l| objc.msg(void, l, "removeAllAnimations", .{});
                objc.msg(void, e.view, "removeFromSuperview", .{});
                objc.release(e.view);
            } else {
                i += 1;
            }
        }
    }

    pub fn get(self: *StagePictures, key: u64) ?objc.Object {
        self.prune();
        for (self.entries.items) |e| {
            if (e.key == key) return e.view;
        }
        return null;
    }

    pub fn getEntry(self: *StagePictures, key: u64) ?*Entry {
        self.prune();
        for (self.entries.items) |*e| {
            if (e.key == key) return e;
        }
        return null;
    }

    pub fn remove(self: *StagePictures, key: u64) void {
        for (self.entries.items, 0..) |e, i| {
            if (e.key == key) {
                _ = self.entries.orderedRemove(i);
                objc.setZig(e.view, @as(?*anyopaque, null));
                if (objc.msg(?objc.Object, e.view, "layer", .{})) |l| objc.msg(void, l, "removeAllAnimations", .{});
                objc.msg(void, e.view, "removeFromSuperview", .{});
                objc.release(e.view);
                return;
            }
        }
    }

    /// Shows `image` (`NSImage`) at `rect` (in `stage_view` coordinates) with
    /// continuous corners of `radius` and `ground` layer background.
    pub fn show(
        self: *StagePictures,
        gpa: std.mem.Allocator,
        stage_view: objc.Object,
        key: u64,
        image: ?objc.Object,
        rect: ui.Rect,
        radius: f32,
        ground: ui.Color,
        border: ?ui.Color,
    ) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (self.stage_view != stage_view) {
            self.clear();
            self.stage_view = stage_view;
        }
        next_serial +%= 1;
        if (next_serial == 0) next_serial = 1;
        const serial = next_serial;
        const view = if (self.getEntry(key)) |e| blk: {
            e.serial = serial;
            e.fading_out = false;
            if (objc.msg(?objc.Object, e.view, "layer", .{})) |l| objc.msg(void, l, "removeAllAnimations", .{});
            break :blk e.view;
        } else blk: {
            const v = objc.msg(objc.Object, objc.msg(objc.Object, pictureViewClass(), "alloc", .{}), "initWithFrame:", .{cgRect(rect)});
            objc.msg(void, v, "setImageScaling:", .{@as(objc.NSUInteger, 2)}); // NSImageScaleNone
            objc.msg(void, v, "setImageAlignment:", .{@as(objc.NSUInteger, 2)}); // NSImageAlignTopLeft
            objc.msg(void, v, "setWantsLayer:", .{objc.YES});
            self.entries.append(gpa, .{ .key = key, .view = v, .serial = serial }) catch {
                objc.release(v);
                return;
            };
            break :blk v;
        };
        objc.setZig(view, @as(*anyopaque, @ptrFromInt(serial)));
        objc.msg(void, view, "setFrame:", .{cgRect(rect)});
        objc.msg(void, view, "setAlphaValue:", .{@as(f64, 1)});
        objc.msg(void, view, "setImage:", .{image});
        styleLayer(view, radius, ground, border);
        bringToFront(stage_view, view);
    }

    /// Shows a stand-in stage picture at `rect` immediately, and if `!testing`
    /// and `wv` is visible on a window, requests an async WebKit snapshot that
    /// populates the moving picture view if it arrives within 50 ms.
    pub fn showSnapshot(
        self: *StagePictures,
        gpa: std.mem.Allocator,
        stage_view: objc.Object,
        key: u64,
        wv: ?objc.Object,
        rect: ui.Rect,
        radius: f32,
        testing: bool,
        ground: ui.Color,
        hairline: ui.Color,
    ) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const stand = standIn(.{ .w = rect.w, .h = rect.h });
        defer if (stand) |s| objc.release(s);
        self.show(gpa, stage_view, key, stand, rect, radius, ground, hairline);
        if (testing) return;
        const web = wv orelse return;
        if (objc.msg(?objc.Object, web, "window", .{}) == null or objc.msg(objc.BOOL, web, "isHidden", .{})) return;
        const e = self.getEntry(key) orelse return;
        const job = std.heap.c_allocator.create(AsyncSnap) catch return;
        job.* = .{
            .view = objc.retain(e.view),
            .serial = e.serial,
            .deadline = ui.clock.now() + 0.05,
        };
        var block = objc.Block(AsyncSnap, &.{ ?objc.Object, ?objc.Object }).init(job, AsyncSnap.arrived);
        objc.msg(void, web, "takeSnapshotWithConfiguration:completionHandler:", .{ @as(?objc.Object, null), @as(*anyopaque, @ptrCast(&block)) });
    }

    /// Decodes JPEG/PNG `bytes` into a full-resolution `NSImage` sized to fill
    /// `rect` from the top-left (`Stage.swift:39-41`) and shows it in `stage_view`.
    pub fn showBytes(
        self: *StagePictures,
        gpa: std.mem.Allocator,
        stage_view: objc.Object,
        key: u64,
        bytes: []const u8,
        rect: ui.Rect,
        radius: f32,
        ground: ui.Color,
    ) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const data = objc.msg(?objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, bytes.len }) orelse return;
        const img = objc.msg(?objc.Object, objc.msg(objc.Object, objc.class("NSImage"), "alloc", .{}), "initWithData:", .{data}) orelse return;
        defer objc.release(img);
        sizeImageToFill(img, rect);
        self.show(gpa, stage_view, key, img, rect, radius, ground, null);
    }

    /// Updates an existing picture's frame/style in place without resetting its
    /// animations or recreating the `NSImage`.
    pub fn place(self: *StagePictures, stage_view: objc.Object, key: u64, rect: ui.Rect, radius: f32, ground: ui.Color) void {
        const e = self.getEntry(key) orelse return;
        const cur = objc.msg(objc.CGRect, e.view, "frame", .{});
        if (@abs(cur.origin.x - rect.x) > 0.25 or @abs(cur.origin.y - rect.y) > 0.25 or
            @abs(cur.size.width - rect.w) > 0.25 or @abs(cur.size.height - rect.h) > 0.25)
        {
            objc.msg(void, e.view, "setFrame:", .{cgRect(rect)});
            if (isCoverKey(key)) {
                if (objc.msg(?objc.Object, e.view, "image", .{})) |img| sizeImageToFill(img, rect);
            }
        }
        styleLayer(e.view, radius, ground, null);
        bringToFront(stage_view, e.view);
    }

    /// Moves `key`'s view to `to_rect` over `duration` seconds with `curve`
    /// using `NSAnimationContext.runAnimationGroup:` and `[[view animator] setFrame:]`.
    pub fn move(self: *StagePictures, key: u64, to_rect: ui.Rect, duration: f64, curve: Curve) void {
        const e = self.getEntry(key) orelse return;
        const pool = objc.Pool.push();
        defer pool.pop();
        var act = MoveCtx{ .view = e.view, .rect = cgRect(to_rect), .duration = duration, .curve = curve };
        var group = objc.Block(MoveCtx, &.{objc.Object}).init(&act, MoveCtx.run);
        objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:", .{&group});
    }

    /// Fades `key`'s view to `to_alpha` over `duration` seconds with `curve`,
    /// optionally removing the picture when the fade completes.
    pub fn fade(self: *StagePictures, key: u64, to_alpha: f32, duration: f64, curve: Curve, remove_after: bool) void {
        const e = self.getEntry(key) orelse return;
        e.fading_out = to_alpha == 0 and remove_after;
        fadeView(e.view, e.serial, to_alpha, duration, curve, remove_after);
    }

    /// `PaneStage.animate`: moves `key` from its current frame to `to_rect`
    /// over `0.32 s` with `.glide` (or insets by 1% and fades to 0 when
    /// `to_rect` is null for a leaving pane), then fades out over `0.12 s`
    /// and removes the view. Under Reduce Motion, only a `0.15 s` fade runs.
    pub fn animateMove(self: *StagePictures, key: u64, to_rect: ?ui.Rect, reduced: bool) void {
        const e = self.getEntry(key) orelse return;
        if (reduced) {
            self.fade(key, 0, 0.15, .ease_out, true);
            return;
        }
        const pool = objc.Pool.push();
        defer pool.pop();
        const cur = objc.msg(objc.CGRect, e.view, "frame", .{});
        const target = if (to_rect) |r| cgRect(r) else insetFraction(cur, 0.01);
        var act = TravelCtx{
            .view = e.view,
            .rect = target,
            .fade_too = to_rect == null,
            .duration = 0.32,
        };
        var group = objc.Block(TravelCtx, &.{objc.Object}).init(&act, TravelCtx.run);
        if (to_rect != null) {
            const after = std.heap.c_allocator.create(ThenFadeDone) catch {
                objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:", .{&group});
                return;
            };
            after.* = .{ .view = objc.retain(e.view), .serial = e.serial };
            var comp = objc.Block(ThenFadeDone, &.{}).init(after, ThenFadeDone.finish);
            objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:completionHandler:", .{ &group, &comp });
        } else {
            e.fading_out = true;
            const done = std.heap.c_allocator.create(RemoveDone) catch {
                objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:", .{&group});
                return;
            };
            done.* = .{ .view = objc.retain(e.view), .serial = e.serial };
            var comp = objc.Block(RemoveDone, &.{}).init(done, RemoveDone.finish);
            objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:completionHandler:", .{ &group, &comp });
        }
    }
};

pub fn coverKey(tab_id: u64) u64 {
    return tab_id | (@as(u64, 1) << 63);
}

pub fn isCoverKey(key: u64) bool {
    return (key & (@as(u64, 1) << 63)) != 0;
}

fn sizeImageToFill(img: objc.Object, rect: ui.Rect) void {
    const reps = objc.msg(?objc.Object, img, "representations", .{}) orelse return;
    const rep = objc.msg(?objc.Object, reps, "firstObject", .{}) orelse return;
    const pw = objc.msg(objc.NSInteger, rep, "pixelsWide", .{});
    const ph = objc.msg(objc.NSInteger, rep, "pixelsHigh", .{});
    if (pw <= 0 or ph <= 0) return;
    const fw: f64 = @floatFromInt(pw);
    const fh: f64 = @floatFromInt(ph);
    const k = @max(@as(f64, @max(1, rect.w)) / fw, @as(f64, @max(1, rect.h)) / fh);
    objc.msg(void, img, "setSize:", .{objc.CGSize{ .width = fw * k, .height = fh * k }});
}

fn bringToFront(stage_view: objc.Object, view: objc.Object) void {
    if (objc.msg(?objc.Object, stage_view, "subviews", .{})) |subs| {
        if (objc.msg(?objc.Object, subs, "lastObject", .{}) == view) return;
    }
    objc.msg(void, stage_view, "addSubview:", .{view});
}

fn fadeView(view: objc.Object, serial: usize, to_alpha: f32, duration: f64, curve: Curve, remove_after: bool) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (duration <= 0) {
        objc.msg(void, view, "setAlphaValue:", .{@as(f64, to_alpha)});
        if (remove_after) {
            objc.setZig(view, @as(?*anyopaque, null));
            objc.msg(void, view, "removeFromSuperview", .{});
        }
        return;
    }
    var act = FadeCtx{ .view = view, .alpha = to_alpha, .duration = duration, .curve = curve };
    var group = objc.Block(FadeCtx, &.{objc.Object}).init(&act, FadeCtx.run);
    if (remove_after) {
        const done = std.heap.c_allocator.create(RemoveDone) catch {
            objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:", .{&group});
            objc.setZig(view, @as(?*anyopaque, null));
            objc.msg(void, view, "removeFromSuperview", .{});
            return;
        };
        done.* = .{ .view = objc.retain(view), .serial = serial };
        var comp = objc.Block(RemoveDone, &.{}).init(done, RemoveDone.finish);
        objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:completionHandler:", .{ &group, &comp });
    } else {
        objc.msg(void, objc.class("NSAnimationContext"), "runAnimationGroup:", .{&group});
    }
}

const AsyncSnap = struct {
    view: objc.Object,
    serial: usize,
    deadline: f64,

    fn arrived(self: *AsyncSnap, img: ?objc.Object, _: ?objc.Object) void {
        defer std.heap.c_allocator.destroy(self);
        defer objc.release(self.view);
        const image = img orelse return;
        if (ui.clock.now() > self.deadline) return;
        if (objc.msg(?objc.Object, self.view, "superview", .{}) == null) return;
        if (@intFromPtr(objc.getZig(anyopaque, self.view)) != self.serial) return;
        objc.msg(void, self.view, "setImage:", .{image});
        if (objc.msg(?objc.Object, self.view, "layer", .{})) |layer| {
            objc.msg(void, layer, "setBorderWidth:", .{@as(f64, 0)});
        }
    }
};

/// `PaneStage.standIn`: a retained `NSImage` of `size`, so test runs on
/// hidden windows have a valid image.
pub fn standIn(size: ui.Size) ?objc.Object {
    const w = @max(1, size.w);
    const h = @max(1, size.h);
    return objc.msg(?objc.Object, objc.msg(objc.Object, objc.class("NSImage"), "alloc", .{}), "initWithSize:", .{
        objc.CGSize{ .width = w, .height = h },
    });
}

const MoveCtx = struct {
    view: objc.Object,
    rect: objc.CGRect,
    duration: f64,
    curve: Curve,

    fn run(self: *MoveCtx, ctx: objc.Object) void {
        objc.msg(void, ctx, "setDuration:", .{self.duration});
        objc.msg(void, ctx, "setTimingFunction:", .{timingFunction(self.curve)});
        objc.msg(void, ctx, "setAllowsImplicitAnimation:", .{objc.YES});
        const anim = objc.msg(objc.Object, self.view, "animator", .{});
        objc.msg(void, anim, "setFrame:", .{self.rect});
    }
};

const FadeCtx = struct {
    view: objc.Object,
    alpha: f32,
    duration: f64,
    curve: Curve,

    fn run(self: *FadeCtx, ctx: objc.Object) void {
        objc.msg(void, ctx, "setDuration:", .{self.duration});
        objc.msg(void, ctx, "setTimingFunction:", .{timingFunction(self.curve)});
        objc.msg(void, ctx, "setAllowsImplicitAnimation:", .{objc.YES});
        const anim = objc.msg(objc.Object, self.view, "animator", .{});
        objc.msg(void, anim, "setAlphaValue:", .{@as(f64, self.alpha)});
    }
};

const TravelCtx = struct {
    view: objc.Object,
    rect: objc.CGRect,
    fade_too: bool,
    duration: f64,

    fn run(self: *TravelCtx, ctx: objc.Object) void {
        objc.msg(void, ctx, "setDuration:", .{self.duration});
        objc.msg(void, ctx, "setTimingFunction:", .{timingFunction(.glide)});
        objc.msg(void, ctx, "setAllowsImplicitAnimation:", .{objc.YES});
        const anim = objc.msg(objc.Object, self.view, "animator", .{});
        objc.msg(void, anim, "setFrame:", .{self.rect});
        if (self.fade_too) objc.msg(void, anim, "setAlphaValue:", .{@as(f64, 0)});
    }
};

const ThenFadeDone = struct {
    view: objc.Object,
    serial: usize,

    fn finish(self: *ThenFadeDone) void {
        defer std.heap.c_allocator.destroy(self);
        defer objc.release(self.view);
        if (objc.msg(?objc.Object, self.view, "superview", .{}) == null) return;
        if (@intFromPtr(objc.getZig(anyopaque, self.view)) != self.serial) return;
        fadeView(self.view, self.serial, 0, 0.12, .ease_out, true);
    }
};

const RemoveDone = struct {
    view: objc.Object,
    serial: usize,

    fn finish(self: *RemoveDone) void {
        defer std.heap.c_allocator.destroy(self);
        defer objc.release(self.view);
        if (objc.msg(?objc.Object, self.view, "superview", .{}) == null) return;
        if (@intFromPtr(objc.getZig(anyopaque, self.view)) != self.serial) return;
        objc.setZig(self.view, @as(?*anyopaque, null));
        objc.msg(void, self.view, "removeFromSuperview", .{});
    }
};

fn timingFunction(curve: Curve) objc.Object {
    const cls = objc.class("CAMediaTimingFunction");
    return switch (curve) {
        .glide => objc.msg(objc.Object, cls, "functionWithControlPoints::::", .{
            @as(f32, 0.22), @as(f32, 1.0), @as(f32, 0.36), @as(f32, 1.0),
        }),
        .ease_out => objc.msg(objc.Object, cls, "functionWithName:", .{objc.nsString("easeOut")}),
        .linear => objc.msg(objc.Object, cls, "functionWithName:", .{objc.nsString("linear")}),
    };
}

fn styleLayer(view: objc.Object, radius: f32, ground: ui.Color, border: ?ui.Color) void {
    const layer = objc.msg(?objc.Object, view, "layer", .{}) orelse return;
    if (cgColor(ground)) |cgc| objc.msg(void, layer, "setBackgroundColor:", .{cgc});
    if (border) |b| {
        if (cgColor(b)) |bc| objc.msg(void, layer, "setBorderColor:", .{bc});
        objc.msg(void, layer, "setBorderWidth:", .{@as(f64, 1)});
    } else {
        objc.msg(void, layer, "setBorderWidth:", .{@as(f64, 0)});
    }
    objc.msg(void, layer, "setCornerRadius:", .{@as(f64, radius)});
    objc.msg(void, layer, "setCornerCurve:", .{objc.nsString("continuous")});
    objc.msg(void, layer, "setMasksToBounds:", .{if (radius > 0) objc.YES else objc.NO});
}

fn cgColor(c: ui.Color) ?objc.Object {
    const ns = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, c.r), @as(f64, c.g), @as(f64, c.b), @as(f64, c.a),
    });
    return objc.msg(?objc.Object, ns, "CGColor", .{});
}

fn cgRect(r: ui.Rect) objc.CGRect {
    return .{
        .origin = .{ .x = r.x, .y = r.y },
        .size = .{ .width = r.w, .height = r.h },
    };
}

fn insetFraction(r: objc.CGRect, f: f64) objc.CGRect {
    const dx = r.size.width * f;
    const dy = r.size.height * f;
    return .{
        .origin = .{ .x = r.origin.x + dx, .y = r.origin.y + dy },
        .size = .{ .width = @max(0, r.size.width - 2 * dx), .height = @max(0, r.size.height - 2 * dy) },
    };
}

fn pictureViewClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaStagePictureView",
        .superclass = "NSImageView",
        .methods = &.{
            .{ .name = "hitTest:", .imp = &hitNothing, .types = "@@:{CGPoint=dd}" },
        },
    });
}

fn hitNothing(_: objc.Object, _: objc.SEL, _: objc.CGPoint) callconv(.c) ?objc.Object {
    return null;
}
