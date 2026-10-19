//! NanoUIView's methods: AppKit's events become the context's input, each
//! running a frame. The pointer's buttons, the wheel, keys and modifiers,
//! the first responder, drags from other apps, and the view's geometry.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");
const textinput = @import("textinput.zig");
const a11y = @import("a11y.zig");
const input = @import("input.zig");
const Surface = @import("surface.zig").Surface;

pub const methods = [_]objc.Method{
    .{ .name = "isFlipped", .imp = &yes, .types = "c@:" },
    .{ .name = "acceptsFirstResponder", .imp = &yes, .types = "c@:" },
    .{ .name = "resignFirstResponder", .imp = &resignFirstResponder, .types = "c@:" },
    .{ .name = "acceptsFirstMouse:", .imp = &yes1, .types = "c@:@" },
    .{ .name = "hitTest:", .imp = &hitTest, .types = "@@:{CGPoint=dd}" },
    .{ .name = "mouseDown:", .imp = &mouseDown, .types = "v@:@" },
    .{ .name = "mouseUp:", .imp = &mouseUp, .types = "v@:@" },
    .{ .name = "mouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
    .{ .name = "rightMouseDown:", .imp = &rightMouseDown, .types = "v@:@" },
    .{ .name = "rightMouseUp:", .imp = &rightMouseUp, .types = "v@:@" },
    .{ .name = "rightMouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
    .{ .name = "otherMouseDown:", .imp = &otherMouseDown, .types = "v@:@" },
    .{ .name = "otherMouseUp:", .imp = &otherMouseUp, .types = "v@:@" },
    .{ .name = "otherMouseDragged:", .imp = &mouseDragged, .types = "v@:@" },
    .{ .name = "mouseMoved:", .imp = &mouseMoved, .types = "v@:@" },
    .{ .name = "mouseExited:", .imp = &mouseExited, .types = "v@:@" },
    .{ .name = "scrollWheel:", .imp = &scrollWheel, .types = "v@:@" },
    .{ .name = "keyDown:", .imp = &keyDown, .types = "v@:@" },
    .{ .name = "flagsChanged:", .imp = &flagsChanged, .types = "v@:@" },
    .{ .name = "paste:", .imp = &paste, .types = "v@:@" },
    .{ .name = "draggingEntered:", .imp = &draggingUpdated, .types = "Q@:@" },
    .{ .name = "draggingUpdated:", .imp = &draggingUpdated, .types = "Q@:@" },
    .{ .name = "draggingExited:", .imp = &draggingExited, .types = "v@:@" },
    .{ .name = "performDragOperation:", .imp = &performDragOperation, .types = "c@:@" },
    // Updates on movement only: nothing polls.
    .{ .name = "wantsPeriodicDraggingUpdates", .imp = &no, .types = "c@:" },
    .{ .name = "setFrameSize:", .imp = &setFrameSize, .types = "v@:{CGSize=dd}" },
    .{ .name = "viewDidChangeBackingProperties", .imp = &backingChanged, .types = "v@:" },
    .{ .name = "viewDidChangeEffectiveAppearance", .imp = &backingChanged, .types = "v@:" },
    .{ .name = "updateTrackingAreas", .imp = &updateTrackingAreas, .types = "v@:" },
    .{ .name = "displayLinkFired:", .imp = &displayLinkFired, .types = "v@:@" },
    .{ .name = "viewWillStartLiveResize", .imp = &liveResizeStart, .types = "v@:" },
    .{ .name = "viewDidEndLiveResize", .imp = &liveResizeEnd, .types = "v@:" },
} ++ textinput.methods ++ a11y.methods;

/// What drags from other apps may bring.
pub const drag_types = [_][]const u8{ "public.url", "public.file-url", "public.utf8-plain-text" };

fn surfaceOf(obj: objc.Object) ?*Surface {
    return objc.getZig(Surface, obj);
}

pub fn yes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn no(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.NO;
}

fn yes1(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn setMods(in: *input.Input, flags: objc.NSUInteger) void {
    in.shift = flags & (1 << 17) != 0;
    in.ctrl = flags & (1 << 18) != 0;
    in.alt = flags & (1 << 19) != 0;
    in.cmd = flags & (1 << 20) != 0;
}

fn setMouse(s: *Surface, event: objc.Object) void {
    const p = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
    s.ctx.input.mouse = s.toView(p);
    setMods(&s.ctx.input, objc.msg(objc.NSUInteger, event, "modifierFlags", .{}));
}

fn hitTest(obj: objc.Object, _: objc.SEL, point: objc.CGPoint) callconv(.c) ?objc.Object {
    const s = surfaceOf(obj) orelse return null;
    const super = objc.msg(?objc.Object, obj, "superview", .{});
    const local = objc.msg(objc.CGPoint, obj, "convertPoint:fromView:", .{ point, super });
    const p: types.Point = .{ .x = @floatCast(local.x), .y = @floatCast(local.y) };
    if (p.x < 0 or p.y < 0 or p.x >= s.size.w or p.y >= s.size.h) return null;
    if (s.transparent and s.ctx.inStageHoleAt(p)) return null;
    return obj;
}

/// The view gives up the keyboard (a page took it): no box has the focus.
fn resignFirstResponder(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const s = surfaceOf(obj) orelse return objc.YES;
    if (s.ctx.focus != 0) {
        s.ctx.focus = 0;
        s.requestFrame();
    }
    return objc.YES;
}

/// A press of `button`: the view takes the keyboard, the box under the
/// pointer the press.
fn press(obj: objc.Object, event: objc.Object, button: input.Button) void {
    const s = surfaceOf(obj) orelse return;
    _ = objc.msg(objc.BOOL, s.window.nswindow, "makeFirstResponder:", .{obj});
    setMouse(s, event);
    s.ctx.updateHot();
    s.ctx.input.click_count = @intCast(objc.msg(objc.NSInteger, event, "clickCount", .{}));
    s.ctx.input.button = button;
    if (button == .left) {
        // Under a hidden title bar, the top strip moves the window as a title bar would.
        if (s.window.title_bar == .hidden and s.ctx.input.mouse.y < s.ctx.title_bar_height and s.ctx.hot == 0) {
            if (s.ctx.input.click_count == 2) s.window.zoom() else objc.msg(void, s.window.nswindow, "performWindowDragWithEvent:", .{event});
            return;
        }
        if (s.ctx.startsWindowDrag()) return objc.msg(void, s.window.nswindow, "performWindowDragWithEvent:", .{event});
    }
    s.ctx.pointerDown();
    s.frame();
}

fn release(obj: objc.Object, event: objc.Object, button: input.Button) void {
    const s = surfaceOf(obj) orelse return;
    // Another button's release, or one whose press went elsewhere.
    if (s.ctx.input.button != button or !s.ctx.input.down) return;
    setMouse(s, event);
    s.ctx.updateHot();
    s.ctx.pointerUp();
    s.frame();
}

fn mouseDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    press(obj, event, .left);
}

fn mouseUp(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    release(obj, event, .left);
}

fn rightMouseDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    press(obj, event, .right);
}

fn rightMouseUp(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    release(obj, event, .right);
}

/// The middle button is the third (number 2); others are not taken.
fn otherMouseDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    if (objc.msg(objc.NSInteger, event, "buttonNumber", .{}) == 2) press(obj, event, .middle);
}

