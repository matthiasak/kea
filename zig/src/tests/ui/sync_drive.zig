//! Settings › Sync through Google Drive (MockDrive): signed in from the
//! page, a folder made and picked in the browser, unlocked with this Mac's
//! account key, and the key copied for another Mac.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const MockDrive = app.mock_drive.MockDrive;

const gpa = std.testing.allocator;
const t = std.testing;

fn clickControl(f: *Fixture, role: ui.A11yRole, label: []const u8) !void {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) {
        const r = c.rects.get(item.id) orelse return error.NoControl;
        f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
        f.tester.settle(1);
        return;
    };
    return error.NoControl;
}

test "Drive: signed in, a folder made and picked, the account key used and copied" {
    var mock: MockDrive = undefined;
    try mock.start();
    defer mock.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var a: Fixture = undefined;
    try a.init(gpa, .{ .sidebar = true });
    defer a.deinit();
    const s = &a.kea.sync;
    s.drive_endpoints = try mock.endpoints(arena.allocator());
    s.setDriveClientId("kea-test-client");

    app.settings.open(a.browser, .sync);
    a.tester.settle(1);
    try clickControl(&a, .radio_button, "Drive");
    try t.expectEqual(.drive, s.place);
    try clickControl(&a, .button, "Sign In…");
    try t.expect(a.tester.containsText("Waiting for Google sign-in"));
    try mock.consent(gpa, s.drive_flow.?.auth_url);
    var n: usize = 0;
    while (s.drive_signing_in and n < 200) : (n += 1) MockDrive.pumpMain(0.05);
    a.tester.settle(1);
    try t.expect(a.tester.hasText("kea.tester@example.com"));

    // A folder made in My Drive, gone into, and picked.
    try clickControl(&a, .button, "Browse…");
    try t.expect(a.tester.containsText("No folders made by Kea here"));
    a.browser.settings.sync.drive_new_folder.set("Work");
    try clickControl(&a, .button, "Create");
    try clickControl(&a, .button, "Work");
    try clickControl(&a, .button, "Select Current Folder");
    try t.expectEqualStrings("My Drive/Work", s.drive_folder_path);
    try t.expect(a.tester.hasText("My Drive/Work"));

    try clickControl(&a, .radio_button, "Account Key");
    try t.expect(a.tester.hasText("Ready to create in Keychain"));
    try clickControl(&a, .button, "Use Account Key");
    try t.expect(s.ready);
    try t.expect(a.tester.containsText("Synced"));
    try clickControl(&a, .button, "Copy Key…");
    const copied = a.tester.clipboard.items;
    try t.expectEqual(@as(usize, 59), copied.len);
    try t.expect(std.mem.startsWith(u8, copied, "kea-key-v1-"));
    try t.expectEqualStrings("Account key copied", a.browser.announcement.?);
}
