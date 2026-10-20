//! Reading what a Mozilla browser on this Mac holds (`Mozilla` in
//! Import.swift): Firefox and Zen, and anything else built on Gecko. History
//! and bookmarks live together in each profile's "places.sqlite", icons in
//! "favicons.sqlite" beside it, saved logins in "logins.json" with their key
//! in "key4.db" (`firefox_key.zig`). Read through copies, as Chromium's are.
const std = @import("std");
const files_mod = @import("files.zig");
const src = @import("sources.zig");
const chromium = @import("chromium.zig");
const key4 = @import("firefox_key.zig");
const sqlite = @import("../sys/sqlite.zig");
const disk = @import("../data/disk.zig");
const json = @import("../data/json.zig");
const bookmarks = @import("../data/bookmarks.zig");
const Bookmark = bookmarks.Bookmark;
const vault = @import("../passwords/vault.zig");
const Base = src.Base;
const Place = src.Place;

pub const Source = struct {
    name: []const u8,
    /// Where profiles are looked for, under the base. Firefox keeps them
    /// under "Firefox/Profiles"; Zen's folder has been spelled a few ways.
    folders: []const []const u8,

    /// Every profile's places.sqlite, newest first, so the profile in use
    /// leads. A folder may point straight at a profile or at a directory of
    /// them.
    pub fn files(s: Source, a: std.mem.Allocator, base: Base) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (s.folders) |folder| {
            const root = try files_mod.join(a, base.path, folder);
            const direct = try files_mod.join(a, root, "places.sqlite");
            if (files_mod.exists(direct) and !(try seen.getOrPut(a, direct)).found_existing) try out.append(a, direct);
            for (try files_mod.list(a, root)) |sub| {
                const p = try std.fs.path.join(a, &.{ root, sub, "places.sqlite" });
                if (files_mod.exists(p) and !(try seen.getOrPut(a, p)).found_existing) try out.append(a, p);
            }
        }
        // Each file's date once, then newest first (`.contentModificationDate`).
        const Dated = struct { path: []const u8, at: f64 };
        const dated = try a.alloc(Dated, out.items.len);
        for (dated, out.items) |*d, p| d.* = .{ .path = p, .at = files_mod.modified(p) };
        std.mem.sort(Dated, dated, {}, struct {
            fn later(_: void, x: Dated, y: Dated) bool {
                return x.at > y.at;
            }
        }.later);
        for (out.items, dated) |*p, d| p.* = d.path;
        return out.items;
    }

    /// The one profile's places.sqlite, by its folder's name, or every one
    /// when null.
    pub fn filesOnly(s: Source, a: std.mem.Allocator, base: Base, only: ?[]const u8) ![]const []const u8 {
        const all = try s.files(a, base);
        const wanted = only orelse return all;
        var out: std.ArrayList([]const u8) = .empty;
        for (all) |f| if (std.mem.eql(u8, std.fs.path.basename(std.fs.path.dirname(f).?), wanted)) try out.append(a, f);
        return out.items;
    }

    pub const Ini = struct {
        /// Profile folder → the name it goes by.
        names: std.StringHashMapUnmanaged([]const u8) = .empty,
        /// The Install section's Default, or else the profile marked Default=1.
        usual: ?[]const u8 = null,
    };

    /// What profiles.ini says, beside the profiles or one folder up.
    pub fn ini(s: Source, a: std.mem.Allocator, base: Base) !Ini {
        var out: Ini = .{};
        var install: ?[]const u8 = null;
        var marked: ?[]const u8 = null;
        for (s.folders) |folder| {
            const root = try files_mod.join(a, base.path, folder);
            for ([_][]const u8{ root, std.fs.path.dirname(root) orelse root }) |dir| {
                const bytes = disk.read(a, try files_mod.join(a, dir, "profiles.ini")) orelse continue;
                if (!std.unicode.utf8ValidateSlice(bytes)) continue;
                var section: []const u8 = "";
                var fields: std.StringHashMapUnmanaged([]const u8) = .empty;
                var lines = std.mem.splitAny(u8, bytes, "\r\n");
                while (true) {
                    const raw = lines.next();
                    const line = std.mem.trim(u8, raw orelse "", " \t");
                    const opens = raw != null and line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']';
                    if (raw == null or opens) {
                        // The section just ended.
                        const path = if (fields.get("Path")) |p| std.fs.path.basename(p) else null;
                        if (std.mem.startsWith(u8, section, "Install")) {
                            if (fields.get("Default")) |at| install = install orelse std.fs.path.basename(at);
                        } else if (std.mem.startsWith(u8, section, "Profile")) if (path) |p| {
                            if (fields.get("Name")) |n| if (n.len > 0) try out.names.put(a, p, n);
                            if (fields.get("Default")) |d| if (std.mem.eql(u8, d, "1")) {
                                marked = marked orelse p;
                            };
                        };
                        fields = .empty;
                        if (raw == null) break;
                        section = line[1 .. line.len - 1];
                    } else if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                        try fields.put(a, line[0..eq], line[eq + 1 ..]);
                    }
                }
            }
        }
        out.usual = install orelse marked;
        return out;
    }
};

