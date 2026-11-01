//! What a tab's title shows of its address (`tab_title.draw`): parsed once
//! per address, not every frame, and its site asked of macOS only once.
const std = @import("std");
const Parts = @import("../data/url.zig").Parts;
const registrable = @import("../data/registrable.zig");
const dialogs = @import("dialogs.zig");

pub const UrlCache = struct {
    /// The address these describe (its Wyhash, its length the seed); 0: none yet.
    hash: u64 = 0,
    parsed: bool = false,
    is_web: bool = false,
    is_file: bool = false,
    /// `http:` to a host that isn't this Mac.
    plain_http: bool = false,
    lookalike: bool = false,
    /// The host less "www." and the path's last part: byte ranges of the address.
    bare_off: u32 = 0,
    bare_len: u32 = 0,
    base_off: u32 = 0,
    base_len: u32 = 0,
    /// `registrable(bare)`, kept once asked (null: not yet, or too long to keep).
    reg_len: ?u8 = null,
    reg_buf: [128]u8 = undefined,

    /// This cache, describing `url` (worked out again when it changed).
    pub fn of(k: *UrlCache, url: []const u8) *UrlCache {
        const h = std.hash.Wyhash.hash(url.len, url);
        if (h == k.hash) return k;
        k.* = .{ .hash = h };
        const parts = Parts.parse(url) orelse return k;
        k.parsed = true;
        const host = parts.hostName() orelse "";
        const shown = if (std.ascii.startsWithIgnoreCase(host, "www.")) host[4..] else host;
        if (shown.len > 0) {
            k.bare_off = @intCast(@intFromPtr(shown.ptr) - @intFromPtr(url.ptr));
            k.bare_len = @intCast(shown.len);
        }
        k.is_web = parts.isWeb();
        k.is_file = parts.schemeIs("file");
        k.plain_http = parts.schemeIs("http") and shown.len > 0 and !dialogs.isLoopback(shown);
        k.lookalike = shown.len > 0 and @import("../chrome/tab_title.zig").isLookalikeHost(shown);
        const last = std.fs.path.basename(parts.path);
        if (last.len > 0) {
            k.base_off = @intCast(@intFromPtr(last.ptr) - @intFromPtr(url.ptr));
            k.base_len = @intCast(last.len);
        }
        return k;
    }

    pub fn bare(k: *const UrlCache, url: []const u8) []const u8 {
        return url[k.bare_off..][0..k.bare_len];
    }

    pub fn base(k: *const UrlCache, url: []const u8) []const u8 {
        return url[k.base_off..][0..k.base_len];
    }

    /// The site `bare` belongs to; asked on `arena` the first time only.
    pub fn site(k: *UrlCache, arena: std.mem.Allocator, bare_host: []const u8) []const u8 {
        if (k.reg_len) |n| return k.reg_buf[0..n];
        const reg = registrable.registrable(arena, bare_host) catch return bare_host;
        if (reg.len <= k.reg_buf.len) {
            @memcpy(k.reg_buf[0..reg.len], reg);
            k.reg_len = @intCast(reg.len);
        }
        return reg;
    }
};
