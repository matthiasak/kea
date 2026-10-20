//! Two headless Keas in step through one folder (the e2e-free half of P12).
const std = @import("std");
const testing = std.testing;
const Temp = @import("../tests/temp.zig").Temp;
const Kea = @import("../app/kea.zig").Kea;
const Sync = @import("sync.zig").Sync;
const core = @import("core.zig");
const disk = @import("../data/disk.zig");

test "folder sync between two Kea instances" {
    const gpa = testing.allocator;
    var ta = try Temp.init(gpa);
    defer ta.deinit(gpa);
    var tb = try Temp.init(gpa);
    defer tb.deinit(gpa);
    const shared = try std.fmt.allocPrint(gpa, "{s}/shared", .{ta.folder});
    defer gpa.free(shared);
    disk.makePath(gpa, shared);

    const ka = try Kea.create(gpa, null, .{ .root = ta.root, .suite = ta.suite, .headless = true });
    defer ka.destroy();
    const kb = try Kea.create(gpa, null, .{ .root = tb.root, .suite = tb.suite, .headless = true });
    defer kb.destroy();
    const sa = &ka.sync;
    const sb = &kb.sync;
    try testing.expect(!sa.device.eql(sb.device));

    try testing.expectEqualStrings("Fill in the bucket details first", sa.use("correct horse", null).?);
    sa.setPlace(.folder);
    try testing.expectEqualStrings("Choose a folder first", sa.use("correct horse", null).?);
    sa.chooseFolder(shared);
    try testing.expectEqualStrings("Type the passphrase", sa.status);
    try testing.expectEqualStrings("Type a passphrase", sa.use("", null).?);
    try testing.expect(sa.use("correct horse", null) == null);
    try testing.expect(sa.ready);
    try testing.expect(std.mem.startsWith(u8, sa.status, "Synced"));

    sb.chooseFolder(shared);
    try testing.expect(sb.use("wrong horse", null) == null);
    try testing.expect(!sb.ready);
    try testing.expectEqualStrings(core.wrong_passphrase, sb.status);
    try testing.expect(sb.use("correct horse", null) == null);
    try testing.expect(sb.ready);
    try testing.expect(std.mem.startsWith(u8, sb.status, "Synced"));

    try testing.expect(ka.bookmarks.add("https://kea.example/flight", "Kea") != null);
    try testing.expect(!kb.bookmarks.contains("https://kea.example/flight"));
    sa.syncNow();
    sb.syncNow();
    try testing.expect(kb.bookmarks.contains("https://kea.example/flight"));

    // B heard from A, and A's state is on disk.
    try testing.expectEqual(@as(usize, 1), sb.devices.len);
    try testing.expect(sb.devices[0].id.eql(sa.device));
    const state = ka.store.readFile("sync.json").?;
    defer gpa.free(state);
    try testing.expect(std.mem.indexOf(u8, state, "\"joined\":true") != null);

    // Settings' checks, and the kinds kept as Swift writes them.
    try testing.expectEqualStrings("Use an https address (http only on this Mac)", sb.useBucket("http://example.com", "b", "a", "s").?);
    try testing.expectEqualStrings("Fill in the bucket, access key and secret", sb.useBucket("https://storage.googleapis.com", " ", "a", "s").?);
    sb.setKind(.history, false);
    var again: Sync = undefined;
    again.init(kb);
    defer again.deinit();
    try testing.expect(!again.kinds.contains(.history) and again.kinds.contains(.tabs));
    try testing.expect(again.device.eql(sb.device));
}

test {
    testing.refAllDecls(Sync);
    testing.refAllDecls(@import("drop.zig").Drop);
}
