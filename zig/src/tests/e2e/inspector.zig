//! Web Inspector on the real stage: WebKit docks it in its page's box, so
//! inside the page's hole — the page above, the inspector below — where a
//! click passes the chrome's view and reaches it, with Ubi Chat, the
//! bookmarks and the HUD up beside it; out in a window of its own, or
//! closed, the page has its box back. A new tab is given `about:blank` to
//! be looked at.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "inspector docks inside stage hole, passes hitTest and clicks, and coexists with panels and HUD", .run = docks },
    .{ .name = "inspector materializes blank new tab and drives console, element picker, and sources", .run = blankTab },
};

/// The inspector is a page of its own in a process of its own: cold, it is
/// seconds before WebKit says it is up.
const opening: f64 = 10;

fn closed(b: *app.Browser) bool {
    return !app.inspector.isVisible(b);
}

/// Up, and out in a window of its own.
fn detached(b: *app.Browser) bool {
    return app.inspector.isVisible(b) and !app.inspector.isAttached(b);
}

/// `n` frames 0.03 s apart: a hidden window draws only when asked.
fn frames(h: *Harness, n: usize) void {
    for (0..n) |_| {
        h.frame();
        h.pump(0.03);
    }
}

fn rect(r: objc.CGRect) ui.Rect {
    return .{ .x = @floatCast(r.origin.x), .y = @floatCast(r.origin.y), .w = @floatCast(r.size.width), .h = @floatCast(r.size.height) };
}

/// `view`'s bounds in `host`, the window's flipped content view: the
/// surface's own coordinates, and a stage hole's.
fn inHost(view: objc.Object, host: objc.Object) ui.Rect {
    return rect(objc.msg(objc.CGRect, view, "convertRect:toView:", .{ objc.msg(objc.CGRect, view, "bounds", .{}), host }));
}

fn middle(r: ui.Rect) objc.CGPoint {
    return .{ .x = r.x + r.w * 0.5, .y = r.y + r.h * 0.5 };
}

/// How far `a` is from `b`, its four sides summed.
fn off(a: ui.Rect, b: ui.Rect) f32 {
    return @abs(a.x - b.x) + @abs(a.y - b.y) + @abs(a.w - b.w) + @abs(a.h - b.h);
}

/// Of some size, and inside `hole` to a point.
fn within(r: ui.Rect, hole: ui.Rect) bool {
    return r.w > 50 and r.h > 50 and r.x >= hole.x - 1 and r.y >= hole.y - 1 and r.x + r.w <= hole.x + hole.w + 1 and r.y + r.h <= hole.y + hole.h + 1;
}

/// Whether the page has the whole of its box, the size of `hole`.
fn fills(wv: objc.Object, hole: ui.Rect) bool {
    return off(rect(objc.msg(objc.CGRect, wv, "frame", .{})), .{ .w = hole.w, .h = hole.h }) < 1;
}

/// `v` is `view` or a view in it (a first responder may be the window).
fn inside(v: objc.Object, view: objc.Object) bool {
    return v == view or (objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSView")}) and objc.msg(objc.BOOL, v, "isDescendantOf:", .{view}));
}

/// A click on `view` at `at` (window coordinates) as `-[NSWindow sendEvent:]`
/// hands one over: the keys to a view that takes them, then the press and
/// the release. Not through the window: a click sent to one that isn't key
/// brings it forward, and a hidden run's never come.
fn click(window: objc.Object, view: objc.Object, at: objc.CGPoint) void {
    if (objc.msg(objc.BOOL, view, "acceptsFirstResponder", .{})) _ = objc.msg(objc.BOOL, window, "makeFirstResponder:", .{view});
    const number = objc.msg(objc.NSInteger, window, "windowNumber", .{});
    for ([_]objc.NSUInteger{ 1, 2 }) |kind| {
        const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            kind, at, @as(objc.NSUInteger, 0), @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, 1),
        }) orelse return;
        objc.msg(void, view, if (kind == 1) "mouseDown:" else "mouseUp:", .{ev});
    }
}

