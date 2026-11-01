//! The Performance & Memory HUD (⌥⇧⌘D): this window's frame timings, the
//! app's and WebKit's memory, and the tab in front's process, in a corner.
//! Nothing when off; when on, processes are asked about once a second and
//! the card is printed on the frame arena.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const footprint = @import("../sys/footprint.zig");
const sleep = @import("../web/sleep.zig");

pub const State = struct {
    shown: bool = false,
    /// Long ago: the first frame shown samples at once, whatever its clock.
    last_sample_at: f64 = -1e9,
    app_mb: f64 = 0,
    web_mb: f64 = 0,
    web_procs: u16 = 0,
    tab_pid: c_int = 0,
    tab_mb: f64 = 0,
};

pub fn toggle(b: *Browser) void {
    b.debug_hud.shown = !b.debug_hud.shown;
    b.debug_hud.last_sample_at = -1e9;
    // GPU and drawable timings come only from the surface's frame log.
    if (b.debug_hud.shown) if (b.window) |w| if (w.surface) |s| {
        if (s.frame_log == null) _ = s.recordFrames(b.gpa) catch null;
    };
    b.redraw();
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    // Scripted runs (`chord:`) reach only the view, not the menus.
    if (c.shortcut(.{ .key = 'd', .cmd = true, .alt = true, .shift = true })) toggle(b);
    if (!b.debug_hud.shown) return;
    const st = &b.debug_hud;
    if (c.time - st.last_sample_at >= 1.0) sample(b, st, c.time);
    // Live while shown, at a second's pace: an idle window still reads true.
    c.frameIn(@floatCast(@max(0.05, st.last_sample_at + 1.0 - c.time)));
    // The surface's last frame, a frame behind: its GPU time has landed.
    var last: ?[3]f64 = null;
    if (b.window) |w| if (w.surface) |s| if (s.frame_log) |*fl| {
        const n = fl.records.items.len;
        if (n >= 2) {
            const r = fl.records.items[n - 2];
            last = .{ r.gpu_ms, r.drawable_wait_ms, r.encode_ms };
        }
    };

    _ = c.open(.{
        .absolute = true,
        .fixed = true,
        .offset = .{ .x = @max(8, c.size.w - 348), .y = 48 },
        .width = .{ .px = 340 },
        .layer = 2,
        .direction = .column,
        .gap = 2,
        .background = p.ground.alpha(0.92),
        .border = p.hairline,
        .radius = 8,
        .padding = .xy(10, 8),
    }, null);
    defer c.end();
    const s = c.stats;
    line(c, p, c.print("build {d:.2} · layout {d:.2} · paint {d:.2} ms", .{ s.build_ms, s.layout_ms, s.paint_ms }));
    if (last) |r| line(c, p, c.print("gpu {d:.2} · wait {d:.2} · encode {d:.2} ms", .{ r[0], r[1], r[2] }));
    line(c, p, c.print("{d} nodes · {d} inst · {d} stages", .{ s.nodes, s.instances, c.stage_count }));
    line(c, p, c.print("animating {s} · frame_in {s} · {s}", .{ if (c.animating) "yes" else "no", if (c.frame_in != null) "yes" else "no", @tagName(c.time_driven) }));
    line(c, p, c.print("App {d:.0} MB · Web ({d} proc) {d:.0} MB", .{ st.app_mb, st.web_procs, st.web_mb }));
    if (b.activeTab()) |t| {
        line(c, p, c.print("Tab #{d} · PID {d} ({d:.0} MB)", .{ t.id, st.tab_pid, st.tab_mb }));
        line(c, p, c.print("wake: {s}", .{sleep.awake(b, t) orelse "eligible to sleep"}));
    }
    if (b.stage_host) |sh| line(c, p, c.print("stage slots {d}", .{sh.slots.items.len}));
}

fn line(c: *ui.Context, p: *const Palette, text: []const u8) void {
    ui.text(c, text, .{ .size = 11, .mono = true, .color = p.ink });
}

fn sample(b: *Browser, st: *State, now: f64) void {
    st.last_sample_at = now;
    st.app_mb = footprint.mb(std.c.getpid()) orelse 0;
    var pids: [64]c_int = undefined;
    var n: usize = 0;
    st.web_mb = 0;
    for (b.tabs.items) |t| {
        const pid = footprint.webPid(t.web) orelse continue;
        if (std.mem.indexOfScalar(c_int, pids[0..n], pid) != null or n == pids.len) continue;
        pids[n] = pid;
        n += 1;
        st.web_mb += footprint.mb(pid) orelse 0;
    }
    st.web_procs = @intCast(n);
    const front = if (b.activeTab()) |t| footprint.webPid(t.web) else null;
    st.tab_pid = front orelse 0;
    st.tab_mb = if (front) |pid| footprint.mb(pid) orelse 0 else 0;
    // ponytail: a log without a file only grows; keep the last ~2k frames.
    if (b.window) |w| if (w.surface) |s| if (s.frame_log) |*fl| {
        if (fl.path == null and fl.records.items.len > 2048) {
            fl.records.shrinkRetainingCapacity(0);
            fl.flushed = 0;
        }
    };
}
