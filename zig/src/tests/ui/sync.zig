//! P12: Settings › Sync taking two headless Macs from off to in step through
//! one folder, and pages going between them — Send to Device out of one,
//! History › Tabs from Other Macs in the other.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;
const Sync = @FieldType(app.Kea, "sync");

fn control(f: *Fixture, role: ui.A11yRole, label: []const u8) ?ui.Rect {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) return c.rects.get(item.id);
    return null;
}

fn clickControl(f: *Fixture, role: ui.A11yRole, label: []const u8) !void {
    const r = control(f, role, label) orelse return error.NoControl;
    f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
}

/// Both fixtures share the computer's name: each Mac named apart.
fn rename(s: *Sync, name: []const u8) !void {
    const copy = try s.gpa.dupe(u8, name);
    s.gpa.free(s.name);
    s.name = copy;
}

fn find(items: []const nanoui.MenuItem, label: []const u8) ?nanoui.MenuItem {
    for (items) |it| if (!it.is_separator and std.mem.eql(u8, it.label, label)) return it;
    return null;
}

fn fire(item: nanoui.MenuItem) void {
    const click = item.click.?;
    var unused: nanoui.menu.Item = undefined;
    click.func(click.ctx, &unused);
}

/// Mac A's Settings › Sync, taken from off to a folder and a passphrase;
/// Mac B joined with the same passphrase. Returns the shared folder (on gpa).
fn joinBoth(a: *Fixture, b: *Fixture) ![]u8 {
    const shared = try std.fmt.allocPrint(gpa, "{s}/shared", .{a.temp.folder});
    errdefer gpa.free(shared);
    app.disk.makePath(gpa, shared);
    try rename(&a.kea.sync, "Kea A");
    try rename(&b.kea.sync, "Kea B");

    app.settings.open(a.browser, .sync);
    a.tester.settle(1);
    try t.expectEqual(app.settings.Page.sync, a.browser.settings.page.?);
    // Off: only how, the status, what goes and who.
    try t.expect(a.tester.hasText("Sync through"));
    try t.expectEqualStrings("Off", a.kea.sync.status);
    try t.expect(!a.tester.hasText("Passphrase"));
    try t.expect(a.tester.hasText("Pins and spaces"));
    try t.expect(a.tester.hasText("None yet"));
    try t.expect(a.tester.hasText("Kea A"));

    try clickControl(a, .radio_button, "Folder");
    a.tester.settle(1);
    try t.expectEqual(.folder, a.kea.sync.place);
    try t.expect(a.tester.hasText("None chosen"));
    // What the open panel hands back (it never shows in a test run).
    a.kea.sync.chooseFolder(shared);
    a.tester.frame();
    try t.expect(a.tester.hasText("Type the passphrase"));
    try t.expect(a.tester.containsText("/shared"));

    // The passphrase typed and Return: in step, the field emptied.
    try clickControl(a, .text_field, "Passphrase");
    a.tester.typeText("correct horse");
    // VoiceOver never reads the secret out.
    for (a.tester.ctx.a11y_items.items) |item| if (item.role == .text_field and std.mem.eql(u8, item.label, "Passphrase"))
        try t.expectEqualStrings("", item.value);
    // Return in a focused field arrives as `insertNewline:`.
    a.tester.textOps(&.{.{ .command = .insert_newline }});
    try t.expect(a.kea.sync.ready);
    try t.expect(std.mem.startsWith(u8, a.kea.sync.status, "Synced"));
    try t.expectEqualStrings("", a.browser.settings.sync.passphrase.text());
    try t.expect(a.tester.containsText("Synced"));

    b.kea.sync.chooseFolder(shared);
    try t.expect(b.kea.sync.use("correct horse", null) == null);
    try t.expect(b.kea.sync.ready);
    return shared;
}

