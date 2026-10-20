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
    .{ .name = "p4-strip-icons", .opts = .{ .sidebar = false, .tabs = 3 }, .setup = stripIcons },
    .{ .name = "p4-column-pins-icons", .opts = .{ .sidebar = true, .tabs = 7 }, .setup = columnPinsIcons },
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
    .{ .name = "p13-extensions-settings", .opts = .{ .sidebar = true, .tabs = 2 }, .setup = @import("snapshots_ext.zig").settings },
    .{ .name = "p13-slot", .opts = .{ .sidebar = false, .tabs = 2 }, .setup = @import("snapshots_ext.zig").slot },
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

fn stripIcons(f: *Fixture) void {
    const seed = @import("ui/seed.zig");
    seed.seedIconFixtures(f.kea);
    f.browser.prefs.set("glyph", seed.Glyph.icons);
    var ubuf: [128]u8 = undefined;
    for (f.browser.tabs.items, 0..) |t, i| {
        const host = seed.icon_fixture_hosts[i % seed.icon_fixture_hosts.len];
        const u = std.fmt.bufPrint(&ubuf, "https://{s}/Tab%20{d}", .{ host, i + 1 }) catch continue;
        t.own(&t.address, u);
        if (i == 0) t.setTitle("Tab 1");
    }
}

