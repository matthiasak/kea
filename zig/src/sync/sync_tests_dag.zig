//! Two headless Keas through one folder on the v2 store: deltas, damage
//! read past and healed, a v1 store upgraded, and places that already hold
//! something.
const std = @import("std");
const testing = std.testing;
const json = @import("../data/json.zig");
const core = @import("core.zig");
const keyring = @import("keyring.zig");
const dag = @import("dag.zig");
const kinds = @import("kinds.zig");
const ops = @import("sync_ops.zig");
const Drop = @import("drop.zig").Drop;
const Temp = @import("../tests/temp.zig").Temp;
const Kea = @import("../app/kea.zig").Kea;
const disk = @import("../data/disk.zig");

const gpa = testing.allocator;

const Two = struct {
    ta: Temp,
    tb: Temp,
    shared: []u8,
    ka: *Kea,
    kb: *Kea,
    arena: std.heap.ArenaAllocator,

    fn init(t: *Two) !void {
        t.ta = try Temp.init(gpa);
        t.tb = try Temp.init(gpa);
        t.shared = try std.fmt.allocPrint(gpa, "{s}/shared", .{t.ta.folder});
        disk.makePath(gpa, t.shared);
        t.ka = try Kea.create(gpa, null, .{ .root = t.ta.root, .suite = t.ta.suite, .headless = true });
        t.kb = try Kea.create(gpa, null, .{ .root = t.tb.root, .suite = t.tb.suite, .headless = true });
        t.arena = .init(gpa);
    }

    fn deinit(t: *Two) void {
        t.ka.destroy();
        t.kb.destroy();
        t.arena.deinit();
        gpa.free(t.shared);
        t.ta.deinit(gpa);
        t.tb.deinit(gpa);
    }

    fn join(t: *Two, k: *Kea, pass: []const u8) !void {
        k.sync.chooseFolder(t.shared);
        try testing.expect(k.sync.use(pass, null) == null);
        try testing.expect(k.sync.ready);
    }

    fn drop(t: *Two) !Drop {
        return Drop.folder(t.arena.allocator(), t.shared);
    }

    fn names(t: *Two, prefix: []const u8) !std.StringArrayHashMapUnmanaged(json.SwiftDate) {
        var d = try t.drop();
        return d.list(t.arena.allocator(), prefix);
    }

    fn spoil(t: *Two, name: []const u8) !void {
        var d = try t.drop();
        try d.put(t.arena.allocator(), name, "not what was written");
    }

    fn headOf(t: *Two, k: *Kea) ![]const u8 {
        return t.arena.allocator().dupe(u8, k.sync.state.value.head);
    }
};

fn chat(k: *Kea, id: json.Uuid, title: []const u8) void {
    k.ai.chats.put(.{ .id = id, .title = title, .touched = json.now() });
}

test "an edited chat goes up alone, and nothing when nothing changed" {
    var t: Two = undefined;
    try t.init();
    defer t.deinit();
    var ids: [10]json.Uuid = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = json.Uuid.random();
        chat(t.ka, id.*, try std.fmt.allocPrint(t.arena.allocator(), "Chat {d}", .{i}));
    }
    try t.join(t.ka, "correct horse");
    try t.join(t.kb, "correct horse");
    t.ka.sync.syncNow();
    t.kb.sync.syncNow();
    try testing.expectEqual(@as(usize, 10), t.kb.ai.chats.index.len);

    const before = try (try t.names(dag.packs_prefix)).clone(t.arena.allocator());
    const commits = (try t.names(dag.commits_prefix)).count();
    chat(t.ka, ids[3], "Chat 3, edited");
    t.ka.sync.syncNow();
    const after = try t.names(dag.packs_prefix);
    try testing.expectEqual(before.count() + 1, after.count());
    var fresh: ?[]const u8 = null;
    for (after.keys()) |n| if (!before.contains(n)) {
        fresh = n;
    };
    const a = t.arena.allocator();
    var d = try t.drop();
    const sk = t.ka.sync.subkeys.?;
    const doc = try json.decode(dag.PackDoc, a, try dag.fetch(a, &d, &sk, fresh.?));
    try testing.expectEqual(@as(usize, 1), doc.value.records.len);
    try testing.expect(std.mem.indexOf(u8, doc.value.records[0].data.bytes, "Chat 3, edited") != null);

    // Nothing changed: no pack, no commit.
    const now_commits = (try t.names(dag.commits_prefix)).count();
    t.ka.sync.syncNow();
    try testing.expectEqual(after.count(), (try t.names(dag.packs_prefix)).count());
    try testing.expectEqual(now_commits, (try t.names(dag.commits_prefix)).count());
    try testing.expectEqual(commits + 1, now_commits);
    t.kb.sync.syncNow();
    try testing.expectEqualStrings("Chat 3, edited", t.kb.ai.chats.chat(ids[3]).?.title);
}

