//! The importers against made-up browsers: blobs built here, SQLite files
//! made in a temp folder, never a real browser's profile or the keychain.
const std = @import("std");
const testing = std.testing;
const cc = @import("../sys/commoncrypto.zig");
const sqlite = @import("../sys/sqlite.zig");
const json = @import("../data/json.zig");
const Store = @import("../data/store.zig").Store;
const Temp = @import("../tests/temp.zig").Temp;
const src = @import("sources.zig");
const chromium = @import("chromium.zig");
const firefox_key = @import("firefox_key.zig");
const arc = @import("arc.zig");
const file = @import("file.zig");
const record = @import("record.zig");

fn encrypt(a: std.mem.Allocator, key: []const u8, iv: []const u8, plain: []const u8) ![]u8 {
    const out = try a.alloc(u8, plain.len + 16);
    var moved: usize = 0;
    try testing.expectEqual(cc.kCCSuccess, cc.CCCrypt(cc.kCCEncrypt, cc.kCCAlgorithmAES128, cc.kCCOptionPKCS7Padding, key.ptr, key.len, iv.ptr, plain.ptr, plain.len, out.ptr, out.len, &moved));
    return out[0..moved];
}

test "chromium decrypts v10 sample" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Import.swift's recipe: PBKDF2-SHA1, salt "saltysalt", 1003 rounds, 16 bytes.
    var key: [16]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), cc.CCKeyDerivationPBKDF(cc.kCCPBKDF2, "peanuts", 7, "saltysalt", 9, cc.kCCPRFHmacAlgSHA1, 1003, &key, 16));
    try testing.expectEqualSlices(u8, &key, &chromium.stretch("peanuts"));
    const iv: [16]u8 = @splat(0x20);
    const blob = try std.mem.concat(a, u8, &.{ "v10", try encrypt(a, &key, &iv, "secret") });
    try testing.expectEqualStrings("secret", chromium.unwrap(a, blob, key).?);
    // A site-hash prefix, as newer builds write it.
    const hashed = try std.mem.concat(a, u8, &.{ "v10", try encrypt(a, &key, &iv, &(@as([32]u8, @splat(0xff)) ++ "secret".*)) });
    try testing.expectEqualStrings("secret", chromium.unwrap(a, hashed, key).?);
    try testing.expect(chromium.unwrap(a, "secret", key) == null);
}

/// One DER element around `parts`.
fn der(a: std.mem.Allocator, tag: u8, parts: []const []const u8) ![]u8 {
    const body = try std.mem.concat(a, u8, parts);
    var head: std.ArrayList(u8) = .empty;
    try head.append(a, tag);
    if (body.len < 0x80) try head.append(a, @intCast(body.len)) else try head.appendSlice(a, &.{ 0x82, @intCast(body.len >> 8), @intCast(body.len & 0xff) });
    return std.mem.concat(a, u8, &.{ head.items, body });
}

test "firefox decrypts constructed PBES2 blob" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const global_salt = "global-salt-for-key4";
    const entry_salt: [32]u8 = @splat(0x5e);
    const iv_body = "fourteen bytes";
    // NSS: PBKDF2-HMAC-SHA256 over SHA-1(global salt ‖ password ""), 32 bytes.
    var ck: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(global_salt, &ck, .{});
    var key: [32]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), cc.CCKeyDerivationPBKDF(cc.kCCPBKDF2, &ck, 20, &entry_salt, 32, cc.kCCPRFHmacAlgSHA256, 1000, &key, 32));
    const iv = [_]u8{ 0x04, 0x0e } ++ iv_body.*;
    const ct = try encrypt(a, &key, &iv, "password-check");

    const oid_pbes2 = [_]u8{ 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d };
    const oid_pbkdf2 = [_]u8{ 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c };
    const oid_hmac256 = [_]u8{ 0x06, 0x08, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09 };
    const oid_aes256 = [_]u8{ 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a };
    const kdf_params = try der(a, 0x30, &.{
        try der(a, 0x04, &.{&entry_salt}),
        try der(a, 0x02, &.{&.{ 0x03, 0xe8 }}), // 1000
        try der(a, 0x02, &.{&.{0x20}}), // 32
        try der(a, 0x30, &.{&oid_hmac256}),
    });
    const params = try der(a, 0x30, &.{
        try der(a, 0x30, &.{ &oid_pbkdf2, kdf_params }),
        try der(a, 0x30, &.{ &oid_aes256, try der(a, 0x04, &.{iv_body}) }),
    });
    const blob = try der(a, 0x30, &.{
        try der(a, 0x30, &.{ &oid_pbes2, params }),
        try der(a, 0x04, &.{ct}),
    });
    try testing.expectEqualStrings("password-check", firefox_key.unwrap(a, blob, global_salt, "").?);
    // Another primary password doesn't pass the check (garbage, or bad padding).
    if (firefox_key.unwrap(a, blob, global_salt, "hunter2")) |wrong| try testing.expect(!std.mem.startsWith(u8, wrong, "password-check"));

    // A login field with that key: base64 DER of key id, cipher and IV, ciphertext.
    const field = try der(a, 0x30, &.{
        try der(a, 0x04, &.{&([_]u8{0xf8} ++ @as([14]u8, @splat(0)) ++ [_]u8{1})}),
        try der(a, 0x30, &.{ &oid_aes256, try der(a, 0x04, &.{iv_body}) }),
        try der(a, 0x04, &.{try encrypt(a, &key, &iv, "kea@example.com")}),
    });
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(field.len));
    _ = std.base64.standard.Encoder.encode(b64, field);
    try testing.expectEqualStrings("kea@example.com", firefox_key.decryptLogin(a, b64, &key).?);
}

