//! Screen recording for extensions (ExtensionCapture.swift, #218): Loom,
//! Screencastify, Awesome Screenshot and the like. An extension's page asks
//! through the `keaCapture` channel, which knows who is asking; Kea asks
//! you, once per extension, whether it may record; brings the page on
//! screen; and calls WebKit's getDisplayMedia in that page itself, which
//! WebKit counts as a click. The Mac's picker follows, every time. What is
//! recording is watched in `capture_watch.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const value = @import("value.zig");
const Extensions = @import("controller.zig").Extensions;
const asking = @import("controller_asking.zig");
const offscreen = @import("offscreen.zig");
const watch_mod = @import("capture_watch.zig");
const Kea = @import("../app/kea.zig").Kea;
const Store = @import("../data/store.zig").Store;
const config = @import("../web/config.zig");
const dialogs = @import("../web/dialogs.zig");
const json = @import("../data/json.zig");

/// The name the pages post to (window.webkit.messageHandlers).
pub const channel = "keaCapture";

pub const screen = watch_mod.screen;
pub const capturing = watch_mod.capturing;
pub const watchScreen = watch_mod.watchScreen;
pub const watchCapture = watch_mod.watchCapture;
pub const watch = watch_mod.watch;
pub const stop = watch_mod.stop;
pub const mockDevices = watch_mod.mockDevices;
pub const set = watch_mod.set;
pub const uiDelegate = watch_mod.uiDelegate;
pub const Recording = watch_mod.Recording;

const gpa = std.heap.c_allocator;

/// `ExtensionCapture.shared`: the state lives in this file; `shared()`
/// gives the Swift-shaped handle.
pub const Capture = struct {
    pub const purge = capture_purge;
    pub const grant = capture_grant;
    pub const displayDecision = display_decision;
    pub const state = capture_state;
};
var the: Capture = .{};
pub fn shared() *Capture {
    return &the;
}

var owner_ref: ?*Extensions = null;

pub fn kea() ?*Kea {
    return if (owner_ref) |o| o.kea else null;
}

// MARK: asking, once per extension

/// `key(_:)`: `extensions.capture.<id>`, on `buf`.
pub fn key(buf: []u8, id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "extensions.capture.{s}", .{id}) catch "extensions.capture.";
}

pub fn allowed(store: *const Store, id: []const u8) bool {
    var buf: [300]u8 = undefined;
    return store.bool(key(&buf, id)) orelse false;
}

/// `allowedIDs`: the extensions you let record, sorted, on `alloc`.
pub fn allowedIDs(alloc: std.mem.Allocator, store: *const Store) ![][]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const prefix = "extensions.capture.";
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    const keys = objc.msg(objc.Object, objc.msg(objc.Object, store.defaults, "dictionaryRepresentation", .{}), "allKeys", .{});
    const n = objc.msg(objc.NSUInteger, keys, "count", .{});
    for (0..n) |i| {
        const k = objc.fromNSString(objc.msg(objc.Object, keys, "objectAtIndex:", .{i}));
        if (!std.mem.startsWith(u8, k, prefix)) continue;
        const id = k[prefix.len..];
        if (!allowed(store, id)) continue;
        try out.append(alloc, try alloc.dupe(u8, id));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.toOwnedSlice(alloc);
}

/// Bumped when who may record changes (Settings › Extensions redraws).
pub var changes: u64 = 0;
var refused: std.StringHashMapUnmanaged(void) = .empty;

/// `forget(_:)`: taken back; asked again the next time it wants to record.
pub fn forget(owner: *Extensions, id: []const u8) void {
    var buf: [300]u8 = undefined;
    owner.kea.store.remove(key(&buf, id));
    if (refused.fetchRemove(id)) |kv| gpa.free(kv.key);
    changes +%= 1;
}

fn contains(array: ?objc.Object, s: []const u8) bool {
    const a = array orelse return false;
    if (!objc.msg(objc.BOOL, a, "isKindOfClass:", .{objc.class("NSArray")})) return false;
    return objc.msg(objc.BOOL, a, "containsObject:", .{objc.nsString(s)});
}

fn idOf(context: objc.Object) []const u8 {
    return objc.fromNSString(objc.msg(?objc.Object, context, "uniqueIdentifier", .{}));
}