fn otherMouseUp(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    if (objc.msg(objc.NSInteger, event, "buttonNumber", .{}) == 2) release(obj, event, .middle);
}

fn mouseDragged(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMouse(s, event);
    s.ctx.updateHot();
    s.frame();
}

fn mouseMoved(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMouse(s, event);
    const before = s.ctx.hot;
    s.ctx.updateHot();
    if (s.ctx.hot != before or s.ctx.wants_moves) return s.frame();
    // Onto or off text that selects, inside the same box: the cursor only.
    const over = s.ctx.pointerOverText();
    if (over != s.ctx.cursor_text) {
        s.ctx.cursor_text = over;
        s.updateCursor();
    }
}

fn mouseExited(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
    if (s.ctx.hot != 0) {
        s.ctx.updateHot();
        s.frame();
    }
}

fn scrollPhase(event: objc.Object) input.ScrollPhase {
    if (objc.msg(objc.NSUInteger, event, "momentumPhase", .{}) != 0) return .momentum;
    const p = objc.msg(objc.NSUInteger, event, "phase", .{});
    // NSEventPhase: began 1, stationary 2, changed 4, ended 8, cancelled 16, may begin 32.
    return if (p & (1 | 32) != 0) .began else if (p & (2 | 4) != 0) .changed else if (p & (8 | 16) != 0) .ended else .none;
}