test "netscape html bookmarks parse" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try t.path(a, "bookmarks.html");
    try writeFile(path,
        \\<!DOCTYPE NETSCAPE-Bookmark-file-1>
        \\<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
        \\<DL><p>
        \\  <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        \\  <DL><p>
        \\    <DT><A HREF="https://example.com/" ADD_DATE="1">Example</A>
        \\    <DT><H3>Folder</H3>
        \\    <DL><p>
        \\      <DT><A HREF="https://ziglang.org/">Zig</A>
        \\      <DT><A HREF="javascript:alert(1)">Bad</A>
        \\    </DL><p>
        \\  </DL><p>
        \\  <DT><A HREF="https://other.example/">Other</A>
        \\</DL><p>
    );
    var control: file.Control = .{};
    const found = try file.read(a, path, &control);
    const marks = found.bookmarks.items;
    try testing.expectEqual(@as(usize, 3), marks.len);
    try testing.expectEqualStrings("Example", marks[0].title);
    try testing.expectEqualStrings("https://example.com/", marks[0].url.?);
    try testing.expectEqualStrings("Folder", marks[1].title);
    try testing.expectEqual(@as(usize, 1), marks[1].kids().len);
    try testing.expectEqualStrings("Zig", marks[1].kids()[0].title);
    try testing.expectEqualStrings("Other", marks[2].title);
    try testing.expect(found.places.items.len == 0 and !found.from_safari);
}

