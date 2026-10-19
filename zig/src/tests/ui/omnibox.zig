//! P6: the address field (Omnibox.swift, Browser.swift "guessing" and "the
//! address field") and the address typed into the tab itself.
const std = @import("std");
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

fn start(f: *Fixture, tabs: usize) !void {
    try f.init(gpa, .{ .sidebar = false, .tabs = tabs });
    f.tester.settle(1);
}

/// What the focused field shows, and its selection (low, high).
fn focused(f: *Fixture) !struct { text: []const u8, lo: usize, hi: usize } {
    const ft = f.tester.ctx.focused_text orelse return error.NothingFocused;
    return .{ .text = ft.text, .lo = @min(ft.caret, ft.anchor), .hi = @max(ft.caret, ft.anchor) };
}

fn seedGitHub(f: *Fixture) void {
    f.kea.history.record("https://github.com/", "GitHub");
}

fn near(a: ui.Color, b: ui.Color) bool {
    return @abs(a.r - b.r) < 0.01 and @abs(a.g - b.g) < 0.01 and @abs(a.b - b.b) < 0.01 and @abs(a.a - b.a) < 0.01;
}

fn hasBackground(f: *Fixture, want: ui.Color) bool {
    for (f.tester.ctx.nodes.items) |n| if (n.style.background) |bg| if (near(bg, want)) return true;
    return false;
}

fn palette(f: *Fixture) *const app.palette.Palette {
    return app.palette.get(f.tester.ctx.theme.dark);
}

test "typing gi completes github.com selected" {
    var f: Fixture = undefined;
    try start(&f, 0);
    defer f.deinit();
    seedGitHub(&f);
    f.tester.typeText("gi");
    f.tester.settle(1);
    try t.expectEqualStrings("github.com", f.browser.omnibox.field.text());
    const s = try focused(&f);
    try t.expectEqualStrings("github.com", s.text);
    try t.expectEqual(@as(usize, 2), s.lo);
    try t.expectEqual(@as(usize, 10), s.hi);
}

test "down picks first row" {
    var f: Fixture = undefined;
    try start(&f, 0);
    defer f.deinit();
    seedGitHub(&f);
    f.tester.typeText("gi");
    f.tester.settle(1);
    try t.expect(!hasBackground(&f, palette(&f).sunset.alpha(0.12)));
    try t.expect(f.tester.shortcut(.{ .key = ui.Shortcut.down }));
    f.tester.settle(1);
    try t.expectEqual(@as(?usize, 0), f.browser.omni.picked);
    try t.expect(hasBackground(&f, palette(&f).sunset.alpha(0.12)));
}

test "return on picked row goes there" {
    var f: Fixture = undefined;
    try start(&f, 0);
    defer f.deinit();
    seedGitHub(&f);
    const blank = f.browser.activeTab().?;
    f.tester.typeText("gi");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down });
    f.tester.key(.enter);
    f.tester.settle(1);
    try t.expectEqualStrings("https://github.com/", blank.url());
    try t.expect(!f.browser.fieldShowing());
    try t.expectEqual(@as(usize, 0), f.browser.omni.typed.items.len);
}

test "cmd-K lists open tabs MRU and cmd release commits" {
    var f: Fixture = undefined;
    try start(&f, 3);
    defer f.deinit();
    const b = f.browser;
    const one = b.tabs.items[1];
    const two = b.tabs.items[2];
    const three = b.tabs.items[3];
    b.select(one);
    b.select(two);
    b.select(three);
    f.tester.settle(1);
    f.mods(.{ .cmd = true });
    try t.expect(f.press("k", 40, .{ .cmd = true }));
    try t.expect(b.summoning and b.editing);
    // The most recent first, never the one in front nor a blank one.
    try t.expectEqual(@as(usize, 2), b.omni.offers.len);
    try t.expectEqual(two.id, b.omni.offers[0].tab.?);
    try t.expectEqual(one.id, b.omni.offers[1].tab.?);
    try t.expectEqual(@as(?usize, 0), b.omni.picked);
    // ⌘K again with ⌘ held walks on; letting ⌘ go takes it.
    try t.expect(f.press("k", 40, .{ .cmd = true }));
    try t.expectEqual(@as(?usize, 1), b.omni.picked);
    f.mods(.{});
    try t.expectEqual(one.id, b.active_id);
    try t.expect(!b.editing and !b.summoning);
}

