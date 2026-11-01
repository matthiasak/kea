//! Google Drive sync against MockDrive: signing in, the Drop, folder browsing.
const std = @import("std");
const testing = std.testing;
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const urlsession = @import("../sys/urlsession.zig");
const Temp = @import("../tests/temp.zig").Temp;
const oauth = @import("gdrive_oauth.zig");
const gdrive = @import("gdrive.zig");
const Drop = @import("drop.zig").Drop;
const MockDrive = @import("mock_drive.zig").MockDrive;

const Heard = struct {
    result: ?oauth.AuthResult = null,

    fn done(ctx: *anyopaque, r: oauth.AuthResult) void {
        const self: *Heard = @ptrCast(@alignCast(ctx));
        self.result = r;
    }

    fn wait(self: *Heard) !oauth.AuthResult {
        var n: usize = 0;
        while (self.result == null and n < 200) : (n += 1) MockDrive.pumpMain(0.05);
        return self.result orelse error.Timeout;
    }

    fn start(self: *Heard, ep: oauth.AuthEndpoints) !*oauth.LoopbackFlow {
        return oauth.LoopbackFlow.start(testing.allocator, ep, "kea-test-client", "kea-test-secret", false, .{ .ctx = self, .func = done });
    }
};

test "Drive sign-in: loopback PKCE, wrong state, cancel, wrong verifier" {
    const gpa = testing.allocator;
    var mock: MockDrive = undefined;
    try mock.start();
    defer mock.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ep = try mock.endpoints(a);
    const sign_in = @import("../ai/sign_in.zig");

    {
        var heard: Heard = .{};
        const flow = try heard.start(ep);
        const query = flow.auth_url[std.mem.indexOfScalar(u8, flow.auth_url, '?').? + 1 ..];
        try testing.expectEqual(@as(usize, 32), sign_in.queryItem(a, query, "state").?.len);
        try testing.expectEqualStrings(oauth.scope, sign_in.queryItem(a, query, "scope").?);
        try testing.expectEqualStrings("offline", sign_in.queryItem(a, query, "access_type").?);
        const redirect = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ flow.port, oauth.redirect_path });
        try testing.expectEqualStrings(redirect, sign_in.queryItem(a, query, "redirect_uri").?);
        try mock.consent(gpa, flow.auth_url);
        const r = try heard.wait();
        defer r.deinit(gpa);
        try testing.expect(r == .ok);
        try testing.expectEqualStrings("kea.tester@example.com", r.ok.email);
        try testing.expect(r.ok.refresh_token.len > 0 and r.ok.access_token.len > 0);
        try testing.expect(r.ok.expires_at > json.now());
        try testing.expectEqual(@as(usize, 1), mock.exchanges);
    }
    // A callback that isn't the flow's: refused, nothing traded.
    {
        var heard: Heard = .{};
        const flow = try heard.start(ep);
        const forged = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}?code=4%2Fforged&state=00000000000000000000000000000000", .{ flow.port, oauth.redirect_path });
        const session = urlsession.ephemeral(10);
        defer objc.release(session);
        const page = (try urlsession.send(a, session, "GET", forged, &.{}, null)).?;
        try testing.expect(std.mem.indexOf(u8, page.body, "didn't work") != null);
        const r = try heard.wait();
        defer r.deinit(gpa);
        try testing.expect(r == .failed);
        try testing.expectEqual(@as(usize, 1), mock.exchanges);
    }
    {
        var heard: Heard = .{};
        const flow = try heard.start(ep);
        flow.cancel();
        const r = try heard.wait();
        try testing.expect(r == .cancelled);
    }
    // Google checks the verifier against the challenge.
    {
        var heard: Heard = .{};
        const flow = try heard.start(ep);
        flow.verifier = @splat('A');
        try mock.consent(gpa, flow.auth_url);
        const r = try heard.wait();
        defer r.deinit(gpa);
        try testing.expect(r == .failed);
        try testing.expectEqual(@as(usize, 1), mock.exchanges);
    }
}

