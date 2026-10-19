//! Updates for an app shipped as a signed bundle on GitHub's releases, the
//! way Harness updates itself. Some seconds after launch, then every few
//! hours, a thread reads the latest release's `manifest.json`:
//!
//!     {"version":"0.1.4","files":{"nanoterm-macos-arm64.zip":{"sha256":"…"}}}
//!
//! When it names a newer version, the zipped app is downloaded into the
//! app's cache, checked against its sha256, unpacked, and kept only if
//! its signature holds and is the running app's own team's. The app then
//! offers "Restart to update" (`restart`). If the user quits instead, the
//! new bundle takes the old one's place as the app ends (`deinit`), and the
//! next launch runs it.
//!
//! Only a bundle that can replace itself takes part: one with a version,
//! signed by a team, and not running from a disk image or translocated.
//! Elsewhere (a build run from zig-out, Linux, Windows) the state stays
//! `off`. Nothing polls: the checks are timers, the work a short thread.
const std = @import("std");
const builtin = @import("builtin");
const mac = builtin.os.tag == .macos;
const objc = if (mac) @import("objc.zig") else struct {};
const desktop = if (mac) @import("desktop.zig") else struct {};

pub const Callback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    /// "owner/repo": its latest release carries `manifest.json` and `asset`.
    repo: []const u8,
    /// The zipped app in each release (`nanoterm-macos-arm64.zip`).
    asset: []const u8,
    /// The app's name: its cache directory (`~/Library/Caches/<name>`).
    name: []const u8,
    /// Called on the main thread when `ready` changes, to redraw.
    changed: ?Callback = null,
    first_ms: u64 = 20 * 1000,
    every_ms: u64 = 6 * 60 * 60 * 1000,
};

pub const Phase = enum(u8) {
    /// This build can't update itself.
    off,
    idle,
    /// A thread is checking or downloading.
    busy,
    /// A newer version is unpacked and verified: `restart` installs it.
    ready,
    /// Installed: it runs from the next launch.
    installed,
};

