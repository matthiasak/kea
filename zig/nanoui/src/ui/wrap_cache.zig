//! Wrapped text, kept for the frame it was made in and the next (as shaped
//! layouts are): a resize makes new widths every frame, and what the last
//! frame wrapped goes at the next frame's start, never during a frame whose
//! boxes still point at it. The lines live in slabs (as shaped glyphs do)
//! whose chunks never move, so a warmed cache wraps anew without reaching
//! the heap.
const std = @import("std");

/// `T`s by the chunk of `chunk_cap`: a full chunk stays where it is and the
/// next is begun, so what was handed out holds until `reset`.
pub fn Slab(comptime T: type, comptime chunk_cap: usize) type {
    return struct {
        const Self = @This();

        chunks: std.ArrayList([]T) = .empty,
        chunk_idx: usize = 0,
        used: usize = 0,

        /// A first chunk, so that filling it needn't allocate.
        pub fn warm(self: *Self, gpa: std.mem.Allocator) void {
            self.chunks.ensureTotalCapacity(gpa, 4) catch return;
            if (self.chunks.items.len == 0) self.chunks.appendAssumeCapacity(gpa.alloc(T, chunk_cap) catch return);
        }

        /// Room for `n`, undefined; null when there is no memory for it.
        pub fn alloc(self: *Self, gpa: std.mem.Allocator, n: usize) ?[]T {
            if (n == 0) return @as([]T, &.{});
            while (self.chunk_idx < self.chunks.items.len) : ({
                self.chunk_idx += 1;
                self.used = 0;
            }) {
                const chunk = self.chunks.items[self.chunk_idx];
                if (chunk.len - self.used < n) continue;
                const at = self.used;
                self.used += n;
                return chunk[at..][0..n];
            }
            self.chunks.ensureUnusedCapacity(gpa, 1) catch return null;
            const chunk = gpa.alloc(T, @max(chunk_cap, n)) catch return null;
            self.chunks.appendAssumeCapacity(chunk);
            self.used = n;
            return chunk[0..n];
        }

        /// What was handed out goes; the chunks stay for the next round.
        pub fn reset(self: *Self) void {
            // ponytail: chunks are kept until deinit (the peak volume stays resident); free the extras here if that shows.
            self.chunk_idx = 0;
            self.used = 0;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (self.chunks.items) |chunk| gpa.free(chunk);
            self.chunks.deinit(gpa);
        }
    };
}

pub fn WrapCache(comptime Line: type) type {
    return struct {
        const Self = @This();
        const Map = std.AutoHashMapUnmanaged(u64, []const Line);
        const Lines = Slab(Line, 16384);
        /// The wraps a frame may reach before the last frame's go.
        const max_wraps = 3072;

        current: Map = .empty,
        previous: Map = .empty,
        cur_slab: Lines = .{},
        prev_slab: Lines = .{},

        /// Room for two frames of wraps, so that making them needn't allocate.
        pub fn warm(self: *Self, gpa: std.mem.Allocator) void {
            if (self.current.capacity() < 4096) self.current.ensureTotalCapacity(gpa, 4096) catch {};
            if (self.previous.capacity() < 4096) self.previous.ensureTotalCapacity(gpa, 4096) catch {};
            self.cur_slab.warm(gpa);
            self.prev_slab.warm(gpa);
        }

        /// The lines kept for `k` this frame or the last.
        pub fn get(self: *Self, gpa: std.mem.Allocator, k: u64) ?[]const Line {
            if (self.current.get(k)) |lines| return lines;
            const kv = self.previous.fetchRemove(k) orelse return null;
            return self.keep(gpa, k, kv.value);
        }

        /// Keeps a copy of `lines` for `k`; empty if it can't.
        pub fn put(self: *Self, gpa: std.mem.Allocator, k: u64, lines: []const Line) []const Line {
            return self.keep(gpa, k, lines) orelse &.{};
        }

        /// `lines` copied into this frame's slab, good for this frame and
        /// the next even when the map has no room to remember them.
        fn keep(self: *Self, gpa: std.mem.Allocator, k: u64, lines: []const Line) ?[]const Line {
            const dst = self.cur_slab.alloc(gpa, lines.len) orelse return null;
            @memcpy(dst, lines);
            self.current.put(gpa, k, dst) catch {};
            return dst;
        }

        /// A new frame: the one before last's wraps go.
        pub fn beginFrame(self: *Self, _: std.mem.Allocator) void {
            if (self.current.count() < max_wraps) return;
            self.previous.clearRetainingCapacity();
            self.prev_slab.reset();
            std.mem.swap(Map, &self.current, &self.previous);
            std.mem.swap(Lines, &self.cur_slab, &self.prev_slab);
        }

        /// Drops every wrap (fonts changed).
        pub fn clear(self: *Self, _: std.mem.Allocator) void {
            self.current.clearRetainingCapacity();
            self.previous.clearRetainingCapacity();
            self.cur_slab.reset();
            self.prev_slab.reset();
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.current.deinit(gpa);
            self.previous.deinit(gpa);
            self.cur_slab.deinit(gpa);
            self.prev_slab.deinit(gpa);
        }
    };
}

test "a full chunk stays put and the next is begun; a reset reuses both" {
    const gpa = std.testing.allocator;
    var slab: Slab(u32, 4) = .{};
    defer slab.deinit(gpa);
    const a = slab.alloc(gpa, 3).?;
    @memset(a, 7);
    // No room left in the first chunk, then more than a chunk holds.
    @memset(slab.alloc(gpa, 3).?, 9);
    const wide = slab.alloc(gpa, 10).?;
    try std.testing.expectEqualSlices(u32, &.{ 7, 7, 7 }, a);
    try std.testing.expectEqual(@as(usize, 3), slab.chunks.items.len);
    slab.reset();
    try std.testing.expectEqual(a.ptr, slab.alloc(gpa, 3).?.ptr);
    try std.testing.expectEqual(wide.ptr, slab.alloc(gpa, 10).?.ptr);
    try std.testing.expectEqual(@as(usize, 3), slab.chunks.items.len);
}

test "a warmed cache keeps wraps in place, frame after frame, off the heap" {
    const L = struct { start: usize, end: usize };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var wraps: WrapCache(L) = .{};
    defer wraps.deinit(gpa);
    wraps.warm(gpa);
    const warmed = failing.allocations;

    for (0..3072) |k| _ = wraps.put(gpa, k, &.{ .{ .start = k, .end = k }, .{ .start = k, .end = k + 1 } });
    const held = wraps.get(gpa, 7).?;
    wraps.beginFrame(gpa);
    // Last frame's lines are carried over when asked for, and stay where they were.
    try std.testing.expectEqual(@as(usize, 8), wraps.get(gpa, 7).?[1].end);
    for (3072..6144) |k| _ = wraps.put(gpa, k, &.{.{ .start = k, .end = k }});
    try std.testing.expectEqual(@as(usize, 8), held[1].end);
    wraps.beginFrame(gpa);
    // Unasked for a frame, they go.
    try std.testing.expect(wraps.get(gpa, 8) == null);
    try std.testing.expect(wraps.get(gpa, 7) != null);
    try std.testing.expectEqual(warmed, failing.allocations);
}
