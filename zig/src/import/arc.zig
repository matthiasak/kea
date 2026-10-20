//! Arc's sidebar, read (ImportArc.swift): its spaces and what is pinned in
//! each, and the favourites above them, from StorableSidebar.json beside its
//! profiles — no key, nothing signed in. This only reads it and says what is
//! there; the import sheet makes the spaces and pins.
//!
//! The file keeps everything in flat lists of an id followed by its object:
//! spaces, and items — a tab, a folder ("list"), or a container of items —
//! joined by childrenIds. A space names its containers the same way, a label
//! followed by an id: the "pinned" one is taken; the "unpinned" one is Arc's
//! Today, which lives a day and is left behind. Read as damaged files are: a
//! folder is taken once and no deeper than 64, only http and https come, a
//! password in an address is dropped, and a file larger than any real
//! sidebar isn't read at all.
const std = @import("std");
const src = @import("sources.zig");
const files = @import("files.zig");
const disk = @import("../data/disk.zig");
const Parts = @import("../data/url.zig").Parts;
const Value = src.Value;

pub const Item = struct { title: []const u8, url: []const u8 };
pub const Folder = struct { title: []const u8, items: []Node };
pub const Node = union(enum) { item: Item, folder: Folder };

pub const Space = struct {
    name: []const u8,
    /// Arc's own, kept for the day it is wanted as it was.
    emoji: ?[]const u8,
    /// One of the space pictures, from `symbol`.
    symbol: []const u8,
    /// The Chromium profile folder the space signs in with.
    profile: []const u8,
    /// In Arc's order, folders kept as folders.
    pinned: []Node,
};

pub const Counts = struct { spaces: usize, pinned: usize };

pub const Sidebar = struct {
    /// The icons at the top, shared by every space of their profile.
    favorites: []Item,
    /// The same, by the profile they belong to.
    favorites_by_profile: std.StringArrayHashMapUnmanaged(std.ArrayList(Item)),
    spaces: []Space,

    pub fn pinnedCount(s: Sidebar) usize {
        var n: usize = 0;
        for (s.spaces) |sp| n += count(sp.pinned);
        return n;
    }

    /// How many spaces and pinned things there are, for the sheet's counts.
    pub fn counts(s: Sidebar) Counts {
        return .{ .spaces = s.spaces.len, .pinned = s.pinnedCount() + s.favorites.len };
    }
};

/// Arc's sidebar for one profile ("Default", "Profile 1"), or every one when
/// null. Null when there is no file or it doesn't read.
pub fn sidebar(a: std.mem.Allocator, base: src.Base, profile: ?[]const u8) !?Sidebar {
    const file = try files.join(a, base.path, "Arc/StorableSidebar.json");
    const size = files.size(file) orelse return null;
    if (size > 32 << 20) return null;
    const bytes = disk.read(a, file) orelse return null;
    return parse(a, bytes, profile);
}

const Reader = struct {
    a: std.mem.Allocator,
    items: std.StringHashMapUnmanaged(Value) = .empty,
    taken: std.StringHashMapUnmanaged(void) = .empty,
    total: usize = 0,

    /// What a container or folder holds, in order: each item once, no more
    /// than 64 folders down and 5000 things in all.
    fn nodes(r: *Reader, id: []const u8, depth: usize) error{OutOfMemory}![]Node {
        var out: std.ArrayList(Node) = .empty;
        if (depth >= 64) return out.items;
        const children = src.field(r.items.get(id), "childrenIds") orelse return out.items;
        if (children != .array) return out.items;
        for (children.array.items) |child| {
            const child_id = src.text(child) orelse continue;
            if (r.total >= 5000) continue;
            if ((try r.taken.getOrPut(r.a, child_id)).found_existing) continue;
            const item = r.items.get(child_id) orelse continue;
            const data = src.field(item, "data") orelse continue;
            if (data != .object) continue;
            if (src.field(data, "tab")) |tab| if (tab == .object) {
                const address = try page(r.a, src.text(src.field(tab, "savedURL"))) orelse continue;
                r.total += 1;
                const title = named(src.text(src.field(item, "title"))) orelse named(src.text(src.field(tab, "savedTitle"))) orelse
                    (Parts.parse(address).?.hostName() orelse address);
                try out.append(r.a, .{ .item = .{ .title = title, .url = address } });
                continue;
            };
            if (src.field(data, "list") != null) {
                const inside = try r.nodes(child_id, depth + 1);
                if (inside.len == 0) continue;
                try out.append(r.a, .{ .folder = .{ .title = named(src.text(src.field(item, "title"))) orelse "Folder", .items = inside } });
            }
        }
        return out.items;
    }
};

