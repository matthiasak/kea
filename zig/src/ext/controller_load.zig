//! Starting and loading (Extensions.swift 196-280, 448-526, 686-736):
//! every extension switched on loaded one after another once the first
//! window is up, the workers WebKit remembers, one extension's context
//! made and loaded or unloaded, and one whose worker died taken up again.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const dispatch = @import("../sys/dispatch.zig");
const json = @import("../data/json.zig");
const controller = @import("controller.zig");
const Extensions = controller.Extensions;
const Browser = @import("../model/browser.zig").Browser;
const shims = @import("shims/install.zig");
const fence = @import("controller_fence.zig");

const log = std.log.scoped(.extensions);

// MARK: off the main thread and back

/// `work(job)` on a global queue, then `then(job)` on the main thread.
pub fn offMain(comptime T: type, job: *T, comptime work: fn (*T) void, comptime then: fn (*T) void) void {
    const S = struct {
        fn bg(p: ?*anyopaque) callconv(.c) void {
            work(@ptrCast(@alignCast(p.?)));
            objc.dispatchMain(p, fg);
        }
        fn fg(p: ?*anyopaque) callconv(.c) void {
            then(@ptrCast(@alignCast(p.?)));
        }
    };
    dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), job, S.bg);
}

/// `try await WKWebExtension(resourceBaseURL:)`: `job.found` (retained)
/// or `job.why` (on `job.gpa`) set, then `then(job)` on the main thread.
/// `T` has `gpa`, `found: ?objc.Object` and `why: ?[]u8`.
pub fn openExtension(comptime T: type, job: *T, folder: []const u8, comptime then: fn (*T) void) void {
    const S = struct {
        fn done(j: *T, found: ?objc.Object, err: ?objc.Object) void {
            if (found) |f| j.found = objc.retain(f) else {
                const said = if (err) |e| objc.fromNSString(objc.msg(objc.Object, e, "localizedDescription", .{})) else "unreadable";
                j.why = j.gpa.dupe(u8, said) catch null;
            }
            if (objc.isMainThread()) then(j) else objc.dispatchMain(j, fg);
        }
        fn fg(p: ?*anyopaque) callconv(.c) void {
            then(@ptrCast(@alignCast(p.?)));
        }
    };
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = fileURL(folder);
    var block = objc.Block(T, &.{ ?objc.Object, ?objc.Object }).init(job, S.done);
    objc.msg(void, objc.class("WKWebExtension"), "extensionWithResourceBaseURL:completionHandler:", .{ url, &block });
}

pub fn fileURL(path: []const u8) objc.Object {
    return objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:isDirectory:", .{ objc.nsString(path), objc.YES });
}

/// `found.displayName` / `found.version`, valid inside the caller's pool.
pub fn text(found: objc.Object, comptime key: [:0]const u8) ?[]const u8 {
    const s = objc.msg(?objc.Object, found, key, .{}) orelse return null;
    return objc.fromNSString(s);
}

// MARK: starting

/// `start(for:)`: the window followed, then — once it is up, the first
/// time only — every extension switched on loaded, one after another.
pub fn start(self: *Extensions, b: *Browser) void {
    self.attach(b);
    if (self.begun) return;
    self.begun = true;
    const job = std.heap.c_allocator.create(Start) catch return;
    job.* = .{ .serial = self.serial };
    // Loading one takes the main thread for tens of milliseconds; the
    // first frame goes first. A hidden launch has no frame to wait for.
    if (self.kea.opts.hidden or controller.appHidden(self.kea)) job.begin() else objc.dispatchMain(job, Start.beginLater);
}

