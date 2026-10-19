//! What stands over one page in its hole (Stage.swift `Page`): the picture
//! of a page waking, the sentence that says it never came (`Trouble`), the
//! sideways swipe's disc or held list, and — for a page of the pair on
//! screen, or a hidden run — its question (`PaneQuestionCard`).
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
    flew(c, p, t.floating);
    if (t.failure) |message| trouble(c, p, t, message);
    if (t.pull) |pull| if (pull.stops.len > 0) list(c, p, pull) else disc(c, p, pull);
    if (t.question()) |_| question(c, p, t);
}

/// A page out in the floating window: its tab says where it went rather
/// than showing a white rectangle; in and out with `Motion.quick`.
fn flew(c: *ui.Context, p: *const Palette, floating: bool) void {
    const shown = @import("../design/motion.zig").quickTo(c, c.peekId("kea.flew"), 0, if (floating) 1 else 0);
    if (shown <= 0) return;
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .background = p.ground, .align_items = .center, .justify = .center, .opacity = shown });
    defer ui.end(c);
    ui.text(c, "This page flew off into the floating window.", .{ .size = 13, .color = p.muted });
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
    if (controls.pill(c, p, "Try again", .{ .filled = true }).clicked) t.reload(false);
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

/// `PaneQuestionCard`: what this page asked, over this page alone. The
/// page dims and takes no click; the card is named for the site asking,
/// plain, and for its first half second takes no click either, so one
/// already on its way can't land on OK. A click on either focuses the page.
fn question(c: *ui.Context, p: *const Palette, t: *Tab) void {
    const q = t.question().?;
    const waited = ui.clock.now() - q.asked;
    const ready = waited >= 0.5;
    if (!ready) c.frameIn(@floatCast(0.5 - waited));
    const dim = c.open(.{ .absolute = true, .width = .fill, .height = .fill, .background = p.ground.alpha(0.62), .align_items = .center, .padding = .{ .top = 56, .left = 16, .right = 16 } }, null);
    defer c.end();
    const page = c.interact(dim, .{});
    var shadow = card.swiftShadow(0.14, 18, 6);
    shadow.knockout = true;
    const i = c.open(.{ .direction = .column, .width = .fill, .max_width = 380, .padding = .all(18), .radius = 14, .background = p.ground, .border = p.hairline, .shadow = shadow, .gap = 10 }, null);
    defer c.end();
    const box = c.interact(i, .{});
    if (page.clicked or box.clicked) if (t.browser) |b| b.focusPane(t);
    c.addA11y(i, .group, c.print("{s} asks", .{if (q.host.len == 0) "This page" else q.host}), "", false, true);
    ui.text(c, if (q.host.len == 0) "This page says" else q.host, .{ .size = 13, .weight = .semibold, .color = p.ink, .truncate = true });
    ui.scroll(c, .{ .width = .fill, .max_height = 200, .scroll_bar = false });
    ui.text(c, q.message, .{ .size = 13, .color = p.ink, .wrap = true });
    ui.end(c);
    if (q.kind == .prompt) {
        ui.row(c, .{ .width = .fill, .padding = .xy(7, 4), .radius = 6, .background = p.ground, .border = p.hairline });
        const typed = ui.textField(c, &q.input, .{ .bare = true, .width = .fill, .size = 13, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
        ui.end(c);
        if (typed.submitted and ready) return t.answerQuestion(true, null);
    }
    ui.row(c, .{ .width = .fill, .justify = .end, .gap = 8, .padding = .{ .top = 2 } });
    defer ui.end(c);
    if (q.kind != .alert and choice(c, p, "Cancel", false, ready)) return t.answerQuestion(false, null);
    if (choice(c, p, "OK", true, ready)) t.answerQuestion(true, null);
}

/// A plain capsule: OK in ink, Cancel in its faint grey; half there and
/// taking no click until the card is ready.
fn choice(c: *ui.Context, p: *const Palette, title: []const u8, strong: bool, ready: bool) bool {
    const i = c.open(.{ .padding = .xy(14, 0), .height = px(26), .radius = 13, .align_items = .center, .background = if (strong) p.ink else p.ink.alpha(0.07), .opacity = if (ready) 1 else 0.5, .control = ready }, null);
    defer c.end();
    const it = if (ready) c.interact(i, .{}) else null;
    c.addA11y(i, .button, title, "", false, ready);
    ui.text(c, title, .{ .size = 12.5, .weight = if (strong) .medium else .regular, .color = if (strong) p.ground else p.ink });
    return if (it) |x| x.clicked else false;
}
