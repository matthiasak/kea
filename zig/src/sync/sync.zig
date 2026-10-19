//! Your Macs in step (`Sync` in Sync.swift): each writes its own sealed files
//! to one store — a synced folder or a bucket — and reads the others'.
//! What Settings shows and sets lives on the main thread; the work (files,
//! network, PBKDF2) runs on one serial queue and comes back to the main
//! thread to read and change the app's stores. Under tests (`opts.root`)
//! every job runs at once on the caller's thread, and the keychain is never
//! touched. The tick itself: tick.zig.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const core = @import("core.zig");
const kinds = @import("kinds.zig");
const Drop = @import("drop.zig").Drop;
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
pub const Place = enum { off, folder, bucket };

/// Another Mac, from its `tabs.kea`.
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
};

pub const state_file = "sync.json";
pub const service = "app.kea.zig.sync";

extern "c" fn SCDynamicStoreCopyComputerName(store: ?*anyopaque, encoding: ?*u32) ?objc.Object;
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
    key: ?core.Key = null,
    secret: ?[]u8 = null,
    started: bool = false,
    ticker: ?*Ticker = null,

    // The queue's (or, while a tick waits on it, the main thread's).
    state: std.json.Parsed(State),
    seen: std.StringHashMapUnmanaged(SwiftDate) = .empty,
    wrote: std.StringHashMapUnmanaged(core.Hash) = .empty,
    /// Owns `seen`'s and `wrote`'s keys.
    names: std.heap.ArenaAllocator,
    last_tabs_write: SwiftDate = core.distant_past,
    others: std.AutoArrayHashMapUnmanaged(json.Uuid, std.json.Parsed(kinds.TabsDoc)) = .empty,

    // Either thread, under `lock`: history cleared or forgotten since the last tick.
    lock: std.c.pthread_mutex_t = .{},
    pending_cleared: ?SwiftDate = null,
    pending_forgot: std.StringArrayHashMapUnmanaged(SwiftDate) = .empty,

    queue: dispatch.Queue,
    inline_jobs: bool,

    /// In place: jobs point back here.
    pub fn init(self: *Sync, kea: *Kea) void {
        const gpa = kea.gpa;
        const store = &kea.store;
        const place_raw = store.string("sync.place");
        defer if (place_raw) |p| gpa.free(p);
        self.* = .{
            .kea = kea,
            .gpa = gpa,
            .place = if (place_raw) |p| std.meta.stringToEnum(Place, p) orelse .off else .off,
            .folder = store.string("sync.folder") orelse dupe(gpa, ""),
            .endpoint = store.string("sync.endpoint") orelse dupe(gpa, "https://storage.googleapis.com"),
            .bucket = store.string("sync.bucket") orelse dupe(gpa, ""),
            .access = store.string("sync.access") orelse dupe(gpa, ""),
            .kinds = readKinds(store.defaults),
            .device = undefined,
            .name = computerName(gpa),
            .status = dupe(gpa, "Off"),
            .devices_arena = .init(gpa),
            .state = loadState(kea),
            .names = .init(gpa),
            .queue = dispatch.dispatch_queue_create("kea.sync", null),
            .inline_jobs = kea.opts.root != null,
        };
        const saved = store.string("sync.device");
        defer if (saved) |s| gpa.free(s);
        self.device = if (saved) |s| json.Uuid.parse(s) catch null orelse self.newDevice() else self.newDevice();
    }

    fn newDevice(self: *Sync) json.Uuid {
        const made = json.Uuid.random();
        self.kea.store.setString("sync.device", &made.string());
        return made;
    }

    /// Before the app's stores go: waits out the queue.
    pub fn deinit(self: *Sync) void {
        if (self.ticker) |t| t.sync = null;
        if (!self.inline_jobs) {
            var done: std.atomic.Value(bool) = .init(false);
            self.post(.{ .done = &done });
            // The queue may be waiting on the main thread: keep it turning.
            while (!done.load(.acquire)) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, 1);
        }
        if (self.takePending()) self.saveState(true);
        dispatch.dispatch_release(self.queue);
        self.resetCaches();
        self.others.deinit(self.gpa);
        self.seen.deinit(self.gpa);
        self.wrote.deinit(self.gpa);
        self.names.deinit();
        self.pending_forgot.deinit(self.gpa);
        self.state.deinit();
        self.devices_arena.deinit();
        for ([_][]u8{ self.folder, self.endpoint, self.bucket, self.access, self.name, self.status }) |s| self.gpa.free(s);
        if (self.secret) |s| self.gpa.free(s);
    }

    fn testing(self: *const Sync) bool {
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
                if (keychain.load(self.gpa, .{ .service = service, .account = "key" })) |k| {
                    defer self.gpa.free(k);
                    if (k.len == 32) {
                        self.key = k[0..32].*;
                        self.ready = true;
                    }
                }
            }
            if (self.key == null) self.setStatus("Type the passphrase");
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
        } else if (self.key == null) self.setStatus("Type the passphrase");
    }

    pub fn chooseFolder(self: *Sync, path: []const u8) void {
        replace(self.gpa, &self.folder, path);
        self.kea.store.setString("sync.folder", path);
        self.setPlace(.folder);
        self.forgetKey();
        self.setStatus("Type the passphrase");
    }

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
        if (self.secret) |old| self.gpa.free(old);
        self.secret = dupe(self.gpa, sc);
        if (!self.testing()) saveKeychain("secret", sc);
        self.setPlace(.bucket);
        self.forgetKey();
        self.setStatus("Type the passphrase");
        return null;
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

    /// Opens (or, the first time, makes) the store with `passphrase`. What
    /// can be said at once comes back; the rest lands in `status` and is
    /// announced in `browser`.
    pub fn use(self: *Sync, passphrase: []const u8, browser: ?*Browser) ?[]const u8 {
        if (passphrase.len == 0) return "Type a passphrase";
        const d = self.drop() orelse return if (self.place == .folder) "Choose a folder first" else "Fill in the bucket details first";
        self.post(.{ .use = .{
            .pass = dupe(self.gpa, passphrase),
            .drop = d,
            .identity = self.storeIdentity(),
            .browser = browser,
        } });
        return null;
    }

    /// One tick now, after any running (`now()`). Under tests it is done on return.
    pub fn syncNow(self: *Sync) void {
        self.post(.tick);
    }

    /// Tabs › Send to Device.
    pub fn send(self: *Sync, url: []const u8, title: []const u8, to: *const Device, browser: *Browser) void {
        const k = self.key orelse return browser.announce("Set up Sync in Settings first");
        if (!self.ready or !kinds.webAddress(url)) return browser.announce("Set up Sync in Settings first");
        var d = self.drop() orelse return browser.announce("Set up Sync in Settings first");
        const sealed = blk: {
            const plain = json.encodeSorted(self.gpa, kinds.SentTab{ .url = url, .title = title, .from = self.name, .at = json.now() }) catch break :blk null;
            defer self.gpa.free(plain);
            break :blk core.seal(self.gpa, plain, k) catch null;
        } orelse {
            d.deinit();
            return browser.announce(core.damaged);
        };
        self.post(.{ .send = .{
            .drop = d,
            .name = std.fmt.allocPrint(self.gpa, "kea/v1/inbox/{f}/{f}.kea", .{ to.id, json.Uuid.random() }) catch @panic("OOM"),
            .sealed = sealed,
            .to = dupe(self.gpa, to.name),
            .browser = browser,
        } });
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

    fn forgetKey(self: *Sync) void {
        self.key = null;
        self.ready = false;
        self.devices = &.{};
        _ = self.devices_arena.reset(.free_all);
        if (!self.testing()) keychain.delete(.{ .service = service, .account = "key" });
        self.post(.reset);
    }

    fn storeIdentity(self: *Sync) []u8 {
        return switch (self.place) {
            .off => dupe(self.gpa, ""),
            .folder => std.fmt.allocPrint(self.gpa, "folder:{s}", .{self.folder}) catch @panic("OOM"),
            .bucket => std.fmt.allocPrint(self.gpa, "bucket:{s}/{s}", .{ self.endpoint, self.bucket }) catch @panic("OOM"),
        };
    }

    /// Where the files go, as set now; the caller owns it.
    pub fn drop(self: *Sync) ?Drop {
        switch (self.place) {
            .off => return null,
            .folder => return if (self.folder.len == 0) null else Drop.folder(self.gpa, self.folder) catch null,
            .bucket => {
                const secret = self.secret orelse return null;
                if (self.endpoint.len == 0 or self.bucket.len == 0 or self.access.len == 0 or secret.len == 0 or !Drop.allowed(self.endpoint)) return null;
                return Drop.bucket(self.gpa, self.endpoint, self.bucket, self.access, secret) catch null;
            },
        }
    }

    pub fn setStatus(self: *Sync, text: []const u8) void {
        if (std.mem.eql(u8, self.status, text)) return;
        replace(self.gpa, &self.status, text);
        for (self.kea.browsers.items) |b| b.redraw();
    }

    // MARK: the queue

    pub const Job = union(enum) {
        tick,
        use: struct { pass: []u8, drop: Drop, identity: []u8, browser: ?*Browser },
        send: struct { drop: Drop, name: []u8, sealed: []u8, to: []u8, browser: *Browser },
        reset,
        done: *std.atomic.Value(bool),
    };

    const Posted = struct { sync: *Sync, job: Job };

    fn post(self: *Sync, job: Job) void {
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
            .tick => tick(self),
            .use => |u| {
                var d = u.drop;
                defer {
                    d.deinit();
                    self.gpa.free(u.pass);
                    self.gpa.free(u.identity);
                }
                var arena: std.heap.ArenaAllocator = .init(self.gpa);
                defer arena.deinit();
                self.unlock(arena.allocator(), &d, u.pass, u.identity) catch |e| {
                    const msg = switch (e) {
                        error.SyncFailed => d.why,
                        error.WrongPassphrase => core.wrong_passphrase,
                        error.Damaged => core.damaged,
                        else => "Out of memory",
                    };
                    onMain(void, failMain, .{ self, msg, u.browser });
                };
            },
            .send => |s| {
                var d = s.drop;
                defer {
                    d.deinit();
                    self.gpa.free(s.name);
                    self.gpa.free(s.sealed);
                    self.gpa.free(s.to);
                }
                var arena: std.heap.ArenaAllocator = .init(self.gpa);
                defer arena.deinit();
                const a = arena.allocator();
                const msg = if (d.put(a, s.name, s.sealed)) |_|
                    std.fmt.allocPrint(a, "Sent to {s}", .{s.to}) catch "Sent"
                else |e| if (e == error.SyncFailed) d.why else "Out of memory";
                onMain(void, announceMain, .{ self, msg, @as(?*Browser, s.browser) });
            },
            .reset => self.resetCaches(),
            .done => |flag| flag.store(true, .release),
        }
    }

    fn unlock(self: *Sync, a: Allocator, d: *Drop, pass: []const u8, identity: []const u8) !void {
        const derived = if (try d.get(a, "kea/v1/salt")) |salt| blk: {
            const k = core.key(pass, salt);
            const check = (try d.get(a, "kea/v1/check")) orelse return error.WrongPassphrase;
            const plain = core.open(a, check, k) catch return error.WrongPassphrase;
            if (!std.mem.eql(u8, plain, "kea")) return error.WrongPassphrase;
            break :blk k;
        } else blk: {
            var salt: [16]u8 = undefined;
            std.c.arc4random_buf(&salt, salt.len);
            try d.put(a, "kea/v1/salt", &salt);
            const k = core.key(pass, &salt);
            try d.put(a, "kea/v1/check", try core.seal(a, "kea", k));
            break :blk k;
        };
        onMain(void, keyMain, .{ self, derived });
        if (!std.mem.eql(u8, self.state.value.store, identity)) {
            try self.setState(.{ .store = identity });
            self.resetCaches();
        }
        tick(self);
    }

    fn keyMain(self: *Sync, k: core.Key) void {
        self.key = k;
        if (!self.testing()) saveKeychain("key", &k);
        self.ready = true;
        for (self.kea.browsers.items) |b| b.redraw();
    }

    fn failMain(self: *Sync, msg: []const u8, browser: ?*Browser) void {
        self.setStatus(msg);
        announceMain(self, msg, browser);
    }

    fn announceMain(self: *Sync, msg: []const u8, browser: ?*Browser) void {
        const b = browser orelse return;
        // Only a window still open.
        for (self.kea.browsers.items) |open| if (open == b) return b.announce(msg);
    }

    pub fn resetCaches(self: *Sync) void {
        self.seen.clearRetainingCapacity();
        self.wrote.clearRetainingCapacity();
        _ = self.names.reset(.retain_capacity);
        for (self.others.values()) |p| p.deinit();
        self.others.clearRetainingCapacity();
        self.last_tabs_write = core.distant_past;
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
        self.kea.store.write(state_file, bytes, now);
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

/// Every 30 s while the app runs; `sync` nulled when Sync goes, and the
/// ticker with it at its next turn.
const Ticker = struct {
    sync: ?*Sync,
    gpa: Allocator,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const t: *Ticker = @ptrCast(@alignCast(ctx.?));
        const s = t.sync orelse return t.gpa.destroy(t);
        s.syncNow();
        objc.dispatchAfter(30 * std.time.ns_per_s, t, fire);
    }
};

