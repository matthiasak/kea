//! Settings › AI (`AISettings`, AIAssist.swift:1509-1834): AI on or off,
//! where it runs, the server's address, where the key comes from, the
//! model, and forgetting every key. A local app is asked for its models
//! only as the page shows (`refresh`), never in the background.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../../model/browser.zig").Browser;
const Kea = @import("../../app/kea.zig").Kea;
const app_name = @import("../../app/kea.zig").app_name;
const Uuid = @import("../../data/json.zig").Uuid;
const Palette = @import("../../design/palette.zig").Palette;
const ai = @import("../../ai/ai.zig");
const keys = @import("../../ai/keys.zig");
const sign_in = @import("../../ai/sign_in.zig");
const client_more = @import("../../ai/client_more.zig");
const local_network = @import("../../web/local_network.zig");
const controls = @import("../controls.zig");
const plate = @import("../controls_plate.zig");
const tab_menu = @import("../tab_menu.zig");
const sheet = @import("../sheet.zig");
const disclose = @import("../disclose.zig");
const motion = @import("../../design/motion.zig");
const frame = @import("frame.zig");
const Kind = enum { keychain, variable, command };

pub const State = struct {
    pasted: ui.TextBuffer = .{},
    /// A variable's name or a command being typed, not yet in use.
    typed: ui.TextBuffer = .{},
    server: ui.TextBuffer = .{},
    /// The cloud model's field, read from the prefs as a provider shows.
    model: ui.TextBuffer = .{},
    hint: ?[]u8 = null,
    source: Kind = .keychain,
    kind: Kind = .keychain,
    models: [][]u8 = &.{},
    looking: bool = false,
    /// The provider last refreshed for (`onChange`), and whether the page
    /// has appeared (`onAppear`); both begin afresh with the panel.
    shown: ?[]u8 = null,
    appeared: bool = false,
    /// Bumped by each refresh, so an older listing's answer is dropped.
    gen: u32 = 0,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.pasted.deinit();
        s.typed.deinit();
        s.server.deinit();
        s.model.deinit();
        if (s.hint) |h| gpa.free(h);
        if (s.shown) |id| gpa.free(id);
        s.setModels(gpa, &.{});
    }

    fn setModels(s: *State, gpa: std.mem.Allocator, list: [][]u8) void {
        for (s.models) |m| gpa.free(m);
        gpa.free(s.models);
        s.models = list;
    }
};

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.settings.ai;
    {
        plate.cardBox(c, p);
        defer ui.end(c);
        _ = frame.prefLine(b, c, p, "ai", "Use AI on pages", "Summarize a page, or open Ubi Chat, from the View menu. Nothing is sent until you ask");
    }
    if (!disclose.begin(c, 0x6b65_612e_6169_626c, b.prefs.ai, motion.settle)) return;
    defer disclose.end(c);
    ui.column(c, .{ .width = .fill, .gap = 18 });
    defer ui.end(c);
    const m = b.kea.ai;
    if (b.prefs.ai) {
        if (!s.appeared) {
            s.appeared = true;
            m.catalog.refreshIfStale();
            m.sign_in.ended = .{ .ctx = b.kea, .func = signedIn };
        }
        const id = b.prefs.ai_provider;
        const same = if (s.shown) |old| (id != null and std.mem.eql(u8, old, id.?)) else id == null;
        if (!same or s.gen == 0) {
            // A key typed for one provider is never saved for another.
            s.pasted.set("");
            s.typed.set("");
            if (s.shown) |old| b.gpa.free(old);
            s.shown = if (id) |v| b.gpa.dupe(u8, v) catch null else null;
            refresh(b);
        }
    }
    {
        plate.cardBox(c, p);
        defer ui.end(c);
        const chosen = m.chosen();
        plate.line(c, p, "Where it runs", place(c, m, chosen));
        if (controls.popUpButton(c, p, "Where it runs", if (chosen) |v| v.label(c.alloc()) catch v.name else "Choose…")) |at| tab_menu.later(b, at, 0, providerItems);
        ui.end(c);
        if (disclose.begin(c, 0x6b65_612e_6169_7072, chosen != null, motion.settle)) {
            defer disclose.end(c);
            if (chosen) |provider| {
                frame.rule(c, p);
                if (provider.is("custom")) {
                    serverRow(b, c, p);
                    frame.rule(c, p);
                    key(b, c, p, provider);
                    frame.rule(c, p);
                    localModel(b, c, p, provider);
                } else if (provider.isLocal()) localModel(b, c, p, provider) else {
                    key(b, c, p, provider);
                    frame.rule(c, p);
                    cloudModel(b, c, p, provider);
                }
            }
        }
    }
    plate.cardBox(c, p);
    defer ui.end(c);
    plate.line(c, p, "Forget every key", "Deletes them from this Mac's keychain. A key made by signing in with OpenRouter still works until you delete it on openrouter.ai");
    if (controls.pill(c, p, "Forget", .{}).clicked) {
        m.keys.forgetAll();
        refresh(b);
        b.announce("Keys forgotten");
    }
    ui.end(c);
}

