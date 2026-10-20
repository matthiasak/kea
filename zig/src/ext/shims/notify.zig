//! notifications.* as the Mac's own (ExtensionShims.swift 3689-3712),
//! posted as "<id>.<key>". A test run (`web/notifications.testing`) posts
//! nothing and never touches UNUserNotificationCenter.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");
const site_notifications = @import("../../web/notifications.zig");

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    if (eql(api, "notifications.create")) return create(c);
    if (eql(api, "notifications.clear")) {
        const key = ans.str(c.first());
        if (key != null and !site_notifications.testing(c.owner.kea)) {
            const pool = objc.Pool.push();
            defer pool.pop();
            const ident = objc.nsString(try std.fmt.allocPrint(c.a, "{s}.{s}", .{ c.id, key.? }));
            objc.msg(void, center(), "removeDeliveredNotificationsWithIdentifiers:", .{objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{ident})});
        }
        return .{ .value = .{ .bool = true } };
    }
    if (eql(api, "notifications.getAll")) return .{ .value = .{ .object = .empty } };
    if (eql(api, "notifications.getPermissionLevel")) return .{ .value = .{ .string = "granted" } };
    if (eql(api, "notifications.update")) return .{ .value = .{ .bool = false } };
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn center() objc.Object {
    return objc.msg(objc.Object, objc.class("UNUserNotificationCenter"), "currentNotificationCenter", .{});
}

/// Asked for, then posted; the key answered once it is.
const Posting = struct { p: *ans.Pending, key: []const u8, request: objc.Object };

fn create(c: *ans.Call) ans.Error!?ans.Out {
    const pool = objc.Pool.push();
    defer pool.pop();
    const named = ans.str(c.first());
    const options = if (named == null) c.first() else c.arg(1);
    const key = named orelse try c.a.dupe(u8, objc.fromNSString(objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSUUID"), "UUID", .{}), "UUIDString", .{})));
    if (site_notifications.testing(c.owner.kea)) return .{ .value = .{ .string = key } };
    const name = objc.fromNSString(objc.msg(?objc.Object, c.webExtension(), "displayName", .{}));
    const content = objc.new("UNMutableNotificationContent");
    defer objc.release(content);
    objc.msg(void, content, "setTitle:", .{objc.nsString(ans.str(ans.field(options, "title")) orelse name)});
    objc.msg(void, content, "setBody:", .{objc.nsString(ans.str(ans.field(options, "message")) orelse "")});
    objc.msg(void, content, "setSubtitle:", .{objc.nsString(name)});
    const ident = try std.fmt.allocPrint(c.a, "{s}.{s}", .{ c.id, key });
    const request = objc.msg(objc.Object, objc.class("UNNotificationRequest"), "requestWithIdentifier:content:trigger:", .{ objc.nsString(ident), content, @as(?objc.Object, null) });
    const posting = try c.a.create(Posting);
    posting.* = .{ .p = c.pending, .key = key, .request = objc.retain(request) };
    var block = objc.Block(Posting, &.{ objc.BOOL, ?objc.Object }).init(posting, authorized);
    // UNAuthorizationOptionAlert | Sound; refused or not, it is posted.
    objc.msg(void, center(), "requestAuthorizationWithOptions:completionHandler:", .{ @as(objc.NSUInteger, 6), @as(*anyopaque, @ptrCast(&block)) });
    return .later;
}

fn authorized(posting: *Posting, _: objc.BOOL, _: ?objc.Object) void {
    var block = objc.Block(Posting, &.{?objc.Object}).init(posting, added);
    objc.msg(void, center(), "addNotificationRequest:withCompletionHandler:", .{ posting.request, @as(*anyopaque, @ptrCast(&block)) });
}

fn added(posting: *Posting, _: ?objc.Object) void {
    objc.dispatchMain(posting, answered);
}

fn answered(ctx: ?*anyopaque) callconv(.c) void {
    const posting: *Posting = @ptrCast(@alignCast(ctx.?));
    objc.release(posting.request);
    // Last: answering frees the arena `posting` lives in.
    posting.p.value(.{ .string = posting.key });
}
