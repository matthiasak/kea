//! `zig build snapshots`: renders named chrome states to PNG files named
//! `<phase>-<state>-<light|dark>.png` in `$KEAZIG_SNAPSHOTS`
//! (default `$TMPDIR/keazig-snapshots`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Fixture = @import("ui/fixture.zig").Fixture;
const Options = @import("ui/fixture.zig").Options;

const State = struct {
    name: []const u8,
    opts: Options,
    /// Brings the fixture to the state before it is drawn.
    setup: ?*const fn (*Fixture) void = null,
    /// Lets go of what `setup` kept, before the fixture goes.
    teardown: ?*const fn (*Fixture) void = null,
};

const states = [_]State{
    .{ .name = "p0-default", .opts = .{} },
    .{ .name = "p3-cards", .opts = .{ .sidebar = true, .tabs = 3 } },
    .{ .name = "p3-strip", .opts = .{ .sidebar = false, .tabs = 3 } },
    .{ .name = "p4-strip-12-tabs", .opts = .{ .sidebar = false, .tabs = 11 } },
    .{ .name = "p4-column-pins-groups", .opts = .{ .sidebar = true, .tabs = 7 }, .setup = pinsAndGroups },
    .{ .name = "p6-site-card", .opts = .{ .sidebar = false, .tabs = 2 }, .setup = siteCard },
    .{ .name = "p6-omnibox-list", .opts = .{ .sidebar = false, .tabs = 2 }, .setup = omniboxList },
    .{ .name = "p6-site-chip", .opts = .{ .sidebar = false, .tabs = 2 }, .setup = siteChip },
    .{ .name = "p8-side-panel", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = sidePanel },
    .{ .name = "p7-split", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = splitPair },
    .{ .name = "p7-peek", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = peekOpen },
    .{ .name = "p7-switcher", .opts = .{ .sidebar = true, .tabs = 7 }, .setup = switcherUp },
    .{ .name = "p8-settings-general", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = settingsOn(.general) },
    .{ .name = "p8-settings-tabs", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = settingsOn(.tabs) },
    .{ .name = "p8-settings-shortcuts", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = settingsOn(.shortcuts) },
    .{ .name = "p8-settings-downloads", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = settingsOn(.downloads) },
    .{ .name = "p8-settings-privacy", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = settingsOn(.privacy) },
    .{ .name = "p8-settings-ai", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = settingsOn(.ai) },
    .{ .name = "p8-settings-about", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = settingsOn(.about) },
    .{ .name = "p8-welcome", .opts = .{ .sidebar = true, .welcome = true } },
    .{ .name = "p8-history", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = @import("snapshots_recall.zig").history },
    .{ .name = "p8-downloads", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = @import("snapshots_recall.zig").downloads },
    .{ .name = "p8-find", .opts = .{ .sidebar = false, .tabs = 2 }, .setup = @import("snapshots_recall.zig").find },
    .{ .name = "p8-bars", .opts = .{ .sidebar = false, .tabs = 2 }, .setup = @import("snapshots_recall.zig").bars },
    .{ .name = "p8-bookmarks-manager", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = @import("snapshots_bookmarks.zig").manager },
    .{ .name = "p9-markdown", .opts = .{ .width = 560, .height = 860 }, .setup = @import("snapshots_markdown.zig").markdown, .teardown = @import("snapshots_markdown.zig").done },
    .{ .name = "p9-mermaid", .opts = .{ .width = 560, .height = 860 }, .setup = @import("snapshots_markdown.zig").mermaid, .teardown = @import("snapshots_markdown.zig").done },
    .{ .name = "p8-bookmarks-bar", .opts = .{ .sidebar = false, .tabs = 2 }, .setup = @import("snapshots_bookmarks.zig").bar },
    .{ .name = "p9-organize", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = @import("snapshots_bookmarks.zig").organize },
    .{ .name = "p9-chat", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = @import("snapshots_chat.zig").chat },
    .{ .name = "p12-sync-settings", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = syncSettings },
    .{ .name = "p10-passwords", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = @import("snapshots_passwords.zig").panel },
    .{ .name = "p10-keep-asking", .opts = .{ .sidebar = false, .tabs = 2 }, .setup = @import("snapshots_passwords.zig").keepAsking },
    .{ .name = "p10-settings-passwords", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = settingsOn(.passwords) },
    .{ .name = "p11-import", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = @import("snapshots_import.zig").sheet },
};

/// Settings open on `page`.
fn settingsOn(comptime page: @import("kea").settings.Page) *const fn (*Fixture) void {
    return struct {
        fn setup(f: *Fixture) void {
            @import("kea").settings.open(f.browser, page);
        }
    }.setup;
}

