//! Files written in the background, one at a time and the newest last
//! (`Disk` in Store.swift). Every write joins one serial queue, and a write
//! that a newer one of the same file has overtaken is dropped, including when
//! the newer one was written at once on the way out. Callers encode on their
//! own thread; only the file I/O goes to the queue.
const std = @import("std");
const dispatch = @import("../sys/dispatch.zig");
const json = @import("json.zig");

const c = struct {
    const FILE = opaque {};
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern "c" fn fclose(stream: *FILE) c_int;
    extern "c" fn fwrite(ptr: [*]const u8, size: usize, nitems: usize, stream: *FILE) usize;
    extern "c" fn fread(ptr: [*]u8, size: usize, nitems: usize, stream: *FILE) usize;
    extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
};

pub const Disk = struct {
    gpa: std.mem.Allocator,
    queue: dispatch.Queue,
    /// Guards `newest` and `count`, held for a moment and never across a write.
    lock: std.c.pthread_mutex_t = .{},
    /// Held across a write or a removal, so the newest-wins check and the
    /// change to the file are one step.
    io: std.c.pthread_mutex_t = .{},
    newest: std.StringHashMapUnmanaged(u64) = .empty,
    count: u64 = 0,

    const Job = struct {
        disk: *Disk,
        path: [:0]u8,
        /// null removes the file.
        bytes: ?[]u8,
        turn: u64,
    };

    pub fn init(gpa: std.mem.Allocator) Disk {
        return .{ .gpa = gpa, .queue = dispatch.dispatch_queue_create("kea.disk", null) };
    }

    pub fn deinit(self: *Disk) void {
        self.drain();
        dispatch.dispatch_release(self.queue);
        const ca = std.heap.c_allocator;
        var it = self.newest.keyIterator();
        while (it.next()) |k| ca.free(k.*);
        self.newest.deinit(ca);
    }

    /// Writes `bytes` (allocated on `gpa`, freed here) to `path` atomically,
    /// creating its folder. `now` writes on the calling thread: quitting
    /// doesn't wait for a queue.
    pub fn write(self: *Disk, path: []const u8, bytes: []u8, now: bool) void {
        defer self.gpa.free(bytes);
        const job = self.ask(path, bytes) orelse return;
        if (now) run(job) else dispatch.dispatch_async_f(self.queue, job, run);
    }

    /// A file gone, in its turn among the writes; a newer write of it wins.
    pub fn remove(self: *Disk, path: []const u8) void {
        const job = self.ask(path, null) orelse return;
        dispatch.dispatch_async_f(self.queue, job, run);
    }

    /// Everything asked for so far, written — for the way out.
    pub fn drain(self: *Disk) void {
        dispatch.dispatch_sync_f(self.queue, null, nothing);
    }

    fn nothing(_: ?*anyopaque) callconv(.c) void {}

    fn ask(self: *Disk, path: []const u8, bytes: ?[]const u8) ?*Job {
        const ca = std.heap.c_allocator;
        const job = ca.create(Job) catch return null;
        const z = ca.dupeSentinel(u8, path, 0) catch {
            ca.destroy(job);
            return null;
        };
        const copy = if (bytes) |b| ca.dupe(u8, b) catch {
            ca.free(z);
            ca.destroy(job);
            return null;
        } else null;
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        const gop = self.newest.getOrPut(ca, path) catch {
            if (copy) |b| ca.free(b);
            ca.free(z);
            ca.destroy(job);
            return null;
        };
        if (!gop.found_existing) gop.key_ptr.* = ca.dupe(u8, path) catch {
            self.newest.removeByPtr(gop.key_ptr);
            if (copy) |b| ca.free(b);
            ca.free(z);
            ca.destroy(job);
            return null;
        };
        self.count += 1;
        gop.value_ptr.* = self.count;
        job.* = .{ .disk = self, .path = z, .bytes = copy, .turn = self.count };
        return job;
    }

    fn isNewest(self: *Disk, path: []const u8, turn: u64) bool {
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        return self.newest.get(path) == turn;
    }

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(ctx.?));
        const d = job.disk;
        const ca = std.heap.c_allocator;
        defer {
            if (job.bytes) |b| ca.free(b);
            ca.free(job.path);
            ca.destroy(job);
        }
        _ = std.c.pthread_mutex_lock(&d.io);
        defer _ = std.c.pthread_mutex_unlock(&d.io);
        // Overtaken: something newer of this file was asked for since.
        if (!d.isNewest(job.path, job.turn)) return;
        if (job.bytes) |b| {
            writeAtomic(ca, job.path, b);
        } else {
            _ = c.unlink(job.path);
        }
    }
};