fn scrollWheel(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMouse(s, event);
    const in = &s.ctx.input;
    in.precise = objc.msg(objc.BOOL, event, "hasPreciseScrollingDeltas", .{});
    in.scroll_phase = scrollPhase(event);
    var dx: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaX", .{}));
    var dy: f32 = @floatCast(objc.msg(f64, event, "scrollingDeltaY", .{}));
    if (!in.precise) {
        dx *= 12;
        dy *= 12;
    }
    // Sideways always reaches the view (rows that scroll sideways); down
    // and up the scrolling box under the pointer, else a view that takes it.
    const took = dy != 0 and s.ctx.applyScroll(dy);
    const wheel = s.ctx.wants_wheel and !took;
    if (!took and dx == 0 and !wheel) return;
    in.scroll = .{ .x = dx, .y = if (wheel) dy else 0 };
    s.frame();
    if (took) s.ctx.updateHot();
}

fn keyDown(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    const code = objc.msg(u16, event, "keyCode", .{});
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{});
    const in = &s.ctx.input;
    setMods(in, flags);
    // Key combinations go to the view first, which may take them.
    const ign = objc.fromNSString(objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{}));
    if (ign.len > 0) {
        const cp = std.unicode.utf8Decode(ign[0..cf.seqLen(ign[0])]) catch 0;
        const key = input.Shortcut.keyOf(cp);
        const special = key == 0xF700 or key == 0xF701 or key == '\t' or key == 0x1b;
        // Option too: a text field with Emacs's keys takes ⌥B, ⌥F, ⌥D.
        if (in.cmd or in.ctrl or in.alt or special) {
            s.ctx.shortcut_taken = false;
            in.shortcut = .{ .key = key, .cmd = in.cmd, .ctrl = in.ctrl, .alt = in.alt, .shift = in.shift };
            s.frame();
            in.shortcut = null;
            if (s.ctx.shortcut_taken) return;
        }
    }
    // A focused text field gets the event through the input system:
    // accents, input methods, the system's key bindings.
    if (textinput.interpret(s, event)) return;
    in.key = switch (code) {
        51 => .backspace,
        117 => .delete,
        123 => .left,
        124 => .right,
        125 => .down,
        126 => .up,
        115 => .home,
        119 => .end,
        36, 76 => .enter,
        48 => .tab,
        53 => .escape,
        116 => .page_up,
        121 => .page_down,
        122 => .f1,
        120 => .f2,
        99 => .f3,
        118 => .f4,
        96 => .f5,
        97 => .f6,
        98 => .f7,
        100 => .f8,
        101 => .f9,
        109 => .f10,
        103 => .f11,
        111 => .f12,
        else => null,
    };
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    if (in.key == null and !in.cmd and !in.ctrl) {
        const chars = objc.fromNSString(objc.msg(?objc.Object, event, "characters", .{}));
        // Printable text only: no controls, no function keys (U+F700…).
        var i: usize = 0;
        while (i < chars.len) {
            const len = cf.seqLen(chars[i]);
            const seq = chars[i..@min(chars.len, i + len)];
            const printable = seq[0] >= 0x20 and seq[0] != 0x7f and !(seq.len == 3 and seq[0] == 0xef and seq[1] >= 0x9c and seq[1] <= 0x9f);
            if (printable and n + seq.len <= buf.len) {
                @memcpy(buf[n .. n + seq.len], seq);
                n += seq.len;
            }
            i += len;
        }
    }
    in.chars = buf[0..n];
    if (in.key == null and n == 0) return;
    s.frame();
}

/// The modifier keys alone: a frame with `mods_changed` (a switcher that
/// commits as Control is let go).
fn flagsChanged(obj: objc.Object, _: objc.SEL, event: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    setMods(&s.ctx.input, objc.msg(objc.NSUInteger, event, "modifierFlags", .{}));
    s.ctx.input.mods_changed = true;
    s.frame();
}

