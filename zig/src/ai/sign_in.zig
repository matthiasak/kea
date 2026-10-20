//! Signing in with OpenRouter (AISignIn.swift): the one provider that lets
//! another app use your own account, through OAuth with PKCE and no secret
//! of ours. You sign in on openrouter.ai, in a tab, and say yes; it sends the
//! tab back to our callback address with a one-time code, traded here for a
//! key of your own and kept like one you pasted.
//!
//! The callback is never loaded: it is taken as the tab is about to go
//! there — in the tab opened for the flow, while the flow waits, coming from
//! openrouter.ai, for ten minutes at most. The verifier lives only in memory.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("../data/json.zig");
const url = @import("../data/url.zig");
const Tab = @import("../web/tab.zig").Tab;
const currentUrl = @import("../web/tab.zig").currentUrl;
const Browser = @import("../model/browser.zig").Browser;
const ai = @import("ai.zig");
const more = @import("client_more.zig");
const app_name = "KeaZig";

pub const callback = "http://localhost:3000/kea/ai/callback";
const b64 = std.base64.url_safe_no_pad.Encoder;

/// The base64url text of 32 bytes (`Passkeys.text`): 43 characters.
pub fn verifierFor(bytes: [32]u8, buf: *[43]u8) []const u8 {
    return b64.encode(buf, &bytes);
}

/// `S256`: the verifier's SHA-256, as base64url.
pub fn challengeFor(verifier: []const u8, buf: *[43]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return b64.encode(buf, &digest);
}

/// One sign-in under way (`AISignIn.flow`).
pub const Flow = struct {
    tab: u64,
    verifier: [43]u8,
    started: f64,
};

/// Said when a sign-in has ended: whether a key is now kept, and what went
/// wrong if not (borrowed for the call).
pub const Ended = struct { ctx: *anyopaque, func: *const fn (*anyopaque, bool, ?[]const u8) void };

pub const State = struct {
    flow: ?Flow = null,
    ended: ?Ended = null,
};

/// openrouter.ai itself, where you sign in — in a test run, the stand-in. On `a`.
pub fn site(m: *const ai.Ai, a: std.mem.Allocator) ![]u8 {
    if (m.testing) if (m.mock) |mock| return std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, mock, "/"), "/openRouter-site/" });
    return a.dupe(u8, "https://openrouter.ai/");
}

/// Whether one is under way, for Settings.
pub fn waiting(m: *const ai.Ai) bool {
    const f = m.sign_in.flow orelse return false;
    return json.now() - f.started < 600;
}

pub fn start(m: *ai.Ai, b: *Browser) void {
    var bytes: [32]u8 = undefined;
    std.c.arc4random_buf(&bytes, bytes.len);
    var vb: [43]u8 = undefined;
    var cb: [43]u8 = undefined;
    const verifier = verifierFor(bytes, &vb);
    const challenge = challengeFor(verifier, &cb);
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const from = site(m, a) catch return;
    const address = std.fmt.allocPrint(a, "{s}auth?callback_url={s}&code_challenge={s}&code_challenge_method=S256&key_label={s}", .{ from, callback, challenge, app_name }) catch return;
    const t = b.open(address, .{ .foreground = true });
    m.sign_in.flow = .{ .tab = t.id, .verifier = vb, .started = json.now() };
}

