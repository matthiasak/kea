//! What goes back to a page for a passkey request (Passkeys.swift "answers",
//! "keys derived from a passkey", "checks", "bytes"): replies as JSON-shaped
//! structs, the made-up credential of a test run, the sealed PRF results,
//! and the relying-party check. No AppKit here.
const std = @import("std");
const json = @import("../data/json.zig");
const cbor = @import("passkeys_cbor.zig");

const P256 = std.crypto.ecc.P256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
const b64 = std.base64.url_safe_no_pad;

extern "c" fn arc4random_buf(buf: [*]u8, n: usize) void;

/// A passkey the Mac holds for the site whose page waits for one.
pub const Offered = struct {
    /// The credential id, raw bytes.
    id: []u8,
    /// The account's name, as the site made it.
    name: []u8,
    /// Where it is kept: iCloud Keychain, a password app.
    provider: ?[]u8 = null,

    pub fn deinit(o: Offered, gpa: std.mem.Allocator) void {
        gpa.free(o.id);
        gpa.free(o.name);
        if (o.provider) |p| gpa.free(p);
    }

    pub fn clone(o: Offered, gpa: std.mem.Allocator) !Offered {
        const id = try gpa.dupe(u8, o.id);
        errdefer gpa.free(id);
        const n = try gpa.dupe(u8, o.name);
        errdefer gpa.free(n);
        return .{ .id = id, .name = n, .provider = if (o.provider) |p| try gpa.dupe(u8, p) else null };
    }

    pub fn eql(a: Offered, b: Offered) bool {
        const same_provider = if (a.provider) |p| (if (b.provider) |q| std.mem.eql(u8, p, q) else false) else b.provider == null;
        return std.mem.eql(u8, a.id, b.id) and std.mem.eql(u8, a.name, b.name) and same_provider;
    }
};

pub const Sealed = struct { key: []const u8, box: []const u8 };

pub const Prf = struct {
    enabled: ?bool = null,
    sealed: ?Sealed = null,
};

/// A reply as the page's script reads it; nulls are left out.
pub const Reply = struct {
    @"error": ?[]const u8 = null,
    message: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    id: ?[]const u8 = null,
    clientDataJSON: ?[]const u8 = null,
    authenticatorData: ?[]const u8 = null,
    signature: ?[]const u8 = null,
    userHandle: ?[]const u8 = null,
    attestationObject: ?[]const u8 = null,
    transports: ?[]const []const u8 = null,
    attachment: ?[]const u8 = null,
    publicKeyAlgorithm: ?i64 = null,
    publicKey: ?[]const u8 = null,
    prf: ?Prf = null,
};

pub fn failure(name: []const u8, message: []const u8) Reply {
    return .{ .@"error" = name, .message = message };
}

// MARK: bytes

/// Base64url without padding (`Passkeys.text`), on `a`.
pub fn text(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try a.alloc(u8, b64.Encoder.calcSize(bytes.len));
    _ = b64.Encoder.encode(out, bytes);
    return out;
}

/// `Passkeys.data`: base64 of either alphabet, padding optional; null when
/// it isn't.
pub fn data(a: std.mem.Allocator, value: []const u8) ?[]u8 {
    const url_text = a.dupe(u8, std.mem.trimEnd(u8, value, "=")) catch return null;
    defer a.free(url_text);
    for (url_text) |*c| c.* = switch (c.*) {
        '+' => '-',
        '/' => '_',
        else => c.*,
    };
    const n = b64.Decoder.calcSizeForSlice(url_text) catch return null;
    const out = a.alloc(u8, n) catch return null;
    b64.Decoder.decode(out, url_text) catch {
        a.free(out);
        return null;
    };
    return out;
}

// MARK: answers

pub fn assertionReply(a: std.mem.Allocator, id: []const u8, client_data: []const u8, auth_data: []const u8, signature: []const u8, user: []const u8, attachment: []const u8) !Reply {
    return .{
        .kind = "get",
        .id = try text(a, id),
        .clientDataJSON = try text(a, client_data),
        .authenticatorData = try text(a, auth_data),
        .signature = try text(a, signature),
        .userHandle = try text(a, user),
        .attachment = attachment,
    };
}

