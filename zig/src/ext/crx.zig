//! Chrome extensions, straight from the Chrome Web Store (Crx.swift).
//!
//! An extension there is a .crx: a zip with a signed header in front of it,
//! fetched from the public update address every Chromium browser asks. The
//! check that matters: the id is the first sixteen bytes of the SHA-256 of
//! the public key, as letters a to p, so the header must carry a key that
//! hashes to the id asked for and a signature by that key over the zip.
const std = @import("std");
const objc = @import("nanoui").objc;
const urlsession = @import("../sys/urlsession.zig");
const dispatch = @import("../sys/dispatch.zig");
const Parts = @import("../data/url.zig").Parts;

pub const Refused = error{ NotAnID, Download, Empty, NotCrx, UnsignedOrWrong, Unpack };

pub const not_an_id = "That isn't a Chrome Web Store link or extension id";

/// `Refused.errorDescription`; `Download`'s code is added by `fetch`.
pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.NotAnID => not_an_id,
        error.Download => "The Chrome Web Store didn't answer",
        error.Empty => "The Chrome Web Store has nothing for that id — it may have been taken down, or only exist for old versions of Chrome",
        error.NotCrx => "What came back isn't a Chrome extension",
        error.UnsignedOrWrong => "The extension's signature doesn't hold up",
        error.Unpack => "The extension couldn't be unpacked",
        else => @errorName(e),
    };
}

/// The version of Chrome the store is told it is talking to.
pub const chrome_version = "140.0.0.0";

pub const Id = [32]u8;

/// The id's letters: each half-byte is a letter from a (0) to p (15).
pub fn letters(bytes: [16]u8) Id {
    var out: Id = undefined;
    for (bytes, 0..) |b, i| {
        out[2 * i] = 'a' + (b >> 4);
        out[2 * i + 1] = 'a' + (b & 0x0f);
    }
    return out;
}

fn hashID(data: []const u8) Id {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return letters(d[0..16].*);
}

extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;

/// Where a folder really is, every link on the way resolved (gpa-owned).
pub fn realPath(gpa: std.mem.Allocator, folder: []const u8) ![]u8 {
    const z = try gpa.dupeSentinel(u8, folder, 0);
    defer gpa.free(z);
    if (realpath(z, null)) |real| {
        defer std.c.free(real);
        return gpa.dupe(u8, std.mem.span(real));
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(folder)});
    return gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, objc.msg(objc.Object, url, "standardizedURL", .{}), "path", .{})));
}

/// The id Chrome gives a folder loaded unpacked, from its real path.
pub fn unpackedID(gpa: std.mem.Allocator, folder: []const u8) !Id {
    const real = try realPath(gpa, folder);
    defer gpa.free(real);
    return hashID(real);
}

/// `id(in:)`: thirty-two letters from a to p, wherever they are — a bare id,
/// a store link, an old chrome.google.com/webstore link. Lowercased.
pub fn id(text: []const u8) ?Id {
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isAlphabetic(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
        if (i - start != 32) continue;
        var out: Id = undefined;
        for (text[start..i], 0..) |c, k| {
            out[k] = std.ascii.toLower(c);
            if (out[k] > 'p') break;
        } else return out;
    }
    return null;
}

fn idAt(s: []const u8) ?Id {
    if (s.len < 32 or (s.len > 32 and s[32] != '/')) return null;
    for (s[0..32]) |c| if (c < 'a' or c > 'p') return null;
    return s[0..32].*;
}

/// `storeID(of:)`: the id in a store page's /detail/ path and nowhere else
/// — only on the store itself, over https, with nothing before its host.
pub fn storeID(url: []const u8) ?Id {
    const p = Parts.parse(url) orelse return null;
    if (!std.ascii.eqlIgnoreCase(p.scheme orelse "", "https") or p.user != null or p.password != null) return null;
    const host = p.host orelse "";
    const prefix = if (std.ascii.eqlIgnoreCase(host, "chromewebstore.google.com"))
        "/detail/"
    else if (std.ascii.eqlIgnoreCase(host, "chrome.google.com"))
        "/webstore/detail/"
    else
        return null;
    if (!std.mem.startsWith(u8, p.path, prefix)) return null;
    const rest = p.path[prefix.len..];
    // `(?:[^/]+/)?([a-p]{32})(?:/.*)?$`, the optional name tried first.
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| if (slash > 0) if (idAt(rest[slash + 1 ..])) |found| return found;
    return idAt(rest);
}

/// `downloadURL(for:)`, as URLComponents writes it (gpa-owned).
pub fn downloadURL(gpa: std.mem.Allocator, ext_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=" ++ chrome_version ++ "&acceptformat=crx3&x=id%3D{s}%26installsource%3Dondemand%26uc", .{ext_id});
}

pub const Fetched = union(enum) {
    /// The .crx; gpa-owned, the callee frees it.
    ok: []u8,
    /// `Refused.errorDescription`; gpa-owned, the callee frees it.
    fail: []u8,
};