pub const Updater = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,
    phase: std.atomic.Value(Phase) = .init(.off),
    /// Where the latest release's files are (`NANOUI_UPDATE_FEED` overrides).
    feed: []const u8 = "",
    /// The running bundle, its version, and the app's cache directory.
    bundle: []const u8 = "",
    current: []const u8 = "",
    cache: []const u8 = "",
    /// The newer version and its unpacked bundle, written by the thread
    /// before it publishes `ready`.
    version_buf: [32]u8 = undefined,
    version_len: usize = 0,
    staged_buf: [1024]u8 = undefined,
    staged_len: usize = 0,

    /// Starts checking, if this build can update itself. Call from `main`,
    /// on the main thread; `deinit` before the app ends.
    pub fn start(init: std.process.Init, options: Options) !*Updater {
        const u = try init.gpa.create(Updater);
        u.* = .{ .gpa = init.gpa, .io = init.io, .options = options };
        if (comptime !mac) return u;
        u.detect(init.environ_map) catch return u;
        u.phase.store(.idle, .release);
        objc.dispatchAfter(options.first_ms * std.time.ns_per_ms, u, tick);
        return u;
    }

    /// Installs a version still waiting, for the next launch, and frees
    /// the updater (unless its thread is still at work: the app is ending).
    pub fn deinit(u: *Updater) void {
        if (comptime mac) switch (u.phase.load(.acquire)) {
            .busy => return,
            .ready => u.install() catch |e| std.log.info("nanoui: update not installed: {t}", .{e}),
            else => {},
        };
        u.free();
    }

    /// The newer version that's ready to install, if one is.
    pub fn ready(u: *const Updater) ?[]const u8 {
        if (u.phase.load(.acquire) != .ready) return null;
        return u.version_buf[0..u.version_len];
    }

    /// Checks now (a menu's "Check for Updates"), unless a check is running.
    pub fn checkNow(u: *Updater) void {
        if (comptime !mac) return;
        if (u.phase.cmpxchgStrong(.idle, .busy, .acq_rel, .acquire) != null) return;
        const t = std.Thread.spawn(.{}, work, .{u}) catch {
            u.phase.store(.idle, .release);
            return;
        };
        t.detach();
    }

    /// Installs the ready version and opens it once this process is gone.
    /// On true, quit the app (`App.quit`).
    pub fn restart(u: *Updater) bool {
        if (comptime !mac) return false;
        if (u.phase.load(.acquire) != .ready) return false;
        u.install() catch |e| {
            std.log.info("nanoui: update not installed: {t}", .{e});
            return false;
        };
        relaunch(u.io, u.bundle);
        return true;
    }

    fn free(u: *Updater) void {
        for ([_][]const u8{ u.feed, u.bundle, u.current, u.cache }) |s| if (s.len > 0) u.gpa.free(s);
        u.gpa.destroy(u);
    }

    fn detect(u: *Updater, env: *const std.process.Environ.Map) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const b = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
        const bundle = objc.fromNSString(objc.msg(?objc.Object, b, "bundlePath", .{}));
        if (!replaceable(bundle)) return error.NotReplaceable;
        const info = objc.msg(?objc.Object, b, "infoDictionary", .{}) orelse return error.NoVersion;
        const v = objc.fromNSString(objc.msg(?objc.Object, info, "objectForKey:", .{objc.nsString("CFBundleShortVersionString")}));
        if (!validVersion(v)) return error.NoVersion;
        u.bundle = try u.gpa.dupe(u8, bundle);
        u.current = try u.gpa.dupe(u8, v);
        u.cache = try desktop.path(u.gpa, .cache, u.options.name);
        u.feed = if (env.get("NANOUI_UPDATE_FEED")) |f|
            try u.gpa.dupe(u8, std.mem.trimEnd(u8, f, "/"))
        else
            try std.fmt.allocPrint(u.gpa, "https://github.com/{s}/releases/latest/download", .{u.options.repo});
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const u: *Updater = @ptrCast(@alignCast(ctx));
        // Once installed or waiting, there's nothing more to look for.
        switch (u.phase.load(.acquire)) {
            .ready, .installed => return,
            else => {},
        }
        u.checkNow();
        objc.dispatchAfter(u.options.every_ms * std.time.ns_per_ms, u, tick);
    }

    fn work(u: *Updater) void {
        var arena: std.heap.ArenaAllocator = .init(u.gpa);
        defer arena.deinit();
        const got = u.fetch(arena.allocator()) catch |e| blk: {
            std.log.info("nanoui: no update: {t}", .{e});
            break :blk false;
        };
        u.phase.store(if (got) .ready else .idle, .release);
        if (got) objc.dispatchMain(u, changed);
    }

    fn changed(ctx: ?*anyopaque) callconv(.c) void {
        const u: *Updater = @ptrCast(@alignCast(ctx));
        if (u.options.changed) |cb| cb.func(cb.ctx);
    }

    /// Finds, downloads and verifies a newer version: true once it's staged.
    fn fetch(u: *Updater, a: std.mem.Allocator) !bool {
        const updates = try std.fs.path.join(a, &.{ u.cache, "updates" });
        const manifest = try run(a, u.io, &.{ "/usr/bin/curl", "-fsSL", "--max-time", "30", try url(a, u.feed, "manifest.json") });
        const release = try parseManifest(a, manifest, u.options.asset);
        if (!newer(release.version, u.current)) {
            std.Io.Dir.cwd().deleteTree(u.io, updates) catch {};
            return false;
        }
        const team = parseTeam(try runErr(a, u.io, &.{ "/usr/bin/codesign", "-dv", "--verbose=2", u.bundle })) orelse return error.Unsigned;

        const dir = try std.fs.path.join(a, &.{ updates, release.version });
        std.Io.Dir.cwd().deleteTree(u.io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(u.io, dir);
        // What failed a check isn't kept.
        errdefer std.Io.Dir.cwd().deleteTree(u.io, dir) catch {};
        const zip = try std.fs.path.join(a, &.{ dir, u.options.asset });
        // From the release of that version, not "latest": it can't change underfoot.
        const tagged = try std.fmt.allocPrint(a, "https://github.com/{s}/releases/download/v{s}/{s}", .{ u.options.repo, release.version, u.options.asset });
        const from = if (std.mem.startsWith(u8, u.feed, "https://github.com/")) tagged else try url(a, u.feed, u.options.asset);
        _ = try run(a, u.io, &.{ "/usr/bin/curl", "-fsSL", "--max-time", "900", "-o", zip, from });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(u.io, zip, a, .limited(1 << 30));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        if (!std.ascii.eqlIgnoreCase(&hex, release.sha256)) return error.ChecksumMismatch;

        const unpacked = try std.fs.path.join(a, &.{ dir, "unpacked" });
        _ = try run(a, u.io, &.{ "/usr/bin/ditto", "-x", "-k", zip, unpacked });
        std.Io.Dir.cwd().deleteFile(u.io, zip) catch {};
        const staged = try std.fs.path.join(a, &.{ unpacked, std.fs.path.basename(u.bundle) });
        _ = try run(a, u.io, &.{ "/usr/bin/codesign", "--verify", "--deep", "--strict", staged });
        const their = parseTeam(try runErr(a, u.io, &.{ "/usr/bin/codesign", "-dv", "--verbose=2", staged })) orelse return error.Unsigned;
        if (!std.mem.eql(u8, their, team)) return error.OtherTeam;
        const plist = try std.fs.path.join(a, &.{ staged, "Contents", "Info.plist" });
        const v = try run(a, u.io, &.{ "/usr/bin/plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist });
        if (!std.mem.eql(u8, std.mem.trim(u8, v, " \n"), release.version)) return error.WrongVersion;

        if (staged.len > u.staged_buf.len) return error.NameTooLong;
        @memcpy(u.staged_buf[0..staged.len], staged);
        u.staged_len = staged.len;
        @memcpy(u.version_buf[0..release.version.len], release.version);
        u.version_len = release.version.len;
        return true;
    }

    fn install(u: *Updater) !void {
        const staged = u.staged_buf[0..u.staged_len];
        try swap(u.gpa, u.io, staged, u.bundle);
        u.phase.store(.installed, .release);
        // The unpacked copy is the installed one now.
        if (std.fs.path.dirname(staged)) |unpacked| if (std.fs.path.dirname(unpacked)) |dir| {
            std.Io.Dir.cwd().deleteTree(u.io, dir) catch {};
        };
    }
};

/// Whether a bundle at this path can be replaced by a new one: an app, not
/// on a disk image, not run from the copy Gatekeeper translocated.
pub fn replaceable(bundle: []const u8) bool {
    return std.mem.endsWith(u8, bundle, ".app") and
        !std.mem.startsWith(u8, bundle, "/Volumes/") and
        std.mem.indexOf(u8, bundle, "/AppTranslocation/") == null;
}

/// A plain dotted version, the only kind that names a directory and a tag.
pub fn validVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > 31) return false;
    for (v) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return false;
    return v[0] != '.' and v[v.len - 1] != '.';
}

