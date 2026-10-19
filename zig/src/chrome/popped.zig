//! A side panel in a window of its own (`PanelWindow`, SidePanels.swift:
//! 299-423): titled, closable and resizable, at least 280 × 360, its place
//! and size kept in the defaults as `NSStringFromRect` text and given back
//! only while a screen still shows most of it. The bookmarks' is one for
//! the app, showing the window in front's (`followBookmarks`). Headless
//! runs keep the record without a window; tests never show one.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const CGRect = objc.CGRect;
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const palette = @import("../design/palette.zig");
const side_panels = @import("side_panels.zig");
const SidePanel = side_panels.SidePanel;
const intersection = @import("../web/float_moves.zig").intersection;

extern fn NSStringFromRect(rect: CGRect) objc.Object;
extern fn NSRectFromString(string: objc.Object) CGRect;

pub const PanelWindow = struct {
    kea: *Kea,
    panel: SidePanel,
    /// Whose panel it shows; null: the window in front's (the bookmarks').
    browser: ?*Browser,
    /// Null in a headless run: only the record.
    window: ?*nanoui.Window = null,
    /// Closed by the app, not by its close button: nothing else follows.
    quiet: bool = false,

    fn frameKey(self: *const PanelWindow) []const u8 {
        return if (self.panel == .chat) "ai.window" else "bookmarks.window";
    }

    /// Draws again (what it shows changed in a browser window).
    pub fn redraw(self: *PanelWindow) void {
        if (self.window) |w| w.redraw();
    }

    /// `close()`: closed without its `closed` work.
    pub fn close(self: *PanelWindow) void {
        self.quiet = true;
        if (self.window) |w| w.close() else self.kea.gpa.destroy(self);
    }

    /// The browser it shows: its own, or the window in front's.
    fn shown(self: *const PanelWindow) ?*Browser {
        if (self.browser) |b| return b;
        const kea = self.kea;
        return kea.windows.front orelse if (kea.browsers.items.len > 0) kea.browsers.items[0] else null;
    }

    fn saveFrame(self: *const PanelWindow) void {
        const kea = self.kea;
        const w = self.window orelse return;
        if (kea.opts.root != null or kea.opts.hidden) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        kea.store.setString(self.frameKey(), objc.fromNSString(NSStringFromRect(objc.msg(CGRect, w.nswindow, "frame", .{}))));
    }
};

