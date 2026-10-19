//! The AI add-on (AI.swift): where it runs — an app on this Mac or a server
//! on your network that runs a model, or a provider you have an account or a
//! key with — and the shared state every window's Ubi Chat uses: the chats,
//! the catalog, the keys, and the client requests go through. On by default,
//! but nothing is detected or sent until you choose where it runs and ask.
const std = @import("std");
const Store = @import("../data/store.zig").Store;
const Prefs = @import("../data/prefs.zig").Prefs;
const Chats = @import("../data/chats_store.zig").Chats;
const url = @import("../data/url.zig");
const local = @import("../web/local_network.zig");
const urlsession = @import("../sys/urlsession.zig");
const Catalog = @import("catalog.zig").Catalog;
const Keys = @import("keys.zig").Keys;
const client = @import("client.zig");
const Assistant = @import("assistant.zig").Assistant;
const Browser = @import("../model/browser.zig").Browser;

/// How requests are written.
pub const Wire = enum { openAI, anthropic, gemini };

/// Where the answers come from: one of the built-ins, or any provider in
/// the models.dev catalog that speaks one of the three wires.
pub const Provider = struct {
    /// Built-ins: "anthropic", "openAI", "gemini", "openRouter", "ollama",
    /// "lmStudio", "custom". Catalog: its models.dev id.
    id: []const u8,
    name: []const u8,
    /// Where requests go outside a test run.
    home: []const u8,
    wire: Wire,
    /// The model asked for when none is chosen; "" when there is none.
    suggested: []const u8,
    /// The variables its key usually lives in.
    env: []const []const u8,
    /// The catalog's models, newest first.
    models: []const []const u8 = &.{},

    pub fn is(p: Provider, id: []const u8) bool {
        return std.mem.eql(u8, p.id, id);
    }

    /// Runs on this Mac or your network.
    pub fn isLocal(p: Provider) bool {
        return p.is("ollama") or p.is("lmStudio") or p.is("custom");
    }

    /// A key goes with requests: always to a provider off this Mac; to a
    /// custom server only if you saved one.
    pub fn takesKey(p: Provider) bool {
        return !p.isLocal() or p.is("custom");
    }

    /// "Ollama, on this Mac" for the apps on this Mac; the name otherwise. On `a`.
    pub fn label(p: Provider, a: std.mem.Allocator) ![]const u8 {
        if (p.isLocal() and !p.is("custom")) return std.fmt.allocPrint(a, "{s}, on this Mac", .{p.name});
        return p.name;
    }
};

// Cheap and quick, for a summary; each can be changed in Settings.
pub const anthropic: Provider = .{ .id = "anthropic", .name = "Anthropic", .home = "https://api.anthropic.com/v1/", .wire = .anthropic, .suggested = "claude-haiku-4-5", .env = &.{"ANTHROPIC_API_KEY"} };
pub const openAI: Provider = .{ .id = "openAI", .name = "OpenAI", .home = "https://api.openai.com/v1/", .wire = .openAI, .suggested = "gpt-5.4-mini", .env = &.{"OPENAI_API_KEY"} };
pub const gemini: Provider = .{ .id = "gemini", .name = "Google Gemini", .home = "https://generativelanguage.googleapis.com/v1beta/", .wire = .gemini, .suggested = "gemini-3.8-flash", .env = &.{ "GEMINI_API_KEY", "GOOGLE_API_KEY" } };
pub const openRouter: Provider = .{ .id = "openRouter", .name = "OpenRouter", .home = "https://openrouter.ai/api/v1/", .wire = .openAI, .suggested = "google/gemini-3.8-flash", .env = &.{"OPENROUTER_API_KEY"} };
/// Ollama, on this Mac. The local apps have no default: the list comes from the app.
pub const ollama: Provider = .{ .id = "ollama", .name = "Ollama", .home = "http://127.0.0.1:11434/v1/", .wire = .openAI, .suggested = "", .env = &.{} };
/// LM Studio, on this Mac.
pub const lmStudio: Provider = .{ .id = "lmStudio", .name = "LM Studio", .home = "http://127.0.0.1:1234/v1/", .wire = .openAI, .suggested = "", .env = &.{} };
/// A server you run that speaks OpenAI's API — llama-server, vLLM, Jan… — at
/// the address in Settings › AI, on this Mac or your network.
pub const custom: Provider = .{ .id = "custom", .name = "Custom server", .home = "http://127.0.0.1:8080/v1/", .wire = .openAI, .suggested = "", .env = &.{} };

pub const built_ins = [_]Provider{ anthropic, openAI, gemini, openRouter, ollama, lmStudio, custom };