pub const known = [_]Source{
    .{ .name = "Firefox", .folders = &.{ "Firefox/Profiles", "Firefox" } },
    .{ .name = "Zen", .folders = &.{ "zen/Profiles", "Zen/Profiles", "zen", "Zen" } },
};

// MARK: - what they kept

/// Every profile's bookmarks run together, and whether every
/// places.sqlite read (see `chromium.bookmarkRead`).
pub fn bookmarkRead(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8) !src.BookmarkRead {
    var out: std.ArrayList(Bookmark) = .empty;
    const list = try s.filesOnly(a, base, profile);
    var complete = list.len > 0;
    for (list) |file| {
        const nodes = bookmarkNodes(a, file) catch {
            complete = false;
            continue;
        };
        try out.appendSlice(a, nodes);
    }
    return .{ .nodes = out.items, .complete = complete };
}

const Raw = struct { id: i64, kind: i64, parent: i64, title: []const u8, url: ?[]const u8, guid: []const u8 };

const Tree = struct {
    a: std.mem.Allocator,
    by_parent: std.AutoHashMapUnmanaged(i64, std.ArrayList(Raw)) = .empty,
    taken: std.AutoHashMapUnmanaged(i64, void) = .empty,

    /// A page is type 1, a folder type 2. The tags folder is Firefox's own
    /// bookkeeping. A damaged file can make a folder its own ancestor: each
    /// folder is taken once, and no deeper than 64.
    fn children(t: *Tree, parent: i64, depth: usize) error{OutOfMemory}![]Bookmark {
        var out: std.ArrayList(Bookmark) = .empty;
        if (depth >= 64) return out.items;
        const kids = t.by_parent.get(parent) orelse return out.items;
        for (kids.items) |item| {
            if (item.kind == 1) {
                const address = item.url orelse continue;
                if (!src.isWeb(address)) continue;
                try out.append(t.a, .{ .id = json.Uuid.random(), .title = item.title, .url = address });
                continue;
            }
            if (item.kind != 2 or std.mem.eql(u8, item.guid, "tags________")) continue;
            if ((try t.taken.getOrPut(t.a, item.id)).found_existing) continue;
            try out.append(t.a, Bookmark.folder(if (item.title.len == 0) "Folder" else item.title, try t.children(item.id, depth + 1)));
        }
        return out.items;
    }
};

/// Rows of moz_bookmarks pointing at moz_places, rebuilt into the tree: the
/// toolbar's pages first, then the menu's, then Other and Mobile as folders.
fn bookmarkNodes(a: std.mem.Allocator, file: []const u8) ![]Bookmark {
    var copy = try files_mod.Snapshot.init(a, file);
    defer copy.deinit();
    const db = try sqlite.Db.open(copy.file, sqlite.open_readonly);
    defer db.close();
    const st = try db.prepare(
        \\SELECT b.id, b.type, b.parent, b.title, p.url, b.guid
        \\FROM moz_bookmarks b
        \\LEFT JOIN moz_places p ON b.fk = p.id
        \\WHERE b.type IN (1, 2)
        \\ORDER BY b.position ASC
    );
    defer st.finalize();

    var t: Tree = .{ .a = a };
    var by_guid: std.StringHashMapUnmanaged(Raw) = .empty;
    while (st.step()) {
        const item: Raw = .{
            .id = st.int(0),
            .kind = st.int(1),
            .parent = st.int(2),
            .title = try a.dupe(u8, st.text(3) orelse ""),
            .url = if (st.text(4)) |u| try a.dupe(u8, u) else null,
            .guid = try a.dupe(u8, st.text(5) orelse ""),
        };
        const slot = try t.by_parent.getOrPut(a, item.parent);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(a, item);
        if (item.guid.len > 0) try by_guid.put(a, item.guid, item);
    }

    var out: std.ArrayList(Bookmark) = .empty;
    if (by_guid.get("toolbar_____")) |r| try out.appendSlice(a, try t.children(r.id, 0));
    if (by_guid.get("menu________")) |r| try out.appendSlice(a, try t.children(r.id, 0));
    if (by_guid.get("unfiled_____")) |r| {
        const kids = try t.children(r.id, 0);
        if (kids.len > 0) try out.append(a, Bookmark.folder("Other", kids));
    }
    if (by_guid.get("mobile______")) |r| {
        const kids = try t.children(r.id, 0);
        if (kids.len > 0) try out.append(a, Bookmark.folder("Mobile", kids));
    }
    return out.items;
}