/// `panel`'s window ("Ubi Chat" 420 × 640, "Bookmarks" 280 × 560 where no
/// frame was kept), showing `browser`'s panel, or the front window's.
pub fn open(kea: *Kea, panel: SidePanel, browser: ?*Browser) ?*PanelWindow {
    const self = kea.gpa.create(PanelWindow) catch return null;
    self.* = .{ .kea = kea, .panel = panel, .browser = browser };
    const app = kea.ui_app orelse return self;
    if (kea.opts.headless) return self;
    const size: objc.CGSize = if (panel == .chat) .{ .width = 420, .height = 640 } else .{ .width = 280, .height = 560 };
    const testing = kea.opts.root != null or kea.opts.hidden;
    const spot: CGRect = if (testing)
        .{ .origin = .{ .x = -20000, .y = -20000 }, .size = size }
    else if (remembered(kea, self.frameKey())) |saved| saved else blk: {
        const screen = @import("../web/float_moves.zig").mainVisible();
        const s = if (screen.size.width > 0) screen else CGRect{ .size = .{ .width = 1440, .height = 900 } };
        break :blk .{ .origin = .{
            .x = @round(s.origin.x + s.size.width / 2 - size.width / 2),
            .y = @round(s.origin.y + s.size.height / 2 - size.height / 2),
        }, .size = size };
    };
    const win = app.newWindow(.{
        .title = if (panel == .chat) "Ubi Chat" else "Bookmarks",
        .width = size.width,
        .height = size.height,
        .kind = .panel,
        .visible = false,
        .on_close = .{ .ctx = self, .func = closed },
        .content = .{ .view = ui.View.init(self, view) },
    }) catch {
        kea.gpa.destroy(self);
        return null;
    };
    self.window = win;
    const ns = win.nswindow;
    objc.msg(void, ns, "setStyleMask:", .{@as(objc.NSUInteger, 1 | 2 | 8)}); // titled, closable, resizable
    objc.msg(void, ns, "setHidesOnDeactivate:", .{objc.NO});
    objc.msg(void, ns, "setMinSize:", .{objc.CGSize{ .width = 280, .height = 360 }});
    objc.msg(void, ns, "setFrame:display:", .{ spot, objc.YES });
    // Never a test run's on screen.
    if (!testing) objc.msg(void, ns, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    return self;
}

/// A kept frame, when it is a window's and a screen still shows most of it.
fn remembered(kea: *Kea, key: []const u8) ?CGRect {
    const text = kea.store.string(key) orelse return null;
    defer kea.store.gpa.free(text);
    const pool = objc.Pool.push();
    defer pool.pop();
    const frame = NSRectFromString(objc.nsString(text));
    if (frame.size.width <= 100) return null;
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    for (0..objc.msg(objc.NSUInteger, screens, "count", .{})) |i| {
        const seen = intersection(objc.msg(CGRect, objc.msg(objc.Object, screens, "objectAtIndex:", .{i}), "visibleFrame", .{}), frame);
        if (seen.size.width * seen.size.height > 0.6 * frame.size.width * frame.size.height) return frame;
    }
    return null;
}

/// `windowWillClose`: its frame kept; closed by its button, the panel goes too.
fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
    const self: *PanelWindow = @ptrCast(@alignCast(ctx));
    const kea = self.kea;
    self.saveFrame();
    if (kea.marks_window == self) kea.marks_window = null;
    if (!self.quiet) switch (self.panel) {
        .bookmarks => {
            kea.prefs.set("bookmarks_sidebar", false);
            side_panels.redrawAll(kea);
        },
        // P9: the chat's window closing closes the chat (`closeAssistant`).
        .chat => {},
    };
    kea.gpa.destroy(self);
}

/// `NSWindowDidMove` / `DidResize` for some window (app/browsers.zig's
/// watch): a panel's keeps its frame.
pub fn framed(kea: *Kea, nswindow: ?objc.Object) void {
    const m = kea.marks_window orelse return;
    const w = m.window orelse return;
    if (nswindow == w.nswindow) m.saveFrame();
}

/// The panel's window, if it has one on screen.
pub fn windowOf(kea: *Kea, panel: SidePanel) ?*nanoui.Window {
    if (panel == .bookmarks) if (kea.marks_window) |m| return m.window;
    return null;
}

/// `followBookmarks`: the bookmarks' window follows the sidebar being
/// asked for and popped out. Called at the top of a browser window's
/// frame only: closing a window frees it at once, so never from inside
/// the panel window's own frame (its doors and menu set the prefs and ask
/// the browsers to draw).
pub fn followBookmarks(kea: *Kea) void {
    const want = kea.prefs.bookmarks_sidebar and kea.prefs.marks_popped;
    if (want == (kea.marks_window != null)) return;
    if (want) {
        kea.marks_window = open(kea, .bookmarks, null);
    } else {
        const m = kea.marks_window.?;
        kea.marks_window = null;
        m.close();
    }
}

fn view(self: *PanelWindow, c: *ui.Context) void {
    // Drawn first inside `newWindow`, before it is filled in.
    if (self.window == null) return;
    const p = palette.get(c.theme.dark);
    const b = self.shown() orelse return;
    ui.column(c, .{ .width = .fill, .height = .fill, .background = p.ground });
    side_panels.panelView(b, c, p, self.panel, false, null, false, true);
    ui.end(c);
    // What it did shows in the browser's window too.
    if (c.input.released or c.input.key != null) b.redraw();
}
