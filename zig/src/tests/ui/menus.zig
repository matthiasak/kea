//! P8.9: the menu bar as App.swift's `.commands` builds it, keys moved in
//! Settings › Shortcuts moving on it, and Escape's order (`ContentView.take`).
const std = @import("std");
const nanoui = @import("nanoui");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

/// The labels of `items`, a separator as "─".
fn labels(a: std.mem.Allocator, items: []const nanoui.MenuItem) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |it| if (!it.hidden) try out.append(a, if (it.is_separator) "─" else it.label);
    return out.items;
}

fn expectLabels(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "menu bar menus and the File menu in App.swift's order" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bar = try app.menus.bar(a, f.kea, f.browser);
    // SwiftUI's app menu, File, Edit, View; the `CommandMenu`s in order; Window. Help is replaced by nothing.
    try expectLabels(&.{ app.kea.app_name, "File", "Edit", "View", "Tabs", "Bookmarks", "History", "Window" }, try labels(a, bar));
    // App.swift:47-78: `.newItem` replaced, then `.printItem`.
    const file = bar[1].submenu.?;
    const want = [_][]const u8{ "New Window", "New Tab", "New Private Tab", "Reopen Closed Tab", "─", "Open Address…", "─", "Bring Things Over…", "─", "Close Tab", "─", "Share…", "Print…" };
    try expectLabels(&want, try labels(a, file));
    // Nothing to share or print from a blank tab; nothing closed to reopen.
    try t.expect(file[3].disabled);
    try t.expect(file[file.len - 1].disabled and file[file.len - 2].disabled);
    // Dynamic titles: the fold item follows the sidebar and the fold.
    var view = bar[3].submenu.?;
    try t.expectEqualStrings("Hide Tab Bar", view[1].label);
    f.browser.folded = true;
    view = (try app.menus.bar(a, f.kea, f.browser))[3].submenu.?;
    try t.expectEqualStrings("Show Tab Bar", view[1].label);
}

test "a key moved in Settings moves on its menu item and runs the command" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const new_tab = struct {
        fn of(items: []const nanoui.MenuItem) *const nanoui.MenuItem {
            for (items) |*it| if (std.mem.eql(u8, it.id, "file.newTab")) return it;
            unreachable;
        }
    }.of;
    try t.expectEqualStrings("Cmd+t", new_tab((try app.menus.bar(a, f.kea, f.browser))[1].submenu.?).accelerator);
    f.kea.shortcuts.setOverride("file.newTab", app.shortcuts.combo("t", .{ .option = true }));
    try t.expectEqualStrings("Cmd+Alt+t", new_tab((try app.menus.bar(a, f.kea, f.browser))[1].submenu.?).accelerator);
    // ⌥⌘T now opens a tab, from the key monitor (from a page: a blank tab is reused).
    const page = f.browser.activeTab().?;
    page.own(&page.address, "https://www.example.com/a");
    const before = f.browser.tabs.items.len;
    try t.expect(f.press("t", 17, .{ .cmd = true, .alt = true }));
    try t.expectEqual(before + 1, f.browser.tabs.items.len);
}

test "a key being recorded in Settings is left to the box" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const page = f.browser.activeTab().?;
    page.own(&page.address, "https://www.example.com/a");
    const before = f.browser.tabs.items.len;
    f.kea.shortcuts.recording = true;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ev = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{}, @as(objc.NSUInteger, app.shortcuts.flag.command), @as(f64, 0), @as(objc.NSInteger, 0),
        @as(?objc.Object, null), objc.nsString("t"), objc.nsString("t"), false, @as(u16, 17),
    });
    try t.expect(!app.keys.take(f.browser, ev));
    try t.expectEqual(before, f.browser.tabs.items.len);
}

test "escape closes one thing at a time, in Swift's order" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const b = f.browser;
    const tab = b.activeTab().?;
    tab.own(&tab.address, "https://www.example.com/a");
    b.edit();
    b.finder.finding = true;
    app.hidden_panel.setReviewing(b, true);
    app.sheet.show(b, .tuning);
    b.peek("https://www.example.com/b", tab);
    f.tester.settle(1);
    // The peek, the sheet, the hidden list, the find bar, then the field.
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(b.peek_tab == null and b.tuning);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(!b.tuning and b.reviewing);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(!b.reviewing and b.finder.finding);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(!b.finder.finding and b.editing);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(!b.editing);
    // Nothing left that wants it: it goes on to the page.
    const pool = nanoui.objc.Pool.push();
    defer pool.pop();
    try t.expect(!app.keys.take(b, escEvent()));
}

fn escEvent() nanoui.objc.Object {
    const objc = nanoui.objc;
    return objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{}, @as(objc.NSUInteger, 0), @as(f64, 0), @as(objc.NSInteger, 0),
        @as(?objc.Object, null), objc.nsString("\x1b"), objc.nsString("\x1b"), false, @as(u16, 53),
    });
}
