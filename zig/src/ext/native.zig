//! Chrome's native messaging (ExtensionNative.swift), for the extensions
//! that talk to an app on this Mac. Those apps leave a small JSON file in
//! Chrome's NativeMessagingHosts folder: a name, the program to run, and
//! which extensions may run it. The same files are read, the same program
//! run with the same argument, the same protocol spoken (`native_pipe.zig`).
//! A host that lists the extension's id among its allowed origins is run;
//! any other is not.
const std = @import("std");
const objc = @import("nanoui").objc;
const value = @import("value.zig");
const disk = @import("../data/disk.zig");
const HostPipe = @import("native_pipe.zig").HostPipe;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
const X_OK = 1;

const gpa = std.heap.c_allocator;

pub const Error = error{ InvalidName, Forbidden, NotFound, NoHost, TooLong, Exited };

/// `Refused`'s text for each.
pub fn refused(err: Error) []const u8 {
    return switch (err) {
        error.InvalidName => "Invalid native messaging host name",
        error.Forbidden => "Access to the specified native messaging host is forbidden.",
        error.NotFound => "Specified native messaging host not found.",
        error.NoHost => "No host named",
        error.TooLong => "Message too long for a native host",
        error.Exited => "Native host has exited.",
    };
}

/// The controller delegate's refusal for an extension that didn't ask
/// (Extensions.swift 1499, 1523).
pub const permission_refused = "Access to native messaging requires the nativeMessaging permission.";

/// Where Chromium browsers look, per user (relative to home) and for the
/// whole Mac. Vivaldi and Opera last: a host of the same name that Chrome
/// or the system knows comes first.
const folders = [_][]const u8{
    "~/Library/Application Support/Google/Chrome/NativeMessagingHosts",
    "~/Library/Application Support/Chromium/NativeMessagingHosts",
    "~/Library/Application Support/Microsoft Edge/NativeMessagingHosts",
    "~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
    "~/Library/Application Support/Arc/User Data/NativeMessagingHosts",
    "/Library/Google/Chrome/NativeMessagingHosts",
    "/Library/Application Support/Chromium/NativeMessagingHosts",
    "/Library/Microsoft/Edge/NativeMessagingHosts",
    "~/Library/Application Support/Vivaldi/NativeMessagingHosts",
    "~/Library/Application Support/com.operasoftware.Opera/NativeMessagingHosts",
};

/// `^[a-z0-9_]+(\.[a-z0-9_]+)*$`
fn validName(name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, name, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    }
    return true;
}

fn kind(o: objc.Object, comptime cls: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class(cls)});
}

/// The program for `name` (on `gpa`), if one is registered and lets this
/// extension in.
fn host(name: []const u8, ext_id: []const u8) Error![:0]u8 {
    if (!validName(name)) return error.InvalidName;
    const home: []const u8 = if (getenv("HOME")) |h| std.mem.span(h) else "";
    const origin = std.fmt.allocPrint(gpa, "chrome-extension://{s}/", .{ext_id}) catch return error.NotFound;
    defer gpa.free(origin);
    const pool = objc.Pool.push();
    defer pool.pop();
    for (folders) |raw| {
        const folder = (if (raw[0] == '~') std.mem.concat(gpa, u8, &.{ home, raw[1..] }) else gpa.dupe(u8, raw)) catch continue;
        defer gpa.free(folder);
        const file = std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ folder, name }) catch continue;
        defer gpa.free(file);
        const data = disk.read(gpa, file) orelse continue;
        defer gpa.free(data);
        const manifest = value.fromText(data) orelse continue;
        if (!kind(manifest, "NSDictionary")) continue;
        const path_obj = objc.msg(?objc.Object, manifest, "objectForKey:", .{objc.nsString("path")}) orelse continue;
        if (!kind(path_obj, "NSString")) continue;
        // `as? [String] ?? []`.
        var allowed = false;
        if (objc.msg(?objc.Object, manifest, "objectForKey:", .{objc.nsString("allowed_origins")})) |list| if (kind(list, "NSArray")) {
            const n = objc.msg(objc.NSUInteger, list, "count", .{});
            var strings = true;
            for (0..n) |i| {
                const item = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
                if (!kind(item, "NSString")) strings = false else if (std.mem.eql(u8, objc.fromNSString(item), origin)) allowed = true;
            }
            allowed = allowed and strings;
        };
        if (!allowed) return error.Forbidden;
        const path = objc.fromNSString(path_obj);
        const program = (if (std.mem.startsWith(u8, path, "/")) gpa.dupeSentinel(u8, path, 0) else std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ folder, path }, 0)) catch return error.NotFound;
        if (access(program, X_OK) != 0) {
            gpa.free(program);
            return error.NotFound;
        }
        return program;
    }
    return error.NotFound;
}