fn place(c: *ui.Context, m: *const ai.Ai, chosen: ?ai.Provider) []const u8 {
    const provider = chosen orelse return "A provider you have a key with, or a server on this Mac or your network";
    const host = m.host(c.alloc(), provider) catch "";
    if (provider.is("custom")) return if (m.staysOnThisMac(provider))
        "Nothing leaves this Mac. Also in private tabs"
    else
        c.print("Sent only to {s}, on your network. Never from a private tab", .{host});
    return if (provider.isLocal())
        "Nothing leaves this Mac. Also in private tabs"
    else
        c.print("Your key, sent only to {s}. Never from a private tab", .{host});
}

fn serverRow(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.settings.ai;
    plate.line(c, p, "Address", "An OpenAI-compatible server — llama-server, vLLM, Jan… — on this Mac or your network");
    defer ui.end(c);
    ui.row(c, .{ .gap = 6, .align_items = .center });
    defer ui.end(c);
    const submitted = field(c, p, &s.server, b.prefs.ai_server, 150, false).submitted;
    if (controls.pill(c, p, "Use", .{}).clicked or submitted) useServer(b);
}

fn useServer(b: *Browser) void {
    const s = &b.settings.ai;
    const url = (local_network.server(b.gpa, s.server.text()) catch null) orelse return b.announce("Use an address on this Mac or your network");
    defer b.gpa.free(url);
    b.prefs.set("ai_server", url);
    s.server.set("");
    refresh(b);
}

fn key(b: *Browser, c: *ui.Context, p: *const Palette, provider: ai.Provider) void {
    const s = &b.settings.ai;
    const m = b.kea.ai;
    {
        plate.line(c, p, "Key from", "Where " ++ app_name ++ " finds it when you ask");
        defer ui.end(c);
        var n: usize = @intFromEnum(s.kind);
        if (controls.segmented(c, p, &.{ "Keychain", "Variable", "Command" }, &n, false)) s.kind = @enumFromInt(n);
    }
    frame.rule(c, p);
    switch (s.kind) {
        .keychain => if (s.source == .keychain and s.hint != null) {
            plate.line(c, p, "Key", c.print("{s}, in your keychain", .{s.hint.?}));
            forgetPill(b, c, p, provider);
        } else {
            plate.line(c, p, "Key", if (provider.is("custom")) "Only if your server asks for one" else if (provider.is("openRouter")) "Paste one, or sign in and OpenRouter makes one for you" else "Paste your API key");
            defer ui.end(c);
            ui.row(c, .{ .gap = 6, .align_items = .center });
            defer ui.end(c);
            const submitted = field(c, p, &s.pasted, "Key", 130, true).submitted;
            if (controls.pill(c, p, "Save", .{}).clicked or submitted) save(b, provider);
            if (provider.is("openRouter") and controls.pill(c, p, "Sign In…", .{}).clicked) {
                sheet.close(b, .tuning);
                sign_in.start(m, b);
            }
            return;
        },
        .variable => if (s.source == .variable) {
            const name = switch (m.keys.source(c.alloc(), m, provider)) {
                .environment => |v| v,
                else => "",
            };
            plate.line(c, p, "Key", c.print("From ${s}", .{name}));
            forgetPill(b, c, p, provider);
        } else {
            plate.line(c, p, "Key", "A variable that holds it, read when you ask");
            typedRow(b, c, p, provider, if (provider.env.len > 0) provider.env[0] else "API_KEY", 150, .variable);
        },
        .command => if (s.source == .command) {
            plate.line(c, p, "Key", "From a command");
            forgetPill(b, c, p, provider);
        } else {
            plate.line(c, p, "Key", "A command that prints it, run by your shell when you ask");
            typedRow(b, c, p, provider, "op read op://Private/Gemini/credential", 200, .command);
        },
    }
    ui.end(c);
}

