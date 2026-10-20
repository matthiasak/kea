//! Reading what a Chromium browser on this Mac holds (`Chromium` in
//! Import.swift). Every one — Chrome, Dia, Arc, Brave, Edge, the rest —
//! keeps its passwords in a SQLite file called "Login Data", each encrypted
//! with a key the browser keeps in the keychain under "<Name> Safe Storage".
//! macOS asks before handing that key over; after that it is arithmetic.
//! Every file is read from a copy (`files.Snapshot`), never underneath the
//! browser that owns it.
const std = @import("std");
const files = @import("files.zig");
const src = @import("sources.zig");
const sqlite = @import("../sys/sqlite.zig");
const cc = @import("../sys/commoncrypto.zig");
const keychain = @import("../sys/keychain.zig");
const disk = @import("../data/disk.zig");
const Parts = @import("../data/url.zig").Parts;
const bookmarks = @import("../data/bookmarks.zig");
const Bookmark = bookmarks.Bookmark;
const Uuid = @import("../data/json.zig").Uuid;
const json = @import("../data/json.zig");
const vault = @import("../passwords/vault.zig");
const favicons = @import("../web/favicons.zig");
const Base = src.Base;
const Place = src.Place;

pub const Source = struct {
    name: []const u8,
    /// Under the base (~/Library/Application Support).
    folder: []const u8,
    service: []const u8,
    account: []const u8,
    /// The app itself, to say so when it is on this Mac but its data isn't
    /// where it should be.
    app: []const u8,

    pub fn root(s: Source, a: std.mem.Allocator, base: Base) ![]u8 {
        return files.join(a, base.path, s.folder);
    }

    /// Every profile: a folder holding passwords, bookmarks or history.
    /// Most browsers keep one folder per profile ("Default", "Profile 1");
    /// Opera keeps its only profile in the browser's folder itself.
    pub fn profiles(s: Source, a: std.mem.Allocator, base: Base) ![]const []const u8 {
        const r = try s.root(a, base);
        var out: std.ArrayList([]const u8) = .empty;
        const inside = try files.list(a, r);
        for (0..inside.len + 1) |i| {
            const folder = if (i == 0) r else try files.join(a, r, inside[i - 1]);
            for ([_][]const u8{ "Login Data", "Bookmarks", "History" }) |f| {
                if (files.exists(try files.join(a, folder, f))) {
                    try out.append(a, folder);
                    break;
                }
            }
        }
        return out.items;
    }

    /// The profiles to read: the one whose folder is named, or every one
    /// when null, which is "All profiles".
    pub fn profilesOnly(s: Source, a: std.mem.Allocator, base: Base, only: ?[]const u8) ![]const []const u8 {
        const all = try s.profiles(a, base);
        const wanted = only orelse return all;
        var out: std.ArrayList([]const u8) = .empty;
        for (all) |p| if (std.mem.eql(u8, std.fs.path.basename(p), wanted)) try out.append(a, p);
        return out.items;
    }

    /// Every profile's passwords file, or the one profile's.
    pub fn loginFiles(s: Source, a: std.mem.Allocator, base: Base, only: ?[]const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (try s.profilesOnly(a, base, only)) |p| {
            const f = try files.join(a, p, "Login Data");
            if (files.exists(f)) try out.append(a, f);
        }
        return out.items;
    }

    pub const LocalState = struct {
        /// Folder → the name it goes by ("Work", "Person 1").
        names: std.StringHashMapUnmanaged([]const u8) = .empty,
        /// "last_used", then "last_active_profiles".
        last: []const []const u8 = &.{},
    };

    /// What the browser says of its profiles in "Local State", beside them.
    pub fn localState(s: Source, a: std.mem.Allocator, base: Base) !LocalState {
        const top = src.readJson(a, try files.join(a, try s.root(a, base), "Local State")) orelse return .{};
        const profile = src.field(top, "profile") orelse return .{};
        if (profile != .object) return .{};
        var out: LocalState = .{};
        if (src.field(profile, "info_cache")) |cache| if (cache == .object) {
            var it = cache.object.iterator();
            while (it.next()) |e| {
                const n = src.text(src.field(e.value_ptr.*, "name")) orelse continue;
                if (n.len > 0) try out.names.put(a, e.key_ptr.*, n);
            }
        };
        var last: std.ArrayList([]const u8) = .empty;
        if (src.text(src.field(profile, "last_used"))) |l| try last.append(a, l);
        for (src.items(src.field(profile, "last_active_profiles"))) |v| if (src.text(v)) |l| try last.append(a, l);
        out.last = last.items;
        return out;
    }

    /// Whether the app is in /Applications or ~/Applications.
    pub fn appInstalled(s: Source, a: std.mem.Allocator) !bool {
        const home_apps = try files.join(a, src.home(), "Applications");
        for ([_][]const u8{ "/Applications", home_apps }) |dir| {
            if (files.exists(try files.join(a, dir, s.app))) return true;
        }
        return false;
    }
};

