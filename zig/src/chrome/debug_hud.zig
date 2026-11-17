//! The Performance & DevTools HUD (⌥⇧⌘D): 120 Hz frame-pacing sparkline,
//! one-click Web Inspector & developer controls, memory/process telemetry,
//! draggable placement, and docked-inspector auto-dodge.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const card_design = @import("../design/card.zig");
const controls = @import("controls.zig");
const plate = @import("controls_plate.zig");
const presence = @import("presence.zig");
const inspector = @import("../web/inspector.zig");
const footprint = @import("../sys/footprint.zig");
const sleep = @import("../web/sleep.zig");
const platform = @import("../sys/platform.zig");
const tools = @import("debug_hud_tools.zig");

pub const State = struct {
    shown: bool = false,
    left_corner: bool = false,
    compact: bool = false,
    copied_until: f64 = 0,
    /// Long ago: the first frame shown samples at once, whatever its clock.
    last_sample_at: f64 = -1e9,
    last_gpu: ?[3]f64 = null,
    app_mb: f64 = 0,
    web_mb: f64 = 0,
    web_procs: u16 = 0,
    tab_pid: c_int = 0,
    tab_mb: f64 = 0,
    pos_x: ?f32 = null,
    pos_y: ?f32 = null,
    drag_active: bool = false,
    drag_grab_dx: f32 = 0,
    drag_grab_dy: f32 = 0,
    last_win_w: f32 = 0,
    cpu_hist: [tools.hist_len]f32 = @splat(0),
    gpu_hist: [tools.hist_len]f32 = @splat(0),
    wait_hist: [tools.hist_len]f32 = @splat(0),
    frame_ms_hist: [tools.hist_len]f32 = @splat(0),
    hist_head: u8 = 0,
    hist_len: u8 = 0,
    last_rec_count: usize = 0,
    last_ui_frame: u64 = 0,
};

pub fn toggle(b: *Browser) void {
    b.debug_hud.shown = !b.debug_hud.shown;
    b.debug_hud.last_sample_at = -1e9;
    if (!b.debug_hud.shown) b.debug_hud.drag_active = false;
    // GPU and drawable timings come only from the surface's frame log.
    if (comptime !platform.is_ios) {
        if (b.debug_hud.shown) if (b.window) |w| if (w.surface) |s| {
            if (s.frame_log == null) _ = s.recordFrames(b.gpa) catch null;
        };
    }
    b.redraw();
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    // Scripted runs (`chord:`) reach only the view, not the menus.
    if (c.shortcut(.{ .key = 'd', .cmd = true, .alt = true, .shift = true })) toggle(b);
    const st = &b.debug_hud;
    const card_id = c.peekId("kea.debug_hud");
    const v = presence.presence(c, card_id, st.shown, motion.settle, null) orelse {
        st.drag_active = false;
        return;
    };
    const o = std.math.clamp(v, 0, 1);

    if (st.shown) {
        tools.ingest(b, c, st);
        if (c.time - st.last_sample_at >= 1.0) sample(b, st, c.time);
        // Live while shown, at a second's pace: an idle window still reads true.
        c.frameIn(@floatCast(@max(0.05, st.last_sample_at + 1.0 - c.time)));
    }

    const hud_w: f32 = if (c.size.w > 0) @min(368, @max(240, c.size.w - 16)) else 368;
    const max_x = @max(8, c.size.w - hud_w - 8);
    const max_y = @max(8, c.size.h - 48);
    const corner_x: f32 = if (st.left_corner) 12 else @max(8, c.size.w - hud_w - 12);
    const card_h_est: f32 = if (st.compact) 42 else 290;
    const auto_x: f32 = if (st.pos_x == null) tools.autoDodgeX(b, c, corner_x, 48, hud_w, card_h_est, st.left_corner) else corner_x;
    const target_x = std.math.clamp(st.pos_x orelse auto_x, 8, max_x);
    const target_y = std.math.clamp(st.pos_y orelse 48, 8, max_y);

    const win_resized = st.last_win_w != 0 and st.last_win_w != c.size.w;
    st.last_win_w = c.size.w;
    if (st.drag_active or v == 0 or (win_resized and st.pos_x == null)) {
        ui.jump(c, card_id, 1, target_x);
        ui.jump(c, card_id, 2, target_y);
    }
    const cur_x = motion.settleTo(c, card_id, 1, target_x);
    const cur_y = motion.settleTo(c, card_id, 2, target_y);

    const card_box = c.open(.{
        .absolute = true,
        .fixed = true,
        .offset = .{ .x = cur_x, .y = cur_y - (1 - o) * 6 },
        .width = .{ .px = hud_w },
        .layer = 2,
        .direction = .column,
        .gap = 6,
        .background = p.ground.alpha(0.95),
        .border = p.hairline,
        .radius = 11,
        .shadow = card_design.swiftShadow(0.14, 16, 4),
        .padding = .xy(10, 8),
        .opacity = o,
        .scale = 0.98 + 0.02 * o,
        .group = true,
        .clip = true,
    }, "kea.debug_hud");
    defer c.end();
    if (st.shown) _ = c.interact(card_box, .{});

    const s = c.stats;
    const line1 = c.print("build {d:.2} · layout {d:.2} · paint {d:.2} ms", .{ s.build_ms, s.layout_ms, s.paint_ms });
    const line2 = if (st.last_gpu) |r| c.print("gpu {d:.2} · wait {d:.2} · encode {d:.2} ms", .{ r[0], r[1], r[2] }) else null;
    const line3 = c.print("{d} nodes · {d} inst · {d} stages", .{ s.nodes, s.instances, c.stage_count });
    const line4 = c.print("animating {s} · frame_in {s} · {s}", .{ if (c.animating) "yes" else "no", if (c.frame_in != null) "yes" else "no", @tagName(c.time_driven) });
    const line5 = c.print("App {d:.0} MB · Web ({d} proc) {d:.0} MB", .{ st.app_mb, st.web_procs, st.web_mb });
    const active = b.activeTab();
    const line6 = if (active) |t| c.print("Tab #{d} · PID {d} ({d:.0} MB)", .{ t.id, st.tab_pid, st.tab_mb }) else null;
    const line7 = if (active) |t| c.print("wake: {s}", .{sleep.awake(b, t) orelse "eligible to sleep"}) else null;
    const line8 = if (b.stage_host) |sh| c.print("stage slots {d}", .{sh.slots.items.len}) else null;

    header(b, c, p, st, card_id, cur_x, cur_y, hud_w, max_x, max_y, &.{
        line1, line2, line3, line4, line5, line6, line7, line8,
    });

    if (st.compact) return;

    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = p.hairline }, .none, null);
    tools.sparkline(c, p, st);
    tools.devToolsBar(b, c, p, st.shown);
    tools.webControlsBar(b, c, p, st, st.shown);
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = p.hairline }, .none, null);

    ui.column(c, .{ .width = .fill, .gap = 2, .selectable = true });
    line(c, p, line1);
    if (line2) |l| line(c, p, l);
    line(c, p, line3);
    line(c, p, line4);
    line(c, p, line5);
    if (line6) |l| line(c, p, l);
    if (line7) |l| line(c, p, l);
    if (line8) |l| line(c, p, l);
    ui.end(c);
}

