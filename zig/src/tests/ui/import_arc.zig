//! Arc's sidebar taken (P11, `Browser.takeArc`): spaces, pins, tabs asleep.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;
const Uuid = app.json.Uuid;
const browser_arc = app.browser_arc;
const arc = browser_arc.arc;

test "Arc's sidebar comes in once: spaces, pins, folders as groups" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{});
    defer f.deinit();
    const b = f.browser;
    b.prefs.set("lists_pins", true);

    // A folder inside a folder files under the top one; a page listed twice comes once.
    var deep = [_]arc.Node{
        .{ .item = .{ .title = "E", .url = "https://e.example/" } },
        .{ .item = .{ .title = "B again", .url = "https://b.example/x" } },
    };
    var reading = [_]arc.Node{
        .{ .item = .{ .title = "B", .url = "https://b.example/x" } },
        .{ .folder = .{ .title = "Deep", .items = &deep } },
    };
    var personal = [_]arc.Node{
        .{ .item = .{ .title = "A", .url = "https://a.example/" } },
        .{ .folder = .{ .title = "Reading", .items = &reading } },
    };
    var docs = [_]arc.Node{.{ .item = .{ .title = "D", .url = "https://d.example/" } }};
    var work = [_]arc.Node{
        .{ .item = .{ .title = "C", .url = "https://c.example/" } },
        .{ .folder = .{ .title = "Docs", .items = &docs } },
    };
    var spaces = [_]arc.Space{
        .{ .name = "PERSONAL", .emoji = null, .symbol = "house", .profile = "Default", .pinned = &personal },
        .{ .name = "Work", .emoji = null, .symbol = "briefcase", .profile = "Default", .pinned = &work },
    };
    var favorites = [_]arc.Item{.{ .title = "GitHub", .url = "https://www.github.com/" }};
    const sidebar: arc.Sidebar = .{ .favorites = &favorites, .favorites_by_profile = .empty, .spaces = &spaces };

    const taken = browser_arc.takeArc(b, sidebar, null, null);
    try t.expectEqual(browser_arc.ArcTaken{ .spaces = 1, .pins = 4, .tabs = 3 }, taken);
    try t.expect(b.prefs.uses_spaces);
    try t.expectEqual(@as(usize, 2), f.kea.spaces.value.len);
    const made = f.kea.spaces.value[1];
    try t.expectEqualStrings("Work", made.name);
    try t.expectEqualStrings("briefcase", made.icon.?);
    try t.expect(made.sharesSignIns == true);

    // The first space's pins: the favourite as a square, the loose page a row.
    const defs = f.kea.pins.defs(Uuid.first);
    try t.expectEqual(@as(usize, 2), defs.len);
    try t.expectEqualStrings("G", defs[0].letter);
    try t.expectEqualStrings("https://a.example/", defs[1].home);
    try t.expect(defs[1].listed == true);

    // On screen: the pins as tabs, and the folder's page asleep in its group.
    var pins: usize = 0;
    var filed: ?*app.Tab = null;
    var nested: ?*app.Tab = null;
    var twice: usize = 0;
    for (b.tabs.items) |tab| {
        pins += @intFromBool(tab.pin != null);
        if (std.mem.eql(u8, tab.url(), "https://b.example/x")) {
            filed = tab;
            twice += 1;
        }
        if (std.mem.eql(u8, tab.url(), "https://e.example/")) nested = tab;
    }
    try t.expectEqual(@as(usize, 2), pins);
    try t.expectEqual(@as(usize, 1), twice);
    const tab = filed orelse return error.TestUnexpectedResult;
    try t.expect(tab.pending != null and !tab.built);
    try t.expectEqual(@as(usize, 1), b.tab_groups.items.len);
    try t.expectEqualStrings("Reading", b.tab_groups.items[0].name);
    try t.expect(tab.group_id.?.eql(b.tab_groups.items[0].id));
    try t.expect(nested.?.group_id.?.eql(b.tab_groups.items[0].id));

    // Work, never brought up: its pins, and its saved row with its group.
    try t.expectEqual(@as(usize, 2), f.kea.pins.defs(made.id).len);
    const row = b.readRow(made.id);
    defer row.deinit();
    try t.expectEqual(@as(usize, 1), row.value.tabs.len);
    try t.expectEqualStrings("https://d.example/", row.value.tabs[0].url);
    try t.expectEqualStrings("Docs", row.value.groups.?[0].name);
    try t.expect(row.value.tabs[0].groupID.?.eql(row.value.groups.?[0].id));

    // Nothing twice.
    try t.expectEqual(browser_arc.ArcTaken{}, browser_arc.takeArc(b, sidebar, null, null));
    try t.expectEqual(@as(usize, 2), f.kea.spaces.value.len);
    try t.expectEqual(@as(usize, 2), f.kea.pins.defs(Uuid.first).len);

    // A site's pin answers wherever it has gone, never another path.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(try browser_arc.samePin(a, "https://mail.google.com", "https://mail.google.com/mail/u/0/"));
    try t.expect(try browser_arc.samePin(a, "https://www.GitHub.com/me", "https://github.com/me/repo"));
    try t.expect(!try browser_arc.samePin(a, "https://github.com/me", "https://github.com/media"));
    try t.expect(!try browser_arc.samePin(a, "http://localhost:3000/", "http://localhost:5173/"));
}