test "arc sidebar json maps spaces and pins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture =
        \\{"sidebar":{"containers":[{"global":{}},{
        \\ "spaces":["s1",{"id":"s1","title":"Work stuff","profile":{"default":true},
        \\   "newContainerIDs":[{"pinned":{}},"c1",{"unpinned":{}},"c2"],
        \\   "customInfo":{"iconType":{"emoji_v2":"🏠\uFE0F"}}},
        \\  "s2",{"id":"s2","title":" Code ","profile":{"custom":{"_0":{"directoryBasename":"Profile 1"}}},
        \\   "containerIDs":["unpinned","c2","pinned","c3"]}],
        \\ "items":[
        \\  "c1",{"id":"c1","childrenIds":["t1","f1"],"data":{"itemContainer":{}}},
        \\  "t1",{"id":"t1","title":null,"childrenIds":[],"data":{"tab":{"savedURL":"https://kea:pw@example.com/a","savedTitle":"Example"}}},
        \\  "f1",{"id":"f1","title":"Docs","childrenIds":["t2","t3","t1"],"data":{"list":{}}},
        \\  "t2",{"id":"t2","title":"Zig","childrenIds":[],"data":{"tab":{"savedURL":"https://ziglang.org/"}}},
        \\  "t3",{"id":"t3","childrenIds":[],"data":{"tab":{"savedURL":"file:///etc/hosts"}}},
        \\  "c2",{"id":"c2","childrenIds":["t4"],"data":{}},
        \\  "t4",{"id":"t4","data":{"tab":{"savedURL":"https://today.example/"}}},
        \\  "c3",{"id":"c3","childrenIds":["t5"]},
        \\  "t5",{"id":"t5","data":{"tab":{"savedURL":"http://github.com/"}}},
        \\  "fav",{"id":"fav","childrenIds":["t6"]},
        \\  "t6",{"id":"t6","title":"Mail","data":{"tab":{"savedURL":"https://mail.example/"}}}],
        \\ "topAppsContainerIDs":[{"default":true},"fav"]}]}}
    ;
    const side = (try arc.parse(a, fixture, null)).?;
    try testing.expectEqual(@as(usize, 2), side.spaces.len);
    const work = side.spaces[0];
    try testing.expectEqualStrings("Work stuff", work.name);
    try testing.expectEqualStrings("house", work.symbol);
    try testing.expectEqualStrings("Default", work.profile);
    try testing.expectEqual(@as(usize, 2), work.pinned.len);
    try testing.expectEqualStrings("Example", work.pinned[0].item.title);
    try testing.expectEqualStrings("https://example.com/a", work.pinned[0].item.url);
    const docs = work.pinned[1].folder;
    try testing.expectEqualStrings("Docs", docs.title);
    try testing.expectEqual(@as(usize, 1), docs.items.len);
    try testing.expectEqualStrings("Zig", docs.items[0].item.title);
    const code = side.spaces[1];
    try testing.expectEqualStrings("Code", code.name);
    try testing.expectEqualStrings("chevron.left.forwardslash.chevron.right", code.symbol);
    try testing.expectEqualStrings("Profile 1", code.profile);
    try testing.expectEqualStrings("github.com", code.pinned[0].item.title);
    try testing.expectEqual(@as(usize, 1), side.favorites.len);
    try testing.expectEqualStrings("Mail", side.favorites[0].title);
    try testing.expectEqual(arc.Counts{ .spaces = 2, .pinned = 4 }, side.counts());

    const one = (try arc.parse(a, fixture, "Profile 1")).?;
    try testing.expectEqual(arc.Counts{ .spaces = 1, .pinned = 1 }, one.counts());
    try testing.expect(try arc.parse(a, "{}", null) == null);
    try testing.expectEqualStrings("sparkles", try arc.symbol(a, null, "My AI"));
    try testing.expectEqualStrings("house", try arc.symbol(a, null, "Maison"));
    try testing.expectEqualStrings("briefcase", try arc.symbol(a, null, ""));
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.mem.printSentinel(&buf, "{s}", .{path}, 0);
    const f = std.c.fopen(z, "wb") orelse return error.Unwritable;
    defer _ = std.c.fclose(f);
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.Unwritable;
}

/// A made-up Chrome under `<root>/Import`, its Default profile's `name`
/// made by `sql`.
fn madeUp(a: std.mem.Allocator, t: Temp, name: []const u8, sql: [:0]const u8) !src.Base {
    const base = try src.Base.of(a, t.root);
    const profile = try std.fs.path.join(a, &.{ base.path, "Google/Chrome/Default" });
    @import("../data/disk.zig").makePath(a, try std.fs.path.join(a, &.{ profile, "x" }));
    const db = try sqlite.Db.open(try std.fs.path.join(a, &.{ profile, name }), sqlite.open_readwrite | sqlite.open_create);
    defer db.close();
    try db.exec(sql);
    return base;
}

test "chromium history reads from a temp sqlite file" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 13_300_000_000_000_000 µs since 1601 = 1_655_526_400 unix.
    const base = try madeUp(a, t, "History",
        \\CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_time INTEGER);
        \\INSERT INTO urls VALUES('https://older.example/', 'Older', 2, 0, 13200000000000000);
        \\INSERT INTO urls VALUES('https://newer.example/', 'Newer', 5, 0, 13300000000000000);
        \\INSERT INTO urls VALUES('ftp://files.example/', 'FTP', 1, 0, 13300000000000001);
        \\INSERT INTO urls VALUES('https://hidden.example/', 'Hidden', 1, 1, 13300000000000002);
        \\INSERT INTO urls VALUES('https://never.example/', 'Never', 0, 0, 13300000000000003);
    );
    const chrome: src.Source = .{ .chromium = chromium.known[1] };
    const list = try chrome.places(a, base, null, 3000);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("https://newer.example/", list[0].url);
    try testing.expectEqualStrings("Newer", list[0].title);
    try testing.expectEqual(@as(i64, 5), list[0].count);
    try testing.expectApproxEqAbs(json.fromUnix(1_655_526_400), list[0].last, 0.001);
    try testing.expectEqualStrings("https://older.example/", list[1].url);
    // LIMIT counts rows before the http(s) filter, as Swift's query does.
    try testing.expectEqual(@as(usize, 1), (try chrome.places(a, base, "Default", 2)).len);
    try testing.expectEqual(@as(usize, 0), (try chrome.places(a, base, "Profile 9", 3000)).len);

    const preview = try chrome.preview(a, base, null);
    try testing.expectEqual(@as(usize, 2), preview.places);
    const found = try src.installed(a, base);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("chromium-Chrome", try found[0].id(a));
    try testing.expectEqualStrings("Default", (try found[0].usual(a, base)).?);
}

