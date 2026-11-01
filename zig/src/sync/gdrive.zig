//! Google Drive as a sync drop (`Drop.where.drive`): logical names like
//! "kea/v2/packs/<hex>.pack" map onto folders and files under the chosen
//! sync folder, through Drive's REST v3. Blocking, like every Drop call;
//! folder browsing for Settings, too.
const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const urlsession = @import("../sys/urlsession.zig");
const uriEncode = @import("sigv4.zig").uriEncode;
const oauth = @import("gdrive_oauth.zig");
const drop = @import("drop.zig");
const Drop = drop.Drop;
const Error = drop.Error;
const SwiftDate = json.SwiftDate;

const folder_mime = "application/vnd.google-apps.folder";
const file_fields = "id,name,mimeType,modifiedTime,size,trashed,capabilities/canAddChildren";
const boundary = "kea_sync_boundary";

pub const FileMeta = struct { id: []u8, mtime: SwiftDate, size: u64 };
pub const FolderEntry = struct { id: []const u8, name: []const u8, can_write: bool };

/// Signed in to one account, at one sync folder. What it learns of the
/// folder's layout is kept for the Drop's life.
pub const Client = struct {
    gpa: Allocator,
    endpoints: oauth.AuthEndpoints,
    client_id: []u8,
    client_secret: ?[]u8,
    /// Replaced when Google hands out another; then `rotated`.
    refresh_token: []u8,
    rotated: bool = false,
    access_token: []u8,
    expires_at: SwiftDate,
    /// "" while only browsing folders.
    root_folder_id: []u8,
    session: objc.Object,
    /// Logical folder ("kea/v2/heads") → its id.
    dir_cache: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Logical name → the file.
    file_cache: std.StringHashMapUnmanaged(FileMeta) = .empty,
    root_checked: bool = false,

    /// Every string copied.
    pub fn init(gpa: Allocator, endpoints: oauth.AuthEndpoints, client_id: []const u8, client_secret: ?[]const u8, refresh_token: []const u8, access_token: ?[]const u8, expires_at: SwiftDate, root_folder_id: []const u8) !Client {
        var c: Client = .{
            .gpa = gpa,
            .endpoints = .{ .auth_url = "", .token_url = "", .api_base = "", .upload_base = "" },
            .client_id = &.{},
            .client_secret = null,
            .refresh_token = &.{},
            .access_token = &.{},
            .expires_at = expires_at,
            .root_folder_id = &.{},
            .session = urlsession.ephemeral(30),
        };
        errdefer c.deinit();
        c.endpoints.auth_url = try gpa.dupe(u8, endpoints.auth_url);
        c.endpoints.token_url = try gpa.dupe(u8, endpoints.token_url);
        c.endpoints.api_base = try gpa.dupe(u8, endpoints.api_base);
        c.endpoints.upload_base = try gpa.dupe(u8, endpoints.upload_base);
        c.client_id = try gpa.dupe(u8, client_id);
        if (client_secret) |s| c.client_secret = try gpa.dupe(u8, s);
        c.refresh_token = try gpa.dupe(u8, refresh_token);
        c.access_token = try gpa.dupe(u8, access_token orelse "");
        c.root_folder_id = try gpa.dupe(u8, root_folder_id);
        return c;
    }

    pub fn deinit(self: *Client) void {
        const e = self.endpoints;
        for ([_][]const u8{ e.auth_url, e.token_url, e.api_base, e.upload_base }) |s| self.gpa.free(s);
        for ([_][]u8{ self.client_id, self.client_secret orelse &.{}, self.refresh_token, self.access_token, self.root_folder_id }) |s| self.gpa.free(s);
        var dirs = self.dir_cache.iterator();
        while (dirs.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.gpa.free(kv.value_ptr.*);
        }
        self.dir_cache.deinit(self.gpa);
        var files = self.file_cache.iterator();
        while (files.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.gpa.free(kv.value_ptr.id);
        }
        self.file_cache.deinit(self.gpa);
        objc.release(self.session);
    }

    fn rememberDir(self: *Client, dir: []const u8, id: []const u8) error{OutOfMemory}!void {
        if (self.dir_cache.contains(dir)) return;
        const k = try self.gpa.dupe(u8, dir);
        errdefer self.gpa.free(k);
        const v = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(v);
        try self.dir_cache.put(self.gpa, k, v);
    }

    fn rememberFile(self: *Client, name: []const u8, f: FileJ) error{OutOfMemory}!void {
        const id = try self.gpa.dupe(u8, f.id);
        errdefer self.gpa.free(id);
        const meta: FileMeta = .{ .id = id, .mtime = f.mtime(), .size = f.bytes() };
        if (self.file_cache.getPtr(name)) |m| {
            self.gpa.free(m.id);
            m.* = meta;
            return;
        }
        const k = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(k);
        try self.file_cache.put(self.gpa, k, meta);
    }

    fn forgetFile(self: *Client, name: []const u8) void {
        const kv = self.file_cache.fetchRemove(name) orelse return;
        self.gpa.free(kv.key);
        self.gpa.free(kv.value.id);
    }
};

