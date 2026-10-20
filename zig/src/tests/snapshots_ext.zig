//! P13's states: Settings › Extensions with the fixture installed, and its
//! pinned button with the puzzle's list open in the strip. Below macOS
//! 15.4 they draw as the app would there: no extensions.
const app = @import("kea");
const Fixture = @import("ui/fixture.zig").Fixture;
const ext_fixture = @import("ui/ext_fixture.zig");

pub fn settings(f: *Fixture) void {
    _ = ext_fixture.install(f) catch null;
    app.settings.open(f.browser, .extensions);
}

pub fn slot(f: *Fixture) void {
    const e = (ext_fixture.install(f) catch null) orelse return;
    e.setPinned(e.installed.items[0].id, true);
    f.tester.settle(1);
    f.browser.overlay = .extension_menu;
    for (f.tester.ctx.a11y_items.items) |item| if (item.role == .button and std.mem.eql(u8, item.label, "Extensions")) {
        if (f.tester.ctx.rects.get(item.id)) |r| f.browser.overlay_anchor = r;
    };
}

const std = @import("std");
