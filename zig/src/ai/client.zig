//! The AI add-on's requests, and nothing else's (AIClient.swift): a session
//! of its own, with no cookies, no cache and nothing remembered, that speaks
//! only to the provider chosen — https, or plain http to this Mac alone — and
//! follows no redirect, so a key never goes anywhere but the host it was kept for.
//!
//! Three ways of writing a request cover every provider: OpenAI's chat
//! completions, Anthropic's messages and Gemini's generateContent. Each
//! answer comes back a piece at a time, as server-sent events.
//!
//! Nothing of a request is logged.
const std = @import("std");
const json = @import("../data/json.zig");
const url = @import("../data/url.zig");
const local = @import("../web/local_network.zig");
const urlsession = @import("../sys/urlsession.zig");
const ai = @import("ai.zig");
const sse = @import("client_sse.zig");

pub const Failure = sse.Failure;
const client_messages = @import("client_messages.zig");
pub const Role = enum { user, assistant, tool };
pub const Image = struct { media_type: []const u8, b64: []const u8 };
pub const Call = struct { id: []const u8, name: []const u8, args: []const u8, thought_sig: ?[]const u8 = null };
pub const Message = struct {
    role: Role,
    text: []const u8,
    images: []const Image = &.{},
    calls: []const Call = &.{},
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

/// One question: what is asked of `provider`. Borrowed for the call.
pub const Ask = struct {
    provider: ai.Provider,
    model: []const u8,
    /// What the model is for and how to treat the page.
    system: []const u8,
    messages: []const Message,
    key: ?[]const u8,
    max_tokens: u32 = 2048,
    /// Caps how many tokens Gemini thinks in first; null leaves it to the model.
    thinking: ?u32 = null,
    tools: bool = false,
};

/// Where the answer goes. `done` comes once, last — unless the stream is
/// cancelled first, when nothing more comes at all. Strings are borrowed
/// for the call.
pub const Sink = struct {
    ctx: *anyopaque,
    piece: *const fn (*anyopaque, []const u8) void,
    done: *const fn (*anyopaque, ?Failure) void,
    tool: ?*const fn (*anyopaque, sse.ToolEvent) void = null,
};

/// A stream under way.
pub const Handle = struct {
    ctx: *anyopaque,
    stop: *const fn (*anyopaque) void,

    /// Stopped: the sink hears nothing more.
    pub fn cancel(h: Handle) void {
        h.stop(h.ctx);
    }
};

/// How an answer is asked for: `real`, or a test's stand-in. `stream` may
/// finish before it returns, and returns null then.
pub const Client = struct {
    ctx: ?*anyopaque = null,
    stream: *const fn (?*anyopaque, *ai.Ai, Ask, Sink) ?Handle,
};

pub const real: Client = .{ .stream = realStream };

/// Where a provider's requests may go: its own host, over https, or this
/// Mac over plain http for the apps that run on it.
pub fn allowed(m: *const ai.Ai, address: []const u8, p: ai.Provider) bool {
    const parts = url.Parts.parse(address) orelse return false;
    const scheme = parts.scheme orelse return false;
    const host_raw = parts.hostName() orelse return false;
    if (parts.user != null or parts.password != null) return false;
    var hb: [256]u8 = undefined;
    if (host_raw.len > hb.len) return false;
    const host = std.ascii.lowerString(&hb, host_raw);
    const theirs = m.host(m.gpa, p) catch return false;
    defer m.gpa.free(theirs);
    const web = std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https");
    const loopback = std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "localhost");
    if (p.is("custom")) return web and std.mem.eql(u8, host, theirs) and local.contains(host);
    if (p.isLocal() or (m.testing and m.mock != null)) return web and loopback and std.mem.eql(u8, host, theirs);
    return std.ascii.eqlIgnoreCase(scheme, "https") and std.mem.eql(u8, host, theirs);
}

/// `base` with `path` after it, as `appendingPathComponent`; on `a`.
fn join(a: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, base, "/")) return std.mem.concat(a, u8, &.{ base, path });
    return std.mem.concat(a, u8, &.{ base, "/", path });
}

pub const Built = struct {
    url: []const u8,
    headers: []const [2][]const u8,
    body: []const u8,
};

