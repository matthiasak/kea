//! NSURLSession requests, waited for. The answer lands on the session's own
//! queue, so the caller blocks: background queues only, never the main thread.
const std = @import("std");
const objc = @import("nanoui").objc;

pub const Response = struct {
    code: i64,
    /// On the caller's allocator.
    body: []u8,
};

/// An ephemeral session, `timeout` seconds per request; retained.
pub fn ephemeral(timeout: f64) objc.Object {
    const pool = objc.Pool.push();
    defer pool.pop();
    const config = objc.msg(objc.Object, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
    objc.msg(void, config, "setTimeoutIntervalForRequest:", .{timeout});
    return objc.retain(objc.msg(objc.Object, objc.class("NSURLSession"), "sessionWithConfiguration:", .{config}));
}

const Wait = struct {
    sem: objc.dispatch_semaphore_t,
    data: ?objc.Object = null,
    response: ?objc.Object = null,
    failed: bool = false,
};

fn done(w: *Wait, data: ?objc.Object, response: ?objc.Object, err: ?objc.Object) void {
    if (data) |d| w.data = objc.retain(d);
    if (response) |r| w.response = objc.retain(r);
    w.failed = err != null;
    _ = objc.dispatch_semaphore_signal(w.sem);
}

/// `session.data(for:)`: null when no answer came (no connection, timed
/// out); `code` is 0 when the answer wasn't HTTP.
pub fn send(
    gpa: std.mem.Allocator,
    session: objc.Object,
    method: []const u8,
    url: []const u8,
    headers: []const [2][]const u8,
    body: ?[]const u8,
) !?Response {
    const pool = objc.Pool.push();
    defer pool.pop();
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse return null;
    const req = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{nsurl});
    objc.msg(void, req, "setHTTPMethod:", .{objc.nsString(method)});
    if (body) |b| {
        const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ b.ptr, @as(objc.NSUInteger, b.len) });
        objc.msg(void, req, "setHTTPBody:", .{d});
    }
    for (headers) |h| objc.msg(void, req, "setValue:forHTTPHeaderField:", .{ objc.nsString(h[1]), objc.nsString(h[0]) });

    var w: Wait = .{ .sem = objc.dispatch_semaphore_create(0) };
    defer objc.dispatch_release(@ptrCast(w.sem));
    var block = objc.Block(Wait, &.{ ?objc.Object, ?objc.Object, ?objc.Object }).init(&w, done);
    const task = objc.msg(objc.Object, session, "dataTaskWithRequest:completionHandler:", .{ req, &block });
    objc.msg(void, task, "resume", .{});
    _ = objc.dispatch_semaphore_wait(w.sem, objc.DISPATCH_TIME_FOREVER);
    defer if (w.data) |d| objc.release(d);
    defer if (w.response) |r| objc.release(r);

    if (w.failed) return null;
    const r = w.response orelse return null;
    const http = objc.msg(objc.BOOL, r, "isKindOfClass:", .{objc.class("NSHTTPURLResponse")});
    const code: i64 = if (http) objc.msg(objc.NSInteger, r, "statusCode", .{}) else 0;
    var out: []u8 = &.{};
    if (w.data) |d| {
        const len = objc.msg(objc.NSUInteger, d, "length", .{});
        out = try gpa.alloc(u8, len);
        if (len > 0) objc.msg(void, d, "getBytes:length:", .{ out.ptr, len });
    }
    return .{ .code = code, .body = out };
}

// MARK: streamed, on the main queue

/// A session whose answers arrive a piece at a time, each on the main queue
/// (`delegateQueue = [NSOperationQueue mainQueue]`), to a `KeaZigStream`
/// delegate that hands them to the task's `Events`.
pub const Config = struct {
    request_timeout: f64 = 60,
    resource_timeout: f64 = 300,
    /// AIClient's session: no cookies, cache or kept credentials, TLS 1.2 at
    /// least, and no redirect followed.
    strict: bool = false,
    /// No cookies, cache or kept credentials, redirects still followed
    /// (`strict` implies it).
    keeps_nothing: bool = false,
};

