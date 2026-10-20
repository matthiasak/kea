//! P10 unit tests: the PRF seal, the vault under tests, the save-offer rules
//! (Forms.swift / Tab.swift / Browser.swift `onCredentials`), the account
//! list's choice, CSV export parsing and the attestation reader.
const std = @import("std");
const testing = std.testing;
const P256 = std.crypto.ecc.P256;
const Temp = @import("../tests/temp.zig").Temp;
const Store = @import("../data/store.zig").Store;
const vault = @import("vault.zig");
const forms = @import("forms.zig");
const accounts = @import("accounts_model.zig");
const reply = @import("passkeys_reply.zig");
const cbor = @import("passkeys_cbor.zig");
const passkeys = @import("passkeys.zig");

const gpa = testing.allocator;

test {
    // Modules, then each struct's own methods (refAllDecls is one level deep).
    testing.refAllDecls(vault);
    testing.refAllDecls(forms);
    testing.refAllDecls(accounts);
    testing.refAllDecls(reply);
    testing.refAllDecls(passkeys);
    testing.refAllDecls(@import("passkeys_relay.zig"));
    testing.refAllDecls(@import("passkeys_requests.zig"));
    testing.refAllDecls(@import("../sys/keychain_internet.zig"));
    inline for (.{ vault.Vault, vault.Login, vault.Kept, forms.SignIn, forms.SignIn.Sent, forms.Offer, accounts.Accounts, accounts.Suggesting, passkeys.Passkeys, passkeys.Answer, reply.Offered }) |T| testing.refAllDecls(T);
}

// MARK: PRF

fn pageKeyPair() struct { secret: [32]u8, public: [65]u8 } {
    var secret: [32]u8 = undefined;
    while (true) {
        std.c.arc4random_buf(&secret, secret.len);
        const s = P256.scalar.Scalar.fromBytes(secret, .big) catch continue;
        if (!s.isZero()) break;
    }
    return .{ .secret = secret, .public = (P256.basePoint.mul(secret, .big) catch unreachable).toUncompressedSec1() };
}

test "PRF seal opens with the peer key" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const page = pageKeyPair();
    const first = reply.rehearsalFirst();
    const second: [32]u8 = @splat(7);
    const prf = reply.prfReply(a, true, &first, &second, page.public);
    try testing.expectEqual(true, prf.enabled.?);
    const plain = try reply.open(a, prf.sealed.?, page.secret);
    const Results = struct { first: []const u8, second: ?[]const u8 = null };
    const parsed = try std.json.parseFromSliceLeaky(Results, a, plain, .{});
    try testing.expectEqualStrings(try reply.text(a, &first), parsed.first);
    try testing.expectEqualStrings(try reply.text(a, &second), parsed.second.?);
    // A test run's made-up first output is SHA-256("rehearsal").
    try testing.expectEqualStrings("K80-FNyo_bGMo9TpWLscTfACWYrm5dgPydmCSmtdxFA", try reply.text(a, &first));
    // The wrong key opens nothing.
    try testing.expectError(error.AuthenticationFailed, reply.open(a, prf.sealed.?, pageKeyPair().secret));
}

test "PRF seal is ECDH both ways, HKDF info kea-prf" {
    const page = pageKeyPair();
    const mine = pageKeyPair();
    try testing.expectEqualSlices(u8, &(try reply.sharedKey(page.public, mine.secret)), &(try reply.sharedKey(mine.public, page.secret)));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nonce: [12]u8 = @splat(3);
    const sealed = try reply.seal(a, "abc", null, page.public, mine.secret, nonce);
    try testing.expectEqualStrings(try reply.text(a, &mine.public), sealed.key);
    const box = reply.data(a, sealed.box).?;
    try testing.expectEqualSlices(u8, &nonce, box[0..12]);
    try testing.expectEqualStrings("{\"first\":\"YWJj\"}", try reply.open(a, sealed, page.secret));
}