fn columnPinsIcons(f: *Fixture) void {
    const seed = @import("ui/seed.zig");
    seed.seedIconFixtures(f.kea);
    f.browser.prefs.set("glyph", seed.Glyph.icons);
    var ubuf: [128]u8 = undefined;
    for (f.browser.tabs.items, 0..) |t, i| {
        const host = seed.icon_fixture_hosts[i % seed.icon_fixture_hosts.len];
        const u = std.fmt.bufPrint(&ubuf, "https://{s}/Tab%20{d}", .{ host, i + 1 }) catch continue;
        t.own(&t.address, u);
        if (i == 0) t.setTitle("Tab 1");
    }
    pinsAndGroups(f);
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

fn writeBytes(gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(z);
    const file = std.c.fopen(z, "wb") orelse return error.OpenFailed;
    defer _ = std.c.fclose(file);
    if (bytes.len > 0 and std.c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.WriteFailed;
}

const Sidecar = struct {
    pixels: [2]u32,
    points: [2]u32,
    cards: bool,
    holes: []const nanoui.ui.Rect,
    card: ?nanoui.ui.Rect = null,
    icons: []const nanoui.ui.Rect = &.{},
};

const RefLights = struct {
    hidden: bool = false,
    x: i64 = 0,
};

const RefFilmFrame = struct {
    lights: ?RefLights = null,
};

const RefFilmJson = struct {
    t: []const i64 = &.{},
    frames: []const RefFilmFrame = &.{},
};

const FilmJson = struct {
    action: []const u8 = "",
    look: []const u8 = "",
    t: []const i64 = &.{},
    frames: []const FilmFrame = &.{},
};

const FilmFrame = struct {
    t: i64 = 0,
    file: ?[]const u8 = null,
    edge_x: f32 = 0,
};

fn columnEdgePt(f: *Fixture) f32 {
    const side_id = std.hash.Wyhash.hash(0, "side-bar");
    const peek_id = std.hash.Wyhash.hash(0, "kea.peek.sheet");
    if (f.tester.ctx.rects.get(side_id)) |r| return @round(@max(0, r.x + r.w));
    if (f.tester.ctx.rects.get(peek_id)) |r| return @round(@max(0, r.x + r.w));
    const w = f.browser.prefs.side_width;
    const h = f.tester.size.h;
    for (f.tester.ctx.nodes.items) |n| {
        if (n.style.absolute and @abs(n.rect.w - w) < 0.5 and @abs(n.rect.h - h) < 0.5) {
            return @round(@max(0, n.rect.x + n.rect.w));
        }
    }
    return 0;
}

fn glideProgress(t: f64) f64 {
    if (t <= 0) return 0;
    const g = @import("kea").motion.glide;
    const resp: f64 = g.response;
    const zeta: f64 = g.damping;
    const w = 2.0 * std.math.pi / resp;
    const s = @sqrt(1.0 - zeta * zeta);
    const wd = w * s;
    return 1.0 - @exp(-zeta * w * t) * (@cos(wd * t) + (zeta / s) * @sin(wd * t));
}

fn refEdgeAt(action: []const u8, idx: usize, rf: []const RefFilmFrame) ?f32 {
    if (idx >= rf.len) return null;
    const l = rf[idx].lights orelse return null;
    if (std.mem.eql(u8, action, "peek")) {
        return if (idx == 0 or l.hidden) 0 else @max(0, 232.0 + @as(f32, @floatFromInt(l.x)));
    }
    return if (l.hidden) 0 else @max(0, 232.0 + @as(f32, @floatFromInt(l.x)));
}
fn runFilm(gpa: std.mem.Allocator, out_dir: []const u8, ref_dir: []const u8, scale: ?f32) !void {
    const actions = [_][]const u8{ "peek", "unpeek", "fold" };
    var default_ts: [30]i64 = undefined;
    for (&default_ts, 0..) |*v, idx| v.* = @intCast(idx * 20);

    for ([_]bool{ false, true }) |dark| {
        const look = if (dark) "dark" else "light";
        var opts: Options = .{ .sidebar = true, .tabs = 3, .dark = dark };
        if (scale) |sc| opts.scale = sc;
        var f: Fixture = undefined;
        try f.init(gpa, opts);
        defer f.deinit();

        // Start folded and settled before peek -> unpeek -> fold.
        f.browser.folded = true;
        f.browser.peeking = false;
        f.tester.settle(2);

        for (actions) |action| {
            if (std.mem.eql(u8, action, "fold")) {
                f.browser.folded = false;
                f.browser.peeking = false;
                f.tester.settle(2);
            }

            const ref_json_path = try std.fmt.allocPrint(gpa, "{s}/film-{s}-{s}.json", .{ ref_dir, action, look });
            defer gpa.free(ref_json_path);
            const ref_bytes = @import("kea").disk.read(gpa, ref_json_path);
            defer if (ref_bytes) |b| gpa.free(b);
            const parsed = if (ref_bytes) |b| (@import("kea").json.decode(RefFilmJson, gpa, b) catch null) else null;
            defer if (parsed) |p| p.deinit();
            const ts: []const i64 = if (parsed) |p| blk: {
                if (p.value.t.len > 0) break :blk p.value.t;
                std.debug.print("film {s}-{s}: empty t in {s}, using defaults\n", .{ action, look, ref_json_path });
                break :blk &default_ts;
            } else blk: {
                std.debug.print("film {s}-{s}: no ref sidecar at {s}, using defaults\n", .{ action, look, ref_json_path });
                break :blk &default_ts;
            };

            var frames: std.ArrayList(FilmFrame) = .empty;
            defer {
                for (frames.items) |fr| if (fr.file) |fp| gpa.free(fp);
                frames.deinit(gpa);
            }

            const rf: []const RefFilmFrame = if (parsed) |p| p.value.frames else &.{};
            var off_ms: f64 = 0;
            if (ts.len >= 3) if (refEdgeAt(action, 1, rf)) |e1| {
                const frac1: f64 = if (std.mem.eql(u8, action, "peek")) e1 / 232.0 else 1.0 - (e1 / 232.0);
                var best_ms: f64 = 0;
                var best_err: f64 = 1e9;
                var ms: f64 = 0;
                while (ms <= 200.0) : (ms += 0.1) {
                    const err = @abs(glideProgress(ms / 1000.0) - frac1);
                    if (err < best_err) {
                        best_err = err;
                        best_ms = ms;
                    }
                }
                off_ms = best_ms - @as(f64, @floatFromInt(ts[2] - ts[1]));
            };

            var start_time = f.tester.time;
            const base_t: i64 = if (ts.len > 1) ts[1] else 0;
            for (ts, 0..) |cur_t, idx| {
                if (idx > 0) {
                    const next_t: i64 = if (idx + 1 < ts.len) ts[idx + 1] else cur_t + 20;
                    const dt_ref_ms: f64 = if (ts.len >= 3) @floatFromInt(next_t - base_t) else @floatFromInt(@max(0, cur_t));
                    const target_time = start_time + @max(0, (dt_ref_ms + off_ms) / 1000.0);
                    while (f.tester.time + 1e-6 < target_time) {
                        const rem: f32 = @floatCast(target_time - f.tester.time);
                        f.tester.dt = @min(1.0 / 240.0, rem);
                        f.tester.frame();
                    }
                    f.tester.dt = 1.0 / 60.0;
                }
                if (f.browser.applied_ground) |g| f.tester.theme.background = g;
                const edge_x = columnEdgePt(&f);
                const frame_path = try std.fmt.allocPrint(gpa, "{s}/film-{s}-{s}-{d:0>2}.png", .{ out_dir, action, look, idx });
                try f.tester.screenshot(frame_path);
                try frames.append(gpa, .{ .t = cur_t, .file = frame_path, .edge_x = edge_x });
                if (idx == 0) {
                    if (std.mem.eql(u8, action, "peek")) {
                        f.browser.peeking = true;
                    } else if (std.mem.eql(u8, action, "unpeek")) {
                        f.browser.peeking = false;
                    } else {
                        @import("kea").fold.toggleFold(f.browser);
                    }
                    f.tester.dt = 0;
                    f.tester.frame();
                    f.tester.dt = 1.0 / 60.0;
                    start_time = f.tester.time;
                }
            }
            const out_json = try @import("kea").json.encode(gpa, FilmJson{
                .action = action,
                .look = look,
                .t = ts,
                .frames = frames.items,
            });
            defer gpa.free(out_json);
            const json_path = try std.fmt.allocPrint(gpa, "{s}/film-{s}-{s}.json", .{ out_dir, action, look });
            defer gpa.free(json_path);
            try writeBytes(gpa, json_path, out_json);
            std.debug.print("film {s}\n", .{json_path});
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const dir = if (init.environ_map.get("KEAZIG_SNAPSHOTS")) |d| try gpa.dupe(u8, d) else blk: {
        const tmp = std.mem.trimEnd(u8, init.environ_map.get("TMPDIR") orelse "/tmp", "/");
        break :blk try std.fmt.allocPrint(gpa, "{s}/keazig-snapshots", .{tmp});
    };
    defer gpa.free(dir);
    const scale_override: ?f32 = if (init.environ_map.get("KEAZIG_SCALE")) |s| (std.fmt.parseFloat(f32, s) catch null) else null;
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        _ = objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
            objc.nsString(dir), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
        });
    }
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "film")) {
        const ref_dir = if (args.len > 2) args[2] else (init.environ_map.get("KEAZIG_REF") orelse "/tmp/kea-ref");
        return runFilm(gpa, dir, ref_dir, scale_override);
    }
    for (states) |s| {
        for ([_]bool{ false, true }) |dark| {
            const look = if (dark) "dark" else "light";
            var opts = s.opts;
            opts.dark = dark;
            if (scale_override) |sc| opts.scale = sc;
            var f: Fixture = undefined;
            try f.init(gpa, opts);
            defer f.deinit();
            defer if (s.teardown) |down| down(&f);
            if (s.setup) |setup| setup(&f);
            f.tester.settle(2);
            // The window's ground, which the hosted window paints behind the view.
            if (f.browser.applied_ground) |g| f.tester.theme.background = g;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.png", .{ dir, s.name, look });
            defer gpa.free(path);
            try f.tester.screenshot(path);

            const pw: u32 = @intFromFloat(@round(opts.width * opts.scale));
            const ph: u32 = @intFromFloat(@round(opts.height * opts.scale));
            var icon_rects: std.ArrayList(nanoui.ui.Rect) = .empty;
            defer icon_rects.deinit(gpa);
            for (f.tester.ctx.nodes.items) |n| {
                if (n.content == .image and n.rect.w > 0 and n.rect.w <= 40 and n.rect.h > 0 and n.rect.h <= 40) {
                    try icon_rects.append(gpa, n.rect);
                }
            }
            const sidecar = try @import("kea").json.encode(gpa, Sidecar{
                .pixels = .{ pw, ph },
                .points = .{ @intFromFloat(@round(opts.width)), @intFromFloat(@round(opts.height)) },
                .cards = f.browser.prefs.sidebar and !f.browser.folded,
                .holes = f.holes(),
                .card = f.browser.site_card.rect,
                .icons = icon_rects.items,
            });
            defer gpa.free(sidecar);
            const jpath = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}.json", .{ dir, s.name, look });
            defer gpa.free(jpath);
            try writeBytes(gpa, jpath, sidecar);
            std.debug.print("snapshot {s}\n", .{path});
        }
    }
}
