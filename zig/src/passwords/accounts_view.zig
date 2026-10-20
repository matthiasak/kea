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

fn copyUtf8(dst: []u8, src: []const u8) u8 {
    var n = @min(src.len, dst.len);
    while (n < src.len and n > 0 and (src[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

const SavedRow = struct {
    passkey: bool = false,
    mark_buf: [16]u8 = undefined,
    mark_len: u8 = 0,
    name_buf: [128]u8 = undefined,
    name_len: u8 = 0,
    detail_buf: [128]u8 = undefined,
    detail_len: u8 = 0,

    fn set(self: *SavedRow, passkey: bool, mark_str: []const u8, name: []const u8, detail: []const u8) void {
        self.passkey = passkey;
        self.mark_len = copyUtf8(&self.mark_buf, mark_str);
        self.name_len = copyUtf8(&self.name_buf, name);
        self.detail_len = copyUtf8(&self.detail_buf, detail);
    }
};

var last_browser: ?*const Browser = null;
var last_rows: [8]SavedRow = undefined;
var last_rows_len: usize = 0;
var last_logins_empty: bool = false;
var last_x: f32 = 0;
var last_y: f32 = 0;
var last_w: f32 = 240;

/// Over the page of the tab it was made for, when that is the one in front.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (last_browser != b) {
        last_browser = b;
        last_rows_len = 0;
    }
    const asked = b.passwords.accounts.suggesting;
    const shown = if (asked) |a| a.tab == b.active_id else false;
    const id = c.peekId(key);
    const last = c.rects.get(id);
    const alpha = if (!shown)
        motion.quickTo(c, id, 2, 0)
    else if (last == null) blk: {
        _ = ui.tween(c, id, 2, 0, 0, .linear);
        c.animating = true;
        break :blk @as(f32, 0);
    } else motion.quickTo(c, id, 2, 1);
    if (!shown and (alpha <= 0.001 or last_rows_len == 0)) {
        last_rows_len = 0;
        return;
    }
    if (shown) {
        const box = anchor(b);
        last_w = width(box.w);
        const at = overlays.at(c.size, box, .{ .w = last_w, .h = if (last) |r| r.h else 0 }, .{ .gap = 6, .margin = 0 });
        last_x = motion.quickTo(c, id, 0, at.x);
        last_y = motion.quickTo(c, id, 1, at.y);
    }
    var shadow = card.swiftShadow(0.14, 22, 8);
    shadow.knockout = true;
    const i = c.open(.{
        .absolute = true,
        .direction = .column,
        .width = .{ .px = last_w },
        .offset = .{ .x = last_x, .y = last_y },
        .background = p.ground,
        .radius = 10,
        .clip = true,
        .border = p.hairline,
        .shadow = shadow,
        // Unseen until its height is known, then fades in and out on Motion.quick.
        .opacity = alpha,
    }, key);
    defer c.end();
    if (!shown) {
        for (last_rows[0..last_rows_len]) |*sr| {
            const mk: Mark = if (sr.passkey) .{ .symbol = "person.badge.key" } else .{ .letter = sr.mark_buf[0..sr.mark_len] };
            _ = row(c, p, mk, sr.name_buf[0..sr.name_len], sr.detail_buf[0..sr.detail_len], false);
        }
        ui.row(c, .{ .width = .fill, .gap = 6, .align_items = .center, .padding = .xy(12, 7), .background = p.wash.alpha(0.5) });
        ui.icon(c, "key", .{ .size = 9, .weight = .medium, .color = p.muted });
        ui.text(c, if (last_logins_empty) "Passkeys on this Mac" else "From your keychain", .{ .size = 10.5, .color = p.muted });
        ui.end(c);
        return;
    }
    const a = asked.?;
    _ = c.interact(i, .{});
    c.addA11y(i, .popover, @tagName(overlays.Overlay.account_list), "", false, true);
    var picked: ?struct { i: usize, passkey: bool } = null;
    var count: usize = 0;
    for (a.passkeys, 0..) |pk, n| {
        const detail = if (pk.provider) |pr| c.print("Passkey · {s}", .{pr}) else "Passkey";
        if (count < last_rows.len) {
            last_rows[count].set(true, "", pk.name, detail);
            count += 1;
        }
        if (row(c, p, .{ .symbol = "person.badge.key" }, pk.name, detail, true)) picked = .{ .i = n, .passkey = true };
    }
    for (a.logins, 0..) |l, n| {
        const init_str = mark_mod.initial(c, l.user);
        const nm = if (l.user.len == 0) "No name" else l.user;
        if (count < last_rows.len) {
            last_rows[count].set(false, init_str, nm, l.host);
            count += 1;
        }
        if (row(c, p, .{ .letter = init_str }, nm, l.host, true)) picked = .{ .i = n, .passkey = false };
    }
    last_rows_len = count;
    last_logins_empty = a.logins.len == 0;
    ui.row(c, .{ .width = .fill, .gap = 6, .align_items = .center, .padding = .xy(12, 7), .background = p.wash.alpha(0.5) });
    ui.icon(c, "key", .{ .size = 9, .weight = .medium, .color = p.muted });
    ui.text(c, if (a.logins.len == 0) "Passkeys on this Mac" else "From your keychain", .{ .size = 10.5, .color = p.muted });
    ui.end(c);
    // Last: a pick takes the list down, and what it drew from.
    if (picked) |pk| relay.pick(b, pk.i, pk.passkey);
}

const Mark = union(enum) { letter: []const u8, symbol: []const u8 };

fn row(c: *ui.Context, p: *const Palette, mark: Mark, name: []const u8, detail: []const u8, live: bool) bool {
    const i = c.open(.{ .direction = .row, .gap = 10, .width = .fill, .align_items = .center, .padding = .xy(10, 7), .control = live }, null);
    defer c.end();
    const it = if (live) c.interact(i, .{}) else ui.Interaction{ .id = c.node(i).id, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };
    if (live) c.addA11y(i, .button, name, detail, false, true);
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
