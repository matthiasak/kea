//! `When` (Recall.swift): how a moment reads in the lists — "2 hr. ago",
//! the time of day, "Today", "Yesterday" or "4 March". The formatters are
//! made once, as Swift's static ones are. Strings land on `alloc`.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");

var cal: ?objc.Object = null;
var hour: ?objc.Object = null;
var plain: ?objc.Object = null;
var ago: ?objc.Object = null;
var brief: ?objc.Object = null;

fn date(at: json.SwiftDate) objc.Object {
    return objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceReferenceDate:", .{at});
}

fn calendar() objc.Object {
    if (cal) |c| return c;
    const c = objc.retain(objc.msg(objc.Object, objc.class("NSCalendar"), "autoupdatingCurrentCalendar", .{}));
    cal = c;
    return c;
}

fn copy(alloc: std.mem.Allocator, s: ?objc.Object) []const u8 {
    return alloc.dupe(u8, objc.fromNSString(s)) catch "";
}

/// `When.said`: "2 hr. ago", relative to now (abbreviated units).
pub fn said(alloc: std.mem.Allocator, at: json.SwiftDate) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const f = ago orelse blk: {
        const m = objc.msg(objc.Object, objc.alloc("NSRelativeDateTimeFormatter"), "init", .{});
        // NSRelativeDateTimeFormatterUnitsStyleAbbreviated = 3.
        objc.msg(void, m, "setUnitsStyle:", .{@as(objc.NSInteger, 3)});
        ago = m;
        break :blk m;
    };
    const now = objc.msg(objc.Object, objc.class("NSDate"), "date", .{});
    return copy(alloc, objc.msg(?objc.Object, f, "localizedStringForDate:relativeToDate:", .{ date(at), now }));
}

/// `When.clock`: the time of day (the short time style).
pub fn clock(alloc: std.mem.Allocator, at: json.SwiftDate) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const f = hour orelse blk: {
        const m = objc.msg(objc.Object, objc.alloc("NSDateFormatter"), "init", .{});
        // NSDateFormatterShortStyle = 1, NoStyle = 0.
        objc.msg(void, m, "setTimeStyle:", .{@as(objc.NSUInteger, 1)});
        objc.msg(void, m, "setDateStyle:", .{@as(objc.NSUInteger, 0)});
        hour = m;
        break :blk m;
    };
    return copy(alloc, objc.msg(?objc.Object, f, "stringFromDate:", .{date(at)}));
}

/// `When.day`: "Today", "Yesterday", or "d MMMM".
pub fn day(alloc: std.mem.Allocator, at: json.SwiftDate) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const d = date(at);
    const c = calendar();
    if (objc.msg(objc.BOOL, c, "isDateInToday:", .{d})) return "Today";
    if (objc.msg(objc.BOOL, c, "isDateInYesterday:", .{d})) return "Yesterday";
    const f = plain orelse blk: {
        const m = objc.msg(objc.Object, objc.alloc("NSDateFormatter"), "init", .{});
        objc.msg(void, m, "setDateFormat:", .{objc.nsString("d MMMM")});
        plain = m;
        break :blk m;
    };
    return copy(alloc, objc.msg(?objc.Object, f, "stringFromDate:", .{d}));
}

/// `.formatted(.dateTime.day().month())`: "27 Sep", in the Mac's own order.
pub fn dayMonth(alloc: std.mem.Allocator, at: json.SwiftDate) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const f = brief orelse blk: {
        const m = objc.msg(objc.Object, objc.alloc("NSDateFormatter"), "init", .{});
        const locale = objc.msg(objc.Object, objc.class("NSLocale"), "currentLocale", .{});
        const format = objc.msg(?objc.Object, objc.class("NSDateFormatter"), "dateFormatFromTemplate:options:locale:", .{ objc.nsString("dMMM"), @as(objc.NSUInteger, 0), locale });
        objc.msg(void, m, "setDateFormat:", .{format orelse objc.nsString("d MMM")});
        brief = m;
        break :blk m;
    };
    return copy(alloc, objc.msg(?objc.Object, f, "stringFromDate:", .{date(at)}));
}

/// `Calendar.current.startOfDay(for:)`.
pub fn startOfDay(at: json.SwiftDate) json.SwiftDate {
    const pool = objc.Pool.push();
    defer pool.pop();
    const d = objc.msg(objc.Object, calendar(), "startOfDayForDate:", .{date(at)});
    return objc.msg(f64, d, "timeIntervalSinceReferenceDate", .{});
}

test "when names today and starts the day at midnight" {
    const t = std.testing;
    const now = json.now();
    try t.expectEqualStrings("Today", day(t.allocator, now));
    try t.expectEqualStrings("Yesterday", day(t.allocator, now - 86400));
    const start = startOfDay(now);
    try t.expect(start <= now and now - start < 86400 + 3600);
    const c = clock(t.allocator, now);
    defer t.allocator.free(c);
    try t.expect(c.len > 0);
}