pub const known = [_]Source{
    .{ .name = "Dia", .folder = "Dia/User Data", .service = "Dia Safe Storage", .account = "Dia", .app = "Dia.app" },
    .{ .name = "Chrome", .folder = "Google/Chrome", .service = "Chrome Safe Storage", .account = "Chrome", .app = "Google Chrome.app" },
    .{ .name = "Arc", .folder = "Arc/User Data", .service = "Arc Safe Storage", .account = "Arc", .app = "Arc.app" },
    .{ .name = "Brave", .folder = "BraveSoftware/Brave-Browser", .service = "Brave Safe Storage", .account = "Brave", .app = "Brave Browser.app" },
    .{ .name = "Edge", .folder = "Microsoft Edge", .service = "Microsoft Edge Safe Storage", .account = "Microsoft Edge", .app = "Microsoft Edge.app" },
    .{ .name = "Vivaldi", .folder = "Vivaldi", .service = "Vivaldi Safe Storage", .account = "Vivaldi", .app = "Vivaldi.app" },
    .{ .name = "Chromium", .folder = "Chromium", .service = "Chromium Safe Storage", .account = "Chromium", .app = "Chromium.app" },
    // Chrome's other channels keep their own data, and share Chrome's key.
    .{ .name = "Chrome Beta", .folder = "Google/Chrome Beta", .service = "Chrome Safe Storage", .account = "Chrome", .app = "Google Chrome Beta.app" },
    .{ .name = "Chrome Dev", .folder = "Google/Chrome Dev", .service = "Chrome Safe Storage", .account = "Chrome", .app = "Google Chrome Dev.app" },
    .{ .name = "Chrome Canary", .folder = "Google/Chrome Canary", .service = "Chrome Safe Storage", .account = "Chrome", .app = "Google Chrome Canary.app" },
    // Opera keeps its one profile in its own folder, not in one inside it.
    .{ .name = "Opera", .folder = "com.operasoftware.Opera", .service = "Opera Safe Storage", .account = "Opera", .app = "Opera.app" },
    .{ .name = "Opera GX", .folder = "com.operasoftware.OperaGX", .service = "Opera Safe Storage", .account = "Opera", .app = "Opera GX.app" },
    .{ .name = "Helium", .folder = "net.imput.helium", .service = "Helium Storage Key", .account = "Helium", .app = "Helium.app" },
    .{ .name = "Comet", .folder = "Comet", .service = "Comet Safe Storage", .account = "Comet", .app = "Comet.app" },
};

pub const Missing = struct { source: Source, looked: []const u8 };

/// Browsers on this Mac with nothing where their data should be — said by
/// name, with where it looked ("~/Library/…"). None in a test run.
pub fn unreadable(a: std.mem.Allocator, base: Base) ![]Missing {
    var out: std.ArrayList(Missing) = .empty;
    if (base.testing) return out.items;
    const home = src.home();
    for (known) |s| {
        if (!try s.appInstalled(a) or (try s.profiles(a, base)).len > 0) continue;
        const r = try s.root(a, base);
        const looked = if (std.mem.startsWith(u8, r, home)) try std.mem.concat(a, u8, &.{ "~", r[home.len..] }) else r;
        try out.append(a, .{ .source = s, .looked = looked });
    }
    return out.items;
}