/// A file as Drive describes it (`files` resource, the fields we ask for).
const FileJ = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    mimeType: []const u8 = "",
    modifiedTime: []const u8 = "",
    size: ?[]const u8 = null,
    trashed: bool = false,
    capabilities: struct { canAddChildren: bool = false } = .{},

    fn folder(f: FileJ) bool {
        return std.mem.eql(u8, f.mimeType, folder_mime);
    }
    fn mtime(f: FileJ) SwiftDate {
        return drop.parseDate(f.modifiedTime) orelse json.fromUnix(0);
    }
    fn bytes(f: FileJ) u64 {
        return std.fmt.parseInt(u64, f.size orelse "0", 10) catch 0;
    }
};

fn client(d: *Drop) *Client {
    return &d.where.drive;
}

fn parse(comptime T: type, d: *Drop, a: Allocator, body: []const u8) Error!T {
    return std.json.parseFromSliceLeaky(T, a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => d.fail(a, "Google Drive's answer made no sense", .{}),
    };
}

/// A Drive query string literal: `'it\'s'`.
fn quote(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '\'');
    for (s) |ch| {
        if (ch == '\\' or ch == '\'') try out.append(a, '\\');
        try out.append(a, ch);
    }
    try out.append(a, '\'');
    return out.items;
}

fn ok(r: urlsession.Response) bool {
    return r.code >= 200 and r.code < 300;
}

fn refused(d: *Drop, a: Allocator, r: urlsession.Response) Error {
    if (r.code == 403 and std.mem.indexOf(u8, r.body, "storageQuotaExceeded") != null) return d.fail(a, "Google Drive storage is full", .{});
    return d.fail(a, "Google Drive answered {d}", .{r.code});
}

fn refresh(d: *Drop, a: Allocator) Error!void {
    const c = client(d);
    const t = oauth.refreshAccessToken(a, c.session, c.endpoints, c.client_id, c.client_secret, c.refresh_token) catch |e| return switch (e) {
        error.AuthRevoked => d.fail(a, "Google Drive sign-in expired — sign in again", .{}),
        error.SyncFailed => d.fail(a, "Can't reach Google Drive", .{}),
        error.OutOfMemory => error.OutOfMemory,
    };
    const access = try c.gpa.dupe(u8, t.access_token);
    c.gpa.free(c.access_token);
    c.access_token = access;
    c.expires_at = json.now() + t.expires_in;
    if (t.refresh_token) |r| if (!std.mem.eql(u8, r, c.refresh_token)) {
        const kept = try c.gpa.dupe(u8, r);
        c.gpa.free(c.refresh_token);
        c.refresh_token = kept;
        c.rotated = true;
    };
}