const Start = struct {
    serial: u64,
    ids: std.ArrayList([]u8) = .empty,
    next: usize = 0,

    fn beginLater(p: ?*anyopaque) callconv(.c) void {
        const job: *Start = @ptrCast(@alignCast(p.?));
        job.begin();
    }

    fn finish(job: *Start) void {
        for (job.ids.items) |s| std.heap.c_allocator.free(s);
        job.ids.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(job);
    }

    fn begin(job: *Start) void {
        const self = controller.alive(job.serial) orelse return job.finish();
        forgetWorkersIfChanged(self, job);
    }

    fn workersDone(job: *Start) void {
        const self = controller.alive(job.serial) orelse return job.finish();
        @import("controller_forget.zig").forgetLeftOver(self, job, leftOverDone);
    }

    fn leftOverDone(p: *anyopaque) void {
        const job: *Start = @ptrCast(@alignCast(p));
        const self = controller.alive(job.serial) orelse return job.finish();
        for (self.installed.items) |r| if (r.enabled) {
            const id = std.heap.c_allocator.dupe(u8, r.id) catch continue;
            job.ids.append(std.heap.c_allocator, id) catch std.heap.c_allocator.free(id);
        };
        job.step();
    }

    fn step(job: *Start) void {
        const self = controller.alive(job.serial) orelse return job.finish();
        if (job.next >= job.ids.items.len) {
            markStarted(self);
            self.checkForUpdates();
            return job.finish();
        }
        load(self, job.ids.items[job.next], job, loaded);
    }

    fn loaded(p: *anyopaque, _: bool) void {
        const job: *Start = @ptrCast(@alignCast(p));
        const self = controller.alive(job.serial) orelse return job.finish();
        const id = job.ids.items[job.next];
        job.next += 1;
        // A moment apart: started all at once, WebKit fails some of their
        // workers and never tries them again.
        const background = if (self.context(id)) |c| objc.msg(objc.BOOL, objc.msg(objc.Object, c, "webExtension", .{}), "hasBackgroundContent", .{}) else false;
        if (job.next < job.ids.items.len and background) return objc.dispatchAfter(400 * std.time.ns_per_ms, job, stepLater);
        job.step();
    }

    fn stepLater(p: ?*anyopaque) callconv(.c) void {
        const job: *Start = @ptrCast(@alignCast(p.?));
        job.step();
    }
};

/// Whether a page loaded now would miss extensions still to load.
pub fn starting(self: *Extensions) bool {
    if (self.started) return false;
    for (self.installed.items) |r| if (r.enabled) return true;
    return false;
}

/// One `whenStarted` caller: run once, by `markStarted` or the time
/// limit, whichever first; freed when both have let go.
pub const Waiter = struct {
    serial: u64,
    browser: *Browser,
    then: *const fn (*Browser) void,
    refs: u8 = 2,
    done: bool = false,

    fn fire(w: *Waiter) void {
        if (!w.done) {
            w.done = true;
            // Its window may have gone meanwhile (`[weak self]`).
            if (controller.alive(w.serial)) |self| for (self.kea.browsers.items) |b| if (b == w.browser) {
                w.then(b);
                break;
            };
        }
        w.drop();
    }

    pub fn drop(w: *Waiter) void {
        w.refs -= 1;
        if (w.refs == 0) std.heap.c_allocator.destroy(w);
    }

    fn timedOut(p: ?*anyopaque) callconv(.c) void {
        const w: *Waiter = @ptrCast(@alignCast(p.?));
        w.fire();
    }
};

/// `whenStarted(within:_:)`: `then(b)` once every extension switched on
/// has loaded, or after `limit` seconds — for a page that should have its
/// extensions' early scripts, and shouldn't wait forever for them.
pub fn whenStarted(self: *Extensions, limit: f64, b: *Browser, then: *const fn (*Browser) void) void {
    if (!starting(self)) return then(b);
    const w = std.heap.c_allocator.create(Waiter) catch return then(b);
    w.* = .{ .serial = self.serial, .browser = b, .then = then };
    self.on_started.append(self.gpa, w) catch {
        std.heap.c_allocator.destroy(w);
        return then(b);
    };
    objc.dispatchAfter(@intFromFloat(limit * std.time.ns_per_s), w, Waiter.timedOut);
}

fn markStarted(self: *Extensions) void {
    self.started = true;
    var waiting = self.on_started;
    self.on_started = .empty;
    defer waiting.deinit(self.gpa);
    for (waiting.items) |w| w.fire();
}

// MARK: workers WebKit remembers

/// WebKit keeps each extension's service worker registered from one launch
/// to the next and may start that stale copy; cleared at launch, before any
/// extension loads, only when what they would run has changed since.
const workers_key = "extensions.workers";

fn workers(self: *Extensions) ![]u8 {
    const gpa = self.gpa;
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (self.installed.items) |r| try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {s}", .{ r.id, r.version }));
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, shims.version());
    for (lines.items) |l| {
        try out.append(gpa, '\n');
        try out.appendSlice(gpa, l);
    }
    return out.toOwnedSlice(gpa);
}

fn forgetWorkersIfChanged(self: *Extensions, job: *Start) void {
    const now = workers(self) catch return job.workersDone();
    defer self.gpa.free(now);
    const kept = self.kea.store.string(workers_key);
    defer if (kept) |k| self.gpa.free(k);
    if (kept != null and std.mem.eql(u8, kept.?, now)) return job.workersDone();
    self.kea.store.setString(workers_key, now);
    const pool = objc.Pool.push();
    defer pool.pop();
    const types = objc.msg(objc.Object, objc.class("NSSet"), "setWithObject:", .{objc.nsString("WKWebsiteDataTypeServiceWorkerRegistrations")});
    const past = objc.msg(objc.Object, objc.class("NSDate"), "distantPast", .{});
    var block = objc.Block(Start, &.{}).init(job, Start.workersDone);
    objc.msg(void, self.websites, "removeDataOfTypes:modifiedSince:completionHandler:", .{ types, past, &block });
}