/// `declares(_:)`: it says so in its manifest, or was given it since.
pub fn declares(owner: *Extensions, context: objc.Object) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const manifest = objc.msg(?objc.Object, objc.msg(objc.Object, context, "webExtension", .{}), "manifest", .{});
    const required = if (manifest) |m| objc.msg(?objc.Object, m, "objectForKey:", .{objc.nsString("permissions")}) else null;
    var buf: [300]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "extensions.granted.{s}", .{idOf(context)}) catch return contains(required, "desktopCapture");
    const given = objc.msg(?objc.Object, owner.kea.store.defaults, "stringArrayForKey:", .{objc.nsString(name)});
    return contains(required, "desktopCapture") or contains(given, "desktopCapture");
}

const Consented = *const fn (job: *Job, yes: bool) void;

/// `consent(_:)`: yes from you now, or before and you have just used this
/// extension (its button within a minute, its pages within seconds).
/// Refused once, not asked again until KeaZig starts afresh.
fn consent(job: *Job, then: Consented) void {
    const owner = job.owner;
    const id = idOf(job.context);
    const pressed = asking.pressedWithin(owner, id, 60);
    if (allowed(&owner.kea.store, id) and (pressed or asking.justUsed(owner, id))) return then(job, true);
    if (refused.contains(id)) return then(job, false);
    job.consented = then;
    asking.askCapture(owner, job.context, job, answered);
}

fn answered(ctx: *anyopaque, yes: bool) void {
    const job: *Job = @ptrCast(@alignCast(ctx));
    const id = idOf(job.context);
    if (!yes) {
        if (!refused.contains(id)) if (gpa.dupe(u8, id)) |k| {
            refused.put(gpa, k, {}) catch gpa.free(k);
        } else |_| {};
    } else {
        var buf: [300]u8 = undefined;
        job.owner.kea.store.setBool(key(&buf, id), true);
        changes +%= 1;
    }
    job.consented.?(job, yes);
}

// MARK: stream ids

/// A stream id handed to an extension: good once, for a minute, for that
/// extension only.
const Grant = struct { extension_id: []u8, made: f64 };
var grants: std.StringHashMapUnmanaged(Grant) = .empty;