pub fn registrationReply(a: std.mem.Allocator, id: []const u8, client_data: []const u8, attestation: []const u8, transports: []const []const u8, attachment: []const u8) !Reply {
    var reply: Reply = .{
        .kind = "create",
        .id = try text(a, id),
        .clientDataJSON = try text(a, client_data),
        .attestationObject = try text(a, attestation),
        .transports = transports,
        .attachment = attachment,
    };
    if (cbor.authenticatorData(attestation)) |auth| {
        reply.authenticatorData = try text(a, auth);
        if (try cbor.publicKey(a, auth)) |key| {
            reply.publicKeyAlgorithm = key.algorithm;
            if (key.der) |der| reply.publicKey = try text(a, der);
        }
    }
    return reply;
}

/// `rehearsalID`: 0…15.
pub const rehearsal_id = blk: {
    var id: [16]u8 = undefined;
    for (&id, 0..) |*b, i| b.* = i;
    break :blk id;
};

/// A test run's credential, in the shape the sheet gives, made up from the
/// request: a P-256 key and all, with nothing signed (`rehearsal`). On `a`
/// (an arena: pieces aren't freed one by one).
pub fn rehearsal(a: std.mem.Allocator, kind: []const u8, rp: []const u8, origin: []const u8, challenge: []const u8) !Reply {
    _ = rp;
    const client = try std.fmt.allocPrint(a, "{{\"type\":\"webauthn.{s}\",\"challenge\":\"{s}\",\"origin\":\"{s}\",\"crossOrigin\":false}}", .{ kind, try text(a, challenge), origin });
    const get = std.mem.eql(u8, kind, "get");
    var auth: std.ArrayList(u8) = .empty;
    try auth.appendNTimes(a, 0, 32);
    try auth.append(a, if (get) 0x05 else 0x45);
    try auth.appendNTimes(a, 0, 4);
    if (get) return assertionReply(a, &rehearsal_id, client, auth.items, &.{ 0x30, 0 }, "user", "platform");
    try auth.appendNTimes(a, 0, 16);
    try auth.appendSlice(a, &.{ 0, rehearsal_id.len });
    try auth.appendSlice(a, &rehearsal_id);
    try auth.appendSlice(a, &.{ 0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20 });
    try auth.appendNTimes(a, 1, 32);
    try auth.appendSlice(a, &.{ 0x22, 0x58, 0x20 });
    try auth.appendNTimes(a, 2, 32);
    var object: std.ArrayList(u8) = .empty;
    try object.appendSlice(a, &.{ 0xA3, 0x63 });
    try object.appendSlice(a, "fmt");
    try object.append(a, 0x64);
    try object.appendSlice(a, "none");
    try object.append(a, 0x67);
    try object.appendSlice(a, "attStmt");
    try object.append(a, 0xA0);
    try object.append(a, 0x68);
    try object.appendSlice(a, "authData");
    try object.appendSlice(a, &.{ 0x59, @intCast(auth.items.len >> 8), @intCast(auth.items.len & 0xFF) });
    try object.appendSlice(a, auth.items);
    return registrationReply(a, &rehearsal_id, client, object.items, &.{ "hybrid", "internal" }, "platform");
}

/// The PRF first output a test run's made-up passkey derives:
/// SHA-256 of "rehearsal".
pub fn rehearsalFirst() [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("rehearsal", &out, .{});
    return out;
}

// MARK: keys derived from a passkey

/// The one-time public key the page's script made for this request
/// (`pageKey`): an uncompressed P-256 point, checked.
pub fn pageKey(a: std.mem.Allocator, prf_key: ?[]const u8) ?[65]u8 {
    const raw = data(a, prf_key orelse return null) orelse return null;
    defer a.free(raw);
    if (raw.len != 65) return null;
    _ = P256.fromSec1(raw) catch return null;
    return raw[0..65].*;
}

