//! P13's extensions: an unpacked one installed from a folder, as a
//! developer loads one, runs its content script on the pages it matches,
//! and its button opens its popup. The page is the harness's own
//! `kea-test://site/page`: the scheme is registered for match patterns as
//! Kea registers chrome-extension (Extensions.swift:155), so the fixture's
//! `kea-test://site/*` matches. Below macOS 15.4 there is no extension
//! engine and the cases are skipped.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "unpacked fixture extension injects content script", .run = injects },
    .{ .name = "clicking the extension button opens its popup window hidden", .run = popupOpens },
};

const files = [_]struct { []const u8, []const u8 }{
    .{ "manifest.json", @embedFile("fixtures/ext/manifest.json") },
    .{ "content.js", @embedFile("fixtures/ext/content.js") },
    .{ "popup.html", @embedFile("fixtures/ext/popup.html") },
};

fn loaded(e: *app.ext_controller.Extensions) bool {
    return e.contexts.count() > 0;
}

/// The fixture, installed from a folder in the case's root and loaded.
fn install(h: *Harness, b: *app.Browser) !*app.ext_controller.Extensions {
    const e = h.kea.?.ext orelse return h.fail("no extensions controller", .{});
    const dir = try h.temp.path(h.gpa, "fixture-ext");
    defer h.gpa.free(dir);
    app.disk.makePath(h.gpa, dir);
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        for (files) |f| {
            const p = try std.fs.path.join(h.gpa, &.{ dir, f[0] });
            defer h.gpa.free(p);
            const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ f[1].ptr, f[1].len });
            try h.expect(objc.msg(objc.BOOL, d, "writeToFile:atomically:", .{ objc.nsString(p), objc.YES }), "couldn't write {s}", .{f[0]});
        }
    }
    objc.msg(void, objc.class("WKWebExtensionMatchPattern"), "registerCustomURLScheme:", .{objc.nsString("kea-test")});
    // As Swift's bench does: no question asked.
    e.installFolderAt(dir, false);
    h.waitFor(e, loaded, 20, "the extension to load") catch {
        // What the controller knows, so a refusal explains itself.
        var said: std.ArrayList(u8) = .empty;
        defer said.deinit(h.gpa);
        for (e.errors.keys(), e.errors.values()) |id, list| for (list.items) |s| {
            said.print(h.gpa, "[{s}] {s}; ", .{ id, s }) catch {};
        };
        return h.fail("not loaded: installed {d}, busy {s}, said '{s}', errors: {s}", .{ e.installed.items.len, e.busy orelse "-", b.announcement orelse "", said.items });
    };
    try h.expect(e.installed.items.len == 1 and e.installed.items[0].source != null, "installed {d}", .{e.installed.items.len});
    return e;
}

fn injects(h: *Harness) !void {
    if (!app.ext.available()) return error.Skipped;
    const b = try h.start();
    _ = try install(h, b);
    const url = "kea-test://site/page?title=E";
    const t = try web.open(h, b, url);
    // document_idle: soon after the page finished.
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (std.mem.eql(u8, try web.eval(h, t, "document.body.dataset.ext"), "1")) return;
        h.pump(0.1);
    }
    return h.fail("content script didn't run: dataset.ext is {s}", .{try web.eval(h, t, "String(document.body.dataset.ext)")});
}

fn popupUp(_: *const u8) bool {
    const p = app.ext_popup.up() orelse return false;
    const pool = objc.Pool.push();
    defer pool.pop();
    const u = objc.msg(?objc.Object, p.web, "URL", .{}) orelse return false;
    return std.mem.endsWith(u8, objc.fromNSString(objc.msg(objc.Object, u, "absoluteString", .{})), "/popup.html");
}

fn popupOpens(h: *Harness) !void {
    if (!app.ext.available()) return error.Skipped;
    const b = try h.start();
    const e = try install(h, b);
    const id = e.installed.items[0].id;
    // Pinned: its button stands in the strip.
    b.prefs.set("sidebar", false);
    e.setPinned(id, true);
    h.frame();
    h.frame();
    const w = b.window orelse return h.fail("no window", .{});
    const a = e.del.anchors.get(id) orelse return h.fail("the button was never drawn", .{});
    try h.expect(a.window == w.nswindow, "the button's anchor isn't in the window", .{});
    const s = w.surface orelse return h.fail("no surface", .{});
    // A press and release on the button, as AppKit hands them over; the
    // window's coordinates run up from its bottom.
    const height = objc.msg(objc.CGRect, objc.msg(objc.Object, w.nswindow, "contentView", .{}), "bounds", .{}).size.height;
    const x = a.rect.origin.x + a.rect.size.width / 2;
    const y = height - (a.rect.origin.y + a.rect.size.height / 2);
    const number = objc.msg(objc.NSInteger, w.nswindow, "windowNumber", .{});
    for ([_]objc.NSUInteger{ 1, 2 }) |kind| {
        const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            kind, objc.CGPoint{ .x = x, .y = y }, @as(objc.NSUInteger, 0), @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, 1),
        }) orelse return h.fail("no mouse event", .{});
        objc.msg(void, s.nsview, if (kind == 1) "mouseDown:" else "mouseUp:", .{ev});
        h.frame();
    }
    const dummy: u8 = 0;
    try h.waitFor(&dummy, popupUp, 10, "the popup to open on its page");
    const p = app.ext_popup.up().?;
    try h.expect(std.mem.eql(u8, p.id, id), "the popup is another extension's", .{});
    const frame = objc.msg(objc.CGRect, p.window.nswindow, "frame", .{});
    try h.expect(!p.window.isVisible() and frame.origin.x <= -10000, "the popup window is on screen at {d},{d}", .{ frame.origin.x, frame.origin.y });
    // Pressed again, its button closes it.
    app.ext_buttons.press(e, id);
    try h.expect(app.ext_popup.up() == null, "a second press left the popup up", .{});
}
