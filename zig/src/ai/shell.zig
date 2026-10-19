//! What a command prints, run by the user's login shell (`AIKeys.shell`):
//! the last line of output, if it looks like a key. Ten seconds, then it is
//! killed. Whichever comes first, the output or the ten seconds, answers; a
//! grandchild holding the pipe open can't keep the caller waiting.
// ponytail: last stdout line is the key; an rc file that prints after it breaks this — use a command that prints only the key
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const dispatch = @import("../sys/dispatch.zig");
const Then = @import("keys.zig").Then;

extern "c" fn dispatch_after_f(when: u64, queue: dispatch.Queue, context: ?*anyopaque, work: dispatch.Work) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn getuid() u32;
const Passwd = extern struct { name: ?[*:0]u8, passwd: ?[*:0]u8, uid: u32, gid: u32, change: isize, class: ?[*:0]u8, gecos: ?[*:0]u8, dir: ?[*:0]u8, shell: ?[*:0]u8, expire: isize };
extern "c" fn getpwuid(uid: u32) ?*Passwd;

const Job = struct {
    gpa: std.mem.Allocator,
    /// The receiver's: the key is handed over on it.
    out: std.mem.Allocator,
    command: []u8,
    ctx: *anyopaque,
    then: Then,
    answered: std.atomic.Value(bool) = .init(false),
    /// The reader and the timer each hold one.
    refs: std.atomic.Value(u8) = .init(2),
    task: ?objc.Object = null,

    fn unref(j: *Job) void {
        if (j.refs.fetchSub(1, .acq_rel) != 1) return;
        if (j.task) |t| objc.release(t);
        j.gpa.free(j.command);
        j.gpa.destroy(j);
    }

    /// The first answer goes to the main thread; a later one is dropped.
    fn answer(j: *Job, value: ?[]u8) void {
        if (j.answered.swap(true, .acq_rel)) {
            if (value) |v| j.gpa.free(v);
            return;
        }
        const d = j.gpa.create(Delivery) catch {
            if (value) |v| j.gpa.free(v);
            return;
        };
        d.* = .{ .out = j.out, .ctx = j.ctx, .then = j.then, .value = value };
        objc.dispatchMain(d, Delivery.run);
    }
};

const Delivery = struct {
    out: std.mem.Allocator,
    ctx: *anyopaque,
    then: Then,
    value: ?[]u8,

    fn run(raw: ?*anyopaque) callconv(.c) void {
        const d: *Delivery = @ptrCast(@alignCast(raw.?));
        const ctx = d.ctx;
        const then = d.then;
        const key: ?[]u8 = if (d.value) |v| blk: {
            defer std.heap.c_allocator.free(v);
            break :blk d.out.dupe(u8, v) catch null;
        } else null;
        std.heap.c_allocator.destroy(d);
        then(ctx, key);
    }
};

/// `command` run in the background; `then(ctx, key)` on the main thread,
/// the key on `gpa` (the receiver frees it), or null.
pub fn run(gpa: std.mem.Allocator, command: []const u8, ctx: *anyopaque, then: Then) void {
    // The job crosses threads: the C allocator, which is thread-safe.
    const a = std.heap.c_allocator;
    const j = a.create(Job) catch return then(ctx, null);
    j.* = .{ .gpa = a, .out = gpa, .command = a.dupe(u8, command) catch {
        a.destroy(j);
        return then(ctx, null);
    }, .ctx = ctx, .then = then };
    dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), j, read);
}

fn read(raw: ?*anyopaque) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(raw.?));
    const pool = objc.Pool.push();
    defer pool.pop();
    const shell: []const u8 = if (getpwuid(getuid())) |pw| if (pw.shell) |s| std.mem.span(s) else "/bin/zsh" else "/bin/zsh";
    const task = objc.msg(objc.Object, objc.class("NSTask"), "new", .{});
    j.task = task;
    objc.msg(void, task, "setExecutableURL:", .{objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(shell)})});
    const args = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for ([_][]const u8{ "-l", "-i", "-c", j.command }) |s| objc.msg(void, args, "addObject:", .{objc.nsString(s)});
    objc.msg(void, task, "setArguments:", .{args});
    const out = objc.msg(objc.Object, objc.class("NSPipe"), "pipe", .{});
    const nothing = objc.msg(objc.Object, objc.class("NSFileHandle"), "fileHandleWithNullDevice", .{});
    objc.msg(void, task, "setStandardOutput:", .{out});
    objc.msg(void, task, "setStandardInput:", .{nothing});
    objc.msg(void, task, "setStandardError:", .{nothing});
    if (!objc.msg(objc.BOOL, task, "launchAndReturnError:", .{@as(?*anyopaque, null)})) {
        j.answer(null);
        j.unref();
        return j.unref();
    }
    const background = dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0);
    dispatch_after_f(dispatch_time(0, 10 * std.time.ns_per_s), background, j, timedOut);
    const handle = objc.msg(objc.Object, out, "fileHandleForReading", .{});
    const data = objc.msg(objc.Object, handle, "readDataToEndOfFile", .{});
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const bytes: []const u8 = if (len == 0) "" else objc.msg([*]const u8, data, "bytes", .{})[0..len];
    j.answer(lastKey(j.gpa, bytes));
    j.unref();
}

fn timedOut(raw: ?*anyopaque) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(raw.?));
    j.answer(null);
    const task = j.task orelse return j.unref();
    if (!objc.msg(objc.BOOL, task, "isRunning", .{})) return j.unref();
    objc.msg(void, task, "terminate", .{});
    // An interactive shell ignores the first; the timer's hold passes to the kill.
    const background = dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0);
    dispatch_after_f(dispatch_time(0, std.time.ns_per_s), background, j, killed);
}

fn killed(raw: ?*anyopaque) callconv(.c) void {
    const j: *Job = @ptrCast(@alignCast(raw.?));
    defer j.unref();
    const task = j.task orelse return;
    if (objc.msg(objc.BOOL, task, "isRunning", .{})) {
        const pid = objc.msg(c_int, task, "processIdentifier", .{});
        _ = std.c.kill(pid, std.c.SIG.KILL);
    }
}

/// The last line that isn't blank, trimmed, when it has at most 400
/// characters and no whitespace; on `a`.
pub fn lastKey(a: std.mem.Allocator, output: []const u8) ?[]u8 {
    var last: ?[]const u8 = null;
    var lines = std.mem.tokenizeAny(u8, output, "\n\r\x0b\x0c");
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (t.len > 0) last = t;
    }
    const found = last orelse return null;
    if ((std.unicode.utf8CountCodepoints(found) catch return null) > 400) return null;
    if (std.mem.indexOfAny(u8, found, " \t") != null) return null;
    return a.dupe(u8, found) catch null;
}

test "the last line that looks like a key" {
    const gpa = std.testing.allocator;
    const k = lastKey(gpa, "Welcome!\n  sk-abc123  \n\n").?;
    defer gpa.free(k);
    try std.testing.expectEqualStrings("sk-abc123", k);
    try std.testing.expect(lastKey(gpa, "two words\n") == null);
    try std.testing.expect(lastKey(gpa, "\n\n") == null);
}
