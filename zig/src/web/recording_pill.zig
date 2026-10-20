//! The recording pill (RecordingIndicator.swift 85-217): "● Loom is
//! recording your screen — Stop", a small panel of KeaZig's own at the foot
//! of the screen for as long as an extension records anything, beside
//! macOS's own sharing item and dots. It never takes the keys or the focus.
//! What is recording is `ext/capture_watch.zig`'s to say; this shows it.
//! An offscreen document that records is lent to the pill — a 2×2 point
//! view behind its content — while it does, and given back after: WebKit
//! won't start a capture from a page nobody sees. A test run keeps it off
//! every screen, whatever it would show.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Kea = @import("../app/kea.zig").Kea;
const palette = @import("../design/palette.zig");
const controls = @import("../chrome/controls.zig");
const capture = @import("../ext/capture.zig");
const watch = @import("../ext/capture_watch.zig");

const heap = std.heap.c_allocator;

const Pill = struct {
    kea: *Kea,
    window: *nanoui.Window,
    /// Where lent pages go (retained).
    lending: objc.Object,
    ready: bool = false,
    /// The pill's size as last laid out.
    size: ?ui.Rect = null,
};

/// A page lent to the pill and where it came from (both retained).
const Hosted = struct { web: objc.Object, home: ?objc.Object };

var panel: ?*Pill = null;
var hosted: std.ArrayList(Hosted) = .empty;

/// The capture model's hooks (`RecordingIndicator.shared`).
pub fn install() void {
    watch.pill = lend;
    watch.on_change = settle;
}

fn lend(web: objc.Object, on: bool) void {
    if (on) host(web) else release(web);
}

/// An offscreen document's page, lent so that WebKit counts it as seen.
fn host(web: objc.Object) void {
    for (hosted.items) |h| if (h.web == web) return;
    const home = objc.msg(?objc.Object, web, "superview", .{});
    hosted.append(heap, .{ .web = objc.retain(web), .home = if (home) |v| objc.retain(v) else null }) catch return;
    const p = own() orelse return;
    objc.msg(void, web, "removeFromSuperview", .{});
    objc.msg(void, web, "setFrame:", .{objc.msg(objc.CGRect, p.lending, "bounds", .{})});
    objc.msg(void, p.lending, "addSubview:", .{web});
    settle();
}

/// Given back to where it was, or to nowhere if it had no home.
fn release(web: objc.Object) void {
    for (hosted.items, 0..) |h, i| if (h.web == web) {
        _ = hosted.orderedRemove(i);
        objc.msg(void, web, "removeFromSuperview", .{});
        if (h.home) |v| {
            objc.msg(void, v, "addSubview:", .{web});
            objc.release(v);
        }
        objc.release(web);
        return settle();
    };
}

/// Up while anything records or a page is lent to it; down otherwise.
fn settle() void {
    const wanted = watch.recordings.items.len > 0 or hosted.items.len > 0;
    if (!wanted) {
        if (panel) |p| objc.msg(void, p.window.nswindow, "orderOut:", .{@as(?objc.Object, null)});
        return;
    }
    const p = own() orelse return;
    fit(p);
    if (p.kea.opts.root != null or p.kea.opts.hidden) return;
    if (!p.window.isVisible()) objc.msg(void, p.window.nswindow, "orderFrontRegardless", .{});
}

/// The panel: borderless, never key or main, over every space and full
/// screen app.
fn own() ?*Pill {
    if (panel) |p| return p;
    const kea = capture.kea() orelse return null;
    const app = kea.ui_app orelse return null;
    const self = heap.create(Pill) catch return null;
    const off: ?f64 = if (kea.opts.hidden) -20000 else null;
    const win = app.newWindow(.{
        .width = 320,
        .height = 40,
        .resizable = false,
        .visible = false,
        .x = off,
        .y = off,
        .kind = .panel,
        .floating = true,
        .all_spaces = true,
        .non_activating = true,
        .on_close = .{ .ctx = self, .func = closed },
        .content = .{ .view = ui.View.init(self, view) },
    }) catch {
        heap.destroy(self);
        return null;
    };
    const ns = win.nswindow;
    // Borderless | nonactivating; NSStatusWindowLevel; canJoinAllSpaces |
    // stationary | ignoresCycle | fullScreenAuxiliary.
    objc.msg(void, ns, "setStyleMask:", .{@as(objc.NSUInteger, 1 << 7)});
    objc.msg(void, ns, "setLevel:", .{@as(objc.NSInteger, 25)});
    objc.msg(void, ns, "setCollectionBehavior:", .{@as(objc.NSUInteger, 1 | 16 | 64 | 256)});
    objc.msg(void, ns, "setHidesOnDeactivate:", .{objc.NO});
    objc.msg(void, ns, "setBecomesKeyOnlyIfNeeded:", .{objc.YES});
    objc.msg(void, ns, "setMovableByWindowBackground:", .{objc.YES});
    objc.msg(void, ns, "setOpaque:", .{objc.NO});
    objc.msg(void, ns, "setBackgroundColor:", .{objc.msg(objc.Object, objc.class("NSColor"), "clearColor", .{})});
    objc.msg(void, ns, "setHasShadow:", .{objc.YES});
    if (win.surface) |s| s.setTransparent(true);
    const lending = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{ .origin = .{ .x = 2, .y = 2 }, .size = .{ .width = 2, .height = 2 } }});
    const content = objc.msg(objc.Object, ns, "contentView", .{});
    // NSWindowBelow: behind the pill's own content.
    objc.msg(void, content, "addSubview:positioned:relativeTo:", .{ lending, @as(objc.NSInteger, -1), @as(?objc.Object, null) });
    self.* = .{ .kea = kea, .window = win, .lending = lending, .ready = true };
    panel = self;
    return self;
}

