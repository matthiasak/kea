//! Passkeys and security keys, carried by Kea itself (Passkeys.swift
//! `Passkeys`): a page's request is taken from its own script, checked
//! against the frame WebKit says it came from, and handed to
//! AuthenticationServices with client data Kea writes; what comes back goes
//! to the page as the credential WebKit would have made. A request from
//! under a name field waits, offered in the account list, until you pick.
//! A run with its own folder (tests) never asks the Mac: it gets made-up
//! credentials (`reply.rehearsal`). Main thread.
const std = @import("std");
const objc = @import("nanoui").objc;
const Kea = @import("../app/kea.zig").Kea;
const json = @import("../data/json.zig");
const registrable = @import("../data/registrable.zig");
const reply = @import("passkeys_reply.zig");
const req = @import("passkeys_requests.zig");
const relay = @import("passkeys_relay.zig");
const call = @import("../web/dialogs.zig").call;

pub const Offered = reply.Offered;
pub const Reply = reply.Reply;
pub const Body = req.Body;

/// The handler's name, in Kea's world (`PasskeyRelay.name`).
pub const name = "keaPasskeys";
/// `PasskeyRelay.bridge`: document start, every frame, Kea's world.
pub const bridge_script = @embedFile("js/passkeys_bridge.js");

const page_source = @embedFile("js/passkeys_page.js");
const prf_token = "__KEA_PRF__";
fn pageWith(comptime prf: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(200_000);
        const at = std.mem.indexOf(u8, page_source, prf_token).?;
        return page_source[0..at] ++ prf ++ page_source[at + prf_token.len ..];
    }
}
const page_prf = pageWith("true");
const page_no_prf = pageWith("false");

/// `PasskeyRelay.page`: document start, every frame, the page's own world,
/// when passkeys are offered; `forms.without_passkeys` otherwise.
pub fn pageScript() []const u8 {
    return if (req.prfAvailable()) page_prf else page_no_prf;
}

extern "c" fn _Block_copy(block: ?*const anyopaque) ?objc.Object;
extern "c" fn _Block_release(block: objc.Object) void;

/// A page's reply handler, copied: answered once, then let go.
pub const Answer = struct {
    block: objc.Object,

    pub fn take(handler: *const anyopaque) ?Answer {
        return .{ .block = _Block_copy(handler) orelse return null };
    }

    /// `replyHandler(value, nil)`, with the reply as the page reads it.
    pub fn send(self: Answer, r: Reply) void {
        defer _Block_release(self.block);
        const pool = objc.Pool.push();
        defer pool.pop();
        var value: ?objc.Object = null;
        if (json.encode(std.heap.c_allocator, r)) |bytes| {
            defer std.heap.c_allocator.free(bytes);
            const d = req.nsData(bytes);
            value = objc.msg(?objc.Object, objc.class("NSJSONSerialization"), "JSONObjectWithData:options:error:", .{ d, @as(objc.NSUInteger, 0), @as(?*anyopaque, null) });
        } else |_| {}
        call(@ptrCast(self.block), .{ value, @as(?objc.Object, null) });
    }

    pub fn fail(self: Answer, err: []const u8, message: []const u8) void {
        self.send(reply.failure(err, message));
    }
};

/// Where a request came from, as WebKit knows it rather than as the page
/// says (`Caller`). Borrowed for the call.
pub const Caller = struct {
    scheme: []const u8,
    host: []const u8,
    /// 0: the scheme's own.
    port: i64 = 0,
    main_frame: bool,
    /// The host of the page the frame is in.
    page_host: ?[]const u8,
    window: ?objc.Object,
    /// The page's view, for a request that waits under its field.
    web: ?objc.Object,
};

const refused = "The operation either timed out or was not allowed.";
const newer = "A newer request took its place.";
const aborted = "The operation was aborted.";

/// A request from under a field, checked and waiting (`Waiting`).
const Waiting = struct {
    token: ?[]u8,
    rp: []u8,
    origin: []u8,
    challenge: []u8,
    /// Retained `ASPublicKeyCredentialClientData`.
    client: objc.Object,
    body: std.json.Parsed(Body),
    answer: Answer,
    offered: []Offered = &.{},

    fn deinit(w: Waiting, gpa: std.mem.Allocator) void {
        if (w.token) |t| gpa.free(t);
        gpa.free(w.rp);
        gpa.free(w.origin);
        gpa.free(w.challenge);
        objc.release(w.client);
        w.body.deinit();
        for (w.offered) |o| o.deinit(gpa);
        gpa.free(w.offered);
    }
};