var tmp_seq: std.atomic.Value(u32) = .init(0);

/// `path`'s parent folders, then `<path>.<pid>.<n>.tmp` renamed over `path`.
fn writeAtomic(gpa: std.mem.Allocator, path: [:0]const u8, bytes: []const u8) void {
    if (std.fs.path.dirname(path)) |dir| makePath(gpa, dir);
    const tmp = std.fmt.allocPrintSentinel(gpa, "{s}.{d}.{d}.tmp", .{ path, std.c.getpid(), tmp_seq.fetchAdd(1, .monotonic) }, 0) catch return;
    defer gpa.free(tmp);
    const f = c.fopen(tmp, "wb") orelse return;
    const wrote = bytes.len == 0 or c.fwrite(bytes.ptr, 1, bytes.len, f) == bytes.len;
    if (c.fclose(f) != 0 or !wrote) {
        _ = c.unlink(tmp);
        return;
    }
    if (c.rename(tmp, path) != 0) _ = c.unlink(tmp);
}

/// `mkdir -p`; failures are left for the write that follows to meet.
pub fn makePath(gpa: std.mem.Allocator, dir: []const u8) void {
    if (dir.len == 0) return;
    const z = gpa.dupeSentinel(u8, dir, 0) catch return;
    defer gpa.free(z);
    for (z[1..], 1..) |ch, i| if (ch == '/') {
        z[i] = 0;
        _ = c.mkdir(z, 0o755);
        z[i] = '/';
    };
    _ = c.mkdir(z, 0o755);
}

/// The whole file at `path` on `gpa`, or null when it can't be read.
pub fn read(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = gpa.dupeSentinel(u8, path, 0) catch return null;
    defer gpa.free(z);
    const f = c.fopen(z, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, f);
        out.appendSlice(gpa, chunk[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
        if (n < chunk.len) break;
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

/// A file that didn't decode is set aside as `<name>.unreadable-<unix
/// seconds>.json` beside it rather than overwritten by the next save.
/// Failing to move it is fine: the read already came back empty.
pub fn quarantine(gpa: std.mem.Allocator, path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| if (dot > 0) base[0..dot] else base else base;
    const stamp: i64 = @intFromFloat(@floor(json.toUnix(json.now())));
    const src = gpa.dupeSentinel(u8, path, 0) catch return;
    defer gpa.free(src);
    const dst = std.fmt.allocPrintSentinel(gpa, "{s}/{s}.unreadable-{d}.json", .{ dir, stem, stamp }, 0) catch return;
    defer gpa.free(dst);
    _ = c.rename(src, dst);
}

test "disk newest write wins" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    const p = try t.path(gpa, "nested/one.json");
    defer gpa.free(p);
    var d = Disk.init(gpa);
    defer d.deinit();
    d.write(p, try gpa.dupe(u8, "first"), false);
    d.write(p, try gpa.dupe(u8, "second"), false);
    d.drain();
    const got = read(gpa, p).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("second", got);
    // An older queued write never lands over a newer one written at once.
    d.write(p, try gpa.dupe(u8, "queued"), false);
    d.write(p, try gpa.dupe(u8, "now"), true);
    d.drain();
    const got2 = read(gpa, p).?;
    defer gpa.free(got2);
    try std.testing.expectEqualStrings("now", got2);
    d.remove(p);
    d.drain();
    try std.testing.expect(read(gpa, p) == null);
}
