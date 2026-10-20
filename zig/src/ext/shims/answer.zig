//! What the shim asks the browser (`ExtensionShims.answer`/`run`,
//! ExtensionShims.swift 3280-4119): a message `{api, args}` from an
//! extension, answered `{value}` or `{error}`. The gates live here; each API
//! family answers in a file of its own (`<family>.zig`, `run(c) ?Out`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const val = @import("../value.zig");
const Extensions = @import("../controller.zig").Extensions;
const Browser = @import("../../model/browser.zig").Browser;
pub const app_name = @import("../../app/kea.zig").app_name;

pub const Value = std.json.Value;
pub const Error = error{ Unsupported, OutOfMemory };
/// A branch's answer: a value now, or `later`, when it handed
/// `c.later()`'s reply (or `c.pending`) to something that answers in time.
pub const Out = union(enum) { value: Value, later };
/// Swift's `return nil`: JS `null`.
pub const none: Out = .{ .value = .null };

const families = .{
    @import("bookmarks.zig"),     @import("history.zig"),  @import("downloads.zig"),
    @import("side_panel.zig"),    @import("pages.zig"),    @import("system.zig"),
    @import("notify.zig"),        @import("speech.zig"),   @import("scripts.zig"),
    @import("settings.zig"),      @import("tabs.zig"),     @import("groups.zig"),
    @import("browsing_data.zig"),
};

/// The popup as its worker finds it (`ExtensionPopup.client(of:)`): set by
/// the popup (UI wave); `url` borrowed until the next call.
pub const PopupClient = struct { url: []const u8, visible: bool, focused: bool };

/// `ExtensionShims`' statics, kept on `Extensions.answer`. Keys and strings on gpa.
pub const State = struct {
    /// Side panel path each extension set; ids whose button opens it.
    panel_path: std.StringHashMapUnmanaged([]u8) = .empty,
    panel_on_click: std.StringHashMapUnmanaged(void) = .empty,
    /// Popups set for buttons: id → (decimal tab id, or "*") → path.
    popups: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]u8)) = .empty,
    /// Keep-awake assertions (IOPMAssertionID), one per extension that asked.
    awake: std.StringHashMapUnmanaged(u32) = .empty,
    /// favIconUrl data: URLs by site.
    fav_icons: std.StringHashMapUnmanaged([]u8) = .empty,
    /// One AVSpeechSynthesizer for every extension that reads aloud (retained).
    speaker: ?objc.Object = null,
    /// The popup's page while up (ExtensionPopup.swift:64), set by the UI wave.
    popup_client: ?*const fn (owner: *Extensions, id: []const u8) ?PopupClient = null,
};

pub fn deinit(owner: *Extensions) void {
    const s = &owner.answer;
    const gpa = owner.gpa;
    var it = s.awake.iterator();
    while (it.next()) |e| @import("system.zig").release(e.value_ptr.*);
    freeKeys(gpa, &s.awake);
    freeStrings(gpa, &s.panel_path);
    freeKeys(gpa, &s.panel_on_click);
    freeStrings(gpa, &s.fav_icons);
    var p = s.popups.iterator();
    while (p.next()) |e| freeStrings(gpa, e.value_ptr);
    freeKeys(gpa, &s.popups);
    if (s.speaker) |sp| {
        _ = objc.msg(objc.BOOL, sp, "stopSpeakingAtBoundary:", .{@as(objc.NSInteger, 0)});
        objc.release(sp);
    }
    s.* = .{};
}

/// A map's keys freed, then the map.
pub fn freeKeys(gpa: std.mem.Allocator, map: anytype) void {
    var it = map.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    map.deinit(gpa);
}

/// A map of gpa strings to gpa strings freed.
pub fn freeStrings(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]u8)) void {
    var it = map.iterator();
    while (it.next()) |e| gpa.free(e.value_ptr.*);
    freeKeys(gpa, map);
}