test "PRF reply without the page's key or output carries none" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(reply.prfReply(a, false, "x", null, null).sealed == null);
    try testing.expect(reply.prfReply(a, null, null, null, pageKeyPair().public).sealed == null);
    try testing.expect(reply.pageKey(a, "not a key") == null);
    const page = pageKeyPair();
    try testing.expectEqualSlices(u8, &page.public, &reply.pageKey(a, try reply.text(a, &page.public)).?);
}

// MARK: attestation, checks, bytes

test "rehearsal registration reads back its P-256 key" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try reply.rehearsal(a, "create", "example.com", "https://example.com", "challenge");
    try testing.expectEqualStrings("create", r.kind.?);
    try testing.expectEqual(@as(i64, -7), r.publicKeyAlgorithm.?);
    const der = reply.data(a, r.publicKey.?).?;
    try testing.expectEqual(@as(usize, 91), der.len);
    try testing.expectEqual(@as(u8, 1), der[27]);
    try testing.expectEqual(@as(u8, 2), der[90]);
    const client = reply.data(a, r.clientDataJSON.?).?;
    try testing.expectEqualStrings("{\"type\":\"webauthn.create\",\"challenge\":\"Y2hhbGxlbmdl\",\"origin\":\"https://example.com\",\"crossOrigin\":false}", client);
    const get = try reply.rehearsal(a, "get", "example.com", "https://example.com", "c");
    try testing.expectEqualStrings("dXNlcg", get.userHandle.?);
    try testing.expectEqualStrings("AAECAwQFBgcICQoLDA0ODw", get.id.?);
}

test "attestation without authData has no authenticator data" {
    try testing.expect(cbor.authenticatorData(&.{ 0xA1, 0x63, 'f', 'm', 't', 0x64, 'n', 'o', 'n', 'e' }) == null);
    try testing.expect(cbor.authenticatorData(&.{0x00}) == null);
}