/// A variable's name or a command, with its Use; inside an open line.
fn typedRow(b: *Browser, c: *ui.Context, p: *const Palette, provider: ai.Provider, prompt: []const u8, width: f32, kind: Kind) void {
    const s = &b.settings.ai;
    ui.row(c, .{ .gap = 6, .align_items = .center });
    defer ui.end(c);
    const submitted = field(c, p, &s.typed, prompt, width, false).submitted;
    if (!(controls.pill(c, p, "Use", .{}).clicked or submitted)) return;
    const typed = std.mem.trim(u8, s.typed.text(), " \t\r\n");
    const m = b.kea.ai;
    if (kind == .variable) {
        if (!keys.isVariableName(typed)) return b.announce("Not a variable name");
        m.keys.setSource(m, .{ .environment = typed }, provider);
    } else {
        if (typed.len == 0) return;
        m.keys.setSource(m, .{ .command = typed }, provider);
    }
    s.typed.set("");
    refresh(b);
}

fn forgetPill(b: *Browser, c: *ui.Context, p: *const Palette, provider: ai.Provider) void {
    if (!controls.pill(c, p, "Forget", .{}).clicked) return;
    b.kea.ai.keys.forget(b.kea.ai, provider);
    refresh(b);
}

fn save(b: *Browser, provider: ai.Provider) void {
    const s = &b.settings.ai;
    const m = b.kea.ai;
    const saved = m.keys.save(m, s.pasted.text(), provider);
    s.pasted.set("");
    b.announce(switch (saved) {
        .kept => "Key kept in the keychain",
        .failed => "The key wasn't kept",
    });
    refresh(b);
}

fn cloudModel(b: *Browser, c: *ui.Context, p: *const Palette, provider: ai.Provider) void {
    const s = &b.settings.ai;
    plate.line(c, p, "Model", if (provider.suggested.len == 0) "Choose one, or type its name" else c.print("Leave empty for {s}", .{provider.suggested}));
    defer ui.end(c);
    ui.row(c, .{ .gap = 6, .align_items = .center });
    defer ui.end(c);
    if (field(c, p, &s.model, provider.suggested, 170, false).changed) b.prefs.setAIModel(s.model.text(), provider.id);
    // `modelMenu`: the chevrons on a wash; its menu on a press.
    const i = c.open(.{ .padding = .all(8), .radius = 7, .background = p.wash, .align_items = .center, .control = true }, null);
    const it = c.interact(i, .{});
    c.addA11y(i, .menu_button, "Models", "", false, true);
    ui.icon(c, "chevron.up.chevron.down", .{ .size = 8.5, .weight = .semibold, .color = p.muted });
    c.end();
    if (it.clicked) if (it.rect) |r| tab_menu.later(b, .{ .x = r.x, .y = r.y + r.h + 4 }, 0, modelItems);
}

fn localModel(b: *Browser, c: *ui.Context, p: *const Palette, provider: ai.Provider) void {
    const s = &b.settings.ai;
    const custom = provider.is("custom");
    if (s.models.len == 0) {
        const host = b.kea.ai.host(c.alloc(), provider) catch "";
        plate.line(c, p, "Model", if (custom)
            (if (s.looking) c.print("Asking {s}…", .{host}) else c.print("Nothing answered at {s}, or it has no model yet", .{host}))
        else if (s.looking) c.print("Asking {s}…", .{provider.name}) else c.print("{s} isn't running, or has no model yet", .{provider.name}));
        if (controls.pill(c, p, "Look Again", .{}).clicked) refresh(b);
    } else {
        const from = if (custom) c.print("From {s}", .{b.kea.ai.host(c.alloc(), provider) catch ""}) else c.print("From {s} on this Mac", .{provider.name});
        plate.line(c, p, "Model", from);
        const chosen = b.prefs.aiModel(provider.id, provider.suggested);
        if (controls.popUpButton(c, p, "Model", if (chosen.len == 0) "Choose…" else chosen)) |at| tab_menu.later(b, at, 0, localItems);
    }
    ui.end(c);
}

