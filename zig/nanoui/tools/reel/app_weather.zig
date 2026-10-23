//! A weather app on Liquid Glass, for the reel: panes of glass over soft
//! glowing color, glass tabs whose tinted lens slides to the day chosen,
//! the temperature counting to the day's, its icon swapping (presence),
//! and the hourly bars morphing to the new day's (springs).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;

const Day = struct { temp: f32, icon: []const u8, sky: []const u8, hours: [8]f32, humidity: f32, wind: f32 };

const days = [_]Day{
    .{ .temp = 31, .icon = "sun.max.fill", .sky = "Sunny", .hours = .{ 27, 28, 30, 31, 32, 31, 29, 28 }, .humidity = 64, .wind = 9 },
    .{ .temp = 28, .icon = "cloud.sun.fill", .sky = "Partly cloudy", .hours = .{ 26, 26, 27, 28, 28, 27, 27, 26 }, .humidity = 71, .wind = 14 },
    .{ .temp = 25, .icon = "cloud.rain.fill", .sky = "Showers", .hours = .{ 25, 24, 24, 25, 26, 24, 23, 23 }, .humidity = 88, .wind = 21 },
};

pub const State = struct { day: usize = 0 };

pub fn view(c: *ui.Context, s: *State, w: f32, h: f32) void {
    const th = c.theme;
    const d = days[s.day];
    const root = ui.div(c).w(w).h(h).clip();
    defer root.end();
    // The sky: soft glows of color for the glass to bend and frost.
    const glows = [_]struct { f32, f32, f32, u24 }{ .{ 80, 60, 420, 0xe8a33d }, .{ 620, 40, 380, 0xd2674f }, .{ 380, 320, 460, 0x6fb0a8 }, .{ 820, 330, 300, 0xbd80e4 } };
    for (glows) |g| {
        const b = ui.div(c).absolute().offset(g[0], g[1]).w(g[2]).h(g[2]).roundedFull().bg(Color.hex(g[3]).alpha(0.75)).shadow(.{ .color = Color.hex(g[3]).alpha(0.9), .blur = 140 });
        b.end();
    }
    const content = ui.div(c).absolute().w(w).h(h).column().p(28).gap(18);
    defer content.end();
    {
        const top = ui.div(c).row().wFull().itemsCenter();
        defer top.end();
        const city = ui.div(c).column().gap(2);
        {
            defer city.end();
            ui.text(c, "Singapore", .{ .size = 26, .weight = .bold, .color = th.text });
            ui.text(c, "Updated just now", .{ .size = 13, .color = th.muted });
        }
        ui.spacer(c);
        _ = kit.tabs(c, &.{ "Today", "Tomorrow", "Weekend" }, &s.day, .{ .variant = .glass, .size = .md });
    }
    const row = ui.div(c).row().wFull().gap(18).grow();
    defer row.end();
    {
        // The day: its temperature counting to the new one, its icon swapped.
        const card = ui.div(c).column().w(340).hFull().p(24).gap(10).rounded(28).glass(.{});
        defer card.end();
        const icons = ui.div(c).w(70).h(70);
        {
            defer icons.end();
            for (days, 0..) |dd, i| {
                if (motion.present(c, c.print("icon-{d}", .{i}), s.day == i, .{ .initial = .{ .scale = 0.6, .opacity = 0, .y = 10 }, .exit = .{ .scale = 0.6, .opacity = 0 }, .transition = .{ .spring = motion.Spring.bouncy } })) |f| {
                    const ic = ui.div(c).absolute().w(70).h(70).center().motion(f);
                    defer ic.end();
                    ui.icon(c, dd.icon, .{ .size = 56, .color = th.accent });
                }
            }
        }
        const temp = motion.number(c, "temp", d.temp, .{ .tween = .{ .duration = 0.7, .ease = .ease_out } });
        ui.text(c, c.print("{d:.0}°", .{temp}), .{ .size = 92, .weight = .bold, .color = th.text });
        ui.text(c, d.sky, .{ .size = 18, .weight = .medium, .color = th.muted });
        ui.spacer(c);
        const stats = ui.div(c).row().wFull().gap(10);
        defer stats.end();
        stat(c, "drop.fill", c.print("{d:.0}%", .{motion.number(c, "hum", d.humidity, .{ .tween = .{ .duration = 0.7 } })}), "Humidity");
        stat(c, "wind", c.print("{d:.0} km/h", .{motion.number(c, "wind", d.wind, .{ .tween = .{ .duration = 0.7 } })}), "Wind");
    }
    {
        // The hours: bars springing to the day's temperatures.
        const card = ui.div(c).column().grow().hFull().p(24).gap(14).rounded(28).glass(.{});
        defer card.end();
        ui.text(c, "Hourly", .{ .size = 15, .weight = .semibold, .color = th.text });
        const bars = ui.div(c).row().wFull().grow().gap(14).itemsEnd();
        defer bars.end();
        for (d.hours, 0..) |t, i| {
            ui.key(c, c.print("hour-{d}", .{i}));
            const col = ui.div(c).column().grow().hFull().gap(8).itemsCenter().justifyEnd();
            defer col.end();
            ui.text(c, c.print("{d:.0}°", .{motion.number(c, "t", t, .{ .tween = .{ .duration = 0.6 } })}), .{ .size = 13, .weight = .semibold, .mono = true, .color = th.text });
            const f = motion.frame(c, .{ .target = .{ .height = (t - 20) * 18 }, .initial = .{ .height = 0 }, .delay = motion.stagger(i, 0.04), .transition = .{ .spring = .{ .stiffness = 200, .damping = 18 } } });
            const bar = ui.div(c).w(26).rounded(13).bg(th.accent.alpha(0.85)).motion(f);
            bar.end();
            ui.text(c, c.print("{d}", .{9 + i * 2}), .{ .size = 12, .mono = true, .color = th.muted });
        }
    }
}

const Color = ui.Color;

fn stat(c: *ui.Context, icon: []const u8, value: []const u8, label: []const u8) void {
    const th = c.theme;
    const s = ui.div(c).column().grow().gap(4).p(12).rounded(16).glass(.{ .style = .clear });
    defer s.end();
    ui.icon(c, icon, .{ .size = 15, .color = th.accent });
    ui.text(c, value, .{ .size = 17, .weight = .bold, .mono = true, .color = th.text });
    ui.text(c, label, .{ .size = 11.5, .color = th.muted });
}