fn suffixes(name: []const u8) bool {
    for ([_][]const u8{ "com", "co.uk", "github.io" }) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

test "relying party fits the page's site only" {
    try testing.expect(reply.fits("example.com", "example.com", null));
    try testing.expect(reply.fits("example.com", "login.example.com", suffixes));
    try testing.expect(!reply.fits("example.com", "login.example.com", null));
    try testing.expect(!reply.fits("com", "example.com", suffixes));
    try testing.expect(!reply.fits("github.io", "alice.github.io", suffixes));
    try testing.expect(!reply.fits("other.com", "example.com", suffixes));
    try testing.expect(!reply.fits("ample.com", "example.com", suffixes));
    try testing.expect(!reply.fits("0.1", "10.0.0.1", suffixes));
}

test "origin text brackets an address and keeps a port" {
    const a = try passkeys.originText(gpa, "HTTPS", "Example.com", 0);
    defer gpa.free(a);
    try testing.expectEqualStrings("https://example.com", a);
    const b = try passkeys.originText(gpa, "http", "::1", 8080);
    defer gpa.free(b);
    try testing.expectEqualStrings("http://[::1]:8080", b);
}

test "base64url reads either alphabet with or without padding" {
    const x = reply.data(gpa, "-_8=").?;
    defer gpa.free(x);
    const y = reply.data(gpa, "+/8").?;
    defer gpa.free(y);
    try testing.expectEqualSlices(u8, &.{ 0xFB, 0xFF }, x);
    try testing.expectEqualSlices(u8, x, y);
}

// MARK: vault

test "vault guarded path returns saved without keychain under tests" {
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    const v: vault.Vault = .{ .gpa = gpa, .store = &store, .guarded = true };
    try testing.expect(v.save("example.com", "kea", "hunter2", 1.0, false));
    try testing.expect(!v.save("example.com", "kea", "", null, false));
    try testing.expect(!v.save("", "kea", "pw", null, false));
    const found = try v.logins("example.com");
    defer vault.freeLogins(gpa, found);
    try testing.expectEqual(@as(usize, 0), found.len);
    const kept = try v.all();
    defer vault.freeKept(gpa, kept);
    try testing.expectEqual(@as(usize, 0), kept.len);
    var proven: ?bool = null;
    v.prove("show the password for example.com", &proven, struct {
        fn done(ctx: *anyopaque, ok: bool) void {
            const p: *?bool = @ptrCast(@alignCast(ctx));
            p.* = ok;
        }
    }.done);
    try testing.expectEqual(true, proven.?);
    // Sites told never: kept sorted, matched by site too.
    v.addNever("example.com");
    v.addNever("a.org");
    v.addNever("example.com");
    const never = try v.never();
    defer {
        for (never) |s| gpa.free(s);
        gpa.free(never);
    }
    try testing.expectEqual(@as(usize, 2), never.len);
    try testing.expectEqualStrings("a.org", never[0]);
    try testing.expect(v.isNever("example.com"));
    try testing.expect(!v.isNever("example.net"));
    // A guarded CSV import counts what it would keep.
    const taken = try v.takeCsv("name,url,username,password,note\nEx,https://www.example.com/login,kea,pw,\nApp,android://x@com.vendor.app/,u,p,\nNo pass,https://b.com,u,,\n\"Q, \"\"quoted\"\"\",http://c.com,\"a\r\nb\",p2,\n", null);
    try testing.expectEqual(@as(usize, 2), taken.kept);
    try testing.expectEqual(@as(usize, 2), taken.skipped);
}

test "vault host keeps websites only" {
    for ([_][2][]const u8{
        .{ "https://www.Example.com/login", "example.com" },
        .{ " example.com ", "example.com" },
        .{ "http://accounts.example.com:8080/", "accounts.example.com" },
        .{ "android://abc@com.vendor.app/", "" },
        .{ "ftp://example.com", "" },
    }) |case| {
        const h = try vault.host(gpa, case[0]);
        defer gpa.free(h);
        try testing.expectEqualStrings(case[1], h);
    }
}

test "csv keeps quotes, doubled quotes and newlines inside them" {
    const rows = try vault.parseCsv(gpa, "a,\"b,\"\"c\"\"\nd\",e\r\n,,\r\nf", null);
    defer vault.freeRows(gpa, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("b,\"c\"\nd", rows[0][1]);
    try testing.expectEqualStrings("e", rows[0][2]);
    try testing.expectEqualStrings("f", rows[1][0]);
}

test "used date is written as Swift's String(Double)" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1760000000.0", vault.swiftDouble(&buf, 1760000000));
    try testing.expectEqualStrings("1760000000.25", vault.swiftDouble(&buf, 1760000000.25));
}

// MARK: forms

fn login(host: []const u8, user: []const u8, password: []const u8, clear: bool) !vault.Login {
    return (vault.Login{ .host = @constCast(host), .user = @constCast(user), .password = @constCast(password), .clear = clear }).clone(gpa);
}

test "forms save-offer decision table" {
    const known = [_]vault.Login{
        .{ .host = @constCast("example.com"), .user = @constCast("kea"), .password = @constCast("old") },
        .{ .host = @constCast("example.com"), .user = @constCast("ubi"), .password = @constCast("same") },
    };
    const on: forms.Gate = .{ .saves = true };
    const D = forms.Decision;
    const cases = [_]struct { gate: forms.Gate, never: bool, user: []const u8, password: []const u8, want: D }{
        .{ .gate = .{ .saves = false }, .never = false, .user = "kea", .password = "new", .want = .ignore },
        .{ .gate = on, .never = false, .user = "kea", .password = "", .want = .ignore },
        .{ .gate = .{ .saves = true, .shy = true }, .never = false, .user = "kea", .password = "new", .want = .ignore },
        .{ .gate = on, .never = true, .user = "kea", .password = "new", .want = .ignore },
        .{ .gate = .{ .saves = true, .extension_page = true }, .never = false, .user = "kea", .password = "new", .want = .ignore },
        .{ .gate = .{ .saves = true, .extension_saves = true }, .never = false, .user = "kea", .password = "new", .want = .ignore },
        .{ .gate = on, .never = false, .user = "ubi", .password = "same", .want = .{ .touch = 1 } },
        .{ .gate = on, .never = false, .user = "kea", .password = "new", .want = .{ .offer = .{ .changed = true } } },
        .{ .gate = on, .never = false, .user = "new", .password = "old", .want = .{ .offer = .{ .changed = false } } },
        .{ .gate = on, .never = false, .user = "", .password = "pin", .want = .{ .offer = .{ .changed = false } } },
    };
    for (cases) |c| try testing.expectEqualDeep(c.want, forms.decide(c.gate, c.never, c.user, c.password, &known));
    try testing.expectEqualDeep(D{ .offer = .{ .changed = false } }, forms.decide(on, false, "kea", "pw", &.{}));
}

test "sign-in is held, settled and handed over once" {
    var s: forms.SignIn = .{};
    defer s.deinit(gpa);
    const page = "http://www.Example.com/login";
    // A first step's name, then a password page with no name on it.
    s.gaveName(gpa, "https://login.example.com/", "kea@example.com", 100);
    try testing.expectEqualStrings("kea@example.com", s.givenName(gpa, page, 200).?);
    try testing.expect(s.givenName(gpa, "https://other.org/", 200) == null);
    try testing.expect(s.givenName(gpa, page, 400) == null);
    s.sentSignIn(gpa, page, "", "pw", 200);
    try testing.expectEqualStrings("example.com", s.sent.?.host);
    try testing.expectEqualStrings("kea@example.com", s.sent.?.user);
    try testing.expect(s.sent.?.clear);
    // Fields gone without a new page: a moment first.
    const later = s.settle(gpa, 201, false);
    try testing.expectEqual(@as(f64, 200), later.later);
    try testing.expectEqual(forms.SignIn.Settle.nothing, s.settleLater(gpa, 202, 150));
    try testing.expectEqual(forms.SignIn.Settle.ask, s.settleLater(gpa, 202, 200));
    // Still a password box: refused, kept a moment longer.
    try testing.expect(s.answered(gpa, true) == null);
    const sent = s.answered(gpa, false).?;
    defer sent.deinit(gpa);
    try testing.expectEqualStrings("pw", sent.password);
    try testing.expect(s.sent == null and s.named == null);
    // Older than 45 s: let go.
    s.sentSignIn(gpa, "https://example.com/", "kea", "pw", 0);
    try testing.expectEqual(forms.SignIn.Settle.nothing, s.settle(gpa, 45, true));
    try testing.expect(s.sent == null);
    // Names longer than 256 characters aren't kept.
    const long: [257]u8 = @splat('x');
    s.gaveName(gpa, page, &long, 0);
    try testing.expect(s.named == null);
}

test "offer for a sent sign-in, under tests" {
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    const v: vault.Vault = .{ .gpa = gpa, .store = &store, .guarded = true };
    const sent = forms.SignIn.Sent{ .host = try gpa.dupe(u8, "example.com"), .user = try gpa.dupe(u8, "kea"), .password = try gpa.dupe(u8, "pw"), .clear = false, .at = 0 };
    const offer = (try forms.offerFor(v, .{ .saves = true }, sent, null, 0)).?;
    defer offer.deinit(gpa);
    try testing.expect(!offer.changed);
    try testing.expectEqualStrings("kea", offer.login.user);
    // The same offer already up: nothing changes.
    const again = forms.SignIn.Sent{ .host = try gpa.dupe(u8, "example.com"), .user = try gpa.dupe(u8, "kea"), .password = try gpa.dupe(u8, "pw"), .clear = false, .at = 1 };
    try testing.expect(try forms.offerFor(v, .{ .saves = true }, again, offer, 1) == null);
    const said = try forms.keep(v, offer, 2);
    defer gpa.free(said);
    try testing.expectEqualStrings("Password saved for example.com", said);
    const never = try forms.neverFor(v, offer);
    defer gpa.free(never);
    try testing.expectEqualStrings("Never for example.com", never);
    const blocked = forms.SignIn.Sent{ .host = try gpa.dupe(u8, "example.com"), .user = try gpa.dupe(u8, "kea"), .password = try gpa.dupe(u8, "pw2"), .clear = false, .at = 3 };
    try testing.expect(try forms.offerFor(v, .{ .saves = true }, blocked, null, 3) == null);
}

test "fill scripts escape backticks and dollars" {
    const s = try forms.fillScript(gpa, "a`b", "p$\\");
    defer gpa.free(s);
    try testing.expectEqualStrings("window.__keaForms && window.__keaForms.fill(`a\\`b`, `p\\$\\\\`)", s);
}

// MARK: accounts

test "accounts match by registrable domain" {
    const cases = [_]struct { host: []const u8, other: []const u8, same: bool }{
        .{ .host = "accounts.example.com", .other = "example.com", .same = true },
        .{ .host = "accounts.example.com", .other = "www.example.com", .same = true },
        .{ .host = "news.bbc.co.uk", .other = "bbc.co.uk", .same = true },
        // The exact host is the other half of the list, not a wider one.
        .{ .host = "accounts.example.com", .other = "accounts.example.com", .same = false },
        .{ .host = "accounts.example.com", .other = "example.org", .same = false },
        .{ .host = "accounts.example.com", .other = "notexample.com", .same = false },
        .{ .host = "bbc.co.uk", .other = "co.uk", .same = false },
        // Tenants of a public suffix are sites of their own.
        .{ .host = "alice.github.io", .other = "bob.github.io", .same = false },
    };
    for (cases) |c| try testing.expectEqual(c.same, try vault.sameSite(gpa, c.host, c.other, suffixes));
    // Without a suffix list, only the host itself is its site.
    try testing.expect(!try vault.sameSite(gpa, "accounts.example.com", "example.com", null));
}

test "accounts list: plain http only on http, the given name first, five at most" {
    var all = try gpa.alloc(vault.Login, 7);
    all[0] = try login("example.com", "a", "1", false);
    all[1] = try login("example.com", "b", "2", true);
    all[2] = try login("example.com", "C", "3", true);
    for (all[3..], 0..) |*l, i| l.* = try login("example.com", ([_][]const u8{ "d", "e", "f", "g" })[i], "x", false);
    const clear = try accounts.pick(gpa, try dupeAll(all), true, "c");
    defer vault.freeLogins(gpa, clear);
    try testing.expectEqual(@as(usize, 2), clear.len);
    try testing.expectEqualStrings("C", clear[0].user);
    try testing.expectEqualStrings("b", clear[1].user);
    const secure = try accounts.pick(gpa, all, false, "g");
    defer vault.freeLogins(gpa, secure);
    try testing.expectEqual(@as(usize, accounts.most), secure.len);
    try testing.expectEqualStrings("g", secure[0].user);
    try testing.expectEqualStrings("a", secure[1].user);
}

fn dupeAll(list: []const vault.Login) ![]vault.Login {
    const out = try gpa.alloc(vault.Login, list.len);
    for (list, out) |l, *o| o.* = try l.clone(gpa);
    return out;
}

test "account list waits half a second and fills only the same page" {
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    const v: vault.Vault = .{ .gpa = gpa, .store = &store, .guarded = true };
    var list: accounts.Accounts = .{ .gpa = gpa };
    defer list.deinit();
    const key = reply.Offered{ .id = @constCast("id"), .name = @constCast("probe@example.com") };
    const spot: forms.Rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    const h: accounts.Hang = .{ .tab = 1, .active = true, .page = "https://example.com/", .spot = spot, .fills = true, .passkeys = &.{key}, .now = 10 };
    try testing.expect(try list.hang(v, h) == null);
    try testing.expectEqual(@as(usize, 1), list.suggesting.?.passkeys.len);
    try testing.expectEqual(@as(f64, 10), list.suggesting.?.shown);
    // Too soon: no choice, and the list stays.
    try testing.expectEqual(accounts.Choice.none, try list.choosePasskey(0, "https://example.com/", 10.3));
    try testing.expect(list.suggesting != null);
    // Another page by now: nothing goes into it.
    try testing.expectEqual(accounts.Choice.none, try list.choosePasskey(0, "https://other.com/", 11));
    try testing.expect(list.suggesting == null);
    _ = try list.hang(v, .{ .tab = 1, .active = true, .page = "https://example.com/", .spot = null, .fills = true, .now = 12 });
    _ = try list.hang(v, h);
    const choice = try list.choosePasskey(0, "https://example.com/", 11);
    defer gpa.free(choice.passkey);
    try testing.expectEqualStrings("id", choice.passkey);
    // The caret leaves: the list comes down a beat later, unless it came back.
    _ = try list.hang(v, .{ .tab = 1, .active = true, .page = "https://example.com/", .spot = null, .fills = true, .now = 12 });
    _ = try list.hang(v, h);
    const token = (try list.hang(v, .{ .tab = 1, .active = true, .page = "https://example.com/", .spot = null, .fills = true, .now = 13 })).?;
    list.lowered(1, token +% 1);
    try testing.expect(list.suggesting != null);
    list.lowered(1, token);
    try testing.expect(list.suggesting == null);
}

test "passkeys page script says whether PRF works here" {
    const req = @import("passkeys_requests.zig");
    try testing.expect(req.atLeast(10, 0));
    try testing.expect(!req.atLeast(99, 0));
    const s = passkeys.pageScript();
    try testing.expect(std.mem.indexOf(u8, s, "__KEA_PRF__") == null);
    const want = if (req.prfAvailable()) "c['extension:prf'] = true;" else "c['extension:prf'] = false;";
    try testing.expect(std.mem.indexOf(u8, s, want) != null);
    try testing.expect(std.mem.indexOf(u8, passkeys.bridge_script, "webkit.messageHandlers.keaPasskeys") != null);
    try testing.expect(std.mem.indexOf(u8, s, "'kea-passkeys-answer'") != null);
}

test "csv import reports progress and stops when cancelled" {
    const Control = struct {
        reports: usize = 0,
        last: []const u8 = "",
        stop: bool = false,
        fn report(ctx: *anyopaque, message: []const u8, _: usize, _: ?usize) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.reports += 1;
            c.last = message;
        }
        fn cancelled(ctx: *anyopaque) bool {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return c.stop;
        }
    };
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    const v: vault.Vault = .{ .gpa = gpa, .store = &store, .guarded = true };
    var c: Control = .{};
    const progress: vault.Progress = .{ .ctx = &c, .report = Control.report, .cancelled = Control.cancelled };
    const taken = try v.takeCsv("url,username,password\nhttps://a.com,u,p\n", progress);
    try testing.expectEqual(@as(usize, 1), taken.kept);
    try testing.expectEqualStrings("Saving passwords…", c.last);
    c.stop = true;
    const none = try v.takeCsv("url,username,password\nhttps://a.com,u,p\n", progress);
    try testing.expectEqual(@as(usize, 0), none.kept + none.skipped);
    const rows = try vault.parseCsv(gpa, "a,b\nc,d\n", progress);
    defer vault.freeRows(gpa, rows);
    try testing.expectEqual(@as(usize, 0), rows.len);
}