/// The callback, about to load in `t`: taken — true — when it is the
/// flow's. The tab is closed once the key is kept.
pub fn intercept(m: *ai.Ai, address: []const u8, main_frame: bool, t: ?*Tab, b: *Browser) bool {
    const p = url.Parts.parse(address) orelse return false;
    if (!p.schemeIs("http") or !std.ascii.eqlIgnoreCase(p.hostName() orelse "", "localhost")) return false;
    if (!std.mem.eql(u8, p.port orelse "", "3000") or !std.mem.eql(u8, p.path, "/kea/ai/callback") or !main_frame) return false;
    const flow = m.sign_in.flow orelse return false;
    const tab = t orelse return false;
    if (tab.id != flow.tab) return false;
    m.sign_in.flow = null;
    var arena: std.heap.ArenaAllocator = .init(m.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const code = queryItem(a, p.query orelse "", "code") orelse "";
    // Sent here by openrouter.ai, and not by a page the tab wandered to.
    const pool = objc.Pool.push();
    defer pool.pop();
    const there: ?[]const u8 = if (tab.web) |wv| currentUrl(wv) orelse tab.address else tab.address;
    const from_host = if (there) |s| if (url.Parts.parse(s)) |q| q.hostName() orelse "" else "" else "";
    const site_address = site(m, a) catch return true;
    const site_host = if (url.Parts.parse(site_address)) |q| q.hostName() orelse "" else "";
    if (json.now() - flow.started >= 600) return finish(m, false, "The sign-in took too long — try again.", tab, b);
    if (from_host.len == 0 or !std.ascii.eqlIgnoreCase(from_host, site_host) or code.len == 0 or (std.unicode.utf8CountCodepoints(code) catch 1024) >= 1024)
        return finish(m, false, "The sign-in didn't come back from OpenRouter.", tab, b);
    const trade = m.gpa.create(Trade) catch return finish(m, false, null, tab, b);
    trade.* = .{ .m = m, .serial = tab.serial };
    more.exchange(m, code, &flow.verifier, trade, traded);
    return true;
}

const Trade = struct { m: *ai.Ai, serial: u64 };

fn traded(raw: *anyopaque, got: more.Exchanged) void {
    const trade: *Trade = @ptrCast(@alignCast(raw));
    const m = trade.m;
    const serial = trade.serial;
    m.gpa.destroy(trade);
    const tab = Tab.alive(serial);
    const b = if (tab) |t| t.browser else null;
    switch (got) {
        .key => |key| switch (m.keys.save(m, key, ai.openRouter)) {
            .kept => finishIn(m, true, null, tab, b),
            .failed => finishIn(m, false, "The keychain refused the key.", tab, b),
        },
        .failed => |f| {
            const why = f.describe(m.gpa) catch null;
            defer if (why) |w| m.gpa.free(w);
            finishIn(m, false, why, tab, b);
        },
    }
}

fn finish(m: *ai.Ai, kept: bool, why: ?[]const u8, t: *Tab, b: *Browser) bool {
    finishIn(m, kept, why, t, b);
    return true;
}

fn finishIn(m: *ai.Ai, kept: bool, why: ?[]const u8, t: ?*Tab, b: ?*Browser) void {
    if (b) |browser| {
        if (kept) if (t) |tab| browser.close(tab);
        browser.announce(if (kept) "Signed in with OpenRouter" else why orelse "The sign-in didn't work");
    }
    if (m.sign_in.ended) |e| e.func(e.ctx, kept, why);
}

/// A query item's value, percent-decoded as `URLComponents.queryItems` does; on `a`.
pub fn queryItem(a: std.mem.Allocator, query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |item| {
        const eq = std.mem.indexOfScalar(u8, item, '=');
        const key = if (eq) |i| item[0..i] else item;
        if (!std.mem.eql(u8, key, name)) continue;
        const raw = if (eq) |i| item[i + 1 ..] else "";
        const out = a.dupe(u8, raw) catch return null;
        return std.Uri.percentDecodeInPlace(out);
    }
    return null;
}

test "PKCE challenge for RFC 7636 appendix B" {
    const bytes = [32]u8{ 116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186, 22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121 };
    var vb: [43]u8 = undefined;
    var cb: [43]u8 = undefined;
    const verifier = verifierFor(bytes, &vb);
    try std.testing.expectEqualStrings("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", verifier);
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challengeFor(verifier, &cb));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a b/c", queryItem(arena.allocator(), "x=1&code=a%20b%2Fc", "code").?);
    try std.testing.expect(queryItem(arena.allocator(), "x=1", "code") == null);
}