/// The passwords of one profile, or of all of them when `profile` is null.
/// The key is asked for once, here, whichever it is.
pub fn read(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8) !src.Found {
    const passphrase = safeStorage(a, base, s) orelse return error.NoPassphrase;
    const key = stretch(passphrase);

    var logins: std.ArrayList(vault.Login) = .empty;
    var never: std.ArrayList([]const u8) = .empty;
    var skipped: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var read_any = false;

    for (try s.loginFiles(a, base, profile)) |file| {
        const list = rows(a, file) catch continue;
        read_any = true;
        for (list) |row| {
            const host = try vault.host(a, row.origin);
            if (host.len == 0) {
                if (!row.never and row.blob.len > 0) skipped += 1;
                continue;
            }
            if (row.never) {
                try never.append(a, host);
                continue;
            }
            const password = unwrap(a, row.blob, key) orelse continue;
            if (password.len == 0) continue;
            const id = try std.mem.concat(a, u8, &.{ host, "\x01", row.user });
            if ((try seen.getOrPut(a, id)).found_existing) continue;
            try logins.append(a, .{
                .host = host,
                .user = try a.dupe(u8, row.user),
                .password = password,
                .used = row.used,
                .clear = startsWithIgnoreCase(row.origin, "http://"),
            });
        }
    }
    if (!read_any) return error.Unreadable;
    return .{ .logins = logins.items, .never = never.items, .skipped = skipped };
}

// MARK: - what they kept

/// The other browser's bookmarks: the bar first, then anything filed
/// elsewhere, folders and all — and whether every profile asked for read
/// cleanly: false when there was no profile, or a Bookmarks file didn't
/// read. A profile with no Bookmarks file has none and reads cleanly.
pub fn bookmarkRead(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8) !src.BookmarkRead {
    var out: std.ArrayList(Bookmark) = .empty;
    const list = try s.profilesOnly(a, base, profile);
    var complete = list.len > 0;
    for (list) |p| {
        const marks = try files.join(a, p, "Bookmarks");
        if (!files.exists(marks)) continue;
        const roots = src.field(src.readJson(a, marks), "roots") orelse {
            complete = false;
            continue;
        };
        if (roots != .object) {
            complete = false;
            continue;
        }
        if (src.field(roots, "bookmark_bar")) |bar| try out.appendSlice(a, try nodes(a, src.items(src.field(bar, "children"))));
        for ([_][]const u8{ "other", "synced" }) |k| {
            const more = src.field(roots, k) orelse continue;
            if (more != .object) continue;
            const kids = try nodes(a, src.items(src.field(more, "children")));
            if (kids.len > 0) try out.append(a, Bookmark.folder(if (std.mem.eql(u8, k, "other")) "Other" else "Mobile", kids));
        }
    }
    return .{ .nodes = out.items, .complete = complete };
}

fn nodes(a: std.mem.Allocator, raw: []const src.Value) error{OutOfMemory}![]Bookmark {
    var out: std.ArrayList(Bookmark) = .empty;
    for (raw) |entry| {
        const n = src.text(src.field(entry, "name")) orelse "";
        const kind = src.text(src.field(entry, "type")) orelse continue;
        if (std.mem.eql(u8, kind, "folder")) {
            try out.append(a, Bookmark.folder(n, try nodes(a, src.items(src.field(entry, "children")))));
        } else if (std.mem.eql(u8, kind, "url")) {
            const address = src.text(src.field(entry, "url")) orelse continue;
            if (!src.isWeb(address)) continue;
            try out.append(a, .{ .id = Uuid.random(), .title = n, .url = address });
        }
    }
    return out.items;
}

