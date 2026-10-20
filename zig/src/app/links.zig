//! Links from elsewhere (Links.swift). A click in Mail, in Slack, in a PDF:
//! macOS hands the address to whichever app owns http, and this is how
//! Kea takes it (`App.Options.on_open_urls`, `on_continue_activity`).
//! Addresses that come while the first window isn't on screen yet wait
//! until it is; then the first goes into the blank tab and the others fill
//! in behind it, a few frames apart, in the order they came. Also: whether
//! Kea is the Mac's browser, and the crash log.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("kea.zig").Kea;
const browsers = @import("browsers.zig");
const little = @import("../web/little.zig");

/// What `Kea` keeps for links (`Links.waiting`, `deliver`).
pub const State = struct {
    /// Addresses that arrived before a window was showing, on `kea.gpa`.
    waiting: std.ArrayList([]u8) = .empty,
    /// A window has shown: links go straight to the window in front.
    ready: bool = false,
    wait: ?*Wait = null,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.wait) |w| w.kea = null;
        for (s.waiting.items) |u| gpa.free(u);
        s.waiting.deinit(gpa);
        s.* = .{};
    }
};

// MARK: taking links

/// `application(_:open:)`: addresses, and pages on this Mac (an .html
/// double-clicked in the Finder once Kea is the browser).
pub fn onOpenURLs(ctx: ?*anyopaque, urls: []const []const u8) void {
    const kea: *Kea = @ptrCast(@alignCast(ctx.?));
    for (urls) |u| if (isWeb(u) or schemeIs(u, "file")) take(kea, u);
}

/// `application(_:continue:restorationHandler:)`: a page handed over from
/// another device (Handoff).
pub fn onContinueActivity(ctx: ?*anyopaque, url: []const u8) void {
    const kea: *Kea = @ptrCast(@alignCast(ctx.?));
    if (isWeb(url)) take(kea, url);
}

fn scheme(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfScalar(u8, url, ':') orelse 0];
}

fn schemeIs(url: []const u8, s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scheme(url), s);
}

/// `url.scheme?.lowercased().hasPrefix("http")`.
fn isWeb(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(scheme(url), "http");
}

fn take(kea: *Kea, url: []const u8) void {
    if (kea.links.ready) return deliver(kea, url);
    const copy = kea.gpa.dupe(u8, url) catch return;
    kea.links.waiting.append(kea.gpa, copy) catch kea.gpa.free(copy);
}

/// The window in front's browser, or a window brought back for it: the
/// link lands where you are, not in the first window.
fn deliver(kea: *Kea, url: []const u8) void {
    const b = browsers.ensureWindow(kea) orelse return;
    // In a small window of its own, for whoever chose that.
    if (b.prefs.little_links) {
        _ = little.show(b, url, true);
        return;
    }
    b.arrive(url);
    if (!kea.opts.hidden) if (b.window) |w| {
        // Put away in the Dock, it stayed there: bringing a window to the
        // front doesn't take it out (#95).
        if (objc.msg(objc.BOOL, w.nswindow, "isMiniaturized", .{})) objc.msg(void, w.nswindow, "deminiaturize:", .{@as(?objc.Object, null)});
        objc.msg(void, w.nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    };
    comeForward(kea);
}

/// `Links.hand(to:)`: the first window is up. Anything that came earlier is
/// handed over once it is on screen (`onceShown`), the first into the blank
/// tab, the others behind it, 0.15 s apart.
pub fn hand(kea: *Kea) void {
    if (kea.links.ready or kea.links.wait != null) return;
    // ponytail: c_allocator, so a wait that fires after its Kea has gone frees itself.
    const w = std.heap.c_allocator.create(Wait) catch return;
    w.* = .{ .kea = kea };
    kea.links.wait = w;
    objc.dispatchMain(w, Wait.fire);
}

const Wait = struct {
    kea: ?*Kea,
    tries: u32 = 0,

    fn again(w: *Wait, ms: u64) void {
        objc.dispatchAfter(ms * std.time.ns_per_ms, w, fire);
    }

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Wait = @ptrCast(@alignCast(ctx.?));
        const kea = w.kea orelse return std.heap.c_allocator.destroy(w);
        const s = &kea.links;
        if (!s.ready) {
            // Gives up waiting after a second or so: a launch started
            // hidden has a window nobody can see yet.
            if (!anyShown() and w.tries <= 40) {
                w.tries += 1;
                return w.again(30);
            }
            s.ready = true;
            if (s.waiting.items.len > 0) if (first(kea)) |b| {
                const url = s.waiting.orderedRemove(0);
                defer kea.gpa.free(url);
                b.arrive(url);
                comeForward(kea);
            };
        } else if (s.waiting.items.len > 0) if (first(kea)) |b| {
            const url = s.waiting.orderedRemove(0);
            defer kea.gpa.free(url);
            _ = b.open(url, .{ .foreground = false, .at_end = true, .may_wait = true });
        };
        if (s.waiting.items.len > 0) return w.again(150);
        s.wait = null;
        std.heap.c_allocator.destroy(w);
    }
};

/// The window the early links were waiting for: the first one's.
fn first(kea: *Kea) ?*@import("../model/browser.zig").Browser {
    return if (kea.browsers.items.len > 0) kea.browsers.items[0] else null;
}

/// `NSApp.windows.contains { $0.isVisible && $0.contentView != nil }`.
fn anyShown() bool {
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const windows = objc.msg(objc.Object, app, "windows", .{});
    for (0..objc.msg(objc.NSUInteger, windows, "count", .{})) |i| {
        const w = objc.msg(objc.Object, windows, "objectAtIndex:", .{i});
        if (objc.msg(objc.BOOL, w, "isVisible", .{}) and objc.msg(?objc.Object, w, "contentView", .{}) != null) return true;
    }
    return false;
}

