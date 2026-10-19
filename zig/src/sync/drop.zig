//! One place every Mac reads and writes, by name — "kea/v1/devices/<uuid>/
//! bookmarks.kea" (`SyncDrop`, `FolderDrop`, `BucketDrop` in SyncCore.swift).
//! Every call blocks: off the main thread, but in tests.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const core = @import("core.zig");
const sigv4 = @import("sigv4.zig");
const urlsession = @import("../sys/urlsession.zig");
const local_network = @import("../web/local_network.zig");
const Parts = @import("../data/url.zig").Parts;

const SwiftDate = json.SwiftDate;
/// Every name under a prefix, with when it last changed.
pub const Names = std.StringArrayHashMapUnmanaged(SwiftDate);
pub const Error = error{ SyncFailed, OutOfMemory };

pub const Drop = struct {
    gpa: std.mem.Allocator,
    where: union(enum) { folder: []u8, bucket: Bucket },
    /// Why the last call failed (`SyncError.errorDescription` or the file
    /// system's own words), on the arena the call was given.
    why: []const u8 = "",

    pub const Bucket = struct {
        endpoint: []u8,
        bucket: []u8,
        access: []u8,
        secret: []u8,
        region: []const u8 = "auto",
        /// Ephemeral, 30 s a request; retained.
        session: objc.Object,
    };

    pub fn folder(gpa: std.mem.Allocator, root: []const u8) !Drop {
        return .{ .gpa = gpa, .where = .{ .folder = try gpa.dupe(u8, root) } };
    }

    pub fn bucket(gpa: std.mem.Allocator, endpoint: []const u8, name: []const u8, access: []const u8, secret: []const u8) !Drop {
        return .{ .gpa = gpa, .where = .{ .bucket = .{
            .endpoint = try gpa.dupe(u8, endpoint),
            .bucket = try gpa.dupe(u8, name),
            .access = try gpa.dupe(u8, access),
            .secret = try gpa.dupe(u8, secret),
            .session = urlsession.ephemeral(30),
        } } };
    }

    pub fn deinit(self: *Drop) void {
        switch (self.where) {
            .folder => |r| self.gpa.free(r),
            .bucket => |b| {
                for ([_][]u8{ b.endpoint, b.bucket, b.access, b.secret }) |s| self.gpa.free(s);
                objc.release(b.session);
            },
        }
    }

    /// `BucketDrop.allowed`: https, or http only to this Mac.
    pub fn allowed(endpoint: []const u8) bool {
        const p = Parts.parse(endpoint) orelse return false;
        const scheme = p.scheme orelse return false;
        const host = p.host orelse return false;
        if (host.len == 0) return false;
        if (std.ascii.eqlIgnoreCase(scheme, "https")) return true;
        return std.ascii.eqlIgnoreCase(scheme, "http") and local_network.onThisMac(host);
    }

    fn fail(self: *Drop, a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Error {
        self.why = try std.fmt.allocPrint(a, fmt, args);
        return error.SyncFailed;
    }

    /// Every name under `prefix` (ending in "/"), on `a`.
    pub fn list(self: *Drop, a: std.mem.Allocator, prefix: []const u8) Error!Names {
        return switch (self.where) {
            .folder => |root| self.folderList(a, root, prefix),
            .bucket => |b| self.bucketList(a, b, prefix),
        };
    }

    /// null when nothing has that name. On `a`.
    pub fn get(self: *Drop, a: std.mem.Allocator, name: []const u8) Error!?[]u8 {
        switch (self.where) {
            .folder => |root| {
                try self.checkRoot(a, root);
                const pool = objc.Pool.push();
                defer pool.pop();
                const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name });
                if (!objc.msg(objc.BOOL, fm(), "fileExistsAtPath:", .{objc.nsString(path)})) return null;
                var err: ?objc.Object = null;
                const d = objc.msg(?objc.Object, objc.class("NSData"), "dataWithContentsOfFile:options:error:", .{ objc.nsString(path), @as(objc.NSUInteger, 0), &err }) orelse
                    return self.failWith(a, err);
                return try copyData(a, d);
            },
            .bucket => |b| {
                const r = try self.send(a, b, "GET", try objectURL(a, b, name), null);
                if (r.code == 200) return r.body;
                if (r.code == 404) return null;
                return self.refused(a, r.code);
            },
        }
    }

    pub fn put(self: *Drop, a: std.mem.Allocator, name: []const u8, data: []const u8) Error!void {
        switch (self.where) {
            .folder => |root| {
                try self.checkRoot(a, root);
                const pool = objc.Pool.push();
                defer pool.pop();
                const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name });
                var err: ?objc.Object = null;
                const dir = objc.nsString(std.fs.path.dirname(path) orelse root);
                if (!objc.msg(objc.BOOL, fm(), "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{ dir, objc.YES, @as(?objc.Object, null), &err }))
                    return self.failWith(a, err);
                const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ data.ptr, @as(objc.NSUInteger, data.len) });
                // NSDataWritingAtomic
                if (!objc.msg(objc.BOOL, d, "writeToFile:options:error:", .{ objc.nsString(path), @as(objc.NSUInteger, 1), &err }))
                    return self.failWith(a, err);
            },
            .bucket => |b| {
                const r = try self.send(a, b, "PUT", try objectURL(a, b, name), data);
                if (r.code < 200 or r.code >= 300) return self.refused(a, r.code);
            },
        }
    }

    pub fn delete(self: *Drop, a: std.mem.Allocator, name: []const u8) Error!void {
        switch (self.where) {
            .folder => |root| {
                try self.checkRoot(a, root);
                const pool = objc.Pool.push();
                defer pool.pop();
                const path = objc.nsString(try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name }));
                if (!objc.msg(objc.BOOL, fm(), "fileExistsAtPath:", .{path})) return;
                _ = objc.msg(objc.BOOL, fm(), "removeItemAtPath:error:", .{ path, @as(?*anyopaque, null) });
            },
            .bucket => |b| {
                const r = try self.send(a, b, "DELETE", try objectURL(a, b, name), null);
                if ((r.code < 200 or r.code >= 300) and r.code != 404) return self.refused(a, r.code);
            },
        }
    }

    // MARK: folder

    fn fm() objc.Object {
        return objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    }

    fn isDir(path: []const u8) bool {
        var dir: objc.BOOL = objc.NO;
        return objc.msg(objc.BOOL, fm(), "fileExistsAtPath:isDirectory:", .{ objc.nsString(path), &dir }) and dir;
    }

    fn checkRoot(self: *Drop, a: std.mem.Allocator, root: []const u8) Error!void {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (!isDir(root)) return self.fail(a, "The folder {s} isn't there", .{root});
    }

    fn failWith(self: *Drop, a: std.mem.Allocator, err: ?objc.Object) Error {
        const text = if (err) |e| objc.fromNSString(objc.msg(objc.Object, e, "localizedDescription", .{})) else "The file couldn't be saved.";
        return self.fail(a, "{s}", .{text});
    }

    fn folderList(self: *Drop, a: std.mem.Allocator, root: []const u8, prefix: []const u8) Error!Names {
        try self.checkRoot(a, root);
        const pool = objc.Pool.push();
        defer pool.pop();
        const clean = if (std.mem.endsWith(u8, prefix, "/")) prefix else try std.fmt.allocPrint(a, "{s}/", .{prefix});
        const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, clean });
        var out: Names = .empty;
        if (!isDir(dir)) return out;
        const resolved = objc.msg(objc.Object, objc.nsString(dir), "stringByResolvingSymlinksInPath", .{});
        const items = objc.msg(?objc.Object, fm(), "enumeratorAtPath:", .{resolved}) orelse return out;
        const regular = objc.nsString("NSFileTypeRegular");
        while (objc.msg(?objc.Object, items, "nextObject", .{})) |rel_ns| {
            const rel = objc.fromNSString(rel_ns);
            // `.skipsHiddenFiles`: neither a hidden file nor anything in a hidden folder.
            if (std.mem.startsWith(u8, std.fs.path.basename(rel), ".")) {
                objc.msg(void, items, "skipDescendants", .{});
                continue;
            }
            const attrs = objc.msg(objc.Object, items, "fileAttributes", .{});
            const kind = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("NSFileType")}) orelse continue;
            if (!objc.msg(objc.BOOL, kind, "isEqualToString:", .{regular})) continue;
            const changed = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("NSFileModificationDate")});
            const at: SwiftDate = if (changed) |c| objc.msg(f64, c, "timeIntervalSinceReferenceDate", .{}) else json.fromUnix(0);
            try out.put(a, try std.fmt.allocPrint(a, "{s}{s}", .{ clean, rel }), at);
        }
        return out;
    }

    // MARK: bucket

    fn base(b: Bucket) []const u8 {
        return std.mem.trimEnd(u8, b.endpoint, "/");
    }

    fn objectURL(a: std.mem.Allocator, b: Bucket, name: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "{s}/{s}/", .{ base(b), try sigv4.uriEncode(a, b.bucket, true) });
        var it = std.mem.splitScalar(u8, name, '/');
        var first = true;
        while (it.next()) |part| : (first = false) {
            if (!first) try out.append(a, '/');
            try out.appendSlice(a, try sigv4.uriEncode(a, part, true));
        }
        return out.items;
    }

    fn listURL(a: std.mem.Allocator, b: Bucket, prefix: []const u8, token: ?[]const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(a, "{s}/{s}?list-type=2&prefix={s}", .{ base(b), try sigv4.uriEncode(a, b.bucket, true), try sigv4.uriEncode(a, prefix, true) });
        if (token) |t| if (t.len > 0) try out.print(a, "&continuation-token={s}", .{try sigv4.uriEncode(a, t, true)});
        return out.items;
    }

    fn refused(self: *Drop, a: std.mem.Allocator, code: i64) Error {
        if (code == 401 or code == 403) return self.fail(a, "The bucket refused the key", .{});
        return self.fail(a, "The bucket answered {d}", .{code});
    }

    fn send(self: *Drop, a: std.mem.Allocator, b: Bucket, method: []const u8, url: []const u8, body: ?[]const u8) Error!urlsession.Response {
        const p = Parts.parse(b.endpoint) orelse Parts{};
        const host = p.host orelse "";
        const https = if (p.scheme) |s| std.ascii.eqlIgnoreCase(s, "https") else false;
        const default_port: []const u8 = if (https) "443" else "80";
        const host_header = if (p.port) |port| if (!std.mem.eql(u8, port, default_port))
            try std.fmt.allocPrint(a, "{s}:{s}", .{ host, port })
        else
            host else host;
        const payload = core.hash(body orelse "");
        const now = json.now();
        const amz = sigv4.amzDate(now);
        const headers = [_]sigv4.Header{
            .{ "host", host_header },
            .{ "x-amz-content-sha256", &payload },
            .{ "x-amz-date", &amz },
        };
        const auth = try sigv4.authorization(a, method, url, &headers, &payload, b.access, b.secret, b.region, "s3", now);
        const all = [_]sigv4.Header{ headers[0], headers[1], headers[2], .{ "Authorization", auth } };
        return (urlsession.send(a, b.session, method, url, &all, body) catch return error.OutOfMemory) orelse
            self.fail(a, "Can't reach {s}", .{if (host.len == 0) b.endpoint else host});
    }

    fn bucketList(self: *Drop, a: std.mem.Allocator, b: Bucket, prefix: []const u8) Error!Names {
        var all: Names = .empty;
        var token: ?[]const u8 = null;
        while (true) {
            const r = try self.send(a, b, "GET", try listURL(a, b, prefix, token), null);
            if (r.code != 200) return self.refused(a, r.code);
            token = try listing(a, r.body, &all);
            if (token == null) break;
        }
        return all;
    }
};

