//! `zig build snapshots`: renders named chrome states to PNG files named
//! `<phase>-<state>-<light|dark>.png` in `$KEAZIG_SNAPSHOTS`
//! (default `$TMPDIR/keazig-snapshots`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Fixture = @import("ui/fixture.zig").Fixture;
const Options = @import("ui/fixture.zig").Options;

const State = struct {
    name: []const u8,
    opts: Options,
};

const states = [_]State{
    .{ .name = "p0-default", .opts = .{} },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const dir = if (init.environ_map.get("KEAZIG_SNAPSHOTS")) |d| try gpa.dupe(u8, d) else blk: {
        const tmp = std.mem.trimEnd(u8, init.environ_map.get("TMPDIR") orelse "/tmp", "/");
        break :blk try std.fmt.allocPrint(gpa, "{s}/keazig-snapshots", .{tmp});
    };
    defer gpa.free(dir);
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        _ = objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
            objc.nsString(dir), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
        });
    }
    for (states) |s| {
        for ([_]bool{ false, true }) |dark| {
            var opts = s.opts;
            opts.dark = dark;
            var f: Fixture = undefined;
            try f.init(gpa, opts);
            defer f.deinit();
            f.tester.settle(2);
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ dir, s.name, if (dark) "dark" else "light" });
            defer gpa.free(path);
            try f.tester.screenshot(path);
            std.debug.print("snapshot {s}\n", .{path});
        }
    }
}
