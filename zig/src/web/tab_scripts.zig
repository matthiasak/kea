//! Kea's page scripts and the relays that carry what they say back to the
//! tab (Tab.swift 632-652 and `arm` 733-819; `ScrollRelay`, `MiddleRelay`,
//! `HoveredLink`, `ImageRelay`, `VeilRelay`, `IconRelay`), all in
//! `Web.world`, with Curtain's picker (`curtain_js.zig`) and AutoScroll.
//! LiveRate's runs in the page's own world. Forms, passkeys and the store
//! arrive with their own phases.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Tab = @import("tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;
const config = @import("config.zig");
const favicons = @import("favicons.zig");
const page_view = @import("page_view.zig");
const state = @import("tab_state.zig");
const image_menu = @import("image_menu.zig");
const curtain_js = @import("curtain_js.zig");

const scroll_script = @embedFile("js/scroll_relay.js");
const middle_script = @embedFile("js/middle_relay.js");
const swipe_script = @embedFile("js/swipe_watch.js");
const image_script = @embedFile("js/image_watch.js");
const link_script = @embedFile("js/hovered_link.js");
/// `LiveRate.script` (LiveRate.swift): a live player's speed nudges never
/// cross exactly 1, so the sound isn't torn down every few seconds.
const live_rate_script = @embedFile("js/live_rate.js");
/// AutoScroll.swift's `script`, and `off` for a page already up.
pub const auto_scroll_script = @embedFile("js/auto_scroll.js");
pub const auto_scroll_off = "window.__keaAutoScrollOff = true;";

/// The handlers this tab's delegate answers, in Kea's world.
const handled = [_][]const u8{ "keaScroll", "keaVeil", "keaImages", "keaMiddle", config.link_relay };

fn controller(wv: objc.Object) objc.Object {
    return objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "userContentController", .{});
}

/// Each name cleared before it is claimed: registering one twice is a
/// hard crash.
pub fn install(t: *Tab) void {
    const wv = t.web orelse return;
    const delegate = t.delegate orelse return;
    const ucc = controller(wv);
    config.release(ucc);
    for (handled) |name| objc.msg(void, ucc, "addScriptMessageHandler:contentWorld:name:", .{ delegate, config.world(), objc.nsString(name) });
    favicons.install(ucc, delegate);
    t.kea.shield.protect(ucc);
    // A new view: armed whatever was armed before.
    t.armed_key = 0;
    arm(t, t.veils);
}

/// `discard`'s half: every handler and script off the controller.
pub fn uninstall(_: *Tab, wv: objc.Object) void {
    const ucc = controller(wv);
    config.release(ucc);
    objc.msg(void, ucc, "removeAllUserScripts", .{});
}

/// `WKUserInjectionTimeAtDocumentStart` = 0, `AtDocumentEnd` = 1.
fn add(ucc: objc.Object, source: []const u8, start: bool, main_only: bool, world: objc.Object) void {
    const script = objc.msg(objc.Object, objc.alloc("WKUserScript"), "initWithSource:injectionTime:forMainFrameOnly:inContentWorld:", .{
        objc.nsString(source), @as(objc.NSInteger, if (start) 0 else 1), main_only, world,
    });
    defer objc.release(script);
    objc.msg(void, ucc, "addUserScript:", .{script});
}

/// `arm(hiding:)`: what goes into the next document, the hidden-things
/// stylesheet (`css`, kept as `Tab.veils` for a view built later) in
/// before it has a body. Done again only when something in it changed.
pub fn arm(t: *Tab, css: []const u8) void {
    if (!std.mem.eql(u8, t.veils, css)) {
        const copy = t.gpa.dupe(u8, css) catch return;
        t.gpa.free(t.veils);
        t.veils = copy;
    }
    const wv = t.web orelse return;
    const prefs = &t.kea.prefs;
    var h = std.hash.Wyhash.init(0);
    h.update(t.veils);
    h.update(&.{ @intFromBool(prefs.auto_scroll), @intFromBool(prefs.shows_links) });
    const key = h.final() | 1;
    if (t.armed_key == key) return;
    t.armed_key = key;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ucc = controller(wv);
    const w = config.world();
    objc.msg(void, ucc, "removeAllUserScripts", .{});
    add(ucc, scroll_script, false, true, w);
    add(ucc, curtain_js.picker_script, true, true, w);
    add(ucc, favicons.relay_script, false, true, w);
    if (prefs.auto_scroll) add(ucc, auto_scroll_script, false, true, w);
    // Every frame: a swipe over an embedded map is the map's.
    add(ucc, swipe_script, true, false, w);
    add(ucc, image_script, true, false, w);
    if (prefs.shows_links) add(ucc, link_script, true, false, w);
    // The main frame only: a middle-click inside an ad's frame is its own.
    add(ucc, middle_script, true, true, w);
    // Every frame, in the page's own world and ahead of its scripts.
    add(ucc, live_rate_script, true, false, config.pageWorld());
    if (t.veils.len > 0) {
        const style = veilStyle(t.gpa, t.veils) catch return;
        defer t.gpa.free(style);
        add(ucc, style, true, true, w);
    }
}

