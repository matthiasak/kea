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


const sigv4 = @import("sigv4.zig");

const MockS3 = struct {
    const SockaddrIn = extern struct { len: u8 = 16, family: u8 = 2, port: u16 = 0, addr: u32 = 0, zero: [8]u8 = @splat(0) };
    extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
    extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern "c" fn getsockname(fd: c_int, addr: *SockaddrIn, len: *u32) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;

    const Obj = struct { data: []u8, rev: u32 };
    fd: c_int,
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    lock: std.c.pthread_mutex_t = .{},
    objs: std.StringArrayHashMapUnmanaged(Obj) = .empty,
    rev: u32 = 0,
    thread: std.Thread = undefined,

    fn start(self: *MockS3) !void {
        const fd = socket(2, 1, 0);
        if (fd < 0) return error.Socket;
        var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0 or listen(fd, 16) != 0) return error.Bind;
        var len: u32 = @sizeOf(SockaddrIn);
        if (getsockname(fd, &addr, &len) != 0) return error.Bind;
        self.* = .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn deinit(self: *MockS3, gpa: std.mem.Allocator) void {
        self.stop.store(true, .release);
        _ = close(self.fd);
        self.thread.join();
        for (self.objs.keys(), self.objs.values()) |k, v| {
            gpa.free(k);
            gpa.free(v.data);
        }
        self.objs.deinit(gpa);
    }

    fn serve(self: *MockS3) void {
        while (!self.stop.load(.acquire)) {
            const client = accept(self.fd, null, null);
            if (client < 0) continue;
            self.handle(client);
            _ = close(client);
        }
    }

    fn handle(self: *MockS3, client: c_int) void {
        const c_gpa = std.heap.c_allocator;
        var arena = std.heap.ArenaAllocator.init(c_gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var buf: [65536]u8 = undefined;
        var total: usize = 0;
        var header_end: ?usize = null;
        var content_len: usize = 0;
        while (total < buf.len) {
            const n = read(client, buf[total..].ptr, buf.len - total);
            if (n <= 0) break;
            total += @intCast(n);
            if (header_end == null) if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                var lines = std.mem.splitSequence(u8, buf[0..idx], "\r\n");
                _ = lines.next();
                while (lines.next()) |ln| {
                    if (std.ascii.startsWithIgnoreCase(ln, "content-length:")) {
                        content_len = std.fmt.parseInt(usize, std.mem.trim(u8, ln["content-length:".len..], " \t"), 10) catch 0;
                    }
                }
            };
            if (header_end) |he| if (total >= he + content_len) break;
        }
        const he = header_end orelse return;
        const head = buf[0 .. he - 4];
        const body = buf[he..@min(total, he + content_len)];
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const req_line = lines.next() orelse return;
        var parts = std.mem.splitScalar(u8, req_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;
        var auth_hdr: []const u8 = "";
        while (lines.next()) |ln| {
            if (std.ascii.startsWithIgnoreCase(ln, "authorization:")) auth_hdr = std.mem.trim(u8, ln["authorization:".len..], " \t");
        }
        if (std.mem.indexOf(u8, auth_hdr, "Credential=GOOG1EKEY/") == null or std.mem.indexOf(u8, auth_hdr, "/auto/s3/aws4_request") == null) {
            return reply(client, "403 Forbidden", "application/xml", "<Error><Code>InvalidAccessKeyId</Code></Error>");
        }
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);

        const bucket_prefix = "/kea-bucket";
        if (!std.mem.startsWith(u8, target, bucket_prefix)) return reply(client, "404 Not Found", "text/plain", "");
        const rest = target[bucket_prefix.len..];
        if (std.mem.startsWith(u8, rest, "?list-type=2")) {
            var prefix: []const u8 = "";
            if (std.mem.indexOf(u8, rest, "prefix=")) |pi| {
                const after = rest[pi + 7 ..];
                const end = std.mem.indexOfScalar(u8, after, '&') orelse after.len;
                prefix = std.mem.replaceOwned(u8, a, after[0..end], "%2F", "/") catch "";
            }
            var xml: std.ArrayList(u8) = .empty;
            xml.appendSlice(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult>") catch return;
            for (self.objs.keys(), self.objs.values()) |k, v| {
                if (!std.mem.startsWith(u8, k, prefix)) continue;
                xml.print(a, "<Contents><Key>{s}</Key><LastModified>2026-10-23T15:00:{d:0>2}.000Z</LastModified><Size>{d}</Size></Contents>", .{ k, v.rev % 60, v.data.len }) catch return;
            }
            xml.appendSlice(a, "</ListBucketResult>") catch return;
            return reply(client, "200 OK", "application/xml", xml.items);
        }
        if (!std.mem.startsWith(u8, rest, "/")) return reply(client, "400 Bad Request", "text/plain", "");
        const key = std.mem.replaceOwned(u8, a, rest[1..], "%2F", "/") catch return;
        if (std.mem.eql(u8, method, "PUT")) {
            self.rev += 1;
            const copy = c_gpa.dupe(u8, body) catch return;
            const gop = self.objs.getOrPut(c_gpa, key) catch return;
            if (gop.found_existing) {
                c_gpa.free(gop.value_ptr.data);
            } else {
                gop.key_ptr.* = c_gpa.dupe(u8, key) catch return;
            }
            gop.value_ptr.* = .{ .data = copy, .rev = self.rev };
            return reply(client, "200 OK", "text/plain", "");
        } else if (std.mem.eql(u8, method, "GET")) {
            const obj = self.objs.get(key) orelse return reply(client, "404 Not Found", "text/plain", "");
            return reply(client, "200 OK", "application/octet-stream", obj.data);
        } else if (std.mem.eql(u8, method, "DELETE")) {
            if (self.objs.fetchSwapRemove(key)) |kv| {
                c_gpa.free(kv.key);
                c_gpa.free(kv.value.data);
            }
            return reply(client, "204 No Content", "text/plain", "");
        }
    }

    fn reply(client: c_int, status: []const u8, ct: []const u8, body: []const u8) void {
        var hbuf: [256]u8 = undefined;
        const h = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, ct, body.len }) catch return;
        _ = write(client, h.ptr, h.len);
        if (body.len > 0) _ = write(client, body.ptr, body.len);
    }
};

