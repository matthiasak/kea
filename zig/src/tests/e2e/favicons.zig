//! P4.2: a page's declared icon is fetched, decoded and kept (Icons.swift).
const std = @import("std");
const objc = @import("nanoui").objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "favicon from page link shows", .run = faviconShows },
};

fn hasIcon(k: *app.Kea) bool {
    return k.favicons.cached("site") != null;
}

var first_buf: [128]u8 = undefined;
var first_name: []const u8 = "";

fn iconChanged(k: *app.Kea) bool {
    const now = k.favicons.cached("site") orelse return false;
    return !std.mem.eql(u8, now.name, first_name);
}

fn faviconShows(h: *Harness) !void {
    const b = try h.start();
    const t = b.open("kea-test://site/f/favicon.html", .{ .foreground = true });
    const k = h.kea.?;
    h.waitFor(k, hasIcon, 10, "the site's icon") catch
        return h.fail("no icon for 'site': url '{s}', loading {}, failure '{s}'", .{ t.url(), t.loading, t.failure orelse "" });
    const icon = k.favicons.icon(t.url()) orelse return h.fail("Mark gets no icon for {s}", .{t.url()});
    try h.expect(std.mem.startsWith(u8, icon.png, "\x89PNG"), "the icon isn't a PNG", .{});
    k.store.disk.drain();
    const kept = h.readFile("icons/site.png") orelse h.readFile("icons/site@dark.png") orelse
        return h.fail("icons/site.png wasn't kept", .{});
    h.gpa.free(kept);

    // The page changes its icon: the relay asks for it again.
    first_name = try std.fmt.bufPrint(&first_buf, "{s}", .{icon.key});
    objc.msg(void, t.web.?, "evaluateJavaScript:completionHandler:", .{
        objc.nsString("document.querySelector('link[rel=icon]').setAttribute('media', 'screen')"), @as(?*anyopaque, null),
    });
    h.waitFor(k, iconChanged, 10, "the icon asked for again") catch return h.fail("the keaIcon relay never refetched", .{});
}
