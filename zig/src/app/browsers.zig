//! Several windows, each with its browser (`Windows.swift` `Browsers`, and
//! Browser.swift "beginning and ending"). The oldest window's tabs are the
//! session files'; every other window is a line in `windows.json`, frame
//! and rows included. One closed while others stay open can come back with
//! ⇧⌘T; the last one closed is kept, tabs and all, until it's shown again.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Kea = @import("kea.zig").Kea;
const app_name = @import("kea.zig").app_name;
const Browser = @import("../model/browser.zig").Browser;
const window_view = @import("../chrome/window_view.zig");
const session = @import("../data/session.zig");
const windows_file = @import("../data/windows_file.zig");
const WindowRecord = windows_file.WindowRecord;
const json = @import("../data/json.zig");
const Uuid = json.Uuid;
const CGRect = objc.CGRect;

extern fn NSStringFromRect(rect: CGRect) objc.Object;
extern fn NSRectFromString(string: objc.Object) CGRect;

/// The first window's size, and every window's least.
pub const default_size: objc.CGSize = .{ .width = 1180, .height = 780 };
pub const min_size: objc.CGSize = .{ .width = 640, .height = 420 };
/// A hidden run's cascade step, about AppKit's (a title bar's height).
const hidden_cascade: f64 = 22;

/// What `Kea` keeps for its windows.
pub const Windows = struct {
    /// The browser whose window was key last (`Front.shared`).
    front: ?*Browser = null,
    /// Windows closed while others were open, newest last (≤10), each its
    /// record as JSON on `kea.gpa`.
    closed: std.ArrayList(Closed) = .empty,
    /// Windows closing now are the app quitting, not windows closed.
    quitting: bool = false,
    pending: ?*Tick = null,
    observer: ?objc.Object = null,
    monitor: ?objc.Object = null,
    dock: [1]nanoui.MenuItem = undefined,
};

const Closed = struct { record: []u8, at: f64 };

/// The Dock menu's items, above the system's.
pub fn dockMenu(kea: *Kea) []const nanoui.MenuItem {
    kea.windows.dock = .{.{ .label = "New Window", .click = .of(kea, dockNewWindow) }};
    return &kea.windows.dock;
}

fn dockNewWindow(kea: *Kea, _: *nanoui.menu.Item) void {
    _ = newWindow(kea) catch {};
}

// MARK: opening

/// The oldest window's when `record` is null; otherwise another window's,
/// from `windows.json`, ⇧⌘T or new (`Browser(record:)` then `Browsers.open`).
pub fn open(kea: *Kea, record: ?*const WindowRecord, frame: ?CGRect) !*Browser {
    const b = try Browser.create(kea, record);
    errdefer b.destroy();
    try kea.browsers.append(kea.gpa, b);
    errdefer _ = kea.browsers.pop();
    if (kea.opts.headless) return b;
    const app = kea.ui_app orelse return b;
    watchFrames(kea);
    const first = record == null;
    const front_b = front(kea, b);
    const beside: ?*nanoui.Window = if (front_b) |f| f.window else null;
    // A new window from one in full screen: in full screen of its own, sized
    // as a window for when it leaves it.
    const full = !first and frame == null and beside != null and beside.?.isFullScreen();
    const size = if (first or full or beside == null) default_size else objc.msg(CGRect, beside.?.nswindow, "frame", .{}).size;
    const off: ?f64 = if (kea.opts.hidden) -20000 else null;
    const win = try app.newWindow(.{
        .title = app_name,
        .width = size.width,
        .height = size.height,
        .min_width = min_size.width,
        .min_height = min_size.height,
        .title_bar = .hidden,
        .visible = false,
        .x = off,
        .y = off,
        // Never a test run's: it would read and write the real app's frame.
        .frame_autosave = if (first and kea.opts.root == null and !kea.opts.hidden) "kea" else null,
        .tabbing_disallowed = true,
        .on_close = .{ .ctx = b, .func = onClose },
        .should_close = .{ .ctx = b, .func = shouldClose },
        .on_key = .{ .ctx = b, .func = onKey },
        .content = .{ .view = ui.View.init(b, window_view.view) },
    });
    const ns = win.nswindow;
    // The strip does the dragging, never the page underneath.
    objc.msg(void, ns, "setMovableByWindowBackground:", .{objc.NO});
    if (frame) |f| {
        objc.msg(void, ns, "setFrame:display:", .{ f, objc.NO });
    } else if (!first and !full) if (beside) |f| {
        // Down and to the right of the window in front, as new windows go.
        const fr = objc.msg(CGRect, f.nswindow, "frame", .{});
        const from: objc.CGPoint = .{ .x = fr.origin.x, .y = fr.origin.y + fr.size.height };
        // AppKit's cascade pulls a window back onto a screen; a hidden run's
        // steps the same way by hand and stays off every one.
        const top_left = if (kea.opts.hidden)
            objc.CGPoint{ .x = from.x + hidden_cascade, .y = from.y - hidden_cascade }
        else
            objc.msg(objc.CGPoint, ns, "cascadeTopLeftFromPoint:", .{from});
        objc.msg(void, ns, "setFrameTopLeftPoint:", .{top_left});
    };
    try b.bindWindow(win);
    if (!kea.opts.hidden) {
        win.show();
        if (full) win.setFullScreen(true);
        comeForward(kea);
    }
    return b;
}

