//! What the e2e pages are served from: `KeaTestScheme`, a WKURLSchemeHandler
//! for `kea-test://site/<path>`, and a loopback HTTP listener for cases that
//! need http (History only records http and https, as Swift's does; WebKit
//! downloads nothing from a custom scheme, so `/download?name=N` there too;
//! `/words/a-b-c` there has the body "a b c", any other path itself).
//!
//! Routes: `/page?title=T&body=B`, `/slow` (first bytes now, the rest after
//! 8 s), `/download?name=N` (a 4 KiB attachment), `/f/<file>` (fixtures/),
//! anything else 404.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const fixtures = [_]struct { []const u8, []const u8 }{
    .{ "hello.html", @embedFile("fixtures/hello.html") },
    .{ "favicon.html", @embedFile("fixtures/favicon.html") },
    .{ "questions.html", @embedFile("fixtures/questions.html") },
    .{ "links.html", @embedFile("fixtures/links.html") },
    .{ "article.html", @embedFile("fixtures/article.html") },
    .{ "float.html", @embedFile("fixtures/float.html") },
    .{ "login.html", @embedFile("fixtures/login.html") },
};

/// Tasks `/slow` still owes a finish; a stopped task leaves the list.
var slow_tasks: std.ArrayListUnmanaged(objc.Object) = .empty;

/// The handler object to pass as `Kea.Options.scheme_handler`.
pub fn handler() objc.Object {
    const cls = objc.defineClass(.{
        .name = "KeaTestScheme",
        .protocols = &.{"WKURLSchemeHandler"},
        .methods = &.{
            .{ .name = "webView:startURLSchemeTask:", .imp = &startTask, .types = "v@:@@" },
            .{ .name = "webView:stopURLSchemeTask:", .imp = &stopTask, .types = "v@:@@" },
        },
    });
    return objc.msg(objc.Object, cls, "new", .{});
}

fn query(url: objc.Object, name: []const u8) []const u8 {
    const comps = objc.msg(?objc.Object, objc.class("NSURLComponents"), "componentsWithURL:resolvingAgainstBaseURL:", .{ url, objc.NO }) orelse return "";
    const items = objc.msg(?objc.Object, comps, "queryItems", .{}) orelse return "";
    const n = objc.msg(objc.NSUInteger, items, "count", .{});
    for (0..n) |i| {
        const item = objc.msg(objc.Object, items, "objectAtIndex:", .{i});
        if (std.mem.eql(u8, objc.fromNSString(objc.msg(?objc.Object, item, "name", .{})), name))
            return objc.fromNSString(objc.msg(?objc.Object, item, "value", .{}));
    }
    return "";
}

fn respond(task: objc.Object, url: objc.Object, status: objc.NSInteger, mime: []const u8, disposition: ?[]const u8, body: []const u8, finish: bool) void {
    var keys: [2]objc.Object = .{ objc.nsString("Content-Type"), objc.nsString("Content-Disposition") };
    var values: [2]objc.Object = .{ objc.nsString(mime), objc.nsString(disposition orelse "") };
    const count: objc.NSUInteger = if (disposition != null) 2 else 1;
    const headers = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, count });
    const res = objc.msg(objc.Object, objc.alloc("NSHTTPURLResponse"), "initWithURL:statusCode:HTTPVersion:headerFields:", .{
        url, status, objc.nsString("HTTP/1.1"), headers,
    });
    defer objc.release(res);
    objc.msg(void, task, "didReceiveResponse:", .{res});
    objc.msg(void, task, "didReceiveData:", .{objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ body.ptr, body.len })});
    if (finish) objc.msg(void, task, "didFinish", .{});
}

fn startTask(_: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object) callconv(.c) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.msg(objc.Object, task, "request", .{}), "URL", .{});
    const path = objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}));
    var buf: [4096]u8 = undefined;
    if (std.mem.eql(u8, path, "/page")) {
        const html = std.fmt.bufPrint(&buf, "<html><head><title>{s}</title></head><body>{s}</body></html>", .{ query(url, "title"), query(url, "body") }) catch "";
        return respond(task, url, 200, "text/html", null, html, true);
    }
    if (std.mem.eql(u8, path, "/slow")) {
        respond(task, url, 200, "text/html", null, "<html><head><title>Slow Page</title></head><body>", false);
        slow_tasks.append(std.heap.c_allocator, objc.retain(task)) catch return;
        objc.dispatchAfter(8 * std.time.ns_per_s, task, finishSlow);
        return;
    }
    if (std.mem.eql(u8, path, "/download")) {
        const disp = std.fmt.bufPrint(&buf, "attachment; filename={s}", .{query(url, "name")}) catch "attachment";
        const body: [4096]u8 = @splat('k');
        return respond(task, url, 200, "application/octet-stream", disp, &body, true);
    }
    if (std.mem.startsWith(u8, path, "/f/")) {
        for (fixtures) |f| if (std.mem.eql(u8, f[0], path[3..])) return respond(task, url, 200, "text/html", null, f[1], true);
    }
    respond(task, url, 404, "text/plain", null, "Not Found", true);
}