test "Drive refresh token: a new access token, then revoked" {
    const gpa = testing.allocator;
    var mock: MockDrive = undefined;
    try mock.start();
    defer mock.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ep = try mock.endpoints(a);
    const t = try mock.issueTokens();
    const session = urlsession.ephemeral(30);
    defer objc.release(session);
    const p = try oauth.refreshAccessToken(a, session, ep, "kea-test-client", null, t.refresh);
    try testing.expect(!std.mem.eql(u8, p.access_token, t.access) and p.expires_in > 0 and p.refresh_token == null);
    mock.revokeRefreshTokens();
    try testing.expectError(error.AuthRevoked, oauth.refreshAccessToken(a, session, ep, "kea-test-client", null, t.refresh));
}

fn driveDrop(mock: *MockDrive, a: std.mem.Allocator, root_id: []const u8) !Drop {
    const t = try mock.issueTokens();
    const client = try gdrive.Client.init(testing.allocator, try mock.endpoints(a), "kea-test-client", null, t.refresh, t.access, json.now() + 3600, root_id);
    return Drop.drive(testing.allocator, client);
}

test "Drop over Google Drive" {
    var mock: MockDrive = undefined;
    try mock.start();
    defer mock.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var browse = try driveDrop(&mock, a, "");
    defer browse.deinit();
    const root = (try gdrive.createFolder(a, &browse, "root", "Kea Sync")).id;
    var d = try driveDrop(&mock, a, root);
    defer d.deinit();

    const names = [_][]const u8{ "kea/v2/heads/A.head", "kea/v2/packs/x.pack", "kea/v2/inbox/6F9619FF-8B86-D011-B42D-00C04FC964FF/7A1B2C3D-0000-4000-8000-000000000001.kea" };
    for (names, 0..) |n, i| try d.put(a, n, try std.fmt.allocPrint(a, "data {d}", .{i}));
    for (names, 0..) |n, i| try testing.expectEqualStrings(try std.fmt.allocPrint(a, "data {d}", .{i}), (try d.get(a, n)).?);
    const big = try a.alloc(u8, 1 << 20);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try d.put(a, "kea/v2/packs/big.pack", big);
    try testing.expectEqualSlices(u8, big, (try d.get(a, "kea/v2/packs/big.pack")).?);
    {
        // A new Drop, knowing nothing yet, sees it all.
        var fresh = try driveDrop(&mock, a, root);
        defer fresh.deinit();
        const all = try fresh.list(a, "kea/v2/");
        try testing.expectEqual(@as(usize, 4), all.count());
        for (names) |n| try testing.expect(all.contains(n));
        try testing.expectEqualStrings("data 1", (try fresh.get(a, names[1])).?);
    }

    // Written over in place: one file, new bytes.
    const before = mock.idOf(a, root, names[0]).?;
    try d.put(a, names[0], "newer");
    try testing.expectEqualStrings(before, mock.idOf(a, root, names[0]).?);
    try testing.expectEqualStrings("newer", (try d.get(a, names[0])).?);
    try testing.expectEqual(@as(usize, 1), (try d.list(a, "kea/v2/heads/")).count());

    try testing.expectEqual(@as(usize, 0), (try d.list(a, "kea/v9/")).count());
    try testing.expect((try d.get(a, "kea/v2/heads/B.head")) == null);
    try testing.expect((try d.get(a, "kea/v9/nothing")) == null);
    try d.delete(a, names[1]);
    try testing.expect((try d.get(a, names[1])) == null);
    try d.delete(a, names[1]);
    try d.delete(a, "kea/v9/nothing");

    // Damaged under us: a short download is refused.
    try testing.expect(mock.writeFile(root, names[0], "n"));
    try testing.expectEqualStrings("n", (try d.get(a, names[0])).?);

    mock.expireAccessTokens();
    try d.put(a, names[0], "after refresh");
    try testing.expect(!d.where.drive.rotated);
    mock.rotate_refresh = true;
    mock.expireAccessTokens();
    const old = try a.dupe(u8, d.where.drive.refresh_token);
    _ = try d.list(a, "kea/");
    try testing.expect(d.where.drive.rotated and !std.mem.eql(u8, old, d.where.drive.refresh_token));
    mock.rotate_refresh = false;

    mock.fail_puts = .quota;
    try testing.expectError(error.SyncFailed, d.put(a, names[0], "x"));
    try testing.expectEqualStrings("Google Drive storage is full", d.why);
    mock.fail_puts = .server;
    try testing.expectError(error.SyncFailed, d.put(a, "kea/v2/new/y", "x"));
    try testing.expectEqualStrings("Google Drive answered 500", d.why);
    mock.fail_puts = null;

    // The folder is looked at once a Drop: new ones for each case.
    const Case = struct {
        fn expectFails(m: *MockDrive, al: std.mem.Allocator, r: []const u8, says: []const u8) !void {
            var t = try driveDrop(m, al, r);
            defer t.deinit();
            try testing.expectError(error.SyncFailed, t.put(al, "kea/x", "y"));
            try testing.expect(std.mem.indexOf(u8, t.why, says) != null);
        }
    };
    mock.setTrashed(root, true);
    try Case.expectFails(&mock, a, root, "in Trash");
    mock.setTrashed(root, false);
    mock.setReadOnly(root, true);
    try Case.expectFails(&mock, a, root, "read-only");
    mock.setReadOnly(root, false);
    {
        var t = try driveDrop(&mock, a, root);
        defer t.deinit();
        mock.revokeRefreshTokens();
        mock.expireAccessTokens();
        try testing.expectError(error.SyncFailed, t.list(a, "kea/"));
        try testing.expectEqualStrings("Google Drive sign-in expired — sign in again", t.why);
    }
    mock.remove(root);
    try Case.expectFails(&mock, a, root, "wasn't found");
}