/// How a task ended, other than finishing: its NSError's code, and whether
/// that is an `NSURLErrorDomain` one.
pub const Failure = struct { url_error: bool, code: i64 };

/// `NSURLErrorCancelled`.
pub const cancelled: i64 = -999;

pub const Events = struct {
    ctx: *anyopaque,
    /// The answer's status: its HTTP status, 0 when it isn't HTTP.
    response: *const fn (*anyopaque, i64) void,
    /// The answer's `expectedContentLength` (−1 unknown), with `response`.
    length: ?*const fn (*anyopaque, i64) void = null,
    data: *const fn (*anyopaque, []const u8) void,
    /// Always last: null when it finished.
    done: *const fn (*anyopaque, ?Failure) void,
};

pub const Request = struct {
    method: []const u8 = "GET",
    url: []const u8,
    headers: []const [2][]const u8 = &.{},
    body: ?[]const u8 = null,
    /// `timeoutInterval`, when not the session's.
    timeout: ?f64 = null,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    obj: objc.Object,
    delegate: objc.Object,
    live: std.ArrayList(*Task) = .empty,
    strict: bool,

    pub fn create(gpa: std.mem.Allocator, config: Config) !*Session {
        const self = try gpa.create(Session);
        const pool = objc.Pool.push();
        defer pool.pop();
        const c = objc.msg(objc.Object, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
        objc.msg(void, c, "setTimeoutIntervalForRequest:", .{config.request_timeout});
        objc.msg(void, c, "setTimeoutIntervalForResource:", .{config.resource_timeout});
        if (config.strict or config.keeps_nothing) {
            const none: ?objc.Object = null;
            objc.msg(void, c, "setURLCache:", .{none});
            objc.msg(void, c, "setHTTPCookieStorage:", .{none});
            objc.msg(void, c, "setHTTPShouldSetCookies:", .{objc.NO});
            objc.msg(void, c, "setURLCredentialStorage:", .{none});
        }
        if (config.strict) {
            // NSURLRequestReloadIgnoringLocalAndRemoteCacheData
            objc.msg(void, c, "setRequestCachePolicy:", .{@as(objc.NSUInteger, 4)});
            // tls_protocol_version_TLSv12
            objc.msg(void, c, "setTLSMinimumSupportedProtocolVersion:", .{@as(u16, 0x0303)});
        }
        const d = objc.msg(objc.Object, streamClass(), "new", .{});
        objc.setZig(d, self);
        const queue = objc.msg(objc.Object, objc.class("NSOperationQueue"), "mainQueue", .{});
        const s = objc.retain(objc.msg(objc.Object, objc.class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:", .{ c, d, queue }));
        self.* = .{ .gpa = gpa, .obj = s, .delegate = d, .strict = config.strict };
        return self;
    }

    /// Every task let go without another word to its events.
    pub fn destroy(self: *Session) void {
        objc.setZig(self.delegate, null);
        objc.msg(void, self.obj, "invalidateAndCancel", .{});
        for (self.live.items) |t| {
            objc.release(t.obj);
            self.gpa.destroy(t);
        }
        self.live.deinit(self.gpa);
        objc.release(self.obj);
        objc.release(self.delegate);
        self.gpa.destroy(self);
    }

    /// Under way, or null when the address isn't one. Main thread.
    pub fn start(self: *Session, r: Request, events: Events) ?*Task {
        const pool = objc.Pool.push();
        defer pool.pop();
        const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(r.url)}) orelse return null;
        const req = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:", .{nsurl});
        objc.msg(void, req, "setHTTPMethod:", .{objc.nsString(r.method)});
        if (r.timeout) |t| objc.msg(void, req, "setTimeoutInterval:", .{t});
        if (r.body) |b| {
            const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ b.ptr, @as(objc.NSUInteger, b.len) });
            objc.msg(void, req, "setHTTPBody:", .{d});
        }
        for (r.headers) |h| objc.msg(void, req, "setValue:forHTTPHeaderField:", .{ objc.nsString(h[1]), objc.nsString(h[0]) });
        const task = self.gpa.create(Task) catch return null;
        self.live.append(self.gpa, task) catch {
            self.gpa.destroy(task);
            return null;
        };
        const obj = objc.retain(objc.msg(objc.Object, self.obj, "dataTaskWithRequest:", .{req}));
        task.* = .{ .obj = obj, .events = events };
        objc.msg(void, obj, "resume", .{});
        return task;
    }

    fn find(self: *Session, obj: objc.Object) ?usize {
        for (self.live.items, 0..) |t, i| if (t.obj == obj) return i;
        return null;
    }
};

