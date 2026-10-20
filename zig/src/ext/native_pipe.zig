//! `HostPipe` (ExtensionNative.swift 156-245): one native messaging host
//! program and the framing Chrome uses to talk to it — each message a
//! four-byte little-endian length and UTF-8 JSON, over its stdin and
//! stdout. Read and reaped on the main thread (`fdwatch`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const fdwatch = nanoui.fdwatch;

const Actions = ?*anyopaque;
const Attr = ?*anyopaque;
extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: *const Actions, attr: *const Attr, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *Actions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *Actions) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *Actions, fd: c_int, to: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addopen(a: *Actions, fd: c_int, path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn posix_spawnattr_init(a: *Attr) c_int;
extern "c" fn posix_spawnattr_destroy(a: *Attr) c_int;
extern "c" fn posix_spawnattr_setflags(a: *Attr, flags: c_short) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn __error() *c_int;
extern "c" var environ: [*:null]const ?[*:0]const u8;

/// Only the descriptors handed over survive into the host.
const POSIX_SPAWN_CLOEXEC_DEFAULT: c_short = 0x4000;
const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK = 0x4;
const O_WRONLY = 0x1;
const F_SETNOSIGPIPE = 73;
const SIGTERM = 15;
const SIGKILL = 9;
const F_SETFD = 2;
const FD_CLOEXEC = 1;
const WNOHANG = 1;
const EINTR = 4;
const EAGAIN = 35;

/// NSJSONReadingFragmentsAllowed / NSJSONWritingFragmentsAllowed.
const fragments: objc.NSUInteger = 4;
/// Chrome's limit on a message to a host.
pub const most = 1 << 20;

/// A message as one frame on `gpa`: its length, then its JSON.
pub fn frame(gpa: std.mem.Allocator, body: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, 4 + body.len);
    std.mem.writeInt(u32, out[0..4], @intCast(body.len), .little);
    @memcpy(out[4..], body);
    return out;
}

/// A Foundation object as JSON text (fragments allowed), autoreleased
/// bytes; null when JSON can't say it.
pub fn encode(message: objc.Object) ?[]const u8 {
    const cls = objc.class("NSJSONSerialization");
    const wrapped = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{message});
    if (!objc.msg(objc.BOOL, cls, "isValidJSONObject:", .{wrapped})) return null;
    const d = objc.msg(?objc.Object, cls, "dataWithJSONObject:options:error:", .{ message, fragments, @as(?*anyopaque, null) }) orelse return null;
    return @import("value.zig").bytes(d);
}

/// What has come from the host, cut into frames as they complete.
pub const Frames = struct {
    buffer: std.ArrayList(u8) = .empty,
    start: usize = 0,

    pub fn deinit(self: *Frames, gpa: std.mem.Allocator) void {
        self.buffer.deinit(gpa);
    }

    pub fn push(self: *Frames, gpa: std.mem.Allocator, chunk: []const u8) !void {
        if (self.start > 0) {
            const rest = self.buffer.items[self.start..];
            std.mem.copyForwards(u8, self.buffer.items[0..rest.len], rest);
            self.buffer.shrinkRetainingCapacity(rest.len);
            self.start = 0;
        }
        try self.buffer.appendSlice(gpa, chunk);
    }

    /// The next whole message's JSON, valid until the next `push`.
    pub fn next(self: *Frames) ?[]const u8 {
        const rest = self.buffer.items[self.start..];
        if (rest.len < 4) return null;
        const len = std.mem.readInt(u32, rest[0..4], .little);
        if (rest.len - 4 < len) return null;
        self.start += 4 + len;
        return rest[4 .. 4 + len];
    }
};

