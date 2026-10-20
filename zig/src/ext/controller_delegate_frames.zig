//! Where an extension may send a tab, and where a window it asks for goes
//! (Extensions.swift 1343-1349, 1413-1442).
const std = @import("std");
const objc = @import("nanoui").objc;
const CGRect = objc.CGRect;

/// `Extensions.mayOpen`: not javascript: (its code in whatever page the tab
/// shows) nor a file on this Mac. Null: allowed; else the error's text.
pub fn mayOpen(url: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return null;
    const scheme = url[0..colon];
    if (std.ascii.eqlIgnoreCase(scheme, "javascript")) return "Cannot navigate to a javascript: URL.";
    if (std.ascii.eqlIgnoreCase(scheme, "file")) return "Cannot navigate to a file: URL.";
    return null;
}

fn area(r: CGRect) f64 {
    return r.size.width * r.size.height;
}

fn intersection(a: CGRect, b: CGRect) CGRect {
    const x0 = @max(a.origin.x, b.origin.x);
    const y0 = @max(a.origin.y, b.origin.y);
    const x1 = @min(a.origin.x + a.size.width, b.origin.x + b.size.width);
    const y1 = @min(a.origin.y + a.size.height, b.origin.y + b.size.height);
    if (x1 <= x0 or y1 <= y0) return .{};
    return .{ .origin = .{ .x = x0, .y = y0 }, .size = .{ .width = x1 - x0, .height = y1 - y0 } };
}

/// A usable frame: set, finite, at least 200×150.
pub fn usable(r: CGRect) bool {
    inline for (.{ r.origin.x, r.origin.y, r.size.width, r.size.height }) |v| if (!std.math.isFinite(v)) return false;
    return r.size.width >= 200 and r.size.height >= 150;
}

/// `onScreen` on given screens' visible frames (`main` when none overlap):
/// no larger than the screen it is mostly on, and a good part on one.
pub fn onScreenOf(asked: CGRect, screens: []const CGRect, main: ?CGRect) CGRect {
    var home: ?CGRect = null;
    for (screens) |s| if (home == null or area(intersection(s, asked)) > area(intersection(home.?, asked))) {
        home = s;
    };
    const h = home orelse main orelse return asked;
    var frame = asked;
    frame.size.width = @min(frame.size.width, h.size.width);
    frame.size.height = @min(frame.size.height, h.size.height);
    var seen: CGRect = .{};
    for (screens) |s| {
        const i = intersection(s, frame);
        if (area(i) > area(seen)) seen = i;
    }
    if (seen.size.width < @min(160, frame.size.width) or seen.size.height < @min(120, frame.size.height)) {
        frame.origin.x = @min(@max(frame.origin.x, h.origin.x), h.origin.x + h.size.width - frame.size.width);
        frame.origin.y = @min(@max(frame.origin.y, h.origin.y), h.origin.y + h.size.height - frame.size.height);
    }
    return frame;
}

/// `Extensions.onScreen`: on this Mac's screens.
pub fn onScreen(asked: CGRect) CGRect {
    const pool = objc.Pool.push();
    defer pool.pop();
    var buf: [16]CGRect = undefined;
    const list = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const n = @min(buf.len, objc.msg(objc.NSUInteger, list, "count", .{}));
    for (0..n) |i| buf[i] = objc.msg(CGRect, objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)}), "visibleFrame", .{});
    const main: ?CGRect = if (objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{})) |m| objc.msg(CGRect, m, "visibleFrame", .{}) else null;
    return onScreenOf(asked, buf[0..n], main);
}

/// `popupFrame(asked:on:)`: a popup given a size without a place, that size
/// in the middle of the screen; null when the size isn't one either.
pub fn popupFrame(asked: CGRect, screen: CGRect) ?CGRect {
    if (!std.math.isFinite(asked.size.width) or !std.math.isFinite(asked.size.height)) return null;
    if (asked.size.width < 200 or asked.size.height < 150) return null;
    const w = @min(asked.size.width, screen.size.width);
    const h = @min(asked.size.height, screen.size.height);
    return .{
        .origin = .{ .x = screen.origin.x + screen.size.width / 2 - w / 2, .y = screen.origin.y + screen.size.height / 2 - h / 2 },
        .size = .{ .width = w, .height = h },
    };
}

fn rect(x: f64, y: f64, w: f64, h: f64) CGRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

test "extension popup frame stays on screen" {
    const screen = rect(0, 0, 1440, 900);
    const nan = std.math.nan(f64);
    // A size without a place: centred, and never larger than the screen.
    const p = popupFrame(rect(nan, nan, 400, 600), screen).?;
    try std.testing.expectEqual(rect(520, 150, 400, 600), p);
    try std.testing.expectEqual(rect(0, 0, 1440, 900), popupFrame(rect(nan, nan, 3000, 2000), screen).?);
    try std.testing.expect(popupFrame(rect(0, 0, 100, 600), screen) == null);
    try std.testing.expect(popupFrame(rect(0, 0, nan, 600), screen) == null);
    // Pushed off every screen: pulled back onto the one it is nearest.
    const off = onScreenOf(rect(5000, 5000, 400, 300), &.{screen}, null);
    try std.testing.expectEqual(rect(1040, 600, 400, 300), off);
    // Bigger than the screen: shrunk to it.
    try std.testing.expectEqual(rect(0, 0, 1440, 900), onScreenOf(rect(0, 0, 4000, 4000), &.{screen}, null));
    // Mostly on screen: left where it is.
    try std.testing.expectEqual(rect(100, 100, 400, 300), onScreenOf(rect(100, 100, 400, 300), &.{screen}, null));
    try std.testing.expect(mayOpen("JavaScript:alert(1)") != null and mayOpen("file:///x") != null and mayOpen("https://a/") == null);
}