/// One call, signed in: the token renewed when stale or refused (once), and
/// tried once more after a moment when Drive is busy.
fn call(d: *Drop, a: Allocator, method: []const u8, url: []const u8, content_type: ?[]const u8, body: ?[]const u8) Error!urlsession.Response {
    const c = client(d);
    var renewed = false;
    if (c.access_token.len == 0 or json.now() >= c.expires_at - 60) {
        try refresh(d, a);
        renewed = true;
    }
    var retried = false;
    while (true) {
        const headers = [_][2][]const u8{ .{ "Authorization", try std.fmt.allocPrint(a, "Bearer {s}", .{c.access_token}) }, .{ "Content-Type", content_type orelse "" } };
        const r = (urlsession.send(a, c.session, method, url, headers[0..if (content_type != null) 2 else 1], body) catch return error.OutOfMemory) orelse
            return d.fail(a, "Can't reach Google Drive", .{});
        if (r.code == 401 and !renewed) {
            renewed = true;
            try refresh(d, a);
            continue;
        }
        const busy = r.code == 429 or r.code == 500 or r.code == 502 or r.code == 503 or r.code == 504;
        if (busy and !retried) {
            retried = true;
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 250 * std.time.ns_per_ms }, null);
            continue;
        }
        return r;
    }
}

fn fileURL(a: Allocator, base: []const u8, id: []const u8, rest: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/files/{s}?{s}", .{ base, try uriEncode(a, id, true), rest });
}

/// Every child of `parent` not in Trash and matching `also` (more query,
/// or ""), every page.
fn children(d: *Drop, a: Allocator, parent: []const u8, also: []const u8) Error![]const FileJ {
    const c = client(d);
    const q = try std.fmt.allocPrint(a, "{s} in parents and trashed = false{s}{s}", .{ try quote(a, parent), if (also.len > 0) " and " else "", also });
    var out: std.ArrayList(FileJ) = .empty;
    var token: ?[]const u8 = null;
    while (true) {
        var url: std.ArrayList(u8) = .empty;
        try url.print(a, "{s}/files?q={s}&fields=nextPageToken,files({s})&pageSize=1000", .{ c.endpoints.api_base, try uriEncode(a, q, true), file_fields });
        if (token) |t| try url.print(a, "&pageToken={s}", .{try uriEncode(a, t, true)});
        const r = try call(d, a, "GET", url.items, null, null);
        if (!ok(r)) return refused(d, a, r);
        const page = try parse(struct { nextPageToken: ?[]const u8 = null, files: []const FileJ = &.{} }, d, a, r.body);
        try out.appendSlice(a, page.files);
        token = page.nextPageToken orelse break;
        if (token.?.len == 0) break;
    }
    return out.items;
}

fn folderQuery(a: Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "name = {s} and mimeType = '{s}'", .{ try quote(a, name), folder_mime });
}

fn makeFolder(d: *Drop, a: Allocator, parent: []const u8, name: []const u8) Error!FileJ {
    const c = client(d);
    const meta = try json.encode(a, .{ .name = name, .mimeType = folder_mime, .parents = @as([]const []const u8, &.{parent}) });
    const r = try call(d, a, "POST", try std.fmt.allocPrint(a, "{s}/files?fields={s}", .{ c.endpoints.api_base, file_fields }), "application/json; charset=UTF-8", meta);
    if (!ok(r)) return refused(d, a, r);
    return parse(FileJ, d, a, r.body);
}

/// Once a Drop: the sync folder is there, not in Trash, and ours to add to.
fn verifyRoot(d: *Drop, a: Allocator) Error!void {
    const c = client(d);
    if (c.root_checked) return;
    if (c.root_folder_id.len == 0) return d.fail(a, "Choose a Google Drive folder first", .{});
    const r = try call(d, a, "GET", try fileURL(a, c.endpoints.api_base, c.root_folder_id, "fields=" ++ file_fields), null, null);
    if (r.code == 404) return d.fail(a, "The Google Drive sync folder wasn't found — it may have been deleted or unshared", .{});
    if (!ok(r)) return refused(d, a, r);
    const f = try parse(FileJ, d, a, r.body);
    if (f.trashed) return d.fail(a, "The Google Drive sync folder is in Trash — restore it in Drive or choose another folder", .{});
    if (!f.folder()) return d.fail(a, "That isn't a Google Drive folder", .{});
    if (!f.capabilities.canAddChildren) return d.fail(a, "The Google Drive sync folder is read-only — choose a folder you can edit", .{});
    c.root_checked = true;
}

