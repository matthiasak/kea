//! Developer Tools strip, Web Developer quick controls, 120 Hz frame-pacing
//! sparkline, and docked-inspector auto-dodge for `debug_hud.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const inspector = @import("../web/inspector.zig");
const platform = @import("../sys/platform.zig");
const State = @import("debug_hud.zig").State;
const Tab = @import("../web/tab.zig").Tab;

pub const hist_len: usize = 96;

const ios_ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1";
const chrome_ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36";

pub const PacingStats = struct {
    fps: f32 = 0,
    p99_ms: f32 = 0,
    last_ms: f32 = 0,
    max_ms: f32 = 0,
};

/// Records new frame timings into `st`'s fixed ring buffer (0 heap allocs).
pub fn ingest(b: *Browser, c: *ui.Context, st: *State) void {
    if (st.last_ui_frame == c.frame) return;
    st.last_ui_frame = c.frame;

    if (comptime !platform.is_ios) {
        if (b.window) |w| if (w.surface) |s| if (s.frame_log) |*fl| {
            const recs = fl.records.items;
            // A frame behind: `gpu_ms` has landed by `n - 2`.
            const ready = if (recs.len >= 2) recs.len - 1 else 0;
            if (ready < st.last_rec_count) st.last_rec_count = 0;
            if (ready > st.last_rec_count) {
                const start = if (ready - st.last_rec_count > hist_len) ready - hist_len else st.last_rec_count;
                for (recs[start..ready]) |r| {
                    pushSample(
                        st,
                        @floatCast(r.cpuMs()),
                        @floatCast(r.gpu_ms),
                        @floatCast(r.drawable_wait_ms),
                        @floatCast(r.interval_ms),
                    );
                }
                const last = recs[ready - 1];
                st.last_gpu = .{ last.gpu_ms, last.drawable_wait_ms, last.encode_ms };
                st.last_rec_count = ready;
            }
            return;
        };
    }

    const cpu_ms: f32 = @floatCast(c.stats.build_ms + c.stats.layout_ms + c.stats.paint_ms);
    pushSample(st, cpu_ms, 0, 0, c.dt * 1000.0);
}

fn pushSample(st: *State, cpu_ms: f32, gpu_ms: f32, wait_ms: f32, interval_ms: f32) void {
    const idx: usize = st.hist_head;
    st.cpu_hist[idx] = @max(0, cpu_ms);
    st.gpu_hist[idx] = @max(0, gpu_ms);
    st.wait_hist[idx] = @max(0, wait_ms);
    st.frame_ms_hist[idx] = if (interval_ms > 0.1) interval_ms else 8.33;
    st.hist_head = @intCast((idx + 1) % hist_len);
    if (st.hist_len < hist_len) st.hist_len += 1;
}

/// Computes live FPS and p99 frame-work ms on the stack (0 heap allocs).
pub fn summaryStats(st: *const State) PacingStats {
    const n: usize = st.hist_len;
    if (n == 0) return .{};

    var totals: [hist_len]f32 = undefined;
    var active_sum: f32 = 0;
    var active_count: usize = 0;
    var last_ms: f32 = 0;
    var max_ms: f32 = 0;
    var last_interval: f32 = 8.33;

    const oldest = (@as(usize, st.hist_head) + hist_len - n) % hist_len;
    for (0..n) |i| {
        const idx = (oldest + i) % hist_len;
        const total = st.cpu_hist[idx] + st.gpu_hist[idx];
        totals[i] = total;
        last_ms = total;
        if (total > max_ms) max_ms = total;
        const iv = st.frame_ms_hist[idx];
        last_interval = iv;
        if (iv > 0.5 and iv < 150.0) {
            active_sum += iv;
            active_count += 1;
        }
    }

    std.mem.sort(f32, totals[0..n], {}, comptime std.sort.asc(f32));
    const p99_idx = @min(n - 1, (n * 99) / 100);
    const avg_iv = if (active_count > 0) active_sum / @as(f32, @floatFromInt(active_count)) else @max(8.33, last_interval);
    const fps = std.math.clamp(1000.0 / @max(1.0, avg_iv), 1.0, 240.0);
    return .{
        .fps = fps,
        .p99_ms = totals[p99_idx],
        .last_ms = last_ms,
        .max_ms = max_ms,
    };
}

pub fn budgetColor(p: *const Palette, ms: f32) ui.Color {
    if (ms <= 8.33) return p.safe;
    if (ms <= 16.67) return p.unsafe;
    return p.red;
}

