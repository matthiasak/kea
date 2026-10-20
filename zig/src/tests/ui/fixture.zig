//! A headless Kea in a temp root and defaults suite, drawn by `ui.Tester`.
//! Holes the page would show through are `tester.ctx.stage_rects[0..stage_count]`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");

/// Keys held with a press.
pub const Mods = struct { cmd: bool = false, shift: bool = false, alt: bool = false, ctrl: bool = false };

pub const Options = struct {
    width: f32 = 1440,
    height: f32 = 900,
    scale: f32 = 2,
    dark: bool = false,
    sidebar: ?bool = null,
    /// Extra tabs opened after the first one.
    tabs: usize = 0,
    /// The first launch's Welcome over the window; off, as if seen before.
    welcome: bool = false,
};

pub const Fixture = struct {
    gpa: std.mem.Allocator,
    temp: app.Temp,
    kea: *app.Kea,
    browser: *app.Browser,
    tester: ui.Tester,

    /// Initializes in place: the tester points into the fixture.
    pub fn init(f: *Fixture, gpa: std.mem.Allocator, opts: Options) !void {
        var temp = try app.Temp.init(gpa);
        errdefer temp.deinit(gpa);
        const k = try app.Kea.create(gpa, null, .{ .root = temp.root, .suite = temp.suite, .headless = true });
        errdefer k.destroy();
        if (opts.sidebar) |on| k.prefs.set("sidebar", on);
        if (!opts.welcome) k.prefs.set("welcomed", true);
        const b = try k.newBrowser();
        for (0..opts.tabs) |i| {
            var buf: [64]u8 = undefined;
            _ = b.open(try std.fmt.bufPrint(&buf, "kea-test://site/page?title=Tab%20{d}", .{i + 1}), .{ .foreground = false, .at_end = true });
        }
        f.* = .{ .gpa = gpa, .temp = temp, .kea = k, .browser = b, .tester = undefined };
        try f.tester.init(gpa, ui.View.init(b, app.window_view.view), .{
            .width = opts.width,
            .height = opts.height,
            .scale = opts.scale,
            .dark = opts.dark,
        });
        // As the hosted window's surface: holes show the page behind.
        f.tester.ctx.transparent_root = true;
        f.tester.frame();
    }

    pub fn deinit(f: *Fixture) void {
        f.tester.deinit();
        f.kea.destroy();
        f.temp.deinit(f.gpa);
    }

    pub fn holes(f: *Fixture) []const ui.Rect {
        return f.tester.ctx.stage_rects[0..f.tester.ctx.stage_count];
    }

    /// A key pressed, as AppKit hands it on: the key monitor first
    /// (`keys.take`), then the menu bar's key equivalents, then the view
    /// that has the keys. `chars` is what it types, `code` its key code.
    /// Whether anything took it.
    pub fn press(f: *Fixture, chars: []const u8, code: u16, m: Mods) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const ev = keyEvent(10, chars, code, m);
        const taken = app.keys.take(f.browser, ev) or f.menuKey(ev) or f.tester.shortcut(.{
            .key = viewKey(chars, code),
            .cmd = m.cmd,
            .ctrl = m.ctrl,
            .alt = m.alt,
            .shift = m.shift,
        });
        f.tester.frame();
        return taken;
    }

    /// Modifiers held or let go of (`flagsChanged`): the monitor, then the view.
    pub fn mods(f: *Fixture, m: Mods) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        app.keys.modifiers(f.browser, keyEvent(12, "", 0, m));
        f.tester.setMods(.{ .cmd = m.cmd, .ctrl = m.ctrl, .alt = m.alt, .shift = m.shift });
    }

    /// What NSMenu does with a key equivalent: the enabled item of the bar
    /// (as it would be made now) wearing that key, clicked.
    fn menuKey(f: *Fixture, ev: objc.Object) bool {
        var buf: [32]u8 = undefined;
        const kc = app.shortcuts.fromEvent(ev, &buf) orelse return false;
        var arena = std.heap.ArenaAllocator.init(f.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const want = app.menus.accel(a, kc) catch return false;
        const bar = app.menus.bar(a, f.kea, f.browser) catch return false;
        return clickKey(bar, want);
    }
};

fn clickKey(items: []const nanoui.MenuItem, want: []const u8) bool {
    for (items) |it| {
        if (it.hidden or it.disabled or it.is_separator) continue;
        if (it.submenu) |sub| if (clickKey(sub, want)) return true;
        if (it.accelerator.len == 0 or !std.mem.eql(u8, it.accelerator, want)) continue;
        const click = it.click orelse return false;
        var unused: nanoui.menu.Item = undefined;
        click.func(click.ctx, &unused);
        return true;
    }
    return false;
}

/// An `NSEvent` of `kind` (10 key down, 12 flags changed) in no window.
fn keyEvent(kind: objc.NSUInteger, chars: []const u8, code: u16, m: Mods) objc.Object {
    const flag = app.shortcuts.flag;
    var flags: u64 = 0;
    if (m.cmd) flags |= flag.command;
    if (m.shift) flags |= flag.shift;
    if (m.alt) flags |= flag.option;
    if (m.ctrl) flags |= flag.control;
    return objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        kind, objc.CGPoint{}, @as(objc.NSUInteger, flags), @as(f64, 0), @as(objc.NSInteger, 0),
        @as(?objc.Object, null), objc.nsString(chars), objc.nsString(chars), false, code,
    });
}

/// The key as the view's shortcuts name it.
fn viewKey(chars: []const u8, code: u16) u21 {
    return switch (code) {
        53 => ui.Shortcut.escape,
        48 => ui.Shortcut.tab,
        36, 76 => ui.Shortcut.enter,
        123 => ui.Shortcut.left,
        124 => ui.Shortcut.right,
        125 => ui.Shortcut.down,
        126 => ui.Shortcut.up,
        else => if (chars.len > 0) std.unicode.utf8Decode(chars[0..std.unicode.utf8ByteSequenceLength(chars[0]) catch 1]) catch 0 else 0,
    };
}