/// The folder for logical `dir` ("" is the root): made when `create`, else
/// null when it isn't there. Of namesakes, the smallest id, as every Mac picks.
fn folderFor(d: *Drop, a: Allocator, dir: []const u8, create: bool) Error!?[]const u8 {
    const c = client(d);
    if (dir.len == 0) return c.root_folder_id;
    if (c.dir_cache.get(dir)) |id| return id;
    const slash = std.mem.lastIndexOfScalar(u8, dir, '/');
    const parent = try folderFor(d, a, if (slash) |i| dir[0..i] else "", create) orelse return null;
    const name = if (slash) |i| dir[i + 1 ..] else dir;
    var pick: ?[]const u8 = null;
    for (try children(d, a, parent, try folderQuery(a, name))) |f| {
        if (pick == null or std.mem.lessThan(u8, f.id, pick.?)) pick = f.id;
    }
    const id = pick orelse if (create) (try makeFolder(d, a, parent, name)).id else return null;
    try c.rememberDir(dir, id);
    return c.dir_cache.get(dir).?;
}

const Split = struct { dir: []const u8, base: []const u8 };

fn split(name: []const u8) Split {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return .{ .dir = "", .base = name };
    return .{ .dir = name[0..slash], .base = name[slash + 1 ..] };
}

/// `name`'s file, from what's known or else Drive (the newest of
/// namesakes); `cached` when it may be stale.
fn lookup(d: *Drop, a: Allocator, name: []const u8) Error!?struct { meta: FileMeta, cached: bool } {
    const c = client(d);
    if (c.file_cache.get(name)) |m| return .{ .meta = .{ .id = try a.dupe(u8, m.id), .mtime = m.mtime, .size = m.size }, .cached = true };
    const s = split(name);
    const parent = try folderFor(d, a, s.dir, false) orelse return null;
    var best: ?FileJ = null;
    for (try children(d, a, parent, try std.fmt.allocPrint(a, "name = {s}", .{try quote(a, s.base)}))) |f| {
        if (!f.folder() and (best == null or f.mtime() > best.?.mtime())) best = f;
    }
    const f = best orelse return null;
    try c.rememberFile(name, f);
    return .{ .meta = .{ .id = try a.dupe(u8, f.id), .mtime = f.mtime(), .size = f.bytes() }, .cached = false };
}

pub fn list(d: *Drop, a: Allocator, prefix: []const u8) Error!drop.Names {
    try verifyRoot(d, a);
    const clean = if (prefix.len == 0 or std.mem.endsWith(u8, prefix, "/")) prefix else try std.fmt.allocPrint(a, "{s}/", .{prefix});
    var out: drop.Names = .empty;
    const id = try folderFor(d, a, std.mem.trimEnd(u8, clean, "/"), false) orelse return out;
    try walk(d, a, id, clean, &out);
    return out;
}

fn walk(d: *Drop, a: Allocator, id: []const u8, at: []const u8, out: *drop.Names) Error!void {
    const c = client(d);
    for (try children(d, a, id, "")) |f| {
        const name = try std.fmt.allocPrint(a, "{s}{s}", .{ at, f.name });
        if (f.folder()) {
            try c.rememberDir(name, f.id);
            try walk(d, a, f.id, try std.fmt.allocPrint(a, "{s}/", .{name}), out);
            continue;
        }
        const t = f.mtime();
        if (out.get(name)) |seen| if (seen >= t) continue;
        try out.put(a, name, t);
        try c.rememberFile(name, f);
    }
}

pub fn get(d: *Drop, a: Allocator, name: []const u8) Error!?[]u8 {
    try verifyRoot(d, a);
    const c = client(d);
    while (true) {
        const found = try lookup(d, a, name) orelse return null;
        const r = try call(d, a, "GET", try fileURL(a, c.endpoints.api_base, found.meta.id, "alt=media"), null, null);
        const short = ok(r) and found.meta.size > 0 and r.body.len != found.meta.size;
        if (found.cached and (r.code == 404 or short)) {
            // Gone or rewritten since we looked: ask again.
            c.forgetFile(name);
            continue;
        }
        if (r.code == 404) return null;
        if (!ok(r)) return refused(d, a, r);
        if (short) return d.fail(a, "Incomplete download from Google Drive", .{});
        return r.body;
    }
}

