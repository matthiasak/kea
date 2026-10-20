//! A small window for a link from another app (Little.swift, Settings ›
//! General `links.little`): the page, and a 34-point line over it with the
//! site and Open in KeaZig — to read and close, or to keep. The page is a
//! tab of its own in a window of its own; Open in KeaZig (⌘O) moves it
//! into the browser's row, loaded as it is. Its keys are its own, before
//! the browser's: ⌘O keeps it, Escape and ⌘W close it.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Kea = @import("../app/kea.zig").Kea;
const app_name = @import("../app/kea.zig").app_name;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("tab.zig").Tab;
const StageHost = @import("stage_host.zig").StageHost;
const Parts = @import("../data/url.zig").Parts;
const palette = @import("../design/palette.zig");
const controls = @import("../chrome/controls.zig");
const page_layers = @import("../chrome/page_layers.zig");
const site_card = @import("../chrome/site_card.zig");
const appkit = @import("../sys/appkit.zig");

const gpa = std.heap.c_allocator;

pub const width: f64 = 900;
pub const height: f64 = 640;

pub const Little = struct {
    kea: *Kea,
    tab: *Tab,
    /// The window it came from, while that window lasts.
    browser: *Browser,
    window: *nanoui.Window,
    host: ?*StageHost = null,
    kept: bool = false,
    /// The ground last given to the NSWindow.
    applied: ?ui.Color = null,

    /// Closed as its button closes it.
    pub fn close(self: *Little) void {
        objc.msg(void, self.window.nswindow, "performClose:", .{@as(?objc.Object, null)});
    }

    /// Into the browser's row — the window in front, whichever that is now
    /// — after the tab on screen, and in front; the small window goes.
    pub fn keep(self: *Little) void {
        const b = self.kea.windows.front orelse (if (alive(self.kea, self.browser)) self.browser else return);
        self.kept = true;
        // Off this window's stage before it goes on the browser's.
        if (self.host) |h| if (self.tab.web) |wv| h.forget(wv);
        b.receive(self.tab);
        const kea = self.kea;
        // Frees `self` (`closed`).
        self.window.close();
        if (kea.opts.hidden or kea.opts.root != null) return;
        @import("../app/browsers.zig").show(b);
    }
};

/// Open ones, newest last, each until it is closed or kept.
pub var open: std.ArrayList(*Little) = .empty;
var monitor: ?objc.Object = null;
var monitor_ctx: u8 = 0;

fn alive(kea: *Kea, b: *Browser) bool {
    return std.mem.indexOfScalar(*Browser, kea.browsers.items, b) != null;
}

/// A link from another app, in a small window in front of it. `front:
/// false`, or a hidden run, makes it without ever showing it.
pub fn show(b: *Browser, url: []const u8, front: bool) ?*Little {
    const kea = b.kea;
    const app = kea.ui_app orelse return null;
    if (kea.opts.headless) return null;
    const self = gpa.create(Little) catch return null;
    const off: ?f64 = if (kea.opts.hidden) -20000 else null;
    const win = app.newWindow(.{
        .width = width,
        .height = height,
        .min_width = 420,
        .min_height = 320,
        .title_bar = .hidden,
        .visible = false,
        .x = off,
        .y = off,
        .tabbing_disallowed = true,
        .on_close = .{ .ctx = self, .func = closed },
        .content = .{ .view = ui.View.init(self, view) },
    }) catch {
        gpa.destroy(self);
        return null;
    };
    // A tab of its own, in this window's space, with its sign-ins.
    const tab = b.make(url, false);
    self.* = .{ .kea = kea, .tab = tab, .browser = b, .window = win };
    open.append(gpa, self) catch {};
    if (monitor == null) monitor = appkit.addLocalMonitor(1 << 10, &monitor_ctx, keyDown);
    if (win.surface) |s| {
        self.host = StageHost.create(gpa, s) catch null;
        if (self.host) |h| {
            h.setPage(tab.web, false);
            if (tab.web) |wv| _ = objc.msg(objc.BOOL, win.nswindow, "makeFirstResponder:", .{wv});
        }
        s.frame();
    }
    // Never a test run's in front: a run started hidden stays off every screen.
    if (front and !kea.opts.hidden and kea.opts.root == null) {
        objc.msg(void, win.nswindow, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
        objc.msg(void, app.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
    }
    return self;
}

/// The small window a tab is in, if it is in one.
pub fn of(t: *const Tab) ?*Little {
    for (open.items) |l| if (l.tab == t) return l;
    return null;
}

/// The small window a key was pressed in, if it was one.
pub fn owning(window: ?objc.Object) ?*Little {
    const w = window orelse return null;
    for (open.items) |l| if (l.window.nswindow == w) return l;
    return null;
}

/// A tab said something changed: its small window draws again.
pub fn changed(t: *const Tab) void {
    if (of(t)) |l| {
        if (l.host) |h| if (t.web) |wv| {
            const had = h.slots.items.len > 0 and h.slots.items[0].webview == wv;
            h.setPage(wv, false);
            if (!had) _ = objc.msg(objc.BOOL, l.window.nswindow, "makeFirstResponder:", .{wv});
        };
        l.window.redraw();
    }
}

/// `Kea.destroy`: every small window of it closes, its page with it.
pub fn closeAll(kea: *Kea) void {
    var i = open.items.len;
    while (i > 0) {
        i -= 1;
        if (i < open.items.len and open.items[i].kea == kea) open.items[i].window.close();
    }
}

/// `windowWillClose`: closed, not kept — the page goes with it.
fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
    const self: *Little = @ptrCast(@alignCast(ctx));
    if (self.host) |h| {
        // A kept page is on the browser's stage now (`keep` let go of it here).
        if (!self.kept) if (self.tab.web) |wv| h.forget(wv);
        h.destroy();
    }
    if (!self.kept) self.tab.destroy();
    if (std.mem.indexOfScalar(*Little, open.items, self)) |i| _ = open.orderedRemove(i);
    if (open.items.len == 0) if (monitor) |m| {
        appkit.removeMonitor(m);
        monitor = null;
    };
    gpa.destroy(self);
}

/// The key monitor: a small window's keys are its own (`LittleWindow.owning`).
fn keyDown(_: *u8, event: objc.Object) ?objc.Object {
    const l = owning(objc.msg(?objc.Object, event, "window", .{})) orelse return event;
    return if (take(l, event)) null else event;
}

/// `take`: ⌘O keeps it, Escape and ⌘W close it; everything else is the page's.
pub fn take(l: *Little, event: objc.Object) bool {
    // NSEventModifierFlagDeviceIndependentFlagsMask.
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{}) & 0xffff0000;
    const command: objc.NSUInteger = 1 << 20;
    var kb: [8]u8 = undefined;
    const raw = objc.fromNSString(objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{}));
    const key = std.ascii.lowerString(kb[0..@min(raw.len, kb.len)], raw[0..@min(raw.len, kb.len)]);
    if ((objc.msg(u16, event, "keyCode", .{}) == 53 and flags == 0) or (std.mem.eql(u8, key, "w") and flags == command)) {
        l.close();
        return true;
    }
    if (std.mem.eql(u8, key, "o") and flags == command) {
        l.keep();
        return true;
    }
    return false;
}

