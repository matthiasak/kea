//! P4: the strip (TabBar.swift) — picking, closing, carrying, the tab's
//! menu, and a row too long for the window scrolling inside its run.
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;

fn strip(f: *Fixture, tabs: usize) !void {
    try f.init(gpa, .{ .sidebar = false, .tabs = tabs });
    f.tester.settle(2);
}

/// The pill of tab `id` as last drawn.
fn pill(f: *Fixture, id: u64) !ui.Rect {
    for (f.browser.strip.seen.items) |s| if (s.id == id) {
        return f.tester.ctx.rects.get(s.node) orelse error.NotLaidOut;
    };
    return error.NotDrawn;
}

fn center(r: ui.Rect) ui.Point {
    return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
}

fn has(f: *Fixture, id: u64) bool {
    return f.browser.tabById(id) != null;
}

/// The cross drawn inside `in`, and how much of it shows.
fn crossOpacity(f: *Fixture, in: ui.Rect) ?f32 {
    for (f.tester.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, "xmark") and in.contains(center(n.rect))) {
            return f.tester.ctx.nodes.items[n.parent].style.opacity;
        },
        else => {},
    };
    return null;
}

test "click selects tab" {
    var f: Fixture = undefined;
    try strip(&f, 3);
    defer f.deinit();
    const t = f.browser.tabs.items[2];
    try std.testing.expect(f.browser.active_id != t.id);
    const at = center(try pill(&f, t.id));
    f.tester.click(at.x, at.y);
    try std.testing.expectEqual(t.id, f.browser.active_id);
}

test "hover shows close disc and click closes" {
    var f: Fixture = undefined;
    try strip(&f, 3);
    defer f.deinit();
    const t = f.browser.tabs.items[1];
    const r = try pill(&f, t.id);
    try std.testing.expectEqual(@as(?f32, 0), crossOpacity(&f, r));
    const at = center(r);
    f.tester.moveTo(at.x, at.y);
    f.tester.settle(1);
    try std.testing.expectEqual(@as(?f32, 1), crossOpacity(&f, r));
    // The cross's 15-point disc, 7 in from the pill's right end.
    f.tester.click(r.x + r.w - 7 - 7.5, at.y);
    try std.testing.expect(!has(&f, t.id));
}

test "middle click closes" {
    var f: Fixture = undefined;
    try strip(&f, 3);
    defer f.deinit();
    const t = f.browser.tabs.items[2];
    const at = center(try pill(&f, t.id));
    f.tester.middleClick(at.x, at.y);
    try std.testing.expect(!has(&f, t.id));
    try std.testing.expectEqual(@as(usize, 3), f.browser.tabs.items.len);
}

test "drag moves tab 0 to index 2" {
    var f: Fixture = undefined;
    try strip(&f, 3);
    defer f.deinit();
    const t = f.browser.tabs.items[0];
    const r = try pill(&f, t.id);
    const step = r.w + 2;
    const at = center(r);
    f.tester.drag(at.x, at.y, at.x + 2 * step, at.y);
    f.tester.settle(1);
    try std.testing.expectEqual(t.id, f.browser.tabs.items[2].id);
    // Let go, it is not a click: nothing else changed.
    try std.testing.expectEqual(@as(usize, 4), f.browser.tabs.items.len);
    try std.testing.expect(f.browser.carry.hand == null);
}

test "right click opens tab menu" {
    var f: Fixture = undefined;
    try strip(&f, 2);
    defer f.deinit();
    const t = f.browser.tabs.items[1];
    const before = f.browser.active_id;
    const at = center(try pill(&f, t.id));
    f.tester.rightClick(at.x, at.y);
    // The menu, not a pick or a close.
    try std.testing.expectEqual(t.id, f.browser.strip.menu_tab);
    try std.testing.expectEqual(before, f.browser.active_id);
    try std.testing.expect(has(&f, t.id));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try app.tab_menu.items(arena.allocator(), f.browser, t);
    // TabMenu's order for a plain tab: groups, spaces and Split View off,
    // one window. Send to Device (between the copies and Mute) comes with Sync.
    const want = [_][]const u8{
        "Pin",          "Move to New Window", "-",          "Rename",           "Duplicate",
        "Site Information…", "Copy Address", "Copy as Markdown Link", "Mute Tab", "Put to Sleep",
        "-",            "Close Tab",          "Close Other Tabs", "Reopen Closed Tab",
    };
    try std.testing.expectEqual(want.len, items.len);
    for (want, items) |w, it| {
        if (std.mem.eql(u8, w, "-")) {
            try std.testing.expect(it.is_separator);
        } else try std.testing.expectEqualStrings(w, it.label);
    }
}

test "strip overflow scrolls instead of overlapping doors" {
    var f: Fixture = undefined;
    try strip(&f, 39);
    defer f.deinit();
    const ctx = &f.tester.ctx;
    const doors = ctx.rects.get(f.browser.strip.doors_node) orelse return error.NotLaidOut;
    const run = ctx.rects.get(f.browser.strip.run_node) orelse return error.NotLaidOut;
    try std.testing.expect(run.x + run.w <= doors.x);
    try std.testing.expectEqual(@as(usize, 40), f.browser.strip.seen.items.len);
    var past = false;
    for (f.browser.strip.seen.items) |s| {
        const r = ctx.rects.get(s.node) orelse return error.NotLaidOut;
        // Each at the narrowest a tab goes, clipped by the run.
        try std.testing.expectApproxEqAbs(@as(f32, 36), r.w, 0.01);
        try std.testing.expect(@min(r.x + r.w, run.x + run.w) <= doors.x);
        past = past or r.x + r.w > run.x + run.w;
    }
    // More tabs than room: the run scrolls rather than growing.
    try std.testing.expect(past);

    // Picking the last tab scrolls the run to it, on the glide.
    const last = f.browser.tabs.items[39];
    f.browser.select(last);
    f.tester.settle(2);
    const r = try pill(&f, last.id);
    try std.testing.expect(r.x >= run.x - 0.5 and r.x + r.w <= run.x + run.w + 0.5);
    try std.testing.expect((ctx.scroll_x.get(f.browser.strip.run_node) orelse 0) > 0);
}
