//! The DAG over a folder: deltas, and reading past damage.
const std = @import("std");
const testing = std.testing;
const json = @import("../data/json.zig");
const keyring = @import("keyring.zig");
const dag = @import("dag.zig");
const dw = @import("dag_write.zig");
const Drop = @import("drop.zig").Drop;
const Temp = @import("../tests/temp.zig").Temp;

const Fixture = struct {
    temp: Temp,
    arena: std.heap.ArenaAllocator,
    d: Drop,
    sk: keyring.Subkeys,
    ring: keyring.Keyring,
    mac: json.Uuid,

    fn init(f: *Fixture) !void {
        const gpa = testing.allocator;
        f.temp = try Temp.init(gpa);
        f.arena = .init(gpa);
        f.d = try Drop.folder(gpa, f.temp.root);
        const mk = keyring.randomKey();
        f.sk = keyring.deriveSubkeys(mk);
        f.ring = try keyring.create(f.arena.allocator(), mk);
        f.mac = json.Uuid.random();
    }

    fn deinit(f: *Fixture) void {
        f.d.deinit();
        f.arena.deinit();
        f.temp.deinit(testing.allocator);
    }

    fn cache(f: *Fixture, objects: bool) !dag.Cache {
        const gpa = testing.allocator;
        var c: dag.Cache = .{ .gpa = gpa };
        if (objects) c.objects = try Drop.folder(gpa, try std.fmt.allocPrint(f.arena.allocator(), "{s}/objects", .{f.temp.folder}));
        return c;
    }

    /// Chats `c1`, `c2` = `second`, published on top of what A last wrote.
    fn write(f: *Fixture, c: *dag.Cache, second: []const u8) !?[]const u8 {
        const a = f.arena.allocator();
        var health: dag.Health = .{};
        const prev = try dag.resolve(a, &f.d, &f.sk, c, f.mac, f.mac, true, "", &health);
        const k = try dw.known(a, if (prev) |p| &.{p.commit} else &.{}, &health);
        var draft: dw.Draft = .{};
        try draft.put(a, &f.sk, &k, "chats", "c1", "first chat, unchanged", 1);
        try draft.put(a, &f.sk, &k, "chats", "c2", second, 2);
        return dw.publish(a, &f.d, &f.sk, c, &draft, .{ .device = f.mac, .name = "Mac A", .ring = f.ring, .prev = prev, .now = json.now() }, false);
    }

    fn count(f: *Fixture, prefix: []const u8) !usize {
        return (try f.d.list(f.arena.allocator(), prefix)).count();
    }

    fn spoil(f: *Fixture, name: []const u8) !void {
        try f.d.put(f.arena.allocator(), name, "not what was written");
    }
};

test "only what changed goes up, nothing when nothing did" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c = try f.cache(true);
    defer c.deinit();
    const a = f.arena.allocator();
    _ = (try f.write(&c, "second chat")).?;
    try testing.expect(try f.write(&c, "second chat") == null);
    try testing.expectEqual(@as(usize, 1), try f.count(dag.packs_prefix));
    const second = (try f.write(&c, "second chat, edited")).?;
    try testing.expectEqual(@as(usize, 2), try f.count(dag.packs_prefix));
    // The new pack holds the edited chat alone.
    const commit = try dag.loadCommit(a, &f.d, &f.sk, &c, second);
    const tree = commit.trees.map.get("chats").?;
    const edited = tree.entries.map.get("c2").?;
    try testing.expect(!std.mem.eql(u8, edited.pack, tree.entries.map.get("c1").?.pack));
    const plain = try dag.fetch(a, &f.d, &f.sk, try dag.packPath(a, edited.pack));
    const doc = try json.decode(dag.PackDoc, a, plain);
    try testing.expectEqual(@as(usize, 1), doc.value.records.len);
    try testing.expectEqualStrings("second chat, edited", doc.value.records[0].data.bytes);
}

