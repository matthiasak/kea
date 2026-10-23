//! The providers and models to choose from, read from models.dev
//! (AICatalog.swift): fetched when Settings › AI is opened and the copy kept
//! on this Mac is more than a day old — never in the background, never in a
//! test run — and slimmed to what is used here. An entry whose address isn't
//! a plain https one is left out.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("../data/json.zig");
const url = @import("../data/url.zig");
const Store = @import("../data/store.zig").Store;
const dispatch = @import("../sys/dispatch.zig");
const urlsession = @import("../sys/urlsession.zig");
const ai = @import("ai.zig");

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    api: []const u8,
    wire: []const u8,
    env: []const []const u8,
    models: []const []const u8,
};

/// A built-in's id → models.dev's id for it.
pub const built_in = [_][2][]const u8{
    .{ "anthropic", "anthropic" },
    .{ "openAI", "openai" },
    .{ "gemini", "google" },
    .{ "openRouter", "openrouter" },
};

/// Where an entry without an "api" is reached, for the ones that speak the OpenAI way.
// ponytail: base URLs for models.dev entries without "api" are a hand table; extend it when a wanted provider is skipped
const bases = [_][2][]const u8{
    .{ "groq", "https://api.groq.com/openai/v1" },
    .{ "xai", "https://api.x.ai/v1" },
    .{ "mistral", "https://api.mistral.ai/v1" },
    .{ "cerebras", "https://api.cerebras.ai/v1" },
    .{ "togetherai", "https://api.together.xyz/v1" },
    .{ "deepinfra", "https://api.deepinfra.com/v1/openai" },
    .{ "perplexity", "https://api.perplexity.ai" },
    .{ "cohere", "https://api.cohere.ai/compatibility/v1" },
    .{ "venice", "https://api.venice.ai/api/v1" },
    .{ "vercel", "https://ai-gateway.vercel.sh/v1" },
};

pub const cache = "ai-catalog.json";

fn lookup(table: []const [2][]const u8, key: []const u8) ?[]const u8 {
    for (table) |row| if (std.mem.eql(u8, row[0], key)) return row[1];
    return null;
}

fn ours(id: []const u8) bool {
    for (built_in) |row| if (std.mem.eql(u8, row[1], id)) return true;
    return false;
}

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    testing: bool,
    /// Owns `providers` and `merged`.
    arena: std.heap.ArenaAllocator,
    /// The catalog's providers that aren't built in, by name.
    providers: []ai.Provider = &.{},
    /// What models.dev lists for the built-ins, by its id for them.
    merged: []Entry = &.{},
    /// models.dev's whole catalog; a test run may point it elsewhere.
    source: []const u8 = "https://models.dev/api.json",
    fetching: ?*Job = null,

    pub fn init(gpa: std.mem.Allocator, store: *Store, testing: bool) Catalog {
        var self: Catalog = .{ .gpa = gpa, .store = store, .testing = testing, .arena = .init(gpa) };
        if (store.readFile(cache)) |bytes| {
            defer gpa.free(bytes);
            if (json.decode([]Entry, gpa, bytes)) |p| {
                defer p.deinit();
                self.apply(p.value);
            } else |_| {}
        }
        return self;
    }

    pub fn deinit(self: *Catalog) void {
        if (self.fetching) |j| j.catalog = null;
        self.arena.deinit();
    }

    /// The models.dev entry for a built-in (by the built-in's id).
    pub fn mergedFor(self: *const Catalog, built_in_id: []const u8) ?Entry {
        const theirs = lookup(&built_in, built_in_id) orelse return null;
        for (self.merged) |e| if (std.mem.eql(u8, e.id, theirs)) return e;
        return null;
    }

    /// Fetched again if the copy on this Mac is a day old. Not in a test run.
    pub fn refreshIfStale(self: *Catalog) void {
        if (self.testing) return;
        if (age(self.store)) |seconds| if (seconds < 86_400) return;
        self.refresh(null, null);
    }

    /// Fetched now; `then(ctx, n)` on the main thread with the number of
    /// providers now listed, or 0, the old list kept, if it couldn't be.
    pub fn refresh(self: *Catalog, ctx: ?*anyopaque, then: ?*const fn (?*anyopaque, usize) void) void {
        if (self.fetching != null) return;
        const a = std.heap.c_allocator;
        const j = a.create(Job) catch return;
        j.* = .{ .catalog = self, .source = a.dupe(u8, self.source) catch return a.destroy(j), .ctx = ctx, .then = then };
        self.fetching = j;
        dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), j, Job.fetch);
    }

    fn apply(self: *Catalog, entries: []const Entry) void {
        var next: std.heap.ArenaAllocator = .init(self.gpa);
        const a = next.allocator();
        var merged: std.ArrayList(Entry) = .empty;
        var providers: std.ArrayList(ai.Provider) = .empty;
        for (entries) |e| {
            const copy = json.clone(a, e) catch return next.deinit();
            if (ours(e.id)) {
                merged.append(a, copy) catch return next.deinit();
                continue;
            }
            if (url.Parts.parse(e.api) == null) continue;
            const wire = std.meta.stringToEnum(ai.Wire, e.wire) orelse continue;
            providers.append(a, .{ .id = copy.id, .name = copy.name, .home = copy.api, .wire = wire, .suggested = "", .env = copy.env, .models = copy.models }) catch return next.deinit();
        }
        std.mem.sort(ai.Provider, providers.items, {}, byName);
        self.arena.deinit();
        self.arena = next;
        self.merged = merged.items;
        self.providers = providers.items;
    }

    fn byName(_: void, a: ai.Provider, b: ai.Provider) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        return objc.msg(objc.NSInteger, objc.nsString(a.name), "localizedCaseInsensitiveCompare:", .{objc.nsString(b.name)}) == -1;
    }
};

