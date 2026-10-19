//! A video that keeps playing after you have gone somewhere else, in a small
//! window that stays above everything (Float.swift, and Browser.swift's
//! `lift`/`land`/`leaving`/`appLeft`). WebKit won't hand a video to the
//! system's picture-in-picture without a real click, so the page itself
//! moves: everything but the video made invisible (`Isolate`), and the
//! whole web view lifted out of its window into the floating panel
//! (`float_panel.zig`). One video floats at a time, for the whole app.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("tab.zig").Tab;
const Store = @import("../data/store.zig").Store;
const Parts = @import("../data/url.zig").Parts;
const panel = @import("float_panel.zig");

const isolate_on = @embedFile("js/float_on.js");
const isolate_off = @embedFile("js/float_off.js");
const isolate_where = @embedFile("js/float_where.js");
const isolate_toggle = @embedFile("js/float_toggle.js");

/// The window whose video is out (`Browser.floating`) and its tab.
var owner: ?*Browser = null;
var tab_id: u64 = 0;
/// Lifted because another app came to the front (`liftedAway`).
var lifted_away = false;

/// The tab whose page is out in the floating window, of `b`'s.
pub fn floating(b: *const Browser) ?u64 {
    return if (owner == b and tab_id != 0) tab_id else null;
}

/// `floater.showing`.
pub fn showing() bool {
    return panel.showing();
}

// MARK: Players, Grounded

/// A host suffix, and for a few shops that also stream, the path that
/// separates the film from the product page.
const known = [_]struct { []const u8, ?[]const u8 }{
    .{ "youtube.com", null },          .{ "youtu.be", null },           .{ "netflix.com", null },
    .{ "primevideo.com", null },       .{ "amazon.com", "/gp/video" },  .{ "amazon.fr", "/gp/video" },
    .{ "amazon.co.uk", "/gp/video" },  .{ "amazon.de", "/gp/video" },   .{ "disneyplus.com", null },
    .{ "tv.apple.com", null },         .{ "twitch.tv", null },          .{ "vimeo.com", null },
    .{ "dailymotion.com", null },      .{ "max.com", null },            .{ "hbomax.com", null },
    .{ "canalplus.com", null },        .{ "mycanal.fr", null },         .{ "arte.tv", null },
    .{ "france.tv", null },            .{ "tf1.fr", null },             .{ "6play.fr", null },
    .{ "crunchyroll.com", null },      .{ "plex.tv", null },            .{ "peacocktv.com", null },
    .{ "hulu.com", null },             .{ "paramountplus.com", null },  .{ "molotov.tv", null },
    .{ "ocs.fr", null },               .{ "mubi.com", null },           .{ "criterionchannel.com", null },
    .{ "ted.com", null },              .{ "nebula.tv", null },          .{ "curiositystream.com", null },
};

/// `Players.knows`: a site with a player worth following into the window.
pub fn playersKnow(url: []const u8) bool {
    const p = Parts.parse(url) orelse return false;
    const raw_host = p.hostName() orelse return false;
    var hb: [256]u8 = undefined;
    var pb: [64]u8 = undefined;
    if (raw_host.len > hb.len) return false;
    const host = std.ascii.lowerString(&hb, raw_host);
    const path = std.ascii.lowerString(pb[0..@min(p.path.len, pb.len)], p.path[0..@min(p.path.len, pb.len)]);
    for (known) |entry| {
        const h = entry[0];
        const suffix = host.len > h.len and host[host.len - h.len - 1] == '.' and std.mem.endsWith(u8, host, h);
        if (!std.mem.eql(u8, host, h) and !suffix) continue;
        const needle = entry[1] orelse return true;
        if (std.mem.startsWith(u8, path, needle)) return true;
    }
    return false;
}

/// `Grounded`: sites whose videos never float out on their own (the site
/// card's Don't Float Videos Here), kept by host as "nofloat.<host>".
pub const grounded_prefix = "nofloat.";

