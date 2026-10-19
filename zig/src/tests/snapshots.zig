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
};

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