/// The icon each wanted page's site goes by, host by host (`Favicons.site`),
/// in the order first met, at most `limit`.
pub fn wantedSites(a: std.mem.Allocator, urls: []const []const u8, limit: usize) ![]const [2][]const u8 {
    var out: std.ArrayList([2][]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (urls) |u| {
        var buf: [300]u8 = undefined;
        const host = try a.dupe(u8, favicons.site(&buf, u) orelse continue);
        if ((try seen.getOrPut(a, host)).found_existing) continue;
        try out.append(a, .{ host, u });
        if (out.items.len >= limit) break;
    }
    return out.items;
}

/// Each wanted site's icon from one icons database: the page's own, or
/// failing that the site's front door's (`scheme://host/`). Bitmaps of 60
/// bytes or fewer aren't icons.
pub fn iconsFrom(a: std.mem.Allocator, file: []const u8, sql: []const u8, wanted: []const [2][]const u8, out: *src.Icons) !void {
    if (!files.exists(file)) return;
    var copy = files.Snapshot.init(a, file) catch return;
    defer copy.deinit();
    const db = sqlite.Db.open(copy.file, sqlite.open_readonly) catch return;
    defer db.close();
    const st = db.prepare(sql) catch return;
    defer st.finalize();
    for (wanted) |w| {
        if (out.contains(w[0])) continue;
        const scheme = (Parts.parse(w[1]) orelse continue).scheme orelse "";
        const doors = [_][]const u8{ w[1], try std.fmt.allocPrint(a, "{s}://{s}/", .{ scheme, w[0] }) };
        for (doors) |door| {
            st.reset();
            st.bindText(1, door);
            if (!st.step()) continue;
            const bytes = st.blob(0);
            if (bytes.len <= 60) continue;
            try out.put(a, w[0], try a.dupe(u8, bytes));
            break;
        }
    }
}

/// The other browser's icons for the given pages, from its "Favicons" file:
/// the largest bitmap it kept for the page, or for the site's front door.
pub fn icons(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8, urls: []const []const u8, limit: usize) !src.Icons {
    var out: src.Icons = .empty;
    const wanted = try wantedSites(a, urls, limit);
    if (wanted.len == 0) return out;
    const sql =
        \\SELECT b.image_data FROM icon_mapping m
        \\JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
        \\WHERE m.page_url = ? AND b.width BETWEEN 16 AND 256
        \\ORDER BY b.width DESC LIMIT 1
    ;
    for (try s.profilesOnly(a, base, profile)) |p| try iconsFrom(a, try files.join(a, p, "Favicons"), sql, wanted, &out);
    return out;
}

// MARK: - where they have been

/// The other browser's history — what it takes to finish an address on the
/// first day. Newest first, at most `limit`.
pub fn places(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8, limit: usize) ![]Place {
    var out: std.ArrayList(Place) = .empty;
    for (try s.profilesOnly(a, base, profile)) |p| {
        const history = try files.join(a, p, "History");
        if (!files.exists(history)) continue;
        const sql = try std.fmt.allocPrint(a,
            \\SELECT url, title, visit_count, last_visit_time FROM urls
            \\WHERE hidden = 0 AND visit_count > 0
            \\ORDER BY last_visit_time DESC LIMIT {d}
        , .{limit});
        placeRows(a, history, sql, chromiumDate, &out) catch {};
    }
    return src.newest(out.items, limit);
}

/// Microseconds since 1601, Chromium's idea of a date, as a `SwiftDate`.
fn chromiumDate(stamp: i64) f64 {
    return json.fromUnix(@as(f64, @floatFromInt(stamp)) / 1_000_000 - 11_644_473_600);
}

/// Rows of url, title, count, stamp from a copy of `file`; a stamp of 0 is now.
pub fn placeRows(a: std.mem.Allocator, file: []const u8, sql: []const u8, date: *const fn (i64) f64, out: *std.ArrayList(Place)) !void {
    var copy = try files.Snapshot.init(a, file);
    defer copy.deinit();
    const db = try sqlite.Db.open(copy.file, sqlite.open_readonly);
    defer db.close();
    const st = try db.prepare(sql);
    defer st.finalize();
    while (st.step()) {
        const address = st.text(0) orelse continue;
        if (!src.isWeb(address)) continue;
        const stamp = st.int(3);
        try out.append(a, .{
            .url = try a.dupe(u8, address),
            .title = try a.dupe(u8, st.text(1) orelse ""),
            .count = @max(1, st.int(2)),
            .last = if (stamp > 0) date(stamp) else json.now(),
        });
    }
}

// MARK: - counting, before anything is brought

/// How much there is to bring, read from the files alone: no key is asked
/// for and nothing is decrypted, so it never prompts.
pub fn preview(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8, limit: usize) !src.Preview {
    var place_count: usize = 0;
    for (try s.profilesOnly(a, base, profile)) |p| {
        place_count += count(a,
            \\SELECT COUNT(*) FROM urls WHERE hidden = 0 AND visit_count > 0
            \\AND (url LIKE 'http:%' OR url LIKE 'https:%')
        , try files.join(a, p, "History"));
    }
    var passwords: usize = 0;
    for (try s.loginFiles(a, base, profile)) |f| {
        passwords += count(a, "SELECT COUNT(*) FROM logins WHERE blacklisted_by_user = 0 AND length(password_value) > 0", f);
    }
    return .{
        .bookmarks = bookmarks.Bookmarks.count((try bookmarkRead(a, base, s, profile)).nodes),
        .places = @min(limit, place_count),
        .passwords = passwords,
        .extensions = try extensions(a, base, s, profile),
    };
}

/// One number from a copy of a SQLite file; 0 for a file that isn't there
/// or won't answer.
pub fn count(a: std.mem.Allocator, sql: []const u8, file: []const u8) usize {
    if (!files.exists(file)) return 0;
    var copy = files.Snapshot.init(a, file) catch return 0;
    defer copy.deinit();
    const db = sqlite.Db.open(copy.file, sqlite.open_readonly) catch return 0;
    defer db.close();
    const st = db.prepare(sql) catch return 0;
    defer st.finalize();
    return if (st.step()) @intCast(@max(0, st.int(0))) else 0;
}

/// The extensions a profile has from the Chrome Web Store, by id: only ones
/// the person added from the store — not built in, unpacked, by policy or
/// by the browser itself, nor themes. A profile without Preferences has
/// only its Extensions/ folders to go by.
pub fn extensions(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try s.profilesOnly(a, base, profile)) |folder| {
        var settings: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(src.Value)) = .empty;
        for ([_][]const u8{ "Preferences", "Secure Preferences" }) |n| {
            const all = src.field(src.field(src.readJson(a, try files.join(a, folder, n)), "extensions"), "settings") orelse continue;
            if (all != .object) continue;
            var it = all.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .object) continue;
                const kept = try settings.getOrPut(a, e.key_ptr.*);
                if (!kept.found_existing) kept.value_ptr.* = .empty;
                var fields = e.value_ptr.object.iterator();
                while (fields.next()) |f| {
                    const slot = try kept.value_ptr.getOrPut(a, f.key_ptr.*);
                    if (!slot.found_existing) slot.value_ptr.* = f.value_ptr.*;
                }
            }
        }
        var ids: std.ArrayList([]const u8) = .empty;
        if (settings.count() == 0) {
            for (try files.list(a, try files.join(a, folder, "Extensions"))) |n| try ids.append(a, n);
        } else {
            var it = settings.iterator();
            while (it.next()) |e| if (fromStore(e.value_ptr.*)) try ids.append(a, e.key_ptr.*);
        }
        std.mem.sort([]const u8, ids.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        outer: for (ids.items) |id| {
            if (!isStoreId(id)) continue;
            for (out.items) |o| if (std.mem.eql(u8, o, id)) continue :outer;
            try out.append(a, id);
        }
    }
    return out.items;
}

