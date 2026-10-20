//! What another browser exported to a file, brought in (ImportFile.swift):
//! the way in from a browser that can't be read directly, from another Mac,
//! or from Safari, whose own files macOS keeps from other apps. A bookmarks
//! page (.html), a passwords file (.csv), or Safari's own export — a ZIP
//! with its bookmarks, its passwords and a history file per profile, named
//! in the Mac's language, so told apart by what they hold.
//!
//! `read` runs off the main thread (the panel's `sources.Job`); `Control`
//! carries its progress out and its cancellation in.
const std = @import("std");
const objc = @import("nanoui").objc;
const files = @import("files.zig");
const src = @import("sources.zig");
const disk = @import("../data/disk.zig");
const json = @import("../data/json.zig");
const dispatch = @import("../sys/dispatch.zig");
const bookmarks_file = @import("../data/bookmarks_file.zig");
const Bookmark = @import("../data/bookmarks.zig").Bookmark;

extern "c" fn usleep(us: c_uint) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
const SIGKILL = 9;

pub const Progress = struct {
    message: []const u8,
    completed: usize = 0,
    total: ?usize = null,
};

/// A cancellation flag shared with the worker, and its progress, at most
/// about ten updates a second. Counts reset when the message changes and
/// stay monotonic within a phase. The callback runs on the worker's thread,
/// outside the state lock, so it may cancel; `message` lives only for the
/// call.
// ponytail: no second lock serializing callbacks (Swift's NSRecursiveLock); one worker thread reports.
pub const Control = struct {
    lock: std.c.pthread_mutex_t = .{},
    ctx: ?*anyopaque = null,
    progress: ?*const fn (ctx: ?*anyopaque, p: Progress) void = null,
    cancelled: bool = false,
    greatest: usize = 0,
    last_message: [256]u8 = undefined,
    last_len: ?usize = null,
    last_emission: f64 = 0,
    emitted: bool = false,

    pub fn cancel(c: *Control) void {
        _ = std.c.pthread_mutex_lock(&c.lock);
        defer _ = std.c.pthread_mutex_unlock(&c.lock);
        c.cancelled = true;
    }

    pub fn isCancelled(c: *Control) bool {
        _ = std.c.pthread_mutex_lock(&c.lock);
        defer _ = std.c.pthread_mutex_unlock(&c.lock);
        return c.cancelled;
    }

    pub fn check(c: *Control) error{Cancelled}!void {
        if (c.isCancelled()) return error.Cancelled;
    }

    pub fn report(c: *Control, p: Progress) void {
        c.emit(p, false);
    }

    fn emit(c: *Control, p: Progress, force: bool) void {
        _ = std.c.pthread_mutex_lock(&c.lock);
        const msg = p.message[0..@min(p.message.len, c.last_message.len)];
        const changed = c.last_len == null or !std.mem.eql(u8, c.last_message[0..c.last_len.?], msg);
        if (changed) {
            @memcpy(c.last_message[0..msg.len], msg);
            c.last_len = msg.len;
            c.greatest = p.completed;
        } else c.greatest = @max(c.greatest, p.completed);
        const done = c.greatest;
        const out: Progress = .{ .message = p.message, .completed = done, .total = if (p.total) |t| @max(t, done) else null };
        const now = dispatch.CFAbsoluteTimeGetCurrent();
        const go = !c.cancelled and (force or !c.emitted or now - c.last_emission >= 0.1);
        if (go) {
            c.last_emission = now;
            c.emitted = true;
        }
        _ = std.c.pthread_mutex_unlock(&c.lock);
        if (go) if (c.progress) |f| f(c.ctx, out);
    }
};

/// Whether the page has a list in it ("<DL", any case).
fn hasList(bytes: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, i, '<')) |lt| : (i = lt + 1) {
        if (std.ascii.startsWithIgnoreCase(bytes[lt..], "<DL")) return true;
    }
    return false;
}

pub const Found = struct {
    bookmarks: std.ArrayList(Bookmark) = .empty,
    places: std.ArrayList(src.Place) = .empty,
    /// Passwords files' text, for the vault's `takeCsv`.
    passwords: std.ArrayList([]const u8) = .empty,
    /// Safari's export holds passwords in the clear; said once brought in.
    /// Known by its history file, which only Safari's export has.
    from_safari: bool = false,
    safari_history: bool = false,

    pub fn isEmpty(f: Found) bool {
        return f.bookmarks.items.len == 0 and f.places.items.len == 0 and f.passwords.items.len == 0;
    }
};

