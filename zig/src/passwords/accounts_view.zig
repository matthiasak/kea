//! `AccountList` (Accounts.swift): the accounts kept for a site, hanging
//! 6 pt under the sign-in box the caret is in, left edges lined up; the
//! Mac's passkeys for a page waiting for one first. One line per account,
//! the name in ink and the site under it in grey; a click fills the form.
//! An overlay over the window (chrome/overlays.zig), placed from the page's
//! hole, following the box as the page scrolls (`Motion.quick`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const motion = @import("../design/motion.zig");
const overlays = @import("../chrome/overlays.zig");
const mark_mod = @import("../chrome/mark.zig");
const relay = @import("form_relay.zig");

pub const key = "kea.accounts";

/// The list's width for a box `w` wide.
pub fn width(w: f32) f32 {
    return @max(240, @min(360, w));
}

/// The sign-in box, in window points: the page's hole plus where the page
/// says its box is.
pub fn anchor(b: *const Browser) ui.Rect {
    const page = b.active_page_frame;
    const s = b.passwords.accounts.spot;
    return .{ .x = page.x + @as(f32, @floatCast(s.x)), .y = page.y + @as(f32, @floatCast(s.y)), .w = @floatCast(s.w), .h = @floatCast(s.h) };
}

/// Over the page of the tab it was made for, when that is the one in front.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const asked = b.passwords.accounts.suggesting orelse return;
    if (asked.tab != b.active_id) return;
    const box = anchor(b);
    const w = width(box.w);
    const id = c.peekId(key);
    const last = c.rects.get(id);
    const at = overlays.at(c.size, box, .{ .w = w, .h = if (last) |r| r.h else 0 }, .{ .gap = 6, .margin = 0 });
    var shadow = card.swiftShadow(0.14, 22, 8);
    shadow.knockout = true;
    const i = c.open(.{
        .absolute = true,
        .direction = .column,
        .width = .{ .px = w },
        .offset = .{ .x = motion.quickTo(c, id, 0, at.x), .y = motion.quickTo(c, id, 1, at.y) },
        .background = p.ground,
        .radius = 10,
        .clip = true,
        .border = p.hairline,
        .shadow = shadow,
        // Unseen until its height is known.
        .opacity = if (last == null) 0 else 1,
    }, key);
    defer c.end();
    _ = c.interact(i, .{});
    c.addA11y(i, .popover, @tagName(overlays.Overlay.account_list), "", false, true);
    var picked: ?struct { i: usize, passkey: bool } = null;
    for (asked.passkeys, 0..) |pk, n| {
        const detail = if (pk.provider) |pr| c.print("Passkey · {s}", .{pr}) else "Passkey";
        if (row(c, p, .{ .symbol = "person.badge.key" }, pk.name, detail)) picked = .{ .i = n, .passkey = true };
    }
    for (asked.logins, 0..) |l, n| {
        if (row(c, p, .{ .letter = mark_mod.initial(c, l.user) }, if (l.user.len == 0) "No name" else l.user, l.host)) picked = .{ .i = n, .passkey = false };
    }
    ui.row(c, .{ .width = .fill, .gap = 6, .align_items = .center, .padding = .xy(12, 7), .background = p.wash.alpha(0.5) });
    ui.icon(c, "key", .{ .size = 9, .weight = .medium, .color = p.muted });
    ui.text(c, if (asked.logins.len == 0) "Passkeys on this Mac" else "From your keychain", .{ .size = 10.5, .color = p.muted });
    ui.end(c);
    // Last: a pick takes the list down, and what it drew from.
    if (picked) |pk| relay.pick(b, pk.i, pk.passkey);
}

const Mark = union(enum) { letter: []const u8, symbol: []const u8 };

fn row(c: *ui.Context, p: *const Palette, mark: Mark, name: []const u8, detail: []const u8) bool {
    const i = c.open(.{ .direction = .row, .gap = 10, .width = .fill, .align_items = .center, .padding = .xy(10, 7), .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, name, detail, false, true);
    c.node(i).style.background = p.hover.alpha(motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0));
    ui.row(c, .{ .width = .{ .px = 22 }, .height = .{ .px = 22 }, .radius = 6, .background = p.wash, .align_items = .center, .justify = .center });
    switch (mark) {
        .letter => |l| ui.text(c, l, .{ .size = 11, .weight = .medium, .color = p.ink }),
        .symbol => |s| ui.icon(c, s, .{ .size = 10, .weight = .medium, .color = p.ink }),
    }
    ui.end(c);
    ui.column(c, .{ .gap = 1, .grow = 1 });
    ui.text(c, name, .{ .size = 12.5, .color = p.ink, .truncate = true });
    ui.text(c, detail, .{ .size = 10.5, .color = p.muted, .truncate = true });
    ui.end(c);
    return it.clicked;
}
