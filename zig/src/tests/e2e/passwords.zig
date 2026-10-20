//! P10: a sign-in form sent and the page moved on — the `keepAsking` bar
//! offers to keep it, and Save goes through the vault, which under tests
//! never reaches the keychain.
const std = @import("std");
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "form submit offers to save", .run = submitOffers },
};

fn drew(b: *app.Browser, said: []const u8) bool {
    const w = b.window orelse return false;
    const s = w.surface orelse return false;
    for (s.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, said)) return true,
        else => {},
    };
    return false;
}

fn offered(b: *app.Browser) bool {
    return b.passwords.offering != null;
}

fn arrived(t: *app.Tab) bool {
    return std.mem.eql(u8, t.page_title, "Welcome") and !t.loading;
}

fn submitOffers(h: *Harness) !void {
    const b = try h.start();
    const t = try web.open(h, b, "kea-test://site/f/login.html");
    _ = try web.eval(h, t, "document.getElementById('user').value = 'kea@example.com'; document.getElementById('pass').value = 'hunter2'; document.forms[0].requestSubmit(); 1");
    try h.waitFor(t, arrived, 10, "the page after the sign-in");
    try h.waitFor(b, offered, 5, "the offer to save");
    const o = b.passwords.offering.?;
    try h.expect(std.mem.eql(u8, o.login.user, "kea@example.com") and std.mem.eql(u8, o.login.password, "hunter2") and !o.changed, "offer {s}/{s} changed {}", .{ o.login.user, o.login.password, o.changed });
    h.frame();
    const line = "Save the password for kea@example.com on site?";
    try h.expect(drew(b, line), "no keepAsking bar", .{});
    try h.expect(drew(b, "Save") and drew(b, "Never here"), "no Save or Never here", .{});
    app.browser_passwords.keepOffer(b);
    try h.expect(b.passwords.offering == null, "still offering", .{});
    const said = b.announcement orelse "";
    try h.expect(std.mem.eql(u8, said, "Password saved for site"), "announced '{s}'", .{said});
    h.frame();
    try h.expect(!drew(b, line), "the bar stayed", .{});
}