/// `token()`: 16 random bytes as hex.
fn token() [32]u8 {
    var bytes: [16]u8 = undefined;
    std.c.arc4random_buf(&bytes, bytes.len);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn dropGrant(k: []const u8, g: Grant) void {
    gpa.free(k);
    gpa.free(g.extension_id);
}

fn expire() void {
    const now = json.now();
    var i = grants.iterator();
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    while (i.next()) |e| if (now - e.value_ptr.made >= 60) stale.append(gpa, e.key_ptr.*) catch {};
    for (stale.items) |k| if (grants.fetchRemove(k)) |kv| dropGrant(kv.key, kv.value);
}

/// `grant(for:)`: from the extension's worker, which has no page to record
/// in: the id now (`reply.ok(NSString)`, "" when not allowed); the
/// recording starts when one of its pages hands it to getUserMedia.
fn capture_grant(_: *Capture, owner: *Extensions, context: objc.Object, reply: value.Reply) void {
    if (!declares(owner, context)) return replyText(reply, "");
    const job = Job.make(owner, context, null, .{ .worker = reply }) orelse return replyText(reply, "");
    consent(job, granted);
}

fn replyText(reply: value.Reply, s: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    reply.ok(objc.nsString(s));
}

fn granted(job: *Job, yes: bool) void {
    defer job.free();
    const reply = job.reply.worker;
    if (!yes) return replyText(reply, "");
    expire();
    const t = token();
    const k = gpa.dupe(u8, &t) catch return replyText(reply, "");
    const ext_id = gpa.dupe(u8, idOf(job.context)) catch {
        gpa.free(k);
        return replyText(reply, "");
    };
    grants.put(gpa, k, .{ .extension_id = ext_id, .made = json.now() }) catch {
        dropGrant(k, .{ .extension_id = ext_id, .made = 0 });
        return replyText(reply, "");
    };
    replyText(reply, &t);
}

// MARK: the channel

/// What the bench reads: the last request and its answer (retained).
var last: ?objc.Object = null;

/// A request on its way: consent, the page on screen, the call in it.
pub const Job = struct {
    owner: *Extensions,
    context: objc.Object,
    web: ?objc.Object,
    reply: union(enum) { worker: value.Reply, page: value.Reply },
    consented: ?Consented = null,
    op: []const u8 = "",
    token: [32]u8 = undefined,
    video: ?objc.Object = null,
    window: bool = false,
    lend: bool = false,
    tries: u8 = 0,

    fn make(owner: *Extensions, context: objc.Object, web: ?objc.Object, reply: @FieldType(Job, "reply")) ?*Job {
        const j = gpa.create(Job) catch return null;
        j.* = .{ .owner = owner, .context = objc.retain(context), .web = if (web) |w| objc.retain(w) else null, .reply = reply };
        return j;
    }

    fn free(self: *Job) void {
        objc.release(self.context);
        if (self.web) |w| objc.release(w);
        if (self.video) |v| objc.release(v);
        if (self.op.len > 0) gpa.free(self.op);
        gpa.destroy(self);
    }
};

fn failure(comptime err: []const u8, comptime message: []const u8) ?objc.Object {
    return value.objectOf(.{ .@"error" = err, .message = message });
}

/// The receiving object: `WKScriptMessageHandlerWithReply` for the channel,
/// and the KVO observer for what is recording. One for the app (retained).
pub fn instance() objc.Object {
    const S = struct {
        var made: ?objc.Object = null;
    };
    if (S.made) |m| return m;
    const cls = objc.defineClass(.{
        .name = "KeaZigCapture",
        .protocols = &.{"WKScriptMessageHandlerWithReply"},
        .methods = &.{
            .{ .name = "userContentController:didReceiveScriptMessage:replyHandler:", .imp = &received, .types = "v@:@@@?" },
            .{ .name = "observeValueForKeyPath:ofObject:change:context:", .imp = &observed, .types = "v@:@@@^v" },
        },
    });
    S.made = objc.msg(objc.Object, cls, "new", .{});
    return S.made.?;
}

/// What ExtController registers on the extension pages' content controller
/// under `channel` (page world).
pub fn handler(owner: *Extensions) objc.Object {
    owner_ref = owner;
    return instance();
}

/// The controller is going away (`Kea.destroy`): stop pointing at it.
pub fn release(owner: *Extensions) void {
    if (owner_ref == owner) owner_ref = null;
}

fn observed(_: objc.Object, _: objc.SEL, _: ?objc.Object, _: ?objc.Object, _: ?objc.Object, _: ?*anyopaque) callconv(.c) void {
    watch_mod.observed();
}

fn get(dict: objc.Object, k: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(k)});
}

fn isKind(o: ?objc.Object, comptime cls: [:0]const u8) bool {
    const x = o orelse return false;
    return objc.msg(objc.BOOL, x, "isKindOfClass:", .{objc.class(cls)});
}

fn remember(op: []const u8, said: ?objc.Object) void {
    const d = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSMutableDictionary"), "alloc", .{}), "init", .{});
    if (said) |a| {
        const keys = objc.msg(objc.Object, a, "allKeys", .{});
        const n = objc.msg(objc.NSUInteger, keys, "count", .{});
        for (0..n) |i| {
            const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
            objc.msg(void, d, "setObject:forKey:", .{ objc.msg(objc.Object, objc.msg(objc.Object, a, "objectForKey:", .{k}), "description", .{}), k });
        }
    }
    if (get(d, "op") == null) objc.msg(void, d, "setObject:forKey:", .{ objc.nsString(op), objc.nsString("op") });
    if (last) |l| objc.release(l);
    last = d;
}