fn fromStore(entry: std.StringArrayHashMapUnmanaged(src.Value)) bool {
    const is = struct {
        fn int(v: ?src.Value, n: i64) bool {
            return if (v) |x| x == .integer and x.integer == n else false;
        }
        fn yes(v: ?src.Value) bool {
            return if (v) |x| x == .bool and x.bool else false;
        }
    };
    // Location 1 is Chromium's "internal": added by the person.
    if (!is.int(entry.get("location"), 1) and !is.yes(entry.get("from_webstore"))) return false;
    if (is.yes(entry.get("was_installed_by_default")) or is.yes(entry.get("was_installed_by_oem"))) return false;
    const manifest = entry.get("manifest");
    if (src.field(manifest, "theme") != null) return false;
    // From another store, Edge's say: not the Chrome Web Store's to give.
    if (src.text(src.field(manifest, "update_url"))) |update| {
        var buf: [256]u8 = undefined;
        const raw = (Parts.parse(update) orelse return false).hostName() orelse "";
        if (raw.len > buf.len) return false;
        const host = std.ascii.lowerString(&buf, raw);
        if (!std.mem.eql(u8, host, "google.com") and !std.mem.endsWith(u8, host, ".google.com")) return false;
    }
    return true;
}

/// Thirty-two letters from a to p: the shape of a store extension's id.
fn isStoreId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |ch| if (ch < 'a' or ch > 'p') return false;
    return true;
}

