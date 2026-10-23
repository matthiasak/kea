//! The reel: `ui.motion` and `nanoui.kit` at work in six mock apps that
//! nanoui draws: a trading app, a chat, a task board, a music player, a
//! weather app on Liquid Glass, and settings. One window goes from app to
//! app, springing to each one's size while the next app's content fades
//! in over the last. A caption names the motion at work. Then the end card.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;
const trade = @import("trade.zig");
const apps = struct {
    const trade_ = @import("trade_view.zig");
    const chat = @import("app_chat.zig");
    const board = @import("app_board.zig");
    const music = @import("app_music.zig");
    const weather = @import("app_weather.zig");
    const settings = @import("app_settings.zig");
    const glass = @import("app_glass.zig");
};
const palette = @import("theme.zig");

/// Points; drawn at 1.5× for 1920 × 1080.
pub const width = 1280;
pub const height = 720;

pub const App = enum { trade, chat, board, music, glass, weather, settings };

/// When each part begins.
pub const at = struct {
    pub const trade = 2.2;
    pub const chat = 6.2;
    pub const board = 10.0;
    pub const music = 13.8;
    pub const glass = 17.4;
    pub const weather = 21.4;
    pub const settings = 24.8;
    pub const end = 27.8;
    pub const done = 30.0;
};

const Meta = struct { app: App, start: f32, w: f32, h: f32, title: []const u8, tag: []const u8, line: []const u8 };

const metas = [_]Meta{
    .{ .app = .trade, .start = at.trade, .w = 1200, .h = 652, .title = "nanotrade", .tag = "motion.number · frame", .line = "prices ease to each tick; candles spring to a new range" },
    .{ .app = .chat, .start = at.chat, .w = 760, .h = 600, .title = "Messages", .tag = "present · layout", .line = "messages spring in and the list makes room" },
    .{ .app = .board, .start = at.board, .w = 1100, .h = 600, .title = "Board", .tag = "layout · springs", .line = "a card lifts, glides to Done, and the column closes up" },
    .{ .app = .music, .start = at.music, .w = 900, .h = 600, .title = "Music", .tag = "springs · keyframes", .line = "the cover grows on play; the bars dance in a loop" },
    .{ .app = .glass, .start = at.glass, .w = 900, .h = 560, .title = "Photos", .tag = "glass · interactive · morph", .line = "glass swells on touch; a button morphs into a panel" },
    .{ .app = .weather, .start = at.weather, .w = 1000, .h = 620, .title = "Weather", .tag = "glass · kit.tabs", .line = "glass cards, a sliding lens, temperatures counting" },
    .{ .app = .settings, .start = at.settings, .w = 720, .h = 600, .title = "Settings", .tag = "nanoui.kit", .line = "a new theme crossfades in; an accordion opens; a toast" },
};

pub fn appAt(t: f32) ?App {
    if (t < at.trade or t >= at.end) return null;
    var a: App = .trade;
    for (metas) |m| if (t >= m.start) {
        a = m.app;
    };
    return a;
}

pub const Director = struct {
    now: f32 = 0,
    dark: bool = false,
    // nanotrade
    market: trade.Market,
    range: usize = 0,
    sorted: bool = false,
    crosshair: bool = false,
    order_open: bool = false,
    qty: f64 = 10,
    placing: bool = false,
    filled: bool = false,
    entry: f32 = 0,
    tick_at: f32 = -10,
    last_up: bool = true,
    // The other apps.
    chat: apps.chat.State = .{},
    board: apps.board.State = .{},
    music: apps.music.State = .{},
    weather: apps.weather.State = .{},
    settings: apps.settings.State = .{},
    glass: apps.glass.State = .{},
    toaster: kit.Toaster,
    cursor: [2]f32 = .{ 1100, 640 },
    cursor_alpha: f32 = 0,

    pub fn draw(d: *Director, c: *ui.Context) void {
        // Settings' theme, picked, crossfades everything to it.
        const want: f32 = switch (d.settings.theme) {
            1 => 0,
            2 => 1,
            else => if (d.dark) 1 else 0,
        };
        const t = motion.number(c, "theme", want, .{ .tween = .{ .duration = 0.6, .ease = .ease_in_out } });
        c.theme = mixTheme(palette.ui_(false), palette.ui_(true), t);
        const th = c.theme;
        const root = ui.div(c).sizeFull().bg(th.background.mix(th.text, if (d.dark) 0.04 else 0.03));
        defer root.end();
        const wash = ui.div(c).absolute().offset(-260, -300).w(1000).h(1000).roundedFull().bg(th.accent.alpha(if (d.dark) 0.08 else 0.07));
        wash.end();
        title(c, d);
        window(c, d);
        caption(c, d);
        d.toaster.view(c);
        endCard(c, d);
        cursor(c, d);
    }
};