test "re space does not chip without exact name" {
    var f: Fixture = undefined;
    try start(&f, 0);
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("searches_sites", true);
    f.tester.typeText("re ");
    f.tester.settle(1);
    try t.expect(b.site_chip == null);
    try t.expectEqualStrings("Reddit", b.omni.site_offer.?.name);
    // Tab is what puts the site in the field.
    try t.expect(f.press("\t", 48, .{}));
    f.tester.settle(1);
    try t.expectEqualStrings("Reddit", b.site_chip.?.name);
    try t.expectEqual(@as(usize, 0), b.omni.typed.items.len);
    try t.expect(f.tester.hasText("Reddit"));
}

test "esc closes pick then field" {
    var f: Fixture = undefined;
    try start(&f, 0);
    defer f.deinit();
    const b = f.browser;
    seedGitHub(&f);
    _ = b.open("https://example.com/", .{ .foreground = true });
    f.tester.settle(1);
    try t.expect(!b.fieldShowing());
    try t.expect(f.press("l", 37, .{ .cmd = true }));
    f.tester.settle(1);
    try t.expect(b.editing);
    // ⌘L's address comes up selected whole.
    const s = try focused(&f);
    try t.expectEqualStrings("https://example.com/", s.text);
    try t.expectEqual(s.text.len, s.hi - s.lo);
    f.tester.typeText("gi");
    _ = f.tester.shortcut(.{ .key = ui.Shortcut.down });
    try t.expect(b.omni.picked != null);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(b.omni.picked == null);
    try t.expect(b.editing);
    try t.expect(f.press("\x1b", 53, .{}));
    try t.expect(!b.editing);
    f.tester.settle(1);
    try t.expect(!f.tester.hasText("Enter a web address"));
}

test "invalid address shakes and reddens" {
    var f: Fixture = undefined;
    try start(&f, 0);
    defer f.deinit();
    const b = f.browser;
    f.tester.typeText("   ");
    f.tester.key(.enter);
    try t.expectEqual(@as(u32, 1), b.refusals);
    f.tester.frame();
    try t.expect(b.omnibox.refused);
    try t.expectEqual(@as(u32, 1), b.omnibox.shakes);
    // Mid-shake the field is off its place; settled, its edge is red.
    f.tester.advance(0.1);
    var moved = false;
    for (f.tester.ctx.nodes.items) |n| if (@abs(n.rect.h - 50) < 0.5 and @abs(n.rect.w - 560) < 0.5) {
        moved = moved or @abs(n.rect.x - (1440 - 560) / 2) > 0.5;
    };
    try t.expect(moved);
    f.tester.settle(1);
    const red = palette(&f).red.alpha(0.35);
    const edged = for (f.tester.ctx.nodes.items) |n| {
        if (n.style.border) |e| if (near(e, red)) break true;
    } else false;
    try t.expect(edged);
}

test "blank tab shows field and kea fact" {
    var f: Fixture = undefined;
    try start(&f, 0);
    defer f.deinit();
    try t.expect(f.browser.activeTab().?.isBlank());
    try t.expect(f.browser.fieldShowing());
    try t.expect(f.tester.hasText("Enter a web address"));
    try t.expect(f.tester.hasText(app.kea_fact.fact()));
    // Typing puts the fact away.
    f.tester.typeText("x");
    f.tester.settle(1);
    try t.expect(!f.tester.hasText(app.kea_fact.fact()));
}

test "clicking the live tab edits its address in place" {
    var f: Fixture = undefined;
    try start(&f, 0);
    defer f.deinit();
    const b = f.browser;
    const page = b.open("https://example.com/a", .{ .foreground = true });
    f.tester.settle(2);
    const before = try pillRect(&f, page.id);
    f.tester.click(before.x + before.w / 2, before.y + before.h / 2);
    try t.expectEqual(@as(?u64, page.id), b.editing_tab);
    try t.expectEqualStrings("example.com/a", b.tab_draft.text());
    f.tester.settle(1);
    // The pill grows to the field's width, the address selected in it.
    try t.expectApproxEqAbs(@min(340, b.strip.room), (try pillRect(&f, page.id)).w, 0.5);
    const s = try focused(&f);
    try t.expectEqualStrings("example.com/a", s.text);
    try t.expectEqual(s.text.len, s.hi - s.lo);
    // Typed over and kept with Return.
    f.tester.typeText("example.org");
    f.tester.key(.enter);
    try t.expect(b.editing_tab == null);
    try t.expectEqualStrings("https://example.org", page.url());
}

fn pillRect(f: *Fixture, id: u64) !ui.Rect {
    for (f.browser.strip.seen.items) |s| if (s.id == id) return f.tester.ctx.rects.get(s.node) orelse error.NotLaidOut;
    return error.NotDrawn;
}
