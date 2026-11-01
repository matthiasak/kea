//! Signing in to Google for Drive sync: OAuth 2.0 with PKCE through a
//! loopback redirect (RFC 8252 §7.3). A worker listens on 127.0.0.1, any
//! free port, for the browser to come back with a one-time code, trades it
//! and the verifier (which lives only in memory) for tokens, and says how it
//! went on the main thread.
const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const urlsession = @import("../sys/urlsession.zig");
const keychain = @import("../sys/keychain.zig");
const sign_in = @import("../ai/sign_in.zig");
const uriEncode = @import("sigv4.zig").uriEncode;
const options = @import("kea_options");

/// Where Google lives; in tests, the stand-in's. Slices borrowed.
pub const AuthEndpoints = struct {
    auth_url: []const u8 = "https://accounts.google.com/o/oauth2/v2/auth",
    token_url: []const u8 = "https://oauth2.googleapis.com/token",
    api_base: []const u8 = "https://www.googleapis.com/drive/v3",
    upload_base: []const u8 = "https://www.googleapis.com/upload/drive/v3",
};

/// Only what Kea makes: no restricted scope, so no yearly security review —
/// and folders made elsewhere (Drive's web page, another app) stay unseen.
pub const scope = "https://www.googleapis.com/auth/drive.file email";
pub const redirect_path = "/kea/gdrive/callback";

fn envValue(name: [*:0]const u8) []const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else "";
}

/// The OAuth client: defaults' own, else $KEA_GDRIVE_CLIENT_ID, else the
/// one built in (`-Dgdrive-client-id`); null when none. The caller frees it.
pub fn resolveClientId(gpa: Allocator, defaults_value: ?[]const u8) ?[]u8 {
    for ([_][]const u8{ defaults_value orelse "", envValue("KEA_GDRIVE_CLIENT_ID"), options.gdrive_client_id }) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len > 0) return gpa.dupe(u8, t) catch null;
    }
    return null;
}

/// The client's secret (Desktop clients have one, not really secret): the
/// keychain's, else $KEA_GDRIVE_CLIENT_SECRET, else the one built in
/// (`-Dgdrive-client-secret`); null when none. The caller frees it.
pub fn resolveClientSecret(gpa: Allocator, use_keychain: bool) ?[]u8 {
    if (use_keychain) if (keychain.load(gpa, .{ .service = "app.kea.zig.sync", .account = "drive_client_secret" })) |s| {
        if (s.len > 0) return s;
        gpa.free(s);
    };
    for ([_][]const u8{ envValue("KEA_GDRIVE_CLIENT_SECRET"), options.gdrive_client_secret }) |v| {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len > 0) return gpa.dupe(u8, t) catch null;
    }
    return null;
}

/// A token endpoint's answer, on the caller's allocator.
pub const TokenPair = struct { access_token: []u8, expires_in: f64, refresh_token: ?[]u8 = null };

/// How a sign-in ended; owned by the flow's gpa, freed by whoever hears it.
pub const AuthResult = union(enum) {
    ok: struct { refresh_token: []u8, access_token: []u8, expires_at: f64, email: []u8 },
    failed: []u8,
    cancelled,

    pub fn deinit(self: AuthResult, gpa: Allocator) void {
        switch (self) {
            .ok => |o| for ([_][]u8{ o.refresh_token, o.access_token, o.email }) |s| gpa.free(s),
            .failed => |f| gpa.free(f),
            .cancelled => {},
        }
    }
};

/// Called once, on the main thread, when a flow ends.
pub const Done = struct { ctx: *anyopaque, func: *const fn (*anyopaque, AuthResult) void };

fn form(a: Allocator, pairs: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |p, i| {
        if (i > 0) try out.append(a, '&');
        try out.print(a, "{s}={s}", .{ p[0], try uriEncode(a, p[1], true) });
    }
    return out.items;
}

fn postForm(a: Allocator, session: objc.Object, url: []const u8, pairs: []const [2][]const u8) !?urlsession.Response {
    const headers = [_][2][]const u8{ .{ "Content-Type", "application/x-www-form-urlencoded" }, .{ "Accept", "application/json" } };
    return urlsession.send(a, session, "POST", url, &headers, try form(a, pairs));
}

