//! P8.1-P8.3: sheets one at a time over the window, Settings on its
//! remembered page, a switch on it moving the page, a key moved in
//! Settings › Shortcuts kept as a difference, and Esc taking the sheet
//! before the field.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

/// The rect of the control VoiceOver calls `label` with `role`.
fn control(f: *Fixture, role: ui.A11yRole, label: []const u8) ?ui.Rect {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) return c.rects.get(item.id);
    return null;
}

fn clickControl(f: *Fixture, role: ui.A11yRole, label: []const u8) !void {
    const r = control(f, role, label) orelse return error.NoControl;
    f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
}

test "cmd-comma opens Settings on remembered page" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    f.kea.store.setString("settings.page", "privacy");
    try t.expect(f.press(",", 43, .{ .cmd = true }));
    f.tester.settle(1);
    try t.expect(f.browser.tuning);
    try t.expectEqual(app.settings.Page.privacy, f.browser.settings.page.?);
    try t.expect(f.tester.hasText("Block ads and trackers"));
    // The rail's other page, picked, is the one remembered next time.
    try clickControl(&f, .tab, "Tabs");
    f.tester.settle(1);
    try t.expect(f.tester.hasText("Tabs in a sidebar"));
    const saved = f.kea.store.string("settings.page").?;
    defer f.kea.store.gpa.free(saved);
    try t.expectEqualStrings("tabs", saved);
    // ⌘, again puts it away; its floor and panel leave.
    try t.expect(f.press(",", 43, .{ .cmd = true }));
    f.tester.settle(1);
    try t.expect(!f.browser.tuning);
    try t.expect(!f.tester.hasText("Tabs in a sidebar"));
}

test "sheets stack as Swift's flags do and close in closePanel's order" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    app.sheet.show(b, .tuning);
    f.tester.settle(1);
    // ⌘Y over Settings: History opens too, Settings stays.
    app.sheet.toggle(b, .recalling);
    f.tester.settle(1);
    try t.expect(b.tuning and b.recalling);
    try t.expect(f.tester.hasText("Settings"));
    try t.expectEqual(app.sheet.Kind.tuning, app.sheet.current(b).?);
    try t.expect(app.sheet.closePanel(b));
    try t.expect(!b.tuning and b.recalling);
    try t.expect(app.sheet.closePanel(b));
    try t.expect(app.sheet.current(b) == null);
    try t.expect(!app.sheet.closePanel(b));
}

test "Tabs page sidebar switch flips layout" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    try expectHole(&f, .{ .x = 0, .y = 52, .w = 1440, .h = 848 });
    app.settings.open(f.browser, .tabs);
    f.tester.settle(1);
    try clickControl(&f, .switch_toggle, "Tabs in a sidebar");
    try t.expect(f.kea.prefs.sidebar);
    _ = app.sheet.closePanel(f.browser);
    f.tester.settle(2);
    try expectHole(&f, .{ .x = 232, .y = 8, .w = 1200, .h = 884 });
}

fn expectHole(f: *Fixture, want: ui.Rect) !void {
    const h = f.holes()[0];
    try t.expectApproxEqAbs(want.x, h.x, 0.01);
    try t.expectApproxEqAbs(want.y, h.y, 0.01);
    try t.expectApproxEqAbs(want.w, h.w, 0.01);
    try t.expectApproxEqAbs(want.h, h.h, 0.01);
}

/// A key pressed with ⌥⌘ held, as the key monitor would hand it over.
fn keyDown(chars: []const u8, code: u16, flags: u64) objc.Object {
    return objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{ .x = 0, .y = 0 }, @as(objc.NSUInteger, flags), @as(f64, 0), @as(objc.NSInteger, 0),
        @as(?objc.Object, null), objc.nsString(chars), objc.nsString(chars), false, code,
    });
}

