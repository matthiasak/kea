//! `nui snapshot`: builds the app, then runs it with `--nanoui-snapshot`,
//! which renders its first window offscreen to a PNG and exits; no window
//! shows. Steps (`--script`) run first, as ui.Tester runs them.
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("main.zig");
const start = @import("start.zig");

/// The folder holding build.zig.zon, from `from` up.
pub fn projectRoot(a: std.mem.Allocator, io: std.Io, from: []const u8) !?[]const u8 {
    var dir: []const u8 = from;
    while (true) {
        const zon = try std.fs.path.join(a, &.{ dir, "build.zig.zon" });
        if (std.Io.Dir.cwd().access(io, zon, .{})) |_| return dir else |_| {}
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

pub fn run(a: std.mem.Allocator, io: std.Io, out: *cli.Out, rest: []const []const u8) !void {
    var png: ?[]const u8 = null;
    var flags: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (cli.eq(arg, "--dark")) {
            try flags.append(a, "--nanoui-dark");
        } else if (cli.eq(arg, "--out") or cli.eq(arg, "--script") or cli.eq(arg, "--wait")) {
            i += 1;
            if (i >= rest.len) return out.fail("{s} needs a value", .{arg}, "nui help");
            if (cli.eq(arg, "--out")) png = rest[i] else if (cli.eq(arg, "--script")) {
                try flags.append(a, try std.fmt.allocPrint(a, "--nanoui-script={s}", .{rest[i]}));
            } else try flags.append(a, try std.fmt.allocPrint(a, "--nanoui-wait={s}", .{rest[i]}));
        } else return out.fail("what is {s}?", .{arg}, "nui snapshot [--out PNG] [--script STEPS] [--dark] [--wait SECONDS]");
    }
    const here = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    const root = (try projectRoot(a, io, here)) orelse return out.fail("no build.zig.zon here or above", .{}, "run it in an app's folder (nui start NAME makes one)");
    const zon = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ root, "build.zig.zon" }), a, .limited(1 << 16));
    const name = start.zonName(zon) orelse return out.fail("build.zig.zon has no name", .{}, null);
    out.step("building {s}…", .{name});
    if (!try cli.zig(a, io, &.{"build"}, root, if (out.json) .quiet else .shown)) return out.fail("{s} doesn't build", .{name}, "the compiler's errors are above");
    const exe = try std.fs.path.join(a, &.{ root, "zig-out", "bin", if (builtin.os.tag == .windows) try std.fmt.allocPrint(a, "{s}.exe", .{name}) else name });
    const target = if (png) |p| (if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(a, &.{ here, p })) else try std.fs.path.join(a, &.{ root, "zig-out", "snapshot.png" });
    std.Io.Dir.cwd().deleteFile(io, target) catch {};
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ exe, try std.fmt.allocPrint(a, "--nanoui-snapshot={s}", .{target}) }, flags.items });
    const r = std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch
        return out.fail("couldn't run {s}", .{exe}, "does `nui build` make it?");
    if (!r.term.success()) {
        if (!out.json and r.stderr.len > 0) out.stdout.print("{s}\n", .{r.stderr}) catch {};
        return out.fail("{s} stopped before its picture was taken", .{name}, null);
    }
    std.Io.Dir.cwd().access(io, target, .{}) catch return out.fail("no picture at {s}", .{target}, "does the app open a native UI window? (pages can't be snapshot)");
    out.step("rendered {s}", .{target});
    out.done(.{ .png = target }, &.{});
}

test "the project's folder is found from inside it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const root = if (builtin.os.tag == .windows) "C:\\Windows\\Temp\\nui-test-root" else "/tmp/nui-test-root";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const deep = try std.fs.path.join(a, &.{ root, "src", "deep" });
    try std.Io.Dir.cwd().createDirPath(io, deep);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "build.zig.zon" }), .data = ".{}" });
    try std.testing.expectEqualStrings(root, (try projectRoot(a, io, deep)).?);
}
