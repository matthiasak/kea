//! P8.4-P8.6, P8.10: History (by day, clearing), Downloads (rows and their
//! actions), the find bar's room, and the bars (the capture question
//! answering WebKit's decision, the announcement, the veiling hint).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

fn start(f: *Fixture) !void {
    try f.init(gpa, .{ .sidebar = false, .tabs = 1 });
    // A page in front: a blank tab's address field would take the keys.
    f.browser.select(f.browser.tabs.items[f.browser.tabs.items.len - 1]);
    f.tester.settle(1);
}

fn yOf(f: *Fixture, s: []const u8) !f32 {
    return (f.tester.findText(s) orelse return error.NotShown).y;
}

test "history panel groups seeded visits by day" {
    var f: Fixture = undefined;
    try start(&f);
    defer f.deinit();
    const now = app.json.now();
    const today = app.when.startOfDay(now);
    f.kea.history.take("https://kea.example/today-late", "Late today", 1, now);
    f.kea.history.take("https://kea.example/today-early", "Early today", 1, @max(today + 1, now - 60));
    f.kea.history.take("https://kea.example/yesterday", "Yesterday's page", 1, today - 3600);
    f.kea.history.take("https://kea.example/old", "Long ago", 1, today - 10 * 86400);
    app.sheet.show(f.browser, .recalling);
    f.tester.settle(1);
    try t.expect(f.tester.hasText("History"));
    try t.expect(f.tester.hasText("4 pages"));
    // Days newest first, each day's pages under its name, newest first.
    const y_today = try yOf(&f, "Today");
    const y_late = try yOf(&f, "Late today");
    const y_early = try yOf(&f, "Early today");
    const y_yesterday = try yOf(&f, "Yesterday");
    const y_ypage = try yOf(&f, "Yesterday's page");
    const y_old = try yOf(&f, "Long ago");
    try t.expect(y_today < y_late and y_late < y_early and y_early < y_yesterday);
    try t.expect(y_yesterday < y_ypage and y_ypage < y_old);
    try t.expect(f.browser.recall.days.len == 3);
    // The hunt narrows it.
    f.tester.typeText("ago");
    f.tester.settle(1);
    try t.expect(f.tester.hasText("1 page"));
    try t.expect(!f.tester.hasText("Late today"));
}

test "history clearing cards and clear history forget icons too" {
    var f: Fixture = undefined;
    try start(&f);
    defer f.deinit();
    f.kea.history.record("https://kea.example/", "Kea");
    app.history_panel.showClearing(f.browser);
    f.tester.settle(1);
    try t.expect(f.browser.recalling and f.browser.recall.clearing);
    try t.expect(f.tester.hasText("Cookies and sign-ins"));
    try t.expect(f.tester.hasText("Sign out of everything"));
    try t.expect(f.tester.hasText("Only what was fetched to draw pages"));
    // An icon kept on disk goes with the history.
    const icons = try std.fs.path.join(gpa, &.{ f.kea.store.folder, "icons" });
    defer gpa.free(icons);
    app.disk.makePath(gpa, icons);
    const icon = try std.fs.path.join(gpa, &.{ icons, "kea.example.png" });
    defer gpa.free(icon);
    f.kea.store.disk.write(icon, try gpa.dupe(u8, "png"), true);
    try t.expect(app.downloads.exists(icon));
    try f.tester.clickText("Clear");
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 0), f.kea.history.visits.count());
    try t.expect(!app.downloads.exists(icon));
    try t.expectEqualStrings("History cleared — no footprints left", f.browser.announcement.?);
    try t.expect(!f.browser.recall.clearing);
    try t.expect(f.tester.hasText("0 pages"));
}

test "history's foot fades between the count and the clearing cards" {
    var f: Fixture = undefined;
    try start(&f);
    defer f.deinit();
    f.kea.history.record("https://kea.example/", "Kea");
    app.sheet.show(f.browser, .recalling);
    f.tester.settle(1);
    try f.tester.clickText("Clear…");
    f.tester.advance(0.05);
    // Mid-way, both: the count leaving where it stood, the cards arriving.
    try t.expect(f.browser.recall.clearing);
    try t.expect(f.tester.hasText("Clear…") and f.tester.hasText("Sign out of everything"));
    f.tester.settle(1);
    try t.expect(!f.tester.hasText("Clear…"));
    try f.tester.clickText("Back");
    f.tester.advance(0.05);
    try t.expect(f.tester.hasText("Clear…") and f.tester.hasText("Sign out of everything"));
    f.tester.settle(1);
    try t.expect(!f.tester.hasText("Sign out of everything"));
}

