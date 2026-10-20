//! What a page says about its sign-ins (Forms.swift `FormRelay`), the sign-in
//! a tab has just sent (Tab.swift 848-948), and the offer to keep it
//! (Browser.swift 624-697 and `onCredentials`, 3810-3832). The tab keeps a
//! `SignIn`; the browser keeps `?Offer`.
const std = @import("std");
const objc = @import("nanoui").objc;
const url = @import("../data/url.zig");
const vault = @import("vault.zig");
const Vault = vault.Vault;
const Login = vault.Login;
const escapeInto = @import("../web/tab_scripts.zig").escapeInto;

/// The handler's name, in Kea's world (`FormRelay.name`).
pub const name = "keaForms";
/// `FormRelay.script`: document end, main frame only, Kea's world.
pub const script = @embedFile("js/forms.js");
/// `FormRelay.withoutPasskeys`: document start, every frame, the page's
/// world, when passkeys aren't offered (`passkeys` off).
pub const without_passkeys = @embedFile("js/without_passkeys.js");
/// Asked after a password went out (`settleSignIn`), in Kea's world.
pub const has_password_script = "!!(window.__keaForms && window.__keaForms.hasPassword())";

pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

pub const Focus = struct {
    typing: bool,
    /// The sign-in box the caret is in, in CSS pixels; null when it left.
    rect: ?Rect,
    /// A box that goes with a password, not one for passkeys alone.
    passwords: bool = true,
    /// A first step's name box: a pick puts in the name alone.
    name: bool = false,
};

/// What `keaForms` said. Strings are borrowed from the message body.
pub const Message = union(enum) {
    form,
    submit: struct { user: []const u8, password: []const u8 },
    name: []const u8,
    settled,
    focus: Focus,
    fullscreen: bool,
};

fn value(body: objc.Object, key: []const u8) ?objc.Object {
    return objc.msg(?objc.Object, body, "objectForKey:", .{objc.nsString(key)});
}

fn isKind(o: objc.Object, comptime cls: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class(cls)});
}

fn text(body: objc.Object, key: []const u8) []const u8 {
    const v = value(body, key) orelse return "";
    return if (isKind(v, "NSString")) objc.fromNSString(v) else "";
}

fn flag(body: objc.Object, key: []const u8, default: bool) bool {
    const v = value(body, key) orelse return default;
    return if (isKind(v, "NSNumber")) objc.msg(objc.BOOL, v, "boolValue", .{}) else default;
}

fn number(o: objc.Object, key: []const u8) ?f64 {
    const v = value(o, key) orelse return null;
    return if (isKind(v, "NSNumber")) objc.msg(f64, v, "doubleValue", .{}) else null;
}

/// `userContentController:didReceiveScriptMessage:`'s reading of the body;
/// null for anything that isn't one of Kea's.
pub fn message(body: objc.Object) ?Message {
    if (!isKind(body, "NSDictionary")) return null;
    const kind = text(body, "kind");
    if (std.mem.eql(u8, kind, "form")) return .form;
    if (std.mem.eql(u8, kind, "submit")) return .{ .submit = .{ .user = text(body, "user"), .password = text(body, "password") } };
    if (std.mem.eql(u8, kind, "name")) return .{ .name = text(body, "user") };
    if (std.mem.eql(u8, kind, "settled")) return .settled;
    if (std.mem.eql(u8, kind, "fullscreen")) return .{ .fullscreen = flag(body, "on", false) };
    if (!std.mem.eql(u8, kind, "focus")) return null;
    var rect: ?Rect = null;
    if (value(body, "rect")) |r| if (isKind(r, "NSDictionary")) {
        if (number(r, "x")) |x| if (number(r, "y")) |y| if (number(r, "w")) |w| if (number(r, "h")) |h| {
            rect = .{ .x = x, .y = y, .w = w, .h = h };
        };
    };
    return .{ .focus = .{
        .typing = flag(body, "typing", false),
        .rect = rect,
        .passwords = flag(body, "passwords", true),
        .name = flag(body, "name", false),
    } };
}

/// `fieldFocused`: the box in the web view's points (page zoom applied).
pub fn spot(rect: Rect, zoom: f64) Rect {
    return .{ .x = rect.x * zoom, .y = rect.y * zoom, .w = rect.w * zoom, .h = rect.h * zoom };
}

/// `fill(user:password:)`'s script, for Kea's world; the caller frees it.
pub fn fillScript(gpa: std.mem.Allocator, user: []const u8, password: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "window.__keaForms && window.__keaForms.fill(`");
    try escapeInto(&out, gpa, user);
    try out.appendSlice(gpa, "`, `");
    try escapeInto(&out, gpa, password);
    try out.appendSlice(gpa, "`)");
    return out.toOwnedSlice(gpa);
}

