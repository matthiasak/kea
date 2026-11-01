//! The sync store's keys (v2): one random store key, wrapped once for each
//! way in — a passphrase, or an account key kept in the keychain — and
//! every object in the store sealed under keys derived from it, bound to its
//! path: `KEAS` 2 ‖ flags ‖ key id ‖ length ‖ digest, nonce, AES-GCM body, tag.
const std = @import("std");
const json = @import("../data/json.zig");
const core = @import("core.zig");
const keychain = @import("../sys/keychain.zig");
const cc = @import("../sys/commoncrypto.zig");

const Aes = std.crypto.aead.aes_gcm.Aes256Gcm;
const Blake3 = std.crypto.hash.Blake3;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const eql = std.crypto.timing_safe.eql;
const Allocator = std.mem.Allocator;

pub const StoreKey = [32]u8;
pub const AccountKey = [32]u8;
pub const KeyMode = enum { password, account_key };

pub const Subkeys = struct {
    enc_key: [32]u8,
    mac_key: [32]u8,
    digest_key: [32]u8,
    /// Lowercase hex of the key id's first 16 bytes.
    key_id: [32]u8,
    key_id_raw: [8]u8,
};

fn kdf(comptime context: []const u8, key: []const u8) [32]u8 {
    var h = Blake3.initKdf(context, .{});
    h.update(key);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn deriveSubkeys(mk: StoreKey) Subkeys {
    const id = kdf("kea.sync.v2.key_id", &mk);
    return .{
        .enc_key = kdf("kea.sync.v2.aead.aes256gcm", &mk),
        .mac_key = kdf("kea.sync.v2.manifest.hmac", &mk),
        .digest_key = kdf("kea.sync.v2.content.blake3", &mk),
        .key_id = std.fmt.bytesToHex(id[0..16].*, .lower),
        .key_id_raw = id[0..8].*,
    };
}

/// Which account key a slot is for: 16 lowercase hex.
pub fn accountKeyId(ak: AccountKey) [16]u8 {
    return std.fmt.bytesToHex(kdf("kea.sync.v2.ak_id", &ak)[0..8].*, .lower);
}

pub fn randomKey() [32]u8 {
    var k: [32]u8 = undefined;
    std.c.arc4random_buf(&k, k.len);
    return k;
}

/// Keyed BLAKE3 of `bytes` under the store's digest key: object ids, lowercase hex.
pub fn oidOf(sk: *const Subkeys, bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Blake3.hash(bytes, &d, .{ .key = sk.digest_key });
    return std.fmt.bytesToHex(d, .lower);
}

// MARK: objects

pub const header_len = 50;
const min_len = header_len + Aes.nonce_length + Aes.tag_length;

fn aad(gpa: Allocator, header: []const u8, path: []const u8) ![]u8 {
    return std.mem.concat(gpa, u8, &.{ header, path });
}

/// `plain` compressed (when not empty) and sealed under `sk`, bound to
/// `logical_path`. On `gpa`.
pub fn sealObject(gpa: Allocator, plain: []const u8, sk: Subkeys, logical_path: []const u8) error{ Damaged, OutOfMemory }![]u8 {
    if (plain.len > std.math.maxInt(u32)) return error.Damaged;
    const body = if (plain.len > 0) try core.compress(gpa, plain) else try gpa.alloc(u8, 0);
    defer gpa.free(body);
    const out = try gpa.alloc(u8, min_len + body.len);
    errdefer gpa.free(out);
    const h = out[0..header_len];
    @memcpy(h[0..4], "KEAS");
    h[4] = 2;
    h[5] = if (plain.len > 0) 1 else 0;
    @memcpy(h[6..14], &sk.key_id_raw);
    std.mem.writeInt(u32, h[14..18], @intCast(plain.len), .little);
    Blake3.hash(plain, h[18..50], .{ .key = sk.digest_key });
    const nonce = out[header_len..][0..Aes.nonce_length];
    std.c.arc4random_buf(nonce, nonce.len);
    const ad = try aad(gpa, h, logical_path);
    defer gpa.free(ad);
    Aes.encrypt(out[header_len + Aes.nonce_length ..][0..body.len], out[out.len - Aes.tag_length ..][0..Aes.tag_length], body, ad, nonce.*, sk.enc_key);
    return out;
}

/// What `sealObject` sealed at `logical_path`; `WrongKey` when another store
/// key sealed it. On `gpa`.
pub fn openObject(gpa: Allocator, wire: []const u8, sk: Subkeys, logical_path: []const u8) error{ WrongKey, Damaged, OutOfMemory }![]u8 {
    if (wire.len < min_len or !std.mem.eql(u8, wire[0..4], "KEAS") or wire[4] != 2) return error.Damaged;
    const h = wire[0..header_len];
    if (!eql([8]u8, h[6..14].*, sk.key_id_raw)) return error.WrongKey;
    const body = wire[header_len + Aes.nonce_length .. wire.len - Aes.tag_length];
    const packed_ = try gpa.alloc(u8, body.len);
    defer gpa.free(packed_);
    const ad = try aad(gpa, h, logical_path);
    defer gpa.free(ad);
    Aes.decrypt(packed_, body, wire[wire.len - Aes.tag_length ..][0..Aes.tag_length].*, ad, wire[header_len..][0..Aes.nonce_length].*, sk.enc_key) catch return error.Damaged;
    const out = if (h[5] & 1 != 0) try core.decompress(gpa, packed_) else try gpa.dupe(u8, packed_);
    errdefer gpa.free(out);
    var digest: [32]u8 = undefined;
    Blake3.hash(out, &digest, .{ .key = sk.digest_key });
    if (out.len != std.mem.readInt(u32, h[14..18], .little) or !eql([32]u8, digest, h[18..50].*)) return error.Damaged;
    return out;
}

// MARK: keyring

pub const PasswordSlot = struct {
    salt: core.Bytes,
    iterations: u32 = core.iterations,
    /// nonce ‖ AES-GCM(store key, aad "kea-v2-pw-slot:" ‖ store id) ‖ tag.
    wrapped_mk: core.Bytes,
};

pub const AccountSlot = struct {
    id: []const u8,
    /// The Mac that enrolled it.
    label: []const u8,
    /// nonce ‖ AES-GCM(store key, aad "kea-v2-ak-slot:" ‖ store id ‖ ":" ‖ id) ‖ tag.
    wrapped_mk: core.Bytes,
};

/// `kea/v2/keyring.json`, its `.bak`, and a copy in every head.
pub const Keyring = struct {
    version: u8 = 2,
    store_id: json.Uuid,
    key_id: []const u8,
    created_at: json.SwiftDate,
    password_slot: ?PasswordSlot = null,
    account_slots: []const AccountSlot = &.{},
    /// HMAC-SHA256 under the mac key of the sorted JSON with `mac` "", hex.
    mac: []const u8 = "",
};

pub const UnlockError = error{ WrongPassphrase, NoPasswordSlot, WrongAccountKey, Damaged, OutOfMemory };

fn wrap(a: Allocator, mk: StoreKey, kek: [32]u8, ad: []const u8) ![]u8 {
    const out = try a.alloc(u8, Aes.nonce_length + mk.len + Aes.tag_length);
    std.c.arc4random_buf(out.ptr, Aes.nonce_length);
    Aes.encrypt(out[Aes.nonce_length..][0..mk.len], out[Aes.nonce_length + mk.len ..][0..Aes.tag_length], &mk, ad, out[0..Aes.nonce_length].*, kek);
    return out;
}

fn unwrap(wrapped: []const u8, kek: [32]u8, ad: []const u8) ?StoreKey {
    if (wrapped.len != Aes.nonce_length + 32 + Aes.tag_length) return null;
    var mk: StoreKey = undefined;
    Aes.decrypt(&mk, wrapped[Aes.nonce_length..][0..32], wrapped[Aes.nonce_length + 32 ..][0..Aes.tag_length].*, ad, wrapped[0..Aes.nonce_length].*, kek) catch return null;
    return mk;
}

fn passwordKek(pass: []const u8, salt: []const u8, iterations: u32) [32]u8 {
    var out: [32]u8 = undefined;
    _ = cc.CCKeyDerivationPBKDF(cc.kCCPBKDF2, pass.ptr, pass.len, salt.ptr, salt.len, cc.kCCPRFHmacAlgSHA256, iterations, &out, out.len);
    return out;
}

fn pwAad(a: Allocator, ring: *const Keyring) ![]u8 {
    return std.fmt.allocPrint(a, "kea-v2-pw-slot:{f}", .{ring.store_id});
}

fn akAad(a: Allocator, ring: *const Keyring, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "kea-v2-ak-slot:{f}:{s}", .{ ring.store_id, id });
}

