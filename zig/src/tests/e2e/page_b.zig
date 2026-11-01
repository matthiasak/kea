//! P5.6, part B: the link under the pointer reaches the status line; a link
//! from another app opens in a small window that never shows here, and
//! Open in Kea moves its page into a tab, loaded as it is; Escape closes
//! one; an unprompted pop-up is blocked and a sized one opens in a small
//! window; a playing video's page floats into the panel and comes back.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "hovering a link sets the status line", .run = hoverStatus },
    .{ .name = "little window opens hidden and Open in Kea keeps its page", .run = littleKeeps },
    .{ .name = "little window closes with escape and its page goes", .run = littleCloses },
    .{ .name = "unprompted popup is blocked and sized popup opens in little window", .run = popups },
    .{ .name = "float panel hosts the page and gives it back", .run = floats },
};

// MARK: the status line

fn pointedAt(b: *app.Browser) bool {
    const d = b.link_status.destination orelse return false;
    return b.link_status.shown and std.mem.eql(u8, d, "kea-test://site/far");
}

fn leftLink(b: *app.Browser) bool {
    return !b.link_status.shown;
}

fn hoverStatus(h: *Harness) !void {
    const b = try h.start();
    const t = try web.open(h, b, "kea-test://site/page?title=Links&body=%3Ca%20id%3Dl%20href%3D%2Ffar%3Efar%3C%2Fa%3E");
    // The relay's own listener hears the pointer come over the link.
    _ = try web.eval(h, t, "document.getElementById('l').dispatchEvent(new MouseEvent('mouseover', {bubbles: true, composed: true})); 1");
    h.waitFor(b, pointedAt, 3, "the link's address") catch
        return h.fail("status is '{s}', shown {}", .{ b.link_status.destination orelse "", b.link_status.shown });
    try h.expect(b.link_status.page == t.serial, "the bubble isn't over the link's page", .{});
    // Leaving the frame altogether: gone a moment later.
    _ = try web.eval(h, t, "document.getElementById('l').dispatchEvent(new MouseEvent('mouseout', {bubbles: true, composed: true, relatedTarget: null})); 1");
    try h.waitFor(b, leftLink, 3, "the status line to clear");
}

// MARK: the small window

fn littleLoaded(l: *app.little.Little) bool {
    return !l.tab.loading and std.mem.eql(u8, l.tab.title(), "Little");
}

fn noLittles(_: *const u8) bool {
    return app.little.open.items.len == 0;
}

fn openLittle(h: *Harness, b: *app.Browser) !*app.little.Little {
    const l = app.little.show(b, "kea-test://site/page?title=Little", true) orelse return h.fail("no small window", .{});
    h.waitFor(l, littleLoaded, 10, "the small window's page") catch return h.fail("title '{s}'", .{l.tab.title()});
    try h.expect(!objc.msg(objc.BOOL, l.window.nswindow, "isVisible", .{}), "a hidden run's small window is on screen", .{});
    try h.expect(b.indexOf(l.tab) == null, "the small window's page is already a tab", .{});
    var buf: [64]u8 = undefined;
    try h.expect(std.mem.eql(u8, app.little.site(&buf, l.tab), "Not a website"), "the line says '{s}'", .{app.little.site(&buf, l.tab)});
    return l;
}

/// A press and release on the view, as AppKit hands them over.
fn clickView(view: objc.Object, window: objc.Object, x: f64, y: f64) void {
    const number = objc.msg(objc.NSInteger, window, "windowNumber", .{});
    for ([_]objc.NSUInteger{ 1, 2 }) |kind| {
        const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            kind, objc.CGPoint{ .x = x, .y = y }, @as(objc.NSUInteger, 0), @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, 1),
        }) orelse return;
        objc.msg(void, view, if (kind == 1) "mouseDown:" else "mouseUp:", .{ev});
    }
}