/// Put in again, reloaded or revived: the next launch clears regardless.
pub fn workersChanged(self: *Extensions) void {
    self.kea.store.remove(workers_key);
}

// MARK: loading

pub const Then = *const fn (*anyopaque, bool) void;

/// One extension being loaded (`load(_:)`).
pub const Load = struct {
    serial: u64,
    gpa: std.mem.Allocator,
    id: []u8,
    folder: []u8,
    source: bool,
    failed: bool = false,
    found: ?objc.Object = null,
    why: ?[]u8 = null,
    ctx: ?*anyopaque,
    then: ?Then,

    /// Let go with no answer (the controller going away).
    pub fn drop(l: *Load) void {
        if (l.found) |f| objc.release(f);
        if (l.why) |w| l.gpa.free(w);
        l.gpa.free(l.id);
        l.gpa.free(l.folder);
        l.gpa.destroy(l);
    }

    fn finish(l: *Load, ok: bool) void {
        const ctx = l.ctx;
        const then = l.then;
        l.drop();
        if (then) |f| f(ctx.?, ok);
    }

    /// Its data cleared (or not): on with the load.
    pub fn go(l: *Load) void {
        offMain(Load, l, prepare, prepared);
    }

    fn prepare(l: *Load) void {
        // One installed from a folder before links were looked at.
        if (l.source) {
            @import("controller_install.zig").unlinkOutside(l.gpa, l.folder) catch {
                l.failed = true;
                return;
            };
        }
        // The shim this build carries, in place of the one that installed it.
        shims.prepare(l.gpa, l.folder, false) catch {};
    }

    fn prepared(l: *Load) void {
        if (controller.alive(l.serial) == null) return l.finish(false);
        if (l.failed) return l.finish(false);
        openExtension(Load, l, l.folder, opened);
    }

    fn opened(l: *Load) void {
        const self = controller.alive(l.serial) orelse return l.finish(false);
        const found = l.found orelse {
            log.warn("Extensions: couldn't load {s}: {s}", .{ l.id, l.why orelse "" });
            return l.finish(false);
        };
        l.finish(made(self, l.id, found));
    }
};

/// `load(_:)`: `then(ctx, ok)` once it loaded or didn't (null: nobody waits).
pub fn load(self: *Extensions, id: []const u8, ctx: ?*anyopaque, then: ?Then) void {
    const r = self.row(id) orelse return if (then) |f| f(ctx.?, false);
    const l = self.gpa.create(Load) catch return if (then) |f| f(ctx.?, false);
    const folder = self.folderFor(id) catch {
        self.gpa.destroy(l);
        return if (then) |f| f(ctx.?, false);
    };
    l.* = .{ .serial = self.serial, .gpa = self.gpa, .id = self.gpa.dupe(u8, id) catch {
        self.gpa.free(folder);
        self.gpa.destroy(l);
        return if (then) |f| f(ctx.?, false);
    }, .folder = folder, .source = r.source != null, .ctx = ctx, .then = then };
    // What a removal still clears goes first: the same id starts with nothing.
    if (self.forgetting.getPtr(id)) |waiting| {
        waiting.append(self.gpa, l) catch return l.finish(false);
        return;
    }
    l.go();
}

const granted_explicitly: objc.NSInteger = 3;