fn docks(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("sidebar", true);
    const t = try web.open(h, b, "kea-test://site/page?title=InspectorTarget");
    // The card takes its room 0.42 s after the column arrives (chrome/room.zig).
    frames(h, 20);
    const w = b.window orelse return h.fail("no window", .{});
    const s = w.surface orelse return h.fail("no surface", .{});
    const sh = b.stage_host orelse return h.fail("no stage host", .{});
    const wv = t.web orelse return h.fail("the page has no web view", .{});
    const host = objc.msg(objc.Object, w.nswindow, "contentView", .{});

    app.inspector.toggleInspector(b);
    try h.waitFor(b, app.inspector.isVisible, opening, "the inspector to open");
    // WebKit opens it as the last run left it: out in a window, it is docked.
    if (!app.inspector.isAttached(b)) app.inspector.toggleAttach(b);
    try h.waitFor(b, app.inspector.isAttached, 5, "the inspector to dock");
    // Frame after frame, the stage leaves the two as WebKit laid them out.
    frames(h, 5);
    try h.expect(app.inspector.isAttached(b), "the stage's frames undocked the inspector", .{});

    // In the page's box, which is the hole: clipped to the card's corners.
    const iwv = app.inspector.inspectorWebViewFor(wv) orelse return h.fail("no inspector web view", .{});
    const box = sh.boxOf(wv) orelse return h.fail("the page isn't on the stage", .{});
    try h.expect(objc.msg(?objc.Object, iwv, "superview", .{}) == box, "the inspector isn't in its page's box", .{});
    try h.expect(s.ctx.stage_count > 0, "no stage hole", .{});
    const hole = s.ctx.stage_rects[0];
    const f = rect(objc.msg(objc.CGRect, box, "frame", .{}));
    try h.expect(off(f, hole) < 1, "box at ({d:.1},{d:.1},{d:.1},{d:.1}), hole ({d:.1},{d:.1},{d:.1},{d:.1})", .{ f.x, f.y, f.w, f.h, hole.x, hole.y, hole.w, hole.h });
    const layer = objc.msg(?objc.Object, box, "layer", .{}) orelse return h.fail("the box has no layer", .{});
    const radius = objc.msg(f64, layer, "cornerRadius", .{});
    try h.expect(objc.msg(objc.BOOL, layer, "masksToBounds", .{}) and radius >= 9.5, "the box doesn't clip to the card's corners (radius {d:.1})", .{radius});

    // Docked at the bottom the page is above it, never under; at a side, beside.
    const pr = inHost(wv, host);
    const ir = inHost(iwv, host);
    try h.expect(within(pr, hole), "the page at ({d:.1},{d:.1},{d:.1},{d:.1}) is out of its hole ({d:.1},{d:.1},{d:.1},{d:.1})", .{ pr.x, pr.y, pr.w, pr.h, hole.x, hole.y, hole.w, hole.h });
    try h.expect(within(ir, hole), "the inspector at ({d:.1},{d:.1},{d:.1},{d:.1}) is out of the hole ({d:.1},{d:.1},{d:.1},{d:.1})", .{ ir.x, ir.y, ir.w, ir.h, hole.x, hole.y, hole.w, hole.h });
    const apart = pr.y + pr.h <= ir.y + 2 or pr.x + pr.w <= ir.x + 2 or ir.x + ir.w <= pr.x + 2;
    try h.expect(apart, "the page ({d:.1},{d:.1},{d:.1},{d:.1}) isn't above or beside the inspector ({d:.1},{d:.1},{d:.1},{d:.1})", .{ pr.x, pr.y, pr.w, pr.h, ir.x, ir.y, ir.w, ir.h });

    // A click in its middle: past the chrome's view, to the inspector — on
    // the stage, and as the window itself finds the view under a point.
    const mid = middle(ir);
    try h.expect(objc.msg(?objc.Object, s.nsview, "hitTest:", .{mid}) == null, "the chrome's view takes the clicks over the docked inspector", .{});
    const staged = objc.msg(?objc.Object, sh.stage_view, "hitTest:", .{mid}) orelse return h.fail("nothing on the stage under the inspector's middle", .{});
    try h.expect(inside(staged, iwv), "the stage's view under the inspector's middle isn't the inspector's", .{});
    const above = objc.msg(?objc.Object, host, "superview", .{});
    const hit = objc.msg(?objc.Object, host, "hitTest:", .{objc.msg(objc.CGPoint, host, "convertPoint:toView:", .{ mid, above })}) orelse return h.fail("nothing in the window under the inspector's middle", .{});
    try h.expect(inside(hit, iwv), "the window's view under the inspector's middle isn't the inspector's", .{});
    // The keys on the page, as after a click there; the click takes them.
    _ = objc.msg(objc.BOOL, w.nswindow, "makeFirstResponder:", .{wv});
    click(w.nswindow, hit, objc.msg(objc.CGPoint, host, "convertPoint:toView:", .{ mid, @as(?objc.Object, null) }));
    h.pump(0.05);
    const first = objc.msg(?objc.Object, w.nswindow, "firstResponder", .{}) orelse return h.fail("no first responder after the click", .{});
    try h.expect(first != s.nsview and inside(first, iwv), "the click in the inspector left the keys elsewhere", .{});

    // Out into a window of its own: the page has its box to itself at once.
    // Docked again before the panels narrow the page: WebKit docks only
    // beside one 500 wide, and its defaults open the next run's as this
    // one leaves it.
    app.inspector.toggleAttach(b);
    try h.waitFor(b, detached, 5, "the inspector to leave for its own window");
    h.frame();
    try h.expect(fills(wv, s.ctx.stage_rects[0]), "the page didn't take its box back from the undocked inspector", .{});
    app.inspector.toggleAttach(b);
    try h.waitFor(b, app.inspector.isAttached, 5, "the inspector to dock again");

    // Ubi Chat, the bookmarks and the HUD up beside it: docked still, and
    // none of them over it.
    _ = b.openChat();
    b.prefs.set("bookmarks_sidebar", true);
    app.debug_hud.toggle(b);
    frames(h, 15);
    try h.expect(app.inspector.isAttached(b), "the panels and the HUD undocked the inspector", .{});
    const again = app.inspector.inspectorWebViewFor(wv) orelse return h.fail("no inspector web view beside the panels", .{});
    try h.expect(objc.msg(?objc.Object, s.nsview, "hitTest:", .{middle(inHost(again, host))}) == null, "the chrome's view takes the clicks over the inspector beside the panels and the HUD", .{});

    // The keys in the inspector, and a click on the HUD's card (no box there
    // takes them) as `-[NSWindow sendEvent:]` hands one over — seen by the
    // monitor, the keys to the chrome's view, the press and the release:
    // they are back in the inspector, not left with the chrome or the page.
    b.debug_hud.pos_x = 20;
    b.debug_hud.pos_y = 60;
    frames(h, 25);
    _ = objc.msg(objc.BOOL, w.nswindow, "makeFirstResponder:", .{again});
    const had_keys = objc.msg(?objc.Object, w.nswindow, "firstResponder", .{}) orelse return h.fail("no first responder in the inspector", .{});
    try h.expect(inside(had_keys, again), "the inspector didn't take the keys", .{});
    const on_hud: objc.CGPoint = .{ .x = 24, .y = 80 };
    try h.expect(objc.msg(?objc.Object, s.nsview, "hitTest:", .{on_hud}) != null, "the chrome's view doesn't take a press on the HUD", .{});
    const height = objc.msg(objc.CGRect, host, "bounds", .{}).size.height;
    const number = objc.msg(objc.NSInteger, w.nswindow, "windowNumber", .{});
    app.inspector.had_keys_on_click = true;
    _ = objc.msg(objc.BOOL, w.nswindow, "makeFirstResponder:", .{s.nsview});
    for ([_]objc.NSUInteger{ 1, 2 }) |kind| {
        const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            kind, objc.CGPoint{ .x = on_hud.x, .y = height - on_hud.y }, @as(objc.NSUInteger, 0), @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, 1),
        }) orelse return h.fail("no mouse event", .{});
        objc.msg(void, s.nsview, if (kind == 1) "mouseDown:" else "mouseUp:", .{ev});
    }
    h.pump(0.1);
    const kept = objc.msg(?objc.Object, w.nswindow, "firstResponder", .{}) orelse return h.fail("no first responder after the press on the HUD", .{});
    try h.expect(kept != s.nsview and inside(kept, again), "a press on the HUD took the keys from the docked inspector", .{});

    // Closed: the page fills its box again.
    app.inspector.toggleInspector(b);
    try h.waitFor(b, closed, 5, "the inspector to close");
    h.frame();
    try h.expect(fills(wv, s.ctx.stage_rects[0]), "the page didn't take its box back from the closed inspector", .{});
}

