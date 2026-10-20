//! Arc's sidebar brought over (Browser.swift `takeArc`, `samePin`,
//! `opened`, `takeAsleep`, 1991-2201): its spaces become spaces here, its
//! favourites the pins of their profile's spaces, its pinned list the
//! space's tabs, asleep. The reading is `import/arc.zig`'s.
const std = @import("std");
const Browser = @import("browser.zig").Browser;
const Uuid = @import("../data/json.zig").Uuid;
const url = @import("../data/url.zig");
const Parts = url.Parts;
const Space = @import("../data/spaces.zig").Space;
const spaces_file = @import("../data/spaces.zig");
const PinDef = @import("../data/pins.zig").PinDef;
const session = @import("../data/session.zig");
const groups_ops = @import("groups.zig");
const TabGroup = groups_ops.TabGroup;
const rows = @import("browser_rows.zig");
pub const arc = @import("../import/arc.zig");
const sources = @import("../import/sources.zig");

pub const ArcTaken = struct { spaces: usize = 0, pins: usize = 0, tabs: usize = 0 };

/// Each of Arc's spaces becomes a space here — the one of the same name if
/// there is one, signed in with the others when Arc's used its first
/// profile — its pinned list the space's tabs, asleep until gone to,
/// folders opened out in their order; the favourites, the icons above
/// every space of a profile in Arc, become the pins of that profile's
/// spaces. A lone space, with spaces off, comes into the one there is;
/// more than one turns spaces on. Nothing twice: a page already in the
/// row, or a pin already there, isn't added again.
pub fn takeArc(b: *Browser, sidebar: arc.Sidebar, source: ?sources.Source, profile: ?[]const u8) ArcTaken {
    var arena: std.heap.ArenaAllocator = .init(b.gpa);
    defer arena.deinit();
    return take(b, arena.allocator(), sidebar, source, profile) catch @panic("OOM");
}

const Target = struct { id: Uuid, space: ?arc.Space };

fn take(b: *Browser, a: std.mem.Allocator, sidebar: arc.Sidebar, source: ?sources.Source, profile: ?[]const u8) !ArcTaken {
    var out: ArcTaken = .{};
    // Every address this brings in, for its icon below.
    var brought: std.ArrayList([]const u8) = .empty;
    var targets: std.ArrayList(Target) = .empty;
    if (sidebar.spaces.len > 1 or (b.prefs.uses_spaces and sidebar.spaces.len > 0)) {
        if (!b.prefs.uses_spaces) b.prefs.set("uses_spaces", true);
        var list: std.ArrayList(Space) = .empty;
        try list.appendSlice(a, b.kea.spaces.value);
        for (sidebar.spaces) |sp| {
            const name = try url.lower(a, sp.name);
            const same: ?Uuid = for (list.items) |s| {
                if (std.mem.eql(u8, try url.lower(a, s.name), name)) break s.id;
            } else null;
            if (same) |id| {
                try targets.append(a, .{ .id = id, .space = sp });
                continue;
            }
            const made: Space = .{ .id = Uuid.random(), .name = sp.name, .colour = 0, .icon = sp.symbol, .sharesSignIns = std.mem.eql(u8, sp.profile, "Default") };
            try list.append(a, made);
            try targets.append(a, .{ .id = made.id, .space = sp });
            out.spaces += 1;
        }
        if (out.spaces > 0) spaces_file.write(b.kea, list.items);
    } else try targets.append(a, .{ .id = b.space_id, .space = if (sidebar.spaces.len > 0) sidebar.spaces[0] else null });

    for (targets.items) |target| {
        // The pins this space had before any of this, for telling a
        // favourite that is already here from one this import is adding.
        const had = b.kea.pins.defs(target.id);
        var defs: std.ArrayList(PinDef) = .empty;
        try defs.appendSlice(a, had);
        // A space's own profile's favourites, as Arc shows them above it.
        const favourites = if (target.space) |sp| (if (sidebar.favorites_by_profile.get(sp.profile)) |l| l.items else sidebar.favorites) else sidebar.favorites;
        // A favourite whose site is already pinned is the pin you have,
        // however far it has gone from the address it was pinned at; only
        // against the pins that were already here: two favourites of Arc's
        // own on one site are two favourites, and stay two.
        for (favourites) |fav| {
            if (try pinnedAlready(a, had, defs.items, fav.url)) continue;
            try defs.append(a, .{ .id = Uuid.random(), .letter = try letterOf(a, fav.url), .home = fav.url, .title = fav.title });
            out.pins += 1;
            try brought.append(a, fav.url);
        }
        var pinned: std.ArrayList(Page) = .empty;
        try opened(a, &pinned, if (target.space) |sp| sp.pinned else &.{}, null);
        for (pinned.items) |p| try brought.append(a, p.item.url);
        // A page Arc keeps loose comes in as a row; one it filed in a
        // folder stays a tab in a group of that name (#478). With rows off
        // the whole list comes in as tabs.
        const rows_on = b.prefs.lists_pins;
        if (rows_on) for (pinned.items) |p| {
            if (p.folder != null) continue;
            if (try pinnedAlready(a, had, defs.items, p.item.url)) continue;
            try defs.append(a, .{ .id = Uuid.random(), .letter = try letterOf(a, p.item.url), .home = p.item.url, .title = p.item.title, .listed = true });
            out.pins += 1;
        };
        // `had` is the store's until this changes it.
        if (b.kea.pins.set(target.id, defs.items)) b.kea.pinsChanged(b, target.id);
        b.pinsChanged(target.id);
        var tabs: std.ArrayList(Page) = .empty;
        for (pinned.items) |p| if (!rows_on or p.folder != null) try tabs.append(a, p);
        out.tabs += try takeAsleep(b, a, tabs.items, target.id);
    }
    @import("browser_import.zig").adoptIcons(b, brought.items, source, profile);
    return out;
}

