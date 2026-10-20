//! `ImportPanel` (ImportPanel.swift): bringing things over from another
//! browser, all in one place — which browser, which of its profiles, and what
//! of it — a sheet (`chrome/sheet.zig`, `bringing_in`). What each browser
//! holds is counted as the sheet opens, off the main thread and from its
//! files alone: nothing prompts until Bring them in is pressed.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const ring = @import("../chrome/ring.zig");
const sheet = @import("../chrome/sheet.zig");
const disclose = @import("../chrome/disclose.zig");
const tab_menu = @import("../chrome/tab_menu.zig");
const when = @import("../chrome/when.zig");
const sources = @import("sources.zig");
const record = @import("record.zig");
const bring = @import("bring.zig");
const Session = bring.Session;

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = bring.panel(b) orelse return;
    // Opened for the extensions: off a browser with none fresh, to the first with some.
    if (s.for_extensions) if (s.pick) |at| if (bring.fresh(s, c.alloc(), at).len == 0) {
        for (0..s.found.len) |i| if (bring.fresh(s, c.alloc(), i).len > 0) {
            s.pick = i;
            break;
        };
    };
    var pl = plate.plate(c, p, "Bring things over", 580);
    if (pl.closed) sheet.close(b, .bringing);
    // As tall as it needs to be, and scrolling past what the window can hold.
    ui.scroll(c, .{ .width = .fill, .max_height = @max(160, c.size.h - 250), .gap = 14, .scroll_bar = false, .padding = .{ .bottom = 2 } });
    content(b, c, p, s);
    ui.end(c);
    pl.foot(c, p);
    foot(b, c, p, s);
    pl.end(c);
}

const options_id: u64 = std.hash.Wyhash.hash(0, "kea.import.options");
const said_id: u64 = std.hash.Wyhash.hash(0, "kea.import.said");

fn content(b: *Browser, c: *ui.Context, p: *const Palette, s: *Session) void {
    ui.text(c, "Nothing in the other browser changes. Passwords go into your keychain.", .{ .size = 12.5, .color = p.muted, .wrap = true });
    if (s.looking) {
        ui.row(c, .{ .gap = 8, .align_items = .center });
        ring.ring(c, 10);
        ui.text(c, "Looking on this Mac…", .{ .size = 12, .color = p.muted });
        ui.end(c);
    } else if (s.found.len == 0) {
        plate.cardBox(c, p);
        plate.nothing(c, p, "No other browser found on this Mac.");
        ui.end(c);
    } else {
        plate.caption(c, p, "On this Mac");
        plate.cardBox(c, p);
        for (s.found, 0..) |src, i| {
            if (i > 0) plate.rule(c, p, 14);
            ui.key(c, c.print("import.row.{d}", .{i}));
            if (row(c, p, src.name(), detail(c, b, s, i), s.pick == i) and !s.bringing) {
                s.pick = i;
                s.replace_bookmarks = false;
                s.for_extensions = false;
                s.brought = false;
            }
        }
        ui.end(c);
    }
    notes(c, p, s);
    // The picked browser's options arrive under `Motion.settle`, fading in.
    if (disclose.begin(c, options_id, s.pick != null, motion.settle)) {
        if (s.pick) |i| options(b, c, p, s, i);
        disclose.end(c);
    }
}

/// One browser to choose, and what it holds (`Row`).
fn row(c: *ui.Context, p: *const Palette, name: []const u8, detail_text: []const u8, chosen: bool) bool {
    const i = c.open(.{ .direction = .row, .gap = 12, .width = .fill, .padding = .xy(14, 9), .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .radio_button, name, detail_text, chosen, true);
    c.node(i).style.background = p.hover.alpha(motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0));
    _ = c.leaf(.{
        .width = .{ .px = 14 },
        .height = .{ .px = 14 },
        .radius = 7,
        .border = if (chosen) p.sunset else p.faint,
        .border_width = if (chosen) 4.5 else 1.2,
    }, .none, null);
    ui.column(c, .{ .gap = 2, .grow = 1, .min_width = 0 });
    ui.text(c, name, .{ .size = 13, .color = p.ink });
    ui.text(c, detail_text, .{ .size = 11.5, .color = p.muted, .tabular = true, .wrap = true });
    ui.end(c);
    return it.clicked;
}