fn macOf(a: Allocator, ring: Keyring, sk: *const Subkeys) error{OutOfMemory}![64]u8 {
    var bare = ring;
    bare.mac = "";
    const bytes = json.encodeSorted(a, bare) catch return error.OutOfMemory;
    defer a.free(bytes);
    var m: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&m, bytes, &sk.mac_key);
    return std.fmt.bytesToHex(m, .lower);
}

fn seal(a: Allocator, ring: *Keyring, sk: *const Subkeys) !void {
    ring.mac = try a.dupe(u8, &try macOf(a, ring.*, sk));
}

/// `Damaged` unless `ring` was written by a holder of `mk`.
pub fn verifyKeyringMac(a: Allocator, ring: *const Keyring, mk: StoreKey) error{ Damaged, OutOfMemory }!void {
    return verifyWithSubkeys(a, ring, &deriveSubkeys(mk));
}

pub fn verifyWithSubkeys(a: Allocator, ring: *const Keyring, sk: *const Subkeys) error{ Damaged, OutOfMemory }!void {
    const want = try macOf(a, ring.*, sk);
    if (ring.mac.len != 64 or !eql([64]u8, want, ring.mac[0..64].*)) return error.Damaged;
    if (!std.mem.eql(u8, ring.key_id, &sk.key_id)) return error.Damaged;
}

