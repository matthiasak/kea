//! Your Macs in step (`Sync` in Sync.swift): each writes its part of one
//! encrypted store — a synced folder, Google Drive or a bucket — and reads
//! the others'. What Settings shows and sets lives on the main thread; the
//! work (files, network, PBKDF2) runs on one serial queue and comes back to
//! the main thread to read and change the app's stores. Under tests
//! (`opts.root`) every job runs at once on the caller's thread, and the
//! keychain is never touched. Unlocking and recovery: sync_ops.zig; Google
//! Drive's sign-in and folders: sync_drive.zig; the tick itself: tick.zig.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const core = @import("core.zig");
const kinds = @import("kinds.zig");
const keyring = @import("keyring.zig");
const dag = @import("dag.zig");
const inspect = @import("inspect.zig");
const Drop = @import("drop.zig").Drop;
const gdrive = @import("gdrive.zig");
const gdrive_oauth = @import("gdrive_oauth.zig");
const ops = @import("sync_ops.zig");
const drive = @import("sync_drive.zig");
const keychain = @import("../sys/keychain.zig");
const dispatch = @import("../sys/dispatch.zig");
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const Chats = @import("../data/chats_store.zig").Chats;
const tick = @import("tick.zig").tick;

const Allocator = std.mem.Allocator;
const SwiftDate = json.SwiftDate;

pub const Kind = kinds.Kind;
pub const Kinds = std.EnumSet(Kind);
pub const Place = enum { off, folder, drive, bucket };

/// Another Mac, from its tabs.
pub const Device = struct {
    pub const Page = struct { title: []const u8, url: []const u8 };
    id: json.Uuid,
    name: []const u8,
    seen: SwiftDate,
    pages: []const Page,
};

/// `sync.json`.
pub const State = struct {
    store: []const u8 = "",
    joined: bool = false,
    ledgers: json.Map(core.SyncLedger) = .{},
    cleared: ?SwiftDate = null,
    forgot: json.Map(SwiftDate) = .{},
    /// This Mac's newest commit in this store.
    head: []const u8 = "",
};

pub const state_file = "sync.json";
pub const service = "app.kea.zig.sync";

extern "c" const kCFRunLoopDefaultMode: objc.Object;
extern "c" fn CFRunLoopRunInMode(mode: objc.Object, seconds: f64, return_after_source_handled: u8) i32;