/// Whether dotted version `latest` is past `current` (0.1.10 > 0.1.9).
/// What doesn't parse is never newer, so a bad manifest can't loop.
pub fn newer(latest: []const u8, current: []const u8) bool {
    const lt = std.mem.trimStart(u8, latest, "v");
    const ct = std.mem.trimStart(u8, current, "v");
    if (!validVersion(lt) or !validVersion(ct)) return false;
    var l = std.mem.splitScalar(u8, lt, '.');
    var c = std.mem.splitScalar(u8, ct, '.');
    while (true) {
        const ls = l.next();
        const cs = c.next();
        if (ls == null and cs == null) return false;
        const lv = if (ls) |s| std.fmt.parseInt(u64, s, 10) catch return false else 0;
        const cv = if (cs) |s| std.fmt.parseInt(u64, s, 10) catch return false else 0;
        if (lv != cv) return lv > cv;
    }
}

pub const Release = struct { version: []const u8, sha256: []const u8 };

/// The version a manifest names and the checksum of `asset` in it.
pub fn parseManifest(a: std.mem.Allocator, json: []const u8, asset: []const u8) !Release {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    if (root != .object) return error.BadManifest;
    const version = root.object.get("version") orelse return error.BadManifest;
    const files = root.object.get("files") orelse return error.BadManifest;
    if (version != .string or files != .object or !validVersion(version.string)) return error.BadManifest;
    const file = files.object.get(asset) orelse return error.NoAsset;
    if (file != .object) return error.BadManifest;
    const sha = file.object.get("sha256") orelse return error.BadManifest;
    if (sha != .string or sha.string.len != 64) return error.BadManifest;
    return .{ .version = version.string, .sha256 = sha.string };
}

/// The team that signed a bundle, from `codesign -dv`'s report; null when
/// it was signed ad hoc.
pub fn parseTeam(report: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const key = "TeamIdentifier=";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const team = std.mem.trim(u8, line[key.len..], " \r");
        if (team.len == 0 or std.mem.eql(u8, team, "not set")) return null;
        return team;
    }
    return null;
}

fn url(a: std.mem.Allocator, feed: []const u8, file: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ feed, file });
}

fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const r = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) });
    if (!r.term.success()) return error.CommandFailed;
    return r.stdout;
}

/// What a command printed on stderr (where codesign reports), if it worked.
fn runErr(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const r = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) });
    if (!r.term.success()) return error.CommandFailed;
    return r.stderr;
}