/// ⌘N. A window closed but kept comes back first; otherwise a new one, with
/// one empty tab.
pub fn newWindow(kea: *Kea) !*Browser {
    for (kea.browsers.items) |b| if (b.shut) {
        show(b);
        return b;
    };
    const record: WindowRecord = .{ .id = Uuid.random(), .space = if (front(kea, null)) |f| f.space_id else Uuid.first };
    return open(kea, &record, null);
}

/// Brings a browser's window on screen.
pub fn show(b: *Browser) void {
    b.shut = false;
    if (b.kea.opts.hidden) return;
    if (b.window) |w| w.show();
    comeForward(b.kea);
}

/// The window in front's browser, or a window brought back or made for it
/// (`ensureWindow`): the Dock icon clicked with no window showing, a link.
pub fn ensureWindow(kea: *Kea) ?*Browser {
    for (kea.browsers.items) |b| if (b.shut) {
        show(b);
        return b;
    };
    if (front(kea, null)) |f| {
        show(f);
        return f;
    }
    return open(kea, null, null) catch null;
}

fn comeForward(kea: *Kea) void {
    if (kea.opts.root != null or kea.opts.hidden) return;
    if (kea.ui_app) |a| objc.msg(void, a.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
}

/// The window in front, or the newest that isn't `except`.
fn front(kea: *Kea, except: ?*Browser) ?*Browser {
    if (kea.windows.front) |f| if (f != except) return f;
    var i = kea.browsers.items.len;
    while (i > 0) {
        i -= 1;
        if (kea.browsers.items[i] != except) return kea.browsers.items[i];
    }
    return null;
}

/// What the menus and keys of no browser's window act on: the window in
/// front's browser (`Front.shared`, `Browsers.acting`).
pub fn acting(kea: *Kea) ?*Browser {
    return front(kea, null);
}

/// At launch, once the first window is up: the other windows there were.
pub fn restore(kea: *Kea) void {
    const records = windows_file.read(&kea.store);
    defer records.deinit();
    if (records.value.len <= 1) return;
    for (records.value[1..]) |*r| _ = reopenRecord(kea, r) catch continue;
    // The first window in front, as the app opens.
    if (!kea.opts.hidden and kea.browsers.items.len > 0) if (kea.browsers.items[0].window) |w| w.show();
}

fn reopenRecord(kea: *Kea, r: *const WindowRecord) !*Browser {
    return open(kea, r, rect(r.frame));
}

/// `WindowRecord.rect`: the saved frame, when it's a real window's.
pub fn rect(frame: ?[]const u8) ?CGRect {
    const s = frame orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const r = NSRectFromString(objc.nsString(s));
    return if (r.size.width > 100 and r.size.height > 100) r else null;
}

// MARK: closing

/// The close button or ⌘W: the last window on screen stays as it is, its
/// browser kept and written down now; any other closes.
fn shouldClose(ctx: *anyopaque, w: *nanoui.Window) bool {
    const b: *Browser = @ptrCast(@alignCast(ctx));
    const kea = b.kea;
    if (kea.windows.quitting) return true;
    for (kea.browsers.items) |o| if (o != b and !o.shut and o.window != null) return true;
    b.shut = true;
    b.flushSession();
    save(kea, true);
    w.hide();
    return false;
}

/// The window is going: its browser with it, remembered for ⇧⌘T unless the
/// app is quitting.
fn onClose(ctx: *anyopaque, _: *nanoui.Window) void {
    const b: *Browser = @ptrCast(@alignCast(ctx));
    const kea = b.kea;
    const quitting = kea.windows.quitting;
    if (!quitting) remember(kea, b);
    b.unbindWindow();
    const was_primary = kea.browsers.items.len > 0 and kea.browsers.items[0] == b;
    for (kea.browsers.items, 0..) |item, i| if (item == b) {
        _ = kea.browsers.orderedRemove(i);
        break;
    };
    if (kea.windows.front == b) kea.windows.front = null;
    b.destroy();
    if (quitting) return;
    if (was_primary and kea.browsers.items.len > 0) becomePrimary(kea.browsers.items[0]);
    save(kea, true);
}

fn remember(kea: *Kea, b: *Browser) void {
    var arena: std.heap.ArenaAllocator = .init(kea.gpa);
    defer arena.deinit();
    const r = recordOf(arena.allocator(), b, true) catch return;
    const bytes = json.encode(kea.gpa, r) catch return;
    kea.windows.closed.append(kea.gpa, .{ .record = bytes, .at = ui.clock.now() }) catch return kea.gpa.free(bytes);
    if (kea.windows.closed.items.len > 10) kea.gpa.free(kea.windows.closed.orderedRemove(0).record);
}

/// The oldest window closed: this one's rows go into the session files now.
fn becomePrimary(b: *Browser) void {
    b.becomePrimary();
    // The first window, opened next launch, comes back where this one is.
    if (b.kea.opts.root == null and !b.kea.opts.hidden) if (b.window) |w|
        objc.msg(void, w.nswindow, "saveFrameUsingName:", .{objc.nsString("kea")});
}

/// ⇧⌘T for a window: it comes back where it was, with its tabs.
pub fn reopenClosedWindow(kea: *Kea) bool {
    const last = kea.windows.closed.pop() orelse return false;
    defer kea.gpa.free(last.record);
    const r = json.decode(WindowRecord, kea.gpa, last.record) catch return false;
    defer r.deinit();
    _ = reopenRecord(kea, &r.value) catch return false;
    save(kea, false);
    return true;
}

/// When the newest window kept for ⇧⌘T was closed (`Browsers.lastClosedAt`).
pub fn lastClosedAt(kea: *Kea) ?f64 {
    const last = kea.windows.closed.getLastOrNull() orelse return null;
    return last.at;
}

// MARK: saving

/// A window's state as a record: frame, space and, when asked, its rows.
fn recordOf(arena: std.mem.Allocator, b: *Browser, rows: bool) !WindowRecord {
    var r: WindowRecord = .{ .id = b.record_id, .space = b.space_id };
    if (b.window) |w| {
        const pool = objc.Pool.push();
        defer pool.pop();
        r.frame = try arena.dupe(u8, objc.fromNSString(NSStringFromRect(objc.msg(CGRect, w.nswindow, "frame", .{}))));
    }
    if (rows) r.rows = try b.allRows(arena);
    return r;
}

/// `windows.json`: the oldest window's frame and space first, then every
/// other window whole.
pub fn save(kea: *Kea, now: bool) void {
    if (kea.browsers.items.len == 0) return;
    var arena: std.heap.ArenaAllocator = .init(kea.gpa);
    defer arena.deinit();
    const records = arena.allocator().alloc(WindowRecord, kea.browsers.items.len) catch return;
    for (kea.browsers.items, records, 0..) |b, *r, i| r.* = recordOf(arena.allocator(), b, i > 0) catch return;
    windows_file.write(&kea.store, records, now);
}

/// Soon, not now: a window being dragged moves many times a second.
pub fn saveSoon(kea: *Kea) void {
    if (kea.windows.pending != null) return;
    // ponytail: c_allocator, so a tick that fires after its Kea has gone frees itself.
    const t = std.heap.c_allocator.create(Tick) catch return;
    t.* = .{ .kea = kea };
    kea.windows.pending = t;
    objc.dispatchAfter(std.time.ns_per_s, t, Tick.fire);
}

const Tick = struct {
    kea: ?*Kea,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const t: *Tick = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(t);
        const kea = t.kea orelse return;
        kea.windows.pending = null;
        save(kea, false);
    }
};

