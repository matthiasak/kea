//! Downloads while they happen (Fetching.swift): an `Entry` per file — the
//! Downloads panel's rows — and `Fetches`, the app's running ones: their
//! progress, the Finder's bar on the file, pause, resume, retry, cancel.
//! Files that landed are Loot's (`data/loot.zig`). The window's side —
//! WebKit's delegate, where a file goes, what landed — is
//! `downloads_keep.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const config = @import("config.zig");

pub const State = enum { downloading, pausing, paused, resuming, failed };
pub const StopAction = enum { pause, cancel };

extern "c" fn objc_initWeak(location: *?objc.Object, value: ?objc.Object) ?objc.Object;
extern "c" fn objc_storeWeak(location: *?objc.Object, value: ?objc.Object) ?objc.Object;
extern "c" fn objc_loadWeakRetained(location: *?objc.Object) ?objc.Object;
extern "c" fn objc_destroyWeak(location: *?objc.Object) void;

var serial: u64 = 0;
fn nextId() u64 {
    serial += 1;
    return serial;
}

// MARK: files

const FileVersion = struct { volume: u64, inode: u64, size: u64, modified: f64 };

fn fileManager() objc.Object {
    return objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
}

pub fn exists(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return objc.msg(objc.BOOL, fileManager(), "fileExistsAtPath:", .{objc.nsString(path)});
}

fn removeFile(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.BOOL, fileManager(), "removeItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) });
}

fn number(attrs: objc.Object, key: []const u8) ?u64 {
    const v = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString(key)}) orelse return null;
    return objc.msg(u64, v, "unsignedLongLongValue", .{});
}

fn versionAt(path: []const u8) ?FileVersion {
    const pool = objc.Pool.push();
    defer pool.pop();
    const attrs = objc.msg(?objc.Object, fileManager(), "attributesOfItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) }) orelse return null;
    const date = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("NSFileModificationDate")}) orelse return null;
    return .{
        .volume = number(attrs, "NSFileSystemNumber") orelse return null,
        .inode = number(attrs, "NSFileSystemFileNumber") orelse return null,
        .size = number(attrs, "NSFileSize") orelse return null,
        .modified = objc.msg(f64, date, "timeIntervalSinceReferenceDate", .{}),
    };
}

/// `Browser.fileName`: only the name's last part, never a path out of the
/// folder; nothing usable is "download". On `gpa`.
pub fn fileName(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const last = objc.fromNSString(objc.msg(objc.Object, objc.nsString(name), "lastPathComponent", .{}));
    for ([_][]const u8{ "", ".", "..", "/" }) |bad| if (std.mem.eql(u8, last, bad)) return gpa.dupe(u8, "download");
    return gpa.dupe(u8, last);
}

/// `Browser.free`: WebKit won't write over a file that is there, so the
/// name gains " 2" and on rather than the download quietly failing.
pub fn free(gpa: std.mem.Allocator, name: []const u8, folder: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns = objc.nsString(name);
    const stem = objc.fromNSString(objc.msg(objc.Object, ns, "stringByDeletingPathExtension", .{}));
    const ext = objc.fromNSString(objc.msg(objc.Object, ns, "pathExtension", .{}));
    var candidate = try std.fs.path.join(gpa, &.{ folder, name });
    var n: usize = 2;
    while (exists(candidate)) : (n += 1) {
        gpa.free(candidate);
        const next = if (ext.len == 0)
            try std.fmt.allocPrint(gpa, "{s} {d}", .{ stem, n })
        else
            try std.fmt.allocPrint(gpa, "{s} {d}.{s}", .{ stem, n, ext });
        defer gpa.free(next);
        candidate = try std.fs.path.join(gpa, &.{ folder, next });
    }
    return candidate;
}

pub fn dupe(gpa: std.mem.Allocator, field: *?[]u8, value: ?[]const u8) void {
    const copy = if (value) |v| gpa.dupe(u8, v) catch @panic("OOM") else null;
    if (field.*) |old| gpa.free(old);
    field.* = copy;
}