fn received(_: objc.Object, _: objc.SEL, _: objc.Object, message: objc.Object, reply_block: *const anyopaque) callconv(.c) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const body = objc.msg(?objc.Object, message, "body", .{});
    const op_obj = if (isKind(body, "NSDictionary")) get(body.?, "op") else null;
    if (!isKind(op_obj, "NSString")) return dialogs.call(reply_block, .{ @as(?objc.Object, null), @as(?objc.Object, objc.nsString("Not a request")) });
    const op = objc.fromNSString(op_obj);
    const reply = value.Reply.take(reply_block);
    // Only the top of one of an extension's own pages, in a view of that
    // extension's.
    const from = sender(message) orelse {
        remember(op, value.objectOf(.{ .refused = "sender" }));
        return reply.ok(failure("NotAllowedError", "Not allowed here"));
    };
    // The microphone or camera, from an offscreen document: one made to
    // record is lent to the pill first. Any other extension page goes on.
    if (std.mem.eql(u8, op, "lend")) {
        const records = offscreen.records(from.web) orelse return reply.ok(value.objectOf(.{ .ok = true }));
        if (!records) return reply.ok(failure("NotAllowedError", "This offscreen document wasn't made to record"));
        watch_mod.lendAwhile(from.web);
        return reply.ok(value.objectOf(.{ .ok = true }));
    }
    const job = Job.make(owner_ref.?, from.context, from.web, .{ .page = reply }) orelse return reply.ok(failure("AbortError", "No answer"));
    job.op = gpa.dupe(u8, op) catch "";
    answer(job, body.?);
}

pub const Sender = struct { context: objc.Object, web: objc.Object };

/// `sender(of:)`: the extension and the view, for a message from the top of
/// one of its own pages in a persistent view; null otherwise.
pub fn sender(message: objc.Object) ?Sender {
    const owner = owner_ref orelse return null;
    const info = objc.msg(objc.Object, message, "frameInfo", .{});
    if (!objc.msg(objc.BOOL, info, "isMainFrame", .{})) return null;
    const web = objc.msg(?objc.Object, message, "webView", .{}) orelse return null;
    const origin = objc.msg(objc.Object, info, "securityOrigin", .{});
    const scheme = objc.fromNSString(objc.msg(?objc.Object, origin, "protocol", .{}));
    if (!std.ascii.eqlIgnoreCase(scheme, "chrome-extension") and !std.ascii.eqlIgnoreCase(scheme, "webkit-extension")) return null;
    const asker = objc.fromNSString(objc.msg(?objc.Object, origin, "host", .{}));
    const url = objc.msg(?objc.Object, web, "URL", .{}) orelse return null;
    if (!std.ascii.eqlIgnoreCase(objc.fromNSString(objc.msg(?objc.Object, url, "scheme", .{})), scheme)) return null;
    if (!std.ascii.eqlIgnoreCase(objc.fromNSString(objc.msg(?objc.Object, url, "host", .{})), asker)) return null;
    const context = for (owner.contexts.values()) |c| {
        if (std.ascii.eqlIgnoreCase(idOf(c), asker)) break c;
    } else return null;
    const store = objc.msg(objc.Object, objc.msg(objc.Object, web, "configuration", .{}), "websiteDataStore", .{});
    if (!objc.msg(objc.BOOL, store, "isPersistent", .{})) return null;
    return .{ .context = context, .web = web };
}

fn finish(job: *Job, result: ?objc.Object) void {
    defer job.free();
    const pool = objc.Pool.push();
    defer pool.pop();
    remember(job.op, result);
    job.reply.page.ok(result);
}

fn answer(job: *Job, body: objc.Object) void {
    const op = job.op;
    const display = std.mem.eql(u8, op, "display");
    if (!declares(job.owner, job.context) and !display)
        return finish(job, failure("NotAllowedError", "It didn't ask to record your screen"));
    // An offscreen document records only if it was made to.
    if (offscreen.records(job.web.?) == false)
        return finish(job, failure("NotAllowedError", "This offscreen document wasn't made to record"));
    job.video = objc.retain(get(body, "video") orelse objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES}));
    // Which picker: a screen, or a window — Chrome's sources in order of
    // preference, or getDisplayMedia's displaySurface.
    var first: []const u8 = "";
    if (get(body, "sources")) |sources| if (isKind(sources, "NSArray")) {
        const n = objc.msg(objc.NSUInteger, sources, "count", .{});
        for (0..n) |i| {
            const s = objc.msg(objc.Object, sources, "objectAtIndex:", .{i});
            if (!isKind(s, "NSString")) continue;
            const t = objc.fromNSString(s);
            if (std.mem.eql(u8, t, "screen") or std.mem.eql(u8, t, "window") or std.mem.eql(u8, t, "tab")) {
                first = t;
                break;
            }
        }
    };
    const surface_obj = get(body, "surface");
    const surface = if (isKind(surface_obj, "NSString")) objc.fromNSString(surface_obj) else "";
    job.window = std.mem.eql(u8, first, "window") or std.mem.eql(u8, first, "tab") or
        std.mem.eql(u8, surface, "window") or std.mem.eql(u8, surface, "browser");
    if (display or std.mem.eql(u8, op, "choose")) return consent(job, chosen);
    if (std.mem.eql(u8, op, "consume")) {
        const t = get(body, "token");
        if (!isKind(t, "NSString")) return finish(job, failure("NotAllowedError", "Invalid state"));
        const text = objc.fromNSString(t);
        const kv = grants.fetchRemove(text) orelse return finish(job, failure("NotAllowedError", "Invalid state"));
        defer dropGrant(kv.key, kv.value);
        if (!std.mem.eql(u8, kv.value.extension_id, idOf(job.context)) or json.now() - kv.value.made >= 60 or text.len != 32)
            return finish(job, failure("NotAllowedError", "Invalid state"));
        @memcpy(&job.token, text);
        return record(job);
    }
    finish(job, failure("NotSupportedError", "Unknown request"));
}

