//! nanotrade's chart: NVDA's candles and volume over a grid with prices,
//! the last price as a line and a label, and a crosshair with a readout
//! when the pointer is over it. Everything moves by `ui.motion`: candles
//! grow in one after another, morph when the range changes (each keeps its
//! place and springs to its new open and close), the price line follows
//! each tick, and the crosshair and readout chase the pointer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const trade = @import("trade.zig");

pub const Chart = struct {
    market: *const trade.Market,
    range: usize,
    /// Show the crosshair (the pointer is over the chart, in the script).
    hover: bool,
    up: ui.Color,
    down: ui.Color,
};

/// Draws the chart in a `w` × `h` box (the candles above, the volume below).
pub fn draw(c: *ui.Context, ch: Chart, w: f32, h: f32) void {
    const th = c.theme;
    const axis_w: f32 = 64;
    const vol_h: f32 = 64;
    const plot_w = w - axis_w;
    const plot_h = h - vol_h - 12;
    const box = ui.div(c).w(w).h(h).clip().control();
    const rect = box.interaction().rect;
    defer box.end();
    const b = ch.market.bounds(ch.range);
    const lo = b[0];
    const hi = b[1];
    const yOf = struct {
        fn f(p: f32, l: f32, hh: f32, ph: f32) f32 {
            return ph * (hh - p) / @max(hh - l, 0.01);
        }
    }.f;
    // The grid and its prices, easing to each range's.
    const shown_lo = motion.number(c, "lo", lo, .{ .spring = .{} });
    const shown_hi = motion.number(c, "hi", hi, .{ .spring = .{} });
    for (0..5) |k| {
        const f = @as(f32, @floatFromInt(k)) / 4;
        const y = f * plot_h;
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = y }, .width = .{ .px = plot_w }, .height = .{ .px = 1 }, .background = th.border.alpha(0.6) }, .none, null);
        const label = ui.div(c).absolute().offset(plot_w + 10, @max(0, y - 9));
        defer label.end();
        ui.text(c, c.print("{d:.2}", .{shown_hi - (shown_hi - shown_lo) * f}), .{ .size = 11, .mono = true, .color = th.muted });
    }
    // The candles: keyed by place, so a new range morphs them.
    const pitch = plot_w / @as(f32, trade.candles);
    const body_w = pitch * 0.62;
    for (ch.market.series[ch.range], 0..) |cd, i| {
        const x = @as(f32, @floatFromInt(i)) * pitch + (pitch - body_w) / 2;
        const rising = cd.close >= cd.open;
        const col = if (rising) ch.up else ch.down;
        const top = yOf(@max(cd.open, cd.close), lo, hi, plot_h);
        const len = @max(2, @abs(yOf(cd.open, lo, hi, plot_h) - yOf(cd.close, lo, hi, plot_h)));
        const wick_top = yOf(cd.high, lo, hi, plot_h);
        const wick_len = @max(2, yOf(cd.low, lo, hi, plot_h) - wick_top);
        const delay = motion.stagger(i, 0.012) + 0.35;
        const spring: motion.Transition = .{ .spring = .{ .stiffness = 210, .damping = 22 } };
        ui.key(c, c.print("wick-{d}", .{i}));
        const wf = motion.frame(c, .{ .target = .{ .y = wick_top, .height = wick_len, .background = col }, .initial = .{ .y = plot_h, .height = 0 }, .delay = delay, .transition = spring });
        const wick = ui.div(c).absolute().offset(x + body_w / 2 - 0.75, 0).w(1.5).motion(wf);
        wick.end();
        ui.key(c, c.print("body-{d}", .{i}));
        const bf = motion.frame(c, .{ .target = .{ .y = top, .height = len, .background = col }, .initial = .{ .y = plot_h, .height = 0 }, .delay = delay, .transition = spring });
        const body = ui.div(c).absolute().offset(x, 0).w(body_w).rounded(1.5).motion(bf);
        body.end();
        ui.key(c, c.print("vol-{d}", .{i}));
        const vh = cd.volume * (vol_h - 8);
        const vf = motion.frame(c, .{ .target = .{ .y = h - vh, .height = vh }, .initial = .{ .y = h, .height = 0 }, .delay = delay, .transition = spring });
        const vol = ui.div(c).absolute().offset(x, 0).w(body_w).rounded(1).bg(col.alpha(0.35)).motion(vf);
        vol.end();
    }
    // The last price: a line and its label, following each tick.
    const price = ch.market.price;
    const rising = price >= ch.market.open;
    const pc = if (rising) ch.up else ch.down;
    ui.key(c, "price-line");
    const lf = motion.frame(c, .{ .target = .{ .y = yOf(price, lo, hi, plot_h) }, .transition = .{ .spring = .{ .stiffness = 260, .damping = 26 } } });
    const line = ui.div(c).absolute().offset(0, 0).w(w).h(22).motion(lf);
    {
        defer line.end();
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = 0 }, .width = .{ .px = plot_w }, .height = .{ .px = 1 }, .background = pc.alpha(0.7) }, .none, null);
        const tag = ui.div(c).absolute().offset(plot_w + 4, -11).px(6).py(3).rounded(5).bg(pc);
        defer tag.end();
        ui.text(c, c.print("{d:.2}", .{motion.number(c, "price", price, .{ .tween = .{ .duration = 0.3 } })}), .{ .size = 11.5, .weight = .semibold, .mono = true, .color = th.background });
    }
    // The crosshair and its readout, chasing the pointer.
    const r = rect orelse return;
    const mx = c.input.mouse.x - r.x;
    const my = c.input.mouse.y - r.y;
    const inside = ch.hover and mx >= 0 and mx < plot_w and my >= 0 and my < plot_h;
    const idx: usize = @intFromFloat(std.math.clamp(@floor(mx / pitch), 0, trade.candles - 1));
    const cx = @as(f32, @floatFromInt(idx)) * pitch + pitch / 2;
    const cf = motion.present(c, "crosshair", inside, .{ .initial = .{ .opacity = 0 }, .exit = .{ .opacity = 0 }, .transition = .{ .tween = .{ .duration = 0.15 } } }) orelse return;
    const cross = ui.div(c).absolute().w(w).h(h).motion(cf);
    defer cross.end();
    ui.key(c, "vline");
    const vf = motion.frame(c, .{ .target = .{ .x = cx }, .transition = .{ .spring = motion.Spring.snappy } });
    const v = ui.div(c).absolute().offset(0, 0).w(1).h(plot_h).bg(th.text.alpha(0.35)).motion(vf);
    v.end();
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = @max(0, my) }, .width = .{ .px = plot_w }, .height = .{ .px = 1 }, .background = th.text.alpha(0.2) }, .none, null);
    const cd = ch.market.series[ch.range][idx];
    ui.key(c, "readout");
    const rf = motion.frame(c, .{ .target = .{ .x = std.math.clamp(cx + 14, 8, plot_w - 330), .y = 10 }, .transition = .{ .spring = motion.Spring.snappy } });
    const ro = ui.div(c).absolute().offset(0, 0).row().gap(12).px(12).py(7).rounded(8).bg(th.surface).border(th.border).shadow(.{ .color = th.shadow.alpha(0.5), .blur = 12, .y = 4 }).motion(rf);
    defer ro.end();
    const fields = [_]struct { []const u8, f32 }{ .{ "O", cd.open }, .{ "H", cd.high }, .{ "L", cd.low }, .{ "C", cd.close } };
    for (fields) |fv| {
        ui.key(c, fv[0]);
        const p = ui.div(c).row().gap(4);
        defer p.end();
        ui.text(c, fv[0], .{ .size = 12, .weight = .semibold, .color = th.muted });
        ui.text(c, c.print("{d:.2}", .{fv[1]}), .{ .size = 12, .mono = true, .color = if (cd.close >= cd.open) ch.up else ch.down });
    }
}