pub fn swap(field: *?objc.Object, value: ?objc.Object) void {
    const kept = if (value) |v| objc.retain(v) else null;
    if (field.*) |old| objc.release(old);
    field.* = kept;
}

// MARK: a row

/// `FetchEntry`: a download the Downloads panel shows. Its resume data and
/// the cookie store it was asked with live only for this run.
pub const Entry = struct {
    gpa: std.mem.Allocator,
    id: u64,
    state: State = .downloading,
    name: ?[]u8 = null,
    fraction: ?f64 = null,
    completed_bytes: i64 = 0,
    total_bytes: i64 = 0,
    error_description: ?[]u8 = null,
    resume_data: ?objc.Object = null,
    request: ?objc.Object = null,
    /// The page's own view while it is there, weak: the row never keeps it
    /// alive once its tab has closed.
    web_view: ?objc.Object = null,
    store: ?objc.Object = null,
    destination: ?[]u8 = null,
    /// The name asked for, before " 2" and on: a retry is numbered afresh.
    retry_name: ?[]u8 = null,
    download: ?objc.Object = null,
    pending_stop: ?StopAction = null,
    operation_id: u64,
    destination_was_absent: ?bool = null,
    partial: ?FileVersion = null,

    pub fn create(gpa: std.mem.Allocator, name: []const u8, request: ?objc.Object, web_view: ?objc.Object) *Entry {
        const e = gpa.create(Entry) catch @panic("OOM");
        e.* = .{ .gpa = gpa, .id = nextId(), .operation_id = nextId() };
        dupe(gpa, &e.name, name);
        dupe(gpa, &e.retry_name, name);
        swap(&e.request, request);
        _ = objc_initWeak(&e.web_view, web_view);
        if (web_view) |wv| swap(&e.store, objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "websiteDataStore", .{}));
        return e;
    }

    pub fn destroy(e: *Entry) void {
        e.clear();
        objc_destroyWeak(&e.web_view);
        dupe(e.gpa, &e.name, null);
        dupe(e.gpa, &e.retry_name, null);
        e.gpa.destroy(e);
    }

    pub fn label(e: *const Entry) []const u8 {
        return e.name orelse "download";
    }

    /// The page's view, if it is still there (autoreleased).
    pub fn page(e: *Entry) ?objc.Object {
        const v = objc_loadWeakRetained(&e.web_view) orelse return null;
        return objc.msg(objc.Object, v, "autorelease", .{});
    }

    pub fn canPause(e: *const Entry) bool {
        return e.state == .downloading and if (e.request) |r| replayable(r) else false;
    }

    pub fn canResume(e: *const Entry) bool {
        return (e.state == .paused or e.state == .failed) and e.resume_data != null and e.store != null and
            if (e.request) |r| replayable(r) else true;
    }

    /// Asked again from the start: only a plain GET or HEAD.
    pub fn canRetry(e: *const Entry) bool {
        return e.state == .failed and e.store != null and if (e.request) |r| replayable(r) else false;
    }

    pub fn began(e: *Entry, download: objc.Object, operation_id: ?u64) void {
        if (operation_id) |id| if (e.operation_id != id) return;
        e.download = download;
        e.pending_stop = null;
        swap(&e.resume_data, null);
        dupe(e.gpa, &e.error_description, null);
        e.state = .downloading;
        e.operation_id = nextId();
    }

    pub fn record(e: *Entry, progress: objc.Object, track_file: bool) void {
        e.completed_bytes = @max(0, objc.msg(i64, progress, "completedUnitCount", .{}));
        e.total_bytes = @max(0, objc.msg(i64, progress, "totalUnitCount", .{}));
        e.fraction = if (e.total_bytes > 0)
            @min(1, @max(0, @as(f64, @floatFromInt(e.completed_bytes)) / @as(f64, @floatFromInt(e.total_bytes))))
        else
            null;
        if (track_file) e.trackPartialFile();
    }

    /// At a terminal callback progress can be ahead of the last KVO
    /// measurement: size and date refreshed only for a file already claimed.
    pub fn recordTerminal(e: *Entry, progress: objc.Object) void {
        e.record(progress, false);
        if (e.destination_was_absent != true) return;
        const dest = e.destination orelse return;
        const expected = e.partial orelse return;
        const current = versionAt(dest) orelse return;
        if (current.volume == expected.volume and current.inode == expected.inode) e.partial = current;
    }

    pub fn reached(e: *Entry, file: []const u8) void {
        if (e.destination == null or !std.mem.eql(u8, e.destination.?, file)) {
            e.destination_was_absent = !exists(file);
            e.partial = null;
            dupe(e.gpa, &e.destination, file);
        } else if (e.destination_was_absent == null) {
            e.destination_was_absent = !exists(file);
        }
        dupe(e.gpa, &e.name, std.fs.path.basename(file));
    }

    /// The file is the one this download began and nothing else's: removed
    /// only while its identity, size and date still match.
    pub fn discardOwnedPartialFile(e: *Entry) void {
        if (e.destination_was_absent != true) return;
        const dest = e.destination orelse return;
        const expected = e.partial orelse return;
        const current = versionAt(dest) orelse return;
        if (std.meta.eql(current, expected)) removeFile(dest);
    }

    /// Whether a resume would go on writing this download's file and
    /// nothing else: WebKit appends to whatever is at the path.
    pub fn partialFileIsOurs(e: *Entry) bool {
        const dest = e.destination orelse return true;
        const current = versionAt(dest);
        const expected = e.partial orelse return current == null;
        return e.destination_was_absent == true and current != null and std.meta.eql(current.?, expected);
    }

    pub fn lostPartialFile(e: *Entry) void {
        swap(&e.resume_data, null);
        dupe(e.gpa, &e.error_description, "The file changed while the download was stopped.");
        e.state = .failed;
    }

    pub fn stopped(e: *Entry, action: StopAction, data: ?objc.Object) void {
        e.download = null;
        e.pending_stop = null;
        swap(&e.resume_data, if (action == .pause) data else null);
        if (action == .cancel) return e.clear();
        if (data != null) {
            dupe(e.gpa, &e.error_description, null);
            e.state = .paused;
        } else {
            // No resume data: the server can't produce it. Retry stays.
            dupe(e.gpa, &e.error_description, "The server doesn't let this download pause.");
            e.state = .failed;
        }
    }

    pub fn failed(e: *Entry, err: objc.Object, resume_data: ?objc.Object) void {
        e.download = null;
        e.pending_stop = null;
        swap(&e.resume_data, resume_data);
        const pool = objc.Pool.push();
        defer pool.pop();
        const text = std.mem.trim(u8, objc.fromNSString(objc.msg(?objc.Object, err, "localizedDescription", .{})), " \t\r\n");
        dupe(e.gpa, &e.error_description, if (text.len == 0) "The download failed for an unknown reason." else text);
        e.state = .failed;
    }

    pub fn preparingToStop(e: *Entry, action: StopAction) u64 {
        e.state = .pausing;
        e.pending_stop = action;
        e.operation_id = nextId();
        return e.operation_id;
    }

    pub fn preparingToStart(e: *Entry, destination: ?[]const u8) u64 {
        e.state = .resuming;
        dupe(e.gpa, &e.error_description, null);
        // A retry writes a file of its own: nothing claimed before is claimed now.
        if (destination) |d| {
            dupe(e.gpa, &e.destination, d);
            e.destination_was_absent = null;
            e.partial = null;
        }
        e.operation_id = nextId();
        return e.operation_id;
    }

    pub fn clear(e: *Entry) void {
        swap(&e.resume_data, null);
        swap(&e.request, null);
        _ = objc_storeWeak(&e.web_view, null);
        swap(&e.store, null);
        dupe(e.gpa, &e.destination, null);
        e.destination_was_absent = null;
        e.partial = null;
        e.download = null;
        e.pending_stop = null;
        e.operation_id = nextId();
        dupe(e.gpa, &e.error_description, null);
        e.fraction = null;
        e.completed_bytes = 0;
        e.total_bytes = 0;
    }

    fn trackPartialFile(e: *Entry) void {
        if (e.completed_bytes <= 0 or e.destination_was_absent != true) return;
        const current = versionAt(e.destination orelse return) orelse return;
        if (e.partial) |prev| if (prev.volume != current.volume or prev.inode != current.inode) return;
        e.partial = current;
    }
};