/// Renders the 44pt 120 Hz frame-pacing sparkline card.
pub fn sparkline(c: *ui.Context, p: *const Palette, st: *const State) void {
    const stats = summaryStats(st);
    ui.column(c, .{ .width = .fill, .gap = 3 });
    defer ui.end(c);

    ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 6 });
    ui.text(c, "120 Hz Pacing", .{ .size = 10.5, .weight = .medium, .color = p.muted });
    ui.spacer(c);
    if (st.hist_len > 0) {
        ui.textf(c, .{ .size = 10.5, .mono = true, .tabular = true, .color = budgetColor(p, stats.p99_ms) }, "{d:.0} fps · p99 {d:.1} ms", .{ stats.fps, stats.p99_ms });
    } else {
        ui.text(c, "sampling…", .{ .size = 10.5, .mono = true, .color = p.faint });
    }
    ui.end(c);

    const frame = c.open(.{
        .width = .fill,
        .height = .{ .px = 44 },
        .radius = 6,
        .clip = true,
        .background = p.wash.alpha(0.6),
        .border = p.hairline.alpha(0.75),
    }, "kea.debug_hud.spark");
    defer c.end();
    _ = frame;

    const cv = ui.canvas(c, .{ .width = .fill, .height = .fill });
    const w: f32 = if (cv.size.w > 1) cv.size.w else 348;
    const h: f32 = if (cv.size.h > 1) cv.size.h else 44;
    const scale_max: f32 = @max(20.0, stats.max_ms * 1.15);
    const usable_h: f32 = @max(4.0, h - 4.0);

    const y16 = h - 1.0 - (16.67 / scale_max) * usable_h;
    if (y16 >= 2.0 and y16 <= h - 2.0) {
        cv.line(.{ .x = 0, .y = y16 }, .{ .x = w, .y = y16 }, .{ .width = 1, .color = p.unsafe.alpha(0.35), .dash = .{ 4, 3 } });
        cv.text(.{ .x = @max(2, w - 24), .y = @max(8, y16 - 2) }, "16.7", .{ .size = 8, .mono = true, .color = p.unsafe.alpha(0.65) });
    }

    const y8 = h - 1.0 - (8.33 / scale_max) * usable_h;
    if (y8 >= 2.0 and y8 <= h - 2.0) {
        cv.line(.{ .x = 0, .y = y8 }, .{ .x = w, .y = y8 }, .{ .width = 1, .color = p.safe.alpha(0.45), .dash = .{ 4, 3 } });
        cv.text(.{ .x = @max(2, w - 20), .y = @max(8, y8 - 2) }, "8.3", .{ .size = 8, .mono = true, .color = p.safe.alpha(0.75) });
    }

    const n: usize = st.hist_len;
    if (n == 0) return;
    const slot_w = w / @as(f32, hist_len);
    const bar_w = @max(1.25, slot_w - 0.75);
    const oldest = (@as(usize, st.hist_head) + hist_len - n) % hist_len;
    for (0..n) |i| {
        const idx = (oldest + i) % hist_len;
        const slot: f32 = @floatFromInt(hist_len - n + i);
        const bx = slot * slot_w;
        const cpu = st.cpu_hist[idx];
        const gpu = st.gpu_hist[idx];
        const total = cpu + gpu;
        const col = budgetColor(p, total);

        const cpu_h = std.math.clamp((cpu / scale_max) * usable_h, if (cpu > 0.01) @as(f32, 1.0) else 0.0, usable_h);
        if (cpu_h > 0) {
            cv.rect(.{ .x = bx, .y = h - 1.0 - cpu_h, .w = bar_w, .h = cpu_h }, col.alpha(0.88), 0.75);
        }
        if (gpu > 0.05) {
            const gpu_h = std.math.clamp((gpu / scale_max) * usable_h, 1.0, @max(0.0, usable_h - cpu_h));
            if (gpu_h > 0) {
                cv.rect(.{ .x = bx, .y = h - 1.0 - cpu_h - gpu_h, .w = bar_w, .h = gpu_h }, p.blue.alpha(0.85), 0.75);
            }
        }
    }
}