/// The icons for the given pages, host by host, from favicons.sqlite beside
/// places.sqlite.
pub fn icons(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8, urls: []const []const u8, limit: usize) !src.Icons {
    var out: src.Icons = .empty;
    const wanted = try chromium.wantedSites(a, urls, limit);
    if (wanted.len == 0) return out;
    const sql =
        \\SELECT i.data FROM moz_pages_w_icons p
        \\JOIN moz_icons_to_pages m ON m.page_id = p.id
        \\JOIN moz_icons i ON i.id = m.icon_id
        \\WHERE p.page_url = ? AND i.data IS NOT NULL
        \\ORDER BY i.width DESC LIMIT 1
    ;
    for (try s.filesOnly(a, base, profile)) |f| {
        try chromium.iconsFrom(a, try files_mod.join(a, std.fs.path.dirname(f).?, "favicons.sqlite"), sql, wanted, &out);
    }
    return out;
}

// MARK: - where they have been

/// The history, as the same `Place` a Chromium browser gives.
pub fn places(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8, limit: usize) ![]Place {
    var out: std.ArrayList(Place) = .empty;
    const sql = try std.fmt.allocPrint(a,
        \\SELECT url, title, visit_count, last_visit_date FROM moz_places
        \\WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
        \\ORDER BY last_visit_date DESC LIMIT {d}
    , .{limit});
    for (try s.filesOnly(a, base, profile)) |f| chromium.placeRows(a, f, sql, &mozillaDate, &out) catch {};
    return src.newest(out.items, limit);
}

/// Microseconds since 1970 — no 1601 offset, unlike Chromium's.
fn mozillaDate(stamp: i64) f64 {
    return json.fromUnix(@as(f64, @floatFromInt(stamp)) / 1_000_000);
}

// MARK: - passwords

/// The saved logins, and the sites the browser was told never to ask
/// about. `error.PrimaryPassword` only when no profile was open to read.
pub fn read(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8) !src.Found {
    var logins: std.ArrayList(vault.Login) = .empty;
    var never: std.ArrayList([]const u8) = .empty;
    var skipped: usize = 0;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var read_any = false;
    var locked = false;

    for (try s.filesOnly(a, base, profile)) |file| {
        const folder = std.fs.path.dirname(file).?;
        const k4 = try files_mod.join(a, folder, "key4.db");
        const store = try files_mod.join(a, folder, "logins.json");
        if (!files_mod.exists(k4) or !files_mod.exists(store)) continue;
        const key = key4.masterKey(a, k4) catch |e| {
            if (e == error.PrimaryPassword) locked = true;
            continue;
        };
        read_any = true;
        const doc = src.readJson(a, store) orelse continue;
        if (doc != .object) continue;
        for (src.items(src.field(doc, "disabledHosts"))) |h| {
            const clean = try vault.host(a, src.text(h) orelse continue);
            if (clean.len > 0) try never.append(a, clean);
        }
        for (src.items(src.field(doc, "logins"))) |entry| {
            const origin = src.text(src.field(entry, "hostname")) orelse continue;
            const host = try vault.host(a, origin);
            if (host.len == 0) {
                skipped += 1;
                continue;
            }
            const user = key4.decryptLogin(a, src.text(src.field(entry, "encryptedUsername")) orelse continue, key) orelse continue;
            const password = key4.decryptLogin(a, src.text(src.field(entry, "encryptedPassword")) orelse continue, key) orelse continue;
            if (password.len == 0) continue;
            const id = try std.mem.concat(a, u8, &.{ host, "\x01", user });
            if ((try seen.getOrPut(a, id)).found_existing) continue;
            try logins.append(a, .{
                .host = host,
                .user = user,
                .password = password,
                .clear = origin.len >= 7 and std.ascii.eqlIgnoreCase(origin[0..7], "http://"),
            });
        }
    }
    if (!read_any and locked) return error.PrimaryPassword;
    if (!read_any) return error.Unreadable;
    return .{ .logins = logins.items, .never = never.items, .skipped = skipped };
}

/// How much there is to bring, from the files alone: key4.db is not
/// opened, so a primary password is only found out at the click.
pub fn preview(a: std.mem.Allocator, base: Base, s: Source, profile: ?[]const u8, limit: usize) !src.Preview {
    var place_count: usize = 0;
    var passwords: usize = 0;
    for (try s.filesOnly(a, base, profile)) |file| {
        place_count += chromium.count(a,
            \\SELECT COUNT(*) FROM moz_places WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
            \\AND (url LIKE 'http:%' OR url LIKE 'https:%')
        , file);
        const folder = std.fs.path.dirname(file).?;
        if (!files_mod.exists(try files_mod.join(a, folder, "key4.db"))) continue;
        const doc = src.readJson(a, try files_mod.join(a, folder, "logins.json")) orelse continue;
        if (doc != .object) continue;
        for (src.items(src.field(doc, "logins"))) |entry| {
            const pass = src.text(src.field(entry, "encryptedPassword")) orelse continue;
            if (src.text(src.field(entry, "hostname")) != null and pass.len > 0) passwords += 1;
        }
    }
    return .{
        .bookmarks = bookmarks.Bookmarks.count((try bookmarkRead(a, base, s, profile)).nodes),
        .places = @min(limit, place_count),
        .passwords = passwords,
    };
}