fn takeSlow(task: objc.Object) bool {
    for (slow_tasks.items, 0..) |t, i| if (t == task) {
        _ = slow_tasks.swapRemove(i);
        return true;
    };
    return false;
}

fn finishSlow(ctx: ?*anyopaque) callconv(.c) void {
    const task: objc.Object = @ptrCast(ctx orelse return);
    if (!takeSlow(task)) return;
    objc.msg(void, task, "didReceiveData:", .{objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ "</body></html>".ptr, @as(objc.NSUInteger, 14) })});
    objc.msg(void, task, "didFinish", .{});
    objc.release(task);
}

fn stopTask(_: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object) callconv(.c) void {
    if (takeSlow(task)) objc.release(task);
}

// The loopback listener: one thread, one request per connection.
const sock = struct {
    const SockaddrIn = extern struct { len: u8 = 16, family: u8 = 2, port: u16 = 0, addr: u32 = 0, zero: [8]u8 = @splat(0) };
    extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
    extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern "c" fn getsockname(fd: c_int, addr: *SockaddrIn, len: *u32) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
};

/// Starts the listener on 127.0.0.1 and returns its port.
pub fn listen() !u16 {
    const fd = sock.socket(2, 1, 0);
    if (fd < 0) return error.Socket;
    var addr: sock.SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (sock.bind(fd, &addr, @sizeOf(sock.SockaddrIn)) != 0 or sock.listen(fd, 16) != 0) return error.Bind;
    var len: u32 = @sizeOf(sock.SockaddrIn);
    if (sock.getsockname(fd, &addr, &len) != 0) return error.Bind;
    const th = try std.Thread.spawn(.{}, serve, .{fd});
    th.detach();
    return std.mem.bigToNative(u16, addr.port);
}

/// A thread per connection: WebKit may hold one open without asking
/// anything (a link click it was told to cancel), and the next must not
/// wait behind it.
fn serve(fd: c_int) void {
    while (true) {
        const client = sock.accept(fd, null, null);
        if (client < 0) continue;
        const th = std.Thread.spawn(.{}, answer, .{client}) catch {
            _ = sock.close(client);
            continue;
        };
        th.detach();
    }
}

fn answer(client: c_int) void {
    defer _ = sock.close(client);
    var req: [4096]u8 = undefined;
    const n = sock.read(client, &req, req.len);
    if (n <= 0) return;
    // "GET <path> HTTP/1.1"
    var parts = std.mem.splitScalar(u8, req[0..@intCast(n)], ' ');
    _ = parts.next();
    const path = parts.next() orelse "/";
    // WebKit won't download from a custom scheme: `/download?name=N`
    // is an http attachment here (the plan's P5.8 fallback).
    const download_route = "/download?name=";
    if (std.mem.startsWith(u8, path, download_route)) {
        var dl_head_buf: [512]u8 = undefined;
        const dl_head = std.fmt.bufPrint(&dl_head_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename={s}\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n", .{path[download_route.len..]}) catch return;
        const file: [4096]u8 = @splat('k');
        _ = sock.write(client, dl_head.ptr, dl_head.len);
        _ = sock.write(client, &file, file.len);
        return;
    }
    // `/words/a-b-c`: its body is "a b c", words neither its address nor its title has.
    var words_buf: [256]u8 = undefined;
    const words_route = "/words/";
    const shown = if (std.mem.startsWith(u8, path, words_route) and path.len - words_route.len <= words_buf.len) blk: {
        const w = words_buf[0 .. path.len - words_route.len];
        _ = std.mem.replace(u8, path[words_route.len..], "-", " ", w);
        break :blk w;
    } else path;
    var body_buf: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "<html><head><title>Local {s}</title></head><body>{s}</body></html>", .{ path, shown }) catch return;
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
    _ = sock.write(client, head.ptr, head.len);
    _ = sock.write(client, body.ptr, body.len);
}