/// `map[key] = text`, both copied onto gpa.
pub fn putString(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged([]u8), key: []const u8, text: []const u8) !void {
    const copy = try gpa.dupe(u8, text);
    errdefer gpa.free(copy);
    const gop = try map.getOrPut(gpa, key);
    if (gop.found_existing) gpa.free(gop.value_ptr.*) else gop.key_ptr.* = gpa.dupe(u8, key) catch |e| {
        map.removeByPtr(gop.key_ptr);
        return e;
    };
    gop.value_ptr.* = copy;
}

/// `Extensions.swift:515`: an extension unloaded lets the Mac sleep again.
pub fn releaseAwake(owner: *Extensions, id: []const u8) void {
    const kv = owner.answer.awake.fetchRemove(id) orelse return;
    @import("system.zig").release(kv.value);
    owner.gpa.free(kv.key);
}

/// `forgetIcons` (Icons.swift:35): the icons forgotten, so are their data: URLs.
pub fn forgetIcons(owner: *Extensions) void {
    freeStrings(owner.gpa, &owner.answer.fav_icons);
    owner.answer.fav_icons = .empty;
}

// MARK: - one answer in flight

/// The reply and everything read for it, until it is answered (once).
pub const Pending = struct {
    arena: std.heap.ArenaAllocator,
    reply: val.Reply,

    /// `{value: obj}`, nil as null.
    pub fn object(p: *Pending, obj: ?objc.Object) void {
        defer p.free();
        const pool = objc.Pool.push();
        defer pool.pop();
        p.reply.ok(dict("value", obj orelse objc.msg(objc.Object, objc.class("NSNull"), "null", .{})));
    }

    pub fn value(p: *Pending, v: Value) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        p.object(val.toObject(v));
    }

    /// `{error: why}`: the extension's promise rejects with it.
    pub fn fail(p: *Pending, why: []const u8) void {
        defer p.free();
        const pool = objc.Pool.push();
        defer pool.pop();
        p.reply.ok(dict("error", objc.nsString(why)));
    }

    fn free(p: *Pending) void {
        const gpa = p.arena.child_allocator;
        p.arena.deinit();
        gpa.destroy(p);
    }

    /// A WebKit-style `(id, NSError*)` reply for a peer that answers in its
    /// own time; what it answers is wrapped as `{value}` / `{error}`.
    pub fn wrapped(p: *Pending) val.Reply {
        var block = objc.Block(Pending, &.{ ?objc.Object, ?objc.Object }).init(p, done);
        return val.Reply.take(&block);
    }

    fn done(p: *Pending, obj: ?objc.Object, err: ?objc.Object) void {
        if (err) |e| return p.fail(objc.fromNSString(objc.msg(?objc.Object, e, "localizedDescription", .{})));
        p.object(obj);
    }
};

fn dict(key: []const u8, obj: objc.Object) objc.Object {
    return objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ obj, objc.nsString(key) });
}

/// One message being answered. Everything on `a` lives until it is.
pub const Call = struct {
    owner: *Extensions,
    browser: *Browser,
    context: objc.Object,
    /// `context.uniqueIdentifier`: the installed row's id.
    id: []const u8,
    api: []const u8,
    args: []const Value,
    a: std.mem.Allocator,
    pending: *Pending,
    why: []const u8 = "",
    manifest_json: ?Value = null,

    /// `args[i]`, nil when missing or null.
    pub fn arg(c: *const Call, i: usize) ?Value {
        if (i >= c.args.len or c.args[i] == .null) return null;
        return c.args[i];
    }

    pub fn first(c: *const Call) ?Value {
        return c.arg(0);
    }

    /// `throw Unsupported(what:)`.
    pub fn fail(c: *Call, comptime fmt: []const u8, args: anytype) Error {
        c.why = std.fmt.allocPrint(c.a, fmt, args) catch "Out of memory";
        return error.Unsupported;
    }

    /// Anything `std.json` writes (structs, slices, Values) as a Value;
    /// null optionals left out, as Swift leaves nil keys out.
    pub fn of(c: *Call, x: anytype) Error!Value {
        const text = std.json.Stringify.valueAlloc(c.a, x, .{ .emit_null_optional_fields = false }) catch return error.OutOfMemory;
        return std.json.parseFromSliceLeaky(Value, c.a, text, .{}) catch error.OutOfMemory;
    }

    pub fn give(c: *Call, x: anytype) Error!?Out {
        return .{ .value = try c.of(x) };
    }

    /// The reply to hand to whatever answers later; the branch returns `.later`.
    /// Once handed (this, or `c.pending` itself), nothing fallible may follow:
    /// an error would answer — and free — a second time.
    pub fn later(c: *Call) val.Reply {
        return c.pending.wrapped();
    }

    /// `context.webExtension`.
    pub fn webExtension(c: *const Call) objc.Object {
        return objc.msg(objc.Object, c.context, "webExtension", .{});
    }

    /// `context.webExtension.manifest`, as JSON (null when it won't say).
    pub fn manifest(c: *Call) Value {
        if (c.manifest_json) |m| return m;
        c.manifest_json = manifestOf(c.a, c.context);
        return c.manifest_json.?;
    }

    /// `allowed(id, context)`.
    pub fn allowed(c: *Call, permission: []const u8) bool {
        return allowsIn(c.a, c.owner, c.id, c.manifest(), permission);
    }
};