/// A keyring with no slots yet for `mk`, on `a`.
pub fn create(a: Allocator, mk: StoreKey) !Keyring {
    const sk = deriveSubkeys(mk);
    var ring: Keyring = .{ .store_id = json.Uuid.random(), .key_id = try a.dupe(u8, &sk.key_id), .created_at = json.now() };
    try seal(a, &ring, &sk);
    return ring;
}

pub fn createWithPassword(a: Allocator, mk: StoreKey, pass: []const u8) !Keyring {
    var ring = try create(a, mk);
    try enrollPasswordSlot(a, &ring, mk, pass);
    return ring;
}

pub fn createWithAccountKey(a: Allocator, mk: StoreKey, ak: AccountKey, label: []const u8) !Keyring {
    var ring = try create(a, mk);
    try enrollAccountSlot(a, &ring, mk, ak, label);
    return ring;
}

/// The passphrase's slot, replacing any; on `a`.
pub fn enrollPasswordSlot(a: Allocator, ring: *Keyring, mk: StoreKey, pass: []const u8) !void {
    const salt_full = randomKey();
    const salt = salt_full[0..16];
    var kek = passwordKek(pass, salt, core.iterations);
    defer std.crypto.secureZero(u8, &kek);
    ring.password_slot = .{ .salt = .{ .bytes = try a.dupe(u8, salt) }, .wrapped_mk = .{ .bytes = try wrap(a, mk, kek, try pwAad(a, ring)) } };
    try seal(a, ring, &deriveSubkeys(mk));
}

/// `ak`'s slot, replacing one with its id; on `a`.
pub fn enrollAccountSlot(a: Allocator, ring: *Keyring, mk: StoreKey, ak: AccountKey, label: []const u8) !void {
    const id = accountKeyId(ak);
    var slots: std.ArrayList(AccountSlot) = .empty;
    for (ring.account_slots) |s| if (!std.mem.eql(u8, s.id, &id)) try slots.append(a, s);
    try slots.append(a, .{ .id = try a.dupe(u8, &id), .label = try a.dupe(u8, label), .wrapped_mk = .{ .bytes = try wrap(a, mk, ak, try akAad(a, ring, &id)) } });
    ring.account_slots = slots.items;
    try seal(a, ring, &deriveSubkeys(mk));
}

