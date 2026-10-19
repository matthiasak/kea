//! Settings › About (Settings.swift:611-711): the bird, poked into flight
//! with a fact, the version, and the keys worth knowing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../../model/browser.zig").Browser;
const app_name = @import("../../app/kea.zig").app_name;
const Palette = @import("../../design/palette.zig").Palette;
const motion = @import("../../design/motion.zig");
const plate = @import("../controls_plate.zig");
const presence = @import("../presence.zig");
const kea_fact = @import("../kea_fact.zig");
const kea_flight = @import("../kea_flight.zig");
const frame = @import("frame.zig");

pub const State = struct {
    /// Flying until then (`c.time`); one flight is three seconds.
    flapping_until: f64 = 0,
    fact: ?[]const u8 = null,
};

const keys = [_][2][]const u8{
    .{ "⌘L", "Address" },
    .{ "⌘K", "Switch tab" },
    .{ "⌘T  ⌘W  ⇧⌘T", "New, close, reopen tab" },
    .{ "⇧⌘V", "Paste and go" },
    .{ "⇧⌘C", "Copy address" },
    .{ "⌃⇥  ⌘1–9", "Next tab, a tab by its place" },
    .{ "⇧⌘S", "Tabs in a sidebar" },
    .{ "⌘S", "Fold the sidebar away" },
    .{ "⇧⌘R", "Reading mode" },
    .{ "⇧⌘H", "Hide something on this site" },
    .{ "⇧⌘P", "Float the video" },
    .{ "⇧⌘⌫", "Clear browsing data" },
};

const fact_id: u64 = std.hash.Wyhash.hash(0, "kea.about.fact");

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.settings.about;
    const flapping = c.time < s.flapping_until;
    if (flapping) c.frameIn(@floatCast(s.flapping_until - c.time));

    ui.row(c, .{ .gap = 14, .padding = .{ .bottom = 2 }, .align_items = .center });
    const i = c.open(.{ .direction = .row, .width = .{ .px = 86 }, .height = .{ .px = 48 }, .align_items = .center, .control = true }, null);
    const it = c.interact(i, .{});
    c.help(i, "Give it a poke");
    c.addA11y(i, .button, "Give it a poke", "", false, true);
    if (!(flapping and kea_flight.view(c, 86, 48, 0))) kea_flight.appIcon(c, 48);
    c.end();
    if (it.clicked and !flapping) {
        s.fact = kea_fact.facts[arc4random_uniform(kea_fact.facts.len)];
        // Thirty frames at ten a second: one flight.
        s.flapping_until = c.time + 3;
        c.changed = true;
    }
    ui.column(c, .{ .gap = 3 });
    ui.text(c, app_name, .{ .size = 15, .weight = .semibold, .color = p.ink });
    ui.text(c, c.print("version {s} · built by you", .{version(c)}), .{ .size = 12, .color = p.muted });
    ui.end(c);
    ui.end(c);

    if (s.fact) |fact| if (presence.presence(c, fact_id, true, motion.settle, null)) |t| {
        ui.column(c, .{ .width = .fill, .opacity = std.math.clamp(t, 0, 1) });
        ui.text(c, fact, .{ .size = 12, .color = p.muted, .wrap = true });
        ui.end(c);
    };

    plate.cardBox(c, p);
    defer ui.end(c);
    for (keys, 0..) |k, n| {
        if (n > 0) frame.rule(c, p);
        ui.row(c, .{ .width = .fill, .padding = .xy(14, 9), .align_items = .center });
        ui.text(c, k[1], .{ .size = 13, .color = p.ink });
        ui.spacer(c);
        // ponytail: the system face, not SF Rounded (`design: .rounded`).
        ui.text(c, k[0], .{ .size = 12, .color = p.muted });
        ui.end(c);
    }
}

/// `CFBundleShortVersionString`, else "dev".
fn version(c: *ui.Context) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const info = objc.msg(?objc.Object, objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{}), "infoDictionary", .{}) orelse return "dev";
    const v = objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("CFBundleShortVersionString")}) orelse return "dev";
    return c.print("{s}", .{objc.fromNSString(v)});
}

extern "c" fn arc4random_uniform(upper: u32) u32;
