//! nanotrade, a mock trading app nanoui draws for the reel: the watchlist down the side (rows that glide when a re-sort
//! moves them, prices that ease to each tick), NVDA's header (its price
//! easing and flashing on each tick, a live dot breathing), the range tabs
//! whose marker slides, the chart, and the order panel that slides in,
//! with its quantity, its total easing, and Place order loading.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;
const trade = @import("trade.zig");
const chart = @import("trade_chart.zig");
const scenes = @import("scenes.zig");
const Director = scenes.Director;

const side_w: f32 = 250;
const panel_w: f32 = 300;

/// nanotrade's content in a `w` × `h` box (under the window's title bar).
pub fn content(c: *ui.Context, d: *Director, w: f32, h: f32) void {
    const th = c.theme;
    const up = th.success;
    const down = th.danger;
    const body = ui.div(c).row().w(w).h(h);
    defer body.end();
    sidebar(c, d, up, down);
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = th.border }, .none, null);
    main(c, d, up, down, w, h);
    order(c, d, w);
}

fn sidebar(c: *ui.Context, d: *Director, up: ui.Color, down: ui.Color) void {
    const th = c.theme;
    const s = ui.div(c).column().w(side_w).hFull().p(12).gap(4);
    defer s.end();
    ui.text(c, "WATCHLIST", .{ .size = 11, .weight = .semibold, .color = th.muted });
    const gap = ui.div(c).h(6);
    gap.end();
    var order_: [6]usize = undefined;
    if (d.sorted) d.market.byChange(&order_) else order_ = .{ 0, 1, 2, 3, 4, 5 };
    for (order_, 0..) |idx, i| {
        const sym = d.market.watch[idx];
        ui.key(c, sym.ticker);
        // In one after another as the window opens; gliding on a re-sort.
        const f = motion.frame(c, .{ .initial = .{ .x = -20, .opacity = 0 }, .delay = 0.3 + motion.stagger(i, 0.06), .layout = true, .transition = .{ .spring = .{ .stiffness = 230, .damping = 24 } } });
        const on = idx == 0;
        const row = ui.div(c).row().wFull().h(52).px(10).gap(10).itemsCenter().rounded(10).bg(if (on) th.accent.alpha(0.12) else th.background.alpha(0)).motion(f);
        defer row.end();
        {
            const names = ui.div(c).column().grow().gap(2);
            defer names.end();
            ui.text(c, sym.ticker, .{ .size = 14, .weight = .bold, .mono = true });
            ui.text(c, sym.name, .{ .size = 11.5, .color = th.muted });
        }
        const right = ui.div(c).column().itemsEnd().gap(3);
        defer right.end();
        ui.text(c, c.print("{d:.2}", .{motion.number(c, "p", sym.price, .{ .tween = .{ .duration = 0.3 } })}), .{ .size = 13, .weight = .medium, .mono = true });
        const col = if (sym.change >= 0) up else down;
        const pill = ui.div(c).px(6).py(1).rounded(5).bg(col.alpha(0.15));
        defer pill.end();
        ui.text(c, c.print("{s}{d:.2}%", .{ if (sym.change >= 0) "+" else "", sym.change }), .{ .size = 11, .weight = .semibold, .mono = true, .color = col });
    }
}

fn main(c: *ui.Context, d: *Director, up: ui.Color, down: ui.Color, w: f32, h: f32) void {
    const th = c.theme;
    const m = ui.div(c).column().grow().hFull().px(24).pt(18).gap(14);
    defer m.end();
    {
        const head = ui.div(c).row().wFull().gap(14).itemsEnd();
        defer head.end();
        {
            const names = ui.div(c).column().gap(4);
            defer names.end();
            const r = ui.div(c).row().gap(10).itemsCenter();
            {
                defer r.end();
                ui.text(c, "NVDA", .{ .size = 22, .weight = .bold, .mono = true });
                ui.text(c, "NVIDIA Corp · NASDAQ", .{ .size = 13, .color = th.muted });
                const pulse = motion.keyframes(c, .{ .values = &.{ .{ .scale = 1, .opacity = 1 }, .{ .scale = 1.6, .opacity = 0.35 }, .{ .scale = 1, .opacity = 1 } }, .duration = 1.3, .repeat = null });
                const dot = ui.div(c).w(8).h(8).roundedFull().bg(up).motion(pulse);
                dot.end();
                ui.text(c, "LIVE", .{ .size = 11, .weight = .bold, .color = up });
            }
            const pr = ui.div(c).row().gap(12).itemsEnd();
            defer pr.end();
            // The price eases to each tick and flashes its direction.
            const shown = motion.number(c, "nvda", d.market.price, .{ .tween = .{ .duration = 0.32, .ease = .ease_out } });
            const flash = motion.frame(c, .{ .target = .{ .background = (if (d.last_up) up else down).alpha(if (d.now - d.tick_at < 0.25) 0.22 else 0) }, .transition = .{ .tween = .{ .duration = 0.25 } } });
            const p = ui.div(c).px(6).rounded(6).motion(flash);
            {
                defer p.end();
                ui.text(c, c.print("{d:.2}", .{shown}), .{ .size = 40, .weight = .bold, .mono = true });
            }
            const ch = d.market.price - d.market.open;
            const col = if (ch >= 0) up else down;
            const pc = ui.div(c).pb(8);
            defer pc.end();
            ui.text(c, c.print("{s}{d:.2}  ({s}{d:.2}%)", .{ if (ch >= 0) "+" else "", ch, if (ch >= 0) "+" else "", ch / d.market.open * 100 }), .{ .size = 16, .weight = .semibold, .mono = true, .color = col });
        }
        ui.spacer(c);
        const tabs = ui.div(c).pb(8);
        defer tabs.end();
        _ = kit.tabs(c, &trade.ranges, &d.range, .{ .variant = .segmented, .size = .md });
        const gap = ui.div(c).w(6);
        gap.end();
        _ = kit.button(c, "Buy NVDA", .{ .variant = .primary, .icon = "plus", .size = .md });
    }
    chart.draw(c, .{ .market = &d.market, .range = d.range, .hover = d.crosshair, .up = up, .down = down }, w - side_w - 49, h - 128);
}

