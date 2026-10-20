//! Split View on the real stage (P7): both pages of a pair are placed at
//! their holes, side by side, a gutter apart.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "two panes show both webviews at hole rects", .run = bothPanes },
    .{ .name = "split enter moves pictures, page laid out once", .run = splitEnterMovesPictures },
};

fn finished(t: *app.Tab) bool {
    return !t.loading and t.progress >= 1;
}

fn bothPanes(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("split_view", true);
    const left = b.open("kea-test://site/page?title=Left", .{ .foreground = true });
    try h.waitFor(left, finished, 10, "the left page");
    const right = b.open("kea-test://site/page?title=Right", .{ .foreground = true });
    try h.waitFor(right, finished, 10, "the right page");
    b.pair(right, left, false);
    // The move is over in 0.32 s; a hidden window draws only when asked.
    for (0..12) |_| h.pump(0.05);
    const w = b.window orelse return h.fail("no window", .{});
    const s = w.surface orelse return h.fail("no surface", .{});
    const holes = s.ctx.stage_rects[0..s.ctx.stage_count];
    try h.expect(holes.len >= 2, "{d} holes, want 2", .{holes.len});
    const sh = b.stage_host.?;
    try h.expect(sh.slots.items.len == 2, "{d} slots, want 2", .{sh.slots.items.len});
    for ([_]*app.Tab{ left, right }, 0..) |t, i| {
        const wv = t.web orelse return h.fail("page {d} has no web view", .{i});
        try h.expect(sh.slots.items[i].webview == wv, "slot {d} doesn't hold its page", .{i});
        try h.expect(objc.msg(?objc.Object, wv, "superview", .{}) == sh.stage_view, "page {d} isn't on the stage", .{i});
        try h.expect(!objc.msg(objc.BOOL, wv, "isHidden", .{}), "page {d} is hidden", .{i});
        try h.expect(objc.msg(f64, wv, "alphaValue", .{}) > 0.99, "page {d} hasn't faded in", .{i});
        const f = objc.msg(objc.CGRect, wv, "frame", .{});
        const r = holes[i];
        const off = @abs(f.origin.x - r.x) + @abs(f.origin.y - r.y) + @abs(f.size.width - r.w) + @abs(f.size.height - r.h);
        try h.expect(off < 1, "page {d} at ({d:.1},{d:.1},{d:.1},{d:.1}), hole ({d:.1},{d:.1},{d:.1},{d:.1})", .{ i, f.origin.x, f.origin.y, f.size.width, f.size.height, r.x, r.y, r.w, r.h });
    }
    try h.expect(@abs(holes[1].x - (holes[0].x + holes[0].w) - 7) < 0.5, "the gutter is {d:.1}, want 7", .{holes[1].x - (holes[0].x + holes[0].w)});
}

fn splitEnterMovesPictures(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("split_view", true);
    const left = b.open("kea-test://site/page?title=Left", .{ .foreground = true });
    try h.waitFor(left, finished, 10, "the left page");
    const right = b.open("kea-test://site/page?title=Right", .{ .foreground = true });
    try h.waitFor(right, finished, 10, "the right page");
    b.select(left);
    h.frame();
    h.pump(0.05);

    const sh = b.stage_host orelse return h.fail("no stage host", .{});
    for (sh.slots.items) |*slot| slot.place_calls = 0;
    const before = b.stage.boxes[0].win_rect;

    b.pair(right, left, false);
    h.frame();
    h.pump(0.16);

    const after = b.stage.boxes[0].win_rect;
    const pic = b.stage.pictures.get(left.id) orelse return h.fail("no stage picture for staying pane", .{});
    const layer = objc.msg(?objc.Object, pic, "layer", .{}) orelse return h.fail("no layer on stage picture", .{});
    const pres = objc.msg(?objc.Object, layer, "presentationLayer", .{}) orelse layer;
    const pf = objc.msg(objc.CGRect, pres, "frame", .{});
    try h.expect(pf.size.width > after.w + 5 and pf.size.width < before.w - 5, "picture width {d:.1} not strictly between after {d:.1} and before {d:.1}", .{ pf.size.width, after.w, before.w });

    for (0..12) |_| h.pump(0.05);
    try h.expect(sh.slots.items.len == 2, "{d} slots, want 2", .{sh.slots.items.len});
    for ([_]*app.Tab{ left, right }, 0..) |t, i| {
        const slot = for (sh.slots.items) |s| {
            if (s.webview == t.web) break s;
        } else return h.fail("no slot for pane {d}", .{i});
        try h.expect(slot.place_calls <= 1, "pane {d} had {d} place calls, want <= 1", .{ i, slot.place_calls });
    }
}
