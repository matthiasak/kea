//! `zig build e2e`: real WebKit, in process. Each case gets its own hidden
//! `Kea` (fresh temp root, defaults suite, the `kea-test` scheme) and its
//! windows never reach the screen. Prints `ok   <name>` or
//! `FAIL <name>: <reason>`, and exits 1 on any failure.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const scheme = @import("scheme.zig");

pub const Case = struct {
    name: []const u8,
    run: *const fn (*Harness) anyerror!void,
};

const cases = @import("smoke.zig").cases ++ @import("windows.zig").cases;

pub const Harness = struct {
    gpa: std.mem.Allocator,
    temp: app.Temp,
    handler: objc.Object,
    /// `http://127.0.0.1:<port>`, the loopback listener.
    http: []const u8,
    kea: ?*app.Kea = null,
    reason_buf: [512]u8 = undefined,
    reason: []const u8 = "",

    /// Opens the case's KeaZig: one hidden window with one browser.
    pub fn start(h: *Harness) !*app.Browser {
        const k = try app.Kea.create(h.gpa, ui_app, .{
            .root = h.temp.root,
            .suite = h.temp.suite,
            .hidden = true,
            .scheme_handler = h.handler,
        });
        h.kea = k;
        const b = try k.newBrowser();
        h.frame();
        return b;
    }

    /// Ends the case's KeaZig as quitting does: windows close, stores flush.
    pub fn quit(h: *Harness) void {
        if (h.kea) |k| k.destroy();
        h.kea = null;
    }

    pub fn browser(h: *Harness) *app.Browser {
        return h.kea.?.browsers.items[0];
    }

    /// Lays out and places the webviews now (hidden windows draw no frames).
    pub fn frame(h: *Harness) void {
        const k = h.kea orelse return;
        for (k.browsers.items) |b| if (b.window) |w| if (w.surface) |s| s.frame();
    }

    /// Runs the event loop in 0.05 s slices until `cond(ctx)` holds.
    pub fn waitFor(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool, timeout_s: f64, what: []const u8) !void {
        const deadline = ui.clock.now() + timeout_s;
        while (!cond(ctx)) {
            if (ui.clock.now() > deadline) return h.fail("timed out after {d:.1} s waiting for {s}", .{ timeout_s, what });
            h.pump(0.05);
        }
    }

    pub fn pump(h: *Harness, seconds: f64) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        nanoui.runFor(seconds);
        h.frame();
    }

    pub fn fail(h: *Harness, comptime fmt: []const u8, args: anytype) error{CaseFailed} {
        h.reason = std.fmt.bufPrint(&h.reason_buf, fmt, args) catch fmt;
        return error.CaseFailed;
    }

    pub fn expect(h: *Harness, ok: bool, comptime fmt: []const u8, args: anytype) !void {
        if (!ok) return h.fail(fmt, args);
    }

    /// Sends a key equivalent to the window's view, as AppKit would on a
    /// key press (`key` is the character, `code` its virtual key code).
    pub fn press(h: *Harness, key: []const u8, code: u16, cmd: bool, ctrl: bool) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const w = h.browser().window orelse return;
        const s = w.surface orelse return;
        var flags: objc.NSUInteger = 0;
        if (cmd) flags |= 1 << 20;
        if (ctrl) flags |= 1 << 18;
        const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
            @as(objc.NSUInteger, 10), objc.CGPoint{}, flags, @as(f64, 0),
            objc.msg(objc.NSInteger, w.nswindow, "windowNumber", .{}), @as(?objc.Object, null),
            objc.nsString(key), objc.nsString(key), objc.NO, code,
        }) orelse return;
        _ = objc.msg(objc.BOOL, s.nsview, "performKeyEquivalent:", .{ev});
    }

    /// The contents of `name` in the case's root, or null.
    pub fn readFile(h: *Harness, name: []const u8) ?[]u8 {
        const p = h.temp.path(h.gpa, name) catch return null;
        defer h.gpa.free(p);
        return app.disk.read(h.gpa, p);
    }
};

var ui_app: *nanoui.App = undefined;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    ui_app = try nanoui.App.create(init, .{ .name = app.kea.app_name, .quit_on_last_window_closed = false });
    defer ui_app.destroy();
    _ = objc.msg(objc.BOOL, ui_app.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 2)});
    objc.msg(void, ui_app.nsapp, "finishLaunching", .{});

    const handler = scheme.handler();
    defer objc.release(handler);
    const port = try scheme.listen();
    var http_buf: [64]u8 = undefined;
    const http = try std.fmt.bufPrint(&http_buf, "http://127.0.0.1:{d}", .{port});

    var failed: usize = 0;
    for (cases) |case| {
        const pool = objc.Pool.push();
        defer pool.pop();
        var h: Harness = .{ .gpa = gpa, .temp = try app.Temp.init(gpa), .handler = handler, .http = http };
        const result = case.run(&h);
        h.quit();
        h.temp.deinit(gpa);
        if (result) |_| {
            std.debug.print("ok   {s}\n", .{case.name});
        } else |err| {
            failed += 1;
            const why = if (err == error.CaseFailed) h.reason else @errorName(err);
            std.debug.print("FAIL {s}: {s}\n", .{ case.name, why });
        }
    }
    if (failed > 0) {
        std.debug.print("{d} of {d} e2e cases failed\n", .{ failed, cases.len });
        std.process.exit(1);
    }
}