test "shortcut override persists as diff" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    const store = &f.kea.shortcuts;
    app.settings.open(b, .shortcuts);
    f.tester.settle(1);
    // New Tab's key, clicked: it listens.
    try clickControl(&f, .button, "⌘T");
    try t.expect(store.recording);
    try t.expect(f.tester.hasText("Type a shortcut"));
    const pool = objc.Pool.push();
    defer pool.pop();
    const flag = app.shortcuts.flag;
    try t.expect(app.settings_shortcuts.take(&b.settings.shortcuts, keyDown("t", 17, flag.command | flag.option)) == null);
    try t.expect(!store.recording);
    const want = app.shortcuts.combo("t", .{ .option = true });
    try t.expect(store.effective("file.newTab").?.eql(want));

    const bytes = f.kea.store.data(app.shortcuts.defaults_key).?;
    defer f.kea.store.gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    const all = parsed.value.object;
    try t.expectEqual(@as(usize, 1), all.count());
    const key = all.get("file.newTab").?.object.get("key").?.object;
    try t.expectEqualStrings("t", key.get("key").?.string);
    try t.expect(key.get("command").?.bool and key.get("option").?.bool);
    try t.expect(!key.get("shift").?.bool and !key.get("control").?.bool);

    // Read back as a new run would, and reset: nothing is kept.
    store.reload();
    try t.expect(store.effective("file.newTab").?.eql(want));
    store.reset("file.newTab");
    try t.expect(f.kea.store.data(app.shortcuts.defaults_key) == null);
}

test "esc chain closes sheet before field" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    const tab = b.activeTab().?;
    tab.own(&tab.address, "https://www.example.com/a");
    b.edit();
    app.sheet.show(b, .tuning);
    f.tester.settle(1);
    try t.expect(b.editing and b.tuning);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(!b.tuning);
    try t.expect(b.editing);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(!b.editing);
}

test "welcome walks its pages and is seen once" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .welcome = true });
    defer f.deinit();
    const b = f.browser;
    try t.expect(b.welcoming);
    try t.expect(f.tester.hasText(app.kea.app_name));
    try clickControl(&f, .button, "Continue");
    f.tester.settle(1);
    try t.expect(f.tester.hasText("Bring things over."));
    try clickControl(&f, .button, "Skip");
    f.tester.settle(1);
    try t.expect(!b.welcoming and f.kea.prefs.welcomed);
    try t.expect(!f.tester.hasText("Bring things over."));
}

test "welcome features page toggles prefs" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .welcome = true });
    defer f.deinit();
    const b = f.browser;
    b.welcome.page = 3;
    f.tester.settle(2);
    try t.expect(f.tester.hasText("Make " ++ app.kea.app_name ++ " yours"));
    try clickControl(&f, .switch_toggle, "Spaces");
    try t.expect(b.prefs.uses_spaces);
    try clickControl(&f, .switch_toggle, "Split View");
    try t.expect(b.prefs.split_view);
    try clickControl(&f, .switch_toggle, "Bookmarks bar");
    try t.expect(b.prefs.bookmarks_bar);
}

test "Settings fields with a placeholder keep focus past the first key" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    app.settings.open(b, .general);
    f.tester.settle(1);
    // Site shortcuts › Add: the keyword field, typed into a key at a time.
    try clickControl(&f, .button, "Add");
    f.tester.settle(0.5);
    const word = f.tester.findText("yt") orelse return error.NoField;
    f.tester.click(word.x + 4, word.y + word.h / 2);
    for ("gh") |ch| f.tester.typeText(&.{ch});
    try t.expectEqualStrings("gh", b.settings.general.draft.?.word.text());
    // The custom engine's address, the same way.
    b.prefs.set("engine", @TypeOf(b.prefs.engine).custom);
    f.tester.settle(0.5);
    const at = f.tester.findText("https://example.com/search?q=%s") orelse return error.NoField;
    f.tester.click(at.x + 4, at.y + at.h / 2);
    for ("ht") |ch| f.tester.typeText(&.{ch});
    try t.expectEqualStrings("ht", b.prefs.custom_engine);
}

test "Welcome keeps keys off the hidden field" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .welcome = true });
    defer f.deinit();
    const b = f.browser;
    try t.expect(b.welcoming);
    f.tester.typeText("a");
    f.tester.frame();
    try t.expectEqual(@as(usize, 0), b.omni.typed.items.len);
    f.tester.key(.enter);
    f.tester.frame();
    try t.expectEqual(@as(u32, 0), b.refusals);
}
