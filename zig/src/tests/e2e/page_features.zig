//! P5.6 page features, part A: Find on page counts and steps, Reading mode
//! takes the article (and says when there is none), the ad blocker's rule
//! list compiles, and Curtain's sheet hides what was taken off a site,
//! before the page draws and on the page already up.
const std = @import("std");
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "find counts matches", .run = findCounts },
    .{ .name = "reader takes the article and says when there is none", .run = readerMode },
    .{ .name = "reader applies theme and size", .run = readerTheme },
    .{ .name = "shield rule list compiles", .run = shieldCompiles },
    .{ .name = "curtain veil hides a fixture element", .run = veilHides },
};

fn answered(b: *app.Browser) bool {
    return b.finder.result != null and !b.finder.busy();
}

fn at(comptime index: usize) fn (*app.Browser) bool {
    return struct {
        fn f(b: *app.Browser) bool {
            const r = b.finder.result orelse return false;
            return r.index == index;
        }
    }.f;
}

fn findCounts(h: *Harness) !void {
    const b = try h.start();
    _ = try web.open(h, b, "kea-test://site/page?title=Find&body=needle%20one,%20needle%20two,%20needle%20three");
    app.page_find.find(b, "needle", .{});
    try h.waitFor(b, answered, 5, "the find answer");
    const r = b.finder.result.?;
    try h.expect(r.index == 1 and r.count == 3 and r.available, "index {?d}, count {?d}, available {}", .{ r.index, r.count, r.available });
    var buf: [48]u8 = undefined;
    const said = app.page_find.status(b, &buf) orelse "";
    try h.expect(std.mem.eql(u8, said, "1 of 3"), "status '{s}'", .{said});
    app.page_find.step(b, 1);
    try h.waitFor(b, at(2), 5, "the second match");
    app.page_find.step(b, -1);
    app.page_find.step(b, -1);
    try h.waitFor(b, at(3), 5, "back round to the last match");
    app.page_find.clear(b);
    try h.expect(b.finder.result == null and !b.finder.finding, "still finding", .{});
}

fn toast(b: *app.Browser) []const u8 {
    return b.announcement orelse "";
}

fn reading(t: *app.Tab) bool {
    return t.reader;
}

fn nothingSaid(b: *app.Browser) bool {
    return std.mem.eql(u8, toast(b), "Nothing to read on this page");
}

fn readerMode(h: *Harness) !void {
    const b = try h.start();
    const t = try web.open(h, b, "kea-test://site/f/article.html");
    app.reader.toggleReader(b);
    try h.waitFor(t, reading, 5, "reading mode");
    try web.evalUntil(h, t, "String(!!document.getElementById('kea-reader') && !document.querySelector('nav'))", "true");
    try web.evalUntil(h, t, "document.querySelector('#kea-reader h1').textContent", "The kea and the snow");
    _ = try web.open(h, b, "kea-test://site/page?title=Empty&body=Hi");
    try h.expect(!b.activeTab().?.reader, "a new page still reading", .{});
    app.reader.toggleReader(b);
    h.waitFor(b, nothingSaid, 5, "the announcement") catch return h.fail("announced '{s}'", .{toast(b)});
}

fn readerTheme(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("reader_theme", .sepia);
    b.prefs.set("reader_size", 22);
    const t = try web.open(h, b, "kea-test://site/f/article.html");
    app.reader.toggleReader(b);
    try h.waitFor(t, reading, 5, "reading mode");
    try web.evalUntil(h, t, "getComputedStyle(document.body).backgroundColor", "rgb(244, 236, 216)");
    try web.evalUntil(h, t, "getComputedStyle(document.getElementById('kea-reader')).fontSize", "22px");
}

fn compiledOrNot(k: *app.Kea) bool {
    return k.shield.list != null or k.shield.trouble != null;
}

fn shieldCompiles(h: *Harness) !void {
    _ = try h.start();
    const k = h.kea.?;
    try h.waitFor(k, compiledOrNot, 15, "the rule list");
    try h.expect(k.shield.trouble == null, "trouble: {s}", .{k.shield.trouble orelse ""});
}

fn veilHides(h: *Harness) !void {
    const b = try h.start();
    const k = h.kea.?;
    // Kept from before: on before the page has drawn.
    k.curtain.hide("#nag", "Nag", "", "site");
    const t = try web.open(h, b, "kea-test://site/page?title=Veil&body=%3Cdiv%20id%3D%22nag%22%3ENag%3C%2Fdiv%3E%3Cdiv%20id%3D%22other%22%3EOther%3C%2Fdiv%3E");
    try web.evalUntil(h, t, "getComputedStyle(document.getElementById('nag')).display", "none");
    try web.evalUntil(h, t, "getComputedStyle(document.getElementById('other')).display", "block");
    // Picked now: off the page that is up, and kept for the site.
    app.curtain_js.picked(b, t, "#other", "Other", "10×10 · top left");
    try web.evalUntil(h, t, "getComputedStyle(document.getElementById('other')).display", "none");
    try h.expect(k.curtain.veils("site").len == 2, "{d} veils kept", .{k.curtain.veils("site").len});
    // ⌘Z while pointing brings the last one back.
    b.veiling = true;
    app.curtain_js.undoHiding(b);
    try web.evalUntil(h, t, "getComputedStyle(document.getElementById('other')).display", "block");
    try h.expect(std.mem.eql(u8, toast(b), "Other is back"), "announced '{s}'", .{toast(b)});
}
