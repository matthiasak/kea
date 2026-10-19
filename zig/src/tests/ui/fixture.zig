//! A headless KeaZig in a temp root and defaults suite, drawn by `ui.Tester`.
//! Holes the page would show through are `tester.ctx.stage_rects[0..stage_count]`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");

pub const Options = struct {
    width: f32 = 1440,
    height: f32 = 900,
    scale: f32 = 2,
    dark: bool = false,
    sidebar: ?bool = null,
    /// Extra tabs opened after the first one.
    tabs: usize = 0,
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
};
