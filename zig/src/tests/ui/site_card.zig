//! P6: the site card (SiteCard.swift) — opened from the tab's menu under
//! the tab's address, closed by Esc or a press outside it, and its zoom
//! steps.
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;

/// A strip with its one tab on an https page, its card opened through the
/// tab menu's Site Information….
fn opened(f: *Fixture) !*app.Tab {
    try f.init(gpa, .{ .sidebar = false });
    errdefer f.deinit();
    const b = f.browser;
    const t = b.activeTab().?;
    t.own(&t.address, "https://www.example.com/a");
    f.tester.settle(1);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const items = try app.tab_menu.items(arena.allocator(), b, t);
    for (items) |it| {
        if (!std.mem.eql(u8, it.label, "Site Information…")) continue;
        try std.testing.expect(!it.disabled);
        const click = it.click.?;
        click.func(click.ctx, undefined);
        break;
    } else return error.NoSiteInformation;
    f.tester.settle(1);
    return t;
}

fn isOpen(f: *Fixture) bool {
    const o = f.browser.overlay orelse return false;
    return o == .site_card;
}

test "site information opens the card under the tab's address" {
    var f: Fixture = undefined;
    const t = try opened(&f);
    defer f.deinit();
    try std.testing.expect(isOpen(&f));
    try std.testing.expectEqual(t.id, f.browser.overlay.?.site_card);
    const field = f.browser.tab_field_rect;
    try std.testing.expect(field.w > 0);
    // The site's name heads the card: 12 under the field, its text 17 in
    // from the card's edge, which is 12 left of the field's.
    const head = f.tester.findText("example.com") orelse return error.NoHeader;
    try std.testing.expect(head.y >= field.y + field.h + 12);
    try std.testing.expectApproxEqAbs(field.x - 12 + 17, head.x, 1);
    // And under the pill itself, as drawn.
    const card = f.browser.site_card.rect orelse return error.NotLaidOut;
    for (f.browser.strip.seen.items) |s| if (s.id == t.id) {
        const pill = f.tester.ctx.rects.get(s.node) orelse return error.NotLaidOut;
        try std.testing.expect(card.y >= pill.y + pill.h);
        try std.testing.expect(@abs(card.x - pill.x) < 16);
    };
    try std.testing.expect(f.tester.hasText("Connection is secure"));
    try std.testing.expect(f.tester.hasText("Copy Address"));
    try std.testing.expect(f.tester.hasText("Zoom"));
}

test "esc closes the site card" {
    var f: Fixture = undefined;
    _ = try opened(&f);
    defer f.deinit();
    try std.testing.expect(isOpen(&f));
    _ = f.press("\x1b", 53, .{});
    f.tester.settle(1);
    try std.testing.expect(!isOpen(&f));
}

test "a press outside closes the site card" {
    var f: Fixture = undefined;
    _ = try opened(&f);
    defer f.deinit();
    try std.testing.expect(isOpen(&f));
    f.tester.click(900, 700);
    f.tester.settle(1);
    try std.testing.expect(!isOpen(&f));
}

test "typing in the address closes the site card" {
    var f: Fixture = undefined;
    _ = try opened(&f);
    defer f.deinit();
    try std.testing.expect(isOpen(&f));
    f.tester.typeText("gi");
    f.tester.settle(1);
    try std.testing.expect(!isOpen(&f));
    // The edit goes on without it.
    try std.testing.expect(f.browser.editing_tab != null);
}

test "zoom steps change the tab's zoom" {
    var f: Fixture = undefined;
    const t = try opened(&f);
    defer f.deinit();
    try std.testing.expect(f.tester.hasText("100%"));
    const plus = stepRect(&f, "plus") orelse return error.NoStep;
    f.tester.click(plus.x + plus.w / 2, plus.y + plus.h / 2);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), t.zoom, 0.001);
    f.tester.settle(1);
    try std.testing.expect(f.tester.hasText("110%"));
    // The site keeps it.
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), f.kea.store.double("zoom.www.example.com").?, 0.001);
    const minus = stepRect(&f, "minus") orelse return error.NoStep;
    f.tester.click(minus.x + minus.w / 2, minus.y + minus.h / 2);
    try std.testing.expectApproxEqAbs(@as(f64, 1), t.zoom, 0.001);
    // The card stays while its lines are only steps.
    try std.testing.expect(isOpen(&f));
}

/// The step holding symbol `name`, as last laid out: the card is drawn
/// last, after the strip's own plus.
fn stepRect(f: *Fixture, name: []const u8) ?ui.Rect {
    const nodes = f.tester.ctx.nodes.items;
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        switch (nodes[i].content) {
            .icon => |ic| if (std.mem.eql(u8, ic.name, name)) return nodes[nodes[i].parent].rect,
            else => {},
        }
    }
    return null;
}
