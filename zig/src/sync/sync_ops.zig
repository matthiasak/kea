//! Unlocking a store and getting out of trouble (sync.zig): what the place
//! holds is looked at first — an empty place gets a new store, a store is
//! joined with its passphrase or this Mac's account key, a v1 store is
//! upgraded, and nothing is written over someone else's files or a
//! damaged store until you say so. Main-thread entry points post jobs;
//! the jobs run on Sync's queue.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const core = @import("core.zig");
const keyring = @import("keyring.zig");
const inspect = @import("inspect.zig");
const Drop = @import("drop.zig").Drop;
const disk = @import("../data/disk.zig");
const sync_mod = @import("sync.zig");
const drive = @import("sync_drive.zig");
const tick_mod = @import("tick.zig");
const Browser = @import("../model/browser.zig").Browser;

const Sync = sync_mod.Sync;
const onMain = sync_mod.onMain;
const dupe = sync_mod.dupe;
const replace = sync_mod.replace;
const Allocator = std.mem.Allocator;

pub const How = union(enum) { pass: []u8, account: keyring.AccountKey };
pub const Intent = enum { join, overwrite, salvage };
pub const Unlock = struct { how: How, drop: Drop, identity: []u8, browser: ?*Browser, intent: Intent = .join, held: ?keyring.StoreKey = null };
pub const Enroll = struct { how: How, drop: Drop, browser: ?*Browser };
pub const Sent = struct { drop: Drop, name: []u8, sealed: []u8, to: []u8, browser: *Browser };

pub const uses_account_key = "This sync store uses an Account Key — switch to Account Key to join";
pub const wrong_account_key = "This Mac's Account Key doesn't match this sync store — import the key or use its passphrase";
pub const has_other_files = "Folder has other files — create a Kea Sync subfolder or confirm in Settings";
pub const store_damaged = "Sync store is damaged — repair or archive & overwrite in Settings";

fn freeHow(gpa: Allocator, how: How) void {
    if (how == .pass) {
        std.crypto.secureZero(u8, how.pass);
        gpa.free(how.pass);
    }
}

// MARK: main thread

/// null when kept, else what to say.
pub fn useBucket(self: *Sync, endpoint: []const u8, bucket: []const u8, access: []const u8, secret: []const u8) ?[]const u8 {
    const ws = " \t\r\n";
    const ep = std.mem.trim(u8, endpoint, ws);
    const bk = std.mem.trim(u8, bucket, ws);
    const ac = std.mem.trim(u8, access, ws);
    const sc = std.mem.trim(u8, secret, ws);
    if (!Drop.allowed(ep)) return "Use an https address (http only on this Mac)";
    if (bk.len == 0 or ac.len == 0 or sc.len == 0) return "Fill in the bucket, access key and secret";
    replace(self.gpa, &self.endpoint, ep);
    self.kea.store.setString("sync.endpoint", ep);
    replace(self.gpa, &self.bucket, bk);
    self.kea.store.setString("sync.bucket", bk);
    replace(self.gpa, &self.access, ac);
    self.kea.store.setString("sync.access", ac);
    const copy = dupe(self.gpa, sc);
    if (self.secret) |old| self.gpa.free(old);
    self.secret = copy;
    if (!self.testing()) sync_mod.saveKeychain("secret", sc);
    self.moved(.bucket);
    return null;
}

/// Tabs › Send to Device.
pub fn send(self: *Sync, url: []const u8, title: []const u8, to: *const sync_mod.Device, browser: *Browser) void {
    const sk = self.subkeys orelse return browser.announce("Set up Sync in Settings first");
    if (!self.ready or !@import("kinds.zig").webAddress(url)) return browser.announce("Set up Sync in Settings first");
    var d = self.drop() orelse return browser.announce("Set up Sync in Settings first");
    const name = std.fmt.allocPrint(self.gpa, "kea/v2/inbox/{f}/{f}.kea", .{ to.id, json.Uuid.random() }) catch @panic("OOM");
    const sealed = blk: {
        const plain = json.encodeSorted(self.gpa, @import("kinds.zig").SentTab{ .url = url, .title = title, .from = self.name, .at = json.now() }) catch break :blk null;
        defer self.gpa.free(plain);
        break :blk keyring.sealObject(self.gpa, plain, sk, name) catch null;
    } orelse {
        d.deinit();
        self.gpa.free(name);
        return browser.announce(core.damaged);
    };
    self.post(.{ .send = .{ .drop = d, .name = name, .sealed = sealed, .to = dupe(self.gpa, to.name), .browser = browser } });
}

