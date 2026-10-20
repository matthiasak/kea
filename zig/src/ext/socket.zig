//! `ExtensionSocket` (ExtensionSocket.swift): a WebSocket for an
//! extension's worker. WebKit runs a worker on its web process's main
//! thread, and a worker's WebSocket waits there on itself, for ever (1Password
//! opening one as a sign-in succeeds froze every page of it). So in a worker
//! the shim's socket is made here instead, with URLSession, and its frames
//! carried over a native port: text as it is, binary as base64. The Origin
//! and the user agent are the ones Chrome would send. Main thread.
const std = @import("std");
const objc = @import("nanoui").objc;
const value = @import("value.zig");
const ext = @import("ext.zig");

/// The native application the shim connects to for a socket
/// (`ExtensionShims.application + ".socket"`).
pub const name = "kea.socket";

const gpa = std.heap.c_allocator;

/// Held from the port's opening until either end lets go.
var open: std.AutoArrayHashMapUnmanaged(u64, *Connection) = .empty;
var serials: u64 = 0;

/// One session for every socket, its delegate queue the main one; each
/// task has its connection as its own delegate.
fn session() objc.Object {
    const S = struct {
        var made: ?objc.Object = null;
    };
    if (S.made) |s| return s;
    const config = objc.msg(objc.Object, objc.class("NSURLSessionConfiguration"), "defaultSessionConfiguration", .{});
    const queue = objc.msg(objc.Object, objc.class("NSOperationQueue"), "mainQueue", .{});
    const s = objc.msg(objc.Object, objc.class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:", .{ config, @as(?objc.Object, null), queue });
    S.made = objc.retain(s);
    return s;
}

pub fn connect(port: objc.Object, ext_id: []const u8) void {
    const c = gpa.create(Connection) catch return;
    serials += 1;
    c.* = .{
        .serial = serials,
        .port = objc.retain(port),
        .origin = std.fmt.allocPrint(gpa, "{s}://{s}", .{ ext.scheme, ext_id }) catch return gpa.destroy(c),
        .delegate = objc.msg(objc.Object, delegateClass(), "new", .{}),
    };
    objc.setZig(c.delegate, c);
    open.put(gpa, c.serial, c) catch {};
    const ctx: *anyopaque = @ptrFromInt(c.serial);
    var on_message = objc.Block(anyopaque, &.{ ?objc.Object, ?objc.Object }).init(ctx, portMessage);
    objc.msg(void, port, "setMessageHandler:", .{&on_message});
    var on_disconnect = objc.Block(anyopaque, &.{?objc.Object}).init(ctx, portGone);
    objc.msg(void, port, "setDisconnectHandler:", .{&on_disconnect});
    // WebKit loses a port a worker opens in its first moments; the shim
    // takes this for the sign that this one arrived.
    c.post(.{ .ready = true });
}

fn of(ctx: *anyopaque) ?*Connection {
    return open.get(@intFromPtr(ctx));
}

fn portGone(ctx: *anyopaque, _: ?objc.Object) void {
    if (of(ctx)) |c| c.end(false);
}

fn kind(o: objc.Object, comptime cls: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class(cls)});
}

fn field(d: objc.Object, key: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString(key)});
}

fn text(d: objc.Object, key: []const u8) ?objc.Object {
    const v = field(d, key) orelse return null;
    return if (kind(v, "NSString")) v else null;
}