fn header(
    b: *Browser,
    c: *ui.Context,
    p: *const Palette,
    st: *State,
    card_id: u64,
    cur_x: f32,
    cur_y: f32,
    hud_w: f32,
    max_x: f32,
    max_y: f32,
    lines: *const [8]?[]const u8,
) void {
    const head = c.open(.{ .direction = .row, .width = .fill, .gap = 4, .align_items = .center, .control = true }, "kea.debug_hud.head");
    defer c.end();
    if (st.shown) {
        const hit = c.interact(head, .{});
        if (hit.double_clicked) {
            st.drag_active = false;
            st.compact = !st.compact;
            c.changed = true;
        } else if (hit.pressed) {
            if (!st.drag_active) {
                st.drag_active = true;
                const r = c.rects.get(card_id) orelse ui.Rect{ .x = cur_x, .y = cur_y, .w = hud_w, .h = 40 };
                st.drag_grab_dx = c.input.mouse.x - r.x;
                st.drag_grab_dy = c.input.mouse.y - r.y;
            }
            const nx = std.math.clamp(c.input.mouse.x - st.drag_grab_dx, 8, max_x);
            const ny = std.math.clamp(c.input.mouse.y - st.drag_grab_dy, 8, max_y);
            if (st.pos_x == null or @abs(st.pos_x.? - nx) > 0.25 or st.pos_y == null or @abs(st.pos_y.? - ny) > 0.25) {
                st.pos_x = nx;
                st.pos_y = ny;
                c.changed = true;
            }
            c.cursor = .closed_hand;
        } else {
            st.drag_active = false;
            if (c.hot == hit.id) c.cursor = .open_hand;
        }
    }

    if (st.compact) {
        ui.text(c, "Perf", .{ .size = 11.5, .weight = .semibold, .color = p.ink });
        if (st.hist_len > 0) {
            const ps = tools.summaryStats(st);
            ui.textf(c, .{ .size = 10.5, .mono = true, .tabular = true, .color = tools.budgetColor(p, ps.p99_ms) }, "{d:.0}fps·{d:.1}ms", .{ ps.fps, ps.p99_ms });
        }
        if (comptime !platform.is_ios) {
            if (inspector.canInspect(b)) {
                if (controls.door(c, p, "wrench.and.screwdriver", .{ .on = inspector.isVisible(b), .help = "Web Inspector   ⌥⌘I" }).clicked and st.shown) {
                    inspector.toggleInspector(b);
                }
                if (controls.door(c, p, "terminal", .{ .help = "JavaScript Console   ⌥⌘J" }).clicked and st.shown) {
                    inspector.showConsole(b);
                }
            }
        }
    } else {
        ui.text(c, "Perf & DevTools", .{ .size = 11.5, .weight = .semibold, .color = p.ink });
    }
    ui.spacer(c);

    const copied = c.time < st.copied_until;
    if (copied and st.shown) c.frameIn(@floatCast(st.copied_until - c.time));
    if (plate.quick(c, p, if (copied) "Copied" else "Copy", null).clicked and st.shown) {
        const full = c.print("{s}\n{s}{s}\n{s}\n{s}\n{s}{s}{s}", .{
            lines[0].?,
            if (lines[1]) |l| c.print("{s}\n", .{l}) else "",
            lines[2].?,
            lines[3].?,
            lines[4].?,
            if (lines[5]) |l| c.print("{s}\n", .{l}) else "",
            if (lines[6]) |l| c.print("{s}\n", .{l}) else "",
            lines[7] orelse "",
        });
        b.kea.writeClipboard(std.mem.trimEnd(u8, full, "\n"));
        st.copied_until = c.time + 1.5;
        c.frameIn(1.5);
        c.changed = true;
    }
    if (controls.door(c, p, if (st.compact) "chevron.down" else "chevron.up", .{ .on = st.compact, .help = if (st.compact) "Expand HUD" else "Compact HUD" }).clicked and st.shown) {
        st.compact = !st.compact;
        c.changed = true;
    }
    if (controls.door(c, p, if (st.left_corner) "arrow.right.to.line" else "arrow.left.to.line", .{ .help = if (st.left_corner) "Snap to Top Right" else "Snap to Top Left" }).clicked and st.shown) {
        st.pos_x = null;
        st.pos_y = null;
        st.left_corner = !st.left_corner;
        c.changed = true;
    }
    if (controls.door(c, p, "xmark", .{ .help = "Close HUD" }).clicked and st.shown) {
        st.shown = false;
        st.drag_active = false;
        c.changed = true;
    }
}