/// A text field on a wash, its prompt faint while it is empty.
fn field(c: *ui.Context, p: *const Palette, buf: *ui.TextBuffer, prompt: []const u8, width: f32, password: bool) ui.TextFieldResult {
    ui.column(c, .{ .padding = .xy(8, 5), .radius = 7, .background = p.wash, .clip = true });
    defer ui.end(c);
    const r = ui.textField(c, buf, .{ .bare = true, .size = 12, .width = .{ .px = width }, .password = password, .caret_color = p.ink, .selection_color = p.ink.alpha(0.12) });
    // After the field, so the first key typed leaves its id (its focus) be.
    if (buf.text().len == 0)
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 8, .y = 5 } }, .{ .text = .{ .str = prompt, .style = .{ .size = 12 }, .color = p.faint } }, null);
    return r;
}

// MARK: menus

const Pick = struct {
    b: *Browser,
    value: ?[]const u8,
    what: enum { provider, model },

    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const b = self.b;
        switch (self.what) {
            .provider => b.prefs.set("ai_provider", self.value),
            .model => if (b.kea.ai.chosen()) |provider| {
                b.prefs.setAIModel(self.value orelse "", provider.id);
                b.settings.ai.model.set(self.value orelse "");
            },
        }
        b.redraw();
    }
};

fn item(arena: std.mem.Allocator, b: *Browser, label: []const u8, value: ?[]const u8, what: @FieldType(Pick, "what"), checked: bool) !MenuItem {
    const pick = try arena.create(Pick);
    pick.* = .{ .b = b, .value = value, .what = what };
    return .{ .label = label, .checked = checked, .click = .of(pick, Pick.fire) };
}

/// "Where it runs": Choose…, the built-ins, a divider, the catalog's.
pub fn providerItems(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const on = b.prefs.ai_provider;
    var out: std.ArrayList(MenuItem) = .empty;
    try out.append(arena, try item(arena, b, "Choose…", null, .provider, on == null));
    for (try b.kea.ai.all(arena), 0..) |provider, n| {
        if (n == ai.built_ins.len) try out.append(arena, .separator);
        const checked = on != null and provider.is(on.?);
        try out.append(arena, try item(arena, b, try provider.label(arena), provider.id, .provider, checked));
    }
    return out.items;
}

/// `modelMenu`: what the provider listed when asked, else the catalog's;
/// then asking it.
fn modelItems(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const m = b.kea.ai;
    const provider = m.chosen() orelse return &.{};
    const s = &b.settings.ai;
    var out: std.ArrayList(MenuItem) = .empty;
    const catalog: []const []const u8 = for (try m.all(arena)) |x| {
        if (x.is(provider.id)) break x.models;
    } else &.{};
    const list: []const []const u8 = if (s.models.len == 0) catalog else s.models;
    for (list) |name| try out.append(arena, try item(arena, b, name, name, .model, false));
    try out.append(arena, .separator);
    const fetch = try arena.create(Fetch);
    fetch.* = .{ .b = b };
    try out.append(arena, .{ .label = try std.fmt.allocPrint(arena, "Fetch From {s}", .{provider.name}), .click = .of(fetch, Fetch.fire) });
    return out.items;
}

const Fetch = struct {
    b: *Browser,
    fn fire(self: *Fetch, _: *nanoui.menu.Item) void {
        const provider = self.b.kea.ai.chosen() orelse return;
        ask(self.b, provider, true);
    }
};

