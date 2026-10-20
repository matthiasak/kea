//! The Objective-C side of passkeys: `PasskeyRelay` (Passkeys.swift 818-844),
//! the `WKScriptMessageHandlerWithReply` every tab's controller gets under
//! `keaPasskeys`; the `ASAuthorizationController` delegate and anchor
//! provider (689-737); and the two questions put to
//! `ASAuthorizationWebBrowserPublicKeyCredentialManager`. Main thread.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const call = @import("../web/dialogs.zig").call;
const passkeys = @import("passkeys.zig");
const Passkeys = passkeys.Passkeys;
const reply = @import("passkeys_reply.zig");
const req = @import("passkeys_requests.zig");

extern "c" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
extern "c" const ASAuthorizationErrorDomain: objc.Object;

pub fn makeRelay(p: *Passkeys) objc.Object {
    const cls = objc.defineClass(.{
        .name = "KeaPasskeyRelay",
        .protocols = &.{"WKScriptMessageHandlerWithReply"},
        .methods = &.{.{ .name = "userContentController:didReceiveScriptMessage:replyHandler:", .imp = @ptrCast(&received), .types = "v@:@@@?" }},
    });
    const o = objc.msg(objc.Object, cls, "new", .{});
    objc.setZig(o, p);
    return o;
}

pub fn makeDelegate(p: *Passkeys) objc.Object {
    const cls = objc.defineClass(.{
        .name = "KeaPasskeyDelegate",
        .protocols = &.{ "ASAuthorizationControllerDelegate", "ASAuthorizationControllerPresentationContextProviding" },
        .methods = &.{
            .{ .name = "authorizationController:didCompleteWithAuthorization:", .imp = @ptrCast(&completed), .types = "v@:@@" },
            .{ .name = "authorizationController:didCompleteWithError:", .imp = @ptrCast(&failed), .types = "v@:@@" },
            .{ .name = "presentationAnchorForAuthorizationController:", .imp = @ptrCast(&anchor), .types = "@@:@" },
        },
    });
    const o = objc.msg(objc.Object, cls, "new", .{});
    objc.setZig(o, p);
    return o;
}

fn isKind(o: objc.Object, comptime cls: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class(cls)});
}

fn answerNow(handler: *const anyopaque, value: ?objc.Object, err: ?[]const u8) void {
    call(handler, .{ value, if (err) |e| @as(?objc.Object, objc.nsString(e)) else null });
}

/// `userContentController(_:didReceive:replyHandler:)`.
fn received(self: objc.Object, _: objc.SEL, _: objc.Object, message: objc.Object, handler: *const anyopaque) callconv(.c) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const p = objc.getZig(Passkeys, self) orelse return answerNow(handler, null, "Not a request");
    const body = objc.msg(?objc.Object, message, "body", .{}) orelse return answerNow(handler, null, "Not a request");
    if (!isKind(body, "NSDictionary")) return answerNow(handler, null, "Not a request");
    const kind = objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString("kind")});
    if (kind != null and isKind(kind.?, "NSString") and std.mem.eql(u8, objc.fromNSString(kind), "cancel")) {
        const token = objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString("token")});
        p.cancel(if (token) |t| (if (isKind(t, "NSString")) objc.fromNSString(t) else null) else null);
        return answerNow(handler, objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES}), null);
    }
    const parsed = decodeBody(p.gpa, body) orelse return answerNow(handler, null, "Not a request");
    const answer = passkeys.Answer.take(handler) orelse return parsed.deinit();
    const frame = objc.msg(objc.Object, message, "frameInfo", .{});
    const origin = objc.msg(objc.Object, frame, "securityOrigin", .{});
    const web = objc.msg(?objc.Object, message, "webView", .{});
    const page_url = if (web) |w| objc.msg(?objc.Object, w, "URL", .{}) else null;
    p.perform(parsed, .{
        .scheme = objc.fromNSString(objc.msg(?objc.Object, origin, "protocol", .{})),
        .host = objc.fromNSString(objc.msg(?objc.Object, origin, "host", .{})),
        .port = objc.msg(objc.NSInteger, origin, "port", .{}),
        .main_frame = objc.msg(objc.BOOL, frame, "isMainFrame", .{}),
        .page_host = if (page_url) |u| (if (objc.msg(?objc.Object, u, "host", .{})) |h| objc.fromNSString(h) else null) else null,
        .window = if (web) |w| objc.msg(?objc.Object, w, "window", .{}) else null,
        .web = web,
    }, answer);
}

/// The message body as JSON values (`[String: Any]`).
fn decodeBody(gpa: std.mem.Allocator, body: objc.Object) ?std.json.Parsed(std.json.Value) {
    const cls = objc.class("NSJSONSerialization");
    if (!objc.msg(objc.BOOL, cls, "isValidJSONObject:", .{body})) return null;
    const d = objc.msg(?objc.Object, cls, "dataWithJSONObject:options:error:", .{ body, @as(objc.NSUInteger, 0), @as(?*anyopaque, null) }) orelse return null;
    return json.decode(std.json.Value, gpa, bytesOf(d)) catch null;
}