fn pinnedAlready(a: std.mem.Allocator, had: []const PinDef, defs: []const PinDef, address: []const u8) !bool {
    for (had) |d| if (try samePin(a, d.home, address)) return true;
    for (defs) |d| if (std.mem.eql(u8, d.home, address)) return true;
    return false;
}

/// The host's first character without its www., uppercased; "•" without one.
// ponytail: ASCII uppercasing and one code point, as `letter` in pins.zig; Swift folds every script and takes a grapheme.
fn letterOf(a: std.mem.Allocator, address: []const u8) ![]const u8 {
    var host = if (Parts.parse(address)) |p| p.hostName() orelse "" else "";
    while (std.mem.startsWith(u8, host, "www.")) host = host[4..];
    if (host.len == 0) return "•";
    const n = @min(host.len, std.unicode.utf8ByteSequenceLength(host[0]) catch 1);
    const out = try a.dupe(u8, host[0..n]);
    if (n == 1) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// Whether a pin is the one a favourite would make: the same site, and one
/// address inside the other (mail.google.com and mail.google.com/mail/u/0/),
/// or failing a site to compare (a file, an about: page), the same address.
/// github.com/me and github.com/work are two pins, and stay two.
pub fn samePin(a: std.mem.Allocator, home: []const u8, address: []const u8) !bool {
    const theirs_parts = Parts.parse(home);
    const mine_parts = Parts.parse(address);
    const mine = if (mine_parts) |p| try site(a, p) else null;
    const theirs = if (theirs_parts) |p| try site(a, p) else null;
    if (mine == null or theirs == null) return std.mem.eql(u8, home, address);
    if (!std.mem.eql(u8, mine.?, theirs.?)) return false;
    const x = try folder(a, mine_parts.?);
    const y = try folder(a, theirs_parts.?);
    return std.mem.startsWith(u8, x, y) or std.mem.startsWith(u8, y, x);
}

/// Its host, lowercased, without the www. that is not part of who it is,
/// and its port: localhost:3000 and localhost:5173 are two sites.
fn site(a: std.mem.Allocator, p: Parts) !?[]const u8 {
    const host = try url.lower(a, p.hostName() orelse return null);
    const name = if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
    const port = p.port orelse return name;
    if (port.len == 0) return name;
    return try std.fmt.allocPrint(a, "{s}:{s}", .{ name, port });
}

/// The path, ending in a slash, so that /me is never taken for the start of /media.
fn folder(a: std.mem.Allocator, p: Parts) ![]const u8 {
    const path = try url.lower(a, p.path);
    return if (std.mem.endsWith(u8, path, "/")) path else try std.mem.concat(a, u8, &.{ path, "/" });
}

/// A page of Arc's pinned list, with the top folder it came from.
const Page = struct { item: arc.Item, folder: ?[]const u8 };

/// Arc's pinned list, folders opened out in their order.
fn opened(a: std.mem.Allocator, out: *std.ArrayList(Page), nodes: []const arc.Node, in: ?[]const u8) !void {
    for (nodes) |node| switch (node) {
        .item => |item| try out.append(a, .{ .item = item, .folder = in }),
        .folder => |inner| try opened(a, out, inner.items, in orelse inner.title),
    };
}

/// The pages not already in `have`, each once.
fn fresh(a: std.mem.Allocator, have: []const []const u8, items: []const Page) ![]const Page {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (have) |h| try seen.put(a, h, {});
    var out: std.ArrayList(Page) = .empty;
    for (items) |p| if (!(try seen.getOrPut(a, p.item.url)).found_existing) try out.append(a, p);
    return out.items;
}

/// The group a folder's pages go into, by name, made (on `gpa`) if
/// missing. Kept whether or not tab groups are on, as the session keeps
/// them: turning groups on later finds it waiting rather than gone.
fn group(gpa: std.mem.Allocator, groups: *std.ArrayList(TabGroup), name: ?[]const u8) ?Uuid {
    const n = name orelse return null;
    for (groups.items) |g| if (std.mem.eql(u8, g.name, n)) return g.id;
    const made = groups_ops.owned(gpa, Uuid.random(), n, false);
    groups.append(gpa, made) catch @panic("OOM");
    return made.id;
}

fn ownedGroups(gpa: std.mem.Allocator, saved: []const session.TabGroup) std.ArrayList(TabGroup) {
    var out: std.ArrayList(TabGroup) = .empty;
    for (saved) |g| out.append(gpa, groups_ops.owned(gpa, g.id, g.name, g.collapsed)) catch @panic("OOM");
    return out;
}

fn sameGroups(x: []const TabGroup, y: []const session.TabGroup) bool {
    if (x.len != y.len) return false;
    for (x, y) |g, h| if (!g.id.eql(h.id) or !std.mem.eql(u8, g.name, h.name) or g.collapsed != h.collapsed) return false;
    return true;
}

/// Pages as tabs at the end of a space's row, asleep: the row on screen,
/// a parked one, or the one saved for a space not brought up. A page from
/// one of Arc's folders goes into the group of that name, made if there is
/// none. Groups are never turned on here.
fn takeAsleep(b: *Browser, a: std.mem.Allocator, items: []const Page, space: Uuid) !usize {
    var have: std.ArrayList([]const u8) = .empty;
    if (space.eql(b.space_id)) {
        for (b.tabs.items) |t| if (t.pending orelse t.address) |u| try have.append(a, u);
        const new = try fresh(a, have.items, items);
        const before = b.tab_groups.items.len;
        for (new) |page| {
            const t = b.makeAsleep(page.item.url, page.item.title, null, space);
            t.group_id = group(b.gpa, &b.tab_groups, page.folder);
            try b.tabs.append(b.gpa, t);
        }
        if (b.tab_groups.items.len != before) b.arrangeGroupedTabs(null);
        const shape = try b.session(a, b.tabs.items, b.active_id, try rows.groupsForSession(a, b.tab_groups.items), b.splits.items);
        b.writeRow(b.space_id, shape, true);
        b.redraw();
        return new.len;
    }
    // A parked row's groups are the ones saved for it (see allRows).
    const saved = b.readRow(space);
    defer saved.deinit();
    const saved_groups = saved.value.groups orelse &.{};
    if (b.parked.getPtr(space)) |row| {
        var groups = row.groups orelse ownedGroups(b.gpa, saved_groups);
        for (row.tabs.items) |t| if (t.pending orelse t.address) |u| try have.append(a, u);
        const new = try fresh(a, have.items, items);
        for (new) |page| {
            const t = b.makeAsleep(page.item.url, page.item.title, null, space);
            t.group_id = group(b.gpa, &groups, page.folder);
            try row.tabs.append(b.gpa, t);
        }
        row.groups = groups;
        if (!sameGroups(groups.items, saved_groups)) {
            var shape = saved.value;
            shape.groups = try rows.groupsForSession(a, groups.items);
            b.writeRow(space, shape, true);
        }
        return new.len;
    }
    var groups = ownedGroups(a, saved_groups);
    for (saved.value.tabs) |e| try have.append(a, e.url);
    const new = try fresh(a, have.items, items);
    var entries: std.ArrayList(session.Entry) = .empty;
    try entries.appendSlice(a, saved.value.tabs);
    for (new) |page| try entries.append(a, .{ .url = page.item.url, .title = page.item.title, .groupID = group(a, &groups, page.folder) });
    var shape = saved.value;
    shape.tabs = entries.items;
    shape.groups = try rows.groupsForSession(a, groups.items);
    b.writeRow(space, shape, true);
    return new.len;
}