/// Puts the bundle at `staged` where `bundle` is: a copy beside it first
/// (`ditto` keeps signatures and works across volumes), then two renames,
/// putting the old one back if the second fails.
pub fn swap(gpa: std.mem.Allocator, io: std.Io, staged: []const u8, bundle: []const u8) !void {
    const parent = std.fs.path.dirname(bundle) orelse return error.NoParent;
    const name = std.fs.path.basename(bundle);
    const pid = std.c.getpid();
    const fresh = try std.fmt.allocPrint(gpa, "{s}/.{s}.new-{d}", .{ parent, name, pid });
    defer gpa.free(fresh);
    const old = try std.fmt.allocPrint(gpa, "{s}/.{s}.old-{d}", .{ parent, name, pid });
    defer gpa.free(old);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, fresh) catch {};
    const r = try std.process.run(gpa, io, .{ .argv = &.{ "/usr/bin/ditto", staged, fresh } });
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    if (!r.term.success()) return error.CopyFailed;
    try std.Io.Dir.renameAbsolute(bundle, old, io);
    std.Io.Dir.renameAbsolute(fresh, bundle, io) catch |e| {
        std.Io.Dir.renameAbsolute(old, bundle, io) catch {};
        cwd.deleteTree(io, fresh) catch {};
        return e;
    };
    cwd.deleteTree(io, old) catch {};
}

/// Opens the bundle once this process has exited, from a shell of its own.
fn relaunch(io: std.Io, bundle: []const u8) void {
    var pid: [16]u8 = undefined;
    const p = std.fmt.bufPrint(&pid, "{d}", .{std.c.getpid()}) catch return;
    _ = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"", p, bundle },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |e| std.log.warn("nanoui: can't relaunch: {t}", .{e});
}

test "versions: newer only when past, and never when unparseable" {
    try std.testing.expect(newer("0.1.4", "0.1.3"));
    try std.testing.expect(newer("0.1.10", "0.1.9"));
    try std.testing.expect(newer("v1.0", "0.9.9"));
    try std.testing.expect(newer("0.2", "0.1.9"));
    try std.testing.expect(!newer("0.1.3", "0.1.3"));
    try std.testing.expect(!newer("0.1", "0.1.0"));
    try std.testing.expect(!newer("0.1.2", "0.1.3"));
    try std.testing.expect(!newer("garbage", "0.1.3"));
    try std.testing.expect(!newer("0.2.0-rc1", "0.1.3"));
    try std.testing.expect(validVersion("0.1.4"));
    try std.testing.expect(!validVersion("0.1.4/../x"));
    try std.testing.expect(!validVersion(""));
    try std.testing.expect(!validVersion(".1"));
}

test "a manifest's version and asset checksum; codesign's team" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sha = "4e9d7a9ad956804564c7c1be7b9df9666388fd55bbc17407e9515b4bf174be03";
    const r = try parseManifest(a, "{\"version\":\"0.1.4\",\"files\":{\"x.zip\":{\"sha256\":\"" ++ sha ++ "\"}}}", "x.zip");
    try std.testing.expectEqualStrings("0.1.4", r.version);
    try std.testing.expectEqualStrings(sha, r.sha256);
    try std.testing.expectError(error.NoAsset, parseManifest(a, "{\"version\":\"0.1.4\",\"files\":{}}", "x.zip"));
    try std.testing.expectError(error.BadManifest, parseManifest(a, "{\"version\":\"../1\",\"files\":{}}", "x.zip"));

    try std.testing.expectEqualStrings("ABCDE12345", parseTeam("Executable=/A.app/Contents/MacOS/a\nIdentifier=com.a\nTeamIdentifier=ABCDE12345\n").?);
    try std.testing.expect(parseTeam("Signature=adhoc\nTeamIdentifier=not set\n") == null);
    try std.testing.expect(parseTeam("") == null);
    try std.testing.expect(replaceable("/Applications/nanoterm.app"));
    try std.testing.expect(!replaceable("/Volumes/nanoterm/nanoterm.app"));
    try std.testing.expect(!replaceable("/private/var/folders/x/AppTranslocation/y/d/nanoterm.app"));
    try std.testing.expect(!replaceable("/Users/me/nanoui/zig-out/bin"));
}

test "the staged bundle takes the installed one's place" {
    if (comptime !mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "/tmp/nanoui-test-update";
    cwd.deleteTree(io, root) catch {};
    defer cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, root ++ "/Apps/a.app/Contents");
    try cwd.createDirPath(io, root ++ "/staged/a.app/Contents");
    try cwd.writeFile(io, .{ .sub_path = root ++ "/Apps/a.app/Contents/v", .data = "old" });
    try cwd.writeFile(io, .{ .sub_path = root ++ "/staged/a.app/Contents/v", .data = "new" });
    try swap(gpa, io, root ++ "/staged/a.app", root ++ "/Apps/a.app");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("new", try cwd.readFile(io, root ++ "/Apps/a.app/Contents/v", &buf));
    // Nothing is left beside it.
    var dir = try cwd.openDir(io, root ++ "/Apps", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 1), n);
}