fn line(c: *ui.Context, p: *const Palette, text: []const u8) void {
    ui.text(c, text, .{ .size = 11, .mono = true, .color = p.ink });
}

fn sample(b: *Browser, st: *State, now: f64) void {
    st.last_sample_at = now;
    st.app_mb = footprint.mb(std.c.getpid()) orelse 0;
    var pids: [256]c_int = undefined;
    var n: usize = 0;
    st.web_mb = 0;
    const addWeb = struct {
        fn add(wv: ?nanoui.objc.Object, list: *[256]c_int, count: *usize, sum: *f64) void {
            const pid = footprint.webPid(wv) orelse return;
            if (std.mem.indexOfScalar(c_int, list[0..count.*], pid) != null or count.* == list.len) return;
            list[count.*] = pid;
            count.* += 1;
            sum.* += footprint.mb(pid) orelse 0;
        }
    }.add;
    for (b.tabs.items) |t| addWeb(t.web, &pids, &n, &st.web_mb);
    for (b.parked.values()) |sp| for (sp.tabs.items) |t| addWeb(t.web, &pids, &n, &st.web_mb);
    if (b.peek_tab) |pt| addWeb(pt.web, &pids, &n, &st.web_mb);
    if (b.web_panel_tab) |wt| addWeb(wt.web, &pids, &n, &st.web_mb);
    st.web_procs = @intCast(n);
    const front = if (b.activeTab()) |t| footprint.webPid(t.web) else null;
    st.tab_pid = front orelse 0;
    st.tab_mb = if (front) |pid| footprint.mb(pid) orelse 0 else 0;
    // ponytail: a log without a file only grows; keep the last ~2k frames.
    if (comptime !platform.is_ios) {
        if (b.window) |w| if (w.surface) |s| if (s.frame_log) |*fl| {
            if (fl.path == null and fl.records.items.len > 2048) {
                fl.records.shrinkRetainingCapacity(0);
                fl.flushed = 0;
            }
        };
    }
}