/// The page on screen — not one still on its way — named as the site, or
/// as what it is when it isn't a website, marked when it came over http.
pub fn site(buf: []u8, t: *const Tab) []const u8 {
    const url = t.committed orelse return "";
    const p = Parts.parse(url) orelse return "Not a website";
    if (p.schemeIs("https")) return site_card.site(url);
    if (p.schemeIs("http")) return std.fmt.bufPrint(buf, "Not secure — {s}", .{site_card.site(url)}) catch "";
    if (p.schemeIs("chrome-extension") or p.schemeIs("webkit-extension")) return "Extension page";
    return if (std.mem.eql(u8, url, "about:blank")) "" else "Not a website";
}

fn px(v: f32) ui.Length {
    return .{ .px = v };
}

fn view(self: *Little, c: *ui.Context) void {
    c.hand_cursor = false;
    // Drawn first inside `newWindow`, before it is filled in.
    if (std.mem.indexOfScalar(*Little, open.items, self) == null) return;
    const p = palette.get(c.theme.dark);
    applyGround(self.window.nswindow, &self.applied, p.ground);
    if (body(c, p, self.tab, true)) objc.dispatchMain(self, keepSoon);
}

/// `ExtensionPopupView`: an extension's popup window (windows.create with
/// type "popup") shows its tab in front as the small window shows a page,
/// the site over it and no Open in KeaZig.
pub fn popupView(b: *Browser, c: *ui.Context) void {
    const p = palette.get(c.theme.dark);
    c.title_bar_height = 0;
    if (b.window) |w| applyGround(w.nswindow, &b.applied_ground, p.ground);
    const tab = b.activeTab() orelse {
        b.stage.count = 0;
        return;
    };
    // The one page on its stage (`Browser.syncStageHost`).
    b.stage.panes[0] = .{ .tab = tab.id };
    b.stage.count = 1;
    _ = body(c, p, tab, false);
}

/// `LittleView`: the page, and the line over it — the site, and Open in
/// KeaZig when there is somewhere to keep it; true when that is pressed.
fn body(c: *ui.Context, p: *const palette.Palette, tab: *Tab, keeps: bool) bool {
    ui.column(c, .{ .width = .fill, .height = .fill });
    defer ui.end(c);
    ui.row(c, .{ .width = .fill, .height = px(34), .padding = .xy(10, 0), .gap = 10, .align_items = .center });
    // Room for the window's own buttons, which sit on this line.
    _ = c.leaf(.{ .width = px(64) }, .none, null);
    ui.spacer(c);
    var buf: [300]u8 = undefined;
    ui.text(c, site(&buf, tab), .{ .size = 12.5, .weight = .medium, .color = p.muted, .truncate = true });
    ui.spacer(c);
    const kept = if (keeps) controls.pill(c, p, "Open in " ++ app_name, .{ .help = "Open in " ++ app_name ++ "   ⌘O" }).clicked else blk: {
        _ = c.leaf(.{ .width = px(64) }, .none, null);
        break :blk false;
    };
    ui.end(c);
    const page = c.open(.{ .width = .fill, .grow = 1 }, "kea.little.page");
    c.addStageHoleNode(page);
    // A page that never came says so, with Try again, as in a tab.
    page_layers.draw(c, p, tab);
    c.end();
    return kept;
}

/// The window's ground: hosted, its root is left unpainted.
fn applyGround(window: objc.Object, applied: *?ui.Color, g: ui.Color) void {
    if (applied.*) |a| if (std.meta.eql(a, g)) return;
    applied.* = g;
    const color = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{ @as(f64, g.r), @as(f64, g.g), @as(f64, g.b), @as(f64, g.a) });
    objc.msg(void, window, "setBackgroundColor:", .{color});
}

/// After the frame: keeping closes the window the frame is drawing.
fn keepSoon(ctx: ?*anyopaque) callconv(.c) void {
    const self: *Little = @ptrCast(@alignCast(ctx orelse return));
    if (std.mem.indexOfScalar(*Little, open.items, self) != null) self.keep();
}