fn bytesOf(d: ?objc.Object) []const u8 {
    const data = d orelse return &.{};
    const n = objc.msg(objc.NSUInteger, data, "length", .{});
    if (n == 0) return &.{};
    const ptr = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return &.{};
    return ptr[0..n];
}

fn conforms(o: objc.Object, comptime protocol: [:0]const u8) bool {
    const proto = objc_getProtocol(protocol) orelse return false;
    return objc.msg(objc.BOOL, o, "conformsToProtocol:", .{proto});
}

fn platformAttachment(o: objc.Object) []const u8 {
    if (!objc.msg(objc.BOOL, o, "respondsToSelector:", .{objc.sel("attachment")})) return "cross-platform";
    return if (objc.msg(objc.NSInteger, o, "attachment", .{}) == 0) "platform" else "cross-platform";
}

/// The PRF output of a platform credential, if this Mac gives one.
fn prfOutput(o: objc.Object) ?objc.Object {
    if (!req.prfAvailable() or !objc.msg(objc.BOOL, o, "respondsToSelector:", .{objc.sel("prf")})) return null;
    return objc.msg(?objc.Object, o, "prf", .{});
}

fn optionalBytes(o: objc.Object, comptime key: [:0]const u8) ?[]const u8 {
    const d = objc.msg(?objc.Object, o, key, .{}) orelse return null;
    return bytesOf(d);
}

fn completed(self: objc.Object, _: objc.SEL, controller: objc.Object, authorization: objc.Object) callconv(.c) void {
    const p = objc.getZig(Passkeys, self) orelse return;
    if (p.controller != controller) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    var arena = std.heap.ArenaAllocator.init(p.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const credential = objc.msg(objc.Object, authorization, "credential", .{});
    const id = optionalBytes(credential, "credentialID") orelse &.{};
    const client = optionalBytes(credential, "rawClientDataJSON") orelse &.{};
    if (conforms(credential, "ASAuthorizationPublicKeyCredentialAssertion")) {
        const platform = isKind(credential, "ASAuthorizationPlatformPublicKeyCredentialAssertion");
        var r = reply.assertionReply(a, id, client, optionalBytes(credential, "rawAuthenticatorData") orelse &.{}, optionalBytes(credential, "signature") orelse &.{}, optionalBytes(credential, "userID") orelse &.{}, if (platform) platformAttachment(credential) else "cross-platform") catch
            return p.finish(reply.failure("NotAllowedError", "The operation either timed out or was not allowed."));
        if (platform) if (prfOutput(credential)) |prf| {
            r.prf = reply.prfReply(a, null, optionalBytes(prf, "first"), optionalBytes(prf, "second"), p.prf_key);
        };
        return p.finish(r);
    }
    if (conforms(credential, "ASAuthorizationPublicKeyCredentialRegistration")) {
        const platform = isKind(credential, "ASAuthorizationPlatformPublicKeyCredentialRegistration");
        const transports: []const []const u8 = if (platform) &.{ "hybrid", "internal" } else &.{"usb"};
        var r = reply.registrationReply(a, id, client, optionalBytes(credential, "rawAttestationObject") orelse &.{}, transports, if (platform) platformAttachment(credential) else "cross-platform") catch
            return p.finish(reply.failure("NotAllowedError", "The operation either timed out or was not allowed."));
        if (platform) if (prfOutput(credential)) |prf| {
            r.prf = reply.prfReply(a, objc.msg(objc.BOOL, prf, "isSupported", .{}), optionalBytes(prf, "first"), optionalBytes(prf, "second"), p.prf_key);
        };
        return p.finish(r);
    }
    p.finish(reply.failure("NotAllowedError", "The authenticator answered with something else."));
}

fn failed(self: objc.Object, _: objc.SEL, controller: objc.Object, err: objc.Object) callconv(.c) void {
    const p = objc.getZig(Passkeys, self) orelse return;
    if (p.controller != controller) return;
    const domain = objc.msg(objc.Object, err, "domain", .{});
    // A credential it already holds is what a site is told; anything else
    // a site may not tell apart.
    if (objc.msg(objc.BOOL, domain, "isEqualToString:", .{ASAuthorizationErrorDomain}) and objc.msg(objc.NSInteger, err, "code", .{}) == 1006)
        return p.finish(reply.failure("InvalidStateError", "The authenticator already holds a credential for this account."));
    p.finish(reply.failure("NotAllowedError", "The operation either timed out or was not allowed."));
}

fn anchor(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.Object {
    if (objc.getZig(Passkeys, self)) |p| if (p.anchor) |w| return w;
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    if (objc.msg(?objc.Object, app, "keyWindow", .{})) |w| return w;
    if (objc.msg(?objc.Object, objc.msg(objc.Object, app, "windows", .{}), "firstObject", .{})) |w| return w;
    return objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSWindow"), "new", .{}), "autorelease", .{});
}

// MARK: the Mac's questions

const AccessBlock = objc.Block(Passkeys, &.{objc.NSInteger});

/// `requestAuthorizationForPublicKeyCredentials`, answered on the main thread.
// ponytail: the Passkeys must outlive macOS's answer (it lives as long as the app).
pub fn requestAccess(p: *Passkeys) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const m = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("ASAuthorizationWebBrowserPublicKeyCredentialManager"), "new", .{}), "autorelease", .{});
    var block = AccessBlock.init(p, accessReplied);
    objc.msg(void, m, "requestAuthorizationForPublicKeyCredentials:", .{@as(*anyopaque, @ptrCast(&block))});
}