/// Safari, and browsers on this Mac with nothing where their data should
/// be: said by name rather than left out.
fn notes(c: *ui.Context, p: *const Palette, s: *Session) void {
    const safari = sources.safari() and !s.base.testing;
    if (!safari and s.unreadable.len == 0) return;
    ui.column(c, .{ .gap = 4, .width = .fill, .padding = .{ .left = 2 } });
    if (safari) ui.text(c, "Safari — macOS keeps its data from other apps: in Safari, File › Export Browsing Data, then bring the file in below.", .{ .size = 11.5, .color = p.muted, .wrap = true });
    for (s.unreadable) |l| ui.text(c, l, .{ .size = 11.5, .color = p.muted, .wrap = true });
    ui.end(c);
}

fn options(b: *Browser, c: *ui.Context, p: *const Palette, s: *Session, i: usize) void {
    const a = c.alloc();
    const src = s.found[i];
    const name = src.name();
    const counted = s.preview(i);
    const pv: ?sources.Preview = if (counted) |k| k.preview else null;
    const earlier = record.of(a, b.store, name);
    plate.cardBox(c, p);
    defer ui.end(c);
    if (earlier) |r| {
        plate.line(c, p, "Brought before", broughtBefore(a, r));
        ui.end(c);
        plate.rule(c, p, 14);
    }
    if (s.profiles[i].len > 1) {
        plate.line(c, p, "Profile", null);
        profilePicker(b, c, p, s, i);
        ui.end(c);
        plate.rule(c, p, 14);
    }
    // A kind the browser has none of is said so, and can't be picked.
    const no_passwords = if (pv) |v| v.passwords == 0 else false;
    plate.line(c, p, "Passwords", if (no_passwords) c.print("None in {s}", .{name}) else if (src.asksForKey())
        c.print("macOS asks once for {s}'s keychain key", .{name})
    else
        c.print("Read from {s}'s own files, unless it has a primary password", .{name}));
    option(c, p, &s.wants_passwords, "Passwords", no_passwords);
    ui.end(c);
    plate.rule(c, p, 14);
    const no_marks = if (pv) |v| v.bookmarks == 0 else false;
    plate.line(c, p, "Bookmarks", if (no_marks) c.print("None in {s}", .{name}) else c.print("In a “{s}” folder, or at the top if you have none yet", .{name}));
    option(c, p, &s.wants_bookmarks, "Bookmarks", no_marks);
    ui.end(c);
    // Brought before: only what is new comes, unless what came from it last
    // time is to go first.
    if (s.wants_bookmarks and !no_marks) if (earlier) |r| {
        plate.rule(c, p, 14);
        const recorded = r.bookmarkIDs.len > 0;
        plate.line(c, p, c.print("Replace what came from {s} before", .{name}), if (recorded)
            c.print("Its bookmarks from {s} go, and these come fresh; passwords only ever add", .{when.dayMonth(a, r.date)})
        else
            c.print("Nothing recorded from {s} yet — only what is new comes", .{name}));
        option(c, p, &s.replace_bookmarks, "Replace", !recorded);
        ui.end(c);
    };
    plate.rule(c, p, 14);
    const no_places = if (pv) |v| v.places == 0 else false;
    plate.line(c, p, "History", if (no_places) c.print("None in {s}", .{name}) else c.print("The last {s} places", .{bring.number(a, if (pv) |v| v.places else 3000)}));
    option(c, p, &s.wants_history, "History", no_places);
    ui.end(c);
    // Arc's own: its spaces, what is pinned in them, its favourites.
    const arc = if (counted) |k| k.arc else null;
    if (arc) |n| if (n.spaces + n.pinned > 0) {
        plate.rule(c, p, 14);
        plate.line(c, p, "Spaces and pinned tabs", arcDetail(c, b, n));
        _ = controls.switch_(c, p, &s.wants_arc, "Spaces and pinned tabs");
        ui.end(c);
        if (s.wants_arc and n.pinned > 0 and !b.prefs.lists_pins) {
            plate.rule(c, p, 14);
            plate.line(c, p, "Keep them as pinned rows", if (b.prefs.sidebar)
                "As in Arc: each pinned page a row with its name, under your pins. Turned on, it stays in Settings › Tabs › Pinned rows"
            else
                "As in Arc: each pinned page a row with its name, under your pins. Turned on, it stays in Settings › Tabs › Pinned rows; rows show with the tabs down the side");
            if (controls.pill(c, p, "Turn on pinned rows", .{}).clicked) b.prefs.set("lists_pins", true);
            ui.end(c);
        }
    };
    const fresh = bring.fresh(s, a, i);
    if (fresh.len > 0) {
        plate.rule(c, p, 14);
        plate.line(c, p, "Extensions", c.print("{d} found — installed fresh from the Chrome Web Store, you say yes to each one", .{fresh.len}));
        _ = controls.switch_(c, p, &s.wants_extensions, "Extensions");
        ui.end(c);
    }
}

