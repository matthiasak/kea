//! Settings › Privacy (Settings.swift:555-609, 874-890; `forgetCaptureChoices`,
//! Browser.swift:1140): the ad blocker and this site's exception, tracking
//! prevention, what sites were allowed, notifications, and clearing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../../model/browser.zig").Browser;
const app_name = @import("../../app/kea.zig").app_name;
const Palette = @import("../../design/palette.zig").Palette;
const controls = @import("../controls.zig");
const plate = @import("../controls_plate.zig");
const frame = @import("frame.zig");
const shield = @import("../../web/shield.zig");
const curtain_js = @import("../../web/curtain_js.zig");
const notifications = @import("../../web/notifications.zig");
const float = @import("../../web/float.zig");
const site_card = @import("../site_card.zig");

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    sites(b, c, p);
    // History, sign-ins and the cache are cleared by the History panel's
    // own model (model/browser_clear.zig).
    if (comptime @hasDecl(Browser, "clearHistory")) clearing(b, c, p);
}

fn sites(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const kea = b.kea;
    const prefs = b.prefs;
    plate.cardBox(c, p);
    defer ui.end(c);
    const trouble = kea.shield.trouble;
    if (frame.switchLine(c, p, "Block ads and trackers", trouble orelse "Third parties whose only job is to watch", prefs.shielded)) {
        prefs.set("shielded", !prefs.shielded);
        shield.shieldedChanged(kea);
    }
    if (trouble) |t| {
        frame.rule(c, p);
        plate.line(c, p, t, "Nothing is being blocked until this clears — try again, or restart " ++ app_name);
        if (controls.pill(c, p, "Try again", .{}).clicked) kea.shield.compile();
        ui.end(c);
    }
    if (prefs.shielded and trouble == null) if (curtain_js.hereHost(b)) |owned| {
        const host = c.print("{s}", .{owned});
        b.gpa.free(owned);
        frame.rule(c, p);
        const on = !kea.shield.isPaused(host);
        if (frame.switchLine(c, p, c.print("Block on {s}", .{host}), "Turn off here if the site breaks — the page reloads", on)) {
            kea.shield.pause(host, on);
            if (b.activeTab()) |t| t.reload(false);
        }
    };
    frame.rule(c, p);
    if (frame.switchLine(c, p, "Prevent cross-site tracking", "As in Safari. Off, sites you rarely open keep their sign-ins, and trackers inside other sites can follow you across them again, as in Chrome. Private tabs keep it on", !prefs.keeps_sign_ins))
        prefs.set("keeps_sign_ins", !prefs.keeps_sign_ins);
    frame.rule(c, p);
    plate.line(c, p, "Camera, microphone, location and notifications", "What each site was allowed or refused, and the sites whose videos don't float");
    if (controls.pill(c, p, "Forget choices", .{}).clicked) forgetCaptureChoices(b);
    ui.end(c);
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "site_notifications", "Let sites ask to send notifications", "A site asks on a card over its page, and only one you allow reaches your Mac's notifications. Private tabs are never asked");
    // `NotificationSites`: each allowed site, with a way to take it back.
    const allowed: []const []u8 = notifications.allowed(c.alloc(), kea) catch &.{};
    for (allowed) |site| {
        ui.key(c, site);
        frame.rule(c, p);
        plate.line(c, p, site_card.site(site), "Can send notifications");
        if (controls.pill(c, p, "Remove", .{}).clicked) notifications.forget(kea, site);
        ui.end(c);
    }
}

fn clearing(b: *Browser, c: *ui.Context, p: *const Palette) void {
    plate.cardBox(c, p);
    defer ui.end(c);
    plate.line(c, p, "History", "Every address you have been to");
    if (controls.pill(c, p, "Clear", .{}).clicked) b.clearHistory();
    ui.end(c);
    frame.rule(c, p);
    plate.line(c, p, "Cookies and sign-ins", "Signs you out of every site");
    if (controls.pill(c, p, "Sign out of everything", .{}).clicked) b.clearSites();
    ui.end(c);
    frame.rule(c, p);
    plate.line(c, p, "Cache", "Only what was fetched to draw pages");
    if (controls.pill(c, p, "Clear", .{}).clicked) b.clearCache();
    ui.end(c);
}

/// Everything a site has been allowed or refused, and the sites whose
/// videos don't float, for the day you want to change your mind.
pub fn forgetCaptureChoices(b: *Browser) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const defaults = b.store.defaults;
    const keys = objc.msg(objc.Object, objc.msg(objc.Object, defaults, "dictionaryRepresentation", .{}), "allKeys", .{});
    for (0..objc.msg(objc.NSUInteger, keys, "count", .{})) |i| {
        const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
        const key = objc.fromNSString(k);
        if (std.mem.startsWith(u8, key, "capture.") or std.mem.startsWith(u8, key, float.grounded_prefix))
            objc.msg(void, defaults, "removeObjectForKey:", .{k});
    }
    b.announce("Camera, microphone, location and notification choices forgotten");
}
