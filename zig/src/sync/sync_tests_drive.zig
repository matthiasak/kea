//! Two headless Keas through Google Drive (MockDrive): signed in through
//! the browser's part of the flow, "Kea Sync" made once and found again, an
//! account key carried from one Mac to the other, and Drive refusing.
const std = @import("std");
const testing = std.testing;
const json = @import("../data/json.zig");
const keyring = @import("keyring.zig");
const Temp = @import("../tests/temp.zig").Temp;
const Kea = @import("../app/kea.zig").Kea;
const Sync = @import("sync.zig").Sync;
const MockDrive = @import("mock_drive.zig").MockDrive;

const gpa = testing.allocator;

const Mac = struct {
    temp: Temp,
    kea: *Kea,

    fn init(m: *Mac, mock: *MockDrive, a: std.mem.Allocator) !void {
        m.temp = try Temp.init(gpa);
        m.kea = try Kea.create(gpa, null, .{ .root = m.temp.root, .suite = m.temp.suite, .headless = true });
        const s = &m.kea.sync;
        s.drive_endpoints = try mock.endpoints(a);
        s.setDriveClientId("kea-test-client");
        s.setPlace(.drive);
    }

    fn deinit(m: *Mac) void {
        m.kea.destroy();
        m.temp.deinit(gpa);
    }

    /// Settings' Sign In…, and the browser's part done by the stand-in.
    fn signIn(m: *Mac, mock: *MockDrive) !void {
        const s = &m.kea.sync;
        try testing.expect(s.startDriveSignIn(null) == null);
        try testing.expect(s.drive_signing_in);
        try mock.consent(gpa, s.drive_flow.?.auth_url);
        var n: usize = 0;
        while (s.drive_signing_in and n < 200) : (n += 1) MockDrive.pumpMain(0.05);
        try testing.expect(s.drive_refresh != null);
        try testing.expectEqualStrings("kea.tester@example.com", s.drive_email);
    }
};

test "two Macs through Google Drive, the second with the first's account key" {
    var mock: MockDrive = undefined;
    try mock.start();
    defer mock.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ma: Mac = undefined;
    try ma.init(&mock, arena.allocator());
    defer ma.deinit();
    var mb: Mac = undefined;
    try mb.init(&mock, arena.allocator());
    defer mb.deinit();
    const sa = &ma.kea.sync;
    const sb = &mb.kea.sync;

    try testing.expectEqualStrings("Sign in to Google Drive first", sa.use("correct horse", null).?);
    try ma.signIn(&mock);
    try testing.expectEqualStrings("Choose a Google Drive folder first", sa.use("correct horse", null).?);
    sa.useKeaSyncFolder(null);
    try testing.expectEqualStrings("My Drive/Kea Sync", sa.drive_folder_path);
    try testing.expect(sa.location == .empty);
    sa.setKeyMode(.account_key);
    try testing.expect(sa.useAccountKey(null) == null);
    try testing.expect(sa.ready);
    try testing.expect(std.mem.startsWith(u8, sa.status, "Synced"));

    try testing.expect(ma.kea.bookmarks.add("https://kea.example/drive", "Drive") != null);
    const chat = json.Uuid.random();
    ma.kea.ai.chats.put(.{ .id = chat, .title = "Through Drive", .touched = json.now() });
    ma.kea.history.record("https://kea.example/drive", "Drive");
    sa.syncNow();

    // B finds the same folder, and the store in it, its own key no use.
    try mb.signIn(&mock);
    sb.useKeaSyncFolder(null);
    try testing.expectEqualStrings(sa.drive_folder_id, sb.drive_folder_id);
    try testing.expect(sb.location == .existing_v2 and !sb.location.existing_v2.has_matching_account_key);
    sb.setKeyMode(.account_key);
    try testing.expect(sb.useAccountKey(null) == null);
    try testing.expect(!sb.ready);
    const text = keyring.encodePortableKey(sa.accountKey().?);
    try testing.expect(sb.importAccountKey(&text, null) == null);
    try testing.expect(sb.ready);
    try testing.expect(mb.kea.bookmarks.contains("https://kea.example/drive"));
    try testing.expectEqualStrings("Through Drive", mb.kea.ai.chats.chat(chat).?.title);
    try testing.expect(mb.kea.history.visits.count() > 0);

    // A page sent from A opens on B.
    sa.syncNow();
    try testing.expectEqual(@as(usize, 1), sa.devices.len);
    const ba = try ma.kea.newBrowser();
    sa.send("https://kea.example/sent", "Sent", &sa.devices[0], ba);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena.allocator(), "Sent to {s}", .{sb.name}), ba.announcement.?);
    sb.syncNow();
    var landed = false;
    for (mb.kea.browsers.items) |b| for (b.tabs.items) |tab| {
        landed = landed or std.mem.eql(u8, tab.url(), "https://kea.example/sent");
    };
    try testing.expect(landed);

    // The folder in Trash: nothing written, and said why.
    mock.setTrashed(sa.drive_folder_id, true);
    sa.syncNow();
    try testing.expect(std.mem.indexOf(u8, sa.status, "in Trash") != null);
}

test "Drive refusing a replace: everything put back, nothing lost" {
    var mock: MockDrive = undefined;
    try mock.start();
    defer mock.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ma: Mac = undefined;
    try ma.init(&mock, arena.allocator());
    defer ma.deinit();
    var mb: Mac = undefined;
    try mb.init(&mock, arena.allocator());
    defer mb.deinit();
    const sb = &mb.kea.sync;

    try ma.signIn(&mock);
    ma.kea.sync.useKeaSyncFolder(null);
    try testing.expect(ma.kea.sync.use("correct horse", null) == null);
    try testing.expect(ma.kea.bookmarks.add("https://kea.example/kept", "Kept") != null);
    ma.kea.sync.syncNow();

    try mb.signIn(&mock);
    sb.useKeaSyncFolder(null);
    try testing.expect(sb.location == .existing_v2);
    // Drive full: refused before anything is touched.
    mock.fail_puts = .quota;
    try testing.expect(sb.overwriteExistingStore("new horse", null) == null);
    mock.fail_puts = null;
    try testing.expect(!sb.ready);
    try testing.expect(std.mem.indexOf(u8, sb.warning_error, "Google Drive storage is full") != null);
    try testing.expect(std.mem.indexOf(u8, sb.warning_error, "Existing files were not modified") != null);
    // Deletes refused halfway: what was moved, put back.
    mock.fail_deletes = true;
    try testing.expect(sb.overwriteExistingStore("new horse", null) == null);
    mock.fail_deletes = false;
    try testing.expect(!sb.ready);
    try testing.expect(std.mem.indexOf(u8, sb.warning_error, "previous store was restored") != null);
    // The store as it was: A's passphrase opens it, A's bookmark comes over.
    try testing.expect(sb.use("correct horse", null) == null);
    try testing.expect(sb.ready);
    try testing.expect(mb.kea.bookmarks.contains("https://kea.example/kept"));
    ma.kea.sync.syncNow();
    try testing.expect(ma.kea.sync.ready);
}