// MARK: through a test Kea

const objc = @import("nanoui").objc;
const Kea = @import("../app/kea.zig").Kea;

/// What a page's reply handler was answered with.
const Got = struct {
    calls: usize = 0,
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    err: [32]u8 = undefined,
    err_len: usize = 0,

    fn answered(g: *Got, value: ?objc.Object, _: ?objc.Object) void {
        g.calls += 1;
        const v = value orelse return;
        g.kind_len = copy(&g.kind, v, "kind");
        g.err_len = copy(&g.err, v, "error");
    }

    fn copy(buf: *[32]u8, dict: objc.Object, key: []const u8) usize {
        const s = objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)}) orelse return 0;
        const text = objc.fromNSString(s);
        const n = @min(text.len, buf.len);
        @memcpy(buf[0..n], text[0..n]);
        return n;
    }

    fn kindText(g: *const Got) []const u8 {
        return g.kind[0..g.kind_len];
    }
    fn errText(g: *const Got) []const u8 {
        return g.err[0..g.err_len];
    }
};
const ReplyBlock = objc.Block(Got, &.{ ?objc.Object, ?objc.Object });

fn ask(p: *passkeys.Passkeys, body: []const u8, caller: passkeys.Caller) !Got {
    var got: Got = .{};
    var block = ReplyBlock.init(&got, Got.answered);
    const answer = passkeys.Answer.take(@ptrCast(&block)).?;
    p.perform(try @import("../data/json.zig").decode(std.json.Value, gpa, body), caller, answer);
    return got;
}

