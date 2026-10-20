//! P4.2: a page's declared icon is fetched, decoded and kept (Icons.swift).
const std = @import("std");
const objc = @import("nanoui").objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "favicon from page link shows", .run = faviconShows },
    .{ .name = "dark look refetches @dark icon", .run = darkLookRefetches },
    .{ .name = "swipe list shows site icons", .run = swipeListShowsIcons },
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
        objc.nsString("document.querySelector('link[rel=icon]').setAttribute('href', 'data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20width=%2764%27%20height=%2764%27%20viewBox=%270%200%2064%2064%27%3E%3Crect%20width=%2764%27%20height=%2764%27%20fill=%27%232080ff%27/%3E%3C/svg%3E')"), @as(?*anyopaque, null),
    });
    h.waitFor(k, iconChanged, 10, "the icon asked for again") catch return h.fail("the keaIcon relay never refetched", .{});
}

var prev_serial: u64 = 0;

fn darkIconLanded(k: *app.Kea) bool {
    return k.favicons.memory.get("site@dark") != null and k.favicons.serial > prev_serial;
}

fn darkLookRefetches(h: *Harness) !void {
    const b = try h.start();
    const k = h.kea.?;
    const Look = @FieldType(@TypeOf(k.prefs), "look");
    k.prefs.set("look", Look.light);
    const t = b.open("kea-test://site/f/favicon_dark.html", .{ .foreground = true });
    h.waitFor(k, hasIcon, 10, "the light icon") catch
        return h.fail("no light icon for 'site'", .{});
    const light_ic = k.favicons.icon(t.url()) orelse return h.fail("no icon in light mode", .{});
    first_name = try std.fmt.bufPrint(&first_buf, "{s}", .{light_ic.key});
    prev_serial = k.favicons.serial;

    // Switch look to dark through prefs alone.
    k.prefs.set("look", Look.dark);
    h.waitFor(k, darkIconLanded, 10, "the @dark icon") catch
        return h.fail("switching to dark look never refetched site@dark", .{});
    const dark_ic = k.favicons.icon(t.url()) orelse return h.fail("no icon in dark mode", .{});
    try h.expect(!std.mem.eql(u8, dark_ic.key, first_name), "expected new icon key, got {s}", .{dark_ic.key});
}

fn swipeListShowsIcons(h: *Harness) !void {
    const b = try h.start();
    const k = h.kea.?;
    const t = b.open("kea-test://site/f/favicon.html", .{ .foreground = true });
    h.waitFor(k, hasIcon, 10, "the site's icon") catch
        return h.fail("no icon for 'site'", .{});
    const Pull = @typeInfo(@FieldType(app.Tab, "pull")).optional.child;
    const Stop = std.meta.Child(@FieldType(Pull, "stops"));
    var stops = [_]Stop{
        .{ .title = @constCast("Favicon Stop"), .url = @constCast("kea-test://site/f/favicon.html") },
    };
    t.pull = .{
        .back = true,
        .travel = 80,
        .armed = true,
        .going = false,
        .stops = &stops,
        .picked = 0,
    };
    defer t.pull = null;
    const s = b.window.?.surface.?;
    s.frame();
    var found_icon_image = false;
    for (s.ctx.nodes.items) |n| {
        if (n.content == .image and @abs(n.rect.w - 14) < 0.5 and @abs(n.rect.h - 14) < 0.5) {
            found_icon_image = true;
            break;
        }
    }
    try h.expect(found_icon_image, "expected a 14x14 ui.image in the history-swipe list", .{});
}