test "Drive folder browsing" {
    var mock: MockDrive = undefined;
    try mock.start();
    defer mock.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = try driveDrop(&mock, a, "");
    defer d.deinit();
    _ = try gdrive.createFolder(a, &d, "root", "beta");
    _ = try gdrive.createFolder(a, &d, "root", "Alpha");
    mock.setReadOnly((try gdrive.createFolder(a, &d, "root", "gamma")).id, true);
    const found = try gdrive.listFolders(a, &d, "root");
    try testing.expectEqual(@as(usize, 3), found.len);
    for (found, [_][]const u8{ "Alpha", "beta", "gamma" }, [_]bool{ true, true, false }) |f, name, w| {
        try testing.expectEqualStrings(name, f.name);
        try testing.expectEqual(w, f.can_write);
    }
    const k = try gdrive.ensureNamedSubfolder(a, &d, "root", "Kea Sync");
    try testing.expectEqualStrings(k.id, (try gdrive.ensureNamedSubfolder(a, &d, "root", "Kea Sync")).id);
    try testing.expectEqual(@as(usize, 4), (try gdrive.listFolders(a, &d, "root")).len);
    const odd = try gdrive.createFolder(a, &d, "root", "it's a \\ test");
    try testing.expectEqualStrings(odd.id, (try gdrive.ensureNamedSubfolder(a, &d, "root", "it's a \\ test")).id);
}

test "inspectRoot: folder, Drive, missing folder" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    const dir = try std.fmt.allocPrint(a, "{s}/inspect", .{t.folder});
    @import("../data/disk.zig").makePath(gpa, dir);
    var f = try Drop.folder(gpa, dir);
    defer f.deinit();
    for ([_][]const u8{ "notes.txt", ".hidden", "kea/v2/x" }) |n| try f.put(a, n, "x");
    const info = try f.inspectRoot(a);
    try testing.expectEqual(@as(usize, 1), info.non_kea_count);
    try testing.expectEqualStrings("notes.txt", info.sample_name);
    try testing.expect(info.has_kea_dir);
    var gone = try Drop.folder(gpa, "/nonexistent/kea-inspect");
    defer gone.deinit();
    try testing.expectError(error.SyncFailed, gone.inspectRoot(a));

    var mock: MockDrive = undefined;
    try mock.start();
    defer mock.deinit();
    var browse = try driveDrop(&mock, a, "");
    defer browse.deinit();
    var d = try driveDrop(&mock, a, (try gdrive.createFolder(a, &browse, "root", "Kea Sync")).id);
    defer d.deinit();
    const empty = try d.inspectRoot(a);
    try testing.expect(empty.non_kea_count == 0 and !empty.has_kea_dir);
    for ([_][]const u8{ "notes.txt", "kea/v2/x" }) |n| try d.put(a, n, "x");
    const di = try d.inspectRoot(a);
    try testing.expectEqual(@as(usize, 1), di.non_kea_count);
    try testing.expectEqualStrings("notes.txt", di.sample_name);
    try testing.expect(di.has_kea_dir);
}