test "a damaged head and commit: the Mac before it, then the head healed" {
    var t: Two = undefined;
    try t.init();
    defer t.deinit();
    try t.join(t.ka, "correct horse");
    try testing.expect(t.ka.bookmarks.add("https://kea.example/one", "One") != null);
    t.ka.sync.syncNow();
    try testing.expect(t.ka.bookmarks.add("https://kea.example/two", "Two") != null);
    t.ka.sync.syncNow();
    const a = t.arena.allocator();
    try t.spoil(try dag.commitPath(a, try t.headOf(t.ka)));
    try t.spoil(try dag.headPath(a, t.ka.sync.device));

    try t.join(t.kb, "correct horse");
    try testing.expect(std.mem.startsWith(u8, t.kb.sync.status, "Synced"));
    try testing.expect(t.kb.bookmarks.contains("https://kea.example/one"));
    try testing.expect(!t.kb.bookmarks.contains("https://kea.example/two"));
    try testing.expect(t.kb.sync.damaged_note.len > 0);

    // A's next round writes its head again; B then has it all, and no damage.
    t.ka.sync.syncNow();
    var d = try t.drop();
    const sk = t.ka.sync.subkeys.?;
    try testing.expect((try dag.readHead(a, &d, &sk, t.ka.sync.device)) != null);
    t.kb.sync.syncNow();
    try testing.expect(t.kb.bookmarks.contains("https://kea.example/two"));
    try testing.expectEqualStrings("", t.kb.sync.damaged_note);
}

test "a damaged pack costs only its records, and its Mac writes it again" {
    var t: Two = undefined;
    try t.init();
    defer t.deinit();
    try t.join(t.ka, "correct horse");
    try testing.expect(t.ka.bookmarks.add("https://kea.example/kept", "Kept") != null);
    t.ka.sync.syncNow();
    const before = try (try t.names(dag.packs_prefix)).clone(t.arena.allocator());
    const id = json.Uuid.random();
    chat(t.ka, id, "Only in the second pack");
    t.ka.sync.syncNow();
    const after = try t.names(dag.packs_prefix);
    try testing.expectEqual(before.count() + 1, after.count());
    for (after.keys()) |n| if (!before.contains(n)) try t.spoil(n);

    try t.join(t.kb, "correct horse");
    try testing.expect(std.mem.startsWith(u8, t.kb.sync.status, "Synced"));
    try testing.expect(t.kb.bookmarks.contains("https://kea.example/kept"));
    try testing.expect(t.kb.ai.chats.chat(id) == null);
    try testing.expect(t.kb.sync.damaged_note.len > 0);

    // A reads its packs back, finds the damage and writes the chat again.
    t.ka.sync.syncNow();
    t.kb.sync.syncNow();
    try testing.expectEqualStrings("Only in the second pack", t.kb.ai.chats.chat(id).?.title);
    try testing.expectEqualStrings("", t.kb.sync.damaged_note);
}

test "a v1 store is upgraded with its passphrase and its Macs' files taken in" {
    var t: Two = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    try testing.expect(t.ka.bookmarks.add("https://kea.example/v1", "From v1") != null);
    const tree = (try kinds.records(&t.ka.sync, .bookmarks, a)).get("tree").?;
    var doc: core.SyncDoc = .{};
    try doc.records.map.put(a, "tree", .{ .data = .{ .bytes = tree }, .at = json.now() });
    const salt = "sixteen byte slt";
    const k = core.key("correct horse", salt);
    var d = try t.drop();
    try d.put(a, "kea/v1/salt", salt);
    try d.put(a, "kea/v1/check", try core.seal(a, "kea", k));
    const old = json.Uuid.random();
    try d.put(a, try std.fmt.allocPrint(a, "kea/v1/devices/{f}/bookmarks.kea", .{old}), try core.seal(a, try json.encodeSorted(a, doc), k));

    t.kb.sync.chooseFolder(t.shared);
    try testing.expect(t.kb.sync.location == .existing_v1);
    try testing.expect(t.kb.sync.use("wrong horse", null) == null);
    try testing.expectEqualStrings(core.wrong_passphrase, t.kb.sync.status);
    try t.join(t.kb, "correct horse");
    try testing.expect(t.kb.bookmarks.contains("https://kea.example/v1"));
    try testing.expect((try d.get(a, "kea/v2/keyring.json")) != null);
    try testing.expect((try t.names(dag.commits_prefix)).count() > 0);
}