fn parseTokens(a: Allocator, body: []const u8) !?TokenPair {
    const T = struct { access_token: []const u8 = "", expires_in: f64 = 3600, refresh_token: ?[]const u8 = null };
    const t = std.json.parseFromSliceLeaky(T, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    if (t.access_token.len == 0) return null;
    return .{
        .access_token = try a.dupe(u8, t.access_token),
        .expires_in = t.expires_in,
        .refresh_token = if (t.refresh_token) |r| if (r.len > 0) try a.dupe(u8, r) else null else null,
    };
}

/// A fresh access token for `refresh_token`, on `a`; `AuthRevoked` when
/// Google no longer takes it (400/401, `invalid_grant`).
pub fn refreshAccessToken(a: Allocator, session: objc.Object, endpoints: AuthEndpoints, client_id: []const u8, client_secret: ?[]const u8, refresh_token: []const u8) error{ AuthRevoked, SyncFailed, OutOfMemory }!TokenPair {
    const pairs = [_][2][]const u8{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", refresh_token }, .{ "client_id", client_id }, .{ "client_secret", client_secret orelse "" } };
    const r = (postForm(a, session, endpoints.token_url, pairs[0..if (client_secret != null) 4 else 3]) catch return error.OutOfMemory) orelse return error.SyncFailed;
    if (r.code == 400 or r.code == 401) return error.AuthRevoked;
    if (r.code != 200) return error.SyncFailed;
    return try parseTokens(a, r.body) orelse error.SyncFailed;
}

/// Plain POSIX sockets on 127.0.0.1, one HTTP/1.1 request a connection
/// (also MockDrive's).
pub const net = struct {
    const SockaddrIn = extern struct { len: u8 = 16, family: u8 = 2, port: u16 = 0, addr: u32 = 0, zero: [8]u8 = @splat(0) };
    const PollFd = extern struct { fd: c_int, events: i16 = 1, revents: i16 = 0 };
    extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
    extern "c" fn bind(fd: c_int, addr: *const SockaddrIn, len: u32) c_int;
    extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    extern "c" fn getsockname(fd: c_int, addr: *SockaddrIn, len: *u32) c_int;
    extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, value: *const anyopaque, len: u32) c_int;
    extern "c" fn poll(fds: [*]PollFd, n: c_uint, timeout: c_int) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    pub extern "c" fn close(fd: c_int) c_int;

    /// Listening on 127.0.0.1 at a port of the system's choosing.
    pub fn listenLocal(port: *u16) !c_int {
        const fd = socket(2, 1, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = close(fd);
        var addr: SockaddrIn = .{ .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (bind(fd, &addr, @sizeOf(SockaddrIn)) != 0 or listen(fd, 16) != 0) return error.Bind;
        var len: u32 = @sizeOf(SockaddrIn);
        if (getsockname(fd, &addr, &len) != 0) return error.Bind;
        port.* = std.mem.bigToNative(u16, addr.port);
        return fd;
    }

    /// Whether `fd` has something to read within `ms`.
    pub fn ready(fd: c_int, ms: c_int) bool {
        var p = [1]PollFd{.{ .fd = fd }};
        return poll(&p, 1, ms) > 0;
    }

    /// A connection, writes to which never raise SIGPIPE.
    pub fn acceptOne(fd: c_int) ?c_int {
        const c = accept(fd, null, null);
        if (c < 0) return null;
        const one: c_int = 1;
        _ = setsockopt(c, 0xffff, 0x1022, &one, @sizeOf(c_int)); // SOL_SOCKET, SO_NOSIGPIPE
        return c;
    }

    pub const Request = struct {
        method: []const u8,
        target: []const u8,
        head: []const u8,
        body: []const u8,

        pub fn header(self: Request, name: []const u8) ?[]const u8 {
            var lines = std.mem.splitSequence(u8, self.head, "\r\n");
            _ = lines.next();
            while (lines.next()) |ln| {
                if (ln.len > name.len and ln[name.len] == ':' and std.ascii.startsWithIgnoreCase(ln, name))
                    return std.mem.trim(u8, ln[name.len + 1 ..], " \t");
            }
            return null;
        }
    };

    /// One whole request (`Content-Length` bodies of any size), on `a`; null
    /// when it doesn't come within `ms` a read.
    pub fn readRequest(a: Allocator, fd: c_int, ms: c_int) ?Request {
        var buf: std.ArrayList(u8) = .empty;
        var head_end: ?usize = null;
        var want: usize = 0;
        while (head_end == null or buf.items.len < head_end.? + want) {
            if (!ready(fd, ms)) return null;
            buf.ensureUnusedCapacity(a, 65536) catch return null;
            const room = buf.unusedCapacitySlice();
            const n = read(fd, room.ptr, room.len);
            if (n <= 0) return null;
            buf.items.len += @intCast(n);
            if (head_end == null) if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |i| {
                head_end = i + 4;
                const r: Request = .{ .method = "", .target = "", .head = buf.items[0..i], .body = "" };
                want = std.fmt.parseInt(usize, r.header("content-length") orelse "0", 10) catch 0;
            };
        }
        const he = head_end.?;
        var parts = std.mem.splitScalar(u8, buf.items[0 .. std.mem.indexOf(u8, buf.items, "\r\n") orelse 0], ' ');
        return .{
            .method = parts.next() orelse return null,
            .target = parts.next() orelse return null,
            .head = buf.items[0 .. he - 4],
            .body = buf.items[he .. he + want],
        };
    }

    fn writeAll(fd: c_int, bytes: []const u8) void {
        var at: usize = 0;
        while (at < bytes.len) {
            const n = write(fd, bytes[at..].ptr, bytes.len - at);
            if (n <= 0) return;
            at += @intCast(n);
        }
    }

    /// `extra`: more header lines, each ending "\r\n".
    pub fn reply(fd: c_int, status: []const u8, content_type: []const u8, extra: []const u8, body: []const u8) void {
        var hbuf: [4096]u8 = undefined;
        const h = std.fmt.bufPrint(&hbuf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n", .{ status, content_type, body.len, extra }) catch return;
        writeAll(fd, h);
        writeAll(fd, body);
    }
};

/// One sign-in under way. Valid until `done.func` returns on the main
/// thread; freed right after.
pub const LoopbackFlow = struct {
    port: u16,
    /// Where the browser goes to sign in.
    auth_url: []u8,
    gpa: Allocator,
    /// The flow's strings and the worker's scratch (`c_allocator`).
    arena: std.heap.ArenaAllocator,
    fd: c_int,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: Done,
    verifier: [43]u8,
    state: [32]u8,
    endpoints: AuthEndpoints,
    client_id: []const u8,
    client_secret: ?[]const u8,
    redirect_uri: []const u8,
    got: Got = .cancelled,

    /// `AuthResult`, on the worker's arena.
    const Got = union(enum) {
        ok: struct { refresh: []const u8, access: []const u8, expires_at: f64, email: []const u8 },
        failed: []const u8,
        cancelled,
    };

    /// Listening, and — when `open_browser` — the browser opened at
    /// `auth_url`. Main thread.
    pub fn start(gpa: Allocator, endpoints: AuthEndpoints, client_id: []const u8, client_secret: ?[]const u8, open_browser: bool, done: Done) !*LoopbackFlow {
        const self = try gpa.create(LoopbackFlow);
        errdefer gpa.destroy(self);
        self.arena = .init(std.heap.c_allocator);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        var port: u16 = 0;
        const fd = try net.listenLocal(&port);
        errdefer _ = net.close(fd);
        var bytes: [32]u8 = undefined;
        std.c.arc4random_buf(&bytes, bytes.len);
        var vb: [43]u8 = undefined;
        var cb: [43]u8 = undefined;
        const challenge = sign_in.challengeFor(sign_in.verifierFor(bytes, &vb), &cb);
        var sb: [16]u8 = undefined;
        std.c.arc4random_buf(&sb, sb.len);
        const state = std.fmt.bytesToHex(sb, .lower);
        const redirect = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ port, redirect_path });
        const url = try std.fmt.allocPrint(a, "{s}?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}&access_type=offline&prompt=consent", .{
            endpoints.auth_url, try uriEncode(a, client_id, true), try uriEncode(a, redirect, true), try uriEncode(a, scope, true), challenge, &state,
        });
        const owned: AuthEndpoints = .{ .token_url = try a.dupe(u8, endpoints.token_url), .api_base = try a.dupe(u8, endpoints.api_base) };
        const id = try a.dupe(u8, client_id);
        const secret = if (client_secret) |s| try a.dupe(u8, s) else null;
        const arena = self.arena;
        self.* = .{
            .port = port,
            .auth_url = url,
            .gpa = gpa,
            .arena = arena,
            .fd = fd,
            .done = done,
            .verifier = vb,
            .state = state,
            .endpoints = owned,
            .client_id = id,
            .client_secret = secret,
            .redirect_uri = redirect,
        };
        const t = try std.Thread.spawn(.{}, run, .{self});
        t.detach();
        if (open_browser) {
            const pool = objc.Pool.push();
            defer pool.pop();
            if (objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)})) |u|
                _ = objc.msg(objc.BOOL, objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{u});
        }
        return self;
    }

    /// Stops listening; `.cancelled` follows. Main thread.
    pub fn cancel(self: *LoopbackFlow) void {
        self.cancelled.store(true, .release);
    }

    fn run(self: *LoopbackFlow) void {
        const pool = objc.Pool.push();
        self.got = self.wait(self.arena.allocator()) catch .{ .failed = "Out of memory" };
        pool.pop();
        _ = net.close(self.fd);
        objc.dispatchMain(self, deliver);
    }

    fn deliver(ctx: ?*anyopaque) callconv(.c) void {
        const self: *LoopbackFlow = @ptrCast(@alignCast(ctx.?));
        const gpa = self.gpa;
        const result: AuthResult = if (self.cancelled.load(.acquire)) .cancelled else own(gpa, self.got) catch .cancelled;
        self.done.func(self.done.ctx, result);
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn own(gpa: Allocator, got: Got) !AuthResult {
        switch (got) {
            .ok => |o| {
                const refresh = try gpa.dupe(u8, o.refresh);
                errdefer gpa.free(refresh);
                const access = try gpa.dupe(u8, o.access);
                errdefer gpa.free(access);
                return .{ .ok = .{ .refresh_token = refresh, .access_token = access, .expires_at = o.expires_at, .email = try gpa.dupe(u8, o.email) } };
            },
            .failed => |f| return .{ .failed = try gpa.dupe(u8, f) },
            .cancelled => return .cancelled,
        }
    }

    fn wait(self: *LoopbackFlow, a: Allocator) !Got {
        const started = json.now();
        while (!self.cancelled.load(.acquire)) {
            if (json.now() - started > 300) return .{ .failed = "The sign-in took too long — try again." };
            if (!net.ready(self.fd, 250)) continue;
            const client = net.acceptOne(self.fd) orelse continue;
            defer _ = net.close(client);
            const req = net.readRequest(a, client, 5000) orelse continue;
            const q = std.mem.indexOfScalar(u8, req.target, '?');
            if (!std.mem.eql(u8, req.target[0 .. q orelse req.target.len], redirect_path)) {
                net.reply(client, "404 Not Found", "text/plain", "", "");
                continue;
            }
            const got = try self.callback(a, if (q) |i| req.target[i + 1 ..] else "");
            const page: []const u8 = switch (got) {
                .ok => "<h2>Signed in to Google Drive</h2><p>You can close this tab and go back to Kea.</p>",
                .failed => |f| try std.fmt.allocPrint(a, "<h2>Google sign-in didn't work</h2><p>{s}</p>", .{f}),
                .cancelled => "",
            };
            net.reply(client, "200 OK", "text/html; charset=utf-8", "", try std.fmt.allocPrint(a, "<!doctype html><meta charset=utf-8><title>Kea</title><body style=\"font:15px -apple-system,sans-serif;text-align:center;margin-top:5em\">{s}</body>", .{page}));
            return got;
        }
        return .cancelled;
    }

    /// The browser, back: checked, and the code traded for tokens and the
    /// account's address.
    fn callback(self: *LoopbackFlow, a: Allocator, query: []const u8) !Got {
        const state = sign_in.queryItem(a, query, "state") orelse "";
        if (state.len != self.state.len or !std.crypto.timing_safe.eql([32]u8, state[0..32].*, self.state))
            return .{ .failed = "The sign-in didn't come back from Google — try again." };
        if (sign_in.queryItem(a, query, "error")) |e|
            return .{ .failed = if (std.mem.eql(u8, e, "access_denied")) "Google sign-in was declined." else "Google sign-in didn't work — try again." };
        const code = sign_in.queryItem(a, query, "code") orelse "";
        if (code.len == 0) return .{ .failed = "Google sent no sign-in code — try again." };
        const session = urlsession.ephemeral(30);
        defer objc.release(session);
        const pairs = [_][2][]const u8{
            .{ "grant_type", "authorization_code" }, .{ "code", code },
            .{ "code_verifier", &self.verifier },    .{ "client_id", self.client_id },
            .{ "redirect_uri", self.redirect_uri },  .{ "client_secret", self.client_secret orelse "" },
        };
        const r = try postForm(a, session, self.endpoints.token_url, pairs[0..if (self.client_secret != null) 6 else 5]) orelse
            return .{ .failed = "Can't reach Google." };
        if (r.code != 200) return .{ .failed = try std.fmt.allocPrint(a, "Google didn't accept the sign-in (it answered {d}).", .{r.code}) };
        const tokens = try parseTokens(a, r.body) orelse return .{ .failed = "Google's answer made no sense." };
        const refresh = tokens.refresh_token orelse return .{ .failed = "Google didn't allow staying signed in — try again." };
        const about = try std.fmt.allocPrint(a, "{s}/about?fields=user(emailAddress,displayName)", .{self.endpoints.api_base});
        const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{tokens.access_token});
        const me = try urlsession.send(a, session, "GET", about, &.{.{ "Authorization", auth }}, null) orelse
            return .{ .failed = "Can't reach Google Drive." };
        const About = struct { user: struct { emailAddress: []const u8 = "" } = .{} };
        const who = if (me.code == 200) std.json.parseFromSliceLeaky(About, a, me.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null else null;
        const user = who orelse return .{ .failed = "Couldn't read the Google account." };
        return .{ .ok = .{ .refresh = refresh, .access = tokens.access_token, .expires_at = json.now() + tokens.expires_in, .email = user.user.emailAddress } };
    }
};

test "client id comes from defaults first, trimmed" {
    const gpa = std.testing.allocator;
    const id = resolveClientId(gpa, "  123.apps.googleusercontent.com \n").?;
    defer gpa.free(id);
    try std.testing.expectEqualStrings("123.apps.googleusercontent.com", id);
}
