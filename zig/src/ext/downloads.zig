//! Downloads an extension started (`downloads.download`): the name it asked
//! for (`Browser.namedDownloads`, Browser.swift:1419) and which files are
//! its own (`ExtensionShims.askedDownloads`/`ownDownloads`), so it may only
//! open or remove those.
const std = @import("std");
const Browser = @import("../model/browser.zig").Browser;

// Swift statics: app-lifetime, on the C allocator.
const heap = std.heap.c_allocator;
/// url → the extension that asked for it.
var asked: std.StringHashMapUnmanaged([]u8) = .empty;
/// extension id → paths of the files it downloaded.
var own: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;

fn put(map: *std.StringHashMapUnmanaged([]u8), gpa: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const v = try gpa.dupe(u8, value);
    errdefer gpa.free(v);
    const got = try map.getOrPut(gpa, key);
    if (got.found_existing) gpa.free(got.value_ptr.*) else got.key_ptr.* = gpa.dupe(u8, key) catch |e| {
        map.removeByPtr(got.key_ptr);
        return e;
    };
    got.value_ptr.* = v;
}

/// Before `startDownload`: the name asked for (folders dropped) and who
/// asked.
pub fn ask(b: *Browser, url: []const u8, ext_id: []const u8, name: ?[]const u8) !void {
    if (name) |n| if (n.len > 0) try put(&b.ext.named_downloads, b.gpa, url, std.fs.path.basename(n));
    try put(&asked, heap, url, ext_id);
}

/// `decideDestination`: the name an extension asked for this response's
/// url, taken off the list (gpa-owned), or null.
pub fn takeName(b: *Browser, url: []const u8) ?[]u8 {
    const kv = b.ext.named_downloads.fetchRemove(url) orelse return null;
    b.gpa.free(kv.key);
    return kv.value;
}

/// `downloadDidFinish`, for a listed download: one an extension asked for
/// is its own from now on.
pub fn finished(source: []const u8, path: []const u8) void {
    const kv = asked.fetchRemove(source) orelse return;
    defer heap.free(kv.key);
    const got = own.getOrPut(heap, kv.value) catch return heap.free(kv.value);
    if (got.found_existing) heap.free(kv.value) else got.value_ptr.* = .empty;
    const p = heap.dupe(u8, path) catch return;
    const slot = got.value_ptr.getOrPut(heap, p) catch return heap.free(p);
    if (slot.found_existing) heap.free(p);
}

pub fn owns(ext_id: []const u8, path: []const u8) bool {
    const paths = own.get(ext_id) orelse return false;
    return paths.contains(path);
}

/// `Browser.destroy`'s half.
pub fn deinit(b: *Browser) void {
    var it = b.ext.named_downloads.iterator();
    while (it.next()) |e| {
        b.gpa.free(e.key_ptr.*);
        b.gpa.free(e.value_ptr.*);
    }
    b.ext.named_downloads.deinit(b.gpa);
}

test "asked downloads become the extension's own" {
    try put(&asked, heap, "https://a/x.zip", "ext");
    finished("https://a/x.zip", "/tmp/x.zip");
    try std.testing.expect(owns("ext", "/tmp/x.zip"));
    try std.testing.expect(!owns("ext", "/tmp/y.zip"));
    try std.testing.expect(!owns("other", "/tmp/x.zip"));
    finished("https://a/x.zip", "/tmp/z.zip");
    try std.testing.expect(!owns("ext", "/tmp/z.zip"));
}