pub const HostPipe = struct {
    gpa: std.mem.Allocator,
    pid: c_int,
    /// The host's stdin (ours to write) and stdout (ours to read).
    input: c_int,
    output: c_int,
    reading: ?fdwatch.Watch = null,
    exit: ?fdwatch.Watch = null,
    frames: Frames = .{},
    exited: bool = false,
    finished: bool = false,
    /// Who hears it: each message (autoreleased, main thread), and its
    /// end (once: end of output or the process gone). After `on_exit` the
    /// pipe frees itself once the process has gone.
    owner: *anyopaque,
    on_message: *const fn (owner: *anyopaque, message: objc.Object) void,
    on_exit: *const fn (owner: *anyopaque) void,
    /// The process itself gone, after `on_exit`, just before the pipe is
    /// let go: a host may close its output and run on.
    on_gone: ?*const fn (owner: *anyopaque) void = null,

    /// Runs `program` with `origin` as its one argument.
    pub fn start(gpa: std.mem.Allocator, program: []const u8, origin: []const u8, owner: *anyopaque, on_message: *const fn (*anyopaque, objc.Object) void, on_exit: *const fn (*anyopaque) void) !*HostPipe {
        const path = try gpa.dupeSentinel(u8, program, 0);
        defer gpa.free(path);
        const arg = try gpa.dupeSentinel(u8, origin, 0);
        defer gpa.free(arg);
        var in: [2]c_int = undefined;
        var out: [2]c_int = undefined;
        if (pipe(&in) != 0) return error.CannotStart;
        if (pipe(&out) != 0) {
            _ = close(in[0]);
            _ = close(in[1]);
            return error.CannotStart;
        }
        var actions: Actions = null;
        var attr: Attr = null;
        _ = posix_spawn_file_actions_init(&actions);
        defer _ = posix_spawn_file_actions_destroy(&actions);
        _ = posix_spawnattr_init(&attr);
        defer _ = posix_spawnattr_destroy(&attr);
        _ = posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
        _ = posix_spawn_file_actions_adddup2(&actions, in[0], 0);
        _ = posix_spawn_file_actions_adddup2(&actions, out[1], 1);
        _ = posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
        const argv = [_:null]?[*:0]const u8{ path, arg };
        var pid: c_int = 0;
        const failed = posix_spawn(&pid, path, &actions, &attr, &argv, environ) != 0;
        _ = close(in[0]);
        _ = close(out[1]);
        if (failed) {
            _ = close(in[1]);
            _ = close(out[0]);
            return error.CannotStart;
        }
        // A host already gone would take the browser with it: writing to
        // its closed pipe raises SIGPIPE. Refused, the write only fails.
        _ = fcntl(in[1], F_SETNOSIGPIPE, @as(c_int, 1));
        _ = fcntl(out[0], F_SETFL, fcntl(out[0], F_GETFL) | O_NONBLOCK);
        // Not handed on to anything else this app runs: a stray copy of a
        // host's stdin would keep it from ever seeing the end.
        _ = fcntl(in[1], F_SETFD, @as(c_int, FD_CLOEXEC));
        _ = fcntl(out[0], F_SETFD, @as(c_int, FD_CLOEXEC));
        const self = try gpa.create(HostPipe);
        self.* = .{ .gpa = gpa, .pid = pid, .input = in[1], .output = out[0], .owner = owner, .on_message = on_message, .on_exit = on_exit };
        self.reading = fdwatch.readable(out[0], self, readable) catch null;
        // Unwatched, it could never be reaped or let go: not started at all.
        self.exit = fdwatch.exited(pid, self, gone) catch {
            if (self.reading) |w| w.cancel();
            _ = kill(pid, SIGKILL);
            _ = waitpid(pid, null, 0);
            _ = close(in[1]);
            _ = close(out[0]);
            gpa.destroy(self);
            return error.CannotStart;
        };
        return self;
    }

    /// Reading stops, and a host still running is asked to end.
    pub fn stop(self: *HostPipe) void {
        if (self.reading) |w| w.cancel();
        self.reading = null;
        if (!self.exited) _ = kill(self.pid, SIGTERM);
    }

    pub fn send(self: *HostPipe, message: objc.Object) error{ TooLong, Exited, Unsaved }!void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const body = encode(message) orelse return error.Exited;
        if (body.len > most) return error.TooLong;
        const bytes = frame(self.gpa, body) catch return error.Exited;
        defer self.gpa.free(bytes);
        var done: usize = 0;
        while (done < bytes.len) {
            const n = write(self.input, bytes[done..].ptr, bytes.len - done);
            if (n < 0) {
                if (__error().* == EINTR) continue;
                return error.Unsaved;
            }
            done += @intCast(n);
        }
    }

    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        const self: *HostPipe = @ptrCast(@alignCast(ctx.?));
        self.drain();
    }

    /// Everything the pipe holds now, then end of output if it has come.
    fn drain(self: *HostPipe) void {
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = read(self.output, &buf, buf.len);
            if (n > 0) {
                self.take(buf[0..@intCast(n)]);
                if (self.reading == null) return;
                continue;
            }
            if (n < 0 and (__error().* == EAGAIN or __error().* == EINTR)) return;
            // End of output.
            if (self.reading) |w| w.cancel();
            self.reading = null;
            self.finish();
            return;
        }
    }

    fn take(self: *HostPipe, chunk: []const u8) void {
        self.frames.push(self.gpa, chunk) catch return;
        const pool = objc.Pool.push();
        defer pool.pop();
        while (self.frames.next()) |body| {
            const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ body.ptr, body.len });
            const message = objc.msg(?objc.Object, objc.class("NSJSONSerialization"), "JSONObjectWithData:options:error:", .{ d, fragments, @as(?*anyopaque, null) }) orelse continue;
            if (self.finished) return;
            self.on_message(self.owner, message);
            // Stopped by what it heard: nothing more is read.
            if (self.reading == null) return;
        }
    }

    fn finish(self: *HostPipe) void {
        if (self.finished) return;
        self.finished = true;
        self.on_exit(self.owner);
    }

    /// The process has gone: reaped, and the pipe let go.
    fn gone(ctx: ?*anyopaque) callconv(.c) void {
        const self: *HostPipe = @ptrCast(@alignCast(ctx.?));
        self.exited = true;
        _ = waitpid(self.pid, null, WNOHANG);
        // The exit may be heard before its last words: all it wrote is in
        // the pipe already, read before it is let go.
        if (self.reading != null) self.drain();
        if (self.reading) |w| w.cancel();
        self.reading = null;
        self.finish();
        if (self.exit) |w| w.cancel();
        _ = close(self.input);
        _ = close(self.output);
        self.frames.deinit(self.gpa);
        if (self.on_gone) |f| f(self.owner);
        self.gpa.destroy(self);
    }
};

