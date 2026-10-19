//! The portable checks of the old `Tests/keazig_smoke.py`, plus P0's
//! lifetime check: closing a split's active tab leaves no slot holding it.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "corrupt session.json is quarantined as .unreadable-<n>.json", .run = quarantine },
    .{ .name = "a tab loads and gets its title", .run = loadsTitle },
    .{ .name = "split halves the hole width", .run = splitHalves },
    .{ .name = "bookmarks panel shrinks the hole by its width + 9", .run = marksPanel },
    .{ .name = "omnibox offers a visited host", .run = omniOffer },
    .{ .name = "typing 'github ' shows the GitHub site chip", .run = siteChip },
    .{ .name = "cmd-. stops a slow load", .run = stopSlow },
    .{ .name = "quit flushes history", .run = quitFlushes },
    .{ .name = "closing a split's active tab frees no slot's webview", .run = closeSplitTab },
};

fn titled(t: *app.Tab) bool {
    t.syncState();
    return std.mem.eql(u8, t.title(), "Zig Guide");
}

fn tabFail(h: *Harness, t: *app.Tab) error{CaseFailed} {
    return h.fail("timed out: title '{s}', url '{s}', loading {}, failure '{s}'", .{ t.title(), t.url(), t.loading, t.failure() orelse "" });
}

fn finished(t: *app.Tab) bool {
    t.syncState();
    return !t.loading and t.progress >= 1;
}

fn unixNow() i64 {
    return @intFromFloat(@floor(app.json.toUnix(app.json.now())));
}

fn quarantine(h: *Harness) !void {
    const p = try h.temp.path(h.gpa, "session.json");
    defer h.gpa.free(p);
    var d = app.disk.Disk.init(h.gpa);
    d.write(p, try h.gpa.dupe(u8, "{broken json"), true);
    d.deinit();
    const before = unixNow();
    _ = try h.start();
    var n = before;
    while (n <= unixNow()) : (n += 1) {
        var buf: [64]u8 = undefined;
        const kept = h.readFile(try std.fmt.bufPrint(&buf, "session.unreadable-{d}.json", .{n})) orelse continue;
        defer h.gpa.free(kept);
        return h.expect(std.mem.eql(u8, kept, "{broken json"), "session.unreadable-{d}.json changed", .{n});
    }
    return h.fail("no session.unreadable-<n>.json", .{});
}

fn loadsTitle(h: *Harness) !void {
    const b = try h.start();
    const t = b.openTab("kea-test://site/page?title=Zig%20Guide&body=hi", true, false);
    h.waitFor(t, titled, 10, "the title") catch return tabFail(h, t);
}

fn openLoaded(h: *Harness, b: *app.Browser, url: []const u8) !*app.Tab {
    const t = b.openTab(url, true, false);
    try h.waitFor(t, finished, 10, url);
    return t;
}

fn splitHalves(h: *Harness) !void {
    const b = try h.start();
    const left = try openLoaded(h, b, "kea-test://site/page?title=Left");
    const right = try openLoaded(h, b, "kea-test://site/f/hello.html");
    b.selectTab(left.id);
    h.frame();
    const single = b.active_page_frame.w;
    b.prefs.set("split_view", true); // off unless asked for, as in Swift
    b.pairSplit(right.id);
    h.frame();
    const split = b.active_page_frame.w;
    try h.expect(single > 400 and split < single * 0.6, "hole {d:.1} → {d:.1}", .{ single, split });
    const sh = b.stage_host.?;
    try h.expect(sh.slots[0].webview == left.web and sh.slots[1].webview == right.web, "slots don't hold both panes", .{});
}

fn marksPanel(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("sidebar", true);
    h.frame();
    const before = b.active_page_frame.w;
    h.press("b", 11, true, true); // ⌃⌘B
    h.frame();
    const after = b.active_page_frame.w;
    const want = b.prefs.marks_width + 9;
    try h.expect(b.marks_open, "⌃⌘B didn't open the panel", .{});
    try h.expect(@abs((before - after) - want) <= 2, "hole {d:.1} → {d:.1}, want a {d:.1} shrink", .{ before, after, want });
}

fn omniOffer(h: *Harness) !void {
    const b = try h.start();
    var buf: [128]u8 = undefined;
    _ = try openLoaded(h, b, try std.fmt.bufPrint(&buf, "{s}/zig-guide", .{h.http}));
    b.omni_open = true;
    b.omni_buf.set("127.0");
    b.updateOmniTyped("127.0");
    const offer = b.omni_offer[0..b.omni_offer_len];
    try h.expect(std.mem.startsWith(u8, offer, "127.0.0.1"), "offer was '{s}'", .{offer});
}

fn siteChip(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("searches_sites", true); // off unless asked for, as in Swift
    b.omni_open = true;
    b.omni_buf.set("github ");
    b.updateOmniTyped("github ");
    const chip = b.omni_chip orelse return h.fail("no chip", .{});
    try h.expect(std.mem.eql(u8, chip.name, "GitHub"), "chip was '{s}'", .{chip.name});
}

/// WebKit holds `/slow`'s first bytes until the rest arrives 8 s later:
/// the load stays in flight.
fn loadingSlow(t: *app.Tab) bool {
    t.syncState();
    return t.loading and t.progress > 0.1;
}

fn stopSlow(h: *Harness) !void {
    const b = try h.start();
    const t = b.openTab("kea-test://site/slow", true, false);
    h.waitFor(t, loadingSlow, 10, "the slow load to start") catch return tabFail(h, t);
    h.pump(0.3);
    t.syncState();
    try h.expect(t.loading, "/slow finished before ⌘.", .{});
    h.press(".", 47, true, false); // ⌘.
    h.pump(0.3);
    t.syncState();
    try h.expect(!t.loading and t.stopped, "still loading after ⌘.", .{});
    const wv = t.web orelse return h.fail("no webview", .{});
    try h.expect(!objc.msg(objc.BOOL, wv, "isLoading", .{}), "WebKit still loading after ⌘.", .{});
}

fn quitFlushes(h: *Harness) !void {
    const b = try h.start();
    var buf: [128]u8 = undefined;
    _ = b.openTab(try std.fmt.bufPrint(&buf, "{s}/flushed-on-quit", .{h.http}), true, false);
    h.quit();
    const hist = h.readFile("history.json") orelse return h.fail("no history.json", .{});
    defer h.gpa.free(hist);
    try h.expect(std.mem.indexOf(u8, hist, "/flushed-on-quit") != null, "history.json lacks the visit: {s}", .{hist[0..@min(hist.len, 200)]});
}

fn closeSplitTab(h: *Harness) !void {
    const b = try h.start();
    const left = try openLoaded(h, b, "kea-test://site/page?title=Left");
    const right = try openLoaded(h, b, "kea-test://site/page?title=Right");
    b.selectTab(left.id);
    b.prefs.set("split_view", true);
    b.pairSplit(right.id);
    h.frame();
    const freed = left.web.?;
    const right_web = right.web.?;
    b.closeTab(left.id);
    h.pump(0.2); // a frame places webviews: any stale slot would message the freed one
    const sh = b.stage_host.?;
    for (sh.slots) |slot| try h.expect(slot.webview != freed, "a slot still holds the closed tab's webview", .{});
    try h.expect(sh.peek_slot.webview != freed, "the peek slot holds the closed tab's webview", .{});
    try h.expect(sh.slots[0].webview == right_web, "the remaining tab isn't in the first slot", .{});
}