/// In front of the app the link was clicked in. Since macOS 14 an app is
/// let in front when the app asking hands the front over (`activate()`);
/// not every app does, so a moment later it asks again the old way. Never
/// a test run's.
fn comeForward(kea: *Kea) void {
    if (kea.opts.root != null or kea.opts.hidden) return;
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    objc.msg(void, app, "activate", .{});
    objc.dispatchAfter(250 * std.time.ns_per_ms, null, stillBehind);
}

fn stillBehind(_: ?*anyopaque) callconv(.c) void {
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    if (!objc.msg(objc.BOOL, app, "isActive", .{})) objc.msg(void, app, "activateIgnoringOtherApps:", .{objc.YES});
}

// MARK: being the browser

const probe = "https://example.com";

/// True when this app is where links from other apps go.
pub fn isDefault() bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const url = objc.msg(objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(probe)});
    const handler = objc.msg(?objc.Object, ws, "URLForApplicationToOpenURL:", .{url}) orelse return false;
    const bundle = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{}), "bundleURL", .{});
    return objc.msg(objc.BOOL, objc.msg(objc.Object, handler, "standardizedURL", .{}), "isEqual:", .{objc.msg(objc.Object, bundle, "standardizedURL", .{})});
}

/// Asks macOS to send http and https here. The system puts up its own
/// confirmation; `done(ctx, worked)` hears the answer on the main thread.
/// Never from a test: it changes the Mac's browser.
pub fn becomeDefault(ctx: ?*anyopaque, done: *const fn (?*anyopaque, bool) void) void {
    const asked = std.heap.c_allocator.create(Asked) catch return;
    asked.* = .{ .ctx = ctx, .done = done };
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const app = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{}), "bundleURL", .{});
    for ([_][]const u8{ "http", "https" }) |s| {
        var block = objc.Block(Asked, &.{?objc.Object}).init(asked, Asked.answered);
        objc.msg(void, ws, "setDefaultApplicationAtURL:toOpenURLsWithScheme:completionHandler:", .{ app, objc.nsString(s), &block });
    }
}

const Asked = struct {
    ctx: ?*anyopaque,
    done: *const fn (?*anyopaque, bool) void,
    left: std.atomic.Value(u8) = .init(2),
    failed: std.atomic.Value(bool) = .init(false),

    /// Either queue's: the last answer goes to the main thread.
    fn answered(a: *Asked, err: ?objc.Object) void {
        if (err != null) a.failed.store(true, .release);
        if (a.left.fetchSub(1, .acq_rel) == 1) objc.dispatchMain(a, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const a: *Asked = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(a);
        a.done(a.ctx, !a.failed.load(.acquire));
    }
};

// MARK: trouble

extern "c" fn NSSetUncaughtExceptionHandler(handler: ?*const fn (objc.Object) callconv(.c) void) void;

/// `crash.log` in Kea's folder, for the handler (process-long).
var crash_path: ?[:0]u8 = null;

/// The nearest thing to a crash reporter a browser with no server can
/// have: nothing is sent anywhere. One entry, appended, so it survives the
/// crash that is about to end the process.
pub fn watchForTrouble(kea: *Kea) void {
    const p = kea.store.file("crash.log") catch return;
    defer kea.gpa.free(p);
    crash_path = std.heap.c_allocator.dupeSentinel(u8, p, 0) catch return;
    NSSetUncaughtExceptionHandler(&uncaught);
}

pub fn logTrouble(kea: *Kea, msg: []const u8) void {
    if (crash_path) |path| return append(path, &.{ msg, "\n" });
    const p = kea.store.file("crash.log") catch return;
    defer kea.gpa.free(p);
    const z = kea.gpa.dupeSentinel(u8, p, 0) catch return;
    defer kea.gpa.free(z);
    append(z, &.{ msg, "\n" });
}

fn uncaught(exception: objc.Object) callconv(.c) void {
    const path = crash_path orelse return;
    const date = objc.msg(objc.Object, objc.class("NSDate"), "date", .{});
    const reason = objc.msg(?objc.Object, exception, "reason", .{});
    const stack = objc.msg(objc.Object, objc.msg(objc.Object, exception, "callStackSymbols", .{}), "componentsJoinedByString:", .{objc.nsString("\n")});
    append(path, &.{
        objc.fromNSString(objc.msg(objc.Object, date, "description", .{})),
        " — ",
        objc.fromNSString(objc.msg(?objc.Object, exception, "name", .{})),
        ": ",
        if (reason != null) objc.fromNSString(reason) else "?",
        "\n",
        objc.fromNSString(stack),
        "\n\n",
    });
}

/// Appends `parts` to the file at `path`, making it when it isn't there.
fn append(path: [:0]const u8, parts: []const []const u8) void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    for (parts) |s| _ = std.c.write(fd, s.ptr, s.len);
}

test "crash entries append" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    const p = try t.path(gpa, "crash.log");
    defer gpa.free(p);
    const z = try gpa.dupeSentinel(u8, p, 0);
    defer gpa.free(z);
    append(z, &.{ "one", "\n\n" });
    append(z, &.{ "two", "\n\n" });
    const got = @import("../data/disk.zig").read(gpa, p).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("one\n\ntwo\n\n", got);
}

test "only web and file addresses are taken" {
    try std.testing.expect(isWeb("HTTPS://a.b"));
    try std.testing.expect(!isWeb("ftp://a.b"));
    try std.testing.expect(!isWeb("mailto:http"));
    try std.testing.expect(schemeIs("file:///tmp/a.html", "file"));
}
