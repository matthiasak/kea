//! `History` against its file: fixtures, the cap, coalescing, and the
//! HistoryRegression cases carried over from the first Kea history.
const std = @import("std");
const nanoui = @import("nanoui");
const json = @import("json.zig");
const Store = @import("store.zig").Store;
const Temp = @import("../tests/temp.zig").Temp;
const history = @import("history.zig");
const History = history.History;
const Visit = history.Visit;
const testing = std.testing;
const gpa = testing.allocator;

const Rig = struct {
    t: Temp,
    store: Store,
    h: History,

    fn init(r: *Rig, file: ?[]const u8) !void {
        r.t = try Temp.init(gpa);
        r.store = try Store.init(gpa, r.t.root, r.t.suite);
        if (file) |bytes| r.store.write(history.file_name, try gpa.dupe(u8, bytes), true);
        r.h.init(gpa, &r.store);
    }

    fn deinit(r: *Rig) void {
        r.h.deinit();
        r.store.disk.drain();
        r.store.deinit();
        r.t.deinit(gpa);
    }

    /// The file as it stands once every write has landed.
    fn saved(r: *Rig) !std.json.Parsed([]Visit) {
        r.store.disk.drain();
        return r.store.load([]Visit, history.file_name) orelse error.NoFile;
    }
};

fn find(list: []const Visit, key: []const u8) ?Visit {
    for (list) |v| if (std.mem.eql(u8, v.key, key)) return v;
    return null;
}

test "history fixture round-trips" {
    const fixture = @embedFile("../tests/fixtures/kea/history.json");
    const a = try json.decode([]Visit, gpa, fixture);
    defer a.deinit();
    const out = try json.encode(gpa, a.value);
    defer gpa.free(out);
    const b = try json.decode([]Visit, gpa, out);
    defer b.deinit();
    try testing.expectEqual(@as(usize, 5), a.value.len);
    for (a.value, b.value) |x, y| {
        try testing.expectEqualStrings(x.url, y.url);
        try testing.expectEqualStrings(x.key, y.key);
        try testing.expectEqualStrings(x.title, y.title);
        try testing.expectEqual(x.count, y.count);
        try testing.expectEqual(x.last, y.last);
    }
    // Every field is required, as synthesized Codable has it.
    try testing.expectError(error.MissingField, json.decode([]Visit, gpa, "[{\"url\":\"https://a.com/\",\"key\":\"k\",\"title\":\"\",\"count\":1}]"));

    // Loaded, flushed and read back, nothing is lost.
    var r: Rig = undefined;
    try r.init(fixture);
    defer r.deinit();
    r.h.retitle("https://github.com/", "GitHub!");
    r.h.flush();
    const back = try r.saved();
    defer back.deinit();
    try testing.expectEqual(@as(usize, 5), back.value.len);
    try testing.expectEqualStrings("GitHub!", find(back.value, "https://github.com/").?.title);
    try testing.expectEqualStrings("He said \"hi\" — ziglang/zig", find(back.value, "https://github.com/ziglang/zig").?.title);
    try testing.expectEqual(@as(f64, 782000000.25), find(back.value, "https://github.com/").?.last);
}

test "history legacy file: merged, cleaned, clamped, rehomed" {
    var r: Rig = undefined;
    try r.init(@embedFile("../tests/fixtures/kea/history-legacy.json"));
    defer r.deinit();
    // Credentials come off at load, and the file is written again for it.
    try testing.expect(r.h.saving != null);
    r.h.flush();
    const back = try r.saved();
    defer back.deinit();
    const raw = r.store.readFile(history.file_name).?;
    defer gpa.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "secret") == null);
    const inbox = find(back.value, "https://example.com/inbox").?;
    try testing.expectEqual(@as(i64, 5), inbox.count);
    try testing.expectEqual(@as(f64, 781000000), inbox.last);
    try testing.expectEqualStrings("Inbox", inbox.title);
    try testing.expectEqualStrings("https://EXAMPLE.com/inbox#top", inbox.url);
    try testing.expectEqual(@as(i64, 1_000_000_000), find(back.value, "https://huge.example/").?.count);
    try testing.expectEqual(@as(i64, 0), find(back.value, "https://neg.example/").?.count);

    // The old credit moves to the front door its pages used once indexed.
    r.h.ensureIndexed();
    try testing.expect(r.h.visits.get("https://news.site/") == null);
    const door = r.h.visits.get("https://www.news.site/").?.visit;
    try testing.expectEqual(@as(i64, 5), door.count);
    try testing.expectEqualStrings("https://www.news.site/", door.url);
}