/// Interactive Web Inspector strip (macOS only when a live page is inspectable).
pub fn devToolsBar(b: *Browser, c: *ui.Context, p: *const Palette, interactive: bool) void {
    if (comptime platform.is_ios) return;
    if (!inspector.canInspect(b)) return;

    const vis = inspector.isVisible(b);
    const picking = inspector.isPickingElement(b);
    const profiling = inspector.isProfiling(b);
    const attached = inspector.isAttached(b);

    ui.row(c, .{ .width = .fill, .gap = 4, .align_items = .center });
    defer ui.end(c);

    if (toolPill(c, p, "Inspector", vis, p.blue, "Web Inspector   ⌥⌘I", interactive, false).clicked) {
        inspector.toggleInspector(b);
    }
    if (toolPill(c, p, "Pick", picking, p.sunset, "Inspect Element   ⌥⌘C", interactive, false).clicked) {
        inspector.inspectElement(b);
    }
    if (toolPill(c, p, "Console", false, p.blue, "JavaScript Console   ⌥⌘J", interactive, false).clicked) {
        inspector.showConsole(b);
    }
    if (toolPill(c, p, "Sources", false, p.blue, "Page Source   ⌥⌘U", interactive, false).clicked) {
        inspector.showPageSource(b);
    }
    if (toolPill(c, p, "Profile", profiling, p.red, "Toggle Timeline Profiling", interactive, profiling).clicked) {
        inspector.toggleProfiling(b);
    }
    if (vis) {
        ui.spacer(c);
        const dock_label = if (attached) "Detach" else "Dock";
        const dock_help = if (attached) "Detach Inspector to Window" else "Dock Inspector to Tab";
        if (toolPill(c, p, dock_label, false, p.teal, dock_help, interactive, false).clicked) {
            inspector.toggleAttach(b);
        }
    }
}

/// Quick Web Developer controls for the active tab: hard reload, UA switcher, zoom.
pub fn webControlsBar(b: *Browser, c: *ui.Context, p: *const Palette, st: *State, interactive: bool) void {
    _ = st;
    const t = b.activeTab() orelse return;
    ui.row(c, .{ .width = .fill, .gap = 4, .align_items = .center });
    defer ui.end(c);

    if (toolPill(c, p, "Hard Reload", false, p.blue, "Reload Bypassing Cache", interactive, false).clicked) {
        t.reload(true);
    }

    const ua_mode = tabUaMode(t);
    const ua_label: []const u8 = switch (ua_mode) {
        0 => "UA: Default",
        1 => "UA: iOS",
        2 => "UA: Chrome",
        else => "UA: Default",
    };
    if (toolPill(c, p, ua_label, ua_mode != 0, p.orange, "Cycle User-Agent & Reload", interactive, false).clicked) {
        const next: u2 = @intCast((@as(u8, ua_mode) + 1) % 3);
        if (t.web == null and !b.kea.opts.headless and t.isBlank()) t.build();
        if (t.web) |wv| {
            if (objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("setCustomUserAgent:")})) {
                const ua: ?objc.Object = switch (next) {
                    1 => objc.nsString(ios_ua),
                    2 => objc.nsString(chrome_ua),
                    else => null,
                };
                objc.msg(void, wv, "setCustomUserAgent:", .{ua});
            }
            if (!t.isBlank()) t.reload(false);
            c.changed = true;
        }
    }

    ui.spacer(c);

    if (miniBtn(c, p, "−", "Zoom Out", interactive).clicked) t.magnifyBy(1.0 / 1.1);
    const zoomed = @abs(t.zoom - 1.0) > 0.01;
    const zoom_txt = c.print("{d:.0}%", .{@round(t.zoom * 100.0)});
    if (toolPill(c, p, zoom_txt, zoomed, p.blue, "Reset Page Zoom", interactive, false).clicked) {
        t.resetZoom();
    }
    if (miniBtn(c, p, "+", "Zoom In", interactive).clicked) t.magnifyBy(1.1);
}

fn tabUaMode(t: *const Tab) u2 {
    const wv = t.web orelse return 0;
    if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("customUserAgent")})) return 0;
    const cur = objc.fromNSString(objc.msg(?objc.Object, wv, "customUserAgent", .{}));
    if (std.mem.eql(u8, cur, ios_ua)) return 1;
    if (std.mem.eql(u8, cur, chrome_ua)) return 2;
    return 0;
}

