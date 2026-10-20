//! Focus and first-responder hand-off across the page, the address field,
//! the find bar, tab address editing, chrome buttons, and popped panels.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "find close returns keys to page", .run = findClose },
    .{ .name = "omnibox esc hands keys to page", .run = omniboxEsc },
    .{ .name = "tab switch with omnibox open", .run = tabSwitchOmnibox },
    .{ .name = "tab address commit hands keys back", .run = tabAddressCommit },
    .{ .name = "new tab and new window focus field", .run = newTabAndWindow },
    .{ .name = "page keys after chrome click", .run = chromeClick },
    .{ .name = "popped chat composer focused", .run = poppedChat },
};

fn responder(b: *app.Browser) ?objc.Object {
    const w = b.window orelse return null;
    return objc.msg(?objc.Object, w.nswindow, "firstResponder", .{});
}

fn isPageResponder(b: *app.Browser, t: *app.Tab) bool {
    const r = responder(b) orelse return false;
    const wv = t.web orelse return false;
    return r == wv or (objc.msg(objc.BOOL, r, "isKindOfClass:", .{objc.class("NSView")}) and objc.msg(objc.BOOL, r, "isDescendantOf:", .{wv}));
}

fn activeHasKeys(b: *app.Browser) bool {
    const t = b.activeTab() orelse return false;
    return isPageResponder(b, t);
}
fn finding(b: *app.Browser) bool {
    return b.finder.finding;
}

fn editing(b: *app.Browser) bool {
    return b.editing;
}


fn clickView(view: objc.Object, window: objc.Object, x: f64, y: f64) void {
    const number = objc.msg(objc.NSInteger, window, "windowNumber", .{});
    for ([_]objc.NSUInteger{ 1, 2 }) |kind| {
        const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            kind, objc.CGPoint{ .x = x, .y = y }, @as(objc.NSUInteger, 0), @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, 1),
        }) orelse return;
        objc.msg(void, view, if (kind == 1) "mouseDown:" else "mouseUp:", .{ev});
    }
}

fn findClose(h: *Harness) !void {
    const b = try h.start();
    const t = try web.open(h, b, "kea-test://site/page?title=FindKeys");
    h.frame();
    h.pump(0.05);
    const s = b.window.?.surface.?;
    h.press("f", 3, true, false);
    try h.waitFor(b, finding, 2, "the find bar");
    h.frame();
    try h.expect(responder(b) == s.nsview, "find bar did not focus surface view", .{});
    h.press("\x1b", 53, false, false);
    h.frame();
    try h.expect(!b.finder.finding, "find bar did not close", .{});
    try h.expect(isPageResponder(b, t), "firstResponder did not return to page after find close", .{});
}

fn omniboxEsc(h: *Harness) !void {
    const b = try h.start();
    _ = try web.open(h, b, "kea-test://site/page?title=OmniEsc");
    h.frame();
    h.pump(0.05);
    const s = b.window.?.surface.?;
    h.press("l", 37, true, false);
    try h.waitFor(b, editing, 2, "the omnibox");
    h.frame();
    try h.expect(responder(b) == s.nsview, "omnibox did not focus surface view", .{});
    h.press("\x1b", 53, false, false);
    h.frame();
    try h.waitFor(b, activeHasKeys, 2, "page to regain firstResponder after omnibox esc");
}

fn tabSwitchOmnibox(h: *Harness) !void {
    const b = try h.start();
    const one = try web.open(h, b, "kea-test://site/page?title=One");
    const two = try web.open(h, b, "kea-test://site/page?title=Two");
    b.select(one);
    h.frame();
    h.pump(0.05);
    h.press("l", 37, true, false);
    try h.waitFor(b, editing, 2, "the omnibox");
    h.frame();
    b.select(two);
    h.frame();
    try h.expect(b.active_id == two.id, "did not switch to second tab", .{});
    try h.waitFor(b, activeHasKeys, 2, "second tab page to receive firstResponder");
    try h.expect(isPageResponder(b, two), "other tab web view is not firstResponder", .{});
}

fn tabAddressCommit(h: *Harness) !void {
    const b = try h.start();
    const t = try web.open(h, b, "kea-test://site/page?title=Commit");
    h.frame();
    h.pump(0.05);
    const s = b.window.?.surface.?;
    b.beginTabEdit(t);
    h.frame();
    try h.expect(responder(b) == s.nsview, "tab edit did not focus surface view", .{});
    b.commitTabEdit();
    h.frame();
    try h.waitFor(b, activeHasKeys, 2, "page to regain firstResponder after tab address commit");
}

fn newTabAndWindow(h: *Harness) !void {
    const b = try h.start();
    _ = try web.open(h, b, "kea-test://site/page?title=Base");
    h.frame();
    h.pump(0.05);
    h.press("t", 17, true, false);
    h.frame();
    const s = b.window.?.surface.?;
    try h.expect(s.ctx.focused_text != null and s.ctx.focus == b.omnibox.text_id, "new tab did not focus omnibox field", .{});
    try h.expect(responder(b) == s.nsview, "new tab surface view is not firstResponder", .{});

    const sec = try app.browsers.newWindow(h.kea.?);
    h.frame();
    const sec_s = sec.window.?.surface.?;
    try h.expect(sec_s.ctx.focused_text != null and sec_s.ctx.focus == sec.omnibox.text_id, "new window did not focus omnibox field", .{});
    try h.expect(responder(sec) == sec_s.nsview, "new window surface view is not firstResponder", .{});
}

fn chromeClick(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("sidebar", true);
    _ = try web.open(h, b, "kea-test://site/page?title=ChromeClick");
    h.frame();
    try h.waitFor(b, activeHasKeys, 2, "initial page firstResponder");
    const w = b.window.?;
    const s = w.surface.?;
    const r = blk: {
        for (s.ctx.a11y_items.items) |item| if (item.role == .button and std.mem.eql(u8, item.label, "Back")) {
            if (s.ctx.rects.get(item.id)) |rect| break :blk rect;
        };
        return h.fail("no Back button in sidebar", .{});
    };
    const height = objc.msg(objc.CGRect, objc.msg(objc.Object, w.nswindow, "contentView", .{}), "bounds", .{}).size.height;
    clickView(s.nsview, w.nswindow, r.x + r.w / 2, height - (r.y + r.h / 2));
    try h.waitFor(b, activeHasKeys, 2, "page to keep keys after chrome click");
}

fn poppedChat(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("ai", true);
    b.prefs.set("chat_popped", true);
    _ = b.openChat();
    h.frame();
    const pw = b.chat.window orelse return h.fail("no popped chat window", .{});
    const w = pw.window orelse return h.fail("no nanoui window on popped chat", .{});
    const s = w.surface orelse return h.fail("no surface on popped chat", .{});
    s.frame();
    try h.expect(s.ctx.focused_text != null, "popped chat composer is not focused", .{});
    try h.expect(objc.msg(?objc.Object, w.nswindow, "firstResponder", .{}) == s.nsview, "popped chat surface is not firstResponder", .{});
}