test "garbage history is quarantined and starts empty" {
    var r: Rig = undefined;
    try r.init("[{\"url\":");
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.h.visits.count());
    try testing.expect(r.store.readFile(history.file_name) == null);
}

test "a title He said \"hi\" saves and reloads" {
    var r: Rig = undefined;
    try r.init(null);
    defer r.deinit();
    r.h.record("https://quotes.example/a", "He said \"hi\"");
    r.h.flush();
    var again: History = undefined;
    again.init(gpa, &r.store);
    defer again.deinit();
    again.ensureIndexed();
    try testing.expectEqualStrings("He said \"hi\"", again.visits.get("https://quotes.example/a").?.visit.title);
}

test "history save is coalesced 1.5 s" {
    var r: Rig = undefined;
    try r.init(null);
    defer r.deinit();
    r.h.record("https://one.example/", "One");
    const first = r.h.saving.?;
    r.h.record("https://two.example/", "Two");
    r.h.record("https://two.example/", "Two");
    try testing.expectEqual(first, r.h.saving.?);
    r.store.disk.drain();
    try testing.expect(r.store.readFile(history.file_name) == null);
    nanoui.runFor(1.0);
    r.store.disk.drain();
    try testing.expect(r.store.readFile(history.file_name) == null);
    nanoui.runFor(0.8);
    try testing.expect(r.h.saving == null);
    const back = try r.saved();
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.value.len);
    try testing.expectEqual(@as(i64, 2), find(back.value, "https://two.example/").?.count);
}

test "history file keeps the best 2000" {
    var r: Rig = undefined;
    try r.init(null);
    defer r.deinit();
    const now = json.now();
    var i: usize = 0;
    while (i < history.cap + 5) : (i += 1) {
        var buf: [64]u8 = undefined;
        // The first five are the least visited and the longest ago.
        const old = i < 5;
        r.h.take(try std.fmt.bufPrint(&buf, "https://site{d}.example/", .{i}), "", if (old) 1 else 10, if (old) now - 400 * 86_400 else now);
    }
    r.h.settle();
    r.h.flush();
    const back = try r.saved();
    defer back.deinit();
    try testing.expectEqual(@as(usize, history.cap), back.value.len);
    try testing.expect(find(back.value, "https://site0.example/") == null);
    try testing.expect(find(back.value, "https://site4.example/") == null);
    try testing.expect(find(back.value, "https://site5.example/") != null);
    const exported = try r.h.exported(gpa);
    defer gpa.free(exported);
    try testing.expectEqual(@as(usize, history.cap), exported.len);
    try testing.expect(std.mem.lessThan(u8, exported[0].key, exported[1].key));
}

test "HistoryRegression: canonical identity, credentials, ranking, and flush" {
    var r: Rig = undefined;
    try r.init(null);
    defer r.deinit();

    // 1. Identity keeps the port and query, drops the fragment.
    r.h.record("https://www.Example.com:8080/Path?a=1#frag", "Port One");
    r.h.record("https://example.com:9090/Path?a=1#frag", "Port Two");
    try testing.expect(r.h.visits.get("https://www.example.com:8080/Path?a=1") != null);
    try testing.expect(r.h.visits.get("https://example.com:9090/Path?a=1") != null);
    // Each deep page also credits its front door.
    try testing.expectEqual(@as(i64, 1), r.h.visits.get("https://www.example.com:8080/").?.visit.count);

    // 2. Credentials never reach memory or disk.
    r.h.record("https://user:secretPass123@secure.example.org/vault", "Vault");
    r.h.flush();
    r.store.disk.drain();
    const raw = r.store.readFile(history.file_name).?;
    defer gpa.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "secretPass123") == null);
    try testing.expect(std.mem.indexOf(u8, raw, "https://secure.example.org/vault") != null);

    // 3. Completion finishes www sites without www.
    r.h.record("https://www.wikipedia.org/wiki/Zig", "Zig Wiki");
    const sugs = try r.h.suggestions(gpa, "wiki", 5);
    defer gpa.free(sugs);
    try testing.expectEqualStrings("www.wikipedia.org", sugs[0].key);
    try testing.expectEqualStrings("pedia.org", (try r.h.completion("wiki", sugs)).?);

    // 4. A match at the start beats one past a dot; never into the last label.
    try testing.expectEqual(@as(?f64, 6), history.rank("com.example.org", "com"));
    try testing.expectEqual(@as(?f64, null), history.rank("other.com", "com"));
}

