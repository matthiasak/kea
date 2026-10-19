//! P8.6: the find bar over a real page — ⌘F opens it, the page's count
//! shows as "1 of 3", ⌘G and Previous step, and it closes.
const std = @import("std");
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "find bar shows 1 of 3 and steps", .run = findBar },
};

/// Whether the window's last frame drew `said`.
fn drew(b: *app.Browser, said: []const u8) bool {
    const w = b.window orelse return false;
    const s = w.surface orelse return false;
    for (s.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, said)) return true,
        else => {},
    };
    return false;
}

fn showing(comptime said: []const u8) fn (*app.Browser) bool {
    return struct {
        fn f(b: *app.Browser) bool {
            return drew(b, said);
        }
    }.f;
}

fn finding(b: *app.Browser) bool {
    return b.finder.finding;
}

fn closed(b: *app.Browser) bool {
    return !b.finder.finding and !drew(b, "Find on page");
}

fn findBar(h: *Harness) !void {
    const b = try h.start();
    _ = try web.open(h, b, "kea-test://site/page?title=Find&body=needle%20one,%20needle%20two,%20needle%20three");
    // ⌘F (kVK_ANSI_F = 3).
    h.press("f", 3, true, false);
    try h.waitFor(b, finding, 2, "the find bar");
    h.frame();
    try h.expect(drew(b, "Find on page"), "no field placeholder", .{});
    // What typing does: the field's words looked for.
    b.find_bar.field.set("needle");
    app.page_find.setNeedle(b, "needle");
    try h.waitFor(b, showing("1 of 3"), 5, "1 of 3");
    // ⌘G (kVK_ANSI_G = 5): the next.
    h.press("g", 5, true, false);
    try h.waitFor(b, showing("2 of 3"), 5, "2 of 3");
    app.page_find.look(b, false);
    try h.waitFor(b, showing("1 of 3"), 5, "back to 1 of 3");
    // The bar's cross (`closeFind`).
    app.page_find.closeFind(b);
    try h.waitFor(b, closed, 3, "the bar to close");
}