fn portMessage(ctx: *anyopaque, message: ?objc.Object, _: ?objc.Object) void {
    const c = of(ctx) orelse return;
    const m = message orelse return;
    if (!kind(m, "NSDictionary")) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    // The worker's shim asks every port to an app whether it has arrived
    // before sending on it (see native.zig): this one answers too.
    if (field(m, "__keaNative")) |word| {
        if (kind(word, "NSString") and std.mem.eql(u8, objc.fromNSString(word), "here?")) c.post(.{ .__keaNative = "here" });
        return;
    }
    if (text(m, "open")) |address| {
        // Said again now that the worker is surely listening: the first,
        // sent as the port opened, is often lost. A repeat is only answered.
        c.post(.{ .ready = true });
        if (c.task != null) return;
        c.start(address, field(m, "protocols"), text(m, "userAgent"));
    } else if (text(m, "send")) |t| {
        c.sendFrame(objc.msg(objc.Object, objc.alloc("NSURLSessionWebSocketMessage"), "initWithString:", .{t}));
    } else if (text(m, "sendBinary")) |encoded| {
        const data = objc.msg(?objc.Object, objc.alloc("NSData"), "initWithBase64EncodedString:options:", .{ encoded, @as(objc.NSUInteger, 0) }) orelse return;
        defer objc.release(data);
        c.sendFrame(objc.msg(objc.Object, objc.alloc("NSURLSessionWebSocketMessage"), "initWithData:", .{data}));
    } else if (field(m, "close")) |code_obj| {
        const task = c.task orelse return;
        const code: objc.NSInteger = if (kind(code_obj, "NSNumber")) objc.msg(objc.NSInteger, code_obj, "integerValue", .{}) else 1000;
        const reason: ?objc.Object = if (text(m, "reason")) |r| objc.msg(objc.Object, r, "dataUsingEncoding:", .{@as(objc.NSUInteger, 4)}) else null;
        objc.msg(void, task, "cancelWithCloseCode:reason:", .{ code, reason });
    }
}

var nothing: u8 = 0;

fn ignored(_: *u8, _: ?objc.Object) void {}

const Connection = struct {
    serial: u64,
    /// The port (retained), the URLSessionWebSocketTask (retained) and its
    /// delegate (+1; `setZig` → this).
    port: objc.Object,
    origin: []u8,
    task: ?objc.Object = null,
    delegate: objc.Object,
    ended: bool = false,

    fn post(self: *Connection, message: anytype) void {
        if (objc.msg(objc.BOOL, self.port, "isDisconnected", .{})) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, self.port, "sendMessage:completionHandler:", .{ value.objectOf(message), @as(?*anyopaque, null) });
    }

    /// Takes the +1 message.
    fn sendFrame(self: *Connection, message: objc.Object) void {
        defer objc.release(message);
        const task = self.task orelse return;
        var done = objc.Block(u8, &.{?objc.Object}).init(&nothing, ignored);
        objc.msg(void, task, "sendMessage:completionHandler:", .{ message, &done });
    }

    fn start(self: *Connection, address: objc.Object, protocols: ?objc.Object, user_agent: ?objc.Object) void {
        const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{address}) orelse return self.fail();
        const scheme = objc.fromNSString(objc.msg(?objc.Object, url, "scheme", .{}));
        if (!std.ascii.eqlIgnoreCase(scheme, "ws") and !std.ascii.eqlIgnoreCase(scheme, "wss")) return self.fail();
        const request = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{url});
        objc.msg(void, request, "setValue:forHTTPHeaderField:", .{ objc.nsString(self.origin), objc.nsString("Origin") });
        if (user_agent) |ua| objc.msg(void, request, "setValue:forHTTPHeaderField:", .{ ua, objc.nsString("User-Agent") });
        // `as? [String] ?? []`, joined by ", ".
        if (protocols) |list| if (kind(list, "NSArray")) {
            const n = objc.msg(objc.NSUInteger, list, "count", .{});
            var all = n > 0;
            for (0..n) |i| all = all and kind(objc.msg(objc.Object, list, "objectAtIndex:", .{i}), "NSString");
            if (all) objc.msg(void, request, "setValue:forHTTPHeaderField:", .{ objc.msg(objc.Object, list, "componentsJoinedByString:", .{objc.nsString(", ")}), objc.nsString("Sec-WebSocket-Protocol") });
        };
        const task = objc.msg(objc.Object, session(), "webSocketTaskWithRequest:", .{request});
        objc.msg(void, task, "setDelegate:", .{self.delegate});
        self.task = objc.retain(task);
        objc.msg(void, task, "resume", .{});
    }

    /// Frames as they come, until the socket ends; how it ended is the
    /// delegate's to say.
    fn receive(self: *Connection, task: objc.Object) void {
        var got = objc.Block(anyopaque, &.{ ?objc.Object, ?objc.Object }).init(@ptrFromInt(self.serial), received);
        objc.msg(void, task, "receiveMessageWithCompletionHandler:", .{&got});
    }

    fn fail(self: *Connection) void {
        self.post(.{ .failed = true });
        self.post(.{ .closed = 1006, .reason = "", .clean = false });
        self.end(true);
    }

    fn end(self: *Connection, telling_port: bool) void {
        if (self.ended) return;
        self.ended = true;
        // NSURLSessionWebSocketCloseCodeGoingAway.
        if (self.task) |t| objc.msg(void, t, "cancelWithCloseCode:reason:", .{ @as(objc.NSInteger, 1001), @as(?objc.Object, null) });
        if (telling_port and !objc.msg(objc.BOOL, self.port, "isDisconnected", .{})) objc.msg(void, self.port, "disconnect", .{});
        _ = open.swapRemove(self.serial);
        // The task holds its delegate until it completes; it hears no one now.
        objc.setZig(self.delegate, null);
        objc.release(self.delegate);
        if (self.task) |t| objc.release(t);
        objc.release(self.port);
        gpa.free(self.origin);
        gpa.destroy(self);
    }
};

