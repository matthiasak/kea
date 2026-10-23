//! Liquid Glass, for the reel, the way iOS 26 asks it to be used: glass is
//! the control layer over content. A glass toolbar with a tinted lens that
//! slides between tabs; plain and prominent glass buttons that swell and
//! light up under a press (interactive glass); and a glass button that
//! morphs into a glass panel and back, its size and corners springing.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;
const Color = ui.Color;

pub const State = struct { tab: usize = 0, open: bool = false };

pub fn view(c: *ui.Context, s: *State, w: f32, h: f32) void {
    const th = c.theme;
    const root = ui.div(c).w(w).h(h).clip();
    defer root.end();
    // Content under the glass: a photo-like scene of color.
    const glows = [_]struct { f32, f32, f32, u24 }{ .{ -60, 120, 460, 0x6fb0a8 }, .{ 340, -80, 420, 0xe8a33d }, .{ 560, 220, 440, 0xd2674f }, .{ 180, 320, 380, 0xbd80e4 } };
    for (glows) |g| {
        const b = ui.div(c).absolute().offset(g[0], g[1]).w(g[2]).h(g[2]).roundedFull().bg(Color.hex(g[3]).alpha(0.85)).shadow(.{ .color = Color.hex(g[3]).alpha(0.9), .blur = 120 });
        b.end();
    }
    {
        const label = ui.div(c).absolute().offset(36, 120).column().gap(6);
        defer label.end();
        ui.text(c, "Kyoto, autumn", .{ .size = 34, .weight = .bold, .color = .white });
        ui.text(c, "214 photos · 12 albums", .{ .size = 16, .color = Color.white.alpha(0.85) });
    }
    // The toolbar: glass over the content, a tinted lens sliding.
    {
        const bar = ui.div(c).absolute().offset(24, 20).w(w - 48).h(64).row().itemsCenter().gap(10).px(10).roundedFull().glass(.{});
        defer bar.end();
        _ = kit.tabs(c, &.{ "Photos", "Albums", "Search" }, &s.tab, .{ .variant = .glass, .size = .md });
        ui.spacer(c);
        _ = kit.iconButton(c, "magnifyingglass", .{ .glass = true, .pill = true });
    }
    // Interactive glass: plain, and prominent (tinted).
    {
        const r = ui.div(c).absolute().offset(36, h - 92).row().gap(12);
        defer r.end();
        _ = kit.button(c, "Share", .{ .glass = true, .pill = true, .size = .lg, .icon = "square.and.arrow.up" });
        _ = kit.button(c, "Save", .{ .glass = true, .variant = .primary, .pill = true, .size = .lg, .icon = "heart.fill" });
    }
    // A button morphing into a panel: one pane of glass, its size, corners
    // and place springing, its rows coming in once it's open.
    const W: f32 = if (s.open) 280 else 64;
    const H: f32 = if (s.open) 220 else 64;
    const f = motion.frame(c, .{ .target = .{ .x = w - 24 - W, .y = h - 24 - H, .width = W, .height = H, .radius = if (s.open) 28 else 32 }, .transition = .{ .spring = .{ .stiffness = 260, .damping = 22 } } });
    const pane = ui.div(c).absolute().glass(.{ .tint = if (s.open) .transparent else th.accent.alpha(0.85) }).clip().motion(f);
    defer pane.end();
    if (motion.present(c, "plus", !s.open, .{ .initial = .{ .opacity = 0, .scale = 0.6 }, .exit = .{ .opacity = 0, .scale = 0.6 }, .transition = .{ .spring = motion.Spring.snappy } })) |pf| {
        const plus = ui.div(c).absolute().w(64).h(64).center().motion(pf);
        defer plus.end();
        ui.icon(c, "plus", .{ .size = 24, .weight = .semibold, .color = th.accent_text });
    }
    if (motion.present(c, "menu", s.open, .{ .initial = .{ .opacity = 0 }, .exit = .{ .opacity = 0 }, .transition = .{ .tween = .{ .duration = 0.15 } } })) |mf| {
        const menu = ui.div(c).absolute().w(280).h(220).column().p(16).gap(4).motion(mf);
        defer menu.end();
        {
            const head = ui.div(c).row().wFull().itemsCenter().pb(6);
            defer head.end();
            ui.text(c, "New", .{ .size = 15, .weight = .bold, .color = th.text });
            ui.spacer(c);
            ui.icon(c, "xmark", .{ .size = 13, .weight = .semibold, .color = th.muted });
        }
        const rows = [_][2][]const u8{ .{ "camera", "Take a photo" }, .{ "rectangle.stack.badge.plus", "New album" }, .{ "square.and.arrow.down", "Import" } };
        for (rows, 0..) |rw, i| {
            ui.key(c, rw[1]);
            const rf = motion.frame(c, .{ .initial = .{ .y = 10, .opacity = 0 }, .delay = 0.08 + motion.stagger(i, 0.06), .transition = .{ .spring = motion.Spring.snappy } });
            const row = ui.div(c).row().wFull().h(44).px(10).gap(12).itemsCenter().rounded(12).bg(Color.white.alpha(0.1)).motion(rf);
            defer row.end();
            ui.icon(c, rw[0], .{ .size = 16, .color = th.accent });
            ui.text(c, rw[1], .{ .size = 14.5, .weight = .medium, .color = th.text });
        }
    }
}
