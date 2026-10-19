//! AIClient's two other requests: OpenRouter's code traded for a key
//! (`exchange`), and the models a provider lists (`models`). Each answer is
//! read whole and handed to the caller on the main thread.
const std = @import("std");
const json = @import("../data/json.zig");
const urlsession = @import("../sys/urlsession.zig");
const ai = @import("ai.zig");
const client = @import("client.zig");
const sse = @import("client_sse.zig");
const Failure = client.Failure;

/// A whole answer read: its status (0 when not HTTP), body, or failure.
const Whole = struct {
    gpa: std.mem.Allocator,
    status: i64 = -1,
    body: std.ArrayList(u8) = .empty,
    ctx: *anyopaque,
    then: *const fn (*anyopaque, *Whole, ?urlsession.Failure) void,
    /// The caller's own.
    extra: *anyopaque,

    fn response(raw: *anyopaque, status: i64) void {
        const w: *Whole = @ptrCast(@alignCast(raw));
        w.status = status;
    }

    fn data(raw: *anyopaque, bytes: []const u8) void {
        const w: *Whole = @ptrCast(@alignCast(raw));
        w.body.appendSlice(w.gpa, bytes) catch {};
    }

    fn done(raw: *anyopaque, f: ?urlsession.Failure) void {
        const w: *Whole = @ptrCast(@alignCast(raw));
        defer {
            w.body.deinit(w.gpa);
            w.gpa.destroy(w);
        }
        w.then(w.ctx, w, f);
    }
};

fn start(m: *ai.Ai, r: urlsession.Request, ctx: *anyopaque, extra: *anyopaque, then: *const fn (*anyopaque, *Whole, ?urlsession.Failure) void) bool {
    const session = m.sessionFor() orelse return false;
    const w = m.gpa.create(Whole) catch return false;
    w.* = .{ .gpa = m.gpa, .ctx = ctx, .then = then, .extra = extra };
    if (session.start(r, .{ .ctx = w, .response = Whole.response, .data = Whole.data, .done = Whole.done }) == null) {
        m.gpa.destroy(w);
        return false;
    }
    return true;
}

/// A key, or why there is none. Borrowed for the call.
pub const Exchanged = union(enum) { key: []const u8, failed: Failure };
pub const ExchangeThen = *const fn (*anyopaque, Exchanged) void;

const Trade = struct { m: *ai.Ai, then: ExchangeThen };

/// OpenRouter's one-time code, and the flow's verifier, for a key of the
/// account's own (see sign_in.zig); `then` once, on the main thread.
pub fn exchange(m: *ai.Ai, code: []const u8, verifier: []const u8, ctx: *anyopaque, then: ExchangeThen) void {
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const base = m.base(a, ai.openRouter) catch return then(ctx, .{ .failed = .unreadable });
    const address = std.mem.concat(a, u8, &.{ base, "auth/keys" }) catch return then(ctx, .{ .failed = .unreadable });
    if (!client.allowed(m, address, ai.openRouter)) return then(ctx, .{ .failed = .refused_host });
    const body = json.encode(a, .{ .code = code, .code_verifier = verifier, .code_challenge_method = "S256" }) catch return then(ctx, .{ .failed = .unreadable });
    const t = m.gpa.create(Trade) catch return then(ctx, .{ .failed = .unreadable });
    t.* = .{ .m = m, .then = then };
    const r: urlsession.Request = .{ .method = "POST", .url = address, .headers = &.{.{ "Content-Type", "application/json" }}, .body = body };
    if (!start(m, r, ctx, t, traded)) {
        m.gpa.destroy(t);
        then(ctx, .{ .failed = .unreadable });
    }
}

fn traded(ctx: *anyopaque, w: *Whole, f: ?urlsession.Failure) void {
    const t: *Trade = @ptrCast(@alignCast(w.extra));
    const m = t.m;
    const then = t.then;
    m.gpa.destroy(t);
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (f) |x| {
        if (!x.url_error) return then(ctx, .{ .failed = .unreadable });
        return then(ctx, .{ .failed = .{ .@"unreachable" = client.reason(a, m, x.code, ai.openRouter) catch "" } });
    }
    if (w.status <= 0) return then(ctx, .{ .failed = .unreadable });
    if (w.status < 200 or w.status >= 300) return then(ctx, .{ .failed = .{ .http = .{ .status = w.status, .said = sse.said(a, w.body.items, null) } } });
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, w.body.items, .{}) catch return then(ctx, .{ .failed = .unreadable });
    const key = if (v == .object) v.object.get("key") else null;
    if (key) |k| if (k == .string and k.string.len > 0 and (std.unicode.utf8CountCodepoints(k.string) catch 400) < 400)
        return then(ctx, .{ .key = k.string });
    then(ctx, .{ .failed = .unreadable });
}