fn accessReplied(p: *Passkeys, _: objc.NSInteger) void {
    objc.dispatchMain(p, accessOnMain);
}

fn accessOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const p: *Passkeys = @ptrCast(@alignCast(ctx.?));
    p.accessAnswered();
}

const Looking = struct {
    p: *Passkeys,
    key: usize,
    token: ?[]u8,
    allowed: [][]u8,
    found: ?objc.Object = null,

    fn deinit(l: *Looking) void {
        const gpa = l.p.gpa;
        if (l.token) |t| gpa.free(t);
        for (l.allowed) |x| gpa.free(x);
        gpa.free(l.allowed);
        if (l.found) |f| objc.release(f);
        std.heap.c_allocator.destroy(l);
    }
};
const FoundBlock = objc.Block(Looking, &.{?objc.Object});

/// Which passkeys the Mac holds for `rp`, as `settle` takes them: the
/// allowed ones (all when none named), 8 at most.
// ponytail: the Passkeys must outlive the answer (it lives as long as the app).
pub fn lookUp(p: *Passkeys, key: usize, token: ?[]const u8, rp: []const u8, allow: ?std.json.Value) void {
    const gpa = p.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const pool = objc.Pool.push();
    defer pool.pop();
    const listed = req.descriptors(arena.allocator(), allow) catch return;
    const l = std.heap.c_allocator.create(Looking) catch return;
    l.* = .{ .p = p, .key = key, .token = null, .allowed = gpa.alloc([]u8, listed.len) catch return std.heap.c_allocator.destroy(l) };
    var made: usize = 0;
    for (listed) |d| {
        l.allowed[made] = gpa.dupe(u8, d.id) catch break;
        made += 1;
    }
    l.allowed = l.allowed[0..made];
    l.token = if (token) |t| gpa.dupe(u8, t) catch null else null;
    const m = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("ASAuthorizationWebBrowserPublicKeyCredentialManager"), "new", .{}), "autorelease", .{});
    var block = FoundBlock.init(l, found);
    objc.msg(void, m, "platformCredentialsForRelyingParty:completionHandler:", .{ objc.nsString(rp), @as(*anyopaque, @ptrCast(&block)) });
}

fn found(l: *Looking, list: ?objc.Object) void {
    l.found = if (list) |x| objc.retain(x) else null;
    objc.dispatchMain(l, foundOnMain);
}

fn foundOnMain(ctx: ?*anyopaque) callconv(.c) void {
    const l: *Looking = @ptrCast(@alignCast(ctx.?));
    defer l.deinit();
    const gpa = l.p.gpa;
    const pool = objc.Pool.push();
    defer pool.pop();
    var out: std.ArrayList(passkeys.Offered) = .empty;
    if (l.found) |list| for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
        if (out.items.len == 8) break;
        const c = objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const id = optionalBytes(c, "credentialID") orelse continue;
        const allowed = l.allowed.len == 0 or for (l.allowed) |x| {
            if (std.mem.eql(u8, x, id)) break true;
        } else false;
        if (!allowed) continue;
        const raw_name = objc.fromNSString(objc.msg(?objc.Object, c, "name", .{}));
        const provider = if (objc.msg(objc.BOOL, c, "respondsToSelector:", .{objc.sel("providerName")})) objc.fromNSString(objc.msg(?objc.Object, c, "providerName", .{})) else "";
        const offered = makeOffered(gpa, id, if (raw_name.len == 0) "Passkey" else prefixChars(raw_name, 200), provider) catch break;
        out.append(gpa, offered) catch {
            offered.deinit(gpa);
            break;
        };
    };
    const list = out.toOwnedSlice(gpa) catch {
        for (out.items) |o| o.deinit(gpa);
        out.deinit(gpa);
        return;
    };
    l.p.settle(l.key, l.token, list);
}

fn makeOffered(gpa: std.mem.Allocator, id: []const u8, name: []const u8, provider: []const u8) !passkeys.Offered {
    const o: passkeys.Offered = .{ .id = try gpa.dupe(u8, id), .name = undefined };
    errdefer gpa.free(o.id);
    const n = try gpa.dupe(u8, name);
    errdefer gpa.free(n);
    return .{ .id = o.id, .name = n, .provider = if (provider.len == 0) null else try gpa.dupe(u8, provider) };
}

/// The first `n` code points (Swift's `prefix(n)` on a String's Characters).
fn prefixChars(s: []const u8, n: usize) []const u8 {
    var it = (std.unicode.Utf8View.init(s) catch return s).iterator();
    var count: usize = 0;
    while (count < n) : (count += 1) _ = it.nextCodepointSlice() orelse return s;
    return s[0..it.i];
}