pub const Task = struct {
    obj: objc.Object,
    /// Null once cancelled: nothing more is said.
    events: ?Events,

    /// Stopped; its events hear nothing more. The task itself is let go
    /// when the session says it ended.
    pub fn cancel(self: *Task) void {
        self.events = null;
        objc.msg(void, self.obj, "cancel", .{});
    }
};

fn streamClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigStream",
        .protocols = &.{ "NSURLSessionDataDelegate", "NSURLSessionTaskDelegate" },
        .methods = &.{
            .{ .name = "URLSession:dataTask:didReceiveResponse:completionHandler:", .imp = &received, .types = "v@:@@@@?" },
            .{ .name = "URLSession:dataTask:didReceiveData:", .imp = &arrived, .types = "v@:@@@" },
            .{ .name = "URLSession:task:didCompleteWithError:", .imp = &completed, .types = "v@:@@@" },
            .{ .name = "URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:", .imp = &redirected, .types = "v@:@@@@@?" },
        },
    });
}

/// A block's own function: `invoke(block, arg)`.
fn callBlock(comptime Arg: type, block: *anyopaque, arg: Arg) void {
    const raw: [*]const *const anyopaque = @ptrCast(@alignCast(block));
    const invoke: *const fn (*anyopaque, Arg) callconv(.c) void = @ptrCast(@alignCast(raw[2]));
    invoke(block, arg);
}

fn taskFor(delegate: objc.Object, obj: objc.Object) ?*Task {
    const s = objc.getZig(Session, delegate) orelse return null;
    const i = s.find(obj) orelse return null;
    return s.live.items[i];
}

fn received(self: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object, response: objc.Object, completion: *anyopaque) callconv(.c) void {
    if (taskFor(self, task)) |t| if (t.events) |e| {
        const http = objc.msg(objc.BOOL, response, "isKindOfClass:", .{objc.class("NSHTTPURLResponse")});
        e.response(e.ctx, if (http) objc.msg(objc.NSInteger, response, "statusCode", .{}) else 0);
        // The response handler may have cancelled it.
        if (t.events) |still| if (still.length) |f| f(still.ctx, objc.msg(i64, response, "expectedContentLength", .{}));
    };
    // NSURLSessionResponseAllow
    callBlock(objc.NSInteger, completion, 1);
}

fn arrived(self: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object, data: objc.Object) callconv(.c) void {
    const t = taskFor(self, task) orelse return;
    const e = t.events orelse return;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    if (len == 0) return;
    const bytes = objc.msg([*]const u8, data, "bytes", .{});
    e.data(e.ctx, bytes[0..len]);
}

fn completed(self: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object, err: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Session, self) orelse return;
    const i = s.find(task) orelse return;
    const t = s.live.swapRemove(i);
    defer {
        objc.release(t.obj);
        s.gpa.destroy(t);
    }
    const e = t.events orelse return;
    const failure: ?Failure = if (err) |x| .{
        .url_error = std.mem.eql(u8, objc.fromNSString(objc.msg(?objc.Object, x, "domain", .{})), "NSURLErrorDomain"),
        .code = objc.msg(objc.NSInteger, x, "code", .{}),
    } else null;
    e.done(e.ctx, failure);
}

fn redirected(self: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, _: objc.Object, request: objc.Object, completion: *anyopaque) callconv(.c) void {
    const strict = if (objc.getZig(Session, self)) |s| s.strict else true;
    callBlock(?objc.Object, completion, if (strict) null else request);
}

test "urlsession compiles" {
    std.testing.refAllDecls(@This());
}