/// Auto-dodges a right-docked `_WKInspector` when the HUD has not been manually dragged.
pub fn autoDodgeX(b: *Browser, c: *ui.Context, def_x: f32, def_y: f32, hud_w: f32, card_h_est: f32, left_corner: bool) f32 {
    if (comptime platform.is_ios) return def_x;
    if (!inspector.isAttached(b)) return def_x;

    const wv: ?objc.Object = blk: {
        if (b.peek_tab) |pt| if (inspector.isAttachedFor(pt.web)) break :blk pt.web;
        if (b.web_panel_tab) |wt| if (inspector.isAttachedFor(wt.web)) break :blk wt.web;
        if (b.activeTab()) |t| if (inspector.isAttachedFor(t.web)) break :blk t.web;
        break :blk null;
    };
    const insp_wv = inspector.inspectorWebViewFor(wv) orelse return def_x;
    const win = b.window orelse return def_x;
    const s = win.surface orelse return def_x;
    if (objc.msg(?objc.Object, insp_wv, "window", .{}) == null) return def_x;

    const bounds = objc.msg(objc.CGRect, insp_wv, "bounds", .{});
    const r = objc.msg(objc.CGRect, insp_wv, "convertRect:toView:", .{ bounds, @as(?objc.Object, s.nsview) });
    const ir: ui.Rect = .{
        .x = @floatCast(r.origin.x),
        .y = @floatCast(r.origin.y),
        .w = @floatCast(r.size.width),
        .h = @floatCast(r.size.height),
    };
    if (ir.w <= 1 or ir.h <= 1) return def_x;

    const overlaps = ir.x < def_x + hud_w and ir.x + ir.w > def_x and ir.y < def_y + card_h_est and ir.y + ir.h > def_y;
    if (!overlaps) return def_x;

    if (!left_corner) {
        const left_of = ir.x - hud_w - 12;
        if (left_of >= 12) return left_of;
        if (ir.x > 12 + hud_w) return 12;
        return @max(8, left_of);
    }
    const right_of = ir.x + ir.w + 12;
    if (right_of + hud_w <= c.size.w - 12) return right_of;
    return def_x;
}

fn toolPill(
    c: *ui.Context,
    p: *const Palette,
    label: []const u8,
    active: bool,
    accent: ui.Color,
    help_text: []const u8,
    interactive: bool,
    pulse_dot: bool,
) ui.Interaction {
    const i = c.open(.{
        .direction = .row,
        .gap = 4,
        .padding = .xy(6, 3.5),
        .radius = 6,
        .align_items = .center,
        .control = true,
    }, null);
    defer c.end();
    const nid = c.node(i).id;
    const it = if (interactive) c.interact(i, .{}) else no_press;
    if (interactive and help_text.len > 0) c.help(i, help_text);
    c.addA11y(i, .button, label, "", active, interactive);

    const h = motion.quickTo(c, nid, 0, if (it.hovered) 1 else 0);
    const on_t = motion.quickTo(c, nid, 1, if (active) 1 else 0);
    const s = &c.node(i).style;
    s.background = p.wash.mix(p.hover, h).mix(accent.alpha(0.16), on_t);
    s.border = if (active) accent.alpha(0.45) else p.hairline.alpha(0.45 + 0.45 * h);

    if (pulse_dot) {
        _ = c.leaf(.{
            .width = .{ .px = 5 },
            .height = .{ .px = 5 },
            .radius = 2.5,
            .background = accent,
            .pulse = .{ .period = 1.1, .scale_amp = 0.2, .alpha_low = 0.3 },
        }, .none, null);
    }
    ui.text(c, label, .{
        .size = 10.5,
        .weight = if (active) .semibold else .medium,
        .color = p.ink.mix(accent, on_t),
    });
    return it;
}

fn miniBtn(c: *ui.Context, p: *const Palette, label: []const u8, help_text: []const u8, interactive: bool) ui.Interaction {
    const i = c.open(.{
        .width = .{ .px = 20 },
        .height = .{ .px = 20 },
        .radius = 5,
        .align_items = .center,
        .justify = .center,
        .control = true,
    }, null);
    defer c.end();
    const nid = c.node(i).id;
    const it = if (interactive) c.interact(i, .{}) else no_press;
    if (interactive) c.help(i, help_text);
    c.addA11y(i, .button, help_text, "", false, interactive);
    const h = motion.quickTo(c, nid, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = p.wash.mix(p.hover, h);
    c.node(i).style.border = p.hairline.alpha(0.45 + 0.45 * h);
    ui.text(c, label, .{ .size = 11, .weight = .medium, .color = p.muted.mix(p.ink, h) });
    return it;
}

const no_press: ui.Interaction = .{ .id = 0, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };
