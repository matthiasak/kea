//! One round with the store (`tick` in Sync.swift): note what changed here,
//! take in every other Mac's newer files, write this Mac's, empty the inbox.
//! On Sync's queue (tests: the caller's thread); the app's stores only
//! through `onMain`.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const core = @import("core.zig");
const kinds = @import("kinds.zig");
const Drop = @import("drop.zig").Drop;
const sync_mod = @import("sync.zig");
const Sync = sync_mod.Sync;
const onMain = sync_mod.onMain;

const Allocator = std.mem.Allocator;
const SwiftDate = json.SwiftDate;
const Kind = kinds.Kind;

/// `DecodingError`'s words.
const unreadable = "The data couldn't be read because it isn't in the correct format.";
const devices_prefix = "kea/v1/devices/";

const Snap = struct {
    place: sync_mod.Place,
    kinds: sync_mod.Kinds,
    key: ?core.Key,
    drop: ?Drop,
    device: json.Uuid,
    name: []const u8,
};

fn snapshot(s: *Sync) Snap {
    return .{
        .place = s.place,
        .kinds = s.kinds,
        .key = s.key,
        .drop = if (s.place != .off and s.key != null) s.drop() else null,
        .device = s.device,
        .name = s.name,
    };
}

fn say(s: *Sync, text: []const u8) void {
    onMain(void, Sync.setStatus, .{ s, text });
}

pub fn tick(s: *Sync) void {
    const snap = onMain(Snap, snapshot, .{s});
    if (snap.place == .off) return say(s, "Off");
    const key = snap.key orelse return say(s, "Type the passphrase");
    var d = snap.drop orelse return say(s, if (snap.place == .folder) "Choose a folder" else "Set up the bucket");
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    round(s, arena.allocator(), &d, key, &snap) catch |e| say(s, switch (e) {
        error.SyncFailed => d.why,
        error.Damaged => core.damaged,
        error.OutOfMemory => "Out of memory",
        else => unreadable,
    });
}

fn sortedKeys(a: Allocator, keys: []const []const u8) ![]const []const u8 {
    const out = try a.dupe([]const u8, keys);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out;
}

/// The kind's ledger in `state`, made when missing. Valid until the next one is made.
fn ledgerFor(s: *Sync, kind: Kind) !*core.SyncLedger {
    const sa = s.state.arena.allocator();
    const gop = try s.state.value.ledgers.map.getOrPut(sa, @tagName(kind));
    if (!gop.found_existing) {
        gop.key_ptr.* = try sa.dupe(u8, @tagName(kind));
        gop.value_ptr.* = .{};
    }
    return gop.value_ptr;
}

fn records(s: *Sync, kind: Kind, a: Allocator) !core.Records {
    return onMain(anyerror!core.Records, kinds.records, .{ s, kind, a });
}

fn stampAll(s: *Sync, a: Allocator, snap: *const Snap, now: SwiftDate) !void {
    for (kinds.record_kinds) |kind| if (snap.kinds.contains(kind)) {
        const current = try records(s, kind, a);
        try core.stamp(s.state.arena.allocator(), &current, try ledgerFor(s, kind), now);
    };
}

/// Another Mac's records put in place, its removals made (`Sync.applying`).
fn applyTaken(s: *Sync, kind: Kind, taken: *const core.Taken, joining: bool, ledger: *core.SyncLedger, a: Allocator) !void {
    s.applying = true;
    defer s.applying = false;
    for (try sortedKeys(a, taken.put.map.keys())) |k| try kinds.apply(s, kind, k, taken.put.map.get(k).?.data.bytes, joining, a);
    for (try sortedKeys(a, taken.remove.map.keys())) |k| {
        kinds.removeRecord(s, kind, k);
        try core.removed(s.state.arena.allocator(), k, taken.remove.map.get(k).?, ledger);
    }
}

fn applyHistory(s: *Sync, doc: kinds.HistoryDoc, a: Allocator) !void {
    return kinds.applyHistory(s, doc, a);
}

/// This Mac's history doc, encoded while the visits it borrows hold.
fn historyDoc(s: *Sync, a: Allocator) ![]u8 {
    const st = &s.state.value;
    return json.encodeSorted(a, kinds.HistoryDoc{ .visits = try s.kea.history.exported(a), .cleared = st.cleared, .forgot = st.forgot });
}

fn putIfChanged(s: *Sync, a: Allocator, d: *Drop, key: core.Key, name: []const u8, plain: []const u8) !void {
    const h = core.hash(plain);
    if (s.wrote.get(name)) |w| if (std.mem.eql(u8, &w, &h)) return;
    try d.put(a, name, try core.seal(a, plain, key));
    try remember(s, &s.wrote, name, h);
}

fn remember(s: *Sync, map: anytype, name: []const u8, v: anytype) !void {
    const gop = try map.getOrPut(s.gpa, name);
    if (!gop.found_existing) gop.key_ptr.* = try s.names.allocator().dupe(u8, name);
    gop.value_ptr.* = v;
}

fn round(s: *Sync, a: Allocator, d: *Drop, key: core.Key, snap: *const Snap) !void {
    const now = json.now();
    _ = s.takePending();
    if (s.state.value.joined) try stampAll(s, a, snap, now);

    const names = try d.list(a, devices_prefix);
    for (try sortedKeys(a, names.keys())) |name| {
        const changed = names.get(name).?;
        if (s.seen.get(name)) |was| if (was == changed) continue;
        if (!std.mem.startsWith(u8, name, devices_prefix)) continue;
        var parts = std.mem.splitScalar(u8, name[devices_prefix.len..], '/');
        const id_part = parts.next() orelse continue;
        const file = parts.next() orelse continue;
        if (parts.next() != null) continue;
        const other = json.Uuid.parse(id_part) catch continue;
        if (other.eql(snap.device) or !std.mem.endsWith(u8, file, ".kea")) continue;
        const kind = std.meta.stringToEnum(Kind, file[0 .. file.len - 4]) orelse continue;

        if (kind != .tabs and !snap.kinds.contains(kind)) continue;
        const sealed = (try d.get(a, name)) orelse continue;
        const plain = try core.open(a, sealed, key);

        switch (kind) {
            .bookmarks, .places, .settings, .chats => {
                const doc = try json.decode(core.SyncDoc, a, plain);
                const ledger = try ledgerFor(s, kind);
                const taken = try core.take(a, &doc.value, ledger);
                try onMain(anyerror!void, applyTaken, .{ s, kind, &taken, !s.state.value.joined, ledger, a });
                const after = try records(s, kind, a);
                var it = taken.put.map.iterator();
                while (it.next()) |e| try core.settle(s.state.arena.allocator(), e.key_ptr.*, after.get(e.key_ptr.*), e.value_ptr.*, ledger, now);
            },
            .history => {
                const doc = try json.decode(kinds.HistoryDoc, a, plain);
                try onMain(anyerror!void, applyHistory, .{ s, doc.value, a });
            },
            .tabs => {
                const doc = try json.decode(kinds.TabsDoc, s.gpa, plain);
                const gop = s.others.getOrPut(s.gpa, other) catch |e| {
                    doc.deinit();
                    return e;
                };
                if (gop.found_existing) gop.value_ptr.deinit();
                gop.value_ptr.* = doc;
            },
        }
        try remember(s, &s.seen, name, changed);
    }

    if (!s.state.value.joined) {
        try stampAll(s, a, snap, now);
        s.state.value.joined = true;
    }

    for (kinds.record_kinds) |kind| if (snap.kinds.contains(kind)) {
        const current = try records(s, kind, a);
        const plain = try json.encodeSorted(a, try core.doc(a, &current, try ledgerFor(s, kind), now));
        try putIfChanged(s, a, d, key, try std.fmt.allocPrint(a, "{s}{f}/{s}.kea", .{ devices_prefix, snap.device, @tagName(kind) }), plain);
    };

    if (snap.kinds.contains(.history)) {
        const forgot = &s.state.value.forgot.map;
        var i: usize = 0;
        while (i < forgot.count()) {
            if (forgot.values()[i] < now - core.keep_gone) forgot.swapRemoveAt(i) else i += 1;
        }
        const plain = try onMain(anyerror![]u8, historyDoc, .{ s, a });
        try putIfChanged(s, a, d, key, try std.fmt.allocPrint(a, "{s}{f}/history.kea", .{ devices_prefix, snap.device }), plain);
    }

    const windows: []const []const kinds.SyncTab = if (snap.kinds.contains(.tabs))
        try onMain(anyerror![]const []const kinds.SyncTab, kinds.windows, .{ s, a })
    else
        &.{};
    var check: std.ArrayList(u8) = .empty;
    try check.appendSlice(a, try json.encodeSorted(a, windows));
    try check.appendSlice(a, snap.name);
    const tabs_hash = core.hash(check.items);
    const tabs_name = try std.fmt.allocPrint(a, "{s}{f}/tabs.kea", .{ devices_prefix, snap.device });
    const same = if (s.wrote.get(tabs_name)) |w| std.mem.eql(u8, &w, &tabs_hash) else false;
    if (!same or now - s.last_tabs_write >= 600) {
        const plain = try json.encodeSorted(a, kinds.TabsDoc{ .name = snap.name, .at = now, .windows = windows });
        try d.put(a, tabs_name, try core.seal(a, plain, key));
        try remember(s, &s.wrote, tabs_name, tabs_hash);
        s.last_tabs_write = now;
    }

    const inbox_prefix = try std.fmt.allocPrint(a, "kea/v1/inbox/{f}/", .{snap.device});
    const inbox = try d.list(a, inbox_prefix);
    for (try sortedKeys(a, inbox.keys())) |item| {
        if (try d.get(a, item)) |sealed| if (core.open(a, sealed, key)) |plain| {
            if (json.decode(kinds.SentTab, a, plain)) |sent| {
                if (kinds.webAddress(sent.value.url)) onMain(void, kinds.openSent, .{ s, sent.value });
            } else |_| {}
        } else |_| {};
        d.delete(a, item) catch {};
    }

    var da: std.heap.ArenaAllocator = .init(s.gpa);
    const devices = devicesSeen(s, da.allocator(), now) catch |e| {
        da.deinit();
        return e;
    };
    onMain(void, publish, .{ s, da, devices });

    say(s, try std.fmt.allocPrint(a, "Synced {s}", .{try relative(a, now)}));
    s.saveState(s.inline_jobs);
    if (s.inline_jobs) s.kea.store.disk.drain();
}

/// Other Macs heard from within 30 days, newest first; on `da`.
fn devicesSeen(s: *Sync, da: Allocator, now: SwiftDate) ![]const sync_mod.Device {
    var list: std.ArrayList(sync_mod.Device) = .empty;
    for (s.others.keys(), s.others.values()) |id, p| {
        const doc = p.value;
        if (doc.at < now - 30 * 86_400) continue;
        var pages: std.ArrayList(sync_mod.Device.Page) = .empty;
        for (doc.windows) |w| for (w) |t| if (kinds.webAddress(t.url))
            try pages.append(da, .{ .title = try da.dupe(u8, t.title), .url = try da.dupe(u8, t.url) });
        try list.append(da, .{ .id = id, .name = try da.dupe(u8, doc.name), .seen = doc.at, .pages = pages.items });
    }
    std.mem.sort(sync_mod.Device, list.items, {}, struct {
        fn newer(_: void, x: sync_mod.Device, y: sync_mod.Device) bool {
            return x.seen > y.seen;
        }
    }.newer);
    return list.items;
}

fn publish(s: *Sync, da: std.heap.ArenaAllocator, devices: []const sync_mod.Device) void {
    s.devices_arena.deinit();
    s.devices_arena = da;
    s.devices = devices;
    for (s.kea.browsers.items) |b| b.redraw();
}

/// `RelativeDateTimeFormatter().localizedString(for:relativeTo: Date())`.
fn relative(a: Allocator, date: SwiftDate) ![]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const f = objc.msg(objc.Object, objc.class("NSRelativeDateTimeFormatter"), "new", .{});
    defer objc.release(f);
    const when = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceReferenceDate:", .{date});
    const now = objc.msg(objc.Object, objc.class("NSDate"), "date", .{});
    return a.dupe(u8, objc.fromNSString(objc.msg(objc.Object, f, "localizedStringForDate:relativeToDate:", .{ when, now })));
}