fn postUnlock(self: *Sync, how: How, browser: ?*Browser, intent: Intent) ?[]const u8 {
    const d = self.drop() orelse {
        freeHow(self.gpa, how);
        return self.missingPlace();
    };
    self.post(.{ .unlock = .{ .how = how, .drop = d, .identity = self.storeIdentity(), .browser = browser, .intent = intent, .held = self.store_key } });
    return null;
}

/// Opens (or, the first time, makes) the store with `passphrase`. What
/// can be said at once comes back; the rest lands in `status` and is
/// announced in `browser`.
pub fn use(self: *Sync, passphrase: []const u8, browser: ?*Browser) ?[]const u8 {
    if (passphrase.len == 0) return "Type a passphrase";
    return postUnlock(self, .{ .pass = dupe(self.gpa, passphrase) }, browser, .join);
}

/// The same with this Mac's account key, made the first time.
pub fn useAccountKey(self: *Sync, browser: ?*Browser) ?[]const u8 {
    const ak = self.accountKey() orelse return "The keychain refused the account key";
    return postUnlock(self, .{ .account = ak }, browser, .join);
}

/// This Mac's account key, made and kept the first time it is asked for.
pub fn accountKey(self: *Sync) ?keyring.AccountKey {
    if (!self.testing()) return keyring.ensureKeychainAccountKey(self.gpa);
    if (self.test_account_key == null) self.test_account_key = keyring.randomKey();
    return self.test_account_key;
}

/// This Mac's account key if it has one; never makes one.
pub fn knownAccountKey(self: *Sync) ?keyring.AccountKey {
    return if (self.testing()) self.test_account_key else keyring.loadKeychainAccountKey(self.gpa);
}

fn credential(self: *Sync, passphrase: ?[]const u8) union(enum) { ok: How, say: []const u8 } {
    if (self.key_mode == .account_key) return .{ .ok = .{ .account = self.accountKey() orelse return .{ .say = "The keychain refused the account key" } } };
    const p = passphrase orelse "";
    if (p.len == 0) return .{ .say = "Type a passphrase" };
    return .{ .ok = .{ .pass = dupe(self.gpa, p) } };
}

/// Other files in the place are fine: the store goes beside them.
pub fn confirmUseNonEmpty(self: *Sync, browser: ?*Browser) void {
    const id = self.storeIdentity();
    defer self.gpa.free(id);
    replace(self.gpa, &self.allow_non_empty_for, id);
    self.kea.store.setString("sync.allow_non_empty", id);
    if (self.key_mode == .account_key) {
        if (useAccountKey(self, browser)) |say| self.failMain(say, browser);
    } else self.setStatus("Type the passphrase");
}

/// A fresh "Kea Sync" folder inside the chosen one, used instead.
pub fn createSubfolderAndUse(self: *Sync, browser: ?*Browser) void {
    switch (self.place) {
        .folder => {
            const path = std.fmt.allocPrint(self.gpa, "{s}/Kea Sync", .{std.mem.trimEnd(u8, self.folder, "/")}) catch return;
            defer self.gpa.free(path);
            disk.makePath(self.gpa, path);
            self.chooseFolder(path);
            if (self.key_mode == .account_key) if (useAccountKey(self, browser)) |say| self.failMain(say, browser);
        },
        .drive => drive.subfolder(self, browser),
        .off, .bucket => self.announceMain("A bucket has no folders — sync here anyway instead", browser),
    }
}

/// The store there archived and replaced by a new one holding this Mac's data.
pub fn overwriteExistingStore(self: *Sync, passphrase: ?[]const u8, browser: ?*Browser) ?[]const u8 {
    return switch (credential(self, passphrase)) {
        .say => |s| s,
        .ok => |h| postUnlock(self, h, browser, .overwrite),
    };
}

/// A new keyring for the store's own key, which this Mac still holds.
pub fn salvageStore(self: *Sync, passphrase: ?[]const u8, browser: ?*Browser) ?[]const u8 {
    if (self.store_key == null) return "This Mac doesn't hold this store's key — archive & reset it instead";
    return switch (credential(self, passphrase)) {
        .say => |s| s,
        .ok => |h| postUnlock(self, h, browser, .salvage),
    };
}

/// Every pack this Mac points at read back, and all of its records written again.
pub fn repairStore(self: *Sync, browser: ?*Browser) void {
    _ = browser;
    self.post(.{ .tick = .{ .verify = true, .repair = true } });
}

pub fn restoreQuarantined(self: *Sync, browser: ?*Browser) void {
    const d = self.drop() orelse return self.announceMain(self.missingPlace(), browser);
    self.post(.{ .restore = .{ .drop = d, .browser = browser } });
}