/// `fetch(_:)`: off the main thread, answered on it.
pub fn fetch(gpa: std.mem.Allocator, ext_id: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), Fetched) void) void {
    const Job = struct {
        gpa: std.mem.Allocator,
        url: []u8,
        ctx: @TypeOf(ctx),
        out: Fetched = undefined,

        fn work(raw: ?*anyopaque) callconv(.c) void {
            const pool = objc.Pool.push();
            defer pool.pop();
            const j: *@This() = @ptrCast(@alignCast(raw));
            const session = urlsession.ephemeral(60);
            defer objc.release(session);
            const got = urlsession.send(j.gpa, session, "GET", j.url, &.{}, null) catch @panic("OOM");
            j.out = if (got) |r| answer: {
                if (r.code != 0 and (r.code < 200 or r.code >= 300)) {
                    j.gpa.free(r.body);
                    break :answer .{ .fail = std.fmt.allocPrint(j.gpa, "The Chrome Web Store answered {d}", .{r.code}) catch @panic("OOM") };
                }
                if (r.body.len == 0) {
                    j.gpa.free(r.body);
                    break :answer .{ .fail = j.gpa.dupe(u8, describe(error.Empty)) catch @panic("OOM") };
                }
                break :answer .{ .ok = r.body };
            } else .{ .fail = j.gpa.dupe(u8, describe(error.Download)) catch @panic("OOM") };
            objc.dispatchMain(raw, back);
        }

        fn back(raw: ?*anyopaque) callconv(.c) void {
            const j: *@This() = @ptrCast(@alignCast(raw));
            defer {
                j.gpa.free(j.url);
                j.gpa.destroy(j);
            }
            cb(j.ctx, j.out);
        }
    };
    const j = gpa.create(Job) catch @panic("OOM");
    j.* = .{ .gpa = gpa, .url = downloadURL(gpa, ext_id) catch @panic("OOM"), .ctx = ctx };
    dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), j, Job.work);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// Length-delimited fields only, which is all a CRX header holds.
const Fields = struct {
    b: []const u8,
    i: usize = 0,

    const Field = struct { n: u64, bytes: []const u8 };

    fn varint(f: *Fields) ?u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (f.i < f.b.len) {
            const byte = f.b[f.i];
            f.i += 1;
            value |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) return value;
            shift += 7;
            if (shift > 56) return null;
        }
        return null;
    }

    fn next(f: *Fields) ?Field {
        while (f.i < f.b.len) {
            const key = f.varint() orelse return null;
            switch (key & 7) {
                2 => {
                    const len = f.varint() orelse return null;
                    if (len > f.b.len - f.i) return null;
                    const start = f.i;
                    f.i += @intCast(len);
                    return .{ .n = key >> 3, .bytes = f.b[start..f.i] };
                },
                0 => _ = f.varint(),
                1 => f.i += 8,
                5 => f.i += 4,
                else => return null,
            }
        }
        return null;
    }

    fn first(b: []const u8, n: u64) ?[]const u8 {
        var f: Fields = .{ .b = b };
        while (f.next()) |x| if (x.n == n) return x.bytes;
        return null;
    }
};

const SecExternalFormatOpenSSL: u32 = 1;
const SecExternalItemTypePublicKey: u32 = 2;
extern "c" const kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256: objc.Object;
extern "c" fn SecItemImport(data: objc.Object, name: ?objc.Object, format: *u32, item_type: *u32, flags: u32, params: ?*const anyopaque, keychain: ?*anyopaque, out: *?objc.Object) i32;
extern "c" fn SecKeyVerifySignature(key: objc.Object, alg: objc.Object, data: objc.Object, signature: objc.Object, err: ?*?objc.Object) u8;
extern "c" fn CFRelease(cf: objc.Object) void;

fn nsData(b: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ b.ptr, @as(objc.NSUInteger, b.len) });
}

/// An RSA public key as Chrome writes it (SubjectPublicKeyInfo DER),
/// checked against a PKCS#1 v1.5 SHA-256 signature.
fn verify(spki: []const u8, signature: []const u8, message: objc.Object) bool {
    var format = SecExternalFormatOpenSSL;
    var kind = SecExternalItemTypePublicKey;
    var items: ?objc.Object = null;
    if (SecItemImport(nsData(spki), null, &format, &kind, 0, null, null, &items) != 0) return false;
    const list = items orelse return false;
    defer CFRelease(list);
    if (objc.msg(objc.NSUInteger, list, "count", .{}) == 0) return false;
    const key = objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    return SecKeyVerifySignature(key, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, message, nsData(signature), null) != 0;
}

