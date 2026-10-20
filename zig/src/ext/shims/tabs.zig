//! Tabs by where they are in the row (ExtensionShims.swift 3901-3929,
//! `located` 3357-3372, `favIconURL` 3374-3393), and chrome.search (3931-3941).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");
const ext = @import("../ext.zig");
const favicons = @import("../../web/favicons.zig");
const Parts = @import("../../data/url.zig").Parts;
const Tab = @import("../../web/tab.zig").Tab;
const Extensions = @import("../controller.zig").Extensions;
const Call = ans.Call;

/// A tab as the shim names it: `i`, its place in its window's row as
/// extensions see it, and `w`, that window's frame from windows.getAll().
/// A bare number, or no frame, is only understood while there is one window.
pub fn located(owner: *Extensions, place: ?std.json.Value) ?*Tab {
    const raw = ans.num(place) orelse ans.num(ans.field(place, "i")) orelse return null;
    if (@abs(raw) > 1e9) return null;
    const index: i64 = @intFromFloat(raw);
    if (ans.field(place, "w")) |w| frame: {
        const left = ans.num(ans.field(w, "left")) orelse break :frame;
        const top = ans.num(ans.field(w, "top")) orelse break :frame;
        const width = ans.num(ans.field(w, "width")) orelse break :frame;
        const height = ans.num(ans.field(w, "height")) orelse break :frame;
        if (index < 0) return null;
        return owner.tabAtFrame(.{ .origin = .{ .x = left, .y = top }, .size = .{ .width = width, .height = height } }, @intCast(index));
    }
    if (owner.kea.browsers.items.len > 1) return null;
    const visible = owner.visibleTabs(owner.gpa, null) catch return null;
    defer owner.gpa.free(visible);
    return if (index >= 0 and index < visible.len) visible[@intCast(index)] else null;
}

/// A tab's icon for favIconUrl: the picture the tab wears, as a small PNG
/// data: URL (Chrome's favIconUrl may be one). Made once per site and kept.
fn favIconURL(owner: *Extensions, tab: *Tab) ?[]const u8 {
    var buf: [300]u8 = undefined;
    const host = favicons.site(&buf, tab.address orelse return null) orelse return null;
    if (owner.answer.fav_icons.get(host)) |known| return known;
    const kept = owner.kea.favicons.cached(host) orelse return null;
    const url = small(owner.gpa, kept.png) orelse return null;
    if (owner.answer.fav_icons.count() > 500) ans.forgetIcons(owner);
    ans.putString(owner.gpa, &owner.answer.fav_icons, host, url) catch {};
    defer owner.gpa.free(url);
    return owner.answer.fav_icons.get(host);
}

/// The picture drawn into a 32-pixel square, as a PNG data: URL on `gpa`.
fn small(gpa: std.mem.Allocator, png: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const side: objc.NSInteger = 32;
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ png.ptr, png.len });
    const image = objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithData:", .{data}) orelse return null;
    objc.autorelease(image);
    const rep = objc.msg(?objc.Object, objc.alloc("NSBitmapImageRep"), "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bytesPerRow:bitsPerPixel:", .{
        @as(?*anyopaque, null), side, side, @as(objc.NSInteger, 8), @as(objc.NSInteger, 4), objc.YES, objc.NO, objc.nsString("NSDeviceRGBColorSpace"), @as(objc.NSInteger, 0), @as(objc.NSInteger, 0),
    }) orelse return null;
    objc.autorelease(rep);
    const ctx_class = objc.class("NSGraphicsContext");
    objc.msg(void, ctx_class, "saveGraphicsState", .{});
    objc.msg(void, ctx_class, "setCurrentContext:", .{objc.msg(objc.Object, ctx_class, "graphicsContextWithBitmapImageRep:", .{rep})});
    objc.msg(void, image, "drawInRect:", .{objc.CGRect{ .size = .{ .width = 32, .height = 32 } }});
    objc.msg(void, ctx_class, "restoreGraphicsState", .{});
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    // NSBitmapImageFileTypePNG
    const out = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), props }) orelse return null;
    const bytes = @import("../value.zig").bytes(out);
    const enc = std.base64.standard.Encoder;
    const prefix = "data:image/png;base64,";
    const url = gpa.alloc(u8, prefix.len + enc.calcSize(bytes.len)) catch return null;
    @memcpy(url[0..prefix.len], prefix);
    _ = enc.encode(url[prefix.len..], bytes);
    return url;
}

/// Another extension's page: its address names another id.
fn othersPage(address: []const u8, id: []const u8) bool {
    const p = Parts.parse(address) orelse return false;
    const scheme = p.scheme orelse return false;
    if (!std.ascii.eqlIgnoreCase(scheme, ext.scheme) and !std.ascii.eqlIgnoreCase(scheme, ext.former_scheme)) return false;
    return !std.mem.eql(u8, p.hostName() orelse "", id);
}

pub fn run(c: *Call) ans.Error!?ans.Out {
    const eql = std.mem.eql;
    const api = c.api;
    if (eql(u8, api, "tabs.describe")) {
        const Described = struct { url: []const u8, title: []const u8, favIconUrl: ?[]const u8 = null };
        const places = ans.list(c.first()) orelse &.{};
        const out = try c.a.alloc(?Described, places.len);
        for (places, out) |place, *o| {
            const tab = located(c.owner, place) orelse {
                o.* = null;
                continue;
            };
            // Another extension's page stays blank, as WebKit keeps it; its own are its own.
            if (tab.address) |addr| if (othersPage(addr, c.id)) {
                o.* = .{ .url = "", .title = "" };
                continue;
            };
            o.* = .{
                .url = try c.a.dupe(u8, tab.address orelse ""),
                .title = try c.a.dupe(u8, tab.title()),
                .favIconUrl = if (favIconURL(c.owner, tab)) |u| try c.a.dupe(u8, u) else null,
            };
        }
        return c.give(out);
    } else if (eql(u8, api, "tabs.move") or eql(u8, api, "tabs.discard") or eql(u8, api, "tabs.activate")) {
        const tab = located(c.owner, c.first()) orelse return c.fail("No tab there", .{});
        const browser = c.owner.browserOf(tab) orelse return c.fail("No tab there", .{});
        if (eql(u8, api, "tabs.move")) {
            const visible = try c.owner.visibleTabs(c.a, browser);
            if (visible.len == 0) return ans.none;
            const wanted = ans.int(c.arg(1)) orelse -1;
            const target = visible[if (wanted < 0 or wanted >= visible.len) visible.len - 1 else @intCast(wanted)];
            if (browser.indexOf(target)) |index| browser.move(tab, index);
        } else if (eql(u8, api, "tabs.discard")) {
            if (tab.id != browser.active_id) browser.sleep(tab, null);
        } else {
            // `activateForExtension`: a pair on screen stays as it is, so an
            // extension can't move typing from one page to the other.
            if (browser.activeSplit()) |pair| if (pair.tabs[0] == tab.id or pair.tabs[1] == tab.id) return ans.none;
            browser.select(tab);
        }
        return ans.none;
    } else if (eql(u8, api, "search.query")) {
        const spec = c.first();
        // Words to search for, as in Chrome — never an address.
        const url = c.browser.searchURL(c.a, ans.str(ans.field(spec, "text")) orelse "") orelse return ans.none;
        const how = ans.str(ans.field(spec, "disposition")) orelse "";
        if (eql(u8, how, "NEW_TAB") or eql(u8, how, "NEW_WINDOW")) {
            _ = c.browser.open(url, .{ .foreground = true });
        } else c.browser.visit(url, false);
        return ans.none;
    }
    return null;
}
