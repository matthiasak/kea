//! Things taken off pages and kept off (`Curtain` in Curtain.swift, the
//! model): per site, a list of selectors in `hidden.json`, put back on as a
//! stylesheet before the page draws.
const std = @import("std");
const json = @import("json.zig");
const url = @import("url.zig");
const Store = @import("store.zig").Store;

pub const Veil = struct {
    selector: []const u8,
    /// What it was, in words.
    label: []const u8,
    /// How big it was and where it sat, measured when hidden.
    note: ?[]const u8 = null,
    date: json.SwiftDate,
};

pub const Curtain = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    /// Owns `by_host`, keys and all.
    arena: std.heap.ArenaAllocator,
    by_host: json.Map([]const Veil) = .{},

    pub const file = "hidden.json";

    pub fn init(gpa: std.mem.Allocator, store: *Store) Curtain {
        var self: Curtain = .{ .gpa = gpa, .store = store, .arena = .init(gpa) };
        if (store.load(json.Map([]const Veil), file)) |p| {
            defer p.deinit();
            self.by_host = copy(self.arena.allocator(), p.value) catch .{};
        }
        return self;
    }

    pub fn deinit(self: *Curtain) void {
        self.arena.deinit();
    }

    /// The host as lists are kept: lowercased, without its www. On `a`.
    pub fn hostOf(a: std.mem.Allocator, address: ?[]const u8) ?[]u8 {
        const h = (url.Parts.parse(address orelse return null) orelse return null).hostName() orelse return null;
        const bare = if (std.ascii.startsWithIgnoreCase(h, "www.")) h[4..] else h;
        return url.lower(a, bare) catch null;
    }

    pub fn veils(self: *const Curtain, host: ?[]const u8) []const Veil {
        return self.by_host.map.get(host orelse return &.{}) orelse &.{};
    }

    pub fn hide(self: *Curtain, selector: []const u8, label: []const u8, note: []const u8, host: []const u8) void {
        const list = self.veils(host);
        for (list) |v| if (std.mem.eql(u8, v.selector, selector)) return;
        var more: std.ArrayList(Veil) = .empty;
        defer more.deinit(self.gpa);
        more.appendSlice(self.gpa, list) catch return;
        more.append(self.gpa, .{ .selector = selector, .label = label, .note = note, .date = json.now() }) catch return;
        self.set(host, more.items);
    }

    /// Put one back.
    pub fn restore(self: *Curtain, selector: []const u8, host: []const u8) void {
        var left: std.ArrayList(Veil) = .empty;
        defer left.deinit(self.gpa);
        for (self.veils(host)) |v| if (!std.mem.eql(u8, v.selector, selector)) left.append(self.gpa, v) catch return;
        self.set(host, left.items);
    }

    /// The last one put back (⌘Z while pointing), copied onto `a`.
    pub fn undo(self: *Curtain, a: std.mem.Allocator, host: []const u8) ?Veil {
        const list = self.veils(host);
        if (list.len == 0) return null;
        const back = json.clone(a, list[list.len - 1]) catch return null;
        self.set(host, list[0 .. list.len - 1]);
        return back;
    }

    pub fn restoreAll(self: *Curtain, host: []const u8) void {
        self.set(host, &.{});
    }

    /// The stylesheet for a site, one rule per selector so one the browser
    /// can't parse takes only itself down; `spared` is left out. On `a`.
    pub fn css(self: *const Curtain, a: std.mem.Allocator, host: ?[]const u8, spared: ?[]const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        errdefer out.deinit();
        var first = true;
        for (self.veils(host)) |v| {
            if (spared) |s| if (std.mem.eql(u8, s, v.selector)) continue;
            if (!first) try out.writer.writeByte('\n');
            first = false;
            try out.writer.print("{s} {{ display: none !important; }}", .{v.selector});
        }
        return out.toOwnedSlice();
    }

    /// `host`'s list replaced (an empty one removes the host), then saved.
    /// `list` may point into the old snapshot.
    fn set(self: *Curtain, host: []const u8, list: []const Veil) void {
        var next: std.heap.ArenaAllocator = .init(self.gpa);
        const a = next.allocator();
        const built = blk: {
            var m = copy(a, self.by_host) catch break :blk null;
            if (list.len == 0) {
                _ = m.map.orderedRemove(host);
            } else {
                const v = json.clone(a, list) catch break :blk null;
                const gop = m.map.getOrPut(a, host) catch break :blk null;
                if (!gop.found_existing) gop.key_ptr.* = a.dupe(u8, host) catch break :blk null;
                gop.value_ptr.* = v;
            }
            break :blk m;
        } orelse return next.deinit();
        self.arena.deinit();
        self.arena = next;
        self.by_host = built;
        self.store.save(file, self.by_host, false);
    }

    fn copy(a: std.mem.Allocator, m: json.Map([]const Veil)) !json.Map([]const Veil) {
        var out: json.Map([]const Veil) = .{};
        try out.map.ensureTotalCapacity(a, m.map.count());
        var it = m.map.iterator();
        while (it.next()) |e| out.map.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), try json.clone(a, e.value_ptr.*));
        return out;
    }
};

test "hidden fixture round-trips" {
    const gpa = std.testing.allocator;
    const bytes = @embedFile("../tests/fixtures/kea/hidden.json");
    const a = try json.decode(json.Map([]const Veil), gpa, bytes);
    defer a.deinit();
    const out = try json.encode(gpa, a.value);
    defer gpa.free(out);
    const b = try json.decode(json.Map([]const Veil), gpa, out);
    defer b.deinit();
    try std.testing.expectEqualDeep(a.value.map.keys(), b.value.map.keys());
    for (a.value.map.values(), b.value.map.values()) |x, y| try std.testing.expectEqualDeep(x, y);
    try std.testing.expect(a.value.map.get("example.com").?[1].note == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"note\":null") == null);
}

test "curtain hides, restores and writes css" {
    const Temp = @import("../tests/temp.zig").Temp;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    store.write(Curtain.file, try gpa.dupe(u8, @embedFile("../tests/fixtures/kea/hidden.json")), true);
    var c = Curtain.init(gpa, &store);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 2), c.veils("example.com").len);
    c.hide("#nag", "div#nag", "10x10 top-left", "example.com");
    c.hide("#nag", "div#nag", "again", "example.com");
    try std.testing.expectEqual(@as(usize, 3), c.veils("example.com").len);
    const sheet = try c.css(gpa, "example.com", "#cookie-bar");
    defer gpa.free(sheet);
    try std.testing.expectEqualStrings("div.promo > a[href=\"/x\"] { display: none !important; }\n#nag { display: none !important; }", sheet);
    const back = c.undo(gpa, "example.com").?;
    defer {
        gpa.free(back.selector);
        gpa.free(back.label);
        gpa.free(back.note.?);
    }
    try std.testing.expectEqualStrings("div#nag", back.label);
    c.restoreAll("news.site");
    try std.testing.expect(c.by_host.map.get("news.site") == null);
    c.restore("#cookie-bar", "example.com");
    c.restore("div.promo > a[href=\"/x\"]", "example.com");
    try std.testing.expectEqual(@as(usize, 0), c.by_host.map.count());
    const host = Curtain.hostOf(gpa, "https://WWW.Example.com/page").?;
    defer gpa.free(host);
    try std.testing.expectEqualStrings("example.com", host);
    store.disk.drain();
    const saved = store.readFile(Curtain.file).?;
    defer gpa.free(saved);
    try std.testing.expectEqualStrings("{}", saved);
}