/// A ceremony waiting on macOS's question (`ensure`'s closure).
pub const Pending = struct {
    /// Retained `NSArray` of requests.
    requests: objc.Object,
    token: ?[]u8,
    window: ?objc.Object,
    answer: Answer,
    prf_key: ?[65]u8,
    /// `perform`'s: called off by its page before it could start.
    check_withdrawn: bool,
};

pub const Changed = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, web: objc.Object) void };

/// `ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState`.
pub const Access = enum(objc.NSInteger) { authorized = 0, denied = 1, not_determined = 2 };

extern "c" fn NSClassFromString(name: objc.Object) ?objc.Object;

fn manager() ?objc.Object {
    const cls = NSClassFromString(objc.nsString("ASAuthorizationWebBrowserPublicKeyCredentialManager")) orelse return null;
    return objc.msg(objc.Object, objc.msg(objc.Object, cls, "new", .{}), "autorelease", .{});
}

/// Whether this Mac lets Kea use its passkeys at all (`access`).
pub fn access() Access {
    const pool = objc.Pool.push();
    defer pool.pop();
    const m = manager() orelse return .denied;
    return @enumFromInt(objc.msg(objc.NSInteger, m, "authorizationStateForPlatformCredentials", .{}));
}

pub const Passkeys = struct {
    kea: *Kea,
    gpa: std.mem.Allocator,
    /// The `KeaPasskeyRelay` every tab's controller gets, made on first use.
    relay_object: ?objc.Object = null,
    /// The `ASAuthorizationController`'s delegate and anchor provider.
    delegate: ?objc.Object = null,
    /// The one on screen (retained), and whom to answer when it ends.
    controller: ?objc.Object = null,
    /// The page's one-time key for this request's PRF results.
    prf_key: ?[65]u8 = null,
    token: ?[]u8 = null,
    answer: ?Answer = null,
    /// Retained window the sheet hangs on.
    anchor: ?objc.Object = null,
    withdrawn: ?[]u8 = null,
    /// One per page, by its view.
    conditional: std.AutoArrayHashMapUnmanaged(usize, Waiting) = .empty,
    /// Told when what a page is offered changes (`offeredChanged`).
    on_changed: ?Changed = null,
    /// Everyone waiting on macOS's question while it is on screen.
    asking: ?std.ArrayList(Pending) = null,

    pub fn init(kea: *Kea) Passkeys {
        return .{ .kea = kea, .gpa = kea.gpa };
    }

    pub fn deinit(p: *Passkeys) void {
        if (p.controller) |c| {
            // Its answer to the cancel comes later, to nobody.
            objc.msg(void, c, "setDelegate:", .{@as(?objc.Object, null)});
            objc.msg(void, c, "setPresentationContextProvider:", .{@as(?objc.Object, null)});
            objc.msg(void, c, "cancel", .{});
            objc.release(c);
        }
        if (p.answer) |a| a.fail("NotAllowedError", refused);
        p.answer = null;
        p.clear();
        for (p.conditional.values()) |w| {
            w.answer.fail("Wait", "");
            w.deinit(p.gpa);
        }
        p.conditional.deinit(p.gpa);
        if (p.asking) |*list| {
            for (list.items) |*pending| p.dropPending(pending, "NotAllowedError", refused);
            list.deinit(p.gpa);
        }
        p.asking = null;
        if (p.withdrawn) |w| p.gpa.free(w);
        p.withdrawn = null;
        if (p.relay_object) |r| {
            objc.setZig(r, null);
            objc.release(r);
        }
        if (p.delegate) |d| {
            objc.setZig(d, null);
            objc.release(d);
        }
    }

    fn testing(p: *const Passkeys) bool {
        return p.kea.opts.root != null;
    }

    /// `FormRelay.passkeysOffered`.
    fn offeredHere(p: *const Passkeys) bool {
        return p.kea.prefs.passkeys;
    }

    /// The handler to add with `addScriptMessageHandlerWithReply:contentWorld:name:`.
    pub fn relayObject(p: *Passkeys) objc.Object {
        if (p.relay_object == null) p.relay_object = relay.makeRelay(p);
        return p.relay_object.?;
    }

    fn changed(p: *Passkeys, web: objc.Object) void {
        if (p.on_changed) |c| c.func(c.ctx, web);
    }

    pub fn cancel(p: *Passkeys, token: ?[]const u8) void {
        const t = token orelse return;
        for (p.conditional.keys(), p.conditional.values()) |key, w| {
            const wt = w.token orelse continue;
            if (!std.mem.eql(u8, wt, t)) continue;
            const web: objc.Object = @ptrFromInt(key);
            const gone = p.conditional.fetchSwapRemove(key).?.value;
            gone.answer.fail("AbortError", aborted);
            gone.deinit(p.gpa);
            p.changed(web);
            return;
        }
        if (p.token) |mine| if (std.mem.eql(u8, mine, t)) {
            if (p.controller) |c| objc.msg(void, c, "cancel", .{});
            return;
        };
        const copy = p.gpa.dupe(u8, t) catch return;
        if (p.withdrawn) |w| p.gpa.free(w);
        p.withdrawn = copy;
    }

    // MARK: offered under the field

    /// The passkeys to offer under this page's fields; none unless it waits.
    pub fn offered(p: *Passkeys, web: ?objc.Object) []const Offered {
        const w = web orelse return &.{};
        if (!p.offeredHere()) return &.{};
        const waiting = p.conditional.getPtr(@intFromPtr(w)) orelse return &.{};
        if (!p.sameOrigin(w, waiting.origin)) return &.{};
        return waiting.offered;
    }

    /// The page is gone — a new document, or the tab — and its request with
    /// it, asked to keep waiting (`forget`).
    pub fn forget(p: *Passkeys, web: objc.Object) void {
        const gone = p.conditional.fetchSwapRemove(@intFromPtr(web)) orelse return;
        gone.value.answer.fail("Wait", "");
        gone.value.deinit(p.gpa);
    }

    /// "scheme://host[:port]" of the view's address (`origin(of:)`).
    fn sameOrigin(p: *Passkeys, web: objc.Object, origin: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(?objc.Object, web, "URL", .{}) orelse return false;
        const scheme = objc.fromNSString(objc.msg(?objc.Object, u, "scheme", .{}));
        const host = objc.fromNSString(objc.msg(?objc.Object, u, "host", .{}));
        if (scheme.len == 0 or host.len == 0) return false;
        const port: i64 = if (objc.msg(?objc.Object, u, "port", .{})) |n| objc.msg(objc.NSInteger, n, "integerValue", .{}) else 0;
        const mine = originText(p.gpa, scheme, host, port) catch return false;
        defer p.gpa.free(mine);
        return std.mem.eql(u8, mine, origin);
    }

    fn wait(p: *Passkeys, body: std.json.Parsed(Body), rp: []const u8, origin: []const u8, challenge: []const u8, client: objc.Object, web: objc.Object, answer: Answer) void {
        const key = @intFromPtr(web);
        // Asked again: the one before is over.
        if (p.conditional.fetchSwapRemove(key)) |old| {
            old.value.answer.fail("NotAllowedError", newer);
            old.value.deinit(p.gpa);
        }
        const gpa = p.gpa;
        const token = if (req.str(body.value, "token")) |t| gpa.dupe(u8, t) catch null else null;
        const waiting: Waiting = .{
            .token = token,
            .rp = gpa.dupe(u8, rp) catch return dropped(body, client, answer),
            .origin = gpa.dupe(u8, origin) catch return dropped(body, client, answer),
            .challenge = gpa.dupe(u8, challenge) catch return dropped(body, client, answer),
            .client = objc.retain(client),
            .body = body,
            .answer = answer,
        };
        p.conditional.put(gpa, key, waiting) catch {
            waiting.answer.fail("NotAllowedError", refused);
            return waiting.deinit(gpa);
        };
        // A test run never asks the Mac: one made up, for the site.
        if (p.testing()) {
            const probe = std.fmt.allocPrint(gpa, "probe@{s}", .{rp}) catch return;
            const one = Offered{ .id = gpa.dupe(u8, &reply.rehearsal_id) catch return gpa.free(probe), .name = probe, .provider = gpa.dupe(u8, "Test") catch null };
            const list = gpa.alloc(Offered, 1) catch return one.deinit(gpa);
            list[0] = one;
            return p.settle(key, token, list);
        }
        // Not asked here: a site loading is no time for macOS's question.
        if (access() != .authorized) return;
        relay.lookUp(p, key, token, rp, req.field(body.value, "allowCredentials"));
    }

    fn dropped(body: std.json.Parsed(Body), client: objc.Object, answer: Answer) void {
        _ = client;
        body.deinit();
        answer.fail("NotAllowedError", refused);
    }

    /// What the Mac holds, for the request that is still the page's (`settle`).
    /// Takes `list`.
    pub fn settle(p: *Passkeys, key: usize, token: ?[]const u8, list: []Offered) void {
        const waiting = p.conditional.getPtr(key) orelse return freeOffered(p.gpa, list);
        const same = if (waiting.token) |a| (if (token) |b| std.mem.eql(u8, a, b) else false) else token == null;
        if (!same) return freeOffered(p.gpa, list);
        freeOffered(p.gpa, waiting.offered);
        waiting.offered = list;
        p.changed(@ptrFromInt(key));
    }

    /// One of the passkeys under the field, picked: the Mac's sheet for it
    /// alone, and the page's waiting request answered with it (`sign`).
    pub fn sign(p: *Passkeys, web: objc.Object, id: []const u8) void {
        if (!p.offeredHere()) return;
        const key = @intFromPtr(web);
        const waiting = p.conditional.getPtr(key) orelse return;
        const has = for (waiting.offered) |o| {
            if (std.mem.eql(u8, o.id, id)) break true;
        } else false;
        if (!has or !p.sameOrigin(web, waiting.origin)) return;
        const window = objc.msg(?objc.Object, web, "window", .{});
        if (!p.testing() and !(appActive() and window != null and objc.msg(objc.BOOL, window.?, "isKeyWindow", .{}))) return;
        const w = p.conditional.fetchSwapRemove(key).?.value;
        defer w.deinit(p.gpa);
        p.changed(web);
        var arena = std.heap.ArenaAllocator.init(p.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (p.testing()) {
            var r = reply.rehearsal(a, "get", w.rp, w.origin, w.challenge) catch return w.answer.fail("NotAllowedError", refused);
            if (req.object(w.body.value, "prf") != null) {
                const first = reply.rehearsalFirst();
                r.prf = reply.prfReply(a, null, &first, null, reply.pageKey(a, req.str(w.body.value, "prfKey")));
            }
            return w.answer.send(r);
        }
        const pool = objc.Pool.push();
        defer pool.pop();
        const requests = req.picked(a, w.body.value, w.rp, w.client, id);
        p.ensure(.{
            .requests = objc.retain(requests),
            .token = if (w.token) |t| p.gpa.dupe(u8, t) catch null else null,
            .window = if (window) |x| objc.retain(x) else null,
            .answer = w.answer,
            .prf_key = reply.pageKey(a, req.str(w.body.value, "prfKey")),
            .check_withdrawn = false,
        });
    }

    // MARK: a request

    /// `perform(_:from:answer:)`. Takes `body`.
    pub fn perform(p: *Passkeys, body: std.json.Parsed(Body), caller: Caller, answer: Answer) void {
        var keep_body = false;
        defer if (!keep_body) body.deinit();
        const v = body.value;
        const kind = req.str(v, "kind") orelse "";
        const asks_under_field = std.mem.eql(u8, kind, "get") and req.boolean(v, "conditional") == true;
        // Switched off: what reaches here came through an extension's page script.
        if (!p.offeredHere()) {
            if (asks_under_field) return answer.fail("Wait", "");
            return answer.fail("NotAllowedError", refused);
        }
        var arena = std.heap.ArenaAllocator.init(p.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const scheme = std.ascii.allocLowerString(a, caller.scheme) catch return answer.fail("NotAllowedError", refused);
        const host = std.ascii.allocLowerString(a, caller.host) catch return answer.fail("NotAllowedError", refused);
        const local = std.mem.eql(u8, host, "localhost") or std.mem.endsWith(u8, host, ".localhost") or
            std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1");
        if (host.len == 0 or !(std.mem.eql(u8, scheme, "https") or (std.mem.eql(u8, scheme, "http") and local)))
            return answer.fail("NotAllowedError", "Passkeys need a secure page.");
        // From under the field: its own page only, with a view to hang on.
        if (asks_under_field and (!caller.main_frame or caller.web == null)) return answer.fail("Wait", "");
        // The page in front of you only. A test run is always behind.
        const focused = if (caller.window) |w| appActive() and objc.msg(objc.BOOL, w, "isKeyWindow", .{}) else false;
        if (!asks_under_field and !p.testing() and !focused) return answer.fail("NotAllowedError", "The document is not focused.");
        const same_site = if (caller.page_host) |ph| std.ascii.eqlIgnoreCase(ph, host) else false;
        if (!caller.main_frame and !same_site) return answer.fail("NotAllowedError", "Passkeys can't be asked for from another site's frame.");
        const named = if (std.mem.eql(u8, kind, "create")) (if (req.object(v, "rp")) |rp_obj| req.str(rp_obj, "id") else null) else req.str(v, "rpId");
        const rp = std.ascii.allocLowerString(a, if (named) |n| (if (n.len == 0) host else n) else host) catch return answer.fail("NotAllowedError", refused);
        if (!reply.fits(rp, host, registrable.publicSuffix()))
            return answer.fail("SecurityError", "The relying party ID is not a registrable domain suffix of, nor equal to the current domain.");
        const challenge = reply.data(a, req.str(v, "challenge") orelse "") orelse &.{};
        if (challenge.len == 0) return answer.fail("TypeError", "A challenge is required.");
        const origin = originText(a, scheme, host, caller.port) catch return answer.fail("NotAllowedError", refused);
        const pool = objc.Pool.push();
        defer pool.pop();
        const client = req.clientData(challenge, origin);
        defer objc.release(client);

        if (asks_under_field) if (caller.web) |web| {
            keep_body = true;
            return p.wait(body, rp, origin, challenge, client, web, answer);
        };
        // A request of the page's own, with a sheet: the one under the field is over.
        if (caller.web) |web| if (caller.main_frame) if (p.conditional.fetchSwapRemove(@intFromPtr(web))) |old| {
            old.value.answer.fail("NotAllowedError", newer);
            old.value.deinit(p.gpa);
            p.changed(web);
        };
        const requests: objc.Object = if (std.mem.eql(u8, kind, "get"))
            req.assertion(a, v, rp, client) catch return answer.fail("NotAllowedError", refused)
        else if (std.mem.eql(u8, kind, "create"))
            (req.registration(a, v, rp, client) catch return answer.fail("NotAllowedError", refused)) orelse
                return answer.fail("TypeError", "The request names no user, or one too long.")
        else
            return answer.fail("NotSupportedError", "Not a passkey request.");
        if (objc.msg(objc.NSUInteger, requests, "count", .{}) == 0)
            return answer.fail("NotSupportedError", "No authenticator here can make that kind of key.");
        std.log.info("passkeys: {s} for {s} from {s}", .{ kind, rp, origin });
        // A test run never shows the sheet: a credential made up on the spot.
        if (p.testing()) {
            var r = reply.rehearsal(a, kind, rp, origin, challenge) catch return answer.fail("NotAllowedError", refused);
            if (req.object(v, "prf") != null) {
                const first = reply.rehearsalFirst();
                r.prf = reply.prfReply(a, if (std.mem.eql(u8, kind, "create")) true else null, &first, null, reply.pageKey(a, req.str(v, "prfKey")));
            }
            return answer.send(r);
        }
        p.ensure(.{
            .requests = objc.retain(requests),
            .token = if (req.str(v, "token")) |t| p.gpa.dupe(u8, t) catch null else null,
            .window = if (caller.window) |w| objc.retain(w) else null,
            .answer = answer,
            .prf_key = reply.pageKey(a, req.str(v, "prfKey")),
            .check_withdrawn = true,
        });
    }

    /// Asked before the first ceremony, then never again (`ensure`).
    fn ensure(p: *Passkeys, pending: Pending) void {
        if (!p.kea.prefs.passkeys_possible or access() != .not_determined) return p.begin(pending);
        if (p.asking) |*list| {
            list.append(p.gpa, pending) catch {
                var x = pending;
                p.dropPending(&x, "NotAllowedError", refused);
            };
            return;
        }
        p.asking = .empty;
        p.asking.?.append(p.gpa, pending) catch {
            var x = pending;
            p.dropPending(&x, "NotAllowedError", refused);
        };
        relay.requestAccess(p);
    }

    /// macOS's question answered: everyone waiting goes ahead.
    pub fn accessAnswered(p: *Passkeys) void {
        var list = p.asking orelse return;
        p.asking = null;
        defer list.deinit(p.gpa);
        for (list.items) |pending| p.begin(pending);
    }

    fn dropPending(p: *Passkeys, pending: *Pending, err: []const u8, message: []const u8) void {
        objc.release(pending.requests);
        if (pending.window) |w| objc.release(w);
        if (pending.token) |t| p.gpa.free(t);
        pending.answer.fail(err, message);
    }

    fn begin(p: *Passkeys, pending: Pending) void {
        var x = pending;
        if (x.check_withdrawn) if (x.token) |t| if (p.withdrawn) |w| if (std.mem.eql(u8, t, w)) {
            p.gpa.free(w);
            p.withdrawn = null;
            return p.dropPending(&x, "AbortError", aborted);
        };
        if (p.controller) |running| {
            const previous = p.answer;
            p.answer = null;
            p.clear();
            objc.msg(void, running, "cancel", .{});
            objc.release(running);
            if (previous) |prev| prev.fail("NotAllowedError", newer);
        }
        defer objc.release(x.requests);
        const controller = objc.msg(objc.Object, objc.alloc("ASAuthorizationController"), "initWithAuthorizationRequests:", .{x.requests});
        const d = p.delegate orelse blk: {
            p.delegate = relay.makeDelegate(p);
            break :blk p.delegate.?;
        };
        objc.msg(void, controller, "setDelegate:", .{d});
        objc.msg(void, controller, "setPresentationContextProvider:", .{d});
        p.controller = controller;
        p.token = x.token;
        p.answer = x.answer;
        p.anchor = x.window;
        p.prf_key = x.prf_key;
        objc.msg(void, controller, "performRequests", .{});
    }

    /// The ceremony's answer for the page, and the state let go (`finish`).
    pub fn finish(p: *Passkeys, r: Reply) void {
        const answer = p.answer;
        p.answer = null;
        if (p.controller) |c| objc.release(c);
        p.controller = null;
        p.clear();
        if (answer) |a| a.send(r);
    }

    fn clear(p: *Passkeys) void {
        p.controller = null;
        if (p.token) |t| p.gpa.free(t);
        p.token = null;
        if (p.anchor) |w| objc.release(w);
        p.anchor = null;
        p.prf_key = null;
    }
};

fn freeOffered(gpa: std.mem.Allocator, list: []Offered) void {
    for (list) |o| o.deinit(gpa);
    gpa.free(list);
}

fn appActive() bool {
    const app = objc.msg(?objc.Object, objc.class("NSApplication"), "sharedApplication", .{}) orelse return false;
    return objc.msg(objc.BOOL, app, "isActive", .{});
}

/// "scheme://host[:port]", an IPv6 host bracketed, on `a`.
pub fn originText(a: std.mem.Allocator, scheme: []const u8, host: []const u8, port: i64) ![]u8 {
    const bracket = std.mem.indexOfScalar(u8, host, ':') != null;
    const lower_scheme = try std.ascii.allocLowerString(a, scheme);
    defer a.free(lower_scheme);
    const lower_host = try std.ascii.allocLowerString(a, host);
    defer a.free(lower_host);
    if (port == 0) return std.fmt.allocPrint(a, "{s}://{s}{s}{s}", .{ lower_scheme, if (bracket) "[" else "", lower_host, if (bracket) "]" else "" });
    return std.fmt.allocPrint(a, "{s}://{s}{s}{s}:{d}", .{ lower_scheme, if (bracket) "[" else "", lower_host, if (bracket) "]" else "", port });
}