test "downloads panel lists a seeded Loot row and its actions call through" {
    var f: Fixture = undefined;
    try start(&f);
    defer f.deinit();
    const file = try std.fs.path.join(gpa, &.{ f.kea.store.folder, "kept.txt" });
    defer gpa.free(file);
    f.kea.store.disk.write(file, try gpa.dupe(u8, "kept"), true);
    f.kea.loot.add(.{ .name = "kept.txt", .from = "kea.example", .path = file, .date = app.json.now() });
    // A paused download that can't resume: only Remove.
    const e = app.downloads.Entry.create(f.kea.gpa, "stalled.zip", null, null);
    e.state = .paused;
    e.completed_bytes = 2048;
    try f.kea.fetches.entries.append(f.kea.gpa, e);
    app.downloads_panel.toggle(f.browser);
    f.tester.settle(1);
    try t.expect(f.browser.hoarding);
    try t.expect(f.tester.hasText("Current downloads"));
    try t.expect(f.tester.hasText("Completed"));
    try t.expect(f.tester.hasText("kept.txt"));
    try t.expect(f.tester.hasText("stalled.zip"));
    try t.expect(f.tester.containsText("Paused · "));
    try t.expect(f.tester.hasText("Clearing the list leaves the files where they are"));
    // Remove on the paused row lets it go.
    try f.tester.clickText("Remove");
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 0), f.kea.fetches.entries.items.len);
    // Under the pointer, the kept row offers Show in Finder and Remove.
    const row = f.tester.findText("kept.txt") orelse return error.NotShown;
    f.tester.moveTo(row.x + 4, row.y + 4);
    f.tester.settle(1);
    try t.expect(f.tester.hasText("Show in Finder"));
    try f.tester.clickText("Remove");
    f.tester.settle(1);
    try t.expectEqual(@as(usize, 0), f.kea.loot.kept.len);
    try t.expect(app.downloads.exists(file));
    try t.expect(f.tester.hasText("Nothing downloaded yet. The nest is empty."));
    try t.expect(f.tester.containsText("Files land in "));
}

const Decided = struct { value: ?objc.NSInteger = null };

fn decided(d: *Decided, v: objc.NSInteger) void {
    d.value = v;
}

fn askCamera(f: *Fixture, d: *Decided) !void {
    var block = objc.Block(Decided, &.{objc.NSInteger}).init(d, decided);
    const tab = f.browser.activeTab().?;
    const a = app.dialogs.make(tab, .capture, "kea.example", "camera", @ptrCast(&block)) orelse return error.OutOfMemory;
    app.dialogs.keepAs(a, "https://kea.example|0");
    app.dialogs.ask(tab, a);
    f.tester.settle(1);
}

test "capture bar answers the decision" {
    var f: Fixture = undefined;
    try start(&f);
    defer f.deinit();
    var d: Decided = .{};
    try askCamera(&f, &d);
    try t.expect(f.browser.asking != null);
    try t.expect(f.tester.hasText("kea.example wants to use your camera"));
    // The first half second takes no click: a page can't time one onto Allow.
    // (Pinned to now: settling draws in real time.)
    f.browser.asking.?.shown = nanoui.ui.clock.now() + 5;
    try f.tester.clickText("Allow");
    try t.expect(d.value == null and f.browser.asking != null);
    f.browser.asking.?.shown = nanoui.ui.clock.now() - 1;
    f.tester.settle(1);
    try t.expect(d.value == null and f.browser.asking != null);
    f.browser.asking.?.shown -= 1;
    try f.tester.clickText("Allow");
    f.tester.settle(1);
    try t.expectEqual(@as(?objc.NSInteger, 1), d.value);
    try t.expect(f.browser.asking == null);
    try t.expectEqual(@as(?bool, true), f.kea.store.bool("capture.https://kea.example|0"));
    try t.expect(!f.tester.hasText("kea.example wants to use your camera"));

    // Refused, and kept refused; a second page asking meanwhile is refused outright.
    var d2: Decided = .{};
    try askCamera(&f, &d2);
    var d3: Decided = .{};
    try askCamera(&f, &d3);
    try t.expectEqual(@as(?objc.NSInteger, 2), d3.value);
    f.browser.asking.?.shown -= 1;
    try f.tester.clickText("Don't allow");
    f.tester.settle(1);
    try t.expectEqual(@as(?objc.NSInteger, 2), d2.value);
    try t.expectEqual(@as(?bool, false), f.kea.store.bool("capture.https://kea.example|0"));
}

test "announcement and veiling hint rise from the bottom" {
    var f: Fixture = undefined;
    try start(&f);
    defer f.deinit();
    f.browser.announce("Bookmark added");
    f.tester.settle(1);
    const said = f.tester.findText("Bookmark added") orelse return error.NotShown;
    try t.expect(said.y > f.tester.ctx.size.h - 80);
    f.browser.veiling = true;
    f.tester.settle(1);
    try t.expect(f.tester.hasText(app.bars.veil_hint));
}

test "find bar narrows below 290 points" {
    try t.expectEqual(@as(f32, 150), app.find_bar.fieldWidth(null));
    try t.expect(!app.find_bar.narrow(null));
    try t.expect(app.find_bar.narrow(289));
    try t.expect(!app.find_bar.narrow(290));
    try t.expectEqual(@as(f32, 160), app.find_bar.fieldWidth(600));
    try t.expectEqual(@as(f32, 120), app.find_bar.fieldWidth(200));
    try t.expectEqual(@as(f32, 40), app.find_bar.fieldWidth(100));
}