pub fn hasAccountSlot(ring: *const Keyring, ak: AccountKey) bool {
    const id = accountKeyId(ak);
    for (ring.account_slots) |s| if (std.mem.eql(u8, s.id, &id)) return true;
    return false;
}

pub fn unlockWithPassword(a: Allocator, ring: *const Keyring, pass: []const u8) UnlockError!StoreKey {
    const slot = ring.password_slot orelse return error.NoPasswordSlot;
    var kek = passwordKek(pass, slot.salt.bytes, slot.iterations);
    defer std.crypto.secureZero(u8, &kek);
    const ad = try pwAad(a, ring);
    defer a.free(ad);
    var mk = unwrap(slot.wrapped_mk.bytes, kek, ad) orelse return error.WrongPassphrase;
    errdefer std.crypto.secureZero(u8, &mk);
    try verifyKeyringMac(a, ring, mk);
    return mk;
}

pub fn unlockWithAccountKey(a: Allocator, ring: *const Keyring, ak: AccountKey) UnlockError!StoreKey {
    const id = accountKeyId(ak);
    for (ring.account_slots) |s| if (std.mem.eql(u8, s.id, &id)) {
        const ad = try akAad(a, ring, &id);
        defer a.free(ad);
        var mk = unwrap(s.wrapped_mk.bytes, ak, ad) orelse return error.Damaged;
        errdefer std.crypto.secureZero(u8, &mk);
        try verifyKeyringMac(a, ring, mk);
        return mk;
    };
    return error.WrongAccountKey;
}

// MARK: account keys

pub const portable_prefix = "kea-key-v1-";
const b64 = std.base64.url_safe_no_pad;

/// `kea-key-v1-` and 48 base64url characters: the key and 4 bytes of its BLAKE3.
pub fn encodePortableKey(ak: AccountKey) [59]u8 {
    var raw: [36]u8 = undefined;
    @memcpy(raw[0..32], &ak);
    var sum: [32]u8 = undefined;
    Blake3.hash(&ak, &sum, .{});
    @memcpy(raw[32..36], sum[0..4]);
    var out: [59]u8 = undefined;
    @memcpy(out[0..portable_prefix.len], portable_prefix);
    _ = b64.Encoder.encode(out[portable_prefix.len..], &raw);
    return out;
}

pub fn decodePortableKey(text: []const u8) error{InvalidAccountKey}!AccountKey {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len != 59 or !std.mem.startsWith(u8, t, portable_prefix)) return error.InvalidAccountKey;
    var raw: [36]u8 = undefined;
    b64.Decoder.decode(&raw, t[portable_prefix.len..]) catch return error.InvalidAccountKey;
    var sum: [32]u8 = undefined;
    Blake3.hash(raw[0..32], &sum, .{});
    if (!eql([4]u8, sum[0..4].*, raw[32..36].*)) return error.InvalidAccountKey;
    return raw[0..32].*;
}

const service = "app.kea.zig.sync";
const account = "account_key";

/// This Mac's account key: iCloud Keychain's first, then the local one. Never in tests.
pub fn loadKeychainAccountKey(gpa: Allocator) ?AccountKey {
    for ([_]?bool{ true, null }) |synced| {
        const data = keychain.load(gpa, .{ .service = service, .account = account, .synchronizable = synced }) orelse continue;
        defer {
            std.crypto.secureZero(u8, data);
            gpa.free(data);
        }
        if (data.len == 32) return data[0..32].*;
    }
    return null;
}

/// Kept in iCloud Keychain, or — a copy without its entitlement — this Mac's.
pub fn saveKeychainAccountKey(ak: AccountKey) bool {
    for ([_]?bool{ true, null }) |synced| keychain.delete(.{ .service = service, .account = account, .synchronizable = synced });
    const extra: keychain.Extra = .{ .label = "Kea Sync Account Key", .accessible = .when_unlocked };
    if (keychain.save(.{ .service = service, .account = account, .synchronizable = true }, &ak, extra)) return true;
    return keychain.save(.{ .service = service, .account = account, .synchronizable = false }, &ak, extra);
}

