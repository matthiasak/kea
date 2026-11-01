//! Google Drive for Sync (sync.zig): signing in once — your browser, a
//! loopback PKCE flow (gdrive_oauth.zig) — the tokens kept, and the folder
//! picked: "Kea Sync" in My Drive, or one Kea made, browsed to.
const std = @import("std");
const Drop = @import("drop.zig").Drop;
const gdrive = @import("gdrive.zig");
const oauth = @import("gdrive_oauth.zig");
const keychain = @import("../sys/keychain.zig");
const sync_mod = @import("sync.zig");
const Browser = @import("../model/browser.zig").Browser;

const Sync = sync_mod.Sync;
const onMain = sync_mod.onMain;
const dupe = sync_mod.dupe;
const replace = sync_mod.replace;
const Allocator = std.mem.Allocator;

pub const Crumb = struct { id: []u8, name: []u8 };

/// Settings' folder browser: where you are under My Drive, and its folders.
pub const Browse = struct {
    /// On the gpa, My Drive itself not among them.
    crumbs: std.ArrayList(Crumb) = .empty,
    arena: std.heap.ArenaAllocator,
    entries: []const gdrive.FolderEntry = &.{},
    loading: bool = false,

    pub fn deinit(self: *Browse, gpa: Allocator) void {
        self.truncate(gpa, 0);
        self.crumbs.deinit(gpa);
        self.arena.deinit();
    }

    fn truncate(self: *Browse, gpa: Allocator, depth: usize) void {
        while (self.crumbs.items.len > depth) {
            const c = self.crumbs.pop().?;
            gpa.free(c.id);
            gpa.free(c.name);
        }
    }

    pub fn current(self: *const Browse) []const u8 {
        return if (self.crumbs.items.len == 0) "root" else self.crumbs.items[self.crumbs.items.len - 1].id;
    }

    /// "My Drive/…/here", on `a`.
    pub fn path(self: *const Browse, a: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "My Drive");
        for (self.crumbs.items) |c| try out.print(a, "/{s}", .{c.name});
        return out.toOwnedSlice(a);
    }
};

pub const Job = union(enum) {
    list: struct { drop: Drop, parent: []u8 },
    create: struct { drop: Drop, parent: []u8, name: []u8, browser: ?*Browser },
    /// `name` in `parent` found or made, then chosen; `use`: unlocked with the account key after.
    ensure: struct { drop: Drop, parent: []u8, parent_path: []u8, browser: ?*Browser, use: bool },
};

// MARK: main thread

/// Signed in: a Drop on `root` ("" to browse only). Null when not.
pub fn drop(s: *Sync, root: []const u8) ?Drop {
    const refresh = s.drive_refresh orelse return null;
    const id = oauth.resolveClientId(s.gpa, s.drive_client_id) orelse return null;
    defer s.gpa.free(id);
    const secret = oauth.resolveClientSecret(s.gpa, !s.testing());
    defer if (secret) |x| s.gpa.free(x);
    const c = gdrive.Client.init(s.gpa, s.drive_endpoints, id, secret, refresh, if (s.drive_access.len > 0) s.drive_access else null, s.drive_expires, root) catch return null;
    return Drop.drive(s.gpa, c);
}

/// What a Drop learned of the tokens, kept for the next one. Any thread.
pub fn keepTokens(s: *Sync, d: *Drop) void {
    if (d.where != .drive) return;
    onMain(void, keepMain, .{ s, &d.where.drive });
}

fn keepMain(s: *Sync, c: *const gdrive.Client) void {
    replace(s.gpa, &s.drive_access, c.access_token);
    s.drive_expires = c.expires_at;
    if (!c.rotated) return;
    if (s.drive_refresh) |old| s.gpa.free(old);
    s.drive_refresh = dupe(s.gpa, c.refresh_token);
    if (!s.testing()) sync_mod.saveKeychain("drive_refresh", c.refresh_token);
}

pub fn setClientId(s: *Sync, id: []const u8) void {
    const t = std.mem.trim(u8, id, " \t\r\n");
    replace(s.gpa, &s.drive_client_id, t);
    s.kea.store.setString("sync.drive.client_id", t);
}

