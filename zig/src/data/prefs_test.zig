//! Prefs against Prefs.swift's `init` (398-526): every default on an empty
//! suite, the legacy migrations, and write-through.
const std = @import("std");
const prefs = @import("prefs.zig");
const Prefs = prefs.Prefs;
const Store = @import("store.zig").Store;
const Temp = @import("../tests/temp.zig").Temp;
const testing = std.testing;

/// Defaults key, Zig field, Swift's default on an empty suite.
const swift_defaults = .{
    .{ "toolbar.left", "navigation_left", false },
    .{ "look", "look", prefs.Look.system },
    .{ "sidebar", "sidebar", false },
    .{ "sidebar.position", "side_position", prefs.SidePosition.left },
    .{ "sidebar.hides", "side_hides", false },
    .{ "sidebar.width", "side_width", @as(f32, 232) },
    .{ "ai.width", "chat_width", @as(f32, 380) },
    .{ "bookmarks.width", "marks_width", @as(f32, 232) },
    .{ "glyph", "glyph", prefs.Glyph.letters },
    .{ "search.engine", "engine", prefs.Engine.google },
    .{ "search.custom", "custom_engine", "" },
    .{ "tabs.sleep", "sleeps_tabs", true },
    .{ "tabs.lazy", "lazy_tabs", true },
    .{ "start.fresh", "starts_fresh", false },
    .{ "search.sites", "searches_sites", false },
    .{ "notifications.ask", "site_notifications", true },
    .{ "tabs.reading", "shows_reading", true },
    .{ "shield", "shielded", true },
    .{ "sites.keep", "keeps_sign_ins", false },
    .{ "extensions.private", "extensions_in_private", false },
    .{ "passkeys", "passkeys", false }, // unentitled test binary
    .{ "downloads.ask", "asks_where_to_save", false },
    .{ "passwords.save", "saves_passwords", true },
    .{ "passwords.fill", "fills_passwords", true },
    .{ "welcomed", "welcomed", false },
    .{ "spaces", "uses_spaces", false },
    .{ "tabs.groups", "uses_tab_groups", false },
    .{ "pins.list", "lists_pins", false },
    .{ "splitView", "split_view", false },
    .{ "ai", "ai", true },
    .{ "ai.server", "ai_server", "http://127.0.0.1:8080/v1/" },
    .{ "commandbar", "command_bar", false },
    .{ "swipe.history", "holds_history", false },
    .{ "float.flicks", "float_flicks", true },
    .{ "kea.facts", "kea_facts", true },
    .{ "float.away", "floats_away", false },
    .{ "float.leave", "floats_on_leave", true },
    .{ "media.click", "waits_for_play", false },
    .{ "links.peek", "peeks_links", true },
    .{ "links.little", "little_links", false },
    .{ "bookmarks.bar", "bookmarks_bar", false },
    .{ "bookmarks.sidebar", "bookmarks_sidebar", false },
    .{ "ai.zoom", "chat_zoom", @as(f64, 1) },
    .{ "ai.popped", "chat_popped", false },
    .{ "bookmarks.popped", "marks_popped", false },
    .{ "handoff", "handoff", true },
    .{ "downloads.button", "always_shows_downloads", false },
    .{ "links.show", "shows_links", true },
    .{ "autoscroll", "auto_scroll", false },
    .{ "pages.120", "fast_pages", false },
    .{ "pageZoom", "page_zoom", @as(f64, 1) },
    .{ "reader.theme", "reader_theme", prefs.ReaderTheme.auto },
    .{ "reader.size", "reader_size", @as(f64, 18) },
    .{ "reader.width", "reader_width", prefs.ReaderWidth.medium },
};

fn expectPref(want: anytype, got: anytype) !void {
    if (@TypeOf(got) == []u8) return testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(@TypeOf(got), want), got);
}

test "prefs defaults match Swift" {
    const gpa = testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    var p = Prefs.init(gpa, &store, .{ .testing = true });
    defer p.deinit();
    inline for (swift_defaults) |row| {
        try testing.expectEqualStrings(row[0], @field(prefs.keys, row[1]));
        expectPref(row[2], @field(p, row[1])) catch |e| {
            std.debug.print("pref {s} ({s}) off its Swift default\n", .{ row[0], row[1] });
            return e;
        };
    }
    try testing.expect(p.chat_side == null);
    try testing.expect(p.marks_side == null);
    try testing.expect(p.ai_provider == null);
    try testing.expectEqual(@as(usize, 0), p.ai_models.count());
    try testing.expectEqual(@as(usize, 0), p.keywords.len);
    try testing.expect(!p.passkeys_possible);
    // A test run downloads into its own folder.
    const dl = try t.path(gpa, "Downloads");
    defer gpa.free(dl);
    try testing.expectEqualStrings(dl, p.downloads);
    // As the Mac has it, and told to WebKit through the suite.
    try testing.expectEqual(p.autocorrect, store.bool("WebAutomaticSpellingCorrectionEnabled").?);
    try testing.expectEqual(false, store.bool("passkeys.entitled").?);
    // Every written key is in the table, and nothing else is set by default.
    try testing.expectEqual(@typeInfo(@TypeOf(prefs.keys)).@"struct".field_names.len, swift_defaults.len + 5);
}

