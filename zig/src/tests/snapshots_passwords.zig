//! P10 snapshot states: the Passwords panel with a few kept, one site
//! open, and the `keepAsking` bar over a page.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("ui/fixture.zig").Fixture;

/// The panel up with three accounts on two sites, github.com open. The
/// list is filled after the panel has read the (guarded, empty) keychain.
pub fn panel(f: *Fixture) void {
    const b = f.browser;
    app.sheet.show(b, .managing);
    f.tester.frame();
    const gpa = b.gpa;
    const rows = [_][2][]const u8{ .{ "github.com", "kea" }, .{ "github.com", "kea-work" }, .{ "kea.example", "kea@example.com" } };
    const saved = gpa.alloc(app.vault.Kept, rows.len) catch return;
    for (rows, saved) |r, *k| k.* = .{ .host = gpa.dupe(u8, r[0]) catch unreachable, .user = gpa.dupe(u8, r[1]) catch unreachable };
    app.vault.freeKept(gpa, b.passwords.saved);
    b.passwords.saved = saved;
    b.passwords.panel.open = gpa.dupe(u8, "github.com") catch null;
}

/// A page sent a name and password: the offer to keep it.
pub fn keepAsking(f: *Fixture) void {
    const b = f.browser;
    b.select(b.tabs.items[b.tabs.items.len - 1]);
    const login = (app.vault.Login{ .host = @constCast("kea.example"), .user = @constCast("kea@example.com"), .password = @constCast("hunter2") }).clone(b.gpa) catch return;
    app.browser_passwords.offer(b, .{ .login = login, .changed = false });
}
