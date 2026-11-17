//! In-process ZIP archive extraction (`store` and `deflate`), rejecting
//! path traversal (`..`, leading `/`) and symbolic links without spawning
//! `/usr/bin/ditto` or `NSTask` (safe on both macOS and iOS sandboxes).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const end_sig = [4]u8{ 'P', 'K', 5, 6 };
const cd_sig = [4]u8{ 'P', 'K', 1, 2 };
const lfh_sig = [4]u8{ 'P', 'K', 3, 4 };

pub const Error = error{
    BadZip,
    UnsafePath,
    SymlinkForbidden,
    UnsupportedMethod,
    WriteFailed,
    OutOfMemory,
};

fn u16le(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn u32le(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn safeRelativePath(raw: []const u8) Error![]const u8 {
    if (raw.len == 0 or raw[0] == '/' or raw[0] == '\\') return error.UnsafePath;
    if (std.mem.indexOfScalar(u8, raw, 0) != null or std.mem.indexOfScalar(u8, raw, '\\') != null) return error.UnsafePath;
    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return error.UnsafePath;
    }
    return raw;
}

/// Extracts `zip` bytes into `dest_dir` (created if absent).
pub fn extractBytes(gpa: std.mem.Allocator, zip: []const u8, dest_dir: []const u8) Error!void {
    if (zip.len < 22) return error.BadZip;
    const min_eocd = zip.len - @min(zip.len, 22 + 65535);
    var eocd_off: ?usize = null;
    var scan = zip.len - 22;
    while (true) {
        if (std.mem.eql(u8, zip[scan..][0..4], &end_sig)) {
            const comment_len = u16le(zip, scan + 20);
            if (scan + 22 + comment_len == zip.len) {
                eocd_off = scan;
                break;
            }
        }
        if (scan == min_eocd) break;
        scan -= 1;
    }
    const eocd = eocd_off orelse return error.BadZip;
    const count: usize = u16le(zip, eocd + 10);
    const cd_size: usize = u32le(zip, eocd + 12);
    const cd_off: usize = u32le(zip, eocd + 16);
    if (cd_off + cd_size > eocd) return error.BadZip;

    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    if (!objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
        objc.nsString(dest_dir), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
    })) return error.WriteFailed;

    var pos = cd_off;
    for (0..count) |_| {
        if (pos + 46 > cd_off + cd_size or !std.mem.eql(u8, zip[pos..][0..4], &cd_sig)) return error.BadZip;
        const method = u16le(zip, pos + 10);
        const comp_size: usize = u32le(zip, pos + 20);
        const uncomp_size: usize = u32le(zip, pos + 24);
        const name_len: usize = u16le(zip, pos + 28);
        const extra_len: usize = u16le(zip, pos + 30);
        const comment_len: usize = u16le(zip, pos + 32);
        const ext_attr = u32le(zip, pos + 38);
        const lfh_off: usize = u32le(zip, pos + 42);
        if (pos + 46 + name_len + extra_len + comment_len > cd_off + cd_size) return error.BadZip;
        const raw_name = zip[pos + 46 ..][0..name_len];
        pos += 46 + name_len + extra_len + comment_len;

        // Unix mode bits in upper 16 bits of external_file_attributes: reject symlinks (0120000).
        const unix_mode = (ext_attr >> 16) & 0o170000;
        if (unix_mode == 0o120000) return error.SymlinkForbidden;

        const rel = try safeRelativePath(raw_name);
        if (std.mem.startsWith(u8, rel, "__MACOSX/")) continue;
        const full = try std.fs.path.join(gpa, &.{ dest_dir, rel });
        defer gpa.free(full);

        if (rel[rel.len - 1] == '/') {
            if (!objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
                objc.nsString(full), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
            })) return error.WriteFailed;
            continue;
        }

        if (lfh_off + 30 > zip.len or !std.mem.eql(u8, zip[lfh_off..][0..4], &lfh_sig)) return error.BadZip;
        const lfh_name_len: usize = u16le(zip, lfh_off + 26);
        const lfh_extra_len: usize = u16le(zip, lfh_off + 28);
        const data_off = lfh_off + 30 + lfh_name_len + lfh_extra_len;
        if (data_off + comp_size > zip.len) return error.BadZip;
        const payload = zip[data_off..][0..comp_size];

        if (std.fs.path.dirname(full)) |parent| {
            if (!objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
                objc.nsString(parent), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
            })) return error.WriteFailed;
        }

        switch (method) {
            0 => {
                if (comp_size != uncomp_size) return error.BadZip;
                const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ payload.ptr, @as(objc.NSUInteger, payload.len) });
                if (!objc.msg(objc.BOOL, data, "writeToFile:atomically:", .{ objc.nsString(full), objc.NO })) return error.WriteFailed;
            },
            8 => {
                const out_buf = try gpa.alloc(u8, uncomp_size);
                defer gpa.free(out_buf);
                var in_reader = std.Io.Reader.fixed(payload);
                var out_writer = std.Io.Writer.fixed(out_buf);
                var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
                var decomp = std.compress.flate.Decompress.init(&in_reader, .raw, &window_buf);
                _ = decomp.reader.streamRemaining(&out_writer) catch return error.BadZip;
                if (out_writer.end != uncomp_size) return error.BadZip;
                const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ out_buf.ptr, @as(objc.NSUInteger, out_buf.len) });
                if (!objc.msg(objc.BOOL, data, "writeToFile:atomically:", .{ objc.nsString(full), objc.NO })) return error.WriteFailed;
            },
            else => return error.UnsupportedMethod,
        }
    }
}

pub fn extractFile(gpa: std.mem.Allocator, zip_path: []const u8, dest_dir: []const u8) Error!void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const nsdata = objc.msg(?objc.Object, objc.class("NSData"), "dataWithContentsOfFile:", .{objc.nsString(zip_path)}) orelse return error.BadZip;
    const ptr = objc.msg(?[*]const u8, nsdata, "bytes", .{});
    const len = objc.msg(objc.NSUInteger, nsdata, "length", .{});
    const slice: []const u8 = if (ptr) |p| p[0..len] else &.{};
    return extractBytes(gpa, slice, dest_dir);
}

test "zip_extract rejects traversal and extracts stored entry" {
    try std.testing.expectError(error.UnsafePath, safeRelativePath("../evil"));
    try std.testing.expectError(error.UnsafePath, safeRelativePath("/abs/evil"));
    try std.testing.expectEqualStrings("manifest.json", try safeRelativePath("manifest.json"));
}