const Text = struct { text: []const u8 };
const Parts = struct { parts: []const Text };
/// The request as the provider wants it, with the key in a header — never
/// in the address, which ends up in errors and logs — and only once the
/// address is known to be the provider's own. On `a`.
pub fn request(m: *const ai.Ai, a: std.mem.Allocator, q: Ask) (error{ RefusedHost, NoKey } || std.mem.Allocator.Error)!Built {
    const p = q.provider;
    const base = try m.base(a, p);
    var address: []const u8 = undefined;
    var body: []const u8 = undefined;
    switch (p.wire) {
        .openAI => {
            address = try join(a, base, "chat/completions");
            const said = try client_messages.openAI(a, q.system, q.messages);
            body = try json.encode(a, .{
                .model = q.model,
                .stream = true,
                .messages = said,
                .tools = if (q.tools) @as(?std.json.Value, try client_messages.toolsFor(a, .openAI)) else null,
                // Only providers that keep nothing of the request.
                .provider = if (p.is("openRouter")) @as(?struct { zdr: bool }, .{ .zdr = true }) else null,
                // A limit on the answer, for every one: OpenAI's own models
                // take it under its newer name.
                .max_completion_tokens = if (p.is("openAI")) @as(?u32, q.max_tokens) else null,
                .max_tokens = if (p.is("openAI")) null else @as(?u32, q.max_tokens),
            });
        },
        .anthropic => {
            address = try join(a, base, "messages");
            const said = try client_messages.anthropic(a, q.messages);
            body = try json.encode(a, .{
                .model = q.model,
                .stream = true,
                .max_tokens = q.max_tokens,
                .system = q.system,
                .messages = said,
                .tools = if (q.tools) @as(?std.json.Value, try client_messages.toolsFor(a, .anthropic)) else null,
            });
        },
        .gemini => {
            // The model's name is part of the path; nothing of the key is.
            var name: std.ArrayList(u8) = .empty;
            // ponytail: ASCII alphanumerics; Swift's set takes other letters too.
            for (q.model) |ch| {
                if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_') try name.append(a, ch) else try name.print(a, "%{X:0>2}", .{ch});
            }
            const path = try std.fmt.allocPrint(a, "models/{s}:streamGenerateContent", .{name.items});
            address = try std.mem.concat(a, u8, &.{ try join(a, base, path), "?alt=sse" });
            const contents = try client_messages.gemini(a, q.messages);
            const sys = try a.alloc(Text, 1);
            sys[0] = .{ .text = q.system };
            // Gemini counts its thinking in maxOutputTokens and sends nothing
            // while it thinks. A budget, not a level: 2.5 models refuse
            // thinkingLevel, and 3.x models take a budget too.
            body = try json.encode(a, .{
                .systemInstruction = Parts{ .parts = sys },
                .contents = contents,
                .tools = if (q.tools) @as(?std.json.Value, try client_messages.toolsFor(a, .gemini)) else null,
                .generationConfig = .{
                    .maxOutputTokens = q.max_tokens,
                    .thinkingConfig = if (q.thinking) |t| @as(?struct { thinkingBudget: u32 }, .{ .thinkingBudget = t }) else null,
                },
            });
        },
    }
    if (!allowed(m, address, p)) return error.RefusedHost;
    var headers: std.ArrayList([2][]const u8) = .empty;
    try headers.append(a, .{ "Content-Type", "application/json" });
    try headers.append(a, .{ "Accept", "text/event-stream" });
    try keyHeaders(a, &headers, p, q.key);
    return .{ .url = address, .headers = headers.items, .body = body };
}

/// The key's headers, for each way of writing; `error.NoKey` when a
/// provider off this Mac has none.
fn keyHeaders(a: std.mem.Allocator, headers: *std.ArrayList([2][]const u8), p: ai.Provider, key: ?[]const u8) !void {
    if (!p.takesKey()) return;
    const k = key orelse "";
    if (k.len == 0) return if (!p.isLocal()) error.NoKey;
    switch (p.wire) {
        .anthropic => {
            try headers.append(a, .{ "x-api-key", k });
            try headers.append(a, .{ "anthropic-version", "2023-06-01" });
        },
        .gemini => try headers.append(a, .{ "x-goog-api-key", k }),
        .openAI => try headers.append(a, .{ "Authorization", try std.mem.concat(a, u8, &.{ "Bearer ", k }) }),
    }
}

/// What went wrong reaching a provider, without its address.
pub fn reason(a: std.mem.Allocator, m: *const ai.Ai, code: i64, p: ai.Provider) ![]u8 {
    return switch (code) {
        // NSURLErrorCannotConnectToHost
        -1004 => if (p.is("custom"))
            std.fmt.allocPrint(a, "Nothing answered at {s}.", .{try m.host(a, p)})
        else if (p.isLocal())
            std.fmt.allocPrint(a, "{s} isn't running on this Mac.", .{p.name})
        else
            std.fmt.allocPrint(a, "{s} couldn't be reached.", .{p.name}),
        -1009 => a.dupe(u8, "This Mac is offline."),
        -1001 => std.fmt.allocPrint(a, "{s} took too long to answer.", .{p.name}),
        // Certificate untrusted, bad date, not yet valid, unknown root; secure connection failed.
        -1202, -1201, -1204, -1203, -1200 => std.fmt.allocPrint(a, "The connection to {s} isn't secure.", .{p.name}),
        else => std.fmt.allocPrint(a, "{s} couldn't be reached.", .{p.name}),
    };
}

