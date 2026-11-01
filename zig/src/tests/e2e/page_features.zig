//! P5.6 page features, part A: Find on page counts and steps, Reading mode
//! takes the article (and says when there is none) or a Markdown page or
//! twin, the ad blocker's rule list compiles, Curtain's sheet hides what was
//! taken off a site, before the page draws and on the page already up, and
//! the back and forward menus jump through a tab's history.
const std = @import("std");
const nanoui = @import("nanoui");
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "find counts matches", .run = findCounts },
    .{ .name = "reader takes the article and says when there is none", .run = readerMode },
    .{ .name = "reader renders markdown and markdown twin with fallback", .run = readerMarkdown },
    .{ .name = "reader applies theme and size", .run = readerTheme },
    .{ .name = "shield rule list compiles", .run = shieldCompiles },
    .{ .name = "curtain veil hides a fixture element", .run = veilHides },
    .{ .name = "gpc and click tracker stripping", .run = gpcAndCleanUrl },
    .{ .name = "back and forward menus jump history entries", .run = backForwardMenus },
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

/// Reading mode on `url`'s page: its heading `title`, from `from`.
fn readsAs(h: *Harness, b: *app.Browser, url: []const u8, title: []const u8, from: []const u8) !void {
    const t = try web.open(h, b, url);
    app.reader.toggle(t);
    h.waitFor(t, reading, 10, url) catch return h.fail("{s} not read: announced '{s}'", .{ url, toast(b) });
    try web.evalUntil(h, t, "document.querySelector('#kea-reader h1').textContent", title);
    try web.evalUntil(h, t, "document.querySelector('#kea-reader .kea-from').textContent", from);
}

fn readerMarkdown(h: *Harness) !void {
    const b = try h.start();
    // A Markdown page, rendered rather than read as text.
    try readsAs(h, b, "kea-test://site/doc.md", "Mountain Kea", "site · markdown");
    try web.evalUntil(h, b.activeTab().?, "document.querySelector('#kea-reader code').textContent", "code");
    try web.evalUntil(h, b.activeTab().?, "document.querySelector('#kea-reader strong').textContent", "bold");
    // An HTML page naming its Markdown twin: the twin is what's read.
    try readsAs(h, b, "kea-test://site/twin.html", "Mountain Kea", "site · markdown");
    // A twin that isn't there: the page's own article.
    try readsAs(h, b, "kea-test://site/broken-twin.html", "Broken Twin", "site");
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
    try web.evalUntil(h, t, "String(document.querySelectorAll('#kea-reader-theme button').length)", "4");
    try web.evalUntil(h, t, "(document.querySelector('#kea-reader-theme button[data-theme=\"dark\"]').click(), document.documentElement.dataset.krTheme)", "dark");
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

fn gpcAndCleanUrl(h: *Harness) !void {
    const b = try h.start();
    var ubuf: [256]u8 = undefined;
    const dirty = try std.fmt.bufPrint(&ubuf, "{s}/page?title=Clean&fbclid=abc123&gclid=xyz987&keep=1", .{h.http});
    const t = try web.open(h, b, dirty);
    try h.expect(std.mem.indexOf(u8, t.url(), "fbclid=") == null and std.mem.indexOf(u8, t.url(), "keep=1") != null, "url was '{s}'", .{t.url()});
    try web.evalUntil(h, t, "String(navigator.globalPrivacyControl)", "true");
}

/// The menu's `label`, chosen; false when the menu hasn't it.
pub fn fire(items: []const nanoui.MenuItem, label: []const u8) bool {
    for (items) |it| if (!it.is_separator and std.mem.eql(u8, it.label, label)) {
        const click = it.click orelse return false;
        var unused: nanoui.menu.Item = undefined;
        click.func(click.ctx, &unused);
        return true;
    };
    return false;
}

const Titled = struct { t: *app.Tab, want: []const u8 };

fn titled(c: Titled) bool {
    return !c.t.loading and std.mem.eql(u8, c.t.title(), c.want);
}

fn backForwardMenus(h: *Harness) !void {
    const b = try h.start();
    var buf: [128]u8 = undefined;
    const t = try web.open(h, b, try std.fmt.bufPrint(&buf, "{s}/back-a", .{h.http}));
    for ([_][]const u8{ "/back-b", "/back-c" }) |path| {
        t.go(try std.fmt.bufPrint(&buf, "{s}{s}", .{ h.http, path }));
        var want: [32]u8 = undefined;
        const title = try std.fmt.bufPrint(&want, "Local {s}", .{path});
        h.waitFor(Titled{ .t = t, .want = title }, titled, 10, title) catch return h.fail("at '{s}' titled '{s}'", .{ t.url(), t.title() });
    }
    var arena = std.heap.ArenaAllocator.init(h.gpa);
    defer arena.deinit();
    // Nearest first: two steps back is the second.
    const back = try app.tab_title.backMenu(arena.allocator(), b, 0);
    try h.expect(back.len == 2 and std.mem.eql(u8, back[0].label, "Local /back-b") and std.mem.eql(u8, back[1].label, "Local /back-a"), "back menu has {d} items, first '{s}'", .{ back.len, if (back.len > 0) back[0].label else "" });
    try h.expect(fire(back, "Local /back-a"), "no Local /back-a in the back menu", .{});
    h.waitFor(Titled{ .t = t, .want = "Local /back-a" }, titled, 10, "two steps back") catch return h.fail("at '{s}' titled '{s}'", .{ t.url(), t.title() });
    try h.expect(std.mem.endsWith(u8, t.url(), "/back-a"), "back at '{s}'", .{t.url()});
    const fwd = try app.tab_title.backMenu(arena.allocator(), b, 1);
    try h.expect(fwd.len == 2 and std.mem.eql(u8, fwd[0].label, "Local /back-b") and std.mem.eql(u8, fwd[1].label, "Local /back-c"), "forward menu has {d} items, first '{s}'", .{ fwd.len, if (fwd.len > 0) fwd[0].label else "" });
}
