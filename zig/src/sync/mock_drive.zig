//! A stand-in Google for tests: OAuth (authorize, token) and as much of
//! Drive v3 as gdrive.zig speaks, in memory, on 127.0.0.1 on its own thread.
//! Unit tests and the UI harness (`kea.mock_drive`) use it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const urlsession = @import("../sys/urlsession.zig");
const sign_in = @import("../ai/sign_in.zig");
const uriEncode = @import("sigv4.zig").uriEncode;
const oauth = @import("gdrive_oauth.zig");
const net = oauth.net;

extern "c" const kCFRunLoopDefaultMode: objc.Object;
extern "c" fn CFRunLoopRunInMode(mode: objc.Object, seconds: f64, return_after_source_handled: u8) i32;

const heap = std.heap.c_allocator;
const folder_mime = "application/vnd.google-apps.folder";

pub const File = struct {
    id: []u8,
    name: []u8,
    parent: []u8,
    folder: bool,
    data: []u8 = &.{},
    /// Unix ms, distinct and rising.
    modified_ms: i64,
    trashed: bool = false,
    can_add_children: bool = true,

    fn free(f: File) void {
        for ([_][]u8{ f.id, f.name, f.parent, f.data }) |s| heap.free(s);
    }
};

const Reply = struct { status: []const u8 = "200 OK", ct: []const u8 = "application/json", extra: []const u8 = "", body: []const u8 = "" };

fn failure(status: []const u8, body: []const u8) Reply {
    return .{ .status = status, .body = body };
}

const not_found = failure("404 Not Found", "{\"error\":{\"code\":404,\"message\":\"File not found\"}}");
const bad = failure("400 Bad Request", "{\"error\":\"invalid_request\"}");
const invalid_grant = failure("400 Bad Request", "{\"error\":\"invalid_grant\"}");
const forbidden = failure("403 Forbidden", "{\"error\":{\"code\":403,\"errors\":[{\"reason\":\"insufficientFilePermissions\"}]}}");

fn item(a: Allocator, query: []const u8, name: []const u8) []const u8 {
    return sign_in.queryItem(a, query, name) orelse "";
}