test "a test Kea's vault and passkeys never reach the Mac" {
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    const kea = try Kea.create(gpa, null, .{ .root = t.root, .suite = t.suite, .headless = true });
    defer kea.destroy();
    try testing.expect(vault.Vault.of(kea).guarded);
    kea.prefs.passkeys = true;
    var p = passkeys.Passkeys.init(kea);
    defer p.deinit();
    const secure: passkeys.Caller = .{ .scheme = "HTTPS", .host = "Example.com", .main_frame = true, .page_host = "example.com", .window = null, .web = null };
    // A made-up passkey, made through the real checks and reply path.
    const made = try ask(&p, "{\"kind\":\"create\",\"token\":\"t\",\"challenge\":\"Y2hhbGxlbmdl\",\"rp\":{\"id\":null},\"user\":{\"id\":\"dXNlcg\",\"name\":\"kea\",\"displayName\":\"\"},\"algorithms\":[-7],\"authenticatorAttachment\":\"platform\"}", secure);
    try testing.expectEqual(@as(usize, 1), made.calls);
    try testing.expectEqualStrings("create", made.kindText());
    const signed = try ask(&p, "{\"kind\":\"get\",\"token\":\"u\",\"challenge\":\"Yw\",\"rpId\":\"example.com\",\"allowCredentials\":[]}", secure);
    try testing.expectEqualStrings("get", signed.kindText());
    // Refusals, as Swift words them.
    const plain = try ask(&p, "{\"kind\":\"get\",\"challenge\":\"Yw\"}", .{ .scheme = "http", .host = "example.com", .main_frame = true, .page_host = null, .window = null, .web = null });
    try testing.expectEqualStrings("NotAllowedError", plain.errText());
    const other = try ask(&p, "{\"kind\":\"get\",\"challenge\":\"Yw\",\"rpId\":\"other.com\"}", secure);
    try testing.expectEqualStrings("SecurityError", other.errText());
    const empty = try ask(&p, "{\"kind\":\"get\",\"challenge\":\"\"}", secure);
    try testing.expectEqualStrings("TypeError", empty.errText());
    const under = try ask(&p, "{\"kind\":\"get\",\"conditional\":true,\"challenge\":\"Yw\"}", secure);
    try testing.expectEqualStrings("Wait", under.errText());
    kea.prefs.passkeys = false;
    const off = try ask(&p, "{\"kind\":\"create\",\"challenge\":\"Yw\"}", secure);
    try testing.expectEqualStrings("NotAllowedError", off.errText());
}