fn originOf(ext_id: []const u8) ?[]u8 {
    return std.fmt.allocPrint(gpa, "chrome-extension://{s}/", .{ext_id}) catch null;
}

// MARK: runtime.sendNativeMessage

/// One `send` in flight: answered by the host's first message, or failed
/// when it ends first.
const Send = struct {
    pipe: ?*HostPipe = null,
    reply: ?value.Reply,
    key: []u8,

    fn heard(owner: *anyopaque, message: objc.Object) void {
        const s: *Send = @ptrCast(@alignCast(owner));
        const reply = s.reply orelse return;
        s.reply = null;
        reply.ok(message);
        s.pipe.?.stop();
    }

    fn ended(owner: *anyopaque) void {
        const s: *Send = @ptrCast(@alignCast(owner));
        if (s.reply) |reply| failed(reply, s.key, error.Exited) else gpa.free(s.key);
        gpa.destroy(s);
    }
};

/// `runtime.sendNativeMessage`: run, send one, read one, stop. `reply`
/// is answered with the host's message or fails with `refused`'s text.
pub fn send(message: objc.Object, host_name: []const u8, ext_id: []const u8, reply: value.Reply) void {
    const key = std.mem.concat(gpa, u8, &.{ ext_id, "→", host_name }) catch return reply.fail(refused(error.Exited));
    const program = host(host_name, ext_id) catch |e| return failed(reply, key, e);
    defer gpa.free(program);
    const origin = originOf(ext_id) orelse return failed(reply, key, error.Exited);
    defer gpa.free(origin);
    const s = gpa.create(Send) catch return failed(reply, key, error.Exited);
    s.* = .{ .reply = reply, .key = key };
    const pipe = HostPipe.start(gpa, program, origin, s, Send.heard, Send.ended) catch {
        gpa.destroy(s);
        return failed(reply, key, error.NotFound);
    };
    s.pipe = pipe;
    pipe.send(message) catch |e| {
        s.reply = null;
        pipe.stop();
        // `ended` still comes, with nothing left to answer.
        const k = gpa.dupe(u8, key) catch return reply.fail(refused(e));
        failed(reply, k, e);
    };
}

/// An extension asking an app that isn't there, over and over — a retry
/// loop — is answered slowly once it has asked a dozen times in a second,
/// so it can't swamp the browser (Extensions.swift 1503-1510). Takes `key`.
var failures: std.StringArrayHashMapUnmanaged(std.ArrayList(f64)) = .empty;

fn failed(reply: value.Reply, key: []u8, err: Error) void {
    const now = @import("../data/json.zig").now();
    const entry = failures.getOrPut(gpa, key) catch {
        gpa.free(key);
        return reply.fail(refused(err));
    };
    if (entry.found_existing) gpa.free(key) else entry.value_ptr.* = .empty;
    const list = entry.value_ptr;
    var kept: usize = 0;
    for (list.items) |t| if (now - t < 1) {
        list.items[kept] = t;
        kept += 1;
    };
    list.shrinkRetainingCapacity(kept);
    list.append(gpa, now) catch {};
    if (list.items.len <= 12) return reply.fail(refused(err));
    const later = gpa.create(Later) catch return reply.fail(refused(err));
    later.* = .{ .reply = reply, .why = refused(err) };
    objc.dispatchAfter(std.time.ns_per_s, later, Later.run);
}

const Later = struct {
    reply: value.Reply,
    why: []const u8,
    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Later = @ptrCast(@alignCast(ctx.?));
        defer gpa.destroy(l);
        l.reply.fail(l.why);
    }
};

// MARK: runtime.connectNative

/// A host connected to a port, held until the host ends (`Live`).
const Link = struct {
    serial: u64,
    pipe: *HostPipe,
    /// The `WKWebExtensionMessagePort` (retained).
    port: objc.Object,
    beating: bool = false,

    fn heard(owner: *anyopaque, message: objc.Object) void {
        const l: *Link = @ptrCast(@alignCast(owner));
        objc.msg(void, l.port, "sendMessage:completionHandler:", .{ message, @as(?*anyopaque, null) });
    }

    fn ended(owner: *anyopaque) void {
        const l: *Link = @ptrCast(@alignCast(owner));
        if (!disconnected(l.port)) objc.msg(void, l.port, "disconnect", .{});
        _ = live.swapRemove(l.serial);
        objc.release(l.port);
        gpa.destroy(l);
    }
};

