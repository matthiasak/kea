//! What stands over one page in its hole (Stage.swift `Page`): the picture
//! of a page waking, the sentence that says it never came (`Trouble`), the
//! sideways swipe's disc or held list, and — for a page of the pair on
//! screen, or a hidden run — its question (the interim `PaneQuestionCard`,
//! P7 ports the real one).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const swipe = @import("../web/swipe.zig");
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const controls = @import("controls.zig");
const ring = @import("ring.zig");

fn px(v: f32) ui.Length {
    return .{ .px = v };
}

/// Inside the hole box; every layer is absolute over the page.
pub fn draw(c: *ui.Context, p: *const Palette, t: *Tab) void {
    if (t.cover) |picture| cover(c, t, picture);
    if (t.failure) |message| trouble(c, p, t, message);
    if (t.pull) |pull| if (pull.stops.len > 0) list(c, p, pull) else disc(c, p, pull);
    if (t.question()) |_| question(c, p, t);
}

/// The page as it was left, anchored where the page starts, never in the
/// way of a click.
// ponytail: comes in with its 0.2 s fade but leaves at once; its bytes go with it.
fn cover(c: *ui.Context, t: *Tab, picture: []const u8) void {
    const fade = ui.tween(c, c.peekId(null), 0x636f_76, 1, 0.2, .ease_out);
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .clip = true, .opacity = fade });
    defer ui.end(c);
    _ = ui.image(c, .{ .key = c.print("kea.cover.{d}.{d}", .{ t.serial, t.cover_serial }), .bytes = picture, .max_width = 1e5, .max_height = 1e5, .radius = 0, .scale = c.scale });
}

/// `Trouble`: one line, and another go.
fn trouble(c: *ui.Context, p: *const Palette, t: *Tab, message: []const u8) void {
    const i = c.open(.{ .absolute = true, .width = .fill, .height = .fill, .background = p.ground, .align_items = .center, .justify = .center, .gap = 10 }, null);
    defer c.end();
    _ = c.interact(i, .{});
    ui.text(c, message, .{ .size = 14, .color = p.ink });
    if (controls.pill(c, p, "Try again", .{ .filled = true }).clicked) t.reload();
}

/// `Disc`: white with a hairline, a line of ink wound round it as the
/// fingers go, closed when armed.
fn disc(c: *ui.Context, p: *const Palette, pull: swipe.Pull) void {
    const travel: f32 = @floatCast(pull.travel);
    const reach = 150 * (1 - @exp(-travel / 110));
    const grown = @min(1, travel / 110);
    const going = ui.tween(c, c.peekId(null), 0x6469_73, if (pull.going) 1 else 0, 0.22, .ease_out);
    const scale = std.math.lerp(0.86 + 0.14 * grown, 1.08, going);
    const side: f32 = if (pull.back) 1 else -1;
    ui.row(c, .{ .absolute = true, .width = .fill, .height = .fill, .align_items = .center, .justify = if (pull.back) .start else .end });
    defer ui.end(c);
    _ = c.open(.{
        .width = px(52),
        .height = px(52),
        .radius = 26,
        .background = p.ground,
        .border = p.hairline,
        .shadow = card.swiftShadow(0.12, 16, 6),
        .scale = scale,
        .opacity = 1 - going,
        .offset = .{ .x = side * (10 + reach * 0.2 + 12 * going) },
        .align_items = .center,
        .justify = .center,
    }, null);
    defer c.end();
    _ = c.open(.{ .absolute = true }, null);
    ring.windArc(c, 52, grown);
    c.end();
    ui.icon(c, if (pull.back) "arrow.left" else "arrow.right", .{ .size = 15, .weight = .semibold, .color = p.ink.alpha(0.4 + 0.6 * grown) });
}

/// `HistoryList`: the pages that way, the lit one where the disc was.
fn list(c: *ui.Context, p: *const Palette, pull: swipe.Pull) void {
    const travel: f32 = @floatCast(pull.travel);
    const reach = 150 * (1 - @exp(-travel / 110));
    const count: f32 = @floatFromInt(pull.stops.len);
    const slide_target = -(@as(f32, @floatFromInt(pull.picked)) - (count - 1) / 2) * 30;
    const slide = ui.spring(c, c.peekId(null), 0x6869_73, slide_target, .{ .response = 0.22, .damping = 0.9 });
    const going = ui.tween(c, c.peekId(null), 0x676f_6e, if (pull.going) 1 else 0, 0.26, .ease_out);
    const side: f32 = if (pull.back) 1 else -1;
    ui.row(c, .{ .absolute = true, .width = .fill, .height = .fill, .align_items = .center, .justify = if (pull.back) .start else .end });
    defer ui.end(c);
    ui.column(c, .{
        .width = px(240),
        .padding = .all(5),
        .gap = 2,
        .radius = 12,
        .background = p.ground,
        .border = p.hairline,
        .shadow = card.swiftShadow(0.16, 18, 6),
        .scale = std.math.lerp(1, 0.96, going),
        .opacity = 1 - going,
        .offset = .{ .x = side * (10 + reach * 0.2), .y = slide },
    });
    defer ui.end(c);
    for (pull.stops, 0..) |stop, i| {
        const lit = i == pull.picked;
        ui.row(c, .{ .width = .fill, .height = px(28), .padding = .xy(9, 0), .gap = 8, .align_items = .center, .radius = 7, .background = if (lit) p.ink.alpha(0.10) else null });
        ui.icon(c, "globe", .{ .size = 11, .frame = 14, .color = p.muted });
        ui.text(c, if (stop.title.len > 0) stop.title else stop.url, .{ .size = 12.5, .color = if (lit) p.ink else p.ink.alpha(0.75), .truncate = true });
        ui.end(c);
    }
}

/// A question over this page alone.
fn question(c: *ui.Context, p: *const Palette, t: *Tab) void {
    const q = t.question().?;
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .align_items = .center, .justify = .center });
    defer ui.end(c);
    var shadow = card.swiftShadow(0.16, 12, 6);
    shadow.knockout = true;
    const i = c.open(.{ .direction = .column, .width = px(340), .padding = .all(18), .radius = 14, .background = p.ground, .border = p.hairline, .shadow = shadow, .gap = 10 }, null);
    defer c.end();
    _ = c.interact(i, .{});
    if (q.host.len > 0) ui.text(c, q.host, .{ .size = 13, .weight = .semibold, .color = p.ink });
    ui.text(c, q.message, .{ .size = 13.5, .color = p.ink, .wrap = true });
    if (q.kind == .prompt) {
        ui.row(c, .{ .width = .fill, .padding = .xy(10, 6), .radius = 8, .background = p.wash });
        _ = ui.textField(c, &q.input, .{ .bare = true, .width = .fill, .size = 13, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
        ui.end(c);
    }
    ui.row(c, .{ .width = .fill, .justify = .end, .gap = 8 });
    defer ui.end(c);
    if (q.kind != .alert and controls.pill(c, p, "Cancel", .{}).clicked) return t.answerQuestion(false, null);
    if (controls.pill(c, p, "OK", .{ .filled = true }).clicked) t.answerQuestion(true, null);
}
