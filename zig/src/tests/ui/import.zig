//! P11: Bring things over — the sheet finds made-up browsers under the test
//! root's `Import` folder (never a real profile, never the keychain),
//! brings their bookmarks and history in and says so; a file brought in
//! shows its card in the corner until done; the Welcome's page offers the
//! browsers found as a Segmented.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try std.mem.printSentinel(&buf, "{s}", .{path}, 0);
    const f = std.c.fopen(z, "wb") orelse return error.Unwritable;
    defer _ = std.c.fclose(f);
    if (std.c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return error.Unwritable;
}

fn sql(path: []const u8, statements: [:0]const u8) !void {
    const db = try app.sqlite.Db.open(path, app.sqlite.open_readwrite | app.sqlite.open_create);
    defer db.close();
    try db.exec(statements);
}

/// A made-up Chrome (two bookmarks, two places) and Firefox (one bookmark,
/// one place) under `<root>/Import`.
pub fn madeUp(a: std.mem.Allocator, root: []const u8) !void {
    const chrome = try std.fs.path.join(a, &.{ root, "Import/Google/Chrome/Default" });
    app.disk.makePath(a, chrome);
    try writeFile(try std.fs.path.join(a, &.{ chrome, "Bookmarks" }),
        \\{"roots":{"bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[
        \\{"type":"url","name":"Zig","url":"https://ziglang.org/"},
        \\{"type":"url","name":"Kea","url":"https://kea.example/"}]},
        \\"other":{"type":"folder","name":"Other","children":[]}}}
    );
    try sql(try std.fs.path.join(a, &.{ chrome, "History" }),
        \\CREATE TABLE urls(url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_time INTEGER);
        \\INSERT INTO urls VALUES('https://chrome-one.example/', 'One', 3, 0, 13300000000000000);
        \\INSERT INTO urls VALUES('https://chrome-two.example/', 'Two', 1, 0, 13300000000000001);
    );
    const fox = try std.fs.path.join(a, &.{ root, "Import/Firefox/Profiles/kea.default" });
    app.disk.makePath(a, fox);
    try sql(try std.fs.path.join(a, &.{ fox, "places.sqlite" }),
        \\CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_date INTEGER);
        \\CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
        \\INSERT INTO moz_places VALUES(1, 'https://fox.example/', 'Fox', 2, 0, 1700000000000000);
        \\INSERT INTO moz_bookmarks VALUES(1, 2, NULL, 0, 0, 'toolbar', 'toolbar_____');
        \\INSERT INTO moz_bookmarks VALUES(2, 1, 1, 1, 0, 'Fox', 'foxfoxfoxfox');
    );
}

/// Frames and the run loop, until `done(f)` or a few seconds have passed.
fn waitFor(f: *Fixture, done: *const fn (*Fixture) bool) !void {
    var n: usize = 0;
    while (!done(f)) : (n += 1) {
        if (n > 200) return error.Timeout;
        nanoui.runFor(0.02);
        f.tester.frame();
    }
    f.tester.settle(1);
}

fn control(f: *Fixture, role: ui.A11yRole, label: []const u8) ?ui.Rect {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) return c.rects.get(item.id);
    return null;
}

fn counted(f: *Fixture) bool {
    const s = f.browser.importing.panel orelse return false;
    if (s.looking) return false;
    for (0..s.found.len) |i| if (s.preview(i) == null) return false;
    return true;
}

fn brought(f: *Fixture) bool {
    const s = f.browser.importing.panel orelse return false;
    return s.brought;
}

test "Bring things over lists browsers and brings bookmarks and history in" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try madeUp(arena.allocator(), f.temp.root);
    const b = f.browser;

    // File › Bring Things Over… opens the sheet; it looks, then counts.
    app.commands.named("file.import").?.run(b);
    try t.expectEqual(app.sheet.Kind.bringing, app.sheet.current(b).?);
    try waitFor(&f, counted);
    try t.expect(f.tester.hasText("On this Mac"));
    try t.expect(f.tester.hasText("Chrome"));
    try t.expect(f.tester.hasText("Firefox"));
    try t.expect(f.tester.hasText("2 bookmarks · 2 places"));
    // Chrome has no passwords: said so, and not read.
    try t.expect(f.tester.hasText("None in Chrome"));

    const bring_in = control(&f, .button, "Bring them in") orelse return error.NoControl;
    f.tester.click(bring_in.x + bring_in.w / 2, bring_in.y + bring_in.h / 2);
    try waitFor(&f, brought);
    try t.expectEqual(@as(usize, 2), app.bookmarks_data.Bookmarks.count(f.kea.bookmarks.roots));
    try t.expect(f.kea.history.visits.count() >= 2);
    try t.expect(f.tester.hasText("2 bookmarks"));
    try t.expect(f.tester.hasText("2 places"));
    try t.expect(f.tester.hasText("Show bookmarks"));

    // Firefox picked: its own counts, and its bookmark comes in beside Chrome's.
    const fox = control(&f, .radio_button, "Firefox") orelse return error.NoControl;
    f.tester.click(fox.x + fox.w / 2, fox.y + fox.h / 2);
    f.tester.settle(1);
    try t.expect(!f.browser.importing.panel.?.brought);
    const again = control(&f, .button, "Bring them in") orelse return error.NoControl;
    f.tester.click(again.x + again.w / 2, again.y + again.h / 2);
    try waitFor(&f, brought);
    try t.expectEqual(@as(usize, 3), app.bookmarks_data.Bookmarks.count(f.kea.bookmarks.roots));
    try t.expect(f.tester.hasText("1 places"));

    // Esc puts it away, and its session lets go once it has left.
    try t.expect(app.sheet.closePanel(b));
    f.tester.settle(2);
    try t.expect(b.importing.panel == null);
}

fn fileDone(f: *Fixture) bool {
    return f.browser.importing.file == null;
}

test "a file brought in shows its card until done" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ f.temp.root, "exported.html" });
    try writeFile(path,
        \\<!DOCTYPE NETSCAPE-Bookmark-file-1>
        \\<DL><p>
        \\  <DT><A HREF="https://ziglang.org/">Zig</A>
        \\</DL><p>
    );
    try t.expect(app.browser_import.takeFile(f.browser, path));
    // A second one waits for the first.
    try t.expect(!app.browser_import.takeFile(f.browser, path));
    f.tester.frame();
    try t.expect(f.tester.hasText("exported.html"));
    try t.expect(f.tester.hasText("Cancel"));
    try waitFor(&f, fileDone);
    try t.expect(!f.tester.hasText("exported.html"));
    try t.expectEqual(@as(usize, 1), app.bookmarks_data.Bookmarks.count(f.kea.bookmarks.roots));
    try t.expectEqualStrings("1 bookmark", f.browser.announcement.?);
}

test "Welcome's bring page offers the browsers found" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .welcome = true });
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try madeUp(arena.allocator(), f.temp.root);
    try t.expect(f.browser.welcoming);
    f.browser.welcome.page = 1;
    f.tester.settle(2);
    try t.expect(f.tester.hasText("Bring things over."));
    try t.expect(control(&f, .radio_button, "Chrome") != null);
    try t.expect(control(&f, .radio_button, "Firefox") != null);
    try t.expect(f.tester.hasText("Folders and all, behind the bookmark button"));
    try t.expect(control(&f, .button, "Bring them in") != null);
}