/// Seconds since the kept copy was written, or null without one.
fn age(store: *Store) ?f64 {
    const path = store.file(cache) catch return null;
    defer store.gpa.free(path);
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const attrs = objc.msg(?objc.Object, fm, "attributesOfItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) }) orelse return null;
    const made = objc.msg(?objc.Object, attrs, "fileModificationDate", .{}) orelse return null;
    return -objc.msg(f64, made, "timeIntervalSinceNow", .{});
}

const Job = struct {
    /// Null once the catalog is gone.
    catalog: ?*Catalog,
    source: []u8,
    ctx: ?*anyopaque,
    then: ?*const fn (?*anyopaque, usize) void,
    /// The slimmed entries, encoded, on the C allocator.
    found: ?[]u8 = null,

    fn fetch(raw: ?*anyopaque) callconv(.c) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const j: *Job = @ptrCast(@alignCast(raw.?));
        const a = std.heap.c_allocator;
        const session = urlsession.ephemeral(20);
        defer objc.release(session);
        if (urlsession.send(a, session, "GET", j.source, &.{}, null) catch null) |r| {
            defer a.free(r.body);
            // Not HTTP counts as answered, as `(response as? HTTPURLResponse).map { … } ?? true`.
            if (r.code == 200 or r.code == 0) j.found = slimmed(a, r.body);
        }
        objc.dispatchMain(j, landed);
    }

    fn landed(raw: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(raw.?));
        const a = std.heap.c_allocator;
        defer {
            if (j.found) |f| a.free(f);
            a.free(j.source);
            a.destroy(j);
        }
        const c = j.catalog orelse return;
        c.fetching = null;
        const n = blk: {
            const bytes = j.found orelse break :blk 0;
            const p = json.decode([]Entry, c.gpa, bytes) catch break :blk 0;
            defer p.deinit();
            if (p.value.len == 0) break :blk 0;
            if (c.gpa.dupe(u8, bytes)) |own| c.store.write(cache, own, false) else |_| {}
            c.apply(p.value);
            break :blk c.providers.len;
        };
        if (j.then) |then| then(j.ctx, n);
    }
};

/// models.dev's catalog slimmed to entries and encoded, on `a`; null when
/// it isn't the catalog.
fn slimmed(a: std.mem.Allocator, body: []const u8) ?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const entries = slim(arena.allocator(), body) catch return null;
    return json.encode(a, entries) catch null;
}