/// Quitting: every window written, now.
pub fn flush(kea: *Kea) void {
    if (kea.browsers.items.len > 0) kea.browsers.items[0].flushSession();
    save(kea, true);
}

/// The app came forward or stepped away: every window's resting lights,
/// and the site card goes with the app (`SiteCardPanel`'s resign observer).
pub fn appActive(kea: *Kea, active: bool) void {
    for (kea.browsers.items) |b| {
        if (b.lights) |l| l.appActive(active);
        if (!active) {
            @import("../chrome/site_card.zig").resign(b);
            @import("../chrome/tab_switcher.zig").cancel(b);
        }
    }
    // A video comes along when another app is in front (`appLeft`/`appBack`).
    @import("../web/float.zig").appActive(kea, active);
}

/// Quitting (`Kea.destroy`): every window closed and every browser let go,
/// nothing remembered or written.
pub fn closeAll(kea: *Kea) void {
    kea.windows.quitting = true;
    if (kea.windows.pending) |t| t.kea = null;
    kea.windows.pending = null;
    unwatch(kea);
    while (kea.browsers.items.len > 0) {
        const b = kea.browsers.items[kea.browsers.items.len - 1];
        // Closing the window runs `onClose`, which drops `b`.
        if (b.window) |w| w.close();
        if (kea.browsers.items.len > 0 and kea.browsers.items[kea.browsers.items.len - 1] == b) {
            _ = kea.browsers.pop();
            b.destroy();
        }
    }
    kea.windows.front = null;
    for (kea.windows.closed.items) |c| kea.gpa.free(c.record);
    kea.windows.closed.deinit(kea.gpa);
}