fn chosen(job: *Job, yes: bool) void {
    if (!yes) return finish(job, failure("NotAllowedError", "Permission denied"));
    job.token = token();
    record(job);
}

// MARK: recording

/// Pages where KeaZig's own call is under way, and the picker it asks for
/// (1 a screen, 2 a window).
var in_flight: std.AutoHashMapUnmanaged(usize, objc.NSInteger) = .empty;

/// `displayDecision(for:)`: WKDisplayCapturePermissionDecision, 0 no.
fn display_decision(_: *Capture, web: objc.Object) objc.NSInteger {
    return in_flight.get(@intFromPtr(web)) orelse 0;
}

pub const display_selector = "_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:";

/// The private UI-delegate method, for offscreen documents, the page
/// delegate and the popup: yes only while KeaZig's own call is under way.
pub fn displayCapture(_: objc.Object, _: objc.SEL, web: objc.Object, _: objc.Object, _: objc.Object, _: objc.BOOL, decide: *const anyopaque) callconv(.c) void {
    dialogs.call(decide, .{the.displayDecision(web)});
}

fn testing(job: *const Job) bool {
    return job.owner.kea.opts.root != null;
}

/// `record(in:…)`: the page on screen — an offscreen one lent to the pill,
/// a tab's brought forward — then the call in it.
fn record(job: *Job) void {
    const web = job.web.?;
    job.lend = offscreen.records(web) != null;
    if (job.lend) watch_mod.host(web) else if (!testing(job)) watch_mod.bringForward(job.owner.kea, web);
    if (testing(job)) return force(job);
    poll(job);
}

const VisibilityBlock = objc.Block(Job, &.{ ?objc.Object, ?objc.Object });

/// Up to 20 looks, 100 ms apart, for the page to be seen.
fn poll(job: *Job) void {
    if (job.tries >= 20) return force(job);
    job.tries += 1;
    const pool = objc.Pool.push();
    defer pool.pop();
    const window = objc.msg(?objc.Object, job.web.?, "window", .{});
    // NSWindowOcclusionStateVisible = 1 << 1; only asked of a tab's window.
    const seen = if (window) |w| objc.msg(objc.BOOL, w, "isVisible", .{}) and
        (job.lend or objc.msg(objc.NSUInteger, w, "occlusionState", .{}) & 2 != 0) else false;
    if (!seen) return later(job);
    var block = VisibilityBlock.init(job, visibility);
    objc.msg(void, job.web.?, "evaluateJavaScript:completionHandler:", .{ objc.nsString("document.visibilityState"), @as(*anyopaque, @ptrCast(&block)) });
}

fn visibility(job: *Job, result: ?objc.Object, _: ?objc.Object) void {
    if (isKind(result, "NSString") and std.mem.eql(u8, objc.fromNSString(result), "visible")) return force(job);
    later(job);
}

fn later(job: *Job) void {
    objc.dispatchAfter(100 * std.time.ns_per_ms, job, struct {
        fn f(ctx: ?*anyopaque) callconv(.c) void {
            poll(@ptrCast(@alignCast(ctx.?)));
        }
    }.f);
}

const ForceBlock = objc.Block(Job, &.{ ?objc.Object, ?objc.Object });