test "someone else's folder is never written over unasked" {
    var t: Two = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var d = try t.drop();
    try d.put(a, "notes.txt", "mine");
    const s = &t.ka.sync;
    s.chooseFolder(t.shared);
    try testing.expectEqualStrings("notes.txt", s.location.non_empty_unrelated.sample);
    try testing.expect(s.use("correct horse", null) == null);
    try testing.expect(!s.ready);
    try testing.expectEqualStrings(ops.has_other_files, s.status);
    try testing.expectEqual(@as(usize, 0), (try t.names("kea/")).count());

    // A "Kea Sync" folder inside, used instead.
    s.createSubfolderAndUse(null);
    try testing.expect(std.mem.endsWith(u8, s.folder, "/shared/Kea Sync"));
    try testing.expect(s.use("correct horse", null) == null);
    try testing.expect(s.ready);
    try testing.expect((try t.names("Kea Sync/kea/v2/heads/")).count() == 1);

    // Or right here, once you say so.
    t.kb.sync.chooseFolder(t.shared);
    t.kb.sync.confirmUseNonEmpty(null);
    try testing.expect(t.kb.sync.use("other horse", null) == null);
    try testing.expect(t.kb.sync.ready);
    try testing.expectEqualStrings("mine", (try d.get(a, "notes.txt")).?);
    try testing.expect((try d.get(a, "kea/v2/keyring.json")) != null);
}

extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;

test "a store replaced is archived, put back on failure, and restored" {
    var t: Two = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    try t.join(t.ka, "correct horse");
    try testing.expect(t.ka.bookmarks.add("https://kea.example/old", "Old") != null);
    t.ka.sync.syncNow();
    const sb = &t.kb.sync;
    sb.chooseFolder(t.shared);
    try testing.expect(sb.location == .existing_v2);

    // A head that can't be moved: everything put back as it was.
    const heads = try std.fmt.allocPrintSentinel(a, "{s}/kea/v2/heads", .{t.shared}, 0);
    _ = chmod(heads, 0o555);
    try testing.expect(sb.overwriteExistingStore("new horse", null) == null);
    _ = chmod(heads, 0o755);
    try testing.expect(!sb.ready);
    try testing.expect(std.mem.indexOf(u8, sb.warning_error, "restored") != null);
    try testing.expect(sb.use("correct horse", null) == null);
    try testing.expect(sb.ready);
    try testing.expect(t.kb.bookmarks.contains("https://kea.example/old"));

    // Replaced for real: the old store archived, A told to unlock again.
    sb.chooseFolder(t.shared);
    try testing.expect(sb.overwriteExistingStore("new horse", null) == null);
    try testing.expect(sb.ready);
    try testing.expect((try t.names("kea/quarantine/")).count() > 0);
    t.ka.sync.syncNow();
    try testing.expect(!t.ka.sync.ready);

    // And back: the archive restored, A's passphrase opens it again.
    sb.restoreQuarantined(null);
    try testing.expect(!sb.ready);
    try testing.expect(t.ka.sync.use("correct horse", null) == null);
    try testing.expect(t.ka.sync.ready);
    try testing.expect(std.mem.startsWith(u8, t.ka.sync.status, "Synced"));
    try testing.expect(sb.use("new horse", null) == null);
    try testing.expectEqualStrings(core.wrong_passphrase, sb.status);
}

test "account keys: one Mac's key carried to another, a passphrase added after" {
    var t: Two = undefined;
    try t.init();
    defer t.deinit();
    const sa = &t.ka.sync;
    const sb = &t.kb.sync;
    sa.setKeyMode(.account_key);
    sa.chooseFolder(t.shared);
    try testing.expect(sa.useAccountKey(null) == null);
    try testing.expect(sa.ready and sa.ring_has_my_account_key and !sa.ring_has_password);
    try testing.expect(t.ka.bookmarks.add("https://kea.example/ak", "AK") != null);
    sa.syncNow();

    // B with a key of its own: refused; with A's, in.
    sb.setKeyMode(.account_key);
    sb.chooseFolder(t.shared);
    try testing.expect(sb.useAccountKey(null) == null);
    try testing.expectEqualStrings(ops.wrong_account_key, sb.status);
    try testing.expect(sb.use("any horse", null) == null);
    try testing.expectEqualStrings(ops.uses_account_key, sb.status);
    const text = keyring.encodePortableKey(sa.accountKey().?);
    try testing.expect(sb.importAccountKey(&text, null) == null);
    try testing.expect(sb.ready);
    try testing.expect(t.kb.bookmarks.contains("https://kea.example/ak"));

    // A backup passphrase: a third Mac gets in with it.
    try testing.expect(sa.enrollBackupPassword("backup horse", null) == null);
    try testing.expect(sa.ring_has_password);
    sb.setKeyMode(.password);
    sb.chooseFolder(t.shared);
    try testing.expect(sb.use("backup horse", null) == null);
    try testing.expect(sb.ready);
}