pub const Sync = struct {
    kea: *Kea,
    gpa: Allocator,
    /// Ubi Chat's chats, set by whoever keeps them; null syncs none.
    chats: ?*Chats = null,
    /// After another Mac's shortcuts land in defaults (`ShortcutStore.reload`).
    shortcuts_changed: ?*const fn (*Kea) void = null,

    // Main thread.
    place: Place,
    folder: []u8,
    endpoint: []u8,
    bucket: []u8,
    access: []u8,
    kinds: Kinds,
    device: json.Uuid,
    /// This Mac's name (`SCDynamicStoreCopyComputerName`).
    name: []u8,
    status: []u8,
    /// Your other Macs seen within 30 days, newest first; owned by `devices_arena`.
    devices: []const Device = &.{},
    devices_arena: std.heap.ArenaAllocator,
    ready: bool = false,
    /// While another Mac's change is put in place: what it changes is not this Mac's news.
    applying: bool = false,
    secret: ?[]u8 = null,
    started: bool = false,
    ticker: ?*Ticker = null,

    key_mode: keyring.KeyMode,
    store_key: ?keyring.StoreKey = null,
    subkeys: ?keyring.Subkeys = null,
    /// The unlocked store's keyring, sorted JSON; read from the store when null.
    ring_json: ?[]u8 = null,
    ring_has_password: bool = false,
    ring_has_my_account_key: bool = false,
    /// Tests' stand-in for the keychain's account key.
    test_account_key: ?keyring.AccountKey = null,

    drive_folder_id: []u8,
    drive_folder_path: []u8,
    drive_email: []u8,
    drive_client_id: []u8,
    drive_refresh: ?[]u8 = null,
    drive_access: []u8,
    drive_expires: SwiftDate = 0,
    /// Google's own addresses, or a stand-in's in tests.
    drive_endpoints: gdrive_oauth.AuthEndpoints = .{},
    drive_flow: ?*gdrive_oauth.LoopbackFlow = null,
    drive_signing_in: bool = false,
    browse: drive.Browse,

    /// What the chosen place held when last looked at; on `inspect_arena`.
    location: inspect.LocationState = .unknown,
    inspect_arena: std.heap.ArenaAllocator,
    /// A replace or repair that failed, and what was kept; "" when none.
    warning_error: []u8,
    /// Damage the last round worked around; "" when none.
    damaged_note: []u8,
    /// The store identity whose other files you said to sync beside.
    allow_non_empty_for: []u8,

    // The queue's (or, while a tick waits on it, the main thread's).
    state: std.json.Parsed(State),
    /// Each other Mac's head: when it last changed, and its commit.
    peer_heads: std.AutoArrayHashMapUnmanaged(json.Uuid, PeerHead) = .empty,
    /// "<uuid>/<kind>" → the tree hash taken in last.
    merged: std.StringHashMapUnmanaged([64]u8) = .empty,
    /// Owns `merged`'s keys.
    names: std.heap.ArenaAllocator,
    last_tabs_write: SwiftDate = core.distant_past,
    tabs_hash: ?core.Hash = null,
    others: std.AutoArrayHashMapUnmanaged(json.Uuid, std.json.Parsed(kinds.TabsDoc)) = .empty,
    cache: dag.Cache,
    rounds: u32 = 0,

    // Either thread, under `lock`: history cleared or forgotten since the last tick.
    lock: std.c.pthread_mutex_t = .{},
    pending_cleared: ?SwiftDate = null,
    pending_forgot: std.StringArrayHashMapUnmanaged(SwiftDate) = .empty,

    queue: dispatch.Queue,
    inline_jobs: bool,

    pub const PeerHead = struct { at: SwiftDate, oid: [64]u8 };

    /// In place: jobs point back here.
    pub fn init(self: *Sync, kea: *Kea) void {
        const gpa = kea.gpa;
        const store = &kea.store;
        const place_raw = store.string("sync.place");
        defer if (place_raw) |p| gpa.free(p);
        const mode_raw = store.string("sync.key_mode");
        defer if (mode_raw) |m| gpa.free(m);
        self.* = .{
            .kea = kea,
            .gpa = gpa,
            .place = if (place_raw) |p| std.meta.stringToEnum(Place, p) orelse .off else .off,
            .folder = store.string("sync.folder") orelse dupe(gpa, ""),
            .endpoint = store.string("sync.endpoint") orelse dupe(gpa, "https://storage.googleapis.com"),
            .bucket = store.string("sync.bucket") orelse dupe(gpa, ""),
            .access = store.string("sync.access") orelse dupe(gpa, ""),
            .kinds = ops.readKinds(store.defaults),
            .device = undefined,
            .name = ops.computerName(gpa),
            .status = dupe(gpa, "Off"),
            .devices_arena = .init(gpa),
            .key_mode = if (mode_raw) |m| std.meta.stringToEnum(keyring.KeyMode, m) orelse .password else .password,
            .drive_folder_id = store.string("sync.drive.folder_id") orelse dupe(gpa, ""),
            .drive_folder_path = store.string("sync.drive.folder_path") orelse dupe(gpa, ""),
            .drive_email = store.string("sync.drive.email") orelse dupe(gpa, ""),
            .drive_client_id = store.string("sync.drive.client_id") orelse dupe(gpa, ""),
            .drive_access = dupe(gpa, ""),
            .browse = .{ .arena = .init(gpa) },
            .inspect_arena = .init(gpa),
            .warning_error = dupe(gpa, ""),
            .damaged_note = dupe(gpa, ""),
            .allow_non_empty_for = store.string("sync.allow_non_empty") orelse dupe(gpa, ""),
            .state = loadState(kea),
            .names = .init(gpa),
            .cache = .{ .gpa = gpa, .objects = objectsDrop(gpa, store) },
            .queue = dispatch.dispatch_queue_create("kea.sync", null),
            .inline_jobs = kea.opts.root != null,
        };
        const dev_key = if (kea.opts.root != null) "sync.device" else "sync.zig.device";
        const saved = store.string(dev_key);
        defer if (saved) |s| gpa.free(s);
        self.device = if (saved) |s| json.Uuid.parse(s) catch null orelse self.newDevice() else self.newDevice();
    }

    fn newDevice(self: *Sync) json.Uuid {
        const made = json.Uuid.random();
        self.kea.store.setString(if (self.kea.opts.root != null) "sync.device" else "sync.zig.device", &made.string());
        return made;
    }

    /// Before the app's stores go: waits out the queue.
    pub fn deinit(self: *Sync) void {
        if (self.ticker) |t| t.sync = null;
        if (self.drive_flow) |f| {
            f.cancel();
            // Its `.cancelled` comes to the main thread, and here.
            while (self.drive_flow != null) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 1);
        }
        if (!self.inline_jobs) {
            var done: std.atomic.Value(bool) = .init(false);
            self.post(.{ .done = &done });
            // The queue may be waiting on the main thread: keep it turning.
            while (!done.load(.acquire)) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 1);
        }
        if (self.takePending()) self.saveState(true);
        dispatch.dispatch_release(self.queue);
        self.resetCaches();
        self.cache.deinit();
        self.others.deinit(self.gpa);
        self.peer_heads.deinit(self.gpa);
        self.merged.deinit(self.gpa);
        self.names.deinit();
        self.pending_forgot.deinit(self.gpa);
        self.state.deinit();
        self.devices_arena.deinit();
        self.inspect_arena.deinit();
        self.browse.deinit(self.gpa);
        for ([_][]u8{ self.folder, self.endpoint, self.bucket, self.access, self.name, self.status, self.drive_folder_id, self.drive_folder_path, self.drive_email, self.drive_client_id, self.drive_access, self.warning_error, self.damaged_note, self.allow_non_empty_for }) |s| self.gpa.free(s);
        for ([_]?[]u8{ self.secret, self.drive_refresh, self.ring_json }) |s| if (s) |x| self.gpa.free(x);
    }

    pub fn testing(self: *const Sync) bool {
        return self.kea.opts.root != null;
    }

    /// Keys and timers: once, after launch (`start`). The 30 s tick and the
    /// first one 3 s in; the app also calls `syncNow` on becoming active.
    pub fn start(self: *Sync) void {
        if (self.started) return;
        self.started = true;
        if (self.place != .off) {
            if (!self.testing()) {
                if (keychain.load(self.gpa, .{ .service = service, .account = "secret" })) |s| self.secret = s;
                if (keychain.load(self.gpa, .{ .service = service, .account = "drive_refresh" })) |r| self.drive_refresh = r;
                if (keychain.load(self.gpa, .{ .service = service, .account = "store_key" })) |k| {
                    defer self.gpa.free(k);
                    if (k.len == 32) ops.keyMain(self, k[0..32].*, null);
                }
            }
            if (self.store_key == null) self.setStatus("Type the passphrase");
        }
        if (self.testing()) return;
        const t = self.gpa.create(Ticker) catch return;
        t.* = .{ .sync = self, .gpa = self.gpa };
        self.ticker = t;
        objc.dispatchAfter(3 * std.time.ns_per_s, t, Ticker.fire);
    }

    // MARK: settings (main thread)

    pub fn setPlace(self: *Sync, place: Place) void {
        self.place = place;
        self.kea.store.setString("sync.place", @tagName(place));
        if (place == .off) {
            self.setStatus("Off");
            self.ready = false;
        } else if (self.store_key == null) self.setStatus("Type the passphrase");
    }

    pub fn chooseFolder(self: *Sync, path: []const u8) void {
        replace(self.gpa, &self.folder, path);
        self.kea.store.setString("sync.folder", path);
        self.moved(.folder);
    }

    /// A Drive folder by id, shown as `display_path`.
    pub fn chooseDriveFolder(self: *Sync, id: []const u8, display_path: []const u8) void {
        replace(self.gpa, &self.drive_folder_id, id);
        replace(self.gpa, &self.drive_folder_path, display_path);
        self.kea.store.setString("sync.drive.folder_id", id);
        self.kea.store.setString("sync.drive.folder_path", display_path);
        self.moved(.drive);
    }

    /// Somewhere else: its store unlocked afresh, and looked at first.
    pub fn moved(self: *Sync, place: Place) void {
        self.setPlace(place);
        self.forgetKey();
        self.setWarning("");
        self.setStatus("Type the passphrase");
        if (self.drop()) |d| self.post(.{ .inspect = d });
    }

    pub fn setKind(self: *Sync, kind: Kind, on: bool) void {
        self.kinds.setPresent(kind, on);
        const pool = objc.Pool.push();
        defer pool.pop();
        // Sorted raw values, as Swift writes them.
        var names: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = self.kinds.iterator();
        while (it.next()) |k| : (n += 1) names[n] = @tagName(k);
        std.mem.sort([]const u8, names[0..n], {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        const list = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
        for (names[0..n]) |s| objc.msg(void, list, "addObject:", .{objc.nsString(s)});
        objc.msg(void, self.kea.store.defaults, "setObject:forKey:", .{ list, objc.nsString("sync.kinds") });
    }

    pub fn setKeyMode(self: *Sync, mode: keyring.KeyMode) void {
        self.key_mode = mode;
        self.kea.store.setString("sync.key_mode", @tagName(mode));
        for (self.kea.browsers.items) |b| b.redraw();
    }

    pub const useBucket = ops.useBucket;
    pub const send = ops.send;
    pub const use = ops.use;
    pub const useAccountKey = ops.useAccountKey;
    pub const confirmUseNonEmpty = ops.confirmUseNonEmpty;
    pub const createSubfolderAndUse = ops.createSubfolderAndUse;
    pub const overwriteExistingStore = ops.overwriteExistingStore;
    pub const salvageStore = ops.salvageStore;
    pub const repairStore = ops.repairStore;
    pub const restoreQuarantined = ops.restoreQuarantined;
    pub const importAccountKey = ops.importAccountKey;
    pub const enrollBackupPassword = ops.enrollBackupPassword;
    pub const enrollBackupAccountKey = ops.enrollBackupAccountKey;
    pub const accountKey = ops.accountKey;
    pub const knownAccountKey = ops.knownAccountKey;
    pub const startDriveSignIn = drive.startSignIn;
    pub const cancelDriveSignIn = drive.cancelSignIn;
    pub const disconnectDrive = drive.disconnect;
    pub const setDriveClientId = drive.setClientId;
    pub const browseDrive = drive.browse;
    pub const createDriveFolder = drive.createFolder;
    pub const useKeaSyncFolder = drive.useKeaSync;
    pub const browseDriveBack = drive.browseBack;
    pub const selectDriveFolder = drive.selectCurrent;

    /// One tick now, its packs checked, after any running (`now()`). Under
    /// tests it is done on return.
    pub fn syncNow(self: *Sync) void {
        self.post(.{ .tick = .{ .verify = true } });
    }

    /// History cleared here: other Macs clear theirs too.
    pub fn historyCleared(self: *Sync) void {
        if (self.applying or self.place == .off) return;
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        self.pending_cleared = json.now();
    }

    /// One page forgotten here (its history key).
    pub fn historyForgot(self: *Sync, key: []const u8) void {
        if (self.applying or self.place == .off) return;
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        const gop = self.pending_forgot.getOrPut(self.gpa, key) catch return;
        if (!gop.found_existing) gop.key_ptr.* = dupe(self.gpa, key);
        gop.value_ptr.* = json.now();
    }

    pub fn forgetKey(self: *Sync) void {
        if (self.store_key) |*k| std.crypto.secureZero(u8, k);
        self.store_key = null;
        self.subkeys = null;
        if (self.ring_json) |r| self.gpa.free(r);
        self.ring_json = null;
        self.ready = false;
        self.devices = &.{};
        _ = self.devices_arena.reset(.free_all);
        if (!self.testing()) for ([_][]const u8{ "store_key", "key" }) |acct| keychain.delete(.{ .service = service, .account = acct });
        self.post(.reset);
    }

    pub fn storeIdentity(self: *Sync) []u8 {
        return switch (self.place) {
            .off => dupe(self.gpa, ""),
            .folder => std.fmt.allocPrint(self.gpa, "folder:{s}", .{self.folder}) catch @panic("OOM"),
            .drive => std.fmt.allocPrint(self.gpa, "drive:{s}", .{self.drive_folder_id}) catch @panic("OOM"),
            .bucket => std.fmt.allocPrint(self.gpa, "bucket:{s}/{s}", .{ self.endpoint, self.bucket }) catch @panic("OOM"),
        };
    }

    /// Where the files go, as set now; the caller owns it.
    pub fn drop(self: *Sync) ?Drop {
        switch (self.place) {
            .off => return null,
            .folder => return if (self.folder.len == 0) null else Drop.folder(self.gpa, self.folder) catch null,
            .drive => return if (self.drive_folder_id.len == 0) null else drive.drop(self, self.drive_folder_id),
            .bucket => {
                const secret = self.secret orelse return null;
                if (self.endpoint.len == 0 or self.bucket.len == 0 or self.access.len == 0 or secret.len == 0 or !Drop.allowed(self.endpoint)) return null;
                return Drop.bucket(self.gpa, self.endpoint, self.bucket, self.access, secret) catch null;
            },
        }
    }

    /// What `use` says when there is nowhere to go yet.
    pub fn missingPlace(self: *const Sync) []const u8 {
        return switch (self.place) {
            .folder => "Choose a folder first",
            .drive => if (self.drive_refresh == null) "Sign in to Google Drive first" else "Choose a Google Drive folder first",
            .off, .bucket => "Fill in the bucket details first",
        };
    }

    pub fn setStatus(self: *Sync, text: []const u8) void {
        if (std.mem.eql(u8, self.status, text)) return;
        replace(self.gpa, &self.status, text);
        for (self.kea.browsers.items) |b| b.redraw();
    }

    pub fn setWarning(self: *Sync, text: []const u8) void {
        replace(self.gpa, &self.warning_error, text);
        for (self.kea.browsers.items) |b| b.redraw();
    }

    pub fn setDamagedNote(self: *Sync, text: []const u8) void {
        if (!std.mem.eql(u8, self.damaged_note, text)) replace(self.gpa, &self.damaged_note, text);
    }

    // MARK: the queue

    pub const Job = union(enum) {
        tick: struct { verify: bool = false, repair: bool = false },
        unlock: ops.Unlock,
        inspect: Drop,
        enroll: ops.Enroll,
        restore: struct { drop: Drop, browser: ?*Browser },
        send: ops.Sent,
        drive: drive.Job,
        reset,
        done: *std.atomic.Value(bool),
    };

    const Posted = struct { sync: *Sync, job: Job };

    pub fn post(self: *Sync, job: Job) void {
        if (self.inline_jobs) return self.run(job);
        const p = self.gpa.create(Posted) catch return;
        p.* = .{ .sync = self, .job = job };
        dispatch.dispatch_async_f(self.queue, p, runPosted);
    }

    fn runPosted(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Posted = @ptrCast(@alignCast(ctx.?));
        defer p.sync.gpa.destroy(p);
        p.sync.run(p.job);
    }

    fn run(self: *Sync, job: Job) void {
        switch (job) {
            .tick => |t| tick(self, t.verify, t.repair),
            .unlock => |u| ops.runUnlock(self, u),
            .inspect => |d| ops.runInspect(self, d),
            .enroll => |e| ops.runEnroll(self, e),
            .restore => |r| ops.runRestore(self, r.drop, r.browser),
            .send => |s| ops.runSend(self, s),
            .drive => |j| drive.run(self, j),
            .reset => self.resetCaches(),
            .done => |flag| flag.store(true, .release),
        }
    }

    pub fn failMain(self: *Sync, msg: []const u8, browser: ?*Browser) void {
        self.setStatus(msg);
        announceMain(self, msg, browser);
    }

    pub fn announceMain(self: *Sync, msg: []const u8, browser: ?*Browser) void {
        const b = browser orelse return;
        // Only a window still open.
        for (self.kea.browsers.items) |open| if (open == b) return b.announce(msg);
    }

    pub fn resetCaches(self: *Sync) void {
        self.peer_heads.clearRetainingCapacity();
        self.merged.clearRetainingCapacity();
        _ = self.names.reset(.retain_capacity);
        for (self.others.values()) |p| p.deinit();
        self.others.clearRetainingCapacity();
        self.last_tabs_write = core.distant_past;
        self.tabs_hash = null;
        self.cache.reset();
    }

    /// History cleared or forgotten here since the last tick, into `state`;
    /// whether there was any.
    pub fn takePending(self: *Sync) bool {
        _ = std.c.pthread_mutex_lock(&self.lock);
        defer _ = std.c.pthread_mutex_unlock(&self.lock);
        const any = self.pending_cleared != null or self.pending_forgot.count() > 0;
        const sa = self.state.arena.allocator();
        if (self.pending_cleared) |c| self.state.value.cleared = c;
        for (self.pending_forgot.keys(), self.pending_forgot.values()) |k, at| {
            core.putKey(sa, &self.state.value.forgot.map, k, at) catch {};
            self.gpa.free(k);
        }
        self.pending_cleared = null;
        self.pending_forgot.clearRetainingCapacity();
        return any;
    }

    /// `state` swapped for `value` (which may borrow from it) on a fresh arena.
    pub fn setState(self: *Sync, value: State) !void {
        const bytes = try json.encode(self.gpa, value);
        defer self.gpa.free(bytes);
        const fresh = try json.decode(State, self.gpa, bytes);
        self.state.deinit();
        self.state = fresh;
    }

    /// Written (sorted keys), and compacted onto a fresh arena.
    pub fn saveState(self: *Sync, now: bool) void {
        const bytes = json.encodeSorted(self.gpa, self.state.value) catch return;
        self.setState(self.state.value) catch {};
        self.kea.store.write(if (self.kea.opts.root != null) state_file else "sync-zig.json", bytes, now);
    }
};

/// `f(args...)` on the main thread, waited for; at once when already there.
pub fn onMain(comptime R: type, comptime f: anytype, args: anytype) R {
    if (objc.isMainThread()) return @call(.auto, f, args);
    const Call = struct {
        args: @TypeOf(args),
        out: R = undefined,
        fn run(p: ?*anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(p.?));
            c.out = @call(.auto, f, c.args);
        }
    };
    var call: Call = .{ .args = args };
    dispatch.dispatch_sync_f(objc.mainQueue(), &call, Call.run);
    return call.out;
}

