//! What unlocks a Mozilla browser's saved logins (`Mozilla` in Import.swift,
//! "passwords" and "the little that reads DER"): key4.db's check and wrapped
//! key, each DER around a ciphertext — PBES2 (PBKDF2-HMAC-SHA256 then
//! AES-256-CBC) in current Firefox, PBE-SHA1-3DES before — and each login
//! field, base64 DER around AES-256-CBC or 3DES-CBC. Only the empty primary
//! password is tried; with another set the check fails and the person is
//! told to export instead.
const std = @import("std");
const cc = @import("../sys/commoncrypto.zig");
const sqlite = @import("../sys/sqlite.zig");
const files = @import("files.zig");
const Sha1 = std.crypto.hash.Sha1;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

const aes256_cbc = "2.16.840.1.101.3.4.1.42";
const pbes2 = "1.2.840.113549.1.5.13";
const pbe_sha1_3des = "1.2.840.113549.1.12.5.1.3";

/// The key that unlocks the logins, from key4.db: the empty primary
/// password checked against the browser's own record first, then the key
/// itself unwrapped from nssPrivate. `error.PrimaryPassword` when the check
/// fails. On `a`.
pub fn masterKey(a: std.mem.Allocator, key4: []const u8) ![]u8 {
    var copy = try files.Snapshot.init(a, key4);
    defer copy.deinit();
    const db = try sqlite.Db.open(copy.file, sqlite.open_readonly);
    defer db.close();

    // The global salt, and the check the empty password has to pass.
    var global_salt: []const u8 = &.{};
    var item2: []const u8 = &.{};
    if (db.prepare("SELECT item1, item2 FROM metaData WHERE id = 'password'")) |meta| {
        defer meta.finalize();
        if (meta.step()) {
            global_salt = try a.dupe(u8, meta.blob(0));
            item2 = try a.dupe(u8, meta.blob(1));
        }
    } else |_| {}
    if (global_salt.len == 0 or item2.len == 0) return error.Unreadable;
    const password = "";
    const check = unwrap(a, item2, global_salt, password) orelse return error.PrimaryPassword;
    if (!std.mem.startsWith(u8, check, "password-check")) return error.PrimaryPassword;

    // The wrapped key, in the nssPrivate row NSS marks with a fixed id.
    const wanted_id = [_]u8{0xf8} ++ @as([14]u8, @splat(0)) ++ [_]u8{0x01};
    var a11: []const u8 = &.{};
    if (db.prepare("SELECT a11, a102 FROM nssPrivate")) |priv| {
        defer priv.finalize();
        while (priv.step()) {
            if (std.mem.eql(u8, priv.blob(1), &wanted_id)) {
                a11 = try a.dupe(u8, priv.blob(0));
                break;
            }
        }
    } else |_| {}
    if (a11.len == 0) return error.Unreadable;
    return unwrap(a, a11, global_salt, password) orelse error.Unreadable;
}

/// One encrypted login field: base64 around a DER SEQUENCE of the key's id,
/// the cipher with its IV, and the ciphertext. Newer profiles use
/// AES-256-CBC, older ones 3DES-CBC; the DER says which. On `a`.
pub fn decryptLogin(a: std.mem.Allocator, b64: []const u8, master: []const u8) ?[]u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return null;
    const blob = a.alloc(u8, n) catch return null;
    dec.decode(blob, b64) catch return null;
    const outer = tlv(blob, 0) orelse return null;
    var parts: [3]Tlv = undefined;
    if (items(outer.body, &parts) != 3) return null;
    var cipher: [2]Tlv = undefined;
    if (items(parts[1].body, &cipher) != 2) return null;
    const iv = cipher[1].body;
    const ct = parts[2].body;
    var oid_buf: [64]u8 = undefined;
    const plain = if (std.mem.eql(u8, oid(&oid_buf, cipher[0].body), aes256_cbc)) blk: {
        var real: [16]u8 = undefined;
        const full: []const u8 = if (iv.len == 14) iv14(&real, iv) else iv;
        break :blk decryptCbc(a, ct, cc.kCCAlgorithmAES128, master, full, cc.kCCBlockSizeAES128);
    } else decryptCbc(a, ct, cc.kCCAlgorithm3DES, master[0..@min(24, master.len)], iv, cc.kCCBlockSize3DES);
    const p = plain orelse return null;
    return if (std.unicode.utf8ValidateSlice(p)) p else null;
}

/// NSS keeps fourteen bytes of IV behind a DER octet-string header.
fn iv14(out: *[16]u8, body: []const u8) []const u8 {
    out[0] = 0x04;
    out[1] = 0x0e;
    @memcpy(out[2..], body[0..14]);
    return out;
}