/// The context made, granted what it was installed with, and loaded.
fn made(self: *Extensions, id: []const u8, found: objc.Object) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const context = objc.msg(objc.Object, objc.class("WKWebExtensionContext"), "contextForExtension:", .{found});
    objc.msg(void, context, "setUniqueIdentifier:", .{objc.nsString(id)});
    // The same origin every launch: what its pages keep is filed under it.
    const base = std.fmt.allocPrint(self.gpa, "{s}://{s}/", .{ @import("ext.zig").scheme, id }) catch return false;
    defer self.gpa.free(base);
    if (objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(base)})) |u| objc.msg(void, context, "setBaseURL:", .{u});
    objc.msg(void, context, "setInspectable:", .{objc.YES});
    // A test run's tabs keep nothing (nonPersistentDataStore, P5.1) where
    // Swift's keep a probe store; WebKit counts those as private and would
    // keep extensions out, so under tests they are let in as in Swift's.
    if (self.kea.opts.root != null) objc.msg(void, context, "setHasAccessToPrivateData:", .{objc.YES});
    // Installing was the consent: everything it asked for then is granted.
    const asked = objc.msg(objc.Object, objc.msg(objc.Object, found, "requestedPermissions", .{}), "allObjects", .{});
    const n = objc.msg(objc.NSUInteger, asked, "count", .{});
    for (0..n) |i| objc.msg(void, context, "setPermissionStatus:forPermission:", .{ granted_explicitly, objc.msg(objc.Object, asked, "objectAtIndex:", .{i}) });
    objc.msg(void, context, "setPermissionStatus:forPermission:", .{ granted_explicitly, objc.nsString("nativeMessaging") });
    fence.grantSites(context);
    // Its own sign-in address, https://<id>.chromiumapp.org, never loaded:
    // one watching its sign-in tab for that address has to see it.
    if (@import("shims/answer.zig").allows(self, id, context, "identity")) {
        const own = std.fmt.allocPrint(self.gpa, "https://{s}.chromiumapp.org/*", .{id}) catch return false;
        defer self.gpa.free(own);
        if (objc.msg(?objc.Object, objc.class("WKWebExtensionMatchPattern"), "matchPatternWithString:", .{objc.nsString(own)})) |p|
            objc.msg(void, context, "setPermissionStatus:forMatchPattern:", .{ granted_explicitly, p });
    }
    fence.fence(context);
    @import("controller_buttons.zig").watchTouches(self);
    var err: ?objc.Object = null;
    if (!objc.msg(objc.BOOL, self.controller, "loadExtensionContext:error:", .{ context, &err })) {
        const why = if (err) |e| objc.fromNSString(objc.msg(objc.Object, e, "localizedDescription", .{})) else "";
        log.warn("Extensions: couldn't load {s}: {s}", .{ id, why });
        return false;
    }
    watch(self, id, context);
    if (self.contexts.getPtr(id)) |old| {
        objc.release(old.*);
        old.* = objc.retain(context);
    } else {
        if (self.loads_this_run.has(id)) _ = self.loaded_before.put(self.gpa, id);
        const key = self.gpa.dupe(u8, id) catch return false;
        self.contexts.put(self.gpa, key, objc.retain(context)) catch {
            self.gpa.free(key);
            return false;
        };
    }
    _ = self.loads_this_run.put(self.gpa, id);
    // Keys you gave its commands in Settings › Shortcuts (#189).
    @import("commands.zig").adopt(self, context, id);
    self.actions_changed += 1;
    self.changed();
    return true;
}

/// `unload(_:)`: it, and what it kept going outside WebKit, gone.
pub fn unload(self: *Extensions, id: []const u8) void {
    const context = self.contexts.get(id) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    @import("../app/browsers.zig").closePopups(self.kea, id);
    _ = objc.msg(objc.BOOL, self.controller, "unloadExtensionContext:error:", .{ context, @as(?*anyopaque, null) });
    @import("offscreen.zig").close(id);
    @import("capture.zig").shared().purge(id);
    @import("shims/answer.zig").releaseAwake(self, id);
    // Its ports read as gone only once WebKit has had a turn.
    objc.dispatchMain(null, stopOrphans);
    unwatch(self, id);
    const kv = self.contexts.fetchOrderedRemove(id).?;
    objc.release(kv.value);
    self.gpa.free(kv.key);
    self.actions_changed += 1;
    self.changed();
}

fn stopOrphans(_: ?*anyopaque) callconv(.c) void {
    @import("native.zig").stopOrphans();
}

// MARK: a worker that won't start

/// One context's `errorsDidUpdateNotification`, heard.
const Watcher = struct { serial: u64, id: []u8, context: objc.Object };

fn watcherClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigExtensionErrors",
        .methods = &.{.{ .name = "errorsChanged:", .imp = &errorsChanged, .types = "v@:@" }},
    });
}

fn watch(self: *Extensions, id: []const u8, context: objc.Object) void {
    unwatch(self, id);
    const w = std.heap.c_allocator.create(Watcher) catch return;
    w.* = .{ .serial = self.serial, .id = std.heap.c_allocator.dupe(u8, id) catch return std.heap.c_allocator.destroy(w), .context = context };
    const o = objc.msg(objc.Object, watcherClass(), "new", .{});
    objc.setZig(o, w);
    const key = self.gpa.dupe(u8, id) catch return dropWatcher(o);
    self.error_watchers.put(self.gpa, key, o) catch {
        self.gpa.free(key);
        return dropWatcher(o);
    };
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    objc.msg(void, center, "addObserver:selector:name:object:", .{ o, objc.sel("errorsChanged:"), objc.nsString("WKWebExtensionContextErrorsDidUpdateNotification"), context });
}