/// A `kea-key-v1-…` key from another Mac, kept as this Mac's and used.
pub fn importAccountKey(self: *Sync, text: []const u8, browser: ?*Browser) ?[]const u8 {
    const ak = keyring.decodePortableKey(text) catch return "That isn't a Kea account key";
    if (self.testing()) self.test_account_key = ak else if (!keyring.saveKeychainAccountKey(ak)) return "The keychain refused the account key";
    self.setKeyMode(.account_key);
    if (self.place == .off) return null;
    return useAccountKey(self, browser);
}

pub fn enrollBackupPassword(self: *Sync, passphrase: []const u8, browser: ?*Browser) ?[]const u8 {
    if (passphrase.len == 0) return "Type a passphrase";
    return postEnroll(self, .{ .pass = dupe(self.gpa, passphrase) }, browser);
}

pub fn enrollBackupAccountKey(self: *Sync, browser: ?*Browser) ?[]const u8 {
    return postEnroll(self, .{ .account = self.accountKey() orelse return "The keychain refused the account key" }, browser);
}

fn postEnroll(self: *Sync, h: How, browser: ?*Browser) ?[]const u8 {
    const d = if (self.ready) self.drop() else null;
    const dd = d orelse {
        freeHow(self.gpa, h);
        return "Set up Sync first";
    };
    self.post(.{ .enroll = .{ .how = h, .drop = dd, .browser = browser } });
    return null;
}

/// Unlocked: the key kept (and, with `ring`, the keyring and the keychain's copy).
pub fn keyMain(s: *Sync, mk: keyring.StoreKey, ring: ?[]const u8) void {
    s.store_key = mk;
    s.subkeys = keyring.deriveSubkeys(mk);
    if (ring) |r| {
        setRing(s, r);
        if (!s.testing()) sync_mod.saveKeychain("store_key", &mk);
    }
    s.ready = true;
    s.setWarning("");
}

/// The keyring as now read or written, and what it says about this Mac's ways in.
pub fn setRing(s: *Sync, bytes: []const u8) void {
    if (s.ring_json) |old| s.gpa.free(old);
    s.ring_json = dupe(s.gpa, bytes);
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const ring = json.decode(keyring.Keyring, arena.allocator(), bytes) catch return;
    s.ring_has_password = ring.value.password_slot != null;
    s.ring_has_my_account_key = if (knownAccountKey(s)) |ak| keyring.hasAccountSlot(&ring.value, ak) else false;
    for (s.kea.browsers.items) |b| b.redraw();
}

pub fn setLocation(s: *Sync, st: inspect.LocationState) void {
    _ = s.inspect_arena.reset(.retain_capacity);
    const a = s.inspect_arena.allocator();
    s.location = switch (st) {
        .existing_v2 => |e| blk: {
            var copy = e;
            copy.keyring = json.clone(a, e.keyring) catch break :blk .unknown;
            break :blk .{ .existing_v2 = copy };
        },
        .non_empty_unrelated => |n| .{ .non_empty_unrelated = .{ .count = n.count, .sample = a.dupe(u8, n.sample) catch "" } },
        .inaccessible => |why| .{ .inaccessible = a.dupe(u8, why) catch "" },
        else => st,
    };
    for (s.kea.browsers.items) |b| b.redraw();
}

fn allowedHere(s: *Sync, identity: []const u8) bool {
    return std.mem.eql(u8, s.allow_non_empty_for, identity);
}

// MARK: the queue

pub fn runInspect(s: *Sync, given: Drop) void {
    var d = given;
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const st = inspect.inspect(arena.allocator(), &d, onMain(?keyring.AccountKey, knownAccountKey, .{s}));
    onMain(void, setLocation, .{ s, st });
    drive.keepTokens(s, &d);
}

pub fn runUnlock(s: *Sync, u: Unlock) void {
    var d = u.drop;
    defer {
        d.deinit();
        freeHow(s.gpa, u.how);
        s.gpa.free(u.identity);
    }
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    unlock(s, arena.allocator(), &d, u) catch |e| {
        const msg = switch (e) {
            error.SyncFailed => d.why,
            error.WrongPassphrase => core.wrong_passphrase,
            error.NoPasswordSlot => uses_account_key,
            error.WrongAccountKey => wrong_account_key,
            error.NeedsPassphrase => "This sync store needs its passphrase to upgrade — switch to Passphrase",
            error.NonEmpty => has_other_files,
            error.StoreDamaged => store_damaged,
            error.NoHeldKey => "This Mac doesn't hold this store's key — archive & reset it instead",
            error.OverwriteFailed => s.warning_error,
            error.Damaged => core.damaged,
            error.OutOfMemory => "Out of memory",
        };
        onMain(void, Sync.failMain, .{ s, msg, u.browser });
    };
    drive.keepTokens(s, &d);
}