/// Settings › Sync with a folder chosen, waiting for the passphrase. A
/// fixed name and folder (only the path is kept; nothing is written), so
/// every run draws the same.
fn syncSettings(f: *Fixture) void {
    const s = &f.kea.sync;
    const name = s.gpa.dupe(u8, "Kea A") catch return;
    s.gpa.free(s.name);
    s.name = name;
    s.chooseFolder("/Volumes/Shared/Kea Sync");
    @import("kea").settings.open(f.browser, .sync);
}

/// Split View on: the two opened tabs a pair, the right with the keys.
fn splitPair(f: *Fixture) void {
    const b = f.browser;
    b.prefs.set("split_view", true);
    b.select(b.tabs.items[1]);
    b.pair(b.tabs.items[2], b.tabs.items[1], false);
}

/// A page in front, and a link of it peeked at over it.
fn peekOpen(f: *Fixture) void {
    const b = f.browser;
    b.select(b.tabs.items[1]);
    b.peek("https://www.example.com/", b.activeTab().?);
}

/// ⌃Tab held: the switcher's eight cards, the tab left last picked.
fn switcherUp(f: *Fixture) void {
    f.browser.select(f.browser.tabs.items[1]);
    _ = f.press("\t", 48, .{ .ctrl = true });
    f.tester.advance(0.2);
}

/// The bookmarks' column, on the side away from the tabs, with two kept.
fn sidePanel(f: *Fixture) void {
    _ = f.kea.bookmarks.add("https://ziglang.org/", "Zig");
    _ = f.kea.bookmarks.add("https://www.example.com/", "Example Domain");
    f.kea.prefs.set("bookmarks_sidebar", true);
}

/// Three squares, a group of two named "Reading", three loose rows.
fn pinsAndGroups(f: *Fixture) void {
    const b = f.browser;
    b.prefs.set("uses_tab_groups", true);
    // Pinning moves each to the head: pinned from a copy of the row.
    var row: [8]*@import("kea").Tab = undefined;
    @memcpy(row[0..b.tabs.items.len], b.tabs.items);
    for (row[1..4]) |t| b.pin(t, false);
    var loose: [8]*@import("kea").Tab = undefined;
    var n: usize = 0;
    for (b.tabs.items) |t| if (t.pin == null) {
        loose[n] = t;
        n += 1;
    };
    const id = b.addTabGroup(loose[n - 1]);
    b.moveToGroup(loose[n - 2], id);
    b.renameTabGroup(id, "Reading");
    b.editing_group_id = null;
}

/// The tab in front on an https page, its address edited: the card under it.
fn siteCard(f: *Fixture) void {
    const b = f.browser;
    const t = b.activeTab().?;
    t.own(&t.address, "https://www.example.com/");
    b.beginTabEdit(t);
}

/// "gi" typed on the blank tab, with places to complete it toward.
fn omniboxList(f: *Fixture) void {
    f.kea.history.record("https://github.com/", "GitHub");
    f.kea.history.record("https://gist.github.com/", "Gists");
    f.browser.setTyped("gi");
}

/// "red", Tab, then "kea": Reddit's search in the field.
fn siteChip(f: *Fixture) void {
    const b = f.browser;
    b.prefs.set("searches_sites", true);
    b.setTyped("red");
    _ = b.lockSiteOffer();
    b.setTyped("kea");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const dir = if (init.environ_map.get("KEAZIG_SNAPSHOTS")) |d| try gpa.dupe(u8, d) else blk: {
        const tmp = std.mem.trimEnd(u8, init.environ_map.get("TMPDIR") orelse "/tmp", "/");
        break :blk try std.fmt.allocPrint(gpa, "{s}/keazig-snapshots", .{tmp});
    };
    defer gpa.free(dir);
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        _ = objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
            objc.nsString(dir), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
        });
    }
    for (states) |s| {
        for ([_]bool{ false, true }) |dark| {
            var opts = s.opts;
            opts.dark = dark;
            var f: Fixture = undefined;
            try f.init(gpa, opts);
            defer f.deinit();
            defer if (s.teardown) |down| down(&f);
            if (s.setup) |setup| setup(&f);
            f.tester.settle(2);
            // The window's ground, which the hosted window paints behind the view.
            if (f.browser.applied_ground) |g| f.tester.theme.background = g;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ dir, s.name, if (dark) "dark" else "light" });
            defer gpa.free(path);
            try f.tester.screenshot(path);
            std.debug.print("snapshot {s}\n", .{path});
        }
    }
}
