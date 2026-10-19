//! `HiddenPanel` (Hidden.swift): what you have taken off this site, and the
//! way back. Resting the pointer on a line puts that one thing back on the
//! page, outlined — you decide what to restore by looking at it, not by
//! decoding its selector. No dimming: the page stays in view under it
//! (App.swift `reviewing`). ⇧⌘U.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const plate = @import("controls_plate.zig");
const controls = @import("controls.zig");
const motion = @import("../design/motion.zig");
const metrics = @import("../design/metrics.zig");
const presence = @import("presence.zig");
const curtain_js = @import("../web/curtain_js.zig");

pub const State = struct {
    /// The line the pointer last came onto (its selector's hash).
    on_row: u64 = 0,
    /// The pointer was over the panel last frame.
    inside: bool = false,
};

/// `reviewing`, with its didSet: closing puts the page back as it was.
pub fn setReviewing(b: *Browser, on: bool) void {
    if (b.reviewing == on) return;
    b.reviewing = on;
    if (!on) {
        curtain_js.stopPeeking(b);
        b.hidden_panel = .{};
    }
    b.redraw();
}

/// ⇧⌘U: Hidden on This Site… (`reviewing.toggle()`).
pub fn toggle(b: *Browser) void {
    setReviewing(b, !b.reviewing);
}

const Act = union(enum) { none, restore: []const u8, restore_all, hide, close };

const panel_id: u64 = std.hash.Wyhash.hash(0, "kea.hidden-panel");

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const t = presence.presence(c, panel_id, b.reviewing, motion.settle, null) orelse return;
    const o = std.math.clamp(t, 0, 1);
    var act: Act = .none;
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .align_items = .end, .padding = .{ .top = metrics.strip + 8, .right = 14 }, .opacity = o });
    // A press anywhere else closes it.
    const floor = c.leaf(.{ .absolute = true, .width = .fill, .height = .fill }, .none, "kea.hidden.floor");
    if (c.interact(floor, .{}).clicked and b.reviewing) act = .close;
    const box = c.open(.{ .scale = 0.97 + 0.03 * t, .scale_anchor = .{ .x = 1, .y = 0 } }, "kea.hidden.panel");
    const inside = c.interact(box, .{}).hovered;
    const a = panel(b, c, p);
    if (a != .none) act = a;
    c.end();
    ui.end(c);
    // Leaving the panel puts the page back the way it was.
    if (b.hidden_panel.inside and !inside) {
        curtain_js.stopPeeking(b);
        b.hidden_panel.on_row = 0;
    }
    b.hidden_panel.inside = inside;
    switch (act) {
        .none => {},
        .restore => |selector| {
            const copy = b.gpa.dupe(u8, selector) catch return;
            defer b.gpa.free(copy);
            curtain_js.restore(b, copy);
        },
        .restore_all => curtain_js.restoreAll(b),
        .hide => curtain_js.toggleHiding(b),
        .close => setReviewing(b, false),
    }
}

fn panel(b: *Browser, c: *ui.Context, p: *const Palette) Act {
    const host = curtain_js.hereHost(b);
    defer if (host) |h| b.gpa.free(h);
    const veils = b.kea.curtain.veils(host);
    var act: Act = .none;
    var pl = plate.plate(c, p, if (host) |h| c.alloc().dupe(u8, h) catch "This page" else "This page", 380);
    if (pl.closed) act = .close;
    if (veils.len == 0) {
        plate.cardBox(c, p);
        plate.nothing(c, p, "Nothing pecked off this site yet.");
        ui.end(c);
    } else {
        ui.column(c, .{ .width = .fill, .gap = 6 });
        plate.caption(c, p, "Hidden on this site — rest on a line to see it");
        ui.scroll(c, .{ .width = .fill, .max_height = 320, .scroll_bar = false, .padding = .{ .bottom = 2 } });
        plate.cardBox(c, p);
        for (veils, 0..) |v, n| {
            if (n > 0) plate.rule(c, p, 14);
            ui.key(c, v.selector);
            if (row(b, c, p, v.selector, v.label, v.note)) act = .{ .restore = v.selector };
        }
        ui.end(c);
        ui.end(c);
        ui.end(c);
    }
    pl.foot(c, p);
    if (controls.pill(c, p, "Hide something…", .{ .filled = true }).clicked) act = .hide;
    if (veils.len > 0 and controls.pill(c, p, "Restore all", .{}).clicked) act = .restore_all;
    ui.spacer(c);
    pl.end(c);
    return act;
}

/// `Row`: what it was, in words, and its size and place; Restore under
/// the pointer. True when Restore was pressed.
fn row(b: *Browser, c: *ui.Context, p: *const Palette, selector: []const u8, label: []const u8, note: ?[]const u8) bool {
    const i = c.open(.{ .direction = .row, .gap = 10, .width = .fill, .padding = .xy(14, 9), .align_items = .center }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .row, label, note orelse "", false, true);
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = p.hover.alpha(h);
    if (it.hovered and b.hidden_panel.on_row != it.id) {
        b.hidden_panel.on_row = it.id;
        curtain_js.peek(b, selector);
    }
    ui.column(c, .{ .gap = 2, .grow = 1, .min_width = 0 });
    ui.text(c, label, .{ .size = 13, .color = p.ink, .truncate = true });
    if (note) |n| if (n.len > 0) ui.text(c, n, .{ .size = 11.5, .color = p.muted, .truncate = true });
    ui.end(c);
    _ = c.leaf(.{ .min_width = 8, .width = .{ .px = 8 } }, .none, null);
    ui.column(c, .{ .opacity = h });
    const restore = plate.quick(c, p, "Restore", null).clicked;
    ui.end(c);
    return restore and it.hovered;
}