fn onKey(ctx: *anyopaque, w: *nanoui.Window) void {
    const b: *Browser = @ptrCast(@alignCast(ctx));
    // The window let go of the keys: its tab switcher goes with them.
    if (!w.isFocused()) return @import("../chrome/tab_switcher.zig").cancel(b);
    // `Browsers.becameKey`.
    b.shut = false;
    b.kea.windows.front = b;
    b.handOff();
}

// MARK: watching frames (`Browsers.watchFrames`)

fn watchFrames(kea: *Kea) void {
    if (kea.windows.observer != null) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.defineClass(.{
        .name = "KeaZigFrames",
        .methods = &.{
            .{ .name = "framed:", .imp = &framed, .types = "v@:@" },
            .{ .name = "menuEnded:", .imp = &menuEnded, .types = "v@:@" },
        },
    });
    const observer = objc.msg(objc.Object, cls, "new", .{});
    objc.setZig(observer, kea);
    kea.windows.observer = observer;
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    for ([_][]const u8{ "NSWindowDidMoveNotification", "NSWindowDidResizeNotification" }) |name|
        objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("framed:"), objc.nsString(name), @as(?objc.Object, null) });
    // A press whose release something else kept — a menu tracks the mouse
    // itself — leaves no window unmovable for long.
    objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("menuEnded:"), objc.nsString("NSMenuDidEndTrackingNotification"), @as(?objc.Object, null) });
    // Movable between presses, for macOS's Move & Resize and tiling; not
    // during one, so a tab picked up in the strip moves itself and not the
    // window — unless the press is on the strip's empty run, which drags it.
    var block = objc.BlockRet(Kea, &.{objc.Object}, ?objc.Object).init(kea, pressed);
    const mask: u64 = (1 << 1) | (1 << 2); // left mouse down, up
    const monitor = objc.msg(?objc.Object, objc.class("NSEvent"), "addLocalMonitorForEventsMatchingMask:handler:", .{ mask, &block });
    kea.windows.monitor = if (monitor) |m| objc.retain(m) else null;
}

fn unwatch(kea: *Kea) void {
    if (kea.windows.observer) |o| {
        objc.msg(void, objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{}), "removeObserver:", .{o});
        objc.setZig(o, null);
        objc.release(o);
    }
    if (kea.windows.monitor) |m| {
        objc.msg(void, objc.class("NSEvent"), "removeMonitor:", .{m});
        objc.release(m);
    }
    kea.windows.observer = null;
    kea.windows.monitor = null;
}

pub fn browserFor(kea: *Kea, window: ?objc.Object) ?*Browser {
    const ns = window orelse return null;
    for (kea.browsers.items) |b| if (b.window) |w| if (w.nswindow == ns) return b;
    return null;
}

fn framed(self_obj: objc.Object, _: objc.SEL, note: objc.Object) callconv(.c) void {
    const kea = objc.getZig(Kea, self_obj) orelse return;
    const window = objc.msg(?objc.Object, note, "object", .{});
    if (browserFor(kea, window) != null) saveSoon(kea) else @import("../chrome/popped.zig").framed(kea, window);
}

fn menuEnded(self_obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const kea = objc.getZig(Kea, self_obj) orelse return;
    for (kea.browsers.items) |b| if (b.window) |w| objc.msg(void, w.nswindow, "setMovable:", .{objc.YES});
}

fn pressed(kea: *Kea, event: objc.Object) ?objc.Object {
    const b = browserFor(kea, objc.msg(?objc.Object, event, "window", .{})) orelse return event;
    const w = b.window.?;
    const up = objc.msg(objc.NSUInteger, event, "type", .{}) == 2;
    const strip = if (w.surface) |s| s.ctx.startsWindowDrag() else false;
    objc.msg(void, w.nswindow, "setMovable:", .{up or strip});
    return event;
}

// MARK: tests

test "a saved frame is a window's only when bigger than 100 × 100" {
    const t = std.testing;
    const r = rect("{{120, 80}, {1180, 780}}").?;
    try t.expectEqual(@as(f64, 120), r.origin.x);
    try t.expectEqual(@as(f64, 780), r.size.height);
    try t.expect(rect("{{0, 0}, {90, 600}}") == null);
    try t.expect(rect(null) == null);
}