pub fn groundedHolds(store: *const Store, host: []const u8) bool {
    var buf: [300]u8 = undefined;
    return store.bool(std.fmt.bufPrint(&buf, grounded_prefix ++ "{s}", .{host}) catch return false) orelse false;
}

/// Off keeps nothing, as Autoplay's does.
pub fn setGrounded(store: *const Store, on: bool, host: []const u8) void {
    var buf: [300]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, grounded_prefix ++ "{s}", .{host}) catch return;
    if (on) store.setBool(key, true) else store.remove(key);
}

// MARK: lifting and landing

/// ⌘⇧P, for lifting one out by hand, or putting it back.
pub fn toggle(b: *Browser) void {
    if (showing()) return land(b);
    lift(b, b.tabById(b.active_id), false, otherPane(b));
}

/// `select`: coming back to the tab whose video is out brings it home
/// first; then, with Settings so, the one being left may float.
pub fn selecting(b: *Browser, tab: *Tab) void {
    if (floating(b) == tab.id) land(b);
    if (b.prefs.floats_on_leave) lift(b, b.tabById(b.active_id), true, otherPane(b));
}

/// Another app in front, or back (`appLeft`/`appBack`).
pub fn appActive(kea: *Kea, active: bool) void {
    if (active) {
        defer lifted_away = false;
        if (!lifted_away) return;
        if (owner) |b| if (std.mem.indexOfScalar(*Browser, kea.browsers.items, b) != null) if (floating(b)) |id| if (id == b.active_id) land(b);
        return;
    }
    const front = kea.windows.front;
    for (kea.browsers.items) |b| {
        if (!b.prefs.floats_away or (front != null and front != b)) continue;
        lifted_away = !showing();
        lift(b, b.tabById(b.active_id), true, otherPane(b));
    }
}

/// With a pair on screen, its other page: what floats when the focused one
/// has nothing playing.
fn otherPane(b: *Browser) ?*Tab {
    const front = b.tabById(b.active_id) orelse return null;
    if (!b.inSplit(front)) return null;
    return b.partnerOf(front);
}

/// `lift(_:quietly:otherwise:)`. `otherwise`: the other page of a pair,
/// tried when this one has nothing playing.
fn lift(b: *Browser, tab: ?*Tab, quietly: bool, otherwise: ?*Tab) void {
    const t = tab orelse return if (otherwise) |o| lift(b, o, quietly, null);
    if (t.isBlank() or t.asleep() or showing() or t.web == null)
        return if (otherwise) |o| lift(b, o, quietly, null);
    const wv = t.web.?;
    // A video filling the screen stays in its own space, as in Safari.
    if (objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("fullscreenState")}) and
        objc.msg(objc.NSInteger, wv, "fullscreenState", .{}) != 0) return;
    // On its own only from a site whose video is the point of the site, and
    // not from one grounded in its site card.
    if (quietly and (!playersKnow(t.url()) or grounded(t))) return if (otherwise) |o| lift(b, o, quietly, null);
    const other: u64 = if (otherwise) |o| o.id else 0;
    t.evaluate(isolate_on, .kea, lifted, (other << 1) | @intFromBool(quietly));
}

fn grounded(t: *const Tab) bool {
    const p = Parts.parse(t.committed orelse return false) orelse return false;
    return groundedHolds(&t.kea.store, p.hostName() orelse return false);
}

fn lifted(t: *Tab, value: ?objc.Object, _: ?objc.Object, arg: usize) void {
    const b = t.browser orelse return;
    const quietly = arg & 1 == 1;
    const said = if (value) |v| objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")}) and
        std.mem.eql(u8, objc.fromNSString(v), "floating") else false;
    if (!said) {
        if (b.tabById(arg >> 1)) |o| return lift(b, o, quietly, null);
        if (!quietly) b.announce("Nothing is playing here");
        return;
    }
    const wv = t.web orelse return;
    if (showing()) return;
    owner = b;
    tab_id = t.id;
    t.floating = true;
    // Off this window's stage before it goes on the panel's.
    if (b.stage_host) |sh| sh.forget(wv);
    panel.lift(b.kea, wv, .{ .ctx = b, .close = onClose, .back = onReturn, .skip = onSkip, .progress = onProgress, .play_pause = onPlayPause });
    b.redraw();
}