const pill_key = "kea.recording.pill";

/// Its size for what it says, at the foot of the screen, centred.
fn fit(p: *Pill) void {
    const s = p.window.surface orelse return;
    // Laid out, then read back by the next frame's view.
    s.frame();
    s.frame();
    const r = p.size orelse return;
    const size: objc.CGSize = .{ .width = @max(10, r.w), .height = @max(10, r.h) };
    const ns = p.window.nswindow;
    if (p.kea.opts.hidden) return p.window.setSize(size.width, size.height);
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const screen = blk: {
        if (objc.msg(?objc.Object, app, "keyWindow", .{})) |w| if (objc.msg(?objc.Object, w, "screen", .{})) |sc| break :blk sc;
        if (objc.msg(?objc.Object, app, "mainWindow", .{})) |w| if (objc.msg(?objc.Object, w, "screen", .{})) |sc| break :blk sc;
        break :blk objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{});
    };
    const area: objc.CGRect = if (screen) |sc| objc.msg(objc.CGRect, sc, "visibleFrame", .{}) else .{ .size = .{ .width = 1440, .height = 900 } };
    var frame: objc.CGRect = .{ .origin = .{ .x = area.origin.x + area.size.width / 2 - size.width / 2, .y = area.origin.y + 24 }, .size = size };
    if (p.window.isVisible()) frame.origin = objc.msg(objc.CGRect, ns, "frame", .{}).origin;
    objc.msg(void, ns, "setFrame:display:", .{ frame, objc.YES });
    s.frame();
}

fn px(v: f32) ui.Length {
    return .{ .px = v };
}

/// A line per extension recording, each with Stop.
fn view(p: *Pill, c: *ui.Context) void {
    c.hand_cursor = false;
    if (!p.ready) return;
    const pal = palette.get(c.theme.dark);
    const i = c.open(.{ .direction = .column, .gap = 4, .padding = .{ .left = 14, .right = 7, .top = 7, .bottom = 7 }, .radius = 18, .background = pal.ground, .border = pal.hairline }, pill_key);
    defer c.end();
    c.addA11y(i, .group, "Recording", "", false, true);
    p.size = c.rects.get(c.node(i).id);
    for (watch.recordings.items) |r| {
        ui.key(c, r.id);
        ui.row(c, .{ .gap = 8, .align_items = .center });
        defer ui.end(c);
        // The pill's one colour: a recording is known at a glance by its red dot.
        _ = c.leaf(.{ .width = px(7), .height = px(7), .radius = 3.5, .background = pal.red }, .none, null);
        ui.row(c, .{ .align_items = .center });
        ui.text(c, r.name, .{ .size = 12.5, .weight = .semibold, .color = pal.ink });
        ui.text(c, c.print(" {s}", .{r.what()}), .{ .size = 12.5, .color = pal.ink });
        ui.end(c);
        _ = c.leaf(.{ .width = px(12) }, .none, null);
        const stop = c.open(.{ .padding = .{ .left = 11, .right = 11 }, .height = px(22), .radius = controls.capsule, .background = pal.ink, .align_items = .center, .justify = .center, .control = true }, null);
        const it = c.interact(stop, .{});
        c.addA11y(stop, .button, c.print("Stop {s}", .{r.name}), "", false, true);
        ui.text(c, "Stop", .{ .size = 12, .weight = .medium, .color = pal.ground });
        c.end();
        if (it.clicked) {
            // After this frame: stopping changes the lines being drawn.
            const id = heap.dupe(u8, r.id) catch continue;
            const box = heap.create([]u8) catch {
                heap.free(id);
                continue;
            };
            box.* = id;
            objc.dispatchMain(@ptrCast(box), stopLater);
        }
    }
}

fn stopLater(ctx: ?*anyopaque) callconv(.c) void {
    const box: *[]u8 = @ptrCast(@alignCast(ctx.?));
    defer {
        heap.free(box.*);
        heap.destroy(box);
    }
    watch.stop(box.*);
}

/// `Kea.destroy`: lent pages go back, the panel goes.
pub fn closeFor(kea: *Kea) void {
    const p = panel orelse return;
    if (p.kea != kea) return;
    while (hosted.items.len > 0) release(hosted.items[hosted.items.len - 1].web);
    p.window.close();
}

fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
    const self: *Pill = @ptrCast(@alignCast(ctx));
    if (panel == self) panel = null;
    objc.msg(void, self.lending, "removeFromSuperview", .{});
    objc.release(self.lending);
    heap.destroy(self);
}
