const std = @import("std");
const objc = @import("nanoui").objc;
const crx = @import("crx.zig");

extern "c" const kSecAttrKeyType: objc.Object;
extern "c" const kSecAttrKeyTypeRSA: objc.Object;
extern "c" const kSecAttrKeySizeInBits: objc.Object;
extern "c" const kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256: objc.Object;
extern "c" fn SecKeyCreateRandomKey(params: objc.Object, err: ?*?objc.Object) ?objc.Object;
extern "c" fn SecKeyCopyPublicKey(key: objc.Object) ?objc.Object;
extern "c" fn SecKeyCopyExternalRepresentation(key: objc.Object, err: ?*?objc.Object) ?objc.Object;
extern "c" fn SecKeyCreateSignature(key: objc.Object, alg: objc.Object, data: objc.Object, err: ?*?objc.Object) ?objc.Object;
extern "c" fn CFRelease(cf: objc.Object) void;

fn bytes(d: objc.Object) []const u8 {
    const p = objc.msg([*]const u8, d, "bytes", .{});
    return p[0..objc.msg(objc.NSUInteger, d, "length", .{})];
}

fn field(out: *std.ArrayList(u8), gpa: std.mem.Allocator, n: u64, body: []const u8) !void {
    var v: u64 = (n << 3) | 2;
    for ([_]u64{ 0, body.len }) |pass| {
        while (v >= 0x80) : (v >>= 7) try out.append(gpa, @intCast((v & 0x7f) | 0x80));
        try out.append(gpa, @intCast(v));
        _ = pass;
        v = body.len;
    }
    try out.appendSlice(gpa, body);
}

/// Chrome's own: the first 16 bytes of the SHA-256, half-bytes as a–p.
fn chromeID(data: []const u8) [32]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    var out: [32]u8 = undefined;
    for (0..32) |i| out[i] = "abcdefghijklmnop"[if (i % 2 == 0) d[i / 2] >> 4 else d[i / 2] & 15];
    return out;
}