fn littleKeeps(h: *Harness) !void {
    const b = try h.start();
    const l = try openLittle(h, b);
    const tab = l.tab;
    const page = tab.web;
    const s = l.window.surface orelse return h.fail("no surface", .{});
    const pill = blk: {
        for (s.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, "Open in Kea")) break :blk n.rect,
            else => {},
        };
        return h.fail("no Open in Kea", .{});
    };
    // The window's coordinates run up from its bottom.
    const height = objc.msg(objc.CGRect, objc.msg(objc.Object, l.window.nswindow, "contentView", .{}), "bounds", .{}).size.height;
    clickView(s.nsview, l.window.nswindow, pill.x + pill.w / 2, height - (pill.y + pill.h / 2));
    const dummy: u8 = 0;
    try h.waitFor(&dummy, noLittles, 3, "the small window to go");
    try h.expect(b.indexOf(tab) != null and b.active_id == tab.id, "the page isn't the tab in front", .{});
    try h.expect(tab.web == page and std.mem.eql(u8, tab.title(), "Little"), "the page was loaded again", .{});
    h.frame();
    const sh = b.stage_host orelse return h.fail("no stage", .{});
    try h.expect(sh.slots.items[0].webview == page, "the window's stage doesn't hold the kept page", .{});
    try h.expect(objc.msg(?objc.Object, page, "superview", .{}) == sh.stage_view, "the kept page isn't in the window", .{});
}

fn littleCloses(h: *Harness) !void {
    const b = try h.start();
    const l = try openLittle(h, b);
    const tabs = b.tabs.items.len;
    // Escape, as the key monitor hands it over (`take`).
    const pool = objc.Pool.push();
    defer pool.pop();
    const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{}, @as(objc.NSUInteger, 0), @as(f64, 0),
        objc.msg(objc.NSInteger, l.window.nswindow, "windowNumber", .{}), @as(?objc.Object, null),
        objc.nsString("\x1b"), objc.nsString("\x1b"), objc.NO, @as(u16, 53),
    }) orelse return h.fail("no key event", .{});
    try h.expect(app.little.take(l, ev), "the small window didn't take escape", .{});
    const dummy: u8 = 0;
    try h.waitFor(&dummy, noLittles, 3, "escape to close the small window");
    try h.expect(b.tabs.items.len == tabs, "closing the small window changed the row", .{});
}

// MARK: pop-ups

fn blocked(t: *app.Tab) bool {
    return t.blocked_popups.items.len > 0;
}

fn oneLittle(_: *const u8) bool {
    return app.little.open.items.len == 1;
}

fn sizedLoaded(l: *app.little.Little) bool {
    return !l.tab.loading and std.mem.eql(u8, l.tab.title(), "Local /words/sized");
}

fn popups(h: *Harness) !void {
    const b = try h.start();
    var buf: [128]u8 = undefined;
    // Asked for as the page loads, with no click: kept on the tab's badge.
    const auto = try web.open(h, b, try std.fmt.bufPrint(&buf, "{s}/popup-auto", .{h.http}));
    const tabs = b.tabs.items.len;
    try h.waitFor(auto, blocked, 5, "the blocked pop-up");
    try h.expect(auto.blocked_popups.items.len == 1 and std.mem.endsWith(u8, auto.blocked_popups.items[0], "/words/popped"), "{d} blocked, first '{s}'", .{ auto.blocked_popups.items.len, if (auto.blocked_popups.items.len > 0) auto.blocked_popups.items[0] else "" });
    try h.expect(b.tabs.items.len == tabs and app.little.open.items.len == 0, "the blocked pop-up opened anyway", .{});
    {
        var arena = std.heap.ArenaAllocator.init(h.gpa);
        defer arena.deinit();
        const menu = try app.tab_title.popupMenu(arena.allocator(), b, auto.id);
        try h.expect(@import("page_features.zig").fire(menu, "Always Allow Pop-ups from 127.0.0.1"), "no Always Allow in a menu of {d}", .{menu.len});
    }
    try h.expect(h.kea.?.store.bool("popups.127.0.0.1") orelse false, "popups.127.0.0.1 not kept", .{});
    try h.expect(auto.blocked_popups.items.len == 0, "the badge still holds {d}", .{auto.blocked_popups.items.len});

    // Clicked, with a size of its own: a small window, not a tab.
    b.prefs.set("popups_in_windows", true);
    const from = try web.open(h, b, try std.fmt.bufPrint(&buf, "{s}/popup-btn", .{h.http}));
    const count = b.tabs.items.len;
    _ = try web.eval(h, from, "document.getElementById('go').click(); 1");
    const dummy: u8 = 0;
    try h.waitFor(&dummy, oneLittle, 5, "the small window");
    const l = app.little.open.items[0];
    const tab = l.tab;
    h.waitFor(l, sizedLoaded, 10, "the pop-up's page") catch return h.fail("title '{s}'", .{tab.title()});
    const size = objc.msg(objc.CGRect, objc.msg(objc.Object, l.window.nswindow, "contentView", .{}), "bounds", .{}).size;
    try h.expect(@abs(size.width - 420) < 1 and @abs(size.height - 320) < 1, "the small window is {d}×{d}", .{ size.width, size.height });
    try h.expect(b.tabs.items.len == count and b.indexOf(tab) == null, "the pop-up is already a tab", .{});

    // ⌃Tab, then ⌃O: the switcher keeps the small window's page as a tab.
    h.press("\t", 48, false, true);
    try h.expect(b.switcher.active(), "⌃Tab didn't start the switcher", .{});
    h.press("o", 31, false, true);
    try h.waitFor(&dummy, noLittles, 3, "the small window to go");
    try h.expect(!b.switcher.active(), "⌃O left the switcher up", .{});
    try h.expect(b.indexOf(tab) != null and b.tabs.items.len == count + 1, "the pop-up's page isn't a tab", .{});
}

