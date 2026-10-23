//! Settings, for the reel, made of nanoui.kit: toggles, segmented tabs
//! whose marker slides, an accordion that opens to its content's height,
//! a select, and Save, which reports with a toast.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;

pub const State = struct {
    notifications: bool = true,
    sounds: bool = false,
    sync: bool = true,
    theme: usize = 0,
    advanced: bool = false,
    beta: bool = false,
    size: ?usize = 1,
};

pub fn view(c: *ui.Context, s: *State) void {
    const th = c.theme;
    const root = ui.div(c).column().sizeFull().px(32).py(24).gap(18);
    defer root.end();
    {
        const head = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer head.end();
        kit.avatar(c, .{ .name = "Rach Pradhan", .size = 44 });
        const n = ui.div(c).column().gap(2);
        defer n.end();
        ui.text(c, "Rach Pradhan", .{ .size = 17, .weight = .bold });
        ui.text(c, "Pro plan · 3 devices", .{ .size = 13, .color = th.muted });
    }
    group(c, "Appearance");
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, "Theme", .{ .size = 14 });
        ui.spacer(c);
        _ = kit.tabs(c, &.{ "System", "Light", "Dark" }, &s.theme, .{ .variant = .segmented, .size = .sm });
    }
    group(c, "Notifications");
    _ = ui.toggle(c, "Allow notifications", &s.notifications);
    _ = ui.toggle(c, "Play sounds", &s.sounds);
    _ = ui.toggle(c, "Sync across devices", &s.sync);
    const sep = ui.div(c).h(2);
    sep.end();
    if (kit.collapsible(c, "advanced", "Advanced", &s.advanced)) |sec| {
        defer sec.end();
        _ = ui.toggle(c, "Try beta features", &s.beta);
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, "Cache size", .{ .size = 14 });
        ui.spacer(c);
        kit.tag(c, "1.2 GB", .{ .status = .info });
    }
    ui.spacer(c);
    const f = ui.div(c).row().wFull().gap(10).justifyEnd();
    defer f.end();
    _ = kit.button(c, "Cancel", .{});
    _ = kit.button(c, "Save changes", .{ .variant = .primary, .icon = "checkmark" });
    _ = motion;
}

fn group(c: *ui.Context, name: []const u8) void {
    ui.text(c, name, .{ .size = 12, .weight = .semibold, .color = c.theme.muted });
}