/// Back into its tab; the stage takes the page again on its next layout.
pub fn land(b: *Browser) void {
    // Another window's video: that window takes it back.
    if (owner) |o| if (o != b) return land(o);
    // The window closes whatever else is true.
    if (showing()) panel.drop();
    const id = tab_id;
    owner = null;
    tab_id = 0;
    const t = b.tabById(id) orelse return;
    t.floating = false;
    t.evaluate(isolate_off, .kea, null, 0);
    b.redraw();
}

/// `tab.discard()` with its page out: the window goes, nothing to land.
pub fn dropped(t: *Tab) void {
    if (showing()) panel.drop();
    t.floating = false;
    if (t.id == tab_id) {
        owner = null;
        tab_id = 0;
    }
}

// MARK: the panel's buttons, answered by the window whose video it is

fn floatingTab() ?*Tab {
    const b = owner orelse return null;
    return b.tabById(tab_id);
}

fn onClose(ctx: *anyopaque) void {
    land(@ptrCast(@alignCast(ctx)));
}

/// Back to the tab it came from, the window in front.
fn onReturn(ctx: *anyopaque) void {
    const b: *Browser = @ptrCast(@alignCast(ctx));
    const came = tab_id;
    land(b);
    if (b.tabById(came)) |t| b.select(t);
    // Never a test run's: a probe started hidden stays off every screen.
    if (b.kea.opts.root != null or b.kea.opts.hidden) return;
    @import("../app/browsers.zig").show(b);
    if (b.kea.ui_app) |a| objc.msg(void, a.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
}

/// Step over the bit you missed, or back to it.
fn onSkip(_: *anyopaque, seconds: f64) void {
    const t = floatingTab() orelse return;
    var buf: [400]u8 = undefined;
    const js = std.fmt.bufPrint(&buf,
        \\(function () {{
        \\  var video = document.querySelector('[data-kea-float]')
        \\    || document.querySelector('video');
        \\  if (!video) return false;
        \\  video.currentTime = Math.max(0, video.currentTime + ({d}));
        \\  return true;
        \\}})();
    , .{seconds}) catch return;
    t.evaluate(js, .kea, null, 0);
}

/// Every half second while the window is up, for the line along its edge.
fn onProgress(_: *anyopaque) void {
    const t = floatingTab() orelse return;
    t.evaluate(isolate_where, .kea, progressed, 0);
}

fn progressed(_: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const v = value orelse return;
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSArray")}) or objc.msg(objc.NSUInteger, v, "count", .{}) != 2) return;
    const through = objc.msg(objc.Object, v, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const playing = objc.msg(objc.Object, v, "objectAtIndex:", .{@as(objc.NSUInteger, 1)});
    panel.progressed(objc.msg(f64, through, "doubleValue", .{}), objc.msg(objc.BOOL, playing, "boolValue", .{}));
}

/// Stop or start it; the button shows which it is now.
fn onPlayPause(_: *anyopaque) void {
    const t = floatingTab() orelse return;
    t.evaluate(isolate_toggle, .kea, toggled, 0);
}

fn toggled(_: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const playing = if (value) |v| objc.msg(objc.BOOL, v, "boolValue", .{}) else true;
    panel.played(playing);
}

test "players are the sites people go to watch" {
    try std.testing.expect(playersKnow("https://www.youtube.com/watch?v=1"));
    try std.testing.expect(playersKnow("https://m.twitch.tv/x"));
    try std.testing.expect(playersKnow("https://www.amazon.de/gp/video/detail/1"));
    try std.testing.expect(!playersKnow("https://www.amazon.de/dp/123"));
    try std.testing.expect(!playersKnow("https://notyoutube.com/"));
    try std.testing.expect(!playersKnow("https://kea.app/"));
}