pub const MockDrive = struct {
    fd: c_int,
    port: u16,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    lock: std.c.pthread_mutex_t = .{},
    files: std.ArrayList(File) = .empty,
    serial: u32 = 0,
    last_ms: i64 = 0,
    /// Codes and tokens handed out, kept till deinit.
    issued: std.heap.ArenaAllocator,
    codes: std.ArrayList(struct { code: []const u8, challenge: []const u8, redirect: []const u8 }) = .empty,
    access: std.ArrayList([]const u8) = .empty,
    refresh: std.ArrayList([]const u8) = .empty,
    email: []const u8 = "kea.tester@example.com",
    // Knobs: set between requests.
    /// A refresh hands out a new refresh token, the old one dropped.
    rotate_refresh: bool = false,
    /// Uploads and creates answer 403 storageQuotaExceeded, or 500.
    fail_puts: ?enum { quota, server } = null,
    /// Deleting a file (not a folder) answers 403.
    fail_deletes: bool = false,
    /// Authorization codes traded for tokens.
    exchanges: usize = 0,

    /// Serving, with My Drive as "root".
    pub fn start(self: *MockDrive) !void {
        var port: u16 = 0;
        const fd = try net.listenLocal(&port);
        self.* = .{ .fd = fd, .port = port, .thread = undefined, .issued = .init(heap) };
        try self.files.append(heap, .{ .id = try heap.dupe(u8, "root"), .name = try heap.dupe(u8, "My Drive"), .parent = &.{}, .folder = true, .modified_ms = self.tick() });
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    pub fn deinit(self: *MockDrive) void {
        self.stop.store(true, .release);
        self.thread.join();
        _ = net.close(self.fd);
        for (self.files.items) |f| f.free();
        self.files.deinit(heap);
        self.codes.deinit(heap);
        self.access.deinit(heap);
        self.refresh.deinit(heap);
        self.issued.deinit();
    }

    fn hold(self: *MockDrive) void {
        _ = std.c.pthread_mutex_lock(&self.lock);
    }

    fn unlock(self: *MockDrive) void {
        _ = std.c.pthread_mutex_unlock(&self.lock);
    }

    fn serve(self: *MockDrive) void {
        while (!self.stop.load(.acquire)) {
            if (!net.ready(self.fd, 100)) continue;
            const c = net.acceptOne(self.fd) orelse continue;
            defer _ = net.close(c);
            var arena = std.heap.ArenaAllocator.init(heap);
            defer arena.deinit();
            const a = arena.allocator();
            const req = net.readRequest(a, c, 5000) orelse continue;
            const out = blk: {
                self.hold();
                defer self.unlock();
                break :blk self.handle(a, req) catch failure("500 Internal Server Error", "");
            };
            net.reply(c, out.status, out.ct, out.extra, out.body);
        }
    }

    fn tick(self: *MockDrive) i64 {
        const now: i64 = @intFromFloat(json.toUnix(json.now()) * 1000);
        self.last_ms = @max(now, self.last_ms + 1);
        return self.last_ms;
    }

    fn issue(self: *MockDrive, comptime prefix: []const u8) ![]const u8 {
        self.serial += 1;
        return std.fmt.allocPrint(self.issued.allocator(), prefix ++ "{d}", .{self.serial});
    }

    fn index(self: *MockDrive, id: []const u8) ?usize {
        for (self.files.items, 0..) |f, i| if (std.mem.eql(u8, f.id, id)) return i;
        return null;
    }

    fn find(self: *MockDrive, id: []const u8) ?*File {
        return &self.files.items[self.index(id) orelse return null];
    }

    fn removeTree(self: *MockDrive, id: []const u8) void {
        const f = self.files.swapRemove(self.index(id) orelse return);
        defer f.free();
        while (true) {
            const child = for (self.files.items) |x| {
                if (std.mem.eql(u8, x.parent, f.id)) break x.id;
            } else break;
            self.removeTree(child);
        }
    }

    /// The live file at `path` ("kea/v2/heads/A.head") under folder `root_id`.
    fn resolve(self: *MockDrive, root_id: []const u8, path: []const u8) ?*File {
        var at: ?*File = self.find(root_id) orelse return null;
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            const parent = at.?.id;
            at = null;
            for (self.files.items) |*f| {
                if (!f.trashed and std.mem.eql(u8, f.parent, parent) and std.mem.eql(u8, f.name, seg)) at = f;
            }
            if (at == null) return null;
        }
        return at;
    }

    fn describe(a: Allocator, f: File) ![]u8 {
        const secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(f.modified_ms, 1000)) };
        const yd = secs.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = secs.getDaySeconds();
        const when = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), @as(u64, @intCast(@mod(f.modified_ms, 1000))),
        });
        return json.encode(a, .{
            .id = f.id,
            .name = f.name,
            .mimeType = if (f.folder) folder_mime else "application/octet-stream",
            .modifiedTime = when,
            .size = if (f.folder) null else try std.fmt.allocPrint(a, "{d}", .{f.data.len}),
            .trashed = f.trashed,
            .parents = @as([]const []const u8, &.{f.parent}),
            .capabilities = .{ .canAddChildren = f.folder and f.can_add_children },
        });
    }

    fn handle(self: *MockDrive, a: Allocator, req: net.Request) !Reply {
        const q_at = std.mem.indexOfScalar(u8, req.target, '?');
        const path = req.target[0 .. q_at orelse req.target.len];
        const query = if (q_at) |i| req.target[i + 1 ..] else "";
        const is = struct {
            fn f(x: []const u8, y: []const u8) bool {
                return std.mem.eql(u8, x, y);
            }
        }.f;
        if (is(path, "/o/oauth2/v2/auth")) return self.authorize(a, query);
        if (is(path, "/token") and is(req.method, "POST")) return self.token(a, req.body);
        const upload = std.mem.startsWith(u8, path, "/upload/drive/v3");
        if (!upload and !std.mem.startsWith(u8, path, "/drive/v3")) return not_found;
        const auth = req.header("authorization") orelse "";
        const live = std.mem.startsWith(u8, auth, "Bearer ") and for (self.access.items) |t| {
            if (is(t, auth[7..])) break true;
        } else false;
        if (!live) return failure("401 Unauthorized", "{\"error\":{\"code\":401,\"message\":\"Invalid Credentials\"}}");
        const rest = path[@as(usize, if (upload) "/upload/drive/v3".len else "/drive/v3".len)..];
        if (is(rest, "/about")) return .{ .body = try json.encode(a, .{ .user = .{ .emailAddress = self.email, .displayName = "Kea Tester" } }) };
        if (is(rest, "/files")) {
            if (is(req.method, "GET")) return self.search(a, query);
            if (!is(req.method, "POST")) return bad;
            const Meta = struct { name: []const u8 = "", mimeType: []const u8 = "", parents: []const []const u8 = &.{} };
            var meta_text = req.body;
            var data: []const u8 = "";
            if (upload) {
                const ct = req.header("content-type") orelse "";
                const bi = std.mem.indexOf(u8, ct, "boundary=") orelse return bad;
                const delim = try std.fmt.allocPrint(a, "\r\n--{s}", .{std.mem.trim(u8, ct[bi + 9 ..], "\"")});
                // "--b\r\n<headers>\r\n\r\n<json>\r\n--b\r\n<headers>\r\n\r\n<data>\r\n--b--"
                var parts = std.mem.splitSequence(u8, try std.mem.concat(a, u8, &.{ "\r\n", req.body }), delim);
                _ = parts.next();
                const bodyOf = struct {
                    fn f(p: []const u8) ?[]const u8 {
                        return p[(std.mem.indexOf(u8, p, "\r\n\r\n") orelse return null) + 4 ..];
                    }
                }.f;
                meta_text = bodyOf(parts.next() orelse return bad) orelse return bad;
                data = bodyOf(parts.next() orelse return bad) orelse return bad;
            }
            const m = std.json.parseFromSliceLeaky(Meta, a, meta_text, .{ .ignore_unknown_fields = true }) catch return bad;
            if (self.fail_puts) |f| return putFailure(f);
            if (m.parents.len != 1 or m.name.len == 0) return bad;
            const p = self.find(m.parents[0]) orelse return not_found;
            if (!p.folder or !p.can_add_children) return forbidden;
            try self.files.append(heap, .{
                .id = try std.fmt.allocPrint(heap, "mock{d}", .{self.serial + 1}),
                .name = try heap.dupe(u8, m.name),
                .parent = try heap.dupe(u8, m.parents[0]),
                .folder = is(m.mimeType, folder_mime),
                .data = try heap.dupe(u8, data),
                .modified_ms = self.tick(),
            });
            self.serial += 1;
            return .{ .body = try describe(a, self.files.items[self.files.items.len - 1]) };
        }
        if (!std.mem.startsWith(u8, rest, "/files/")) return not_found;
        const f = self.find(rest["/files/".len..]) orelse return not_found;
        if (is(req.method, "GET")) {
            if (is(item(a, query, "alt"), "media")) return .{ .ct = "application/octet-stream", .body = try a.dupe(u8, f.data) };
            return .{ .body = try describe(a, f.*) };
        }
        if (is(req.method, "PATCH") and upload) {
            if (self.fail_puts) |why| return putFailure(why);
            if (self.find(f.parent)) |p| if (!p.can_add_children) return forbidden;
            const copy = try heap.dupe(u8, req.body);
            heap.free(f.data);
            f.data = copy;
            f.modified_ms = self.tick();
            return .{ .body = try describe(a, f.*) };
        }
        if (is(req.method, "DELETE")) {
            if (self.fail_deletes and !f.folder) return forbidden;
            self.removeTree(f.id);
            return .{ .status = "204 No Content" };
        }
        return bad;
    }

    fn putFailure(why: @FieldType(MockDrive, "fail_puts")) Reply {
        return switch (why.?) {
            .quota => failure("403 Forbidden", "{\"error\":{\"code\":403,\"errors\":[{\"domain\":\"usageLimits\",\"reason\":\"storageQuotaExceeded\"}],\"message\":\"The user's Drive storage quota has been exceeded.\"}}"),
            .server => failure("500 Internal Server Error", "{\"error\":{\"code\":500}}"),
        };
    }

    fn authorize(self: *MockDrive, a: Allocator, query: []const u8) !Reply {
        const redirect = item(a, query, "redirect_uri");
        const challenge = item(a, query, "code_challenge");
        if (!std.mem.eql(u8, item(a, query, "code_challenge_method"), "S256") or redirect.len == 0 or challenge.len == 0) return bad;
        const keep = self.issued.allocator();
        const code = try self.issue("4/mock-code-");
        try self.codes.append(heap, .{ .code = code, .challenge = try keep.dupe(u8, challenge), .redirect = try keep.dupe(u8, redirect) });
        const to = try std.fmt.allocPrint(a, "Location: {s}?code={s}&state={s}\r\n", .{ redirect, try uriEncode(a, code, true), try uriEncode(a, item(a, query, "state"), true) });
        return .{ .status = "302 Found", .ct = "text/plain", .extra = to };
    }

    fn token(self: *MockDrive, a: Allocator, body: []const u8) !Reply {
        const grant = item(a, body, "grant_type");
        var refresh: ?[]const u8 = null;
        if (std.mem.eql(u8, grant, "authorization_code")) {
            const code = item(a, body, "code");
            const i = for (self.codes.items, 0..) |c, i| {
                if (std.mem.eql(u8, c.code, code)) break i;
            } else return invalid_grant;
            const c = self.codes.swapRemove(i);
            var cb: [43]u8 = undefined;
            if (!std.mem.eql(u8, sign_in.challengeFor(item(a, body, "code_verifier"), &cb), c.challenge) or !std.mem.eql(u8, item(a, body, "redirect_uri"), c.redirect))
                return invalid_grant;
            self.exchanges += 1;
            refresh = try self.issue("1//mock-refresh-");
            try self.refresh.append(heap, refresh.?);
        } else if (std.mem.eql(u8, grant, "refresh_token")) {
            const old = item(a, body, "refresh_token");
            const i = for (self.refresh.items, 0..) |t, i| {
                if (std.mem.eql(u8, t, old)) break i;
            } else return invalid_grant;
            if (self.rotate_refresh) {
                _ = self.refresh.swapRemove(i);
                refresh = try self.issue("1//mock-refresh-");
                try self.refresh.append(heap, refresh.?);
            }
        } else return bad;
        const access = try self.issue("ya29.mock-access-");
        try self.access.append(heap, access);
        return .{ .body = try json.encode(a, .{ .access_token = access, .expires_in = @as(u32, 3599), .refresh_token = refresh, .token_type = "Bearer", .scope = oauth.scope }) };
    }

    /// `files.list`: the `q` forms gdrive.zig writes, `pageSize`, `pageToken`.
    fn search(self: *MockDrive, a: Allocator, query: []const u8) !Reply {
        const q = item(a, query, "q");
        var parent: ?[]const u8 = null;
        var name: ?[]const u8 = null;
        var mime: ?[]const u8 = null;
        var trashed: ?bool = null;
        var i: usize = 0;
        var from: usize = 0;
        var quoted = false;
        while (i <= q.len) : (i += 1) {
            if (i < q.len) {
                if (quoted and q[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (q[i] == '\'') quoted = !quoted;
                if (quoted or !std.mem.startsWith(u8, q[i..], " and ")) continue;
            }
            const clause = q[from..i];
            from = i + " and ".len;
            if (std.mem.endsWith(u8, clause, " in parents")) {
                parent = literal(a, clause[0 .. clause.len - " in parents".len]) orelse return bad;
            } else if (std.mem.startsWith(u8, clause, "name = ")) {
                name = literal(a, clause["name = ".len..]) orelse return bad;
            } else if (std.mem.startsWith(u8, clause, "mimeType = ")) {
                mime = literal(a, clause["mimeType = ".len..]) orelse return bad;
            } else if (std.mem.eql(u8, clause, "trashed = false") or std.mem.eql(u8, clause, "trashed = true")) {
                trashed = std.mem.endsWith(u8, clause, "true");
            } else return bad;
            i += " and ".len - 1;
        }
        const size = std.fmt.parseInt(usize, item(a, query, "pageSize"), 10) catch 100;
        const skip = std.fmt.parseInt(usize, item(a, query, "pageToken"), 10) catch 0;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "{\"files\":[");
        var matched: usize = 0;
        for (self.files.items) |f| {
            if (parent) |p| if (!std.mem.eql(u8, f.parent, p)) continue;
            if (name) |n| if (!std.mem.eql(u8, f.name, n)) continue;
            if (mime) |m| if (!std.mem.eql(u8, m, if (f.folder) folder_mime else "application/octet-stream")) continue;
            if (trashed) |t| if (f.trashed != t) continue;
            matched += 1;
            if (matched <= skip or matched > skip + size) continue;
            if (matched > skip + 1) try out.append(a, ',');
            try out.appendSlice(a, try describe(a, f));
        }
        try out.append(a, ']');
        if (matched > skip + size) try out.print(a, ",\"nextPageToken\":\"{d}\"", .{skip + size});
        try out.append(a, '}');
        return .{ .body = out.items };
    }

    fn literal(a: Allocator, s: []const u8) ?[]const u8 {
        if (s.len < 2 or s[0] != '\'' or s[s.len - 1] != '\'') return null;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < s.len - 1) : (i += 1) {
            if (s[i] == '\\') i += 1;
            out.append(a, s[i]) catch return null;
        }
        return out.items;
    }

    // MARK: for tests

    /// This server's URLs, on `a`.
    pub fn endpoints(self: *MockDrive, a: Allocator) !oauth.AuthEndpoints {
        const base = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.port});
        return .{
            .auth_url = try std.mem.concat(a, u8, &.{ base, "/o/oauth2/v2/auth" }),
            .token_url = try std.mem.concat(a, u8, &.{ base, "/token" }),
            .api_base = try std.mem.concat(a, u8, &.{ base, "/drive/v3" }),
            .upload_base = try std.mem.concat(a, u8, &.{ base, "/upload/drive/v3" }),
        };
    }

    /// A signed-in account without the browser; valid till deinit.
    pub fn issueTokens(self: *MockDrive) !struct { refresh: []const u8, access: []const u8 } {
        self.hold();
        defer self.unlock();
        const refresh = try self.issue("1//mock-refresh-");
        try self.refresh.append(heap, refresh);
        const access = try self.issue("ya29.mock-access-");
        try self.access.append(heap, access);
        return .{ .refresh = refresh, .access = access };
    }

    pub fn expireAccessTokens(self: *MockDrive) void {
        self.hold();
        defer self.unlock();
        self.access.clearRetainingCapacity();
    }

    pub fn revokeRefreshTokens(self: *MockDrive) void {
        self.hold();
        defer self.unlock();
        self.refresh.clearRetainingCapacity();
    }

    pub fn setTrashed(self: *MockDrive, id: []const u8, on: bool) void {
        self.hold();
        defer self.unlock();
        if (self.find(id)) |f| f.trashed = on;
    }

    pub fn setReadOnly(self: *MockDrive, id: []const u8, on: bool) void {
        self.hold();
        defer self.unlock();
        if (self.find(id)) |f| f.can_add_children = !on;
    }

    /// Deleted for good, and everything in it.
    pub fn remove(self: *MockDrive, id: []const u8) void {
        self.hold();
        defer self.unlock();
        self.removeTree(id);
    }

    /// The id of `path` under folder `root_id`, on `a`.
    pub fn idOf(self: *MockDrive, a: Allocator, root_id: []const u8, path: []const u8) ?[]u8 {
        self.hold();
        defer self.unlock();
        const f = self.resolve(root_id, path) orelse return null;
        return a.dupe(u8, f.id) catch null;
    }

    /// The bytes of `path` under `root_id`, on `a`.
    pub fn readFile(self: *MockDrive, a: Allocator, root_id: []const u8, path: []const u8) ?[]u8 {
        self.hold();
        defer self.unlock();
        const f = self.resolve(root_id, path) orelse return null;
        return a.dupe(u8, f.data) catch null;
    }

    /// New bytes for the file at `path` (to damage it): whether it was there.
    pub fn writeFile(self: *MockDrive, root_id: []const u8, path: []const u8, data: []const u8) bool {
        self.hold();
        defer self.unlock();
        const f = self.resolve(root_id, path) orelse return false;
        const copy = heap.dupe(u8, data) catch return false;
        heap.free(f.data);
        f.data = copy;
        f.modified_ms = self.tick();
        return true;
    }

    /// The browser's part of signing in: open `auth_url`, follow Google's
    /// redirect to the flow's callback. Blocks; not on the main queue's behalf.
    pub fn consent(self: *MockDrive, gpa: Allocator, auth_url: []const u8) !void {
        _ = self;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const session = urlsession.ephemeral(30);
        defer objc.release(session);
        const r = try urlsession.send(arena.allocator(), session, "GET", auth_url, &.{}, null) orelse return error.NoAnswer;
        if (r.code != 200) return error.Refused;
    }

    /// Turns the main run loop for `seconds`, so main-queue work runs.
    pub fn pumpMain(seconds: f64) void {
        const until = json.now() + seconds;
        while (json.now() < until) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, 1);
    }
};