pub fn replayable(request: objc.Object) bool {
    const m = objc.fromNSString(objc.msg(?objc.Object, request, "HTTPMethod", .{}));
    const method = if (m.len == 0) "GET" else m;
    return (std.ascii.eqlIgnoreCase(method, "GET") or std.ascii.eqlIgnoreCase(method, "HEAD")) and
        objc.msg(?objc.Object, request, "HTTPBody", .{}) == null and
        objc.msg(?objc.Object, request, "HTTPBodyStream", .{}) == null;
}

/// Is `wv` sending a file to disk (Sleep.swift `awake`: "downloading").
pub fn busy(kea: *Kea, wv: objc.Object) bool {
    for (kea.fetches.running.values()) |item| if (objc.msg(?objc.Object, item.download, "webView", .{}) == wv) return true;
    return false;
}

pub const fetches_part = @import("downloads_fetches.zig");
pub const Fetches = fetches_part.Fetches;
pub const Running = fetches_part.Running;
pub const Op = fetches_part.Op;
pub const Stop = fetches_part.Stop;
pub const Ended = fetches_part.Ended;

/// `Fetches.view(for:store:)`: the page's view while its tab is open;
/// otherwise one of the attempt's own on the same store (+1, `helper`).
pub fn viewFor(kea: *Kea, e: *Entry, store: objc.Object) struct { objc.Object, bool } {
    if (e.page()) |p| {
        const its = objc.msg(objc.Object, objc.msg(objc.Object, p, "configuration", .{}), "websiteDataStore", .{});
        if (its == store) return .{ objc.retain(p), false };
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const conf = objc.new("WKWebViewConfiguration");
    defer objc.release(conf);
    objc.msg(void, conf, "setWebsiteDataStore:", .{store});
    objc.msg(void, conf, "setProcessPool:", .{config.processPool()});
    objc.msg(void, conf, "setApplicationNameForUserAgent:", .{objc.nsString(config.userAgentName())});
    if (kea.opts.scheme_handler) |h| objc.msg(void, conf, "setURLSchemeHandler:forURLScheme:", .{ h, objc.nsString("kea-test") });
    const view = objc.msg(objc.Object, objc.alloc("WKWebView"), "initWithFrame:configuration:", .{ objc.CGRect{}, conf });
    return .{ view, true };
}

test "file names never leave the folder" {
    const gpa = std.testing.allocator;
    for ([_][2][]const u8{ .{ "", "download" }, .{ "..", "download" }, .{ "/", "download" }, .{ "a/b/c.txt", "c.txt" }, .{ "../x.pdf", "x.pdf" } }) |c| {
        const got = try fileName(gpa, c[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "a taken name gains the next number" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    const pool = objc.Pool.push();
    defer pool.pop();
    for ([_][]const u8{ "a.txt", "a 2.txt", "notes" }) |name| {
        const p = try t.path(gpa, name);
        defer gpa.free(p);
        _ = objc.msg(objc.BOOL, objc.msg(objc.Object, objc.class("NSData"), "data", .{}), "writeToFile:atomically:", .{ objc.nsString(p), objc.NO });
    }
    const cases = [_][2][]const u8{ .{ "a.txt", "a 3.txt" }, .{ "notes", "notes 2" }, .{ "b.pdf", "b.pdf" } };
    for (cases) |c| {
        const got = try free(gpa, c[0], t.root);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c[1], std.fs.path.basename(got));
    }
}
