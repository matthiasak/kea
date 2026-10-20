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

const cases = @import("smoke.zig").cases ++ @import("windows.zig").cases ++ @import("favicons.zig").cases ++ @import("web.zig").cases ++ @import("links.zig").cases ++ @import("downloads.zig").cases ++ @import("page_features.zig").cases ++ @import("page_b.zig").cases ++ @import("side_panels.zig").cases ++ @import("peek_switch.zig").cases ++ @import("split.zig").cases ++ @import("find_bar.zig").cases ++ @import("menus.zig").cases ++ @import("chat.zig").cases ++ @import("passwords.zig").cases ++ @import("extensions.zig").cases ++ @import("quality.zig").cases ++ @import("webkit_metrics.zig").cases;

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
        return h.startWith(.{});
    }

    pub fn startWith(h: *Harness, opts: struct { measuring: bool = false }) !*app.Browser {
        const k = try app.Kea.create(h.gpa, ui_app, .{
            .root = h.temp.root,
            .suite = h.temp.suite,
            .hidden = true,
            .scheme_handler = h.handler,
            .measuring = opts.measuring,
        });
        h.kea = k;
        // As if launched before: the Welcome isn't what a case is about.
        k.prefs.set("welcomed", true);
        const b = try k.newBrowser();
        // The menu bar and the key monitor, as the app installs them.
        app.menus.install(k);
        app.keys.install(k);
        h.frame();
        return b;
    }

    /// Opens the case's KeaZig on the fastest screen without stealing focus,
    /// recording frames on the window's surface.
    pub fn startOnscreen(h: *Harness) !*app.Browser {
        const k = try app.Kea.create(h.gpa, ui_app, .{
            .root = h.temp.root,
            .suite = h.temp.suite,
            .hidden = true,
            .scheme_handler = h.handler,
        });
        h.kea = k;
        _ = objc.msg(objc.BOOL, ui_app.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 1)});
        k.prefs.set("welcomed", true);
        const b = try k.newBrowser();
        app.menus.install(k);
        app.keys.install(k);
        k.opts.hidden = false;
        const w = b.window orelse return error.NoWindow;
        const s = w.surface orelse return error.NoSurface;
        objc.msg(void, w.nswindow, "setCollectionBehavior:", .{@as(objc.NSUInteger, (1 << 0) | (1 << 8))});
        objc.msg(void, w.nswindow, "setLevel:", .{@as(objc.NSInteger, 3)});
        placeOnFastestScreen(w.nswindow);
        objc.msg(void, w.nswindow, "orderFrontRegardless", .{});
        pumpWindowVisibility(w.nswindow, 0.3);
        _ = try s.recordFrames(h.gpa);
        s.frame();
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

    /// A key pressed in the case's window, as AppKit has it: through the
    /// app (`sendEvent:`), so the key monitor sees it first and the menu
    /// bar's key equivalents next. `key` is the character, `code` its
    /// virtual key code.
    pub fn press(h: *Harness, key: []const u8, code: u16, cmd: bool, ctrl: bool) void {
        var flags: objc.NSUInteger = 0;
        if (cmd) flags |= 1 << 20;
        if (ctrl) flags |= 1 << 18;
        h.send(10, key, code, flags);
    }

    /// An `NSEvent` of `kind` (10 key down, 12 flags changed) for the
    /// case's window, sent through the app.
    pub fn send(h: *Harness, kind: objc.NSUInteger, key: []const u8, code: u16, flags: objc.NSUInteger) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const w = h.browser().window orelse return;
        const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
            kind,                                                        objc.CGPoint{}, flags, ui.clock.now(),
            objc.msg(objc.NSInteger, w.nswindow, "windowNumber", .{}), @as(?objc.Object, null),
            objc.nsString(key), objc.nsString(key), objc.NO, code,
        }) orelse return;
        objc.msg(void, ui_app.nsapp, "sendEvent:", .{ev});
        // Handed to the page first: AppKit offers a key equivalent to the
        // key window, which a hidden one never is, so it is offered here.
        if (kind == 10 and app.keys.handedToPage(ev)) _ = objc.msg(objc.BOOL, w.nswindow, "performKeyEquivalent:", .{ev});
    }

    /// The contents of `name` in the case's root, or null.
    pub fn readFile(h: *Harness, name: []const u8) ?[]u8 {
        const p = h.temp.path(h.gpa, name) catch return null;
        defer h.gpa.free(p);
        return app.disk.read(h.gpa, p);
    }
};

fn pumpWindowVisibility(nswindow: objc.Object, max_s: f64) void {
    const deadline = ui.clock.now() + max_s;
    const mode = objc.nsString("kCFRunLoopDefaultMode");
    while (ui.clock.now() < deadline) {
        const pool = objc.Pool.push();
        defer pool.pop();
        const until = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, 0.01)});
        // NSEventMaskAppKitDefined (1 << 13): WindowServer visibility/occlusion updates only.
        while (objc.msg(?objc.Object, ui_app.nsapp, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
            @as(objc.NSUInteger, 1 << 13), until, mode, objc.YES,
        })) |ev| {
            objc.msg(void, ui_app.nsapp, "sendEvent:", .{ev});
        }
        nanoui.runFor(0.01);
        if (objc.msg(objc.NSUInteger, nswindow, "occlusionState", .{}) & 2 != 0) break;
    }
}