pub fn parse(a: std.mem.Allocator, bytes: []const u8, wanted: ?[]const u8) !?Sidebar {
    const top = src.parseJson(a, bytes) orelse return null;
    if (top != .object) return null;
    const containers = src.field(src.field(top, "sidebar"), "containers") orelse return null;
    if (containers != .array) return null;
    const main = for (containers.array.items) |c| {
        if (c == .object and c.object.contains("spaces")) break c;
    } else return null;

    var r: Reader = .{ .a = a };
    for (src.items(src.field(main, "items"))) |item| {
        if (item != .object) continue;
        if (src.text(src.field(item, "id"))) |id| try r.items.put(a, id, item);
    }

    var spaces: std.ArrayList(Space) = .empty;
    for (src.items(src.field(main, "spaces"))) |space| {
        if (space != .object) continue;
        const profile = profileName(src.field(space, "profile"));
        if (wanted) |w| if (!std.mem.eql(u8, w, profile)) continue;
        const name = named(src.text(src.field(space, "title"))) orelse "Space";
        const emoji = src.text(src.field(src.field(src.field(space, "customInfo"), "iconType"), "emoji_v2"));
        const pinned = container("pinned", src.field(space, "newContainerIDs")) orelse container("pinned", src.field(space, "containerIDs"));
        try spaces.append(a, .{
            .name = name,
            .emoji = emoji,
            .symbol = try symbol(a, emoji, name),
            .profile = profile,
            .pinned = if (pinned) |id| try r.nodes(id, 0) else &.{},
        });
    }

    // The favourites: a profile followed by its container's id.
    var favorites: std.ArrayList(Item) = .empty;
    var by_profile: std.StringArrayHashMapUnmanaged(std.ArrayList(Item)) = .empty;
    const tops = src.items(src.field(main, "topAppsContainerIDs"));
    for (tops, 0..) |entry, index| {
        if (entry == .string) continue;
        const profile = profileName(entry);
        if (index + 1 >= tops.len) continue;
        const id = src.text(tops[index + 1]) orelse continue;
        if (wanted) |w| if (!std.mem.eql(u8, w, profile)) continue;
        for (try r.nodes(id, 0)) |node| switch (node) {
            .item => |it| {
                try favorites.append(a, it);
                const slot = try by_profile.getOrPut(a, profile);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(a, it);
            },
            .folder => {},
        };
    }
    return .{ .favorites = favorites.items, .favorites_by_profile = by_profile, .spaces = spaces.items };
}

/// The id after `label` in a space's list of containers. Arc has written
/// the label as a string and, lately, as an object keyed by it.
fn container(label: []const u8, list: ?Value) ?[]const u8 {
    const l = src.items(list);
    for (l, 0..) |entry, index| {
        if (index + 1 >= l.len) break;
        const matches = if (src.text(entry)) |t| std.mem.eql(u8, t, label) else src.field(entry, label) != null;
        if (matches) if (src.text(l[index + 1])) |id| return id;
    }
    return null;
}

/// "Default", or the folder of the profile a space or favourites belong to:
/// {"default": {}} or {"custom": {"_0": {"directoryBasename": …}}}.
fn profileName(v: ?Value) []const u8 {
    const custom = src.field(v, "custom") orelse return "Default";
    if (custom != .object) return "Default";
    const zero = src.field(custom, "_0");
    const inner = if (zero != null and zero.? == .object) zero.? else custom;
    const n = src.text(src.field(inner, "directoryBasename")) orelse return "Default";
    return if (n.len == 0) "Default" else n;
}

/// A web address, with any password in it left behind.
fn page(a: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    var p = Parts.parse(text orelse return null) orelse return null;
    const scheme = p.scheme orelse return null;
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return null;
    if (p.user == null and p.password == null) return text.?;
    p.user = null;
    p.password = null;
    return try p.string(a);
}

/// Trimmed, at most 300 characters; null when empty.
// ponytail: counts code points where Swift counts grapheme clusters; the cut differs only inside a combined emoji.
fn named(text: ?[]const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text orelse return null, " \t\r\n");
    if (t.len == 0) return null;
    var it = std.unicode.Utf8View.initUnchecked(t).iterator();
    var n: usize = 0;
    while (it.nextCodepointSlice()) |_| {
        n += 1;
        if (n == 300) return t[0..it.i];
    }
    return t;
}

pub fn count(nodes: []const Node) usize {
    var n: usize = 0;
    for (nodes) |node| n += switch (node) {
        .item => 1,
        .folder => |f| count(f.items),
    };
    return n;
}

// MARK: - the space's picture