/// The zip inside a CRX3 (a gpa-owned copy), once its signature has been
/// checked against `ext_id`. Safe off the main thread.
pub fn verifiedZip(gpa: std.mem.Allocator, crx: []const u8, ext_id: []const u8) ![]u8 {
    if (crx.len <= 12 or !std.mem.eql(u8, crx[0..4], "Cr24") or le32(crx, 4) != 3) return error.NotCrx;
    const header_size = le32(crx, 8);
    if (header_size > crx.len - 12) return error.NotCrx;
    const header = crx[12..][0..header_size];
    const zip = crx[12 + header_size ..];

    // CrxFileHeader: 2 = sha256_with_rsa proofs, 10000 = signed_header_data
    // (SignedData: 1 = crx_id).
    const signed = Fields.first(header, 10000) orelse return error.UnsignedOrWrong;
    const crx_id = Fields.first(signed, 1) orelse return error.UnsignedOrWrong;
    if (crx_id.len != 16 or !std.mem.eql(u8, &letters(crx_id[0..16].*), ext_id)) return error.UnsignedOrWrong;

    const pool = objc.Pool.push();
    defer pool.pop();
    // What is signed: a fixed prefix, the signed header, and the zip.
    const message = objc.msg(objc.Object, objc.class("NSMutableData"), "data", .{});
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(signed.len), .little);
    for ([_][]const u8{ "CRX3 SignedData\x00", &length, signed, zip }) |part|
        objc.msg(void, message, "appendBytes:length:", .{ part.ptr, @as(objc.NSUInteger, part.len) });

    // One RSA proof whose key is the one the id is made from, and whose
    // signature holds; the store's own proof is not the one that counts.
    var fields: Fields = .{ .b = header };
    while (fields.next()) |f| {
        if (f.n != 2) continue;
        const key = Fields.first(f.bytes, 1) orelse continue;
        const signature = Fields.first(f.bytes, 2) orelse continue;
        if (!std.mem.eql(u8, &hashID(key), ext_id)) continue;
        if (verify(key, signature, message)) return gpa.dupe(u8, zip);
    }
    return error.UnsignedOrWrong;
}

/// Runs /usr/bin/ditto with `args`; true when it exited 0.
pub fn ditto(args: []const []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const list = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (args) |a| objc.msg(void, list, "addObject:", .{objc.nsString(a)});
    const task = objc.msg(objc.Object, objc.alloc("NSTask"), "init", .{});
    defer objc.release(task);
    objc.msg(void, task, "setExecutableURL:", .{objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString("/usr/bin/ditto")})});
    objc.msg(void, task, "setArguments:", .{list});
    if (!objc.msg(objc.BOOL, task, "launchAndReturnError:", .{@as(?*anyopaque, null)})) return false;
    objc.msg(void, task, "waitUntilExit", .{});
    return objc.msg(c_int, task, "terminationStatus", .{}) == 0;
}

/// Unpacks a zip into `folder`, which is replaced whole. Safe off the main
/// thread; `gpa` unused (Foundation does the work).
pub fn unpack(_: std.mem.Allocator, zip: []const u8, folder: []const u8) !void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const files = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const uuid = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSUUID"), "UUID", .{}), "UUIDString", .{});
    const tmp = objc.msg(objc.Object, objc.msg(objc.Object, files, "temporaryDirectory", .{}), "path", .{});
    const scratch = objc.msg(objc.Object, tmp, "stringByAppendingPathComponent:", .{objc.msg(objc.Object, objc.nsString("kea-crx-"), "stringByAppendingString:", .{uuid})});
    if (!objc.msg(objc.BOOL, files, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{ scratch, true, @as(?objc.Object, null), @as(?*anyopaque, null) })) return error.Unpack;
    defer _ = objc.msg(objc.BOOL, files, "removeItemAtPath:error:", .{ scratch, @as(?*anyopaque, null) });
    const archive = objc.msg(objc.Object, scratch, "stringByAppendingPathComponent:", .{objc.nsString("x.zip")});
    if (!objc.msg(objc.BOOL, nsData(zip), "writeToFile:atomically:", .{ archive, false })) return error.Unpack;
    const out = objc.msg(objc.Object, scratch, "stringByAppendingPathComponent:", .{objc.nsString("out")});
    const manifest = objc.msg(objc.Object, out, "stringByAppendingPathComponent:", .{objc.nsString("manifest.json")});
    if (!ditto(&.{ "-x", "-k", objc.fromNSString(archive), objc.fromNSString(out) }) or
        !objc.msg(objc.BOOL, files, "fileExistsAtPath:", .{manifest})) return error.Unpack;
    // `ditto` keeps a symbolic link as a link, and the shim rewrites the
    // pages a package ships: a link would have that land wherever it points.
    const carried = objc.msg(objc.Object, files, "enumeratorAtPath:", .{out});
    while (objc.msg(?objc.Object, carried, "nextObject", .{})) |_| {
        const attrs = objc.msg(?objc.Object, carried, "fileAttributes", .{}) orelse continue;
        const kind = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("NSFileType")});
        if (std.mem.eql(u8, objc.fromNSString(kind), "NSFileTypeSymbolicLink")) return error.Unpack;
    }
    const target = objc.nsString(folder);
    _ = objc.msg(objc.BOOL, files, "removeItemAtPath:error:", .{ target, @as(?*anyopaque, null) });
    _ = objc.msg(objc.BOOL, files, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{ objc.msg(objc.Object, target, "stringByDeletingLastPathComponent", .{}), true, @as(?objc.Object, null), @as(?*anyopaque, null) });
    if (!objc.msg(objc.BOOL, files, "moveItemAtPath:toPath:error:", .{ out, target, @as(?*anyopaque, null) })) return error.Unpack;
}