// MARK: - the key

fn safeStorage(a: std.mem.Allocator, base: Base, s: Source) ?[]const u8 {
    // A test run's made-up browser keeps its key beside its profiles, not
    // in the keychain.
    if (base.testing) {
        const r = s.root(a, base) catch return null;
        const bytes = disk.read(a, files.join(a, r, "Safe Storage") catch return null) orelse return null;
        if (!std.unicode.utf8ValidateSlice(bytes)) return null;
        return std.mem.trim(u8, bytes, " \t\r\n");
    }
    const t = keychain.load(a, .{ .service = s.service, .account = s.account }) orelse return null;
    if (t.len == 0 or !std.unicode.utf8ValidateSlice(t)) return null;
    return t;
}

/// Chromium's own recipe, unchanged for a decade: PBKDF2 over SHA-1, the
/// salt "saltysalt", 1003 rounds, sixteen bytes out.
pub fn stretch(passphrase: []const u8) [16]u8 {
    var key: [16]u8 = @splat(0);
    // No passphrase, no key: the logins then just don't decrypt.
    if (passphrase.len == 0) return key;
    const salt = "saltysalt";
    _ = cc.CCKeyDerivationPBKDF(cc.kCCPBKDF2, passphrase.ptr, passphrase.len, salt, salt.len, cc.kCCPRFHmacAlgSHA1, 1003, &key, key.len);
    return key;
}

/// "v10" and then AES-128-CBC with an IV of sixteen spaces. Encrypted, or
/// not taken at all: a password lying in a profile in the clear is one only
/// some other program would have put there. On `a`.
pub fn unwrap(a: std.mem.Allocator, blob: []const u8, key: [16]u8) ?[]u8 {
    if (blob.len <= 3 or !std.mem.eql(u8, blob[0..3], "v10")) return null;
    const body = blob[3..];
    const iv: [16]u8 = @splat(0x20);
    const out = a.alloc(u8, body.len + cc.kCCBlockSizeAES128) catch return null;
    var moved: usize = 0;
    if (cc.CCCrypt(cc.kCCDecrypt, cc.kCCAlgorithmAES128, cc.kCCOptionPKCS7Padding, &key, key.len, &iv, body.ptr, body.len, out.ptr, out.len, &moved) != cc.kCCSuccess) return null;
    const plain = out[0..moved];
    if (std.unicode.utf8ValidateSlice(plain)) return plain;
    // Newer builds prefix the password with a hash of the site.
    if (plain.len <= 32 or !std.unicode.utf8ValidateSlice(plain[32..])) return null;
    return plain[32..];
}

// MARK: - the file

const Row = struct { origin: []const u8, user: []const u8, blob: []const u8, never: bool, used: ?f64 };

fn rows(a: std.mem.Allocator, file: []const u8) ![]Row {
    var copy = try files.Snapshot.init(a, file);
    defer copy.deinit();
    const db = try sqlite.Db.open(copy.file, sqlite.open_readonly);
    defer db.close();
    const st = try db.prepare(
        \\SELECT origin_url, username_value, password_value, blacklisted_by_user, date_last_used
        \\FROM logins
    );
    defer st.finalize();
    var out: std.ArrayList(Row) = .empty;
    while (st.step()) {
        const stamp = st.int(4);
        try out.append(a, .{
            .origin = try a.dupe(u8, st.text(0) orelse ""),
            .user = try a.dupe(u8, st.text(1) orelse ""),
            .blob = try a.dupe(u8, st.blob(2)),
            .never = st.int(3) != 0,
            // Microseconds since 1601; `Login.used` is unix seconds.
            .used = if (stamp > 0) @as(f64, @floatFromInt(stamp)) / 1_000_000 - 11_644_473_600 else null,
        });
    }
    return out.items;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}
