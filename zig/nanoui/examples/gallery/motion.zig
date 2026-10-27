//! The gallery's Motion page: `ui.motion` at work. A card that grows on a
//! click and gives on a press, a toast that comes and goes, a list that
//! staggers in and glides when shuffled, a counter that counts, a dot that
//! breathes forever, and the easing curves side by side.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;

pub const Demo = struct {
    open: bool = false,
    toast: bool = false,
    /// The list's order, and a round that replays its entrance.
    order: [5]u8 = .{ 0, 1, 2, 3, 4 },
    round: u32 = 0,
    count: f32 = 0,
    /// The easings run to the right when on.
    played: bool = false,
    seed: u64 = 7,

    pub fn page(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const whole = ui.div(c).grow().hFull().clip();
        defer whole.end();
        d.content(c);
        // The toast, over the page at its bottom.
        if (motion.present(c, "toast", d.toast, .{
            .initial = .{ .y = 24, .opacity = 0, .scale = 0.96 },
            .exit = .{ .y = 24, .opacity = 0 },
            .transition = .{ .spring = motion.Spring.snappy },
        })) |f| {
            const t = ui.div(c).absolute().offset(28, c.size.h - 84).row().gap(10).itemsCenter().px(16).py(12).rounded(12).bg(th.text).shadow(.{ .color = .{ .a = 0.25 }, .blur = 18, .y = 6 }).motion(f);
            defer t.end();
            ui.icon(c, "checkmark.circle.fill", .{ .size = 15, .color = th.success });
            ui.text(c, "Saved. Click the button again to hide me.", .{ .color = th.background });
        }
    }

    fn content(d: *Demo, c: *ui.Context) void {
        const sc = ui.div(c).column().sizeFull().scrollY().p(if (@import("phone.zig").compact(c)) 16 else 28).gap(20);
        defer sc.end();
        ui.heading(c, "Motion");
        ui.text(c, "Springs and tweens, interruptible: click twice quickly and watch it turn.", .{ .wrap = true, .color = c.theme.muted });
        {
            // Side by side, or stacked on a phone.
            const wide = !@import("phone.zig").compact(c);
            const r = (if (wide) ui.div(c).row() else ui.div(c).column()).wFull().gap(16).itemsStart();
            defer r.end();
            d.card(c);
            d.counter(c);
        }
        d.list(c);
        d.easings(c);
    }

    fn card(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const box = ui.div(c).column().gap(12);
        defer box.end();
        ui.text(c, "Spring and press", .{ .weight = .semibold });
        const f = motion.frame(c, .{
            .target = .{ .width = if (d.open) 320 else 180, .height = if (d.open) 160 else 96, .radius = if (d.open) 24 else 14, .background = if (d.open) th.accent else th.surface },
            .initial = .{ .y = 12, .opacity = 0 },
            .press = .{ .scale = 0.96 },
            .hover = .{ .y = -2 },
            .transition = .{ .spring = motion.Spring.bouncy },
        });
        const k = ui.div(c).column().p(16).gap(6).border(th.border).clip().control().motion(f);
        defer k.end();
        if (k.clicked()) d.open = !d.open;
        ui.text(c, if (d.open) "Open" else "Click me", .{ .weight = .semibold, .color = if (d.open) th.accent_text else th.text });
        ui.text(c, "size, corners, color", .{ .size = 12, .color = if (d.open) th.accent_text else th.muted });
        if (ui.button(c, if (d.toast) "Hide the toast" else "Show a toast", .{}).clicked) d.toast = !d.toast;
    }

    fn counter(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const box = ui.div(c).column().gap(12);
        defer box.end();
        ui.text(c, "Numbers and loops", .{ .weight = .semibold });
        const shown = motion.number(c, "count", d.count, .{ .tween = .{ .duration = 0.8, .ease = .ease_out } });
        ui.text(c, c.print("{d:.0}", .{shown}), .{ .size = 40, .weight = .bold, .mono = true });
        const r = ui.div(c).row().gap(8).itemsCenter();
        defer r.end();
        if (ui.button(c, "+ 250", .{ .variant = .primary }).clicked) d.count += 250;
        if (ui.button(c, "Reset", .{ .variant = .ghost }).clicked) d.count = 0;
        // A dot breathing forever.
        const pulse = motion.keyframes(c, .{ .values = &.{ .{ .scale = 1, .opacity = 1 }, .{ .scale = 1.6, .opacity = 0.3 }, .{ .scale = 1, .opacity = 1 } }, .duration = 1.6, .repeat = null });
        const dot = ui.div(c).w(12).h(12).roundedFull().bg(th.danger).motion(pulse);
        dot.end();
        ui.label(c, "live");
    }

    fn list(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const box = ui.div(c).column().wFull().gap(10);
        defer box.end();
        {
            const r = ui.div(c).row().gap(8).itemsCenter();
            defer r.end();
            ui.text(c, "Stagger and layout", .{ .weight = .semibold });
            ui.spacer(c);
            if (ui.button(c, "Shuffle", .{}).clicked) d.shuffle();
            if (ui.button(c, "Replay", .{ .variant = .ghost }).clicked) d.round += 1;
        }
        const names = [_][]const u8{ "Springs keep their speed", "Tweens ease from where they are", "Presence waits for exits", "Layout glides to the new place", "Keyframes loop and yoyo" };
        const hues = [_]u24{ 0xe8453c, 0xf2a93b, 0x3fae5a, 0x2f6fd0, 0x8e44ad };
        for (d.order, 0..) |n, i| {
            ui.key(c, c.print("row-{d}-{d}", .{ d.round, n }));
            const f = motion.frame(c, .{
                .initial = .{ .x = -24, .opacity = 0 },
                .delay = motion.stagger(i, 0.06),
                .layout = true,
                .transition = .{ .spring = .{} },
            });
            const row = ui.div(c).row().wFull().gap(10).px(14).py(10).rounded(10).bg(th.surface).border(th.border).itemsCenter().motion(f);
            defer row.end();
            _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = .hex(hues[n]) }, .none, null);
            ui.text(c, names[n], .{});
        }
    }

    fn shuffle(d: *Demo) void {
        var prng = std.Random.DefaultPrng.init(d.seed);
        d.seed +%= 0x9e3779b97f4a7c15;
        prng.random().shuffle(u8, &d.order);
    }

    fn easings(d: *Demo, c: *ui.Context) void {
        const th = c.theme;
        const box = ui.div(c).column().wFull().gap(8);
        defer box.end();
        {
            const r = ui.div(c).row().gap(8).itemsCenter();
            defer r.end();
            ui.text(c, "Easings", .{ .weight = .semibold });
            ui.spacer(c);
            if (ui.button(c, "Play", .{}).clicked) d.played = !d.played;
        }
        const all = [_]struct { []const u8, motion.Easing }{
            .{ "linear", .linear },       .{ "ease out", .ease_out },   .{ "ease in out", .ease_in_out },
            .{ "back out", .back_out },   .{ "circ in out", .circ_in_out }, .{ "anticipate", .anticipate },
        };
        for (all) |e| {
            ui.key(c, e[0]);
            const r = ui.div(c).row().wFull().gap(10).itemsCenter().h(22);
            defer r.end();
            const l = ui.div(c).w(90);
            ui.text(c, e[0], .{ .size = 12, .color = th.muted, .mono = true });
            l.end();
            const track = ui.div(c).grow().h(4).rounded(2).bg(th.track);
            defer track.end();
            const f = motion.frame(c, .{ .target = .{ .x = if (d.played) 300 else 0 }, .transition = .{ .tween = .{ .duration = 1, .ease = e[1] } } });
            const dot = ui.div(c).absolute().offset(0, -5).w(14).h(14).roundedFull().bg(th.accent).motion(f);
            dot.end();
        }
    }
};