fn received(ctx: *anyopaque, message: ?objc.Object, _: ?objc.Object) void {
    const m = message orelse return;
    const c = of(ctx) orelse return;
    if (c.ended) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    // NSURLSessionWebSocketMessageTypeData = 0, String = 1.
    if (objc.msg(objc.NSInteger, m, "type", .{}) == 1) {
        c.post(.{ .text = objc.fromNSString(objc.msg(?objc.Object, m, "string", .{})) });
    } else if (objc.msg(?objc.Object, m, "data", .{})) |d| {
        c.post(.{ .binary = objc.fromNSString(objc.msg(objc.Object, d, "base64EncodedStringWithOptions:", .{@as(objc.NSUInteger, 0)})) });
    }
    if (c.task) |t| c.receive(t);
}

// MARK: URLSessionWebSocketDelegate

fn delegateClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigExtensionSocket",
        .protocols = &.{"NSURLSessionWebSocketDelegate"},
        .methods = &[_]objc.Method{
            .{ .name = "URLSession:webSocketTask:didOpenWithProtocol:", .imp = &didOpen, .types = "v@:@@@" },
            .{ .name = "URLSession:webSocketTask:didCloseWithCode:reason:", .imp = &didClose, .types = "v@:@@q@" },
            .{ .name = "URLSession:task:didCompleteWithError:", .imp = &didComplete, .types = "v@:@@@" },
        },
    });
}

fn didOpen(self: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object, chosen: ?objc.Object) callconv(.c) void {
    const c = objc.getZig(Connection, self) orelse return;
    c.post(.{ .opened = objc.fromNSString(chosen) });
    c.receive(task);
}

fn didClose(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, code: objc.NSInteger, reason: ?objc.Object) callconv(.c) void {
    const c = objc.getZig(Connection, self) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    var said: ?objc.Object = null;
    if (reason) |r| if (objc.msg(?objc.Object, objc.alloc("NSString"), "initWithData:encoding:", .{ r, @as(objc.NSUInteger, 4) })) |s| {
        objc.autorelease(s);
        said = s;
    };
    c.post(.{ .closed = code, .reason = objc.fromNSString(said), .clean = true });
    c.end(true);
}

fn didComplete(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, err: ?objc.Object) callconv(.c) void {
    const c = objc.getZig(Connection, self) orelse return;
    if (c.ended) return;
    if (err != null) return c.fail();
    c.post(.{ .closed = 1005, .reason = "", .clean = true });
    c.end(true);
}