test "a damaged head, commit or pack falls back to what still reads" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var w = try f.cache(true);
    defer w.deinit();
    const a = f.arena.allocator();
    const one = (try f.write(&w, "second chat")).?;
    const two = (try f.write(&w, "second chat, edited")).?;
    const other = json.Uuid.random();

    // The newest commit damaged: the head's previous one.
    try f.spoil(try dag.commitPath(a, two));
    var r1 = try f.cache(false);
    defer r1.deinit();
    var h1: dag.Health = .{};
    const back = (try dag.resolve(a, &f.d, &f.sk, &r1, f.mac, other, true, "", &h1)).?;
    try testing.expectEqualStrings(one, back.oid);
    try testing.expect(h1.recovered_from_ancestor and h1.damaged() > 0);

    // The head damaged too: a scan finds the newest commit that reads.
    try f.spoil(try dag.headPath(a, f.mac));
    var r2 = try f.cache(false);
    defer r2.deinit();
    var h2: dag.Health = .{};
    const scanned = (try dag.resolve(a, &f.d, &f.sk, &r2, f.mac, f.mac, true, "", &h2)).?;
    try testing.expectEqualStrings(one, scanned.oid);
    try testing.expect(h2.heal_head);

    // A damaged pack: the record's older version, the rest intact.
    const three = (try f.write(&w, "second chat, edited again")).?;
    var r3 = try f.cache(false);
    defer r3.deinit();
    var h3: dag.Health = .{};
    const tip = (try dag.resolve(a, &f.d, &f.sk, &r3, f.mac, other, true, "", &h3)).?;
    try testing.expectEqualStrings(three, tip.oid);
    const tree = tip.commit.trees.map.get("chats").?;
    try f.spoil(try dag.packPath(a, tree.entries.map.get("c2").?.pack));
    var wants: std.ArrayList(dag.Want) = .empty;
    for (tree.entries.map.keys(), tree.entries.map.values()) |k, e| try wants.append(a, .{ .kind = "chats", .key = k, .ref = e });
    const got = try dag.loadEntries(a, &f.d, &f.sk, &r3, wants.items, .{ .from = tip.link() }, &h3);
    try testing.expectEqualStrings("first chat, unchanged", got.get("c1").?.bytes);
    try testing.expectEqualStrings("second chat", got.get("c2").?.bytes);
    try testing.expect(h3.recovered_from_ancestor and h3.bad_packs.count() == 1);
}

test "pruning keeps all the newest commits reach, however old it looks" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var c = try f.cache(false);
    defer c.deinit();
    const a = f.arena.allocator();
    _ = (try f.write(&c, "second chat")).?;
    const tip = (try f.write(&c, "second chat, edited")).?;
    try f.d.put(a, try dag.packPath(a, "abababababababababababababababababababababababababababababababab"), "a pack nobody points at");
    const packs = try f.count(dag.packs_prefix);
    const link: dag.Link = .{ .oid = tip, .commit = try dag.loadCommit(a, &f.d, &f.sk, &c, tip) };
    // A month on: only the stray pack goes.
    try testing.expectEqual(@as(usize, 1), try dw.prune(a, &f.d, &f.sk, &c, &.{link}, json.now() + 30 * 86_400));
    try testing.expectEqual(packs - 1, try f.count(dag.packs_prefix));
    var r = try f.cache(false);
    defer r.deinit();
    var h: dag.Health = .{};
    const back = (try dag.resolve(a, &f.d, &f.sk, &r, f.mac, json.Uuid.random(), true, "", &h)).?;
    const tree = back.commit.trees.map.get("chats").?;
    var wants: std.ArrayList(dag.Want) = .empty;
    for (tree.entries.map.keys(), tree.entries.map.values()) |k, e| try wants.append(a, .{ .kind = "chats", .key = k, .ref = e });
    try testing.expectEqual(@as(usize, 2), (try dag.loadEntries(a, &f.d, &f.sk, &r, wants.items, .{}, &h)).count());
    try testing.expectEqual(@as(usize, 0), h.damaged());
}