fn manifestOf(a: std.mem.Allocator, context: objc.Object) Value {
    const ext = objc.msg(objc.Object, context, "webExtension", .{});
    const parsed = val.toJson(a, objc.msg(?objc.Object, ext, "manifest", .{})) orelse return .null;
    return parsed.value;
}

// MARK: - helpers on what came in (Swift's `as?`)

pub fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// `as? Int`: a whole number.
pub fn int(v: ?Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and @abs(f) < 9.0e15) @intFromFloat(f) else null,
        else => null,
    };
}

/// `as? Double`.
pub fn num(v: ?Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn flag(v: ?Value) ?bool {
    const x = v orelse return null;
    return if (x == .bool) x.bool else null;
}

pub fn list(v: ?Value) ?[]Value {
    const x = v orelse return null;
    return if (x == .array) x.array.items else null;
}

pub fn isObject(v: ?Value) bool {
    const x = v orelse return false;
    return x == .object;
}

/// `(v as? [String: Any])?[key]`, nil for null.
pub fn field(v: ?Value, key: []const u8) ?Value {
    const x = v orelse return null;
    if (x != .object) return null;
    const got = x.object.get(key) orelse return null;
    return if (got == .null) null else got;
}

/// `(v as? [Any])?.compactMap { $0 as? String } ?? []`.
pub fn strings(a: std.mem.Allocator, v: ?Value) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (list(v) orelse &.{}) |x| if (x == .string) try out.append(a, x.string);
    return out.items;
}

/// `v as? [String]`: only when every one is a string.
pub fn allStrings(a: std.mem.Allocator, v: ?Value) !?[]const []const u8 {
    const items = list(v) orelse return null;
    for (items) |x| if (x != .string) return null;
    return try strings(a, v);
}

pub fn contains(set: []const []const u8, x: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

// MARK: - what it asked for

/// The defaults key Kea keeps optional grants under.
pub fn grantedKey(a: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "extensions.granted.{s}", .{id});
}

/// `Store.settings.stringArray(forKey: "extensions.granted.<id>") ?? []`, on `a`.
pub fn granted(a: std.mem.Allocator, owner: *Extensions, id: []const u8) ![]const []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const key = try grantedKey(a, id);
    const obj = objc.msg(?objc.Object, owner.kea.store.defaults, "stringArrayForKey:", .{objc.nsString(key)});
    const parsed = val.toJson(a, obj) orelse return &.{};
    return strings(a, parsed.value);
}

/// The grants written back (`Store.settings.set(_, forKey:)`).
pub fn setGranted(a: std.mem.Allocator, owner: *Extensions, id: []const u8, names: []const []const u8) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const key = try grantedKey(a, id);
    const text = try std.json.Stringify.valueAlloc(a, names, .{});
    const arr = val.fromText(text) orelse return;
    objc.msg(void, owner.kea.store.defaults, "setObject:forKey:", .{ arr, objc.nsString(key) });
}