pub fn slim(a: std.mem.Allocator, body: []const u8) ![]Entry {
    const all = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    if (all != .object) return error.NotACatalog;
    var entries: std.ArrayList(Entry) = .empty;
    var it = all.object.iterator();
    while (it.next()) |kv| {
        const id = kv.key_ptr.*;
        const p = kv.value_ptr.*;
        if (p != .object) return error.NotACatalog;
        if (std.mem.eql(u8, id, "ollama") or std.mem.eql(u8, id, "lmstudio")) continue;
        var api: []const u8 = str(p.object.get("api")) orelse lookup(&bases, id) orelse "";
        // Azure, Bedrock, Vertex and the like have a placeholder in theirs.
        if (!ours(id)) {
            if (!std.mem.startsWith(u8, api, "https://") or std.mem.indexOf(u8, api, "${") != null) continue;
            if (!std.mem.endsWith(u8, api, "/")) api = try std.mem.concat(a, u8, &.{ api, "/" });
        }
        const npm = str(p.object.get("npm")) orelse "";
        const wire = if (std.mem.eql(u8, npm, "@ai-sdk/anthropic")) "anthropic" else if (std.mem.eql(u8, npm, "@ai-sdk/google")) "gemini" else "openAI";
        const Model = struct { key: []const u8, released: []const u8 };
        var found: std.ArrayList(Model) = .empty;
        if (p.object.get("models")) |models| if (models == .object) {
            var mit = models.object.iterator();
            while (mit.next()) |m| {
                if (m.value_ptr.* != .object) continue;
                const model = m.value_ptr.object;
                if (model.get("modalities")) |mod| if (mod == .object) {
                    const output = mod.object.get("output") orelse continue;
                    if (output != .array or !hasText(output.array.items)) continue;
                };
                try found.append(a, .{ .key = m.key_ptr.*, .released = str(model.get("release_date")) orelse "" });
            }
        };
        std.mem.sort(Model, found.items, {}, struct {
            fn newer(_: void, x: Model, y: Model) bool {
                const o = std.mem.order(u8, x.released, y.released);
                return if (o == .eq) std.mem.order(u8, x.key, y.key) == .lt else o == .gt;
            }
        }.newer);
        const names = try a.alloc([]const u8, found.items.len);
        for (names, found.items) |*n, m| n.* = m.key;
        var env: std.ArrayList([]const u8) = .empty;
        if (p.object.get("env")) |e| if (e == .array) for (e.array.items) |v| if (v == .string) try env.append(a, v.string);
        try entries.append(a, .{ .id = id, .name = str(p.object.get("name")) orelse id, .api = api, .wire = wire, .env = env.items, .models = names });
    }
    return entries.items;
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn hasText(items: []const std.json.Value) bool {
    for (items) |i| if (i == .string and std.mem.eql(u8, i.string, "text")) return true;
    return false;
}

test "catalog slims models.dev" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"groq":{"name":"Groq","env":["GROQ_API_KEY"],"models":{"a":{"release_date":"2024-01-01"},"b":{"release_date":"2025-01-01"},
        \\  "img":{"modalities":{"output":["image"]}}}},
        \\ "azure":{"api":"https://${RESOURCE}.openai.azure.com","models":{}},
        \\ "ollama":{"api":"http://127.0.0.1","models":{}},
        \\ "anthropic":{"name":"Anthropic","npm":"@ai-sdk/anthropic","env":["ANTHROPIC_API_KEY"],"models":{"c":{}}}}
    ;
    const e = try slim(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 2), e.len);
    const groq = if (std.mem.eql(u8, e[0].id, "groq")) e[0] else e[1];
    try std.testing.expectEqualStrings("https://api.groq.com/openai/v1/", groq.api);
    try std.testing.expectEqualStrings("openAI", groq.wire);
    try std.testing.expectEqual(@as(usize, 2), groq.models.len);
    try std.testing.expectEqualStrings("b", groq.models[0]);
    const anth = if (std.mem.eql(u8, e[0].id, "anthropic")) e[0] else e[1];
    try std.testing.expectEqualStrings("anthropic", anth.wire);
    try std.testing.expectEqualStrings("", anth.api);
}
