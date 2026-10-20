//! The accounts that hang from the sign-in box the caret is in
//! (Browser.swift 636-803, `hang(from:)`, `choose`, and the passkeys' arrival
//! at 1575-1585), for `AccountList` (Accounts.swift) to draw. One per browser.
const std = @import("std");
const vault = @import("vault.zig");
const Vault = vault.Vault;
const Login = vault.Login;
const Rect = @import("forms.zig").Rect;
const Offered = @import("passkeys_reply.zig").Offered;
const Curtain = @import("../data/curtain.zig").Curtain;
const url = @import("../data/url.zig");

/// At most this many accounts in the list.
pub const most = 5;
/// A click in the list's first half second is not a choice.
pub const settling = 0.5;
/// The list goes this long after the caret leaves (`lowering`).
pub const lowering_delay = 0.2;

pub const Suggesting = struct {
    tab: u64,
    logins: []Login,
    /// The Mac's passkeys for a page waiting for one under its field.
    passkeys: []Offered,
    /// The page the list was made for: a click fills only that one.
    host: []u8,
    clear: bool,
    /// Hung from a first step's name box: a pick puts in the name alone.
    name_only: bool = false,
    shown: f64,

    pub fn deinit(s: Suggesting, gpa: std.mem.Allocator) void {
        vault.freeLogins(gpa, s.logins);
        for (s.passkeys) |p| p.deinit(gpa);
        gpa.free(s.passkeys);
        gpa.free(s.host);
    }
};

/// Where the caret is, as the page last said (`Tab.onField`).
pub const Hang = struct {
    tab: u64,
    /// The tab is the window's active one.
    active: bool,
    /// The tab's page address.
    page: ?[]const u8,
    /// The box in the web view's points (`forms.spot`); null: it left.
    spot: ?Rect,
    passwords: bool = true,
    name: bool = false,
    /// `passwords.fill`.
    fills: bool,
    /// `SignIn.givenName`.
    given: ?[]const u8 = null,
    /// `Passkeys.offered(web)`.
    passkeys: []const Offered = &.{},
    now: f64,
};

pub const Field = struct { tab: u64, spot: Rect, passwords: bool, name: bool };

pub const Choice = union(enum) {
    none,
    /// Fill both (`forms.fillScript`); already touched in the vault. Owned.
    fill: Login,
    /// A first step: the name alone (`forms.nameScript`). Owned.
    name: []u8,
    /// `Passkeys.sign(web, id)`. Owned.
    passkey: []u8,
};