test "crx unpacks fixture" {
    const gpa = std.testing.allocator;
    const pool = objc.Pool.push();
    defer pool.pop();
    const files = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const base = try std.fmt.allocPrint(gpa, "/tmp/kea-crx-test-{d}", .{std.c.getpid()});
    defer gpa.free(base);
    defer _ = objc.msg(objc.BOOL, files, "removeItemAtPath:error:", .{ objc.nsString(base), @as(?*anyopaque, null) });
    const src = try std.fmt.allocPrint(gpa, "{s}/src", .{base});
    defer gpa.free(src);
    _ = objc.msg(objc.BOOL, files, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{ objc.nsString(src), true, @as(?objc.Object, null), @as(?*anyopaque, null) });
    const manifest = try std.fmt.allocPrint(gpa, "{s}/manifest.json", .{src});
    defer gpa.free(manifest);
    _ = objc.msg(objc.BOOL, objc.nsString("{\"manifest_version\":3}"), "writeToFile:atomically:encoding:error:", .{ objc.nsString(manifest), false, @as(objc.NSUInteger, 4), @as(?*anyopaque, null) });
    const zip_path = try std.fmt.allocPrint(gpa, "{s}/x.zip", .{base});
    defer gpa.free(zip_path);
    try std.testing.expect(crx.ditto(&.{ "-c", "-k", src, zip_path }));
    const zip = bytes(objc.msg(objc.Object, objc.class("NSData"), "dataWithContentsOfFile:", .{objc.nsString(zip_path)}));

    // An RSA key kept nowhere (no kSecAttrIsPermanent).
    const params = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
    objc.msg(void, params, "setObject:forKey:", .{ kSecAttrKeyTypeRSA, kSecAttrKeyType });
    objc.msg(void, params, "setObject:forKey:", .{ objc.msg(objc.Object, objc.class("NSNumber"), "numberWithInt:", .{@as(c_int, 2048)}), kSecAttrKeySizeInBits });
    const private = SecKeyCreateRandomKey(params, null).?;
    defer CFRelease(private);
    const public = SecKeyCopyPublicKey(private).?;
    defer CFRelease(public);
    const pkcs1 = SecKeyCopyExternalRepresentation(public, null).?;
    defer CFRelease(pkcs1);
    // SubjectPublicKeyInfo around a 2048-bit PKCS#1 key.
    const spki = try std.mem.concat(gpa, u8, &.{ "\x30\x82\x01\x22\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01\x05\x00\x03\x82\x01\x0f\x00", bytes(pkcs1) });
    defer gpa.free(spki);
    const ext_id = chromeID(spki);
    var raw_id: [16]u8 = undefined;
    {
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(spki, &d, .{});
        raw_id = d[0..16].*;
    }

    var signed: std.ArrayList(u8) = .empty;
    defer signed.deinit(gpa);
    try field(&signed, gpa, 1, &raw_id);
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(signed.items.len), .little);
    for ([_][]const u8{ "CRX3 SignedData\x00", &len, signed.items, zip }) |p| try message.appendSlice(gpa, p);
    const ns_message = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ message.items.ptr, @as(objc.NSUInteger, message.items.len) });
    const signature = SecKeyCreateSignature(private, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, ns_message, null).?;
    defer CFRelease(signature);

    var proof: std.ArrayList(u8) = .empty;
    defer proof.deinit(gpa);
    try field(&proof, gpa, 1, spki);
    try field(&proof, gpa, 2, bytes(signature));
    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(gpa);
    try field(&header, gpa, 2, proof.items);
    try field(&header, gpa, 10000, signed.items);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(gpa);
    try file.appendSlice(gpa, "Cr24\x03\x00\x00\x00");
    std.mem.writeInt(u32, &len, @intCast(header.items.len), .little);
    try file.appendSlice(gpa, &len);
    try file.appendSlice(gpa, header.items);
    try file.appendSlice(gpa, zip);

    const got = try crx.verifiedZip(gpa, file.items, &ext_id);
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u8, zip, got);
    try std.testing.expectError(error.UnsignedOrWrong, crx.verifiedZip(gpa, file.items, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    file.items[file.items.len - 10] ^= 1;
    try std.testing.expectError(error.UnsignedOrWrong, crx.verifiedZip(gpa, file.items, &ext_id));
    try std.testing.expectError(error.NotCrx, crx.verifiedZip(gpa, "PK\x03\x04 not a crx", &ext_id));

    const into = try std.fmt.allocPrint(gpa, "{s}/out/{s}", .{ base, &ext_id });
    defer gpa.free(into);
    try crx.unpack(gpa, got, into);
    const unpacked = try std.fmt.allocPrint(gpa, "{s}/manifest.json", .{into});
    defer gpa.free(unpacked);
    try std.testing.expect(objc.msg(objc.BOOL, files, "fileExistsAtPath:", .{objc.nsString(unpacked)}));
}

test "unpacked id matches Chrome" {
    // /tmp is a link to /private/tmp: the real path is the one hashed.
    const got = try crx.unpackedID(std.testing.allocator, "/tmp");
    try std.testing.expectEqualStrings(&chromeID("/private/tmp"), &got);
}

test "store id parsed from links" {
    const want = "abcdefghijklmnopabcdefghijklmnop";
    for ([_][]const u8{
        "https://chromewebstore.google.com/detail/ublock/" ++ want,
        "https://chromewebstore.google.com/detail/" ++ want,
        "https://chromewebstore.google.com/detail/name/" ++ want ++ "/reviews",
        "https://CHROMEWEBSTORE.google.com/detail/" ++ want ++ "?hl=en",
        "https://chrome.google.com/webstore/detail/name/" ++ want,
    }) |u| try std.testing.expectEqualStrings(want, &(crx.storeID(u) orelse return error.Missed));
    for ([_][]const u8{
        "http://chromewebstore.google.com/detail/" ++ want,
        "https://evil@chromewebstore.google.com/detail/" ++ want,
        "https://example.com/detail/" ++ want,
        "https://chromewebstore.google.com/search/" ++ want,
        "https://chromewebstore.google.com/detail/" ++ want ++ "x",
        "https://chrome.google.com/detail/" ++ want,
    }) |u| try std.testing.expect(crx.storeID(u) == null);
    // `id(in:)`: a bare id, a store link, an old webstore link, any case.
    try std.testing.expectEqualStrings(want, &crx.id(want).?);
    try std.testing.expectEqualStrings(want, &crx.id("ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP").?);
    try std.testing.expectEqualStrings(want, &crx.id("https://chrome.google.com/webstore/detail/x/" ++ want ++ "?a=1").?);
    try std.testing.expect(crx.id("z" ++ want) == null);
    try std.testing.expect(crx.id("abcdefghijklmnopabcdefghijklmnoq") == null);
    try std.testing.expect(crx.id("not an id") == null);
    const url = try crx.downloadURL(std.testing.allocator, want);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0.0.0&acceptformat=crx3&x=id%3D" ++ want ++ "%26installsource%3Dondemand%26uc", url);
}