fn placeOnFastestScreen(nswindow: objc.Object) void {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const count = objc.msg(objc.NSUInteger, screens, "count", .{});
    if (count == 0) return;
    var best = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    var best_fps: objc.NSInteger = 0;
    for (0..count) |i| {
        const scr = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const fps: objc.NSInteger = if (objc.msg(objc.BOOL, scr, "respondsToSelector:", .{objc.sel("maximumFramesPerSecond")}))
            objc.msg(objc.NSInteger, scr, "maximumFramesPerSecond", .{})
        else
            60;
        if (fps > best_fps) {
            best_fps = fps;
            best = scr;
        }
    }
    const vis = objc.msg(objc.CGRect, best, "visibleFrame", .{});
    const w = @min(1440.0, vis.size.width);
    const h = @min(900.0, vis.size.height);
    const x = vis.origin.x + @floor((vis.size.width - w) * 0.5);
    const y = vis.origin.y + @floor((vis.size.height - h) * 0.5);
    objc.msg(void, nswindow, "setFrame:display:", .{
        objc.CGRect{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } },
        objc.YES,
    });
}

var ui_app: *nanoui.App = undefined;

/// Every allocation (and growing remap) the cases make on `gpa`, from any
/// thread: the idle case asks that a frame make none.
pub var allocations: usize = 0;

const Counting = struct {
    child: std.mem.Allocator,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn count() void {
        _ = @atomicRmw(usize, &allocations, .Add, 1, .monotonic);
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        count();
        return @as(*Counting, @ptrCast(@alignCast(ctx))).child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        if (n > m.len) count();
        return @as(*Counting, @ptrCast(@alignCast(ctx))).child.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        if (n > m.len) count();
        return @as(*Counting, @ptrCast(@alignCast(ctx))).child.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        @as(*Counting, @ptrCast(@alignCast(ctx))).child.rawFree(m, a, ra);
    }
};

pub fn main(init: std.process.Init) !void {
    var onscreen = false;
    for (try init.minimal.args.toSlice(init.arena.allocator())) |arg| {
        if (std.mem.eql(u8, arg, "--onscreen")) onscreen = true;
    }
    // Cases get their own allocator so a leak fails the run, not just prints.
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    var counting: Counting = .{ .child = if (onscreen) std.heap.smp_allocator else dbg.allocator() };
    const gpa = counting.allocator();
    ui_app = try nanoui.App.create(init, .{ .name = app.kea.app_name, .quit_on_last_window_closed = false });
    defer ui_app.destroy();
    _ = objc.msg(objc.BOOL, ui_app.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, if (onscreen) 1 else 2)});
    objc.msg(void, ui_app.nsapp, "finishLaunching", .{});

    const handler = scheme.handler();
    defer objc.release(handler);
    const port = try scheme.listen();
    var http_buf: [64]u8 = undefined;
    const http = try std.fmt.bufPrint(&http_buf, "http://127.0.0.1:{d}", .{port});

    if (onscreen) {
        const ok = try @import("smooth.zig").run(init, gpa, ui_app, handler, http);
        if (!ok) std.process.exit(1);
        return;
    }
    var failed: usize = 0;
    // `KEAZIG_E2E=<text>`: only the cases whose names contain it.
    const only = init.environ_map.get("KEAZIG_E2E");
    for (cases) |case| {
        if (only) |o| if (std.mem.indexOf(u8, case.name, o) == null) continue;
        const pool = objc.Pool.push();
        defer pool.pop();
        var h: Harness = .{ .gpa = gpa, .temp = try app.Temp.init(gpa), .handler = handler, .http = http };
        const result = case.run(&h);
        h.quit();
        // A surface closed with a frame on its way is freed by that frame.
        nanoui.runFor(0.01);
        h.temp.deinit(gpa);
        if (result) |_| {
            std.debug.print("ok   {s}\n", .{case.name});
        } else |err| if (err == error.Skipped) {
            // A case for what this Mac lacks (extensions below macOS 15.4).
            std.debug.print("ok   {s} (skipped: <15.4)\n", .{case.name});
        } else {
            failed += 1;
            const why = if (err == error.CaseFailed) h.reason else @errorName(err);
            std.debug.print("FAIL {s}: {s}\n", .{ case.name, why });
        }
    }
    if (dbg.deinit() == .leak) {
        std.debug.print("e2e cases leaked memory\n", .{});
        std.process.exit(1);
    }
    if (failed > 0) {
        std.debug.print("{d} of {d} e2e cases failed\n", .{ failed, cases.len });
        std.process.exit(1);
    }
}
