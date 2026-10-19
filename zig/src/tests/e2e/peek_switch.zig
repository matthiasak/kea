//! P7: a shift-clicked link peeked at over the page and kept with ⌘Return;
//! ⌃Tab's switcher, its pictures taken, and ⌃ let go of going back.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "shift-click opens peek and cmd-return keeps it as a tab", .run = peekKept },
    .{ .name = "ctrl-tab then release returns to previous tab", .run = controlTab },
};

/// The peek's page, loaded at the link's address.
fn peeked(b: *app.Browser) bool {
    const t = b.peek_tab orelse return false;
    return std.mem.endsWith(u8, t.url(), "/peeked") and !t.loading;
}

fn peekKept(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("peeks_links", true);
    const from = try web.open(h, b, "kea-test://site/f/links.html");
    const count = b.tabs.items.len;
    // Peeks are for web addresses (Browser.swift:4285): the loopback site's.
    var buf: [400]u8 = undefined;
    const where = try web.eval(h, from, try std.fmt.bufPrint(&buf, "var a = document.getElementById('plain'); a.href = '{s}/peeked'; var r = a.getBoundingClientRect(); (r.left + r.width / 2) + ',' + (r.top + r.height / 2)", .{h.http}));
    var parts = std.mem.splitScalar(u8, where, ',');
    const x = std.fmt.parseFloat(f64, parts.next() orelse "") catch return h.fail("no link at '{s}'", .{where});
    const y = std.fmt.parseFloat(f64, parts.next() orelse "") catch return h.fail("no link at '{s}'", .{where});
    web.clickAt(from.web.?, x, y, 1 << 17); // ⇧
    try h.waitFor(b, peeked, 10, "the peeked page");
    const page = b.peek_tab.?;
    try h.expect(b.tabs.items.len == count, "the peek joined the row", .{});
    try h.expect(b.activeTab().? == from, "the page under the peek left the front", .{});
    try h.expect(std.mem.endsWith(u8, from.url(), "links.html"), "the page itself went to '{s}'", .{from.url()});
    // On the stage, at the panel's hole: the last one, after the page's.
    h.frame();
    const sh = b.stage_host.?;
    try h.expect(sh.peek_slot.webview == page.web, "the peek's page isn't on the stage", .{});
    const s = b.window.?.surface.?;
    const holes = s.ctx.stage_rects[0..s.ctx.stage_count];
    try h.expect(holes.len == 2, "{d} holes with the peek open", .{holes.len});
    const frame = objc.msg(objc.CGRect, page.web.?, "frame", .{});
    try h.expect(@abs(frame.size.width - holes[1].w) < 0.5 and @abs(frame.origin.x - holes[1].x) < 0.5, "the peek's page at x {d} w {d}, its hole at x {d} w {d}", .{ frame.origin.x, frame.size.width, holes[1].x, holes[1].w });

    h.press("\r", 36, true, false); // ⌘Return
    try h.expect(b.peek_tab == null, "⌘Return left the peek open", .{});
    try h.expect(b.tabs.items.len == count + 1, "{d} tabs after keeping the peek", .{b.tabs.items.len});
    try h.expect(b.activeTab().? == page, "the kept page isn't in front", .{});
    try h.expect(b.indexOf(page).? == b.indexOf(from).? + 1, "the kept page isn't beside the one it came from", .{});
    h.frame();
    try h.expect(sh.peek_slot.webview == null and sh.slots.items[0].webview == page.web, "the kept page isn't the stage's page", .{});
}

fn controlTab(h: *Harness) !void {
    const b = try h.start();
    const a = try web.open(h, b, "kea-test://site/page?title=A");
    const second = try web.open(h, b, "kea-test://site/page?title=B");
    try h.expect(b.activeTab().? == second, "B isn't in front", .{});
    h.press("\t", 48, false, true); // ⌃Tab, ⌃ held
    try h.expect(b.switcher.active(), "⌃Tab didn't start the switcher", .{});
    try h.expect(b.switcher.selected == a.id, "the switcher isn't on the tab left last", .{});
    // Held: the panel comes, and the pictures of its pages.
    try h.waitFor(b, struct {
        fn f(br: *app.Browser) bool {
            return br.switcher.visible and br.switcher.previews.count() >= 2;
        }
    }.f, 5, "the switcher's pictures");
    try h.expect(b.switcher.preview(a.id, a.address) != null, "no picture of A", .{});
    letGoOfControl(h);
    try h.expect(!b.switcher.active(), "⌃ let go of left the switcher up", .{});
    try h.expect(b.activeTab().? == a, "⌃ let go of didn't go back to A", .{});
}

/// ⌃ let go of, as AppKit hands it on (`flagsChanged`), through the app.
fn letGoOfControl(h: *Harness) void {
    h.send(12, "", 59, 0);
}