test "native messaging frames round-trip" {
    const gpa = std.testing.allocator;
    const pool = objc.Pool.push();
    defer pool.pop();
    const value = @import("value.zig");
    const first = encode(value.fromText("{\"text\":\"héllo\",\"n\":[1,2]}").?).?;
    const a = try frame(gpa, first);
    defer gpa.free(a);
    const b = try frame(gpa, encode(objc.nsString("plain")).?);
    defer gpa.free(b);
    try std.testing.expectEqual(@as(u32, @intCast(first.len)), std.mem.readInt(u32, a[0..4], .little));
    const both = try std.mem.concat(gpa, u8, &.{ a, b });
    defer gpa.free(both);
    // Arriving a byte at a time, then in uneven pieces: the same two.
    for ([_]usize{ 1, 3, 7, both.len }) |step| {
        var frames: Frames = .{};
        defer frames.deinit(gpa);
        var got: std.ArrayList([]u8) = .empty;
        defer {
            for (got.items) |g| gpa.free(g);
            got.deinit(gpa);
        }
        var i: usize = 0;
        while (i < both.len) : (i += step) {
            try frames.push(gpa, both[i..@min(both.len, i + step)]);
            while (frames.next()) |body| try got.append(gpa, try gpa.dupe(u8, body));
        }
        try std.testing.expectEqual(@as(usize, 2), got.items.len);
        const back = value.toJson(gpa, value.fromText(got.items[0]).?).?;
        defer back.deinit();
        try std.testing.expectEqualStrings("héllo", back.value.object.get("text").?.string);
        try std.testing.expectEqual(@as(i64, 2), back.value.object.get("n").?.array.items[1].integer);
        try std.testing.expectEqualStrings("\"plain\"", got.items[1]);
    }
}

extern "c" fn usleep(us: c_uint) c_int;

test "a write to a host that has gone fails as unsaved, not a signal" {
    const Quiet = struct {
        fn heard(_: *anyopaque, _: objc.Object) void {}
        fn ended(_: *anyopaque) void {}
    };
    var owner: u8 = 0;
    // Its exit is heard on the main queue, which no one runs here: the
    // pipe stays put (and is left behind, on c_allocator).
    const p = try HostPipe.start(std.heap.c_allocator, "/usr/bin/true", "chrome-extension://x/", &owner, Quiet.heard, Quiet.ended);
    _ = usleep(300_000);
    const pool = objc.Pool.push();
    defer pool.pop();
    try std.testing.expectError(error.Unsaved, p.send(objc.nsString("hi")));
    p.stop();
}