/// Records this Mac has read or written, by oid: `<support>/sync-objects/`.
fn objectsDrop(gpa: Allocator, store: anytype) ?Drop {
    const path = store.folderFor("sync-objects") catch return null;
    defer gpa.free(path);
    return Drop.folder(gpa, path) catch null;
}

/// Every 30 s while the app runs; `sync` nulled when Sync goes, and the
/// ticker with it at its next turn.
const Ticker = struct {
    sync: ?*Sync,
    gpa: Allocator,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const t: *Ticker = @ptrCast(@alignCast(ctx.?));
        const s = t.sync orelse return t.gpa.destroy(t);
        s.post(.{ .tick = .{} });
        objc.dispatchAfter(30 * std.time.ns_per_s, t, fire);
    }
};

pub fn dupe(gpa: Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @panic("OOM");
}

pub fn replace(gpa: Allocator, field: *[]u8, value: []const u8) void {
    const copy = dupe(gpa, value);
    gpa.free(field.*);
    field.* = copy;
}

pub fn saveKeychain(account: []const u8, data: []const u8) void {
    keychain.delete(.{ .service = service, .account = account });
    _ = keychain.save(.{ .service = service, .account = account }, data, .{});
}

fn loadState(kea: *Kea) std.json.Parsed(State) {
    if (kea.store.readFile(if (kea.opts.root != null) state_file else "sync-zig.json")) |bytes| {
        defer kea.gpa.free(bytes);
        if (json.decode(State, kea.gpa, bytes)) |p| return p else |_| {}
    }
    return json.decode(State, kea.gpa, "{}") catch @panic("OOM");
}