/// `fillName(_:)`'s script; the caller frees it.
pub fn nameScript(gpa: std.mem.Allocator, user: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "window.__keaForms && window.__keaForms.name(`");
    try escapeInto(&out, gpa, user);
    try out.appendSlice(gpa, "`)");
    return out.toOwnedSlice(gpa);
}

/// The page address's host, lowercased; null without one.
fn pageHost(gpa: std.mem.Allocator, page: ?[]const u8) ?[]u8 {
    const h = (url.Parts.parse(page orelse return null) orelse return null).hostName() orelse return null;
    return url.lower(gpa, h) catch null;
}

/// A tab's sign-in in flight, in memory only: never written down.
pub const SignIn = struct {
    /// The name a first step was sent with, for its site, a few minutes.
    named: ?Named = null,
    /// A name and password the page just sent: held, not yet offered.
    sent: ?Sent = null,

    pub const Named = struct { site: []u8, user: []u8, at: f64 };
    pub const Sent = struct {
        /// The site it was sent from, without www.
        host: []u8,
        user: []u8,
        password: []u8,
        /// That page came over plain http.
        clear: bool,
        at: f64,

        pub fn deinit(s: Sent, gpa: std.mem.Allocator) void {
            gpa.free(s.host);
            gpa.free(s.user);
            gpa.free(s.password);
        }
    };

    pub fn deinit(s: *SignIn, gpa: std.mem.Allocator) void {
        s.dropNamed(gpa);
        s.dropSent(gpa);
    }

    fn dropNamed(s: *SignIn, gpa: std.mem.Allocator) void {
        if (s.named) |n| {
            gpa.free(n.site);
            gpa.free(n.user);
        }
        s.named = null;
    }

    fn dropSent(s: *SignIn, gpa: std.mem.Allocator) void {
        if (s.sent) |x| x.deinit(gpa);
        s.sent = null;
    }

    /// `gaveName`: kept under the page's site, 256 characters at most.
    pub fn gaveName(s: *SignIn, gpa: std.mem.Allocator, page: ?[]const u8, user: []const u8, now: f64) void {
        const count = std.unicode.utf8CountCodepoints(user) catch user.len;
        if (user.len == 0 or count > 256) return;
        const h = pageHost(gpa, page) orelse return;
        defer gpa.free(h);
        const site = vault.registrable(gpa, h) catch return;
        const copy = gpa.dupe(u8, user) catch return gpa.free(site);
        s.dropNamed(gpa);
        s.named = .{ .site = site, .user = copy, .at = now };
    }

    /// `givenName`: the name sent on the step before, if this site's and
    /// under five minutes old. Borrowed from `s`.
    pub fn givenName(s: *const SignIn, gpa: std.mem.Allocator, page: ?[]const u8, now: f64) ?[]const u8 {
        const n = s.named orelse return null;
        if (now - n.at >= 300) return null;
        const h = pageHost(gpa, page) orelse return null;
        defer gpa.free(h);
        const site = vault.registrable(gpa, h) catch return null;
        defer gpa.free(site);
        return if (std.mem.eql(u8, site, n.site)) n.user else null;
    }

    /// `sentSignIn`: held under the host it was sent from, while the page is
    /// still the sign-in page; a password page with no name takes the one
    /// the step before was sent with.
    pub fn sentSignIn(s: *SignIn, gpa: std.mem.Allocator, page: ?[]const u8, user: []const u8, password: []const u8, now: f64) void {
        const h = pageHost(gpa, page) orelse return;
        defer gpa.free(h);
        const bare = if (std.mem.startsWith(u8, h, "www.")) h[4..] else h;
        const who = if (user.len == 0) s.givenName(gpa, page, now) orelse "" else user;
        const clear = (url.Parts.parse(page.?) orelse return).schemeIs("http");
        const host_copy = gpa.dupe(u8, bare) catch return;
        const user_copy = gpa.dupe(u8, who) catch return gpa.free(host_copy);
        const pass_copy = gpa.dupe(u8, password) catch {
            gpa.free(host_copy);
            return gpa.free(user_copy);
        };
        s.dropSent(gpa);
        s.sent = .{ .host = host_copy, .user = user_copy, .password = pass_copy, .clear = clear, .at = now };
    }

    pub const Settle = union(enum) {
        nothing,
        /// Fields the page removed by itself: ask again after 1.5 s with
        /// `settleLater(stamp)`, which runs `settle(navigated: true)` only
        /// if nothing newer went out.
        later: f64,
        /// Evaluate `has_password_script` in Kea's world and hand the
        /// answer to `answered`.
        ask,
    };

    /// `settleSignIn(navigated:)`: a new document is judged at once; held
    /// for 45 s at most.
    pub fn settle(s: *SignIn, gpa: std.mem.Allocator, now: f64, navigated: bool) Settle {
        const sent = s.sent orelse return .nothing;
        if (now - sent.at >= 45) {
            s.dropSent(gpa);
            return .nothing;
        }
        return if (navigated) .ask else .{ .later = sent.at };
    }

    pub fn settleLater(s: *SignIn, gpa: std.mem.Allocator, now: f64, stamp: f64) Settle {
        const sent = s.sent orelse return .nothing;
        if (sent.at != stamp) return .nothing;
        return s.settle(gpa, now, true);
    }

    /// The page's answer to `has_password_script`: the box still there is a
    /// refused sign-in, kept a moment longer; gone, it took, and what was
    /// sent is handed over (the caller owns it) for `offerFor`.
    pub fn answered(s: *SignIn, gpa: std.mem.Allocator, still: bool) ?Sent {
        if (still) return null;
        const sent = s.sent orelse return null;
        s.sent = null;
        s.dropNamed(gpa);
        return sent;
    }
};

