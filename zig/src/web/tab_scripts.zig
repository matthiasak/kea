//! Kea's page scripts and the relays that carry what they say back to the
//! tab (Tab.swift 632-652 and `arm` 733-819; `ScrollRelay`, `MiddleRelay`,
//! `HoveredLink`, `ImageRelay`, `VeilRelay`, `IconRelay`), all in
//! `Web.world`. Curtain's picker, forms, passkeys, the store, AutoScroll
//! and LiveRate scripts arrive with their own phases.
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

const scroll_script = @embedFile("js/scroll_relay.js");
const middle_script = @embedFile("js/middle_relay.js");
const swipe_script = @embedFile("js/swipe_watch.js");
const image_script = @embedFile("js/image_watch.js");
const link_script = @embedFile("js/hovered_link.js");

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
    arm(t, "", false);
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
/// stylesheet (`css`) in before it has a body. `again`: scripts already
/// there are taken off first (`favicons.install` put the icon's in).
pub fn arm(t: *Tab, css: []const u8, again: bool) void {
    const wv = t.web orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ucc = controller(wv);
    const w = config.world();
    if (again) {
        objc.msg(void, ucc, "removeAllUserScripts", .{});
        add(ucc, favicons.relay_script, false, true, w);
    }
    add(ucc, scroll_script, false, true, w);
    // Every frame: a swipe over an embedded map is the map's.
    add(ucc, swipe_script, true, false, w);
    add(ucc, image_script, true, false, w);
    if (t.kea.prefs.shows_links) add(ucc, link_script, true, false, w);
    // The main frame only: a middle-click inside an ad's frame is its own.
    add(ucc, middle_script, true, true, w);
    if (css.len > 0) {
        const style = veilStyle(t.gpa, css) catch return;
        defer t.gpa.free(style);
        add(ucc, style, true, true, w);
    }
}

/// `Veiling.style`: a stylesheet put in before the document has a body.
pub fn veilStyle(gpa: std.mem.Allocator, css: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "(function () {\n  var sheet = document.getElementById('kea-veil');\n  if (!sheet) {\n    sheet = document.createElement('style');\n    sheet.id = 'kea-veil';\n    (document.head || document.documentElement).appendChild(sheet);\n  }\n  sheet.textContent = `");
    for (css) |ch| switch (ch) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '`' => try out.appendSlice(gpa, "\\`"),
        '$' => try out.appendSlice(gpa, "\\$"),
        else => try out.append(gpa, ch),
    };
    try out.appendSlice(gpa, "`;\n})();");
    return out.toOwnedSlice(gpa);
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
        const address = objc.fromNSString(body);
        t.own(&t.hovered, if (address.len == 0) null else address);
        if (t.browser) |b| if (b.prefs.shows_links) t.changed(.state);
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
        // `VeilRelay`: Curtain's picker (its model arrives with Curtain).
        const b = t.browser orelse return;
        if (string(body, "trouble")) |trouble| {
            var buf: [300]u8 = undefined;
            b.announce(std.fmt.bufPrint(&buf, "Couldn't hide that — {s}", .{trouble}) catch return);
        } else if (@hasDecl(Browser, "veilPicked")) {
            if (field(body, "off")) |off| if (objc.msg(objc.BOOL, off, "boolValue", .{})) return b.veilEnded();
            const selector = string(body, "selector") orelse return;
            b.veilPicked(t, selector, string(body, "label") orelse selector, string(body, "note") orelse "");
        }
    }
}