fn blankTab(h: *Harness) !void {
    const b = try h.start();
    const t = b.activeTab() orelse return h.fail("no tab", .{});
    try h.expect(t.isBlank(), "the first tab isn't a new tab: '{s}'", .{t.url()});
    try h.expect(app.inspector.canInspect(b), "a new tab can't be inspected", .{});
    // Asked every frame (the HUD): asking wakes nothing.
    try h.expect(!app.inspector.isVisible(b) and !app.inspector.isAttached(b) and t.isBlank(), "asking after the inspector woke the new tab", .{});

    app.inspector.showConsole(b);
    try h.expect(!t.isBlank() and std.mem.eql(u8, t.url(), "about:blank"), "the new tab went to '{s}', want about:blank", .{t.url()});
    try h.expect(t.web != null, "the new tab has no page to look at", .{});
    try h.waitFor(b, app.inspector.isVisible, opening, "the console on a new tab");

    app.inspector.inspectElement(b);
    try h.waitFor(b, app.inspector.isPickingElement, 5, "the element picker");
    app.inspector.showPageSource(b);
    h.pump(0.1);
    app.inspector.toggleProfiling(b);
    try h.waitFor(b, app.inspector.isProfiling, 5, "the timeline recording");
    try h.expect(app.inspector.isVisible(b), "the inspector went away while it was driven", .{});

    // Closed before the next case: no inspector window is left behind.
    app.inspector.toggleInspector(b);
    try h.waitFor(b, closed, 5, "the inspector to close");
}