/// Google's sign-in in your browser; what to say when it can't begin.
pub fn startSignIn(s: *Sync, b: ?*Browser) ?[]const u8 {
    _ = b;
    if (s.drive_flow != null) return null;
    const id = oauth.resolveClientId(s.gpa, s.drive_client_id) orelse return "Enter a Google OAuth Client ID first";
    defer s.gpa.free(id);
    const secret = oauth.resolveClientSecret(s.gpa, !s.testing());
    defer if (secret) |x| s.gpa.free(x);
    s.drive_flow = oauth.LoopbackFlow.start(s.gpa, s.drive_endpoints, id, secret, !s.testing(), .{ .ctx = s, .func = signedIn }) catch return "Couldn't start the sign-in";
    s.drive_signing_in = true;
    s.setStatus("Waiting for Google sign-in in your browser…");
    return null;
}

pub fn cancelSignIn(s: *Sync) void {
    if (s.drive_flow) |f| f.cancel();
}

fn signedIn(ctx: *anyopaque, result: oauth.AuthResult) void {
    const s: *Sync = @ptrCast(@alignCast(ctx));
    defer result.deinit(s.gpa);
    s.drive_flow = null;
    s.drive_signing_in = false;
    switch (result) {
        .ok => |o| {
            if (s.drive_refresh) |old| s.gpa.free(old);
            s.drive_refresh = dupe(s.gpa, o.refresh_token);
            if (!s.testing()) sync_mod.saveKeychain("drive_refresh", o.refresh_token);
            replace(s.gpa, &s.drive_access, o.access_token);
            s.drive_expires = o.expires_at;
            replace(s.gpa, &s.drive_email, o.email);
            s.kea.store.setString("sync.drive.email", o.email);
            s.setStatus(if (s.drive_folder_id.len == 0) "Choose a Google Drive folder" else "Type the passphrase");
        },
        .failed => |why| s.setStatus(why),
        .cancelled => s.setStatus(if (s.drive_refresh == null) "Sign in to Google Drive" else "Type the passphrase"),
    }
}

/// Signed out: the tokens forgotten here (Google keeps the grant until
/// you remove it from your account).
pub fn disconnect(s: *Sync) void {
    cancelSignIn(s);
    if (s.drive_refresh) |old| s.gpa.free(old);
    s.drive_refresh = null;
    replace(s.gpa, &s.drive_access, "");
    replace(s.gpa, &s.drive_email, "");
    s.kea.store.setString("sync.drive.email", "");
    if (!s.testing()) keychain.delete(.{ .service = sync_mod.service, .account = "drive_refresh" });
    if (s.place == .drive) s.forgetKey();
    s.setStatus("Sign in to Google Drive");
}

/// Into `id` (named `name`), or back to My Drive with "root"; its folders listed.
pub fn browse(s: *Sync, id: []const u8, name: []const u8) void {
    if (std.mem.eql(u8, id, "root")) s.browse.truncate(s.gpa, 0) else {
        s.browse.crumbs.append(s.gpa, .{ .id = dupe(s.gpa, id), .name = dupe(s.gpa, name) }) catch return;
    }
    list(s);
}

/// Back up to `depth` folders below My Drive.
pub fn browseBack(s: *Sync, depth: usize) void {
    s.browse.truncate(s.gpa, depth);
    list(s);
}

fn list(s: *Sync) void {
    const d = drop(s, "") orelse return s.setStatus("Sign in to Google Drive");
    s.browse.loading = true;
    s.post(.{ .drive = .{ .list = .{ .drop = d, .parent = dupe(s.gpa, s.browse.current()) } } });
}

/// The browser's current folder, synced to.
pub fn selectCurrent(s: *Sync) void {
    const p = s.browse.path(s.gpa) catch return;
    defer s.gpa.free(p);
    s.chooseDriveFolder(s.browse.current(), p);
}