/// A kind's switch; off and out of reach when there is none of it.
fn option(c: *ui.Context, p: *const Palette, on: *bool, label: []const u8, none: bool) void {
    if (!none) {
        _ = controls.switch_(c, p, on, label);
        return;
    }
    var off = false;
    ui.column(c, .{ .opacity = 0.4 });
    _ = controls.switch_(c, p, &off, label);
    ui.end(c);
}

/// What Arc's side of the import will do, which depends on whether pinned
/// rows are on.
fn arcDetail(c: *ui.Context, b: *Browser, n: sources.arc.Counts) []const u8 {
    const spaces = if (n.spaces == 1) "1 space" else c.print("{d} spaces", .{n.spaces});
    const head = c.print("{s}, {d} pinned — each a space here, the favourites as pins", .{ spaces, n.pinned });
    return if (b.prefs.lists_pins)
        c.print("{s}, its pinned pages as rows under them, and the ones it filed in a folder as tabs in a group of that name", .{head})
    else
        c.print("{s}, its pinned tabs asleep in it", .{head});
}

fn detail(c: *ui.Context, b: *Browser, s: *Session, i: usize) []const u8 {
    const a = c.alloc();
    const counted = s.preview(i) orelse return "Counting…";
    var parts: std.ArrayList([]const u8) = .empty;
    if (s.profiles[i].len > 1) parts.append(a, c.print("{d} profiles", .{s.profiles[i].len})) catch {};
    // What it has; a kind it has none of isn't worth a word.
    const kinds = [_]struct { usize, []const u8 }{ .{ counted.preview.bookmarks, "bookmark" }, .{ counted.preview.places, "place" }, .{ counted.preview.passwords, "password" } };
    for (kinds) |k| if (k[0] > 0) parts.append(a, bring.counted(a, k[0], k[1])) catch {};
    if (counted.arc) |n| if (n.spaces > 0) parts.append(a, bring.counted(a, n.spaces, "space")) catch {};
    if (record.of(a, b.store, s.found[i].name())) |r| parts.append(a, c.print("brought {s}", .{when.dayMonth(a, r.date)})) catch {};
    if (parts.items.len == 0) return "Nothing to bring in";
    return std.mem.join(a, " · ", parts.items) catch "";
}

/// "312 bookmarks, 1,204 places and 58 passwords, 27 Sep".
fn broughtBefore(a: std.mem.Allocator, r: record.Record) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const kinds = [_]struct { i64, []const u8 }{ .{ r.bookmarks, "bookmark" }, .{ r.places, "place" }, .{ r.passwords, "password" }, .{ r.spaces orelse 0, "space" }, .{ r.pinned orelse 0, "pinned tab" } };
    for (kinds) |k| if (k[0] > 0) parts.append(a, bring.counted(a, @intCast(k[0]), k[1])) catch {};
    const what = if (parts.items.len == 0) "Nothing new" else bring.listed(a, parts.items);
    return std.fmt.allocPrint(a, "{s}, {s}", .{ what, when.dayMonth(a, r.date) }) catch "";
}

// MARK: the profile picker

/// The `.menu` picker, drawn as AppKit's pop-up button; its menu on a press.
fn profilePicker(b: *Browser, c: *ui.Context, p: *const Palette, s: *Session, i: usize) void {
    const title = profileTitle(c, s, i, s.chosen[i] orelse s.usual[i] orelse "");
    if (controls.popUpButton(c, p, "Profile", title)) |at| if (!s.bringing) tab_menu.later(b, at, i, profileMenu);
}

fn profileTitle(c: *ui.Context, s: *Session, i: usize, id: []const u8) []const u8 {
    if (id.len == 0) return "All profiles";
    for (s.profiles[i]) |pr| if (std.mem.eql(u8, pr.id, id)) {
        const usual = if (s.usual[i]) |u| std.mem.eql(u8, u, pr.id) else false;
        return if (usual) c.print("Most recent: {s}", .{pr.name}) else pr.name;
    };
    return id;
}

const Pick = struct {
    b: *Browser,
    source: usize,
    id: []const u8,
    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        choose(self.b, self.source, self.id);
    }
};