fn copyData(a: std.mem.Allocator, d: objc.Object) ![]u8 {
    const len = objc.msg(objc.NSUInteger, d, "length", .{});
    const out = try a.alloc(u8, len);
    if (len > 0) objc.msg(void, d, "getBytes:length:", .{ out.ptr, len });
    return out;
}

/// One page of a ListObjectsV2 answer into `names`; the continuation token,
/// if there is more (`BucketDrop.listing`).
pub fn listing(a: std.mem.Allocator, xml: []const u8, names: *Names) !?[]const u8 {
    var next: ?[]const u8 = null;
    var in_contents = false;
    var key: ?[]const u8 = null;
    var date: ?SwiftDate = null;
    var text_from: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, xml, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, xml, lt, '>') orelse break;
        i = gt + 1;
        const inner = xml[lt + 1 .. gt];
        if (inner.len == 0 or inner[0] == '?' or inner[0] == '!') continue;
        const closing = inner[0] == '/';
        const self_closing = inner[inner.len - 1] == '/';
        const name_part = std.mem.trimStart(u8, inner, "/");
        const name_end = std.mem.indexOfAny(u8, name_part, " \t\r\n/") orelse name_part.len;
        const full = name_part[0..name_end];
        const tag = if (std.mem.lastIndexOfScalar(u8, full, ':')) |c| full[c + 1 ..] else full;
        if (!closing) {
            if (std.mem.eql(u8, tag, "Contents")) {
                in_contents = true;
                key = null;
                date = null;
            }
            text_from = gt + 1;
            if (!self_closing) continue;
        }
        const text = try unescape(a, std.mem.trim(u8, if (closing) xml[text_from..lt] else "", " \t\r\n"));
        if (in_contents) {
            if (std.mem.eql(u8, tag, "Key")) {
                key = text;
            } else if (std.mem.eql(u8, tag, "LastModified")) {
                date = parseDate(text);
            } else if (std.mem.eql(u8, tag, "Contents")) {
                if (key) |k| if (k.len > 0) if (date) |d| try names.put(a, k, d);
                in_contents = false;
            }
        } else if (std.mem.eql(u8, tag, "NextContinuationToken") and text.len > 0) next = text;
        text_from = gt + 1;
    }
    return next;
}