/// `urlsession` failures as `AIError`s, on `a`; null for a cancelled task,
/// which finishes quietly.
fn failed(a: std.mem.Allocator, m: *const ai.Ai, f: urlsession.Failure, p: ai.Provider) ?Failure {
    if (!f.url_error) return .unreadable;
    if (f.code == urlsession.cancelled) return null;
    return .{ .@"unreachable" = reason(a, m, f.code, p) catch return .unreadable };
}

// MARK: - asking

const Live = struct {
    gpa: std.mem.Allocator,
    /// Owns the copies below and every failure's words.
    arena: std.heap.ArenaAllocator,
    m: *ai.Ai,
    provider: ai.Provider,
    key: ?[]const u8,
    sink: Sink,
    reader: sse.Reader,
    task: ?*urlsession.Task = null,
    status: i64 = -1,
    /// A refusal's body, read up to 4 KiB.
    body: std.ArrayList(u8) = .empty,

    fn ok(l: *const Live) bool {
        return l.status >= 200 and l.status < 300;
    }

    fn free(l: *Live) void {
        l.reader.deinit();
        l.body.deinit(l.gpa);
        l.arena.deinit();
        l.gpa.destroy(l);
    }

    /// The sink told, and everything let go.
    fn end(l: *Live, f: ?Failure) void {
        if (l.task) |t| t.cancel();
        const sink = l.sink;
        sink.done(sink.ctx, f);
        l.free();
    }

    fn stop(raw: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(raw));
        if (l.task) |t| t.cancel();
        l.free();
    }

    fn response(raw: *anyopaque, status: i64) void {
        const l: *Live = @ptrCast(@alignCast(raw));
        l.status = status;
    }

    fn data(raw: *anyopaque, bytes: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(raw));
        if (l.status == 0) return l.end(.unreadable);
        if (!l.ok()) {
            l.body.appendSlice(l.gpa, bytes) catch {};
            if (l.body.items.len > 4096) l.refused();
            return;
        }
        switch (l.reader.feed(bytes, l.sink.ctx, l.sink.piece)) {
            .more => {},
            .done => l.end(null),
            .failed => |f| l.end(f),
        }
    }

    fn refused(l: *Live) void {
        const a = l.arena.allocator();
        l.end(.{ .http = .{ .status = l.status, .said = sse.said(a, l.body.items, l.key) } });
    }

    fn done(raw: *anyopaque, f: ?urlsession.Failure) void {
        const l: *Live = @ptrCast(@alignCast(raw));
        // The session lets the task go after this.
        l.task = null;
        if (f) |x| return l.end(failed(l.arena.allocator(), l.m, x, l.provider));
        if (l.status <= 0) return l.end(.unreadable);
        if (!l.ok()) return l.refused();
        switch (l.reader.finish(l.sink.ctx, l.sink.piece)) {
            .more, .done => l.end(null),
            .failed => |x| l.end(x),
        }
    }
};

fn realStream(_: ?*anyopaque, m: *ai.Ai, q: Ask, sink: Sink) ?Handle {
    const l = m.gpa.create(Live) catch {
        sink.done(sink.ctx, .unreadable);
        return null;
    };
    l.* = .{ .gpa = m.gpa, .arena = .init(m.gpa), .m = m, .provider = q.provider, .key = null, .sink = sink, .reader = undefined };
    const a = l.arena.allocator();
    l.key = if (q.key) |k| a.dupe(u8, k) catch null else null;
    l.reader = .{ .a = m.gpa, .keep = a, .wire = q.provider.wire, .key = l.key, .on_tool = sink.tool };
    const built = request(m, a, q) catch |e| {
        l.end(switch (e) {
            error.RefusedHost => .refused_host,
            error.NoKey => .no_key,
            error.OutOfMemory => .unreadable,
        });
        return null;
    };
    const session = m.sessionFor() orelse {
        l.end(.unreadable);
        return null;
    };
    l.task = session.start(.{ .method = "POST", .url = built.url, .headers = built.headers, .body = built.body }, .{
        .ctx = l,
        .response = Live.response,
        .data = Live.data,
        .done = Live.done,
    }) orelse {
        l.end(.refused_host);
        return null;
    };
    return .{ .ctx = l, .stop = Live.stop };
}

/// The answer to `q`, a piece at a time, through `m.client`.
pub fn stream(m: *ai.Ai, q: Ask, sink: Sink) ?Handle {
    return m.client.stream(m.client.ctx, m, q, sink);
}

test {
    _ = @import("client_more.zig");
}
