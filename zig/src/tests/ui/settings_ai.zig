//! P9: Settings › AI — the switch, and a provider chosen from its menu.
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

fn clickControl(f: *Fixture, role: ui.A11yRole, label: []const u8) !void {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) {
        const r = c.rects.get(item.id) orelse return error.NoControl;
        return f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
    };
    return error.NoControl;
}

test "settings AI page turns AI on and picks a provider" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("ai", false);
    app.settings.open(b, .ai);
    f.tester.settle(1);
    try t.expectEqual(app.settings.Page.ai, b.settings.page.?);
    try clickControl(&f, .switch_toggle, "Use AI on pages");
    try t.expect(b.prefs.ai);
    f.tester.settle(1);
    try t.expect(f.tester.hasText("Where it runs"));

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const items = try app.settings_ai.providerItems(arena.allocator(), b, 0);
    try t.expectEqualStrings("Choose…", items[0].label);
    try t.expectEqualStrings("Anthropic", items[1].label);
    const click = items[1].click.?;
    click.func(click.ctx, undefined);
    try t.expectEqualStrings("anthropic", b.prefs.ai_provider.?);
    f.tester.settle(1);
    try t.expect(f.tester.hasText("Paste your API key"));
}