/// The order panel: it slides in from the right while open.
fn order(c: *ui.Context, d: *Director, w: f32) void {
    const th = c.theme;
    const f = motion.present(c, "order", d.order_open, .{ .initial = .{ .x = panel_w + 20, .opacity = 0.6 }, .exit = .{ .x = panel_w + 20 }, .transition = .{ .spring = .{ .stiffness = 260, .damping = 28 } } }) orelse return;
    const p = ui.div(c).absolute().offset(w - panel_w - 14, 14).w(panel_w).column().gap(14).p(18).rounded(14).bg(th.surface).border(th.border).shadow(.{ .color = th.shadow.alpha(1), .blur = 30, .y = 10 }).motion(f);
    defer p.end();
    {
        const h = ui.div(c).row().wFull().itemsCenter();
        defer h.end();
        ui.text(c, "Buy NVDA", .{ .size = 17, .weight = .bold });
        ui.spacer(c);
        _ = kit.iconButton(c, "xmark", .{ .size = .xs });
    }
    var kind: usize = 0;
    _ = kit.tabs(c, &.{ "Market", "Limit", "Stop" }, &kind, .{ .variant = .segmented, .size = .sm });
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, "Shares", .{ .size = 13, .color = th.muted });
        ui.spacer(c);
        _ = kit.numberInput(c, &d.qty, .{ .min = 1, .max = 500, .step = 10 });
    }
    line(c, "Price", c.print("{d:.2}", .{d.market.price}));
    const total = motion.number(c, "total", @floatCast(d.qty * d.market.price), .{ .tween = .{ .duration = 0.35, .ease = .ease_out } });
    line(c, "Estimated total", c.print("${d:.2}", .{total}));
    _ = kit.button(c, if (d.filled) "Filled" else if (d.placing) "Placing…" else "Place order", .{ .variant = if (d.filled) .success else .primary, .full_width = true, .loading = d.placing, .icon = if (d.filled) "checkmark" else "", .size = .lg });
    if (d.filled) {
        const pf = motion.frame(c, .{ .initial = .{ .y = 8, .opacity = 0 }, .transition = .{ .spring = motion.Spring.snappy } });
        const card = ui.div(c).column().wFull().gap(6).p(12).rounded(10).bg(th.success.alpha(0.1)).motion(pf);
        defer card.end();
        ui.text(c, c.print("Position · {d:.0} NVDA", .{d.qty}), .{ .size = 12.5, .weight = .semibold });
        const pnl = motion.number(c, "pnl", @floatCast((d.market.price - d.entry) * d.qty), .{ .tween = .{ .duration = 0.4 } });
        ui.text(c, c.print("{s}${d:.2} today", .{ if (pnl >= 0) "+" else "−", @abs(pnl) }), .{ .size = 15, .weight = .bold, .mono = true, .color = if (pnl >= 0) th.success else th.danger });
    }
}

fn line(c: *ui.Context, label: []const u8, value: []const u8) void {
    const th = c.theme;
    const r = ui.div(c).row().wFull().itemsCenter();
    defer r.end();
    ui.text(c, label, .{ .size = 13, .color = th.muted });
    ui.spacer(c);
    ui.text(c, value, .{ .size = 14, .weight = .semibold, .mono = true });
}