const UnlockError = error{ SyncFailed, WrongPassphrase, NoPasswordSlot, WrongAccountKey, NeedsPassphrase, NonEmpty, StoreDamaged, NoHeldKey, OverwriteFailed, Damaged, OutOfMemory };

fn newRing(a: Allocator, s: *Sync, mk: keyring.StoreKey, h: How) ![]u8 {
    const ring = switch (h) {
        .pass => |p| try keyring.createWithPassword(a, mk, p),
        .account => |ak| try keyring.createWithAccountKey(a, mk, ak, s.name),
    };
    return json.encodeSorted(a, ring) catch error.OutOfMemory;
}

fn writeRing(a: Allocator, d: *Drop, bytes: []const u8) !void {
    try d.put(a, inspect.keyring_path, bytes);
    try d.put(a, inspect.keyring_bak_path, bytes);
}

fn unlock(s: *Sync, a: Allocator, d: *Drop, u: Unlock) UnlockError!void {
    const ak: ?keyring.AccountKey = if (u.how == .account) u.how.account else onMain(?keyring.AccountKey, knownAccountKey, .{s});
    const st = inspect.inspect(a, d, ak);
    onMain(void, setLocation, .{ s, st });
    switch (u.intent) {
        .join => {},
        .overwrite => {
            const mk = keyring.randomKey();
            const bytes = try newRing(a, s, mk, u.how);
            switch (inspect.overwriteStore(a, d, bytes)) {
                .ok => return opened(s, a, d, mk, bytes, u.identity, null),
                .failed => |msg| {
                    onMain(void, Sync.setWarning, .{ s, msg });
                    return error.OverwriteFailed;
                },
            }
        },
        .salvage => {
            const mk = u.held orelse return error.NoHeldKey;
            const bytes = try newRing(a, s, mk, u.how);
            try writeRing(a, d, bytes);
            return opened(s, a, d, mk, bytes, u.identity, null);
        },
    }
    switch (st) {
        .unknown, .inaccessible => return error.SyncFailed,
        .corrupted_store => return error.StoreDamaged,
        .non_empty_unrelated => if (!onMain(bool, allowedHere, .{ s, u.identity })) return error.NonEmpty else return fresh(s, a, d, u),
        .empty => return fresh(s, a, d, u),
        .existing_v2 => |e| {
            const mk = switch (u.how) {
                .pass => |p| try keyring.unlockWithPassword(a, &e.keyring, p),
                .account => |k| try keyring.unlockWithAccountKey(a, &e.keyring, k),
            };
            const bytes = json.encodeSorted(a, e.keyring) catch return error.OutOfMemory;
            // Found in a backup or a head: keyring.json written again.
            if (e.source != .primary) try writeRing(a, d, bytes);
            return opened(s, a, d, mk, bytes, u.identity, null);
        },
        .existing_v1 => {
            const pass = if (u.how == .pass) u.how.pass else return error.NeedsPassphrase;
            const salt = (try d.get(a, "kea/v1/salt")) orelse return error.StoreDamaged;
            const old = core.key(pass, salt);
            const check = (try d.get(a, "kea/v1/check")) orelse return error.WrongPassphrase;
            const plain = core.open(a, check, old) catch return error.WrongPassphrase;
            if (!std.mem.eql(u8, plain, "kea")) return error.WrongPassphrase;
            const mk = keyring.randomKey();
            const bytes = try newRing(a, s, mk, u.how);
            try writeRing(a, d, bytes);
            return opened(s, a, d, mk, bytes, u.identity, old);
        },
    }
}

fn fresh(s: *Sync, a: Allocator, d: *Drop, u: Unlock) UnlockError!void {
    const mk = keyring.randomKey();
    const bytes = try newRing(a, s, mk, u.how);
    try writeRing(a, d, bytes);
    return opened(s, a, d, mk, bytes, u.identity, null);
}