pub fn put(d: *Drop, a: Allocator, name: []const u8, data: []const u8) Error!void {
    try verifyRoot(d, a);
    const c = client(d);
    if (try lookup(d, a, name)) |found| {
        const r = try call(d, a, "PATCH", try fileURL(a, c.endpoints.upload_base, found.meta.id, "uploadType=media&fields=" ++ file_fields), "application/octet-stream", data);
        if (ok(r)) return c.rememberFile(name, try parse(FileJ, d, a, r.body));
        if (r.code != 404) return refused(d, a, r);
        c.forgetFile(name);
    }
    const s = split(name);
    const parent = (try folderFor(d, a, s.dir, true)).?;
    const meta = try json.encode(a, .{ .name = s.base, .parents = @as([]const []const u8, &.{parent}) });
    // ponytail: data containing the boundary line would break the part; sealed objects are random bytes.
    var body: std.ArrayList(u8) = .empty;
    try body.print(a, "--{0s}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{1s}\r\n--{0s}\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, meta });
    try body.appendSlice(a, data);
    try body.print(a, "\r\n--{s}--\r\n", .{boundary});
    const url = try std.fmt.allocPrint(a, "{s}/files?uploadType=multipart&fields={s}", .{ c.endpoints.upload_base, file_fields });
    const r = try call(d, a, "POST", url, "multipart/related; boundary=" ++ boundary, body.items);
    if (!ok(r)) return refused(d, a, r);
    try c.rememberFile(name, try parse(FileJ, d, a, r.body));
}

/// Every file of that name goes; none is fine.
pub fn delete(d: *Drop, a: Allocator, name: []const u8) Error!void {
    try verifyRoot(d, a);
    const c = client(d);
    c.forgetFile(name);
    const s = split(name);
    const parent = try folderFor(d, a, s.dir, false) orelse return;
    for (try children(d, a, parent, try std.fmt.allocPrint(a, "name = {s}", .{try quote(a, s.base)}))) |f| {
        if (f.folder()) continue;
        const r = try call(d, a, "DELETE", try fileURL(a, c.endpoints.api_base, f.id, ""), null, null);
        if (!ok(r) and r.code != 404) return refused(d, a, r);
    }
}

/// The sync folder's own entries' names, for `Drop.inspectRoot`.
pub fn rootNames(d: *Drop, a: Allocator, names: *std.ArrayList([]const u8)) Error!void {
    try verifyRoot(d, a);
    for (try children(d, a, client(d).root_folder_id, "")) |f| try names.append(a, f.name);
}

// MARK: folder browsing, for Settings

fn entry(f: FileJ) FolderEntry {
    return .{ .id = f.id, .name = f.name, .can_write = f.capabilities.canAddChildren };
}

/// The folders in `parent_id` ("root": My Drive), by name. On `a`.
pub fn listFolders(a: Allocator, d: *Drop, parent_id: []const u8) Error![]FolderEntry {
    const found = try children(d, a, parent_id, "mimeType = '" ++ folder_mime ++ "'");
    const out = try a.alloc(FolderEntry, found.len);
    for (out, found) |*o, f| o.* = entry(f);
    std.mem.sort(FolderEntry, out, {}, struct {
        fn lt(_: void, x: FolderEntry, y: FolderEntry) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
    return out;
}

pub fn createFolder(a: Allocator, d: *Drop, parent_id: []const u8, name: []const u8) Error!FolderEntry {
    return entry(try makeFolder(d, a, parent_id, name));
}

/// `name` in `parent_id`, one we can add to; made when there's none.
pub fn ensureNamedSubfolder(a: Allocator, d: *Drop, parent_id: []const u8, name: []const u8) Error!FolderEntry {
    for (try children(d, a, parent_id, try folderQuery(a, name))) |f| if (f.capabilities.canAddChildren) return entry(f);
    return createFolder(a, d, parent_id, name);
}