fn metaOf(a: App) Meta {
    for (metas) |m| if (m.app == a) return m;
    unreachable;
}

/// The window apps live in: it springs to each app's size, centered, and
/// the app's content fades in over the last one's.
fn window(c: *ui.Context, d: *Director) void {
    const th = c.theme;
    const now = appAt(d.now);
    const m = metaOf(now orelse if (d.now >= at.end) .settings else .trade);
    const f = motion.present(c, "window", now != null, .{
        .target = .{ .x = (width - m.w) / 2, .y = (height - 30 - m.h) / 2, .width = m.w, .height = m.h },
        .initial = .{ .scale = 0.92, .opacity = 0, .y = (height - 30 - m.h) / 2 + 30 },
        .exit = .{ .scale = 0.9, .opacity = 0 },
        .transition = .{ .spring = .{ .stiffness = 170, .damping = 22 } },
    }) orelse return;
    const w = ui.div(c).absolute().column().rounded(14).bg(th.background).border(th.border).shadow(.{ .color = th.shadow.alpha(1), .blur = 50, .y = 20 }).clip().motion(f);
    defer w.end();
    {
        const bar = ui.div(c).row().wFull().h(44).px(16).gap(8).itemsCenter().bg(th.surface_hover.alpha(0.6));
        defer bar.end();
        for ([_]u24{ 0xff5f57, 0xfebc2e, 0x28c840 }) |col| _ = c.leaf(.{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .radius = 6, .background = .hex(col) }, .none, null);
        const t = ui.div(c).grow().center();
        defer t.end();
        ui.text(c, m.title, .{ .size = 13, .weight = .semibold, .color = th.muted });
    }
    const area = ui.div(c).grow().wFull().clip();
    defer area.end();
    inline for (comptime std.enums.values(App)) |a| {
        const mm = comptime blk: {
            for (metas) |x| if (x.app == a) break :blk x;
            unreachable;
        };
        if (motion.present(c, "app-" ++ @tagName(a), now == a, .{
            .initial = .{ .opacity = 0, .y = 14 },
            .exit = .{ .opacity = 0 },
            .transition = .{ .tween = .{ .duration = 0.28, .ease = .ease_out } },
        })) |af| {
            const content = ui.div(c).absolute().w(mm.w).h(mm.h - 44).motion(af);
            defer content.end();
            switch (a) {
                .trade => apps.trade_.content(c, d, mm.w, mm.h - 44),
                .chat => apps.chat.view(c, &d.chat, d.now - mm.start),
                .board => apps.board.view(c, &d.board, mm.w),
                .music => apps.music.view(c, &d.music),
                .weather => apps.weather.view(c, &d.weather, mm.w, mm.h - 44),
                .glass => apps.glass.view(c, &d.glass, mm.w, mm.h - 44),
                .settings => apps.settings.view(c, &d.settings),
            }
        }
    }
}

fn title(c: *ui.Context, d: *Director) void {
    const th = c.theme;
    const f = motion.present(c, "title", d.now < at.trade - 0.1, .{ .initial = .{ .opacity = 0 }, .exit = .{ .opacity = 0, .scale = 0.96, .y = -20 }, .transition = .{ .spring = .{} } }) orelse return;
    const box = ui.div(c).absolute().w(width).h(height).column().center().gap(18).motion(f);
    defer box.end();
    {
        const r = ui.div(c).row().itemsEnd();
        defer r.end();
        for ("ui.motion", 0..) |ch, i| {
            ui.key(c, c.print("l{d}", .{i}));
            const lf = motion.frame(c, .{ .initial = .{ .y = 60, .opacity = 0, .scale = 0.6 }, .delay = 0.15 + motion.stagger(i, 0.05), .transition = .{ .spring = motion.Spring.bouncy } });
            const l = ui.div(c).motion(lf);
            defer l.end();
            ui.text(c, c.print("{c}", .{ch}), .{ .size = 116, .weight = .bold, .mono = i < 3, .color = if (i < 3) th.accent else th.text });
        }
    }
    const sf = motion.frame(c, .{ .initial = .{ .y = 16, .opacity = 0 }, .delay = 0.8, .transition = .{ .spring = motion.Spring.gentle } });
    const s = ui.div(c).column().itemsCenter().gap(10).motion(sf);
    defer s.end();
    ui.text(c, "One motion library for every nanoui app", .{ .size = 26, .weight = .medium });
    ui.text(c, "springs · presence · layout · keyframes · glass", .{ .size = 17, .color = th.muted, .mono = true });
}

