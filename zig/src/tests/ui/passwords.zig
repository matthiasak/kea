//! P10: the account list hanging 6 pt under the sign-in box and Esc taking
//! it down, the `keepAsking` bar's three answers, Settings › Passwords'
//! rows, and ⌥⌘L's Passwords panel.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

fn control(f: *Fixture, role: ui.A11yRole, label: []const u8) ?ui.Rect {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) return c.rects.get(item.id);
    return null;
}

fn offer(f: *Fixture) !void {
    const login = try (app.vault.Login{ .host = @constCast("example.com"), .user = @constCast("kea"), .password = @constCast("hunter2") }).clone(gpa);
    app.browser_passwords.offer(f.browser, .{ .login = login, .changed = false });
    f.tester.settle(1);
    try t.expect(f.tester.hasText("Save the password for kea on example.com?"));
}

fn click(f: *Fixture, label: []const u8) !void {
    const r = control(f, .button, label) orelse return error.NoControl;
    f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
}

test "keepAsking bar answers Save, Not now and Never here" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    try offer(&f);
    try click(&f, "Save");
    try t.expect(b.passwords.offering == null);
    try t.expectEqualStrings("Password saved for example.com", b.announcement.?);
    try offer(&f);
    try click(&f, "Not now");
    try t.expect(b.passwords.offering == null);
    try t.expect(!app.vault.Vault.of(f.kea).isNever("example.com"));
    try offer(&f);
    try click(&f, "Never here");
    try t.expect(b.passwords.offering == null);
    try t.expectEqualStrings("Never for example.com", b.announcement.?);
    try t.expect(app.vault.Vault.of(f.kea).isNever("example.com"));
    f.tester.settle(1);
    try t.expect(!f.tester.hasText("Save the password for kea on example.com?"));
}

test "account list anchors 6 pt under the box and esc closes it" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    const b = f.browser;
    const page = f.holes()[0];
    b.active_page_frame = page;
    const tab = b.activeTab().?;
    const logins = try gpa.alloc(app.vault.Login, 1);
    logins[0] = try (app.vault.Login{ .host = @constCast("example.com"), .user = @constCast("kea@example.com"), .password = @constCast("hunter2") }).clone(gpa);
    b.passwords.accounts.suggesting = .{ .tab = tab.id, .logins = logins, .passkeys = try gpa.alloc(app.passkeys.Offered, 0), .host = try gpa.dupe(u8, "example.com"), .clear = false, .shown = 0 };
    b.passwords.accounts.spot = .{ .x = 40, .y = 100, .w = 300, .h = 30 };
    f.tester.settle(1);
    const list = control(&f, .popover, "account_list") orelse return error.NoList;
    try t.expectApproxEqAbs(page.x + 40, list.x, 0.5);
    try t.expectApproxEqAbs(page.y + 100 + 30 + 6, list.y, 0.5);
    try t.expectApproxEqAbs(@as(f32, 300), list.w, 0.5);
    try t.expect(control(&f, .button, "kea@example.com") != null);
    try t.expect(f.tester.hasText("From your keychain"));
    // A narrow box: the list keeps its 240.
    try t.expectEqual(@as(f32, 240), app.accounts_view.width(120));
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(b.passwords.accounts.suggesting == null);
    f.tester.settle(1);
    try t.expect(control(&f, .popover, "account_list") == null);
}