/// The kept key, or a new one kept now; null when the keychain refuses.
pub fn ensureKeychainAccountKey(gpa: Allocator) ?AccountKey {
    if (loadKeychainAccountKey(gpa)) |k| return k;
    const k = randomKey();
    return if (saveKeychainAccountKey(k)) k else null;
}

test "objects are bound to their key and path" {
    const gpa = std.testing.allocator;
    const sk = deriveSubkeys(randomKey());
    const plain = "{\"records\":[]} and enough words to squeeze, squeeze, squeeze";
    const wire = try sealObject(gpa, plain, sk, "kea/v2/packs/a.pack");
    defer gpa.free(wire);
    const back = try openObject(gpa, wire, sk, "kea/v2/packs/a.pack");
    defer gpa.free(back);
    try std.testing.expectEqualStrings(plain, back);
    try std.testing.expectError(error.Damaged, openObject(gpa, wire, sk, "kea/v2/packs/b.pack"));
    try std.testing.expectError(error.WrongKey, openObject(gpa, wire, deriveSubkeys(randomKey()), "kea/v2/packs/a.pack"));
    for ([_]usize{ 5, 20, header_len + 3, wire.len - 1 }) |i| {
        wire[i] ^= 1;
        try std.testing.expectError(error.Damaged, openObject(gpa, wire, sk, "kea/v2/packs/a.pack"));
        wire[i] ^= 1;
    }
    try std.testing.expectError(error.Damaged, openObject(gpa, wire[0 .. wire.len - 1], sk, "kea/v2/packs/a.pack"));
    const empty = try sealObject(gpa, "", sk, "e");
    defer gpa.free(empty);
    const none = try openObject(gpa, empty, sk, "e");
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "one store key behind a passphrase and an account key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mk = randomKey();
    const ak = randomKey();
    var ring = try createWithPassword(a, mk, "correct horse");
    try enrollAccountSlot(a, &ring, mk, ak, "Mac B");
    try std.testing.expect(hasAccountSlot(&ring, ak));
    // Mac A by passphrase, Mac B by account key: the same store key.
    const text = try json.encodeSorted(a, ring);
    const read = (try json.decode(Keyring, a, text)).value;
    try std.testing.expectEqual(mk, try unlockWithPassword(a, &read, "correct horse"));
    try std.testing.expectEqual(mk, try unlockWithAccountKey(a, &read, ak));
    try std.testing.expectError(error.WrongPassphrase, unlockWithPassword(a, &read, "wrong horse"));
    try std.testing.expectError(error.WrongAccountKey, unlockWithAccountKey(a, &read, randomKey()));
    // A slot changed without the mac: refused.
    var forged = read;
    forged.account_slots = read.account_slots[0..0];
    try std.testing.expectError(error.Damaged, verifyKeyringMac(a, &forged, mk));
    try std.testing.expectError(error.Damaged, unlockWithPassword(a, &forged, "correct horse"));
    const only_ak = try createWithAccountKey(a, mk, ak, "Mac A");
    try std.testing.expectError(error.NoPasswordSlot, unlockWithPassword(a, &only_ak, "correct horse"));
}

test "portable account keys round-trip and catch a typo" {
    const ak = randomKey();
    var text = encodePortableKey(ak);
    try std.testing.expect(std.mem.startsWith(u8, &text, portable_prefix));
    var padded: [61]u8 = undefined;
    padded[0] = ' ';
    @memcpy(padded[1..60], &text);
    padded[60] = '\n';
    try std.testing.expectEqual(ak, try decodePortableKey(&padded));
    text[30] = if (text[30] == 'A') 'B' else 'A';
    try std.testing.expectError(error.InvalidAccountKey, decodePortableKey(&text));
    try std.testing.expectError(error.InvalidAccountKey, decodePortableKey("kea-key-v1-short"));
}