/// `allowed(id, context).contains(permission)` (ExtensionShims.swift:3395):
/// what the manifest named, and any optional ones granted since.
pub fn allows(owner: *Extensions, id: []const u8, context: objc.Object, permission: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(owner.gpa);
    defer arena.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    return allowsIn(arena.allocator(), owner, id, manifestOf(arena.allocator(), context), permission);
}

fn allowsIn(a: std.mem.Allocator, owner: *Extensions, id: []const u8, manifest: Value, permission: []const u8) bool {
    const asked = strings(a, field(manifest, "permissions")) catch return false;
    if (contains(asked, permission)) return true;
    return contains(granted(a, owner, id) catch return false, permission);
}

/// The families whose answers leave the extension's own origin: gated on
/// the names its manifest asked for (`gates`).
const gates = std.StaticStringMap(void).initComptime(.{
    .{"bookmarks"},     .{"history"},   .{"downloads"}, .{"sessions"},      .{"topSites"},
    .{"browsingData"},  .{"readingList"}, .{"userScripts"}, .{"identity"},  .{"search"},
    .{"notifications"}, .{"idle"},      .{"power"},     .{"tts"},           .{"tabGroups"},
});

// MARK: - answering

/// `ExtensionShims.answer(_:from:owner:)`: always answered, `{value}` or `{error}`.
pub fn answer(owner: *Extensions, message: objc.Object, context: objc.Object, reply: val.Reply) void {
    const p = owner.gpa.create(Pending) catch {
        const pool = objc.Pool.push();
        defer pool.pop();
        return reply.ok(dict("error", objc.nsString("Out of memory")));
    };
    p.* = .{ .arena = .init(owner.gpa), .reply = reply };
    const a = p.arena.allocator();
    const body = val.toJson(a, message) orelse return p.fail("Not a Kea message");
    const api = str(field(body.value, "api")) orelse return p.fail("Not a Kea message");
    const browser = owner.browser() orelse return p.fail("No browser window");
    const c = a.create(Call) catch return p.fail("Out of memory");
    c.* = .{
        .owner = owner,
        .browser = browser,
        .context = context,
        .id = a.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, context, "uniqueIdentifier", .{}))) catch return p.fail("Out of memory"),
        .api = api,
        .args = list(field(body.value, "args")) orelse &.{},
        .a = a,
        .pending = p,
    };
    const out = run(c) catch |e| return p.fail(if (e == error.Unsupported) c.why else "Out of memory");
    switch (out) {
        .value => |v| p.value(v),
        .later => {},
    }
}

fn run(c: *Call) Error!Out {
    const api = c.api;
    if (std.mem.startsWith(u8, api, "setting.")) {
        // A browser setting (chrome.privacy…) belongs to the family its name
        // starts with; only an extension that asked for it may touch it.
        const name = if (std.mem.indexOfScalar(u8, api, ':')) |i| api[i + 1 ..] else "";
        const family = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
        if (family.len == 0 or !c.allowed(family)) return c.fail("The extension never asked for \u{201C}{s}\u{201D}", .{family});
        return .{ .value = try @import("settings.zig").setting(c, name) };
    }
    // `tabs.describe` is guarded by WebKit's own "tabs" permission.
    if (std.mem.eql(u8, api, "tabs.describe") and !objc.msg(objc.BOOL, c.context, "hasPermission:", .{objc.nsString("tabs")}))
        return c.fail("The extension never asked for \u{201C}tabs\u{201D}", .{});
    const family = api[0 .. std.mem.indexOfScalar(u8, api, '.') orelse api.len];
    if (gates.has(family) and !c.allowed(family)) return c.fail("The extension never asked for \u{201C}{s}\u{201D}", .{family});
    inline for (families) |f| if (try f.run(c)) |out| return out;
    return c.fail("{s} isn't available in " ++ app_name, .{api});
}

// MARK: - the side panel and the button's popup (side_panel.zig), for the controller
const side_panel = @import("side_panel.zig");
pub const defaultPanel = side_panel.defaultPanel;
pub const openPanel = side_panel.openPanel;
pub const panelOnClick = side_panel.panelOnClick;
pub const popupFor = side_panel.popupFor;

test {
    std.testing.refAllDecls(@This());
}