test "history suggestions, known places and completion" {
    var r: Rig = undefined;
    try r.init(null);
    defer r.deinit();
    // Nothing visited: the well-known names, ranked by where the match falls.
    const first = try r.h.suggestions(gpa, "gi", 5);
    defer gpa.free(first);
    try testing.expectEqualStrings("github.com", first[0].key);
    try testing.expectEqual(history.Suggestion.Kind.known, first[0].kind);
    try testing.expectEqualStrings("thub.com", (try r.h.completion("gi", first)).?);
    try testing.expect(try r.h.completion("g", first) == null);
    try testing.expectEqual(@as(usize, 0), (try r.h.suggestions(gpa, "  ", 5)).len);

    // Visited, it is offered as a visit and the known row steps aside.
    r.h.record("https://github.com/ziglang/zig", "ziglang/zig: General-purpose language");
    const after = try r.h.suggestions(gpa, "gi", 5);
    defer gpa.free(after);
    try testing.expectEqualStrings("github.com", after[0].key);
    try testing.expectEqual(history.Suggestion.Kind.visited, after[0].kind);
    for (after) |s| try testing.expect(!std.mem.eql(u8, s.url, "https://github.com"));
    // Titles from three letters, below every address match.
    const by_title = try r.h.suggestions(gpa, "general purpose", 5);
    defer gpa.free(by_title);
    try testing.expectEqualStrings("github.com/ziglang/zig", by_title[0].key);
}

test "history recent, everything, retitle and forget" {
    var r: Rig = undefined;
    try r.init(null);
    defer r.deinit();
    const now = json.now();
    r.h.take("https://a.example/one", "One", 1, now - 30);
    r.h.take("https://b.example/two", "Two", 1, now - 20);
    r.h.take("https://c.example/", "", 4, now - 10);
    r.h.take("https://c.example/", "Ignored", 2, now - 50);
    try testing.expectEqualStrings("Ignored", r.h.visits.get("https://c.example/").?.visit.title);
    try testing.expectEqual(@as(i64, 4), r.h.visits.get("https://c.example/").?.visit.count);

    const recent = r.h.recent();
    try testing.expectEqual(@as(usize, 3), recent.len);
    try testing.expectEqualStrings("c.example", recent[0].address);
    try testing.expect(r.h.recent().ptr == recent.ptr);

    r.h.retitle("https://a.example/one#x", "Uno");
    try testing.expectEqualStrings("Uno", r.h.visits.get("https://a.example/one").?.visit.title);
    const all = try r.h.everything(gpa, "UNO", 10);
    defer gpa.free(all);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqualStrings("a.example/one", all[0].address);

    r.h.forgetBefore(now - 25);
    try testing.expect(r.h.visits.get("https://a.example/one") == null);
    r.h.forgetKeyBefore("https://b.example/two", now - 100);
    try testing.expect(r.h.visits.get("https://b.example/two") != null);
    r.h.forget("https://b.example/two");
    try testing.expectEqual(@as(usize, 1), r.h.visits.count());
    try testing.expect(r.h.visited_hosts.get("b.example") == null);
    r.h.forgetAll();
    try testing.expectEqual(@as(usize, 0), r.h.visits.count());
    try testing.expectEqual(@as(usize, 0), r.h.recent().len);
}

test "history absorb keeps what says more" {
    var r: Rig = undefined;
    try r.init(null);
    defer r.deinit();
    r.h.take("https://a.example/x", "Mine", 5, 100);
    r.h.absorb(&.{
        .{ .url = "https://a.example/x", .key = "https://a.example/x", .title = "Theirs", .count = 3, .last = 50 },
        .{ .url = "https://b.example/y", .key = "https://b.example/y", .title = "New", .count = 2, .last = 70 },
    });
    const a = r.h.visits.get("https://a.example/x").?.visit;
    try testing.expectEqualStrings("Mine", a.title);
    try testing.expectEqual(@as(i64, 5), a.count);
    try testing.expectEqual(@as(i64, 2), r.h.visits.get("https://b.example/y").?.visit.count);
    try testing.expect(r.h.saving != null);
}
