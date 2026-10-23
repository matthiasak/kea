//! nui: nanoui's command, for people and for coding agents. It never asks
//! anything and never opens a window on its own (`run` aside): `start`
//! makes an app that builds, `snapshot` renders one to a PNG, and every
//! command takes `--json` for output a program reads.
const std = @import("std");
const builtin = @import("builtin");
const version = @import("build_options").version;

const usage =
    \\nui: make and check nanoui apps
    \\
    \\  nui start NAME [--dir PATH] [--nanoui REF | --local PATH] [--no-build]
    \\                         a new app that builds (also: new, init)
    \\  nui build [ARGS…]      compile (zig build ARGS)
    \\  nui test [ARGS…]       the tests: views rendered offscreen
    \\  nui snapshot [--out PNG] [--script STEPS] [--dark] [--wait SECONDS]
    \\                         build, then render the app to a PNG; no window
    \\  nui run [ARGS…]        open the app's window (for people, not agents)
    \\  nui doctor             check Zig and the platform
    \\  nui version
    \\
    \\  --json                 output a program can read
    \\
    \\Script steps: click:TEXT, type:TEXT, key:enter, wait:SECONDS, live:SECONDS, ";" between.
    \\
;

/// Human lines, or one JSON object at the end.
pub const Out = struct {
    json: bool,
    stdout: *std.Io.Writer,
    failed: bool = false,

    pub fn step(o: *Out, comptime fmt: []const u8, args: anytype) void {
        if (o.json) return;
        o.stdout.print("  " ++ fmt ++ "\n", args) catch {};
        o.stdout.flush() catch {};
    }

    /// An error and what to do about it; the command exits 1.
    pub fn fail(o: *Out, comptime fmt: []const u8, args: anytype, fix: ?[]const u8) void {
        o.failed = true;
        if (o.json) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
            o.stdout.print("{f}\n", .{std.json.fmt(.{ .ok = false, .@"error" = msg, .fix = fix }, .{})}) catch {};
        } else {
            o.stdout.print("error: " ++ fmt ++ "\n", args) catch {};
            if (fix) |f| o.stdout.print("fix: {s}\n", .{f}) catch {};
        }
        o.stdout.flush() catch {};
    }

    /// What was done, and the commands to run next.
    pub fn done(o: *Out, what: anytype, next: []const []const u8) void {
        if (o.json) {
            o.stdout.print("{f}\n", .{std.json.fmt(.{ .ok = true, .result = what, .next = next }, .{})}) catch {};
        } else if (next.len > 0) {
            o.stdout.print("\nnext:\n", .{}) catch {};
            for (next) |n| o.stdout.print("  {s}\n", .{n}) catch {};
        }
        o.stdout.flush() catch {};
    }
};

/// How much of zig's output shows: all, its errors only, none.
pub const Show = enum { shown, quiet, silent };

/// Runs `zig ARGS` in `cwd`. True if it worked.
pub fn zig(a: std.mem.Allocator, io: std.Io, args: []const []const u8, cwd: ?[]const u8, show: Show) !bool {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{"zig"}, args });
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
        .stdin = .ignore,
        .stdout = if (show == .shown) .inherit else .ignore,
        .stderr = if (show == .silent) .ignore else .inherit,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const all = try init.minimal.args.toSlice(a);
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    var out: Out = .{ .json = false, .stdout = &w.interface };
    // --json anywhere; the rest in order.
    var args: std.ArrayList([]const u8) = .empty;
    for (all[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) out.json = true else try args.append(a, arg);
    }
    if (args.items.len == 0 or eq(args.items[0], "help") or eq(args.items[0], "--help") or eq(args.items[0], "-h")) {
        try w.interface.writeAll(usage);
        try w.interface.flush();
        return 0;
    }
    const cmd = args.items[0];
    const rest = args.items[1..];
    if (eq(cmd, "start") or eq(cmd, "new") or eq(cmd, "init")) {
        try start(a, io, &out, rest);
    } else if (eq(cmd, "build") or eq(cmd, "test") or eq(cmd, "run")) {
        const zig_args = try std.mem.concat(a, []const u8, &.{ if (eq(cmd, "build")) &.{} else &.{cmd}, if (eq(cmd, "run") and rest.len > 0) &.{"--"} else &.{}, rest });
        if (!try zig(a, io, if (zig_args.len == 0) &.{"build"} else try std.mem.concat(a, []const u8, &.{ &.{"build"}, zig_args }), null, if (out.json) .quiet else .shown)) {
            out.fail("zig build {s} failed", .{if (eq(cmd, "build")) "" else cmd}, "the errors are above");
        } else out.done(.{ .command = cmd }, &.{});
    } else if (eq(cmd, "snapshot")) {
        try @import("snapshot.zig").run(a, io, &out, rest);
    } else if (eq(cmd, "doctor")) {
        try @import("doctor.zig").run(a, io, &out);
    } else if (eq(cmd, "version") or eq(cmd, "--version")) {
        if (out.json) out.done(.{ .nui = version }, &.{}) else {
            try w.interface.print("nui {s} (nanoui {s})\n", .{ version, version });
            try w.interface.flush();
        }
    } else {
        out.fail("no command {s}", .{cmd}, "nui help");
    }
    return if (out.failed) 1 else 0;
}

fn start(a: std.mem.Allocator, io: std.Io, out: *Out, rest: []const []const u8) !void {
    var o: @import("start.zig").Options = .{ .name = "", .ref = "v" ++ version };
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (eq(arg, "--no-build")) {
            o.build = false;
        } else if (eq(arg, "--dir") or eq(arg, "--nanoui") or eq(arg, "--local")) {
            i += 1;
            if (i >= rest.len) return out.fail("{s} needs a value", .{arg}, "nui help");
            if (eq(arg, "--dir")) o.dir = rest[i] else if (eq(arg, "--nanoui")) o.ref = rest[i] else o.local = rest[i];
        } else if (o.name.len == 0 and arg.len > 0 and arg[0] != '-') {
            o.name = arg;
        } else return out.fail("what is {s}?", .{arg}, "nui start NAME [--dir PATH] [--nanoui REF | --local PATH] [--no-build]");
    }
    if (o.name.len == 0) return out.fail("start needs a name", .{}, "nui start my-app");
    try @import("start.zig").run(a, io, out, o);
}

pub fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

test {
    _ = @import("start.zig");
    _ = @import("snapshot.zig");
}