fn dupe(gpa: Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch @panic("OOM");
}

fn replace(gpa: Allocator, field: *[]u8, value: []const u8) void {
    const copy = dupe(gpa, value);
    gpa.free(field.*);
    field.* = copy;
}

fn saveKeychain(account: []const u8, data: []const u8) void {
    keychain.delete(.{ .service = service, .account = account });
    _ = keychain.save(.{ .service = service, .account = account }, data, .{});
}

fn readKinds(defaults: objc.Object) Kinds {
    const pool = objc.Pool.push();
    defer pool.pop();
    const list = objc.msg(?objc.Object, defaults, "stringArrayForKey:", .{objc.nsString("sync.kinds")}) orelse return .full;
    var out: Kinds = .empty;
    for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
        const s = objc.fromNSString(objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)}));
        if (std.meta.stringToEnum(Kind, s)) |k| out.insert(k);
    }
    return out;
}

fn computerName(gpa: Allocator) []u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = SCDynamicStoreCopyComputerName(null, null) orelse return dupe(gpa, "Mac");
    defer objc.release(s);
    return dupe(gpa, objc.fromNSString(s));
}

fn loadState(kea: *Kea) std.json.Parsed(State) {
    if (kea.store.readFile(state_file)) |bytes| {
        defer kea.gpa.free(bytes);
        if (json.decode(State, kea.gpa, bytes)) |p| return p else |_| {}
    }
    return json.decode(State, kea.gpa, "{}") catch @panic("OOM");
}