test "account list arrow keys move highlight and return fills" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    const b = f.browser;
    b.active_page_frame = f.holes()[0];
    const tab = b.activeTab().?;
    if (tab.address) |old| b.gpa.free(old);
    tab.address = try b.gpa.dupe(u8, "https://example.com/");
    const logins = try gpa.alloc(app.vault.Login, 2);
    logins[0] = try (app.vault.Login{ .host = @constCast("example.com"), .user = @constCast("one@example.com"), .password = @constCast("p1") }).clone(gpa);
    logins[1] = try (app.vault.Login{ .host = @constCast("example.com"), .user = @constCast("two@example.com"), .password = @constCast("p2") }).clone(gpa);
    b.passwords.accounts.suggesting = .{ .tab = tab.id, .logins = logins, .passkeys = try gpa.alloc(app.passkeys.Offered, 0), .host = try gpa.dupe(u8, "example.com"), .clear = false, .shown = app.json.toUnix(app.json.now()) };
    b.passwords.accounts.spot = .{ .x = 40, .y = 100, .w = 300, .h = 30 };
    f.tester.settle(1);
    try t.expect(f.press("", 125, .{}));
    try t.expectEqual(@as(?usize, 0), b.passwords.accounts.selected);
    try t.expect(f.press("", 125, .{}));
    try t.expectEqual(@as(?usize, 1), b.passwords.accounts.selected);
    try t.expect(f.press("", 126, .{}));
    try t.expectEqual(@as(?usize, 0), b.passwords.accounts.selected);
    try t.expect(f.press("\r", 36, .{}));
    try t.expect(b.passwords.accounts.suggesting == null);
    try t.expectEqual(@as(?u64, tab.id), b.passwords.accounts.picked_into);
}

test "Settings Passwords page renders its rows" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    // In Swift's rail order: after Extensions, before Downloads.
    const pages = app.settings.pages;
    for (pages, 0..) |e, i| if (e.page == .passwords) {
        try t.expectEqual(app.settings.Page.extensions, pages[i - 1].page);
        try t.expectEqual(app.settings.Page.downloads, pages[i + 1].page);
    };
    app.settings.open(f.browser, .passwords);
    f.tester.settle(1);
    for ([_][]const u8{ "Your passwords", "Offer to save passwords", "Fill in sign-ins", "Offer passkeys" }) |line| {
        if (!f.tester.hasText(line)) {
            std.debug.print("missing line: {s}\n", .{line});
            return error.MissingLine;
        }
    }
    try t.expect(control(&f, .switch_toggle, "Offer to save passwords") != null);
}

test "cmd-option-L opens the Passwords panel and esc closes it" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    // kVK_ANSI_L = 37.
    try t.expect(f.press("l", 37, .{ .cmd = true, .alt = true }));
    f.tester.settle(1);
    try t.expect(b.managing);
    try t.expect(f.tester.hasText("No passwords tucked away yet. Sign in somewhere and say yes, or bring yours in below."));
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(!b.managing);
}

test "Apple Passwords extension enabled steps Kea's sign-in list aside" {
    var f: Fixture = undefined;
    try f.init(gpa, .{});
    defer f.deinit();
    const b = f.browser;
    const tab = b.activeTab().?;
    try t.expect(app.form_relay.fills(tab));
    const e = (try @import("ext_fixture.zig").controller(&f)) orelse return;
    try e.installed.append(e.gpa, .{
        .id = try e.gpa.dupe(u8, app.ext_controller.Extensions.apple_passwords_id),
        .name = try e.gpa.dupe(u8, "iCloud Passwords"),
        .version = try e.gpa.dupe(u8, "3.4.0"),
        .enabled = true,
        .fromStore = true,
        .permissions = try e.gpa.alloc([]const u8, 0),
    });
    try t.expect(e.usesApple());
    try t.expect(!app.form_relay.fills(tab));
    if (tab.address) |old| b.gpa.free(old);
    tab.address = try b.gpa.dupe(u8, "https://example.com/");
    const logins = try gpa.alloc(app.vault.Login, 1);
    logins[0] = try (app.vault.Login{ .host = @constCast("example.com"), .user = @constCast("kea@example.com"), .password = @constCast("hunter2") }).clone(gpa);
    b.passwords.accounts.suggesting = .{ .tab = tab.id, .logins = logins, .passkeys = try gpa.alloc(app.passkeys.Offered, 0), .host = try gpa.dupe(u8, "example.com"), .clear = false, .shown = 0 };
    app.form_relay.hang(tab, .{ .x = 40, .y = 100, .w = 300, .h = 30 }, true, false);
    try t.expect(b.passwords.accounts.suggesting == null);
}