var live: std.AutoArrayHashMapUnmanaged(u64, *Link) = .empty;
var serials: u64 = 0;

fn disconnected(port: objc.Object) bool {
    return objc.msg(objc.BOOL, port, "isDisconnected", .{});
}

fn linkOf(ctx: *anyopaque) ?*Link {
    return live.get(@intFromPtr(ctx));
}

/// `runtime.connectNative`: run, and keep the two talking until either
/// end lets go. Main thread.
pub fn connect(port: objc.Object, ext_id: []const u8) Error!void {
    const name = objc.msg(?objc.Object, port, "applicationIdentifier", .{}) orelse return error.NoHost;
    const program = try host(objc.fromNSString(name), ext_id);
    defer gpa.free(program);
    // A new port is often a worker starting over; the one before may have
    // left its host behind.
    stopOrphans();
    const origin = originOf(ext_id) orelse return error.NotFound;
    defer gpa.free(origin);
    const l = gpa.create(Link) catch return error.NotFound;
    serials += 1;
    l.* = .{ .serial = serials, .pipe = undefined, .port = objc.retain(port) };
    l.pipe = HostPipe.start(gpa, program, origin, l, Link.heard, Link.ended) catch {
        objc.release(l.port);
        gpa.destroy(l);
        return error.NotFound;
    };
    live.put(gpa, l.serial, l) catch {};
    const ctx: *anyopaque = @ptrFromInt(l.serial);
    var on_message = objc.Block(anyopaque, &.{ ?objc.Object, ?objc.Object }).init(ctx, portMessage);
    objc.msg(void, port, "setMessageHandler:", .{&on_message});
    var on_disconnect = objc.Block(anyopaque, &.{?objc.Object}).init(ctx, portGone);
    objc.msg(void, port, "setDisconnectHandler:", .{&on_disconnect});
}

fn portMessage(ctx: *anyopaque, message: ?objc.Object, _: ?objc.Object) void {
    const m = message orelse return;
    const l = linkOf(ctx) orelse return;
    // A worker's shim asking whether the port has arrived (see the shim,
    // after its WebSocket): answered here, never passed on.
    if (kind(m, "NSDictionary")) if (objc.msg(?objc.Object, m, "objectForKey:", .{objc.nsString("__keaNative")})) |word| {
        // The shim's answer to "alive" is only the worker keeping itself.
        if (!kind(word, "NSString") or !std.mem.eql(u8, objc.fromNSString(word), "here?")) return;
        say(l.port, "here");
        // WebKit unloads a worker that hasn't posted on a port for two
        // minutes (iCloud Passwords then forgets it was paired); a word now
        // and then, heard only by the shim, has the worker answer on it.
        if (!l.beating) {
            l.beating = true;
            objc.dispatchAfter(25 * std.time.ns_per_s, ctx, beat);
        }
        return;
    };
    l.pipe.send(m) catch {};
}

fn say(port: objc.Object, word: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(void, port, "sendMessage:completionHandler:", .{ value.objectOf(.{ .__keaNative = word }), @as(?*anyopaque, null) });
}

fn beat(ctx: ?*anyopaque) callconv(.c) void {
    const l = linkOf(ctx.?) orelse return;
    if (!l.beating or disconnected(l.port)) return;
    say(l.port, "alive");
    objc.dispatchAfter(25 * std.time.ns_per_s, ctx, beat);
}

fn portGone(ctx: *anyopaque, _: ?objc.Object) void {
    const l = linkOf(ctx) orelse return;
    l.beating = false;
    l.pipe.stop();
}

/// WebKit doesn't always say when a port goes: an extension unloaded
/// leaves its worker's ports disconnected without calling their handlers,
/// and each host would run on until the browser quit. The hosts of ports
/// that have gone are stopped; a port still connected keeps its own.
pub fn stopOrphans() void {
    for (live.values()) |l| if (disconnected(l.port)) l.pipe.stop();
}

test "native host names" {
    try std.testing.expect(validName("com.1password.native_messaging"));
    try std.testing.expect(!validName("Com.app"));
    try std.testing.expect(!validName("a..b"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("a.b."));
}
