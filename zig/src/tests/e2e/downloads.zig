//! P5.5: a file a page sends lands in the test run's Downloads folder and
//! Loot remembers it in `downloads.json`.
const std = @import("std");
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "download lands and downloads.json records it", .run = lands },
    .{ .name = "copy image stops reading past 50 MB", .run = hugeImage },
};

fn refused(b: *app.Browser) bool {
    const said = b.announcement orelse return false;
    return std.mem.eql(u8, said, "Couldn't copy that image");
}

/// Swift reads the picture as it comes and lets go past `largestImage`;
/// one that never ends is refused long before it would have finished.
fn hugeImage(h: *Harness) !void {
    const b = try h.start();
    const scheme = @import("scheme.zig");
    scheme.huge_sent.store(0, .monotonic);
    const url = try std.fmt.allocPrint(h.gpa, "{s}/huge", .{h.http});
    defer h.gpa.free(url);
    app.image_menu.copyFrom(b.activeTab().?, url);
    h.waitFor(b, refused, 30, "the refusal") catch
        return h.fail("not refused; {d} bytes sent", .{scheme.huge_sent.load(.monotonic)});
    const sent = scheme.huge_sent.load(.monotonic);
    try h.expect(sent < 200_000_000, "{d} bytes sent before it let go", .{sent});
}

fn kept(k: *app.Kea) bool {
    return k.loot.kept.len > 0;
}

const Keep = struct { name: []const u8, path: []const u8 };

fn lands(h: *Harness) !void {
    const b = try h.start();
    const k = h.kea.?;
    // From the loopback listener: WebKit downloads nothing from `kea-test`.
    const url = try std.fmt.allocPrint(h.gpa, "{s}/download?name=a.txt", .{h.http});
    defer h.gpa.free(url);
    _ = b.open(url, .{ .foreground = true });
    h.waitFor(k, kept, 10, "the download") catch
        return h.fail("nothing kept; {d} running, showing {}", .{ k.fetches.running.count(), k.fetches.showing });
    const want = try h.temp.path(h.gpa, "Downloads/a.txt");
    defer h.gpa.free(want);
    // WebKit may report the file under /private/var: compare the tail.
    try h.expect(std.mem.endsWith(u8, k.loot.kept[0].path, "/Downloads/a.txt"), "kept path '{s}'", .{k.loot.kept[0].path});
    const body = app.disk.read(h.gpa, want) orelse return h.fail("no file at {s}", .{want});
    defer h.gpa.free(body);
    try h.expect(body.len == 4096, "file has {d} bytes", .{body.len});
    try h.expect(k.fetches.entries.items.len == 0 and k.fetches.running.count() == 0, "a landed download is still listed", .{});
    k.store.disk.drain();
    const bytes = h.readFile("downloads.json") orelse return h.fail("no downloads.json", .{});
    defer h.gpa.free(bytes);
    const parsed = try app.json.decode([]const Keep, h.gpa, bytes);
    defer parsed.deinit();
    try h.expect(parsed.value.len == 1 and std.mem.eql(u8, parsed.value[0].name, "a.txt"), "downloads.json is {s}", .{bytes});
}