fn unescape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '&') for ([_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" } }) |e| {
            if (std.mem.startsWith(u8, s[i..], e[0])) {
                try out.appendSlice(a, e[1]);
                i += e[0].len;
                continue :outer;
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

/// ISO 8601 internet date-time, fractional seconds or not.
pub fn parseDate(s: []const u8) ?SwiftDate {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't') or s[13] != ':' or s[16] != ':') return null;
    const num = struct {
        fn f(t: []const u8) ?i64 {
            return std.fmt.parseInt(i64, t, 10) catch null;
        }
    }.f;
    const y = num(s[0..4]) orelse return null;
    const mo = num(s[5..7]) orelse return null;
    const d = num(s[8..10]) orelse return null;
    const h = num(s[11..13]) orelse return null;
    const mi = num(s[14..16]) orelse return null;
    const sec = num(s[17..19]) orelse return null;
    var rest = s[19..];
    var frac: f64 = 0;
    if (rest.len > 0 and rest[0] == '.') {
        const end = std.mem.indexOfNone(u8, rest[1..], "0123456789") orelse rest.len - 1;
        frac = std.fmt.parseFloat(f64, rest[0 .. end + 1]) catch return null;
        rest = rest[end + 1 ..];
    }
    var offset: i64 = 0;
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {} else if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        offset = ((num(rest[1..3]) orelse return null) * 60 + (num(rest[4..6]) orelse return null)) * 60;
        if (rest[0] == '-') offset = -offset;
    } else return null;
    // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * (if (mo > 2) mo - 3 else mo + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const unix = days * 86400 + h * 3600 + mi * 60 + sec - offset;
    return json.fromUnix(@as(f64, @floatFromInt(unix)) + frac);
}

test "bucket listing parses names, dates and the next page" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var names: Names = .empty;
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>
        \\<Contents><Key>kea/v1/devices/A/tabs.kea</Key><LastModified>2009-10-12T17:50:30.000Z</LastModified><Size>4</Size></Contents>
        \\<Contents><Key>a&amp;b</Key><LastModified>2001-01-01T00:00:01Z</LastModified></Contents>
        \\<IsTruncated>true</IsTruncated><NextContinuationToken>1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=</NextContinuationToken></ListBucketResult>
    ;
    const next = try listing(a, xml, &names);
    try std.testing.expectEqualStrings("1ueGcxLPRx1Tr/XYExHnhbYLgveDs2J/wm36Hy4vbOwM=", next.?);
    try std.testing.expectEqual(json.fromUnix(1255369830), names.get("kea/v1/devices/A/tabs.kea").?);
    try std.testing.expectEqual(@as(f64, 1), names.get("a&b").?);
    try std.testing.expect(Drop.allowed("https://storage.googleapis.com") and Drop.allowed("http://localhost:9000"));
    try std.testing.expect(!Drop.allowed("http://example.com") and !Drop.allowed("storage"));
}