/// `prfReply`: `enabled` only answers a registration. The results go sealed
/// for the page's one-time key (ECDH P-256, HKDF-SHA256 with info
/// "kea-prf", AES-GCM combined); without that key, none go. On `a`.
pub fn prfReply(a: std.mem.Allocator, enabled: ?bool, first: ?[]const u8, second: ?[]const u8, page: ?[65]u8) Prf {
    var reply: Prf = .{ .enabled = enabled };
    const f = first orelse return reply;
    const key = page orelse return reply;
    const mine = randomScalar();
    var nonce: [Aes.nonce_length]u8 = undefined;
    arc4random_buf(&nonce, nonce.len);
    reply.sealed = seal(a, f, second, key, mine, nonce) catch return reply;
    return reply;
}

fn randomScalar() [32]u8 {
    while (true) {
        var k: [32]u8 = undefined;
        arc4random_buf(&k, k.len);
        const s = P256.scalar.Scalar.fromBytes(k, .big) catch continue;
        if (!s.isZero()) return k;
    }
}

/// The sealing itself, with the key pair half and nonce given.
pub fn seal(a: std.mem.Allocator, first: []const u8, second: ?[]const u8, page: [65]u8, mine: [32]u8, nonce: [Aes.nonce_length]u8) !Sealed {
    const plain = try json.encode(a, .{ .first = try text(a, first), .second = if (second) |s| try text(a, s) else null });
    const key = try sharedKey(page, mine);
    const box = try a.alloc(u8, nonce.len + plain.len + Aes.tag_length);
    box[0..nonce.len].* = nonce;
    Aes.encrypt(box[nonce.len..][0..plain.len], box[nonce.len + plain.len ..][0..Aes.tag_length], plain, "", nonce, key);
    const mine_public = (try P256.basePoint.mul(mine, .big)).toUncompressedSec1();
    return .{ .key = try text(a, &mine_public), .box = try text(a, box) };
}

/// ECDH's x coordinate through HKDF-SHA256 (empty salt, info "kea-prf").
pub fn sharedKey(theirs: [65]u8, mine: [32]u8) ![32]u8 {
    const point = try (try P256.fromSec1(&theirs)).mul(mine, .big);
    const x = point.affineCoordinates().x.toBytes(.big);
    const prk = Hkdf.extract("", &x);
    var key: [32]u8 = undefined;
    Hkdf.expand(&key, "kea-prf", prk);
    return key;
}

/// The page's side of it (`unseal` in the page script): the results JSON,
/// opened with the page's private half. On `a`.
pub fn open(a: std.mem.Allocator, sealed: Sealed, page_secret: [32]u8) ![]u8 {
    const their_raw = data(a, sealed.key) orelse return error.Encoding;
    if (their_raw.len != 65) return error.Encoding;
    const key = try sharedKey(their_raw[0..65].*, page_secret);
    const box = data(a, sealed.box) orelse return error.Encoding;
    if (box.len < Aes.nonce_length + Aes.tag_length) return error.Encoding;
    const body = box[Aes.nonce_length .. box.len - Aes.tag_length];
    const plain = try a.alloc(u8, body.len);
    try Aes.decrypt(plain, body, box[box.len - Aes.tag_length ..][0..Aes.tag_length].*, "", box[0..Aes.nonce_length].*, key);
    return plain;
}

// MARK: checks

/// The relying party is the page's own host, or a domain above it that is
/// still a site of its own: never another site, never an address, never a
/// public suffix (`fits`). Without the suffix list, the host only.
pub fn fits(rp: []const u8, host: []const u8, is_suffix: ?*const fn ([]const u8) bool) bool {
    if (std.mem.eql(u8, rp, host)) return true;
    const address = std.mem.indexOfScalar(u8, host, ':') != null or for (host) |c| {
        if (!std.ascii.isDigit(c) and c != '.') break false;
    } else true;
    if (address or host.len <= rp.len + 1 or !std.mem.endsWith(u8, host, rp) or host[host.len - rp.len - 1] != '.') return false;
    if (std.mem.indexOfScalar(u8, rp, '.') == null) return false;
    const suffix = is_suffix orelse return false;
    return !suffix(rp);
}