/// The AI add-on's shared state (`AIProvider`'s statics, `AIKeys`,
/// `AICatalog.shared`, `AIClient.shared`, `Shared.chats`).
pub const Ai = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    prefs: *Prefs,
    /// `Store.testing`: keys kept in memory, nothing fetched.
    testing: bool,
    /// A test run's stand-in for every provider, on the loopback address
    /// (`AIProvider.mock`); never outside a test run.
    mock: ?[]u8 = null,
    chats: Chats,
    catalog: Catalog,
    keys: Keys,
    /// AIClient's own session, made on first use.
    session: ?*urlsession.Session = null,
    /// Where requests go: the real client, or a test's stand-in.
    client: client.Client = client.real,
    /// OpenRouter's sign-in under way (`AISignIn.flow`, `ended`).
    sign_in: @import("sign_in.zig").State = .{},
    /// Every window's assistant, by serial: an answer that arrives after its
    /// window's chat closed finds none (`[weak self]`).
    assistants: std.ArrayList(*Assistant) = .empty,
    next_serial: u64 = 1,
    /// Settings › AI opened in `b`'s window (`settingsPage = .ai; tuning =
    /// true`); the chrome sets it.
    open_settings: ?*const fn (b: *Browser) void = null,

    pub fn create(gpa: std.mem.Allocator, store: *Store, prefs: *Prefs, testing: bool) !*Ai {
        const self = try gpa.create(Ai);
        self.* = .{
            .gpa = gpa,
            .store = store,
            .prefs = prefs,
            .testing = testing,
            .chats = Chats.init(gpa, store),
            .catalog = Catalog.init(gpa, store, testing),
            .keys = .{ .gpa = gpa, .store = store, .testing = testing },
        };
        return self;
    }

    /// Every assistant is destroyed first (their windows close before this).
    pub fn destroy(self: *Ai) void {
        if (self.session) |s| s.destroy();
        self.assistants.deinit(self.gpa);
        self.keys.deinit();
        self.catalog.deinit();
        self.chats.deinit();
        if (self.mock) |m| self.gpa.free(m);
        self.gpa.destroy(self);
    }

    /// The assistant with `serial`, while it lives.
    pub fn assistant(self: *const Ai, serial: u64) ?*Assistant {
        for (self.assistants.items) |a| if (a.serial == serial) return a;
        return null;
    }

    /// AIClient's session: ephemeral, nothing kept, no redirect followed.
    pub fn sessionFor(self: *Ai) ?*urlsession.Session {
        if (self.session == null) self.session = urlsession.Session.create(self.gpa, .{ .request_timeout = 60, .resource_timeout = 300, .strict = true }) catch null;
        return self.session;
    }

    /// The one address requests go to. A key is kept for this host and is
    /// never sent to any other (see client.request). On `a`.
    pub fn base(self: *const Ai, a: std.mem.Allocator, p: Provider) ![]u8 {
        if (self.testing) if (self.mock) |m| return std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, m, "/"), "/", p.id, "/" });
        if (p.is("custom")) return a.dupe(u8, if (self.prefs.ai_server.len > 0 and url.Parts.parse(self.prefs.ai_server) != null) self.prefs.ai_server else custom.home);
        return a.dupe(u8, p.home);
    }

    /// The base address's host, lowercased; "" when it has none. On `a`.
    pub fn host(self: *const Ai, a: std.mem.Allocator, p: Provider) ![]u8 {
        const b = try self.base(a, p);
        defer a.free(b);
        const parts = url.Parts.parse(b) orelse return a.dupe(u8, "");
        return std.ascii.allocLowerString(a, parts.hostName() orelse "");
    }

    pub fn staysOnThisMac(self: *const Ai, p: Provider) bool {
        if (!p.isLocal()) return false;
        const h = self.host(self.gpa, p) catch return false;
        defer self.gpa.free(h);
        return local.onThisMac(h);
    }

    /// Every provider to choose from: the built-ins, with the catalog's
    /// models for four of them, then the rest of the catalog by name. On `a`.
    pub fn all(self: *const Ai, a: std.mem.Allocator) ![]Provider {
        var out: std.ArrayList(Provider) = .empty;
        for (built_ins) |built| {
            var p = built;
            if (self.catalog.mergedFor(built.id)) |found| {
                p.models = found.models;
                var env: std.ArrayList([]const u8) = .empty;
                try env.appendSlice(a, built.env);
                for (found.env) |e| if (!has(built.env, e)) try env.append(a, e);
                p.env = env.items;
            }
            try out.append(a, p);
        }
        try out.appendSlice(a, self.catalog.providers);
        return out.items;
    }

    /// A built-in by id, else a catalog provider (borrowed from the catalog).
    pub fn named(self: *const Ai, id: []const u8) ?Provider {
        for (built_ins) |p| if (p.is(id)) return p;
        for (self.catalog.providers) |p| if (p.is(id)) return p;
        return null;
    }

    /// `prefs.aiProvider`.
    pub fn chosen(self: *const Ai) ?Provider {
        return self.named(self.prefs.ai_provider orelse return null);
    }

    /// `prefs.aiModel(for:)`.
    pub fn model(self: *const Ai, p: Provider) []const u8 {
        return self.prefs.aiModel(p.id, p.suggested);
    }
};

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

test {
    _ = @import("ai_tests.zig");
}