/// In: the key kept, this store's state begun afresh when it is another
/// store, a v1 store's files taken in, and the first round.
fn opened(s: *Sync, a: Allocator, d: *Drop, mk: keyring.StoreKey, ring: []const u8, identity: []const u8, legacy: ?core.Key) UnlockError!void {
    onMain(void, keyMain, .{ s, mk, @as(?[]const u8, ring) });
    // Another store (another place, or this one made anew): joined afresh,
    // every Mac's files read again.
    const full = std.fmt.allocPrint(a, "{s}#{s}", .{ identity, &keyring.deriveSubkeys(mk).key_id }) catch return error.OutOfMemory;
    if (!std.mem.eql(u8, s.state.value.store, full)) {
        s.setState(.{ .store = full }) catch return error.OutOfMemory;
        s.resetCaches();
    }
    if (legacy) |k| tick_mod.importLegacyV1(s, a, d, k) catch |e| switch (e) {
        error.SyncFailed, error.OutOfMemory => |x| return x,
        else => return error.Damaged,
    };
    tick_mod.tick(s, true, false);
}

pub fn runEnroll(s: *Sync, e: Enroll) void {
    var d = e.drop;
    defer {
        d.deinit();
        freeHow(s.gpa, e.how);
    }
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const said: []const u8 = enroll(s, a, &d, e.how) catch |err| if (err == error.SyncFailed) d.why else core.damaged;
    onMain(void, Sync.announceMain, .{ s, said, e.browser });
    drive.keepTokens(s, &d);
}

fn ringNow(s: *Sync, a: Allocator) ?struct { []u8, keyring.StoreKey } {
    const r = s.ring_json orelse return null;
    const k = s.store_key orelse return null;
    return .{ a.dupe(u8, r) catch return null, k };
}

fn enroll(s: *Sync, a: Allocator, d: *Drop, h: How) ![]const u8 {
    const now = onMain(?struct { []u8, keyring.StoreKey }, ringNow, .{ s, a }) orelse return error.Damaged;
    var ring = (try json.decode(keyring.Keyring, a, now[0])).value;
    try keyring.verifyKeyringMac(a, &ring, now[1]);
    switch (h) {
        .pass => |p| try keyring.enrollPasswordSlot(a, &ring, now[1], p),
        .account => |k| try keyring.enrollAccountSlot(a, &ring, now[1], k, s.name),
    }
    const bytes = try json.encodeSorted(a, ring);
    try writeRing(a, d, bytes);
    onMain(void, setRing, .{ s, bytes });
    // Every head carries the keyring: this Mac's written again next round.
    s.post(.{ .tick = .{} });
    return if (h == .pass) "Backup passphrase added" else "Account key added";
}

pub fn runRestore(s: *Sync, given: Drop, browser: ?*Browser) void {
    var d = given;
    defer d.deinit();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = inspect.restoreLatestQuarantine(a, &d) catch |e| {
        const msg = if (e == error.SyncFailed and d.why.len > 0) d.why else "There's no archived store to restore";
        return onMain(void, Sync.failMain, .{ s, msg, browser });
    };
    onMain(void, Sync.forgetKey, .{s});
    onMain(void, setLocation, .{ s, inspect.inspect(a, &d, onMain(?keyring.AccountKey, knownAccountKey, .{s})) });
    const msg = std.fmt.allocPrint(a, "Restored the store archived at {s} — unlock it to join", .{ts}) catch "Restored the archived store";
    onMain(void, Sync.failMain, .{ s, msg, browser });
    drive.keepTokens(s, &d);
}

pub fn runSend(s: *Sync, sent: Sent) void {
    var d = sent.drop;
    defer {
        d.deinit();
        s.gpa.free(sent.name);
        s.gpa.free(sent.sealed);
        s.gpa.free(sent.to);
    }
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = if (d.put(a, sent.name, sent.sealed)) |_|
        std.fmt.allocPrint(a, "Sent to {s}", .{sent.to}) catch "Sent"
    else |e| if (e == error.SyncFailed) d.why else "Out of memory";
    onMain(void, Sync.announceMain, .{ s, msg, @as(?*Browser, sent.browser) });
    drive.keepTokens(s, &d);
}

pub fn readKinds(defaults: objc.Object) sync_mod.Kinds {
    const pool = objc.Pool.push();
    defer pool.pop();
    const list = objc.msg(?objc.Object, defaults, "stringArrayForKey:", .{objc.nsString("sync.kinds")}) orelse return .full;
    var out: sync_mod.Kinds = .empty;
    for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
        const s = objc.fromNSString(objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)}));
        if (std.meta.stringToEnum(sync_mod.Kind, s)) |k| out.insert(k);
    }
    return out;
}

extern "c" fn SCDynamicStoreCopyComputerName(store: ?*anyopaque, encoding: ?*u32) ?objc.Object;

pub fn computerName(gpa: Allocator) []u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = SCDynamicStoreCopyComputerName(null, null) orelse return dupe(gpa, "Mac");
    defer objc.release(s);
    return dupe(gpa, objc.fromNSString(s));
}