fn paste(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    // ⌘V goes to the view first, as other shortcuts do: it may paste what
    // is not text (an image).
    s.ctx.shortcut_taken = false;
    s.ctx.input.shortcut = .{ .key = 'v', .cmd = true };
    s.frame();
    s.ctx.input.shortcut = null;
    if (s.ctx.shortcut_taken) return;
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    const str = objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")});
    const bytes = objc.fromNSString(str);
    // One line: newlines become spaces.
    s.pasted.clearRetainingCapacity();
    s.pasted.appendSlice(s.gpa, bytes) catch return;
    for (s.pasted.items) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    textinput.paste(s, s.pasted.items);
}

/// Where a drag is, in view points.
fn dragPoint(s: *Surface, info: objc.Object) types.Point {
    return s.toView(objc.msg(objc.CGPoint, info, "draggingLocation", .{}));
}

/// A drag from another app moves over the view: a copy where a box takes drops.
fn draggingUpdated(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.NSUInteger {
    const s = surfaceOf(obj) orelse return 0;
    const p = dragPoint(s, info);
    s.ctx.input.drag_over = p;
    s.frame();
    return if (s.ctx.acceptsDropAt(p)) 1 else 0; // NSDragOperationCopy
}

fn draggingExited(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.ctx.input.drag_over = null;
    s.frame();
}

/// The drop: its links (files as file URLs) and text, for one frame.
fn performDragOperation(obj: objc.Object, _: objc.SEL, info: objc.Object) callconv(.c) objc.BOOL {
    const s = surfaceOf(obj) orelse return objc.NO;
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const p = dragPoint(s, info);
    const pb = objc.msg(objc.Object, info, "draggingPasteboard", .{});
    const classes = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
    var urls: std.ArrayList([]const u8) = .empty;
    if (objc.msg(?objc.Object, pb, "readObjectsForClasses:options:", .{ classes, @as(?objc.Object, null) })) |arr| {
        const n = objc.msg(objc.NSUInteger, arr, "count", .{});
        for (0..n) |i| {
            const url = objc.msg(objc.Object, arr, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
            const str = a.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}))) catch continue;
            urls.append(a, str) catch {};
        }
    }
    const text = a.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")}))) catch "";
    s.ctx.input.drag_over = null;
    s.ctx.input.drop = .{ .point = p, .urls = urls.items, .text = text };
    s.frame();
    s.ctx.input.drop = null;
    return if (s.ctx.acceptsDropAt(p)) objc.YES else objc.NO;
}

fn displayLinkFired(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.frame();
}

fn liveResizeStart(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "viewWillStartLiveResize", .{});
    const s = surfaceOf(obj) orelse return;
    s.renderer.setLiveResize(true);
}

fn liveResizeEnd(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "viewDidEndLiveResize", .{});
    const s = surfaceOf(obj) orelse return;
    // A stage's view presents with its pages always (`Surface.hosted`).
    if (!s.hosted) s.renderer.setLiveResize(false);
    s.frame();
}

fn setFrameSize(obj: objc.Object, _: objc.SEL, size: objc.CGSize) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "setFrameSize:", .{size});
    const s = surfaceOf(obj) orelse return;
    s.updateGeometry();
    s.frame();
}

fn backingChanged(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = surfaceOf(obj) orelse return;
    s.updateGeometry();
    s.frame();
}

fn updateTrackingAreas(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "updateTrackingAreas", .{});
    const s = surfaceOf(obj) orelse return;
    if (s.tracking) |t| {
        objc.msg(void, obj, "removeTrackingArea:", .{t});
        objc.release(t);
    }
    // Entered and exited, moved, always active, in the visible rect.
    const opts: objc.NSUInteger = 0x01 | 0x02 | 0x80 | 0x200;
    const area = objc.msg(objc.Object, objc.alloc("NSTrackingArea"), "initWithRect:options:owner:userInfo:", .{
        objc.CGRect{}, opts, obj, @as(?objc.Object, null),
    });
    objc.msg(void, obj, "addTrackingArea:", .{area});
    s.tracking = area;
}