fn unwatch(self: *Extensions, id: []const u8) void {
    const kv = self.error_watchers.fetchSwapRemove(id) orelse return;
    const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
    objc.msg(void, center, "removeObserver:", .{kv.value});
    dropWatcher(kv.value);
    self.gpa.free(kv.key);
}

pub fn dropWatcher(o: objc.Object) void {
    if (objc.getZig(Watcher, o)) |w| {
        std.heap.c_allocator.free(w.id);
        std.heap.c_allocator.destroy(w);
    }
    objc.setZig(o, null);
    objc.release(o);
}

/// WebKit records a worker that failed to start as an error on its
/// context, and doesn't try again: taken up afresh as soon as that shows.
fn errorsChanged(o: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const w = objc.getZig(Watcher, o) orelse return;
    const self = controller.alive(w.serial) orelse return;
    if (self.contexts.get(w.id) != w.context) return;
    const errs = objc.msg(objc.Object, w.context, "errors", .{});
    const n = objc.msg(objc.NSUInteger, errs, "count", .{});
    var failed = false;
    for (0..n) |i| {
        const e = objc.msg(objc.Object, errs, "objectAtIndex:", .{i});
        const domain = objc.fromNSString(objc.msg(objc.Object, e, "domain", .{}));
        // WKWebExtensionContextErrorBackgroundContentFailedToLoad.
        if (std.mem.eql(u8, domain, "WKWebExtensionContextErrorDomain") and objc.msg(objc.NSInteger, e, "code", .{}) == 6) failed = true;
    }
    if (!failed) return;
    const later = std.heap.c_allocator.create(Watcher) catch return;
    later.* = .{ .serial = w.serial, .id = std.heap.c_allocator.dupe(u8, w.id) catch return std.heap.c_allocator.destroy(later), .context = w.context };
    objc.dispatchAfter(2 * std.time.ns_per_s, later, reviveLater);
}

fn reviveLater(p: ?*anyopaque) callconv(.c) void {
    const w: *Watcher = @ptrCast(@alignCast(p.?));
    defer {
        std.heap.c_allocator.free(w.id);
        std.heap.c_allocator.destroy(w);
    }
    const self = controller.alive(w.serial) orelse return;
    if (self.contexts.get(w.id) != w.context) return;
    revive(self, w.id, "its worker failed to start");
}

/// `revive(_:because:)`: unloaded and loaded, as a relaunch would — at
/// most once a minute, so one that can never start doesn't go round.
pub fn revive(self: *Extensions, id: []const u8, because: []const u8) void {
    const r = self.row(id) orelse return;
    if (!r.enabled) return;
    const now = json.now();
    if (self.revived.get(id)) |last| if (now - last <= 60) return;
    if (self.revived.getPtr(id)) |v| v.* = now else {
        const key = self.gpa.dupe(u8, id) catch return;
        self.revived.put(self.gpa, key, now) catch return self.gpa.free(key);
    }
    workersChanged(self);
    const note = std.fmt.allocPrint(self.gpa, "restarted the extension: {s}", .{because}) catch return;
    defer self.gpa.free(note);
    self.noteError(note, id);
    // Its popup goes with it; opened again once the extension is back.
    const job = self.gpa.create(Revive) catch return;
    job.* = .{ .serial = self.serial, .gpa = self.gpa, .id = self.gpa.dupe(u8, id) catch return self.gpa.destroy(job) };
    if (self.del.popup_request) |p| if (std.mem.eql(u8, p.id, id)) {
        job.popup = self.gpa.dupe(u8, p.url) catch null;
    };
    // `id` may be a key `unload` frees: the job's own copy from here.
    unload(self, job.id);
    load(self, job.id, job, Revive.loaded);
}

const Revive = struct {
    serial: u64,
    gpa: std.mem.Allocator,
    id: []u8,
    popup: ?[]u8 = null,

    fn loaded(p: *anyopaque, ok: bool) void {
        const job: *Revive = @ptrCast(@alignCast(p));
        defer {
            if (job.popup) |u| job.gpa.free(u);
            job.gpa.free(job.id);
            job.gpa.destroy(job);
        }
        const self = controller.alive(job.serial) orelse return;
        const url = job.popup orelse return;
        if (!ok) return;
        const context = self.context(job.id) orelse return;
        // Its button as it is now: the one it hung from may have gone.
        @import("controller_buttons.zig").showPopup(self, url, context, job.id);
    }
};
