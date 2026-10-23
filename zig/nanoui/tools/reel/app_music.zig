//! A music player, for the reel: the cover springs up when it plays and
//! settles back when it pauses (Apple Music's way), the play button gives
//! under a press, the equalizer's bars dance in a loop while it plays
//! (keyframes), the progress eases along, and the next track's cover
//! slides in over the last (presence).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;

const Track = struct { title: []const u8, artist: []const u8, hues: [2]u24, length: f32 };

const tracks = [_]Track{
    .{ .title = "Retarget", .artist = "The Springs", .hues = .{ 0xe8a33d, 0xd2674f }, .length = 214 },
    .{ .title = "Presence", .artist = "Layout & Co.", .hues = .{ 0x6fb0a8, 0x8a9bb0 }, .length = 187 },
    .{ .title = "Keyframes", .artist = "Yoyo", .hues = .{ 0xbd80e4, 0xd2674f }, .length = 241 },
    .{ .title = "Liquid", .artist = "Glass Panes", .hues = .{ 0x7fa86b, 0x6fb0a8 }, .length = 198 },
};

pub const State = struct {
    playing: bool = false,
    track: usize = 0,
    /// Seconds into the track.
    pos: f32 = 41,
};

pub fn view(c: *ui.Context, s: *State) void {
    const th = c.theme;
    const root = ui.div(c).row().sizeFull().p(28).gap(32);
    defer root.end();
    {
        const left = ui.div(c).column().w(360).gap(18).itemsCenter();
        defer left.end();
        // The cover: larger while playing, sliding to the next track.
        const sf = motion.frame(c, .{ .target = .{ .scale = if (s.playing) 1 else 0.86 }, .initial = .{ .scale = 0.86 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const holder = ui.div(c).w(260).h(260).motion(sf);
        {
            defer holder.end();
            for (tracks, 0..) |tr, i| {
                if (motion.present(c, c.print("cover-{d}", .{i}), s.track == i, .{ .initial = .{ .x = 60, .opacity = 0 }, .exit = .{ .x = -60, .opacity = 0 }, .transition = .{ .spring = motion.Spring.snappy } })) |f| {
                    const cover = ui.div(c).absolute().w(260).h(260).rounded(22).bg(.hex(tr.hues[0])).clip().shadow(.{ .color = th.shadow.alpha(1), .blur = if (s.playing) 40 else 16, .y = if (s.playing) 18 else 6 }).center().motion(f);
                    defer cover.end();
                    const blob = ui.div(c).absolute().offset(120, 120).w(220).h(220).roundedFull().bg(Color.hex(tr.hues[1]).alpha(0.8));
                    blob.end();
                    ui.icon(c, "music.note", .{ .size = 76, .color = .white });
                }
            }
        }
        const t = tracks[s.track];
        {
            const words = ui.div(c).column().itemsCenter().gap(4);
            defer words.end();
            ui.text(c, t.title, .{ .size = 24, .weight = .bold });
            ui.text(c, t.artist, .{ .size = 15, .color = th.muted });
        }
        const pos = motion.number(c, "pos", s.pos, .{ .tween = .{ .duration = 0.4, .ease = .linear } });
        {
            const bar = ui.div(c).column().w(300).gap(6);
            defer bar.end();
            kit.progress(c, pos / t.length, .{ .height = 5 });
            const times = ui.div(c).row().wFull();
            defer times.end();
            ui.text(c, clock(c, pos), .{ .size = 12, .mono = true, .color = th.muted });
            ui.spacer(c);
            ui.text(c, clock(c, t.length), .{ .size = 12, .mono = true, .color = th.muted });
        }
        const controls = ui.div(c).row().gap(22).itemsCenter();
        defer controls.end();
        _ = kit.iconButton(c, "backward.fill", .{ .size = .lg });
        ui.key(c, "play");
        const pf = motion.frame(c, .{ .press = .{ .scale = 0.9 }, .hover = .{ .scale = 1.05 }, .transition = .{ .spring = motion.Spring.bouncy } });
        const play = ui.div(c).w(64).h(64).roundedFull().center().bg(th.accent).control().motion(pf);
        {
            defer play.end();
            ui.icon(c, if (s.playing) "pause.fill" else "play.fill", .{ .size = 26, .color = th.accent_text });
        }
        _ = kit.iconButton(c, "forward.fill", .{ .size = .lg });
    }
    // Up next, with the equalizer dancing beside what plays.
    const right = ui.div(c).column().grow().gap(6).pt(8);
    defer right.end();
    ui.text(c, "UP NEXT", .{ .size = 11.5, .weight = .semibold, .color = th.muted });
    const gap = ui.div(c).h(4);
    gap.end();
    for (tracks, 0..) |tr, i| {
        ui.key(c, c.print("row-{d}", .{i}));
        const on = i == s.track;
        const row = ui.div(c).row().wFull().h(58).px(12).gap(12).itemsCenter().rounded(12).bg(if (on) th.accent.alpha(0.12) else th.background.alpha(0));
        defer row.end();
        const sw = ui.div(c).w(38).h(38).rounded(8).bg(.hex(tr.hues[0]));
        sw.end();
        {
            const words = ui.div(c).column().grow().gap(2);
            defer words.end();
            ui.text(c, tr.title, .{ .size = 14.5, .weight = .semibold, .color = if (on) th.accent else th.text });
            ui.text(c, tr.artist, .{ .size = 12, .color = th.muted });
        }
        if (on and s.playing) equalizer(c) else ui.text(c, clock(c, tr.length), .{ .size = 12, .mono = true, .color = th.muted });
    }
}

const Color = ui.Color;

/// Five bars dancing, each on its own loop.
fn equalizer(c: *ui.Context) void {
    const th = c.theme;
    const eq = ui.div(c).row().h(22).gap(3).itemsEnd();
    defer eq.end();
    const highs = [_]f32{ 18, 10, 22, 14, 20 };
    for (highs, 0..) |hi, k| {
        ui.key(c, c.print("eq-{d}", .{k}));
        const f = motion.keyframes(c, .{ .values = &.{ .{ .height = 5 }, .{ .height = hi }, .{ .height = 7 }, .{ .height = hi * 0.7 }, .{ .height = 5 } }, .duration = 0.8 + @as(f32, @floatFromInt(k)) * 0.13, .repeat = null, .ease = .linear });
        const bar = ui.div(c).w(4).rounded(2).bg(th.accent).motion(f);
        bar.end();
    }
}

fn clock(c: *ui.Context, s: f32) []const u8 {
    const v: u32 = @intFromFloat(@max(0, s));
    return c.print("{d}:{d:0>2}", .{ v / 60, v % 60 });
}
