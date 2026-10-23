//! A chat, for the reel: messages spring in from below and the ones above
//! glide up to make room (presence and layout), the typing dots bounce in
//! a loop (keyframes), and Send wakes when there's a draft and gives under
//! a press.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;

const Message = struct { mine: bool, who: []const u8, text: []const u8 };

const messages = [_]Message{
    .{ .mine = false, .who = "Maya Chen", .text = "The motion library just landed in nanoui!" },
    .{ .mine = false, .who = "Leo Park", .text = "Springs keep their speed when you retarget them?" },
    .{ .mine = true, .who = "", .text = "Yep, and presence waits for exits." },
    .{ .mine = false, .who = "Maya Chen", .text = "Just tried layout: the list glides when it reorders." },
    .{ .mine = true, .who = "", .text = "Looks great. Ship it." },
    .{ .mine = false, .who = "Leo Park", .text = "On its way." },
};

pub const State = struct {
    /// How many messages show, the typing dots, the composer's draft.
    shown: usize = 3,
    typing: bool = false,
    draft: []const u8 = "",
};

pub fn view(c: *ui.Context, s: *State, t: f32) void {
    _ = t;
    const th = c.theme;
    const root = ui.div(c).column().sizeFull();
    defer root.end();
    {
        const head = ui.div(c).row().wFull().h(64).px(20).gap(12).itemsCenter().border(th.border.alpha(0.5));
        defer head.end();
        kit.avatarGroup(c, &.{ "Maya Chen", "Leo Park", "Rach Pradhan" }, .{ .size = 32 });
        const n = ui.div(c).column().gap(2);
        defer n.end();
        ui.text(c, "Design team", .{ .size = 15, .weight = .bold });
        ui.text(c, "3 members · 2 online", .{ .size = 12, .color = th.muted });
    }
    {
        const list = ui.div(c).column().wFull().grow().justifyEnd().px(20).py(16).gap(10).clip();
        defer list.end();
        for (messages[0..@min(s.shown, messages.len)], 0..) |m, i| {
            ui.key(c, c.print("msg-{d}", .{i}));
            const f = motion.frame(c, .{ .initial = .{ .y = 18, .opacity = 0, .scale = 0.92 }, .layout = true, .transition = .{ .spring = motion.Spring.snappy } });
            const row = (if (m.mine) ui.div(c).row().wFull().justifyEnd() else ui.div(c).row().wFull().gap(10).itemsEnd()).motion(f);
            defer row.end();
            if (!m.mine) kit.avatar(c, .{ .name = m.who, .size = 28 });
            const b = ui.div(c).column().gap(3).px(14).py(9).rounded(16).bg(if (m.mine) th.accent else th.surface_hover);
            defer b.end();
            if (!m.mine) ui.text(c, m.who, .{ .size = 11.5, .weight = .semibold, .color = th.accent });
            ui.text(c, m.text, .{ .size = 14.5, .color = if (m.mine) th.accent_text else th.text });
        }
        if (motion.present(c, "typing", s.typing, .{ .initial = .{ .opacity = 0, .scale = 0.8 }, .exit = .{ .opacity = 0, .scale = 0.8 }, .layout = true, .transition = .{ .spring = motion.Spring.snappy } })) |f| {
            const row = ui.div(c).row().gap(10).itemsEnd().motion(f);
            defer row.end();
            kit.avatar(c, .{ .name = "Leo Park", .size = 28 });
            const b = ui.div(c).row().gap(5).px(14).py(13).rounded(16).bg(th.surface_hover);
            defer b.end();
            for (0..3) |k| {
                ui.key(c, c.print("dot-{d}", .{k}));
                const bounce = motion.keyframes(c, .{ .values = &.{ .{ .y = 0, .opacity = 0.5 }, .{ .y = -5, .opacity = 1 }, .{ .y = 0, .opacity = 0.5 } }, .duration = 0.9, .repeat = null, .delay = @as(f32, @floatFromInt(k)) * 0.15 });
                const dot = ui.div(c).w(8).h(8).roundedFull().bg(th.muted).motion(bounce);
                dot.end();
            }
        }
    }
    const comp = ui.div(c).row().wFull().h(68).px(16).gap(10).itemsCenter().border(th.border.alpha(0.5));
    defer comp.end();
    {
        const field = ui.div(c).row().grow().h(40).px(14).itemsCenter().rounded(20).bg(th.surface).border(th.border);
        defer field.end();
        if (s.draft.len > 0) ui.text(c, s.draft, .{ .size = 14 }) else ui.text(c, "Message Design team", .{ .size = 14, .color = th.muted });
    }
    _ = kit.iconButton(c, "arrow.up", .{ .variant = .primary, .pill = true, .disabled = s.draft.len == 0 });
}