/// A profile chosen for a browser: counted, unless it was already.
pub fn choose(b: *Browser, i: usize, id: []const u8) void {
    const s = b.importing.panel orelse return;
    if (i >= s.found.len) return;
    s.chosen[i] = s.alloc().dupe(u8, id) catch return;
    s.brought = false;
    bring.count(s, i);
    b.redraw();
}

fn profileMenu(arena: std.mem.Allocator, b: *Browser, i: u64) anyerror![]const MenuItem {
    const s = b.importing.panel orelse return &.{};
    const at: usize = @intCast(i);
    if (at >= s.found.len) return &.{};
    const now = s.chosen[at] orelse s.usual[at] orelse "";
    var out: std.ArrayList(MenuItem) = .empty;
    for (s.profiles[at]) |pr| {
        const pick = try arena.create(Pick);
        pick.* = .{ .b = b, .source = at, .id = pr.id };
        const usual = if (s.usual[at]) |u| std.mem.eql(u8, u, pr.id) else false;
        const label = if (usual) try std.fmt.allocPrint(arena, "Most recent: {s}", .{pr.name}) else pr.name;
        try out.append(arena, .{ .label = label, .checked = std.mem.eql(u8, now, pr.id), .click = .of(pick, Pick.fire) });
    }
    try out.append(arena, .separator);
    const all = try arena.create(Pick);
    all.* = .{ .b = b, .source = at, .id = "" };
    try out.append(arena, .{ .label = "All profiles", .checked = now.len == 0, .click = .of(all, Pick.fire) });
    return out.items;
}

// MARK: the foot

fn foot(b: *Browser, c: *ui.Context, p: *const Palette, s: *Session) void {
    ui.column(c, .{ .gap = 10, .width = .fill });
    defer ui.end(c);
    // What came over fades in (`.transition(.opacity)`), the foot settling.
    if (disclose.begin(c, said_id, s.brought, motion.settle)) {
        defer disclose.end(c);
        ui.column(c, .{ .gap = 5, .width = .fill });
        for (s.said) |maybe| if (maybe) |said| {
            ui.row(c, .{ .gap = 8, .width = .fill });
            const tint = if (said.ok) p.ink else p.muted;
            ui.icon(c, if (said.ok) "checkmark" else "exclamationmark.circle", .{ .size = 10.5, .weight = .semibold, .frame = 12, .color = tint });
            ui.text(c, said.text, .{ .size = 12.5, .color = tint, .wrap = true });
            ui.end(c);
        };
        ui.end(c);
    }
    ui.row(c, .{ .gap = 8, .width = .fill, .align_items = .center });
    defer ui.end(c);
    if (s.brought) {
        if (controls.pill(c, p, "Show bookmarks", .{}).clicked) {
            sheet.close(b, .bringing);
            sheet.show(b, .bookmarking);
        }
        // Bookmarks having just arrived is the one moment the bar is worth offering.
        if (s.marks_landed and !b.prefs.bookmarks_bar) if (controls.pill(c, p, "Show the bookmarks bar", .{}).clicked) {
            b.prefs.set("bookmarks_bar", true);
            sheet.close(b, .bringing);
        };
        if (comptime @hasField(sheet.Kind, "managing")) {
            if (controls.pill(c, p, "Show passwords", .{}).clicked) {
                sheet.close(b, .bringing);
                sheet.show(b, .managing);
            }
        }
    } else if (s.pick) |i| {
        const pv = s.preview(i);
        const can = s.wants_passwords or s.wants_bookmarks or s.wants_history or (s.wants_extensions and bring.fresh(s, c.alloc(), i).len > 0) or (s.wants_arc and pv != null and pv.?.arc != null);
        if (pill(c, p, if (s.bringing) "Bringing…" else "Bring them in", true, !s.bringing and can)) bring.bring(s);
        if (s.bringing) ring.ring(c, 10);
    }
    ui.spacer(c);
    if (pill(c, p, "File…", false, !s.bringing)) b.importFile();
}

/// A `Pill` that may be `.disabled`: dimmed, and nothing when pressed.
pub fn pill(c: *ui.Context, p: *const Palette, title: []const u8, filled: bool, enabled: bool) bool {
    ui.column(c, .{ .opacity = if (enabled) 1 else 0.5 });
    defer ui.end(c);
    return controls.pill(c, p, title, .{ .filled = filled }).clicked and enabled;
}