/// Arc's emoji as the nearest of the space pictures (Spaces.icons), then the
/// space's name, then a briefcase.
pub fn symbol(a: std.mem.Allocator, emoji: ?[]const u8, name: []const u8) ![]const u8 {
    if (emoji) |e| {
        // The same emoji with or without the mark asking for its coloured
        // form (U+FE0F), which Arc writes on some.
        const bare = try std.mem.replaceOwned(u8, a, e, "\u{FE0F}", "");
        for (by_emoji) |row| for (row[1]) |candidate| if (std.mem.eql(u8, candidate, bare)) return row[0];
    }
    // Whole words, or the start of one for the longer keys: "ai" is a word
    // here, not the middle of "maison".
    // ponytail: ASCII lowercasing; Swift lowercases every script ("École" stays "École" here).
    const lower = try std.ascii.allocLowerString(a, name);
    var words: std.ArrayList([]const u8) = .empty;
    var start: ?usize = null;
    for (lower, 0..) |ch, i| {
        // Bytes past ASCII belong to letters (é, ü …).
        const letter = std.ascii.isAlphanumeric(ch) or ch >= 0x80;
        if (letter and start == null) start = i;
        if (!letter) if (start) |s| {
            try words.append(a, lower[s..i]);
            start = null;
        };
    }
    if (start) |s| try words.append(a, lower[s..]);
    for (by_word) |row| for (row[1]) |key| for (words.items) |w| {
        const long = std.unicode.utf8CountCodepoints(key) catch key.len;
        if (std.mem.eql(u8, w, key) or (long >= 4 and std.mem.startsWith(u8, w, key))) return row[0];
    };
    return "briefcase";
}

const Row = struct { []const u8, []const []const u8 };

const by_emoji = [_]Row{
    .{ "briefcase", &.{ "💼", "👔", "📊", "📈", "🗂" } },
    .{ "building.2", &.{ "🏢", "🏛", "🏙" } },
    .{ "house", &.{ "🏠", "🏡", "🛋" } },
    .{ "desktopcomputer", &.{"🖥"} },
    .{ "laptopcomputer", &.{"💻"} },
    .{ "terminal", &.{ "⌨", "🧑‍💻", "👨‍💻", "👩‍💻" } },
    .{ "chevron.left.forwardslash.chevron.right", &.{ "🧑‍🔧", "🛠", "🔧", "⚙" } },
    .{ "sparkles", &.{ "✨", "🤖", "🪄", "⭐", "🌟" } },
    .{ "brain.head.profile", &.{"🧠"} },
    .{ "lightbulb", &.{"💡"} },
    .{ "gamecontroller", &.{ "🎮", "🕹", "👾" } },
    .{ "beach.umbrella", &.{ "🏖", "🌴", "⛱", "🏝" } },
    .{ "cup.and.saucer", &.{ "☕", "🍵", "🫖" } },
    .{ "music.note", &.{ "🎵", "🎶", "🎧", "🎸", "🎹" } },
    .{ "film", &.{ "🎬", "🍿", "📺", "🎥" } },
    .{ "paintpalette", &.{ "🎨", "🖌", "🖍", "✏" } },
    .{ "camera", &.{ "📷", "📸" } },
    .{ "book", &.{ "📚", "📖", "📕", "📘", "📰" } },
    .{ "graduationcap", &.{ "🎓", "🏫", "✍" } },
    .{ "cart", &.{ "🛒", "🛍", "💸", "💰", "💳" } },
    .{ "airplane", &.{ "✈", "🧳", "🌍", "🌎", "🌏", "🗺" } },
    .{ "dumbbell", &.{ "🏋", "💪", "🏃", "⚽", "🏀" } },
    .{ "leaf", &.{ "🌿", "🌱", "🍃", "🦋", "🌸", "🌳" } },
    .{ "heart", &.{ "❤", "💖", "💕", "🥰", "😍" } },
};

const by_word = [_]Row{
    .{ "briefcase", &.{ "work", "job", "office", "boulot", "travail", "client" } },
    .{ "house", &.{ "home", "perso", "personal", "maison", "family", "famille" } },
    .{ "chevron.left.forwardslash.chevron.right", &.{ "code", "dev", "github", "eng" } },
    .{ "sparkles", &.{ "ai", "gpt", "claude", "llm" } },
    .{ "graduationcap", &.{ "school", "study", "studies", "course", "cours", "uni", "école" } },
    .{ "book", &.{ "read", "lecture", "news", "research" } },
    .{ "paintpalette", &.{ "design", "art", "creative", "figma" } },
    .{ "music.note", &.{ "music", "musique" } },
    .{ "gamecontroller", &.{ "game", "gaming", "jeu" } },
    .{ "cart", &.{ "shop", "achat", "money", "finance" } },
    .{ "airplane", &.{ "travel", "trip", "voyage" } },
    .{ "dumbbell", &.{ "sport", "gym", "fitness" } },
    .{ "film", &.{ "film", "movie", "video", "watch" } },
};