/// A name and password waiting to be offered a place in the keychain.
pub const Offer = struct {
    login: Login,
    /// The same account is already kept, with another password.
    changed: bool,

    pub fn deinit(o: Offer, gpa: std.mem.Allocator) void {
        o.login.deinit(gpa);
    }

    pub fn eql(a: Offer, b: Offer) bool {
        return a.changed == b.changed and a.login.eql(b.login);
    }
};

/// Why a sent sign-in is never offered, besides its site's own choice.
pub const Gate = struct {
    /// `passwords.save`.
    saves: bool,
    /// A private tab.
    shy: bool = false,
    /// An extension's own page isn't a site.
    extension_page: bool = false,
    /// A password manager extension asked to do the saving itself.
    extension_saves: bool = false,
};

pub const Decision = union(enum) {
    ignore,
    /// Already kept, same password: touch `known[i]`, with `clear` as sent.
    touch: usize,
    offer: struct { changed: bool },
};

/// The rules of `onCredentials` once the keychain has said what it keeps
/// for the host (`known`), and whether the site said never.
pub fn decide(gate: Gate, never: bool, user: []const u8, password: []const u8, known: []const Login) Decision {
    if (!gate.saves or password.len == 0 or gate.shy or never or gate.extension_page or gate.extension_saves) return .ignore;
    for (known, 0..) |k, i| if (std.mem.eql(u8, k.user, user) and std.mem.eql(u8, k.password, password)) return .{ .touch = i };
    const changed = for (known) |k| {
        if (std.mem.eql(u8, k.user, user)) break true;
    } else false;
    return .{ .offer = .{ .changed = changed } };
}

/// `onCredentials` in full: the offer to show, or null when nothing changes
/// (ignored, already kept and touched, or the same offer already up).
/// Takes `sent` (freed here).
pub fn offerFor(v: Vault, gate: Gate, sent: SignIn.Sent, current: ?Offer, now_unix: f64) !?Offer {
    defer sent.deinit(v.gpa);
    if (!gate.saves or sent.password.len == 0 or gate.shy or gate.extension_page or gate.extension_saves) return null;
    if (v.isNever(sent.host)) return null;
    const known = try v.logins(sent.host);
    defer vault.freeLogins(v.gpa, known);
    switch (decide(gate, false, sent.user, sent.password, known)) {
        .ignore => return null,
        .touch => |i| {
            // Where it was last used is where it is offered from now on.
            var same = known[i];
            same.clear = sent.clear;
            v.touch(same, now_unix);
            return null;
        },
        .offer => |o| {
            const login = try (Login{ .host = sent.host, .user = sent.user, .password = sent.password, .clear = sent.clear }).clone(v.gpa);
            const offer: Offer = .{ .login = login, .changed = o.changed };
            if (current) |c| if (c.eql(offer)) {
                offer.deinit(v.gpa);
                return null;
            };
            return offer;
        },
    }
}

/// `keepOffer`: saved with its use now; the announcement (caller frees).
/// The caller drops the offer and relists.
pub fn keep(v: Vault, offer: Offer, now_unix: f64) ![]u8 {
    const l = offer.login;
    if (!v.save(l.host, l.user, l.password, now_unix, l.clear)) return v.gpa.dupe(u8, "The keychain refused it");
    return std.fmt.allocPrint(v.gpa, "{s} for {s}", .{ if (offer.changed) "Password updated" else "Password saved", l.host });
}

/// `neverOffer`: never for this site; the announcement (caller frees).
pub fn neverFor(v: Vault, offer: Offer) ![]u8 {
    v.addNever(offer.login.host);
    return std.fmt.allocPrint(v.gpa, "Never for {s}", .{offer.login.host});
}

/// `choose(_:)`'s refusal when the fields went away meanwhile.
pub const fields_gone = "Couldn't find the sign-in fields anymore";