test "sync page turns on with a folder and lists the other Mac" {
    var a: Fixture = undefined;
    try a.init(gpa, .{ .sidebar = true });
    defer a.deinit();
    var b: Fixture = undefined;
    try b.init(gpa, .{ .sidebar = true });
    defer b.deinit();
    const shared = try joinBoth(&a, &b);
    defer gpa.free(shared);

    // A hears from B on its next round.
    a.kea.sync.syncNow();
    a.tester.frame();
    try t.expectEqual(@as(usize, 1), a.kea.sync.devices.len);
    try t.expect(a.tester.containsText("Kea B · "));
    try t.expect(!a.tester.hasText("None yet"));
    // A switch flipped (the first, in view) changes what goes across.
    try clickControl(&a, .switch_toggle, "Bookmarks");
    try t.expect(!a.kea.sync.kinds.contains(.bookmarks) and a.kea.sync.kinds.contains(.history));
    // Back to off.
    try clickControl(&a, .radio_button, "Off");
    a.tester.settle(1);
    try t.expectEqualStrings("Off", a.kea.sync.status);
    try t.expect(!a.tester.hasText("Passphrase"));
}

test "send to device reaches the other Mac and its tabs show in History" {
    var a: Fixture = undefined;
    try a.init(gpa, .{ .sidebar = true });
    defer a.deinit();
    var b: Fixture = undefined;
    try b.init(gpa, .{ .sidebar = true });
    defer b.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();

    const page = a.browser.open("https://kea.example/flight", .{ .foreground = true });
    page.setTitle("Kea flight");
    // Not set up: the way to Settings.
    var send = try app.sync_send.menu(ar, a.browser, page);
    try t.expect(!send.disabled);
    try t.expect(find(send.submenu.?, "Set Up Sync…") != null);
    try t.expect(find(send.submenu.?, "Share…") != null);
    // A blank page has nothing to send.
    try t.expect((try app.sync_send.menu(ar, a.browser, a.browser.tabs.items[0])).disabled);

    const shared = try joinBoth(&a, &b);
    defer gpa.free(shared);
    send = try app.sync_send.menu(ar, a.browser, page);
    try t.expect(find(send.submenu.?, "No Other Macs Yet").?.disabled);

    a.kea.sync.syncNow();
    // Tabs › Send to Device, and the tab's own menu, both list B.
    const tabs_menu = try app.menus.items(ar, a.kea, a.browser, .tabs);
    send = find(tabs_menu, "Send to Device").?;
    const to_b = find(send.submenu.?, "Kea B").?;
    const own = try app.tab_menu.items(ar, a.browser, page);
    try t.expect(find(find(own, "Send to Device").?.submenu.?, "Kea B") != null);
    fire(to_b);
    try t.expectEqualStrings("Sent to Kea B", a.browser.announcement.?);

    // B's next round opens it behind, and says where from.
    b.kea.sync.syncNow();
    var landed = false;
    for (b.browser.tabs.items) |tab| landed = landed or std.mem.eql(u8, tab.url(), "https://kea.example/flight");
    try t.expect(landed);
    try t.expectEqualStrings("From Kea A: Kea flight", b.browser.announcement.?);
    // History › Tabs from Other Macs: each Mac's open pages, A's on B, B's on A.
    b.kea.sync.syncNow();
    a.kea.sync.syncNow();
    for ([_]*Fixture{ &b, &a }, [_][]const u8{ "Kea A", "Kea B" }) |f, other| {
        const history = try app.menus.items(ar, f.kea, f.browser, .history);
        try t.expect(find(history, "Tabs from Other Macs").?.disabled);
        const mac = find(history, other).?;
        try t.expect(mac.on_open != null);
        const id = for (f.kea.sync.devices) |d| (if (std.mem.eql(u8, d.name, other)) break d.id) else return error.NoDevice;
        const pages = try app.sync_send.pages(ar, f.browser, id);
        try t.expect(find(pages, "Kea flight") != null or find(pages, "https://kea.example/flight") != null);
        try t.expect(find(pages, "Open All") != null);
    }
    // Opening one from the list: in front, here.
    const before = a.browser.tabs.items.len;
    const pages = try app.sync_send.pages(ar, a.browser, a.kea.sync.devices[0].id);
    fire(pages[0]);
    try t.expectEqual(before + 1, a.browser.tabs.items.len);
}