/// The names, on the receiver's `gpa`; empty on any failure. The receiver frees them.
pub const ModelsThen = *const fn (*anyopaque, []const []u8) void;

const Listing = struct { m: *ai.Ai, provider: ai.Provider, then: ModelsThen };

/// The models a provider lists, asked only when Settings shows them or the
/// user asks. An app on this Mac needs no key; Ollama's "cloud" models,
/// which it runs on ollama.com, are left out: nothing chosen here leaves
/// this Mac. `then` once, on the main thread.
pub fn models(m: *ai.Ai, p: ai.Provider, key: ?[]const u8, ctx: *anyopaque, then: ModelsThen) void {
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const maybe = modelsRequest(m, a, p, key) catch null;
    const r = maybe orelse return then(ctx, &.{});
    const l = m.gpa.create(Listing) catch return then(ctx, &.{});
    l.* = .{ .m = m, .provider = p, .then = then };
    if (!start(m, r, ctx, l, listed)) {
        m.gpa.destroy(l);
        then(ctx, &.{});
    }
}

/// The request for the list, or null when it may not go. On `a`.
pub fn modelsRequest(m: *const ai.Ai, a: std.mem.Allocator, p: ai.Provider, key: ?[]const u8) !?urlsession.Request {
    const base = try m.base(a, p);
    var address: []const u8 = if (p.is("ollama")) blk: {
        // deletingLastPathComponent: ".../v1/" → ".../".
        const trimmed = std.mem.trimEnd(u8, base, "/");
        const cut = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse trimmed.len;
        break :blk try std.mem.concat(a, u8, &.{ trimmed[0 .. cut + 1], "api/tags" });
    } else try std.mem.concat(a, u8, &.{ base, "models" });
    switch (p.wire) {
        .anthropic => address = try std.mem.concat(a, u8, &.{ address, "?limit=1000" }),
        .gemini => address = try std.mem.concat(a, u8, &.{ address, "?pageSize=1000" }),
        .openAI => {},
    }
    if (!client.allowed(m, address, p)) return null;
    var headers: std.ArrayList([2][]const u8) = .empty;
    if (p.takesKey()) {
        const k = key orelse "";
        if (k.len > 0) switch (p.wire) {
            .anthropic => {
                try headers.append(a, .{ "x-api-key", k });
                try headers.append(a, .{ "anthropic-version", "2023-06-01" });
            },
            .gemini => try headers.append(a, .{ "x-goog-api-key", k }),
            .openAI => try headers.append(a, .{ "Authorization", try std.mem.concat(a, u8, &.{ "Bearer ", k }) }),
        } else if (!p.isLocal()) return null;
    }
    return .{ .url = address, .headers = headers.items, .timeout = if (p.isLocal()) 2 else 10 };
}

fn listed(ctx: *anyopaque, w: *Whole, f: ?urlsession.Failure) void {
    const l: *Listing = @ptrCast(@alignCast(w.extra));
    const m = l.m;
    const p = l.provider;
    const then = l.then;
    m.gpa.destroy(l);
    if (f != null or w.status != 200) return then(ctx, &.{});
    const names = modelNames(m.gpa, p, w.body.items) catch return then(ctx, &.{});
    then(ctx, names);
}

/// What a listing's body names, for each way of listing; on `gpa`.
pub fn modelNames(gpa: std.mem.Allocator, p: ai.Provider, body: []const u8) ![][]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{});
    if (v != .object) return error.NotAList;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    const list = v.object.get(if (p.is("ollama") or p.wire == .gemini) "models" else "data");
    const items: []const std.json.Value = if (list) |x| (if (x == .array) x.array.items else &.{}) else &.{};
    for (items) |model| {
        if (model != .object) continue;
        const o = model.object;
        const name = o.get(if (p.is("ollama") or p.wire == .gemini) "name" else "id") orelse continue;
        if (name != .string) continue;
        const n = name.string;
        if (p.is("ollama")) {
            if (o.get("remote_host") != null or o.get("remote_model") != null) continue;
            if (std.mem.endsWith(u8, n, "-cloud") or std.mem.indexOf(u8, n, ":cloud") != null or std.mem.indexOf(u8, n, "-cloud:") != null) continue;
        } else if (p.wire == .gemini) {
            const methods = o.get("supportedGenerationMethods") orelse continue;
            if (methods != .array) continue;
            var takes = false;
            for (methods.array.items) |x| if (x == .string and std.mem.eql(u8, x.string, "generateContent")) {
                takes = true;
            };
            if (!takes) continue;
        }
        const shown = if (p.wire == .gemini and !p.is("ollama") and std.mem.startsWith(u8, n, "models/")) n[7..] else n;
        try out.append(gpa, try gpa.dupe(u8, shown));
    }
    if (!p.is("ollama")) std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

test {
    _ = @import("client_tests.zig");
}