/// A new folder where the browser is.
pub fn createFolder(s: *Sync, name: []const u8, b: ?*Browser) void {
    const n = std.mem.trim(u8, name, " \t\r\n");
    if (n.len == 0) return s.announceMain("Type a folder name", b);
    const d = drop(s, "") orelse return s.announceMain("Sign in to Google Drive first", b);
    s.post(.{ .drive = .{ .create = .{ .drop = d, .parent = dupe(s.gpa, s.browse.current()), .name = dupe(s.gpa, n), .browser = b } } });
}

/// My Drive's "Kea Sync", found or made, and synced to.
pub fn useKeaSync(s: *Sync, b: ?*Browser) void {
    ensure(s, "root", "My Drive", b, false);
}

/// "Kea Sync" inside the chosen folder, used instead.
pub fn subfolder(s: *Sync, b: ?*Browser) void {
    ensure(s, s.drive_folder_id, s.drive_folder_path, b, s.key_mode == .account_key);
}

fn ensure(s: *Sync, parent: []const u8, parent_path: []const u8, b: ?*Browser, use: bool) void {
    const d = drop(s, "") orelse return s.announceMain("Sign in to Google Drive first", b);
    s.post(.{ .drive = .{ .ensure = .{ .drop = d, .parent = dupe(s.gpa, parent), .parent_path = dupe(s.gpa, parent_path), .browser = b, .use = use } } });
}

fn listed(s: *Sync, parent: []const u8, entries: []const gdrive.FolderEntry) void {
    s.browse.loading = false;
    // Only for where the browser still is.
    if (!std.mem.eql(u8, parent, s.browse.current())) return;
    _ = s.browse.arena.reset(.retain_capacity);
    const a = s.browse.arena.allocator();
    const out = a.alloc(gdrive.FolderEntry, entries.len) catch return;
    for (out, entries) |*o, e| o.* = .{ .id = a.dupe(u8, e.id) catch "", .name = a.dupe(u8, e.name) catch "", .can_write = e.can_write };
    s.browse.entries = out;
    for (s.kea.browsers.items) |b| b.redraw();
}

fn chosen(s: *Sync, id: []const u8, path: []const u8, use: bool, b: ?*Browser) void {
    s.chooseDriveFolder(id, path);
    if (use) if (s.useAccountKey(b)) |say| s.failMain(say, b);
}

// MARK: the queue

pub fn run(s: *Sync, job: Job) void {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    switch (job) {
        .list => |j| {
            var d = j.drop;
            defer {
                keepTokens(s, &d);
                d.deinit();
                s.gpa.free(j.parent);
            }
            const entries = gdrive.listFolders(a, &d, j.parent) catch |e| {
                onMain(void, Sync.setStatus, .{ s, if (e == error.SyncFailed) d.why else "Out of memory" });
                return onMain(void, listed, .{ s, j.parent, @as([]const gdrive.FolderEntry, &.{}) });
            };
            onMain(void, listed, .{ s, j.parent, @as([]const gdrive.FolderEntry, entries) });
        },
        .create => |j| {
            var d = j.drop;
            defer {
                keepTokens(s, &d);
                d.deinit();
                s.gpa.free(j.parent);
                s.gpa.free(j.name);
            }
            _ = gdrive.createFolder(a, &d, j.parent, j.name) catch |e| return onMain(void, Sync.failMain, .{ s, if (e == error.SyncFailed) d.why else "Out of memory", j.browser });
            const entries = gdrive.listFolders(a, &d, j.parent) catch &.{};
            onMain(void, listed, .{ s, j.parent, @as([]const gdrive.FolderEntry, entries) });
        },
        .ensure => |j| {
            var d = j.drop;
            defer {
                keepTokens(s, &d);
                d.deinit();
                s.gpa.free(j.parent);
                s.gpa.free(j.parent_path);
            }
            const f = gdrive.ensureNamedSubfolder(a, &d, j.parent, "Kea Sync") catch |e| return onMain(void, Sync.failMain, .{ s, if (e == error.SyncFailed) d.why else "Out of memory", j.browser });
            const p = std.fmt.allocPrint(a, "{s}/{s}", .{ j.parent_path, f.name }) catch return;
            onMain(void, chosen, .{ s, f.id, @as([]const u8, p), j.use, j.browser });
        },
    }
}