/// The caption pill at the bottom: the motion at work, and what it does.
fn caption(c: *ui.Context, d: *Director) void {
    const th = c.theme;
    const now = appAt(d.now);
    for (metas) |m| {
        const f = motion.present(c, c.print("cap-{s}", .{@tagName(m.app)}), now == m.app and d.now > m.start + 0.25, .{
            .initial = .{ .y = 14, .opacity = 0 },
            .exit = .{ .y = -8, .opacity = 0 },
            .transition = .{ .spring = motion.Spring.snappy },
        }) orelse continue;
        const pill = ui.div(c).fixed().offset(width / 2 - 340, height - 30).w(680).h(26).row().center().gap(10).layer(60).motion(f);
        defer pill.end();
        const tag = ui.div(c).px(8).py(2).rounded(6).bg(th.accent);
        {
            defer tag.end();
            ui.text(c, m.tag, .{ .size = 12, .weight = .bold, .mono = true, .color = th.accent_text });
        }
        ui.text(c, m.line, .{ .size = 14, .weight = .medium, .color = th.text });
    }
}

fn endCard(c: *ui.Context, d: *Director) void {
    const th = c.theme;
    const f = motion.present(c, "end", d.now >= at.end + 0.15, .{ .initial = .{ .scale = 0.9, .opacity = 0 }, .exit = .{ .opacity = 0 }, .transition = .{ .spring = motion.Spring.bouncy } }) orelse return;
    const box = ui.div(c).fixed().w(width).h(height).column().center().gap(16).layer(70).motion(f);
    defer box.end();
    ui.text(c, "ui.motion", .{ .size = 96, .weight = .bold, .mono = true, .color = th.accent });
    ui.text(c, "Six apps, one motion library", .{ .size = 26, .weight = .medium });
    {
        const r = ui.div(c).row().gap(12).pt(6);
        defer r.end();
        for ([_][]const u8{ "nanoui", "ui.motion", "nanoui.kit", "Liquid Glass" }, 0..) |it, i| {
            ui.key(c, it);
            const g = motion.frame(c, .{ .initial = .{ .y = 14, .opacity = 0 }, .delay = 0.3 + motion.stagger(i, 0.08), .transition = .{ .spring = motion.Spring.snappy } });
            const chip = ui.div(c).px(16).py(8).roundedFull().bg(th.accent.alpha(0.14)).motion(g);
            defer chip.end();
            ui.text(c, it, .{ .size = 18, .weight = .semibold, .mono = true, .color = th.accent });
        }
    }
    const l = motion.frame(c, .{ .initial = .{ .opacity = 0 }, .delay = 0.7, .transition = .{ .tween = .{ .duration = 0.5 } } });
    const link = ui.div(c).motion(l);
    defer link.end();
    ui.text(c, "github.com/justrach/nanoui", .{ .size = 19, .color = th.muted, .mono = true });
}

/// The pointer: an arrow, wherever the script has it.
fn cursor(c: *ui.Context, d: *Director) void {
    if (d.cursor_alpha <= 0.01) return;
    const p = ui.div(c).fixed().offset(d.cursor[0] - 4, d.cursor[1] - 3).layer(90).opacity(d.cursor_alpha);
    defer p.end();
    ui.icon(c, "cursorarrow", .{ .size = 30, .weight = .regular, .color = c.theme.text });
}

/// Theme `a` turned `t` of the way into theme `b`, color by color.
fn mixTheme(a: ui.Theme, b: ui.Theme, t: f32) ui.Theme {
    var r = a;
    inline for (@typeInfo(ui.Theme).@"struct".field_names) |name| {
        if (@TypeOf(@field(r, name)) == ui.Color) @field(r, name) = @field(a, name).mix(@field(b, name), t);
    }
    r.dark = t > 0.5;
    return r;
}