/// A key4.db entry — the check or the wrapped key — unwrapped with
/// `password`. On `a`.
pub fn unwrap(a: std.mem.Allocator, blob: []const u8, global_salt: []const u8, password: []const u8) ?[]u8 {
    const outer = tlv(blob, 0) orelse return null;
    var top: [2]Tlv = undefined;
    if (items(outer.body, &top) != 2) return null;
    var algo: [2]Tlv = undefined;
    if (items(top[0].body, &algo) != 2) return null;
    var oid_buf: [64]u8 = undefined;
    const algo_oid = oid(&oid_buf, algo[0].body);
    const ciphertext = top[1].body;

    if (std.mem.eql(u8, algo_oid, pbes2)) {
        // NSS feeds PBKDF2 the SHA-1 of the salt and the password
        // (`sftkdb_passwordToKey`). Import.swift:1077 takes SHA-256 here,
        // which no real key4.db unwraps with.
        var params: [2]Tlv = undefined;
        if (items(algo[1].body, &params) != 2) return null;
        var kdf: [2]Tlv = undefined;
        if (items(params[0].body, &kdf) != 2) return null;
        var kp: [4]Tlv = undefined;
        if (items(kdf[1].body, &kp) < 2) return null;
        const entry_salt = kp[0].body;
        // A corrupt file's count could be anything; NSS writes 10,000.
        if (kp[1].body.len > 4) return null;
        const rounds = integer(kp[1].body);
        if (rounds < 1 or rounds > 10_000_000 or entry_salt.len == 0) return null;
        var enc: [2]Tlv = undefined;
        if (items(params[1].body, &enc) != 2 or enc[1].body.len != 14) return null;
        var ck: [20]u8 = undefined;
        var h = Sha1.init(.{});
        h.update(global_salt);
        h.update(password);
        h.final(&ck);
        var key: [32]u8 = undefined;
        if (cc.CCKeyDerivationPBKDF(cc.kCCPBKDF2, &ck, ck.len, entry_salt.ptr, entry_salt.len, cc.kCCPRFHmacAlgSHA256, @intCast(rounds), &key, key.len) != cc.kCCSuccess) return null;
        var iv: [16]u8 = undefined;
        return decryptCbc(a, ciphertext, cc.kCCAlgorithmAES128, &key, iv14(&iv, enc[1].body), cc.kCCBlockSizeAES128);
    }
    if (std.mem.eql(u8, algo_oid, pbe_sha1_3des)) {
        // A chain of SHA-1 and HMAC-SHA-1 over the salts ends in the 3DES
        // key and its IV.
        var params: [2]Tlv = undefined;
        if (items(algo[1].body, &params) < 1) return null;
        const entry_salt = params[0].body;
        var hp: [20]u8 = undefined;
        var h1 = Sha1.init(.{});
        h1.update(global_salt);
        h1.update(password);
        h1.final(&hp);
        var chp: [20]u8 = undefined;
        var h2 = Sha1.init(.{});
        h2.update(&hp);
        h2.update(entry_salt);
        h2.final(&chp);
        var pes: [20]u8 = @splat(0);
        @memcpy(pes[0..@min(20, entry_salt.len)], entry_salt[0..@min(20, entry_salt.len)]);
        var k: [40]u8 = undefined;
        var tk: [20]u8 = undefined;
        hmac(k[0..20], &chp, &.{ &pes, entry_salt });
        hmac(&tk, &chp, &.{&pes});
        hmac(k[20..40], &chp, &.{ &tk, entry_salt });
        return decryptCbc(a, ciphertext, cc.kCCAlgorithm3DES, k[0..24], k[32..40], cc.kCCBlockSize3DES);
    }
    return null;
}

fn hmac(out: *[20]u8, key: []const u8, parts: []const []const u8) void {
    var m = HmacSha1.init(key);
    for (parts) |p| m.update(p);
    m.final(out);
}

/// CBC decryption with PKCS#7 padding stripped, for AES or 3DES. On `a`.
pub fn decryptCbc(a: std.mem.Allocator, data: []const u8, algorithm: u32, key: []const u8, iv: []const u8, block: usize) ?[]u8 {
    // CommonCrypto reads a whole block of IV, whatever the slice holds.
    if (data.len == 0 or iv.len != block) return null;
    const out = a.alloc(u8, data.len + block) catch return null;
    var moved: usize = 0;
    if (cc.CCCrypt(cc.kCCDecrypt, algorithm, cc.kCCOptionPKCS7Padding, key.ptr, key.len, iv.ptr, data.ptr, data.len, out.ptr, out.len, &moved) != cc.kCCSuccess) return null;
    return out[0..moved];
}

// MARK: - the little that reads DER

pub const Tlv = struct { tag: u8, body: []const u8, next: usize };

/// One DER element at an offset: its tag, its content, and where the next
/// begins. Enough to walk NSS's key and login structures, no more.
pub fn tlv(b: []const u8, i: usize) ?Tlv {
    if (i + 1 >= b.len) return null;
    const tag = b[i];
    var j = i + 1;
    var len: usize = b[j];
    j += 1;
    if (len & 0x80 != 0) {
        // At most four bytes of length: nothing in key4.db is longer.
        const n = len & 0x7f;
        if (n == 0 or n > 4 or j + n > b.len) return null;
        len = 0;
        for (0..n) |_| {
            len = (len << 8) | b[j];
            j += 1;
        }
    }
    if (j + len > b.len) return null;
    return .{ .tag = tag, .body = b[j .. j + len], .next = j + len };
}

/// The elements of a constructed value, in order, into `out`; how many there
/// were (counted past `out.len`, as Swift's array would hold them).
pub fn items(body: []const u8, out: []Tlv) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (tlv(body, i)) |one| : (i = one.next) {
        if (n < out.len) out[n] = one;
        n += 1;
    }
    return n;
}

/// An object identifier as its dotted string, in `buf`.
pub fn oid(buf: []u8, body: []const u8) []const u8 {
    if (body.len == 0) return "";
    var w: std.Io.Writer = .fixed(buf);
    w.print("{d}.{d}", .{ body[0] / 40, body[0] % 40 }) catch return "";
    var value: u64 = 0;
    for (body[1..]) |byte| {
        value = (value << 7) | (byte & 0x7f);
        if (byte & 0x80 == 0) {
            w.print(".{d}", .{value}) catch return "";
            value = 0;
        }
    }
    return w.buffered();
}

/// An unsigned integer, as key4.db's are small.
pub fn integer(body: []const u8) u64 {
    var v: u64 = 0;
    for (body) |b| v = (v << 8) | b;
    return v;
}