/// Everything in the file or folder: one file, a folder of them, or a ZIP,
/// opened into a folder of its own and gone afterwards. On `a`.
pub fn read(a: std.mem.Allocator, path: []const u8, control: *Control) !Found {
    var counter: usize = 0;
    var found: Found = .{};
    try control.check();
    const is_zip = std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".zip");
    if (files.isLink(path)) return found;
    if (is_zip) {
        if (try unzip(a, path, control, counter)) |folder| {
            defer files.remove(folder);
            try collect(a, folder, &found, control, &counter);
        }
    } else if (files.isDir(path)) {
        try collect(a, path, &found, control, &counter);
    } else if (files.exists(path)) {
        try take(a, path, null, &found, control, &counter);
    }
    if (is_zip) found.from_safari = found.safari_history;
    control.emit(.{ .message = try std.fmt.allocPrint(a, "{s}: Files read", .{std.fs.path.basename(path)}), .completed = counter }, true);
    try control.check();
    return found;
}

/// Files directly in the folder and in its immediate child folders; deeper
/// folders are never visited.
fn collect(a: std.mem.Allocator, folder: []const u8, found: *Found, control: *Control, counter: *usize) !void {
    if (!files.isDir(folder) or files.isLink(folder)) return;
    const root = std.mem.trimEnd(u8, folder, "/");
    control.report(.{ .message = try std.fmt.allocPrint(a, "{s}: Scanning folders", .{std.fs.path.basename(root)}), .completed = counter.* });
    var list: std.ArrayList([]const u8) = .empty;
    for (try files.list(a, root)) |n| {
        try control.check();
        const item = try files.join(a, root, n);
        if (files.isLink(item)) continue;
        if (files.isDir(item)) {
            for (try files.list(a, item)) |cn| {
                try control.check();
                const child = try files.join(a, item, cn);
                if (!files.isLink(child) and !files.isDir(child) and isImportFile(child)) try list.append(a, child);
            }
            continue;
        }
        if (isImportFile(item)) try list.append(a, item);
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    for (list.items) |file| {
        try control.check();
        // A damaged or unreadable member shouldn't hide the other files.
        take(a, file, root, found, control, counter) catch |e| if (e == error.Cancelled) return e;
    }
}

fn isImportFile(file: []const u8) bool {
    const ext = std.fs.path.extension(file);
    for ([_][]const u8{ ".html", ".htm", ".csv", ".json" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

fn take(a: std.mem.Allocator, file: []const u8, root: ?[]const u8, found: *Found, control: *Control, counter: *usize) !void {
    try control.check();
    const label = if (root) |r| (if (std.mem.startsWith(u8, file, r) and file.len > r.len + 1) file[r.len + 1 ..] else std.fs.path.basename(file)) else std.fs.path.basename(file);
    const ext = std.fs.path.extension(file);
    if (std.ascii.eqlIgnoreCase(ext, ".html") or std.ascii.eqlIgnoreCase(ext, ".htm")) {
        const raw = try readData(a, file, control, label, "Reading bookmark file");
        // UTF-8, or else ISO Latin-1, each byte its own code point.
        const bytes = if (std.unicode.utf8ValidateSlice(raw)) raw else blk: {
            var wide: std.ArrayList(u8) = .empty;
            for (raw) |b| {
                var buf: [2]u8 = undefined;
                const n = std.unicode.utf8Encode(b, &buf) catch unreachable;
                try wide.appendSlice(a, buf[0..n]);
            }
            break :blk wide.items;
        };
        try control.check();
        // BookmarksFile.read: a page with a list in it, or nothing.
        if (hasList(bytes)) {
            try found.bookmarks.appendSlice(a, try bookmarks_file.parse(a, bytes));
            const message = try std.fmt.allocPrint(a, "{s}: Parsing bookmarks", .{label});
            control.report(.{ .message = message, .completed = bytes.len, .total = bytes.len });
        }
    } else if (std.ascii.eqlIgnoreCase(ext, ".csv")) {
        const bytes = try readData(a, file, control, label, "Reading CSV");
        try control.check();
        if (std.unicode.utf8ValidateSlice(bytes)) try found.passwords.append(a, bytes);
    } else if (std.ascii.eqlIgnoreCase(ext, ".json")) {
        if (try history(a, file, control, label)) |list| {
            found.safari_history = true;
            try found.places.appendSlice(a, list);
        }
    }
    counter.* += 1;
    control.report(.{ .message = try std.fmt.allocPrint(a, "{s}: File complete", .{label}), .completed = counter.* });
}

/// Safari's history file: "metadata" whose "data_type" says "history", and
/// "history", one entry per page. The first steps of a redirect, and pages
/// that failed to load, are left out. Null for a file that isn't Safari's
/// history at all.
fn history(a: std.mem.Allocator, file: []const u8, control: *Control, label: []const u8) !?[]src.Place {
    const bytes = try readData(a, file, control, label, "Reading history");
    try control.check();
    const top = src.parseJson(a, bytes) orelse return null;
    const kind = src.text(src.field(src.field(top, "metadata"), "data_type")) orelse return null;
    if (!std.mem.eql(u8, kind, "history")) return null;
    const list = src.field(top, "history") orelse return null;
    if (list != .array) return null;
    const entries = list.array.items;
    try control.check();

    const message = try std.fmt.allocPrint(a, "{s}: Parsing history", .{label});
    var out: std.ArrayList(src.Place) = .empty;
    control.report(.{ .message = message, .total = entries.len });
    for (entries, 0..) |entry, index| {
        try control.check();
        if (entry != .object) return null;
        const failed = if (src.field(entry, "latest_visit_was_load_failure")) |f| f == .bool and f.bool else false;
        if (src.field(entry, "destination_url") == null and !failed) if (src.text(src.field(entry, "url"))) |address| if (src.isWeb(address)) {
            const stamp = number(src.field(entry, "time_usec")) orelse 0;
            const visits = number(src.field(entry, "visits_count")) orelse 1;
            try out.append(a, .{
                .url = address,
                .title = src.text(src.field(entry, "title")) orelse "",
                .count = @max(1, @as(i64, @intFromFloat(visits))),
                .last = if (stamp > 0) json.fromUnix(stamp / 1_000_000) else json.now(),
            });
        };
        if (index % 64 == 63 or index == entries.len - 1) {
            control.report(.{ .message = message, .completed = index + 1, .total = entries.len });
        }
    }
    try control.check();
    return out.items;
}

fn number(v: ?src.Value) ?f64 {
    const n = v orelse return null;
    return switch (n) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// The file's bytes, with progress by bytes read.
// ponytail: one read where Swift reads 64 KB chunks; cancellation lands before and after it.
fn readData(a: std.mem.Allocator, file: []const u8, control: *Control, label: []const u8, stage: []const u8) ![]u8 {
    try control.check();
    const message = try std.fmt.allocPrint(a, "{s}: {s}", .{ label, stage });
    const total: ?usize = if (files.size(file)) |s| @intCast(s) else null;
    control.report(.{ .message = message, .total = total });
    const bytes = disk.read(a, file) orelse return error.Unreadable;
    control.report(.{ .message = message, .completed = bytes.len, .total = total });
    try control.check();
    return bytes;
}

/// The ZIP opened into a folder of its own by the Mac's own ditto; the child
/// is stopped if the import is cancelled, and the folder removed on every
/// unsuccessful path.
fn unzip(a: std.mem.Allocator, zip: []const u8, control: *Control, counter: usize) !?[]const u8 {
    const folder = try files.scratchFolder(a);
    var keep = false;
    defer if (!keep) files.remove(folder);
    try control.check();

    const pool = objc.Pool.push();
    defer pool.pop();
    const task = objc.msg(objc.Object, objc.alloc("NSTask"), "init", .{});
    defer objc.release(task);
    objc.msg(void, task, "setExecutableURL:", .{objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString("/usr/bin/ditto")})});
    const args = [_]objc.Object{ objc.nsString("-x"), objc.nsString("-k"), objc.nsString(zip), objc.nsString(folder) };
    objc.msg(void, task, "setArguments:", .{objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObjects:count:", .{ &args, @as(objc.NSUInteger, args.len) })});
    const null_device = objc.msg(objc.Object, objc.class("NSFileHandle"), "fileHandleWithNullDevice", .{});
    objc.msg(void, task, "setStandardOutput:", .{null_device});
    objc.msg(void, task, "setStandardError:", .{null_device});
    if (!objc.msg(objc.BOOL, task, "launchAndReturnError:", .{@as(?*anyopaque, null)})) return null;

    const message = try std.fmt.allocPrint(a, "{s}: Extracting ZIP", .{std.fs.path.basename(zip)});
    while (objc.msg(objc.BOOL, task, "isRunning", .{})) {
        control.check() catch |e| {
            terminate(task);
            return e;
        };
        control.report(.{ .message = message, .completed = counter });
        _ = usleep(25_000);
    }
    objc.msg(void, task, "waitUntilExit", .{});
    try control.check();
    if (objc.msg(c_int, task, "terminationStatus", .{}) != 0) return null;
    keep = true;
    control.report(.{ .message = try std.fmt.allocPrint(a, "{s}: ZIP extracted", .{std.fs.path.basename(zip)}), .completed = counter });
    return folder;
}

fn terminate(task: objc.Object) void {
    if (objc.msg(objc.BOOL, task, "isRunning", .{})) {
        objc.msg(void, task, "terminate", .{});
        var waited: u32 = 0;
        while (objc.msg(objc.BOOL, task, "isRunning", .{}) and waited < 25) : (waited += 1) _ = usleep(10_000);
        if (objc.msg(objc.BOOL, task, "isRunning", .{})) _ = kill(objc.msg(c_int, task, "processIdentifier", .{}), SIGKILL);
    }
    objc.msg(void, task, "waitUntilExit", .{});
}