/// `prefs.$autoScroll`: every tab's next page, and the page each shows now.
pub fn autoScrollChanged(b: *Browser) void {
    const parked = b.parkedTabs(b.gpa) catch return;
    defer b.gpa.free(parked);
    for ([_][]const *Tab{ b.tabs.items, parked }) |list| for (list) |t| {
        curtain_js.armFor(t, t.url());
        t.evaluate(if (t.kea.prefs.auto_scroll) auto_scroll_script else auto_scroll_off, .kea, null, 0);
    };
}

/// `Veiling.style`: a stylesheet put in before the document has a body.
pub fn veilStyle(gpa: std.mem.Allocator, css: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "(function () {\n  var sheet = document.getElementById('kea-veil');\n  if (!sheet) {\n    sheet = document.createElement('style');\n    sheet.id = 'kea-veil';\n    (document.head || document.documentElement).appendChild(sheet);\n  }\n  sheet.textContent = `");
    try escapeInto(&out, gpa, css);
    try out.appendSlice(gpa, "`;\n})();");
    return out.toOwnedSlice(gpa);
}

/// Text put between backticks in a script: `\`, `` ` `` and `$` escaped.
pub fn escapeInto(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '`' => try out.appendSlice(gpa, "\\`"),
        '$' => try out.appendSlice(gpa, "\\$"),
        else => try out.append(gpa, ch),
    };
}

// MARK: what the page says

fn field(body: objc.Object, key: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString(key)});
}

fn isKind(o: objc.Object, comptime cls: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class(cls)});
}

fn number(body: objc.Object, key: []const u8) ?f64 {
    const v = field(body, key) orelse return null;
    if (!isKind(v, "NSNumber")) return null;
    return objc.msg(f64, v, "doubleValue", .{});
}

fn string(body: objc.Object, key: []const u8) ?[]const u8 {
    const v = field(body, key) orelse return null;
    if (!isKind(v, "NSString")) return null;
    return objc.fromNSString(v);
}

/// `userContentController:didReceiveScriptMessage:` for every relay.
pub fn received(t: *Tab, message: objc.Object) void {
    if (favicons.relayed(t, message)) return;
    const name = objc.fromNSString(objc.msg(?objc.Object, message, "name", .{}));
    const body = objc.msg(?objc.Object, message, "body", .{}) orelse return;
    const main_frame = objc.msg(objc.BOOL, objc.msg(objc.Object, message, "frameInfo", .{}), "isMainFrame", .{});
    if (std.mem.eql(u8, name, config.link_relay)) {
        // `HoveredLink`: only from this tab's own page.
        if (objc.msg(?objc.Object, message, "webView", .{}) != t.web or !isKind(body, "NSString")) return;
        @import("../chrome/link_bubble.zig").relayed(t, objc.fromNSString(body));
        return;
    }
    if (!isKind(body, "NSDictionary")) return;
    if (std.mem.eql(u8, name, "keaScroll")) {
        if (string(body, "side")) |side| return page_view.answer(t, std.mem.eql(u8, side, "free"));
        const y = number(body, "y") orelse return;
        const ceiling = number(body, "max") orelse return;
        return state.scrolled(t, y, ceiling);
    }
    if (std.mem.eql(u8, name, "keaMiddle")) {
        // `MiddleRelay`: the main frame's, to a real http(s) address.
        if (!main_frame) return;
        const href = string(body, "href") orelse return;
        if (!(std.ascii.startsWithIgnoreCase(href, "http://") or std.ascii.startsWithIgnoreCase(href, "https://"))) return;
        const b = t.browser orelse return;
        _ = b.open(href, .{ .foreground = false, .from = t, .may_wait = true });
        return;
    }
    if (std.mem.eql(u8, name, "keaImages")) {
        const src = string(body, "src") orelse return;
        for ([_][]const u8{ "http:", "https:", "data:", "blob:" }) |s| if (std.ascii.startsWithIgnoreCase(src, s))
            return image_menu.show(t, src, objc.msg(objc.Object, message, "frameInfo", .{}));
        return;
    }
    if (std.mem.eql(u8, name, "keaVeil")) {
        // `VeilRelay`: Curtain's picker.
        const b = t.browser orelse return;
        if (string(body, "trouble")) |trouble| return curtain_js.trouble(b, trouble);
        if (field(body, "off")) |off| if (objc.msg(objc.BOOL, off, "boolValue", .{})) return curtain_js.ended(b);
        const selector = string(body, "selector") orelse return;
        curtain_js.picked(b, t, selector, string(body, "label") orelse selector, string(body, "note") orelse "");
    }
}