/// The local model `Picker`: Choose…, then each listed.
fn localItems(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const provider = b.kea.ai.chosen() orelse return &.{};
    const chosen = b.prefs.aiModel(provider.id, provider.suggested);
    var out: std.ArrayList(MenuItem) = .empty;
    try out.append(arena, try item(arena, b, "Choose…", "", .model, chosen.len == 0));
    for (b.settings.ai.models) |name| try out.append(arena, try item(arena, b, name, name, .model, std.mem.eql(u8, name, chosen)));
    return out.items;
}

// MARK: looking

/// `refresh`: the key's hint and source, and a local app's models.
fn refresh(b: *Browser) void {
    const s = &b.settings.ai;
    const m = b.kea.ai;
    s.gen +%= 1;
    if (s.gen == 0) s.gen = 1;
    const provider = m.chosen() orelse return;
    var arena: std.heap.ArenaAllocator = .init(b.gpa);
    defer arena.deinit();
    if (s.hint) |h| b.gpa.free(h);
    s.hint = null;
    if (provider.takesKey()) if (m.keys.hint(arena.allocator(), m, provider)) |h| {
        s.hint = b.gpa.dupe(u8, h) catch null;
    };
    s.source = switch (m.keys.source(arena.allocator(), m, provider)) {
        .keychain => .keychain,
        .environment => .variable,
        .command => .command,
    };
    s.kind = s.source;
    s.model.set(b.prefs.ai_models.get(provider.id) orelse "");
    s.setModels(b.gpa, &.{});
    s.looking = false;
    if (!provider.isLocal()) return;
    s.looking = true;
    ask(b, provider, false);
}

/// A listing under way, by the window's record id, so a window closed
/// meanwhile hears nothing.
const Asking = struct {
    kea: *Kea,
    window: Uuid,
    gen: u32,
    id: []u8,
    /// Asked from the model menu: an empty answer is said aloud.
    fetch: bool,
    had_key: bool = false,
};

fn ask(b: *Browser, provider: ai.Provider, fetch: bool) void {
    const l = b.gpa.create(Asking) catch return;
    l.* = .{ .kea = b.kea, .window = b.record_id, .gen = b.settings.ai.gen, .id = b.gpa.dupe(u8, provider.id) catch return b.gpa.destroy(l), .fetch = fetch };
    if (provider.takesKey() or fetch) b.kea.ai.keys.key(b.kea.ai, provider, l, keyed) else keyed(l, null);
}

fn keyed(ctx: *anyopaque, k: ?[]u8) void {
    const l: *Asking = @ptrCast(@alignCast(ctx));
    const m = l.kea.ai;
    defer if (k) |v| m.gpa.free(v);
    l.had_key = k != null;
    const provider = m.named(l.id) orelse return listed(l, &.{});
    client_more.models(m, provider, k, l, listed);
}

fn listed(ctx: *anyopaque, names: []const []u8) void {
    const l: *Asking = @ptrCast(@alignCast(ctx));
    const kea = l.kea;
    const gpa = kea.ai.gpa;
    defer {
        gpa.free(l.id);
        gpa.destroy(l);
    }
    const owned: [][]u8 = @constCast(names);
    const b = for (kea.browsers.items) |w| {
        if (w.record_id.eql(l.window)) break w;
    } else null;
    const s = if (b) |w| &w.settings.ai else null;
    if (s == null or (s.?.gen != l.gen and !l.fetch)) {
        for (owned) |n| gpa.free(n);
        gpa.free(owned);
        return;
    }
    s.?.setModels(gpa, owned);
    s.?.looking = false;
    const w = b.?;
    if (l.fetch and names.len == 0) if (kea.ai.named(l.id)) |provider| {
        const said = if (l.had_key) std.fmt.allocPrint(gpa, "{s} listed no models", .{provider.name}) else std.fmt.allocPrint(gpa, "No key for {s}", .{provider.name});
        if (said) |text| {
            w.announce(text);
            gpa.free(text);
        } else |_| {}
    };
    w.redraw();
}

/// `sign_in.ended`: each window's page looks again.
fn signedIn(ctx: *anyopaque, _: bool, _: ?[]const u8) void {
    const kea: *Kea = @ptrCast(@alignCast(ctx));
    for (kea.browsers.items) |b| if (b.settings.ai.appeared) {
        refresh(b);
        b.redraw();
    };
}