// MARK: the floating window

fn playing(h: *Harness, t: *app.Tab) bool {
    const said = web.eval(h, t, "(function () { var v = document.getElementById('v'); return v.readyState >= 2 && !v.paused; })()") catch return false;
    return std.mem.eql(u8, said, "1");
}

fn lifted(t: *app.Tab) bool {
    return t.floating and app.float_panel.currentPanel() != null;
}

fn landed(t: *app.Tab) bool {
    return !t.floating and app.float_panel.currentPanel() == null;
}

fn floats(h: *Harness) !void {
    const b = try h.start();
    const t = try web.open(h, b, "kea-test://site/f/float.html");
    const deadline = nanoui.ui.clock.now() + 10;
    while (!playing(h, t)) {
        if (nanoui.ui.clock.now() > deadline) return h.fail("the fixture's video never played", .{});
        h.pump(0.1);
    }
    const page = t.web orelse return h.fail("no page", .{});
    app.float.toggle(b);
    h.waitFor(t, lifted, 5, "the page to float") catch return h.fail("floating {}, panel {}", .{ t.floating, app.float_panel.currentPanel() != null });
    const p = app.float_panel.currentPanel().?;
    const host = p.host orelse return h.fail("the panel has no stage", .{});
    try h.expect(host.slots.items[0].webview == page, "the panel's stage doesn't hold the page", .{});
    try h.expect(objc.msg(?objc.Object, page, "superview", .{}) == host.stage_view, "the page isn't in the panel", .{});
    try h.expect(!objc.msg(objc.BOOL, p.window.nswindow, "isVisible", .{}), "a hidden run's panel is on screen", .{});
    h.frame();
    const sh = b.stage_host orelse return h.fail("no stage", .{});
    try h.expect(sh.slots.items[0].webview != page, "the window's stage still holds the floating page", .{});
    try h.expect(std.mem.eql(u8, try web.eval(h, t, "document.documentElement.classList.contains('kea-floating')"), "1"), "everything but the video is still there", .{});

    // ⇧⌘P again: home.
    app.float.toggle(b);
    try h.waitFor(t, landed, 5, "the page to land");
    h.frame();
    try h.expect(sh.slots.items[0].webview == page, "the window's stage didn't take the page back", .{});
    try h.expect(objc.msg(?objc.Object, page, "superview", .{}) == sh.stage_view, "the page isn't back in the window", .{});
    h.pump(1.2);
    try h.expect(std.mem.eql(u8, try web.eval(h, t, "document.documentElement.classList.contains('kea-floating')"), "0"), "the page wasn't put back as it was", .{});
}
