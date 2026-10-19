//! Tests for `chats_store.zig`.
const std = @import("std");
const json = @import("json.zig");
const Store = @import("store.zig").Store;
const Temp = @import("../tests/temp.zig").Temp;
const roundtrip = @import("../tests/roundtrip.zig");
const cs = @import("chats_store.zig");
const Chats = cs.Chats;
const Chat = cs.Chat;
const gpa = std.testing.allocator;

const chat_fixture = @embedFile("../tests/fixtures/kea/chat.json");

test "chat fixture round-trips" {
    try roundtrip.check(Chat, chat_fixture, true);
    try roundtrip.check([]const cs.Entry, @embedFile("../tests/fixtures/kea/chats-index.json"), true);
    try roundtrip.check([]const Chat, @embedFile("../tests/fixtures/kea/chats-legacy.json"), true);
}

test "chat files have sorted keys and omit nil optionals" {
    const p = try json.decode(Chat, gpa, chat_fixture);
    defer p.deinit();
    const out = try json.encodeSorted(gpa, p.value);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"compacted\":1,\"id\":\"AAAAAAAA-1111-4222-8333-444444444444\",\"pageHidden\":false,\"pins\":"));
    try std.testing.expect(std.mem.indexOf(u8, out, "{\"answer\":\"They are birds.\",\"done\":true,\"id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "null") == null);
    try std.testing.expectEqualStrings("Pelican facts", p.value.label());
    const bare: Chat = .{ .id = json.Uuid.first, .touched = 0 };
    try std.testing.expectEqualStrings("Ubi Chat", bare.label());
    // Sixty characters, not sixty bytes.
    const q: [122]u8 = comptime blk: {
        var s: [122]u8 = undefined;
        for (0..61) |i| s[2 * i ..][0..2].* = "é".*;
        break :blk s;
    };
    const turns = [_]cs.Turn{.{ .id = json.Uuid.first, .question = &q }};
    const accented: Chat = .{ .id = json.Uuid.first, .touched = 0, .turns = &turns };
    try std.testing.expectEqualStrings(q[0..120], accented.label());
}

fn open(t: *Temp) !Store {
    t.* = try Temp.init(gpa);
    return Store.init(gpa, t.root, t.suite);
}

test "legacy chats.json migrates into index and per-chat files" {
    var t: Temp = undefined;
    var store = try open(&t);
    defer t.deinit(gpa);
    defer store.deinit();
    store.write(Chats.legacy, try gpa.dupe(u8, @embedFile("../tests/fixtures/kea/chats-legacy.json")), true);
    var chats = Chats.init(gpa, &store);
    defer chats.deinit();
    try std.testing.expectEqual(@as(usize, 3), chats.index.len);
    try std.testing.expectEqualStrings("Pelican facts", chats.index[0].title);
    try std.testing.expectEqualStrings("Tell me everything about the very long history of the kea bi", chats.index[1].title);
    try std.testing.expectEqualStrings("Ubi Chat", chats.index[2].title);
    try std.testing.expectEqual(@as(i64, 0), chats.index[2].turns);
    store.disk.drain();
    try std.testing.expect(store.readFile(Chats.legacy) == null);
    const index = store.readFile(Chats.index_file).?;
    defer gpa.free(index);
    try std.testing.expect(std.mem.startsWith(u8, index, "[{\"id\":\"AAAAAAAA-1111-4222-8333-444444444444\",\"starred\":true,\"task\":false,\"title\":\"Pelican facts\""));
    // The title that only repeated the first question is cleared.
    const long = chats.chat(try json.Uuid.parse("FFFFFFFF-1111-4222-8333-444444444444")).?;
    try std.testing.expectEqualStrings("", long.title);
    try std.testing.expect(long.pageHidden);
    const pel = chats.chat(chats.index[0].id).?;
    try std.testing.expectEqualStrings("- asked about pelicans", pel.summary.?);
    // A second launch reads the index, not the legacy file.
    var again = Chats.init(gpa, &store);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 3), again.index.len);
}

test "chat LRU keeps 8 and reads the rest from disk" {
    var t: Temp = undefined;
    var store = try open(&t);
    defer t.deinit(gpa);
    defer store.deinit();
    var chats = Chats.init(gpa, &store);
    defer chats.deinit();
    try std.testing.expectEqual(@as(usize, 0), chats.index.len);
    var ids: [10]json.Uuid = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = json.Uuid.random();
        const turn: cs.Turn = .{ .id = json.Uuid.random(), .question = "Why?" };
        chats.put(.{ .id = id.*, .touched = @floatFromInt(i), .turns = if (i % 2 == 0) &.{turn} else &.{} });
    }
    try std.testing.expectEqual(@as(usize, Chats.held), chats.recent.items.len);
    try std.testing.expect(chats.recent.items[0].value.id.eql(ids[2]));
    try std.testing.expect(chats.index[0].id.eql(ids[9]));
    // Not held: read back from its file.
    const first = chats.chat(ids[0]).?;
    try std.testing.expectEqualStrings("Why?", first.turns[0].question);
    try std.testing.expect(chats.recent.items[Chats.held - 1].value.id.eql(ids[0]));
    // A change that keeps the row leaves the index alone; a new title changes it.
    var renamed = first;
    renamed.title = "Named";
    chats.put(renamed);
    try std.testing.expectEqualStrings("Named", chats.index[9].title);
    try std.testing.expectEqual(@as(usize, 5), chats.sweepEmpty());
    try std.testing.expectEqual(@as(usize, 5), chats.index.len);
    chats.remove(ids[0]);
    try std.testing.expectEqual(@as(usize, 4), chats.index.len);
    try std.testing.expect(chats.chat(ids[0]) == null);
    store.disk.drain();
    var buf: [64]u8 = undefined;
    try std.testing.expect(store.readFile(Chats.fileName(&buf, ids[1])) == null);
    var again = Chats.init(gpa, &store);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 4), again.index.len);
}

test "unreadable index is set aside and rebuilt from chat files" {
    var t: Temp = undefined;
    var store = try open(&t);
    defer t.deinit(gpa);
    defer store.deinit();
    var buf: [64]u8 = undefined;
    const id = try json.Uuid.parse("AAAAAAAA-1111-4222-8333-444444444444");
    store.write(Chats.fileName(&buf, id), try gpa.dupe(u8, chat_fixture), true);
    store.write("chats/BBBBBBBB-0000-4000-8000-000000000000.json", try gpa.dupe(u8, "{nope"), true);
    store.write(Chats.index_file, try gpa.dupe(u8, "[broken"), true);
    var chats = Chats.init(gpa, &store);
    defer chats.deinit();
    try std.testing.expectEqual(@as(usize, 1), chats.index.len);
    try std.testing.expectEqualStrings("Pelican facts", chats.index[0].title);
    try std.testing.expectEqual(@as(i64, 2), chats.index[0].turns);
    try std.testing.expect(store.readFile("chats/BBBBBBBB-0000-4000-8000-000000000000.json") == null);
    // A file gone from under the index takes its row with it.
    const path = try store.file(Chats.fileName(&buf, id));
    defer gpa.free(path);
    store.disk.remove(path);
    store.disk.drain();
    try std.testing.expect(chats.recent.items.len == 0);
    try std.testing.expect(chats.chat(id) == null);
    try std.testing.expectEqual(@as(usize, 0), chats.index.len);
}