test "prefs legacy migrations" {
    const gpa = testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    store.setString("manner", "side");
    store.setString("glyph", "icons");
    store.setBool("inspector", true);
    store.setString("mind.model", "x");
    store.setBool("mind.open", true);
    store.setDouble("sidebar.width", 9999);
    store.setDouble("ai.width", 10);
    store.setDouble("ai.zoom", 7);
    store.setString("look", "bogus");
    var p = Prefs.init(gpa, &store, .{ .testing = true });
    defer p.deinit();
    try testing.expect(p.sidebar);
    try testing.expect(p.welcomed);
    try testing.expectEqual(prefs.Glyph.icons, p.glyph);
    try testing.expectEqual(prefs.Look.system, p.look);
    try testing.expect(!store.hasKey("inspector"));
    try testing.expect(!store.hasKey("mind.model"));
    try testing.expect(!store.hasKey("mind.open"));
    try testing.expectEqual(@as(f32, 440), p.side_width);
    try testing.expectEqual(@as(f32, 300), p.chat_width);
    try testing.expectEqual(@as(f64, 2), p.chat_zoom);
    // An explicit sidebar beats the old manner.
    store.setBool("sidebar", false);
    var q = Prefs.init(gpa, &store, .{ .testing = true });
    defer q.deinit();
    try testing.expect(!q.sidebar);
}

test "prefs setters write through" {
    const gpa = testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    var p = Prefs.init(gpa, &store, .{ .testing = true });
    defer p.deinit();
    p.set("look", .dark);
    p.set("sidebar", true);
    p.set("side_width", 300);
    p.set("chat_side", .left);
    p.set("custom_engine", "https://e.example/?q=%s");
    p.set("ai_provider", "anthropic");
    p.set("autocorrect", !p.autocorrect);
    p.set("reader_theme", .sepia);
    p.set("reader_size", 22);
    p.set("reader_width", .wide);
    p.setChatZoom(1.26);
    p.setAIModel("claude-x", "anthropic");
    p.setAIModel("sk-secret", "openAI");
    p.setAIModel("two words", "openAI");
    const kw = [_]prefs.Keyword{.{ .id = @import("json.zig").Uuid.random(), .keyword = "yt", .template = "https://www.youtube.com/results?search_query=%s" }};
    p.setKeywords(&kw);
    try testing.expectEqualStrings("yt", p.keywords[0].keyword);
    var q = Prefs.init(gpa, &store, .{ .testing = true });
    defer q.deinit();
    try testing.expectEqual(prefs.Look.dark, q.look);
    try testing.expect(q.sidebar);
    try testing.expectEqual(@as(f32, 300), q.side_width);
    try testing.expectEqual(prefs.SidePosition.left, q.chat_side.?);
    try testing.expectEqualStrings("https://e.example/?q=%s", q.custom_engine);
    try testing.expectEqualStrings("anthropic", q.ai_provider.?);
    try testing.expectEqual(p.autocorrect, q.autocorrect);
    try testing.expectEqual(p.autocorrect, store.bool("WebAutomaticSpellingCorrectionEnabled").?);
    try testing.expectEqual(@as(f64, 1.3), q.chat_zoom);
    try testing.expectEqual(prefs.ReaderTheme.sepia, q.reader_theme);
    try testing.expectEqual(@as(f64, 22), q.reader_size);
    try testing.expectEqual(prefs.ReaderWidth.wide, q.reader_width);
    try testing.expectEqualStrings("claude-x", q.aiModel("anthropic", "s"));
    try testing.expectEqualStrings("s", q.aiModel("openAI", "s"));
    try testing.expectEqual(@as(usize, 1), q.keywords.len);
    try testing.expect(q.keywords[0].id.eql(kw[0].id));
    p.set("chat_side", null);
    p.set("ai_provider", null);
    try testing.expect(!store.hasKey("ai.side"));
    try testing.expect(!store.hasKey("ai.provider"));
}