test "bucket sync between two Kea instances over HTTP SigV4" {
    const gpa = testing.allocator;
    var srv: MockS3 = undefined;
    try srv.start();
    defer srv.deinit( std.heap.c_allocator);
    const endpoint = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{srv.port});
    defer gpa.free(endpoint);

    var ta = try Temp.init(gpa);
    defer ta.deinit(gpa);
    var tb = try Temp.init(gpa);
    defer tb.deinit(gpa);
    const ka = try Kea.create(gpa, null, .{ .root = ta.root, .suite = ta.suite, .headless = true });
    defer ka.destroy();
    const kb = try Kea.create(gpa, null, .{ .root = tb.root, .suite = tb.suite, .headless = true });
    defer kb.destroy();
    const sa = &ka.sync;
    const sb = &kb.sync;

    // Bad HMAC key is refused with 403 -> "The bucket refused the key".
    try testing.expect(sa.useBucket(endpoint, "kea-bucket", "BADKEY", "secret") == null);
    try testing.expect(sa.use("correct horse", null) == null);
    try testing.expect(!sa.ready);
    try testing.expectEqualStrings("The bucket refused the key", sa.status);

    // Valid HMAC key initializes salt + check on Mac A and joins Mac B.
    try testing.expect(sa.useBucket(endpoint, "kea-bucket", "GOOG1EKEY", "secret") == null);
    try testing.expect(sa.use("correct horse", null) == null);
    try testing.expect(sa.ready);
    try testing.expect(std.mem.startsWith(u8, sa.status, "Synced"));

    try testing.expect(sb.useBucket(endpoint, "kea-bucket", "GOOG1EKEY", "secret") == null);
    try testing.expect(sb.use("wrong horse", null) == null);
    try testing.expect(!sb.ready);
    try testing.expectEqualStrings(core.wrong_passphrase, sb.status);
    try testing.expect(sb.use("correct horse", null) == null);
    try testing.expect(sb.ready);

    // Sync bookmarks and history across the bucket.
    _ = ka.bookmarks.add("https://kea.example/gcs", "GCS Sync");
    ka.history.record("https://kea.example/gcs", "GCS Sync");
    sa.syncNow();
    sb.syncNow();
    try testing.expect(kb.bookmarks.contains("https://kea.example/gcs"));
    try testing.expect(kb.history.visits.count() > 0);
}
test {
    testing.refAllDecls(Sync);
    testing.refAllDecls(@import("drop.zig").Drop);
}