/// `force(in:…)`: called by the app, so WebKit counts it as a click: the
/// page's own getDisplayMedia, kept by the shim, is called at once.
fn force(job: *Job) void {
    const web = job.web.?;
    in_flight.put(gpa, @intFromPtr(web), if (job.window) 2 else 1) catch {};
    const pool = objc.Pool.push();
    defer pool.pop();
    const args = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    objc.msg(void, args, "setObject:forKey:", .{ objc.nsString(&job.token), objc.nsString("token") });
    objc.msg(void, args, "setObject:forKey:", .{ job.video.?, objc.nsString("video") });
    var block = ForceBlock.init(job, forced);
    objc.msg(void, web, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", .{
        objc.nsString("return await globalThis[Symbol.for('kea.capture')](token, video);"),
        args,
        @as(?objc.Object, null),
        config.pageWorld(),
        @as(*anyopaque, @ptrCast(&block)),
    });
}

fn forced(job: *Job, result: ?objc.Object, err: ?objc.Object) void {
    const web = job.web.?;
    _ = in_flight.remove(@intFromPtr(web));
    const pool = objc.Pool.push();
    defer pool.pop();
    var ok = false;
    const out: ?objc.Object = if (err) |e| blk: {
        const d = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
        objc.msg(void, d, "setObject:forKey:", .{ objc.nsString("AbortError"), objc.nsString("error") });
        objc.msg(void, d, "setObject:forKey:", .{ objc.msg(objc.Object, e, "localizedDescription", .{}), objc.nsString("message") });
        break :blk d;
    } else if (!isKind(result, "NSDictionary"))
        failure("AbortError", "No answer")
    else blk: {
        const said = get(result.?, "ok");
        if (isKind(said, "NSNumber") and objc.msg(objc.BOOL, said.?, "boolValue", .{})) {
            ok = true;
            watch_mod.watch(web, idOf(job.context));
            break :blk value.objectOf(.{ .ok = true, .token = @as([]const u8, &job.token) });
        }
        break :blk result;
    };
    if (job.lend and !ok) watch_mod.giveBack(web);
    finish(job, out);
}

// MARK: the rest

/// `purge(_:)`: the extension went away: what it records stops, and its ids
/// with it.
fn capture_purge(_: *Capture, id: []const u8) void {
    stop(id);
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(gpa);
    var i = grants.iterator();
    while (i.next()) |e| if (std.mem.eql(u8, e.value_ptr.extension_id, id)) stale.append(gpa, e.key_ptr.*) catch {};
    for (stale.items) |k| if (grants.fetchRemove(k)) |kv| dropGrant(kv.key, kv.value);
}

/// `state`: what the bench sees, autoreleased.
fn capture_state(_: *Capture) ?objc.Object {
    const k = kea() orelse return null;
    const ids = allowedIDs(gpa, &k.store) catch return null;
    defer {
        for (ids) |s| gpa.free(s);
        gpa.free(ids);
    }
    const Line = struct { id: []const u8, what: []const u8 };
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    var pills: std.ArrayList([]u8) = .empty;
    defer {
        for (pills.items) |p| gpa.free(p);
        pills.deinit(gpa);
    }
    for (watch_mod.recordings.items) |r| {
        lines.append(gpa, .{ .id = r.id, .what = r.what() }) catch {};
        if (std.fmt.allocPrint(gpa, "{s} {s}", .{ r.name, r.what() })) |p| pills.append(gpa, p) catch gpa.free(p) else |_| {}
    }
    const base = value.objectOf(.{
        .grants = grants.count(),
        .recordings = lines.items,
        .allowed = ids,
        .pill = pills.items,
        .lent = watch_mod.lent.count(),
        .lendings = watch_mod.lendings,
        .watching = watch_mod.watching(),
    }) orelse return null;
    const d = objc.msg(objc.Object, base, "mutableCopy", .{});
    objc.autorelease(d);
    const empty = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    objc.msg(void, d, "setObject:forKey:", .{ last orelse empty, objc.nsString("last") });
    return d;
}

test "capture key is extensions.capture.<id>" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("extensions.capture.abc", key(&buf, "abc"));
    const t = token();
    for (t) |c| try std.testing.expect(std.ascii.isHex(c));
}