test "chromium reads a made-up profile's passwords with the key beside it" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = chromium.stretch("peanuts");
    const blob = try std.mem.concat(a, u8, &.{ "v10", try encrypt(a, &key, &@as([16]u8, @splat(0x20)), "secret") });
    var sql: std.ArrayList(u8) = .empty;
    try sql.print(a,
        \\CREATE TABLE logins(origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER, date_last_used INTEGER);
        \\INSERT INTO logins VALUES('https://www.example.com/login', 'kea', X'{X}', 0, 0);
        \\INSERT INTO logins VALUES('https://never.example/', '', X'', 1, 0);
        \\INSERT INTO logins VALUES('android://x@com.vendor.app/', 'kea', X'{X}', 0, 0);
    , .{ blob, blob });
    try sql.append(a, 0);
    const base = try madeUp(a, t, "Login Data", sql.items[0 .. sql.items.len - 1 :0]);
    try writeFile(try std.fs.path.join(a, &.{ base.path, "Google/Chrome/Safe Storage" }), "peanuts\n");

    const found = try chromium.read(a, base, chromium.known[1], null);
    try testing.expectEqual(@as(usize, 1), found.logins.len);
    try testing.expectEqualStrings("example.com", found.logins[0].host);
    try testing.expectEqualStrings("kea", found.logins[0].user);
    try testing.expectEqualStrings("secret", found.logins[0].password);
    try testing.expectEqual(@as(usize, 1), found.never.len);
    try testing.expectEqual(@as(usize, 1), found.skipped);
    try testing.expectEqual(@as(usize, 2), (try chromium.preview(a, base, chromium.known[1], null, 3000)).passwords);
}

test "import records add up per browser" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var store = try Store.init(testing.allocator, t.root, t.suite);
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = json.Uuid.random();
    try record.note(testing.allocator, &store, "Chrome", .{ .ids = &.{id}, .bookmarks = 1, .places = 10 });
    try record.note(testing.allocator, &store, "Chrome", .{ .passwords = 3, .spaces = 2 });
    const r = record.of(a, &store, "Chrome").?;
    try testing.expectEqual(@as(i64, 1), r.bookmarks);
    try testing.expectEqual(@as(i64, 10), r.places);
    try testing.expectEqual(@as(i64, 3), r.passwords);
    try testing.expectEqual(@as(?i64, 2), r.spaces);
    try testing.expectEqual(@as(?i64, null), r.pinned);
    try testing.expect(r.bookmarkIDs.len == 1 and r.bookmarkIDs[0].eql(id));
    try record.forgetBookmarks(testing.allocator, &store, "Chrome");
    try testing.expectEqual(@as(usize, 0), record.of(a, &store, "Chrome").?.bookmarkIDs.len);
    try testing.expect(record.of(a, &store, "Arc") == null);
}

extern "c" const kCFRunLoopDefaultMode: *const anyopaque;
extern "c" fn CFRunLoopRunInMode(mode: *const anyopaque, seconds: f64, return_after_source_handled: u8) i32;

test "count runs off the main thread and delivers on it" {
    var t = try Temp.init(testing.allocator);
    defer t.deinit(testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try madeUp(a, t, "History",
        \\CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_time INTEGER);
        \\INSERT INTO urls VALUES('https://example.com/', 'Example', 1, 0, 13300000000000000);
    );
    const Got = struct {
        places: ?usize = null,
        on_main: bool = false,
        fn done(ctx: ?*anyopaque, job: *src.CountJob) void {
            const got: *@This() = @ptrCast(@alignCast(ctx.?));
            defer job.deinit();
            got.on_main = @import("nanoui").objc.isMainThread();
            got.places = if (job.output) |c| c.preview.places else |_| 0;
        }
    };
    var got: Got = .{};
    try src.count(testing.allocator, .{ .base = base, .source = .{ .chromium = chromium.known[1] }, .profile = null }, &got, Got.done);
    var waited: usize = 0;
    while (got.places == null and waited < 200) : (waited += 1) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 1);
    try testing.expectEqual(@as(?usize, 1), got.places);
    try testing.expect(got.on_main);
}