pub const Accounts = struct {
    gpa: std.mem.Allocator,
    suggesting: ?Suggesting = null,
    /// `hanging.spot`: where the list hangs from.
    spot: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Set once you have picked, until the caret leaves the boxes.
    picked_into: ?u64 = null,
    /// The page last looked up for the box the caret is in: the keychain is
    /// asked once per box, not per frame of a scroll.
    looked: ?struct { tab: u64, host: []u8, clear: bool, name: bool } = null,
    /// The sign-in box the caret is in.
    field: ?Field = null,
    /// Bumped to cancel a pending lowering (`lowering?.cancel()`).
    lowering: u64 = 0,

    pub fn deinit(a: *Accounts) void {
        a.drop();
        a.forgetLooked();
    }

    fn drop(a: *Accounts) void {
        if (a.suggesting) |s| s.deinit(a.gpa);
        a.suggesting = null;
    }

    fn forgetLooked(a: *Accounts) void {
        if (a.looked) |l| a.gpa.free(l.host);
        a.looked = null;
    }

    /// `dropChoice`.
    pub fn dropChoice(a: *Accounts) void {
        a.drop();
    }

    /// Another tab in front (`suggesting = nil; looked = nil`): the list
    /// down, and back on a tab with the caret still in a box it may come again.
    pub fn away(a: *Accounts) void {
        a.drop();
        a.forgetLooked();
    }

    /// `hang(from:)`. Returns a token when the list should come down after
    /// `lowering_delay`: then call `lowered(tab, token)`.
    pub fn hang(a: *Accounts, v: Vault, h: Hang) !?u64 {
        const at = h.spot orelse {
            if (a.field) |f| if (f.tab == h.tab) {
                a.field = null;
            };
            if (a.looked) |l| if (l.tab == h.tab) a.forgetLooked();
            if (a.picked_into == h.tab) a.picked_into = null;
            const s = a.suggesting orelse return null;
            if (s.tab != h.tab) return null;
            a.lowering +%= 1;
            return a.lowering;
        };
        a.lowering +%= 1;
        a.field = .{ .tab = h.tab, .spot = at, .passwords = h.passwords, .name = h.name };
        if (!h.active or a.picked_into == h.tab) return null;
        const host = Curtain.hostOf(a.gpa, h.page) orelse return null;
        var host_owned = true;
        defer if (host_owned) a.gpa.free(host);
        // A page over plain http is offered only what was kept from one.
        const clear = isClear(h.page);
        if (a.looked) |l| if (l.tab == h.tab and std.mem.eql(u8, l.host, host) and l.clear == clear and l.name == h.name) {
            if (a.suggesting) |s| if (s.tab == h.tab) {
                a.spot = at;
            };
            return null;
        };
        a.forgetLooked();
        a.looked = .{ .tab = h.tab, .host = host, .clear = clear, .name = h.name };
        host_owned = false;
        const known = try offered(v, h.fills and h.passwords, host, clear, h.given);
        var known_owned = true;
        defer if (known_owned) vault.freeLogins(a.gpa, known);
        if (known.len == 0 and h.passkeys.len == 0) {
            a.drop();
            return null;
        }
        if (a.suggesting) |up| if (up.tab == h.tab and up.name_only == h.name and sameLogins(up.logins, known) and samePasskeys(up.passkeys, h.passkeys)) {
            a.spot = at;
            return null;
        };
        const passkeys = try a.gpa.alloc(Offered, h.passkeys.len);
        var made: usize = 0;
        errdefer {
            for (passkeys[0..made]) |p| p.deinit(a.gpa);
            a.gpa.free(passkeys);
        }
        for (h.passkeys) |p| {
            passkeys[made] = try p.clone(a.gpa);
            made += 1;
        }
        const host_copy = try a.gpa.dupe(u8, host);
        a.drop();
        a.spot = at;
        a.suggesting = .{ .tab = h.tab, .logins = known, .passkeys = passkeys, .host = host_copy, .clear = clear, .name_only = h.name, .shown = h.now };
        known_owned = false;
        return null;
    }

    /// The pending lowering, if nothing cancelled it.
    pub fn lowered(a: *Accounts, tab: u64, token: u64) void {
        if (token != a.lowering) return;
        if (a.suggesting) |s| if (s.tab == tab) a.drop();
    }

    /// A page's passkeys arrived or went while the caret is in its box: the
    /// field to hang again from (`offeredChanged`).
    pub fn passkeysChanged(a: *Accounts, tab: u64) ?Field {
        const f = a.field orelse return null;
        if (f.tab != tab) return null;
        a.forgetLooked();
        return f;
    }

    /// `choose(_ login:)`: the `i`th account, into a page that is still the
    /// one the list was made for. `page` is that tab's address now; `now`
    /// is unix seconds, as everywhere here.
    pub fn choose(a: *Accounts, v: Vault, i: usize, page: ?[]const u8, now: f64) !Choice {
        const list = a.picked(page, now) orelse return .none;
        defer list.deinit(a.gpa);
        if (i >= list.logins.len) return .none;
        a.picked_into = list.tab;
        const login = list.logins[i];
        if (list.name_only) return .{ .name = try a.gpa.dupe(u8, login.user) };
        v.touch(login, now);
        return .{ .fill = try login.clone(a.gpa) };
    }

    /// `choose(_ passkey:)`: the Mac's sheet for the `i`th passkey.
    pub fn choosePasskey(a: *Accounts, i: usize, page: ?[]const u8, now: f64) !Choice {
        const list = a.picked(page, now) orelse return .none;
        defer list.deinit(a.gpa);
        if (i >= list.passkeys.len) return .none;
        a.picked_into = list.tab;
        return .{ .passkey = try a.gpa.dupe(u8, list.passkeys[i].id) };
    }

    /// The list taken down for a pick, when the pick counts.
    fn picked(a: *Accounts, page: ?[]const u8, now: f64) ?Suggesting {
        a.lowering +%= 1;
        const list = a.suggesting orelse return null;
        if (now - list.shown <= settling) return null;
        a.suggesting = null;
        const host = Curtain.hostOf(a.gpa, page);
        defer if (host) |h| a.gpa.free(h);
        if (host == null or !std.mem.eql(u8, host.?, list.host) or isClear(page) != list.clear) {
            list.deinit(a.gpa);
            return null;
        }
        return list;
    }
};

fn isClear(page: ?[]const u8) bool {
    return (url.Parts.parse(page orelse return false) orelse return false).schemeIs("http");
}

/// The accounts for a box (`hang`'s `kept`/`known`): with `fills` (and a
/// box that goes with a password), every login kept for the site, only the
/// plain-http ones on a plain-http page, the name sent on the step before
/// first, five at most. On `v.gpa`.
pub fn offered(v: Vault, fills: bool, host: []const u8, clear: bool, given: ?[]const u8) ![]Login {
    if (!fills) return v.gpa.alloc(Login, 0);
    return pick(v.gpa, try v.loginsMatching(host), clear, given);
}

/// `offered`'s narrowing of what the vault found (takes `all`, on `gpa`).
pub fn pick(gpa: std.mem.Allocator, all: []Login, clear: bool, given: ?[]const u8) ![]Login {
    var n: usize = 0;
    for (all) |l| {
        if (clear and !l.clear) {
            l.deinit(gpa);
            continue;
        }
        all[n] = l;
        n += 1;
    }
    if (given) |g| for (all[0..n], 0..) |l, i| if (std.ascii.eqlIgnoreCase(l.user, g)) {
        std.mem.rotate(Login, all[0 .. i + 1], i);
        break;
    };
    for (all[@min(n, most)..n]) |l| l.deinit(gpa);
    return gpa.realloc(all, @min(n, most));
}

fn sameLogins(a: []const Login, b: []const Login) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

fn samePasskeys(a: []const Offered, b: []const Offered) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}
