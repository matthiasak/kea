//! Removing (Extensions.swift 773-857, 1986-2015): an extension taken out,
//! and what it kept cleared — its chrome.storage, which WebKit keeps by id,
//! and what its pages kept at chrome-extension://<id>, cleared from a blank
//! page at that origin hosted by a stand-in with nothing of its own.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const controller = @import("controller.zig");
const Extensions = controller.Extensions;
const load_ops = @import("controller_load.zig");
const install_ops = @import("controller_install.zig");
const disk = @import("../data/disk.zig");
const ext = @import("ext.zig");

const log = std.log.scoped(.extensions);

/// Ids whose data is still to clear, kept until it is: a quit or a crash
/// in the middle would leave it for the next extension at the same path.
const forgetting_key = "extensions.forgetting";

const forget_script =
    \\localStorage.clear();
    \\for (const db of await indexedDB.databases()) {
    \\    await new Promise(done => { const q = indexedDB.deleteDatabase(db.name); q.onsuccess = q.onerror = q.onblocked = done; });
    \\}
    \\for (const key of await caches.keys()) await caches.delete(key);
;

/// `remove(_:)`.
pub fn remove(self: *Extensions, id_: []const u8) void {
    const gpa = self.gpa;
    // The row's id goes with the row.
    const id = gpa.dupe(u8, id_) catch return;
    defer gpa.free(id);
    load_ops.unload(self, id);
    @import("external.zig").generation +%= 1;
    @import("capture.zig").forget(self, id);
    self.clearErrors(id);
    self.setSettings(id, .null);
    var buf: [160]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "extensions.granted.{s}", .{id})) |k| self.kea.store.remove(k) else |_| {}
    self.loads_this_run.remove(gpa, id);
    self.loaded_before.remove(gpa, id);
    if (std.fmt.bufPrint(&buf, "extensions.newtab.{s}", .{id})) |k| self.kea.store.remove(k) else |_| {}
    if (self.rowIndex(id)) |i| controller.freeRow(gpa, self.installed.orderedRemove(i));
    self.save();
    if (self.folderFor(id)) |folder| {
        defer gpa.free(folder);
        install_ops.removeItem(folder);
    } else |_| {}
    var left = leftOver(self);
    defer freeList(gpa, &left);
    const known = for (left.items) |l| {
        if (std.mem.eql(u8, l, id)) break true;
    } else false;
    if (!known) if (gpa.dupe(u8, id)) |copy| left.append(gpa, copy) catch gpa.free(copy) else |_| {};
    setLeftOver(self, left.items);
    forgetData(self, id, null, null);
}

fn freeList(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |s| gpa.free(s);
    list.deinit(gpa);
}

/// `extensions.forgetting`, on gpa.
fn leftOver(self: *Extensions) std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    const pool = objc.Pool.push();
    defer pool.pop();
    const arr = objc.msg(?objc.Object, self.kea.store.defaults, "stringArrayForKey:", .{objc.nsString(forgetting_key)}) orelse return out;
    const n = objc.msg(objc.NSUInteger, arr, "count", .{});
    for (0..n) |i| {
        const s = self.gpa.dupe(u8, objc.fromNSString(objc.msg(objc.Object, arr, "objectAtIndex:", .{i}))) catch continue;
        out.append(self.gpa, s) catch self.gpa.free(s);
    }
    return out;
}

fn setLeftOver(self: *Extensions, ids: []const []u8) void {
    if (ids.len == 0) return self.kea.store.remove(forgetting_key);
    const pool = objc.Pool.push();
    defer pool.pop();
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (ids) |s| objc.msg(void, arr, "addObject:", .{objc.nsString(s)});
    objc.msg(void, self.kea.store.defaults, "setObject:forKey:", .{ arr, objc.nsString(forgetting_key) });
}

/// `forgotten(_:)`: its data is gone; no longer to clear.
fn forgotten(self: *Extensions, id: []const u8) void {
    var left = leftOver(self);
    defer freeList(self.gpa, &left);
    var i: usize = 0;
    while (i < left.items.len) {
        if (std.mem.eql(u8, left.items[i], id)) self.gpa.free(left.orderedRemove(i)) else i += 1;
    }
    setLeftOver(self, left.items);
}

/// `forgetLeftOver()`: at launch, before anything loads, what a removal
/// didn't finish clearing; then `then(ctx)`.
pub fn forgetLeftOver(self: *Extensions, ctx: *anyopaque, then: *const fn (*anyopaque) void) void {
    const job = self.gpa.create(LeftOver) catch return then(ctx);
    job.* = .{ .serial = self.serial, .gpa = self.gpa, .ids = leftOver(self), .ctx = ctx, .then = then };
    job.step();
}

const LeftOver = struct {
    serial: u64,
    gpa: std.mem.Allocator,
    ids: std.ArrayList([]u8),
    next: usize = 0,
    ctx: *anyopaque,
    then: *const fn (*anyopaque) void,

    fn step(j: *LeftOver) void {
        const self = controller.alive(j.serial) orelse return j.done();
        while (j.next < j.ids.items.len) {
            const id = j.ids.items[j.next];
            j.next += 1;
            if (self.forgetting.contains(id)) continue;
            return forgetData(self, id, j, cleared);
        }
        j.done();
    }

    fn cleared(p: *anyopaque, _: bool) void {
        const j: *LeftOver = @ptrCast(@alignCast(p));
        j.step();
    }

    fn done(j: *LeftOver) void {
        const ctx = j.ctx;
        const then = j.then;
        freeList(j.gpa, &j.ids);
        j.gpa.destroy(j);
        then(ctx);
    }
};

/// `forgetData(of:)`: `then(ctx, cleared)`, all of it or not. Loads of the
/// same id wait for it (`forgetting`).
fn forgetData(self: *Extensions, id: []const u8, ctx: ?*anyopaque, then: ?load_ops.Then) void {
    const gpa = self.gpa;
    const entry = self.forgetting.getOrPut(gpa, id) catch return if (then) |f| f(ctx.?, false);
    if (!entry.found_existing) {
        entry.key_ptr.* = gpa.dupe(u8, id) catch {
            self.forgetting.swapRemoveAt(entry.index);
            return if (then) |f| f(ctx.?, false);
        };
        entry.value_ptr.* = .empty;
    }
    const j = gpa.create(Forget) catch return if (then) |f| f(ctx.?, false);
    j.* = .{ .serial = self.serial, .gpa = gpa, .id = gpa.dupe(u8, id) catch {
        gpa.destroy(j);
        return if (then) |f| f(ctx.?, false);
    }, .ctx = ctx, .then = then };
    const pool = objc.Pool.push();
    defer pool.pop();
    const types = objc.msg(objc.Object, objc.class("WKWebExtensionController"), "allExtensionDataTypes", .{});
    var block = objc.Block(Forget, &.{objc.Object}).init(j, Forget.records);
    objc.msg(void, self.controller, "fetchDataRecordsOfTypes:completionHandler:", .{ types, &block });
}

const Forget = struct {
    serial: u64,
    gpa: std.mem.Allocator,
    id: []u8,
    ctx: ?*anyopaque,
    then: ?load_ops.Then,
    folder: ?[]u8 = null,
    found: ?objc.Object = null,
    why: ?[]u8 = null,
    stand_in: ?objc.Object = null,
    web: ?objc.Object = null,
    page: ?objc.Object = null,
    /// The job and the page's time limit, each holding it.
    refs: u8 = 1,
    settled: bool = false,

    fn records(j: *Forget, all: objc.Object) void {
        const self = controller.alive(j.serial) orelse return j.finish(false);
        const pool = objc.Pool.push();
        defer pool.pop();
        const mine = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
        const n = objc.msg(objc.NSUInteger, all, "count", .{});
        for (0..n) |i| {
            const r = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
            if (std.mem.eql(u8, objc.fromNSString(objc.msg(objc.Object, r, "uniqueIdentifier", .{})), j.id)) objc.msg(void, mine, "addObject:", .{r});
        }
        if (objc.msg(objc.NSUInteger, mine, "count", .{}) == 0) return j.standIn();
        const types = objc.msg(objc.Object, objc.class("WKWebExtensionController"), "allExtensionDataTypes", .{});
        var block = objc.Block(Forget, &.{}).init(j, standIn);
        objc.msg(void, self.controller, "removeDataOfTypes:fromDataRecords:completionHandler:", .{ types, mine, &block });
    }

    /// A stand-in at the same origin, with no worker, scripts or pages.
    fn standIn(j: *Forget) void {
        if (controller.alive(j.serial) == null) return j.finish(false);
        const pool = objc.Pool.push();
        defer pool.pop();
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        const tmp = objc.fromNSString(objc.msg(objc.Object, objc.msg(objc.Object, fm, "temporaryDirectory", .{}), "path", .{}));
        const uuid = objc.fromNSString(objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSUUID"), "UUID", .{}), "UUIDString", .{}));
        const folder = std.fmt.allocPrint(j.gpa, "{s}/kea-forget-{s}", .{ tmp, uuid }) catch return j.finish(false);
        j.folder = folder;
        disk.makePath(j.gpa, folder);
        const manifest = std.fs.path.join(j.gpa, &.{ folder, "manifest.json" }) catch return j.finish(false);
        defer j.gpa.free(manifest);
        const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ manifest_text.ptr, manifest_text.len });
        if (!objc.msg(objc.BOOL, d, "writeToFile:atomically:", .{ objc.nsString(manifest), objc.YES })) {
            log.warn("Extensions: couldn't clear what {s} kept: no stand-in", .{j.id});
            return j.finish(false);
        }
        load_ops.openExtension(Forget, j, folder, opened);
    }

    const manifest_text = "{\"manifest_version\": 3, \"name\": \"Kea\", \"version\": \"1\"}";

    fn opened(j: *Forget) void {
        const self = controller.alive(j.serial) orelse return j.finish(false);
        const found = j.found orelse {
            log.warn("Extensions: couldn't clear what {s} kept: {s}", .{ j.id, j.why orelse "" });
            return j.finish(false);
        };
        const pool = objc.Pool.push();
        defer pool.pop();
        const context = objc.retain(objc.msg(objc.Object, objc.class("WKWebExtensionContext"), "contextForExtension:", .{found}));
        j.stand_in = context;
        objc.msg(void, context, "setUniqueIdentifier:", .{objc.nsString(j.id)});
        const base_text = std.fmt.allocPrint(j.gpa, "{s}://{s}/", .{ ext.scheme, j.id }) catch return j.finish(false);
        defer j.gpa.free(base_text);
        const base = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(base_text)}) orelse return j.finish(false);
        objc.msg(void, context, "setBaseURL:", .{base});
        var err: ?objc.Object = null;
        if (!objc.msg(objc.BOOL, self.controller, "loadExtensionContext:error:", .{ context, &err })) {
            const why = if (err) |e| objc.fromNSString(objc.msg(objc.Object, e, "localizedDescription", .{})) else "";
            log.warn("Extensions: couldn't clear what {s} kept: {s}", .{ j.id, why });
            objc.release(context);
            j.stand_in = null;
            return j.finish(false);
        }
        const configuration = objc.msg(?objc.Object, context, "webViewConfiguration", .{}) orelse return j.finish(false);
        // `HiddenPage`: an empty page at `base`, loaded within 10 seconds.
        const web = objc.msg(objc.Object, objc.alloc("WKWebView"), "initWithFrame:configuration:", .{ objc.CGRect{}, configuration });
        j.web = web;
        const page = objc.msg(objc.Object, pageClass(), "new", .{});
        objc.setZig(page, j);
        j.page = page;
        objc.msg(void, web, "setNavigationDelegate:", .{page});
        j.refs += 1;
        objc.dispatchAfter(10 * std.time.ns_per_s, j, timedOut);
        objc.msg(void, web, "loadHTMLString:baseURL:", .{ objc.nsString("<!doctype html>"), base });
    }

    fn timedOut(p: ?*anyopaque) callconv(.c) void {
        const j: *Forget = @ptrCast(@alignCast(p.?));
        if (!j.settled) j.loaded(false);
        j.release();
    }

    fn loaded(j: *Forget, ok: bool) void {
        if (j.settled) return;
        j.settled = true;
        if (!ok) {
            log.warn("Extensions: couldn't open {s} to clear what it kept", .{j.id});
            return j.finish(false);
        }
        const pool = objc.Pool.push();
        defer pool.pop();
        const world = objc.msg(objc.Object, objc.class("WKContentWorld"), "defaultClientWorld", .{});
        var block = objc.Block(Forget, &.{ ?objc.Object, ?objc.Object }).init(j, ran);
        objc.msg(void, j.web.?, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", .{ objc.nsString(forget_script), @as(?objc.Object, null), @as(?objc.Object, null), world, &block });
    }

    fn ran(j: *Forget, _: ?objc.Object, err: ?objc.Object) void {
        if (err) |e| {
            log.warn("Extensions: couldn't clear what {s} kept: {s}", .{ j.id, objc.fromNSString(objc.msg(objc.Object, e, "localizedDescription", .{})) });
            return j.finish(false);
        }
        j.finish(true);
    }

    fn finish(j: *Forget, ok: bool) void {
        j.settled = true;
        const pool = objc.Pool.push();
        defer pool.pop();
        if (j.web) |w| {
            objc.msg(void, w, "setNavigationDelegate:", .{@as(?objc.Object, null)});
            objc.release(w);
            j.web = null;
        }
        if (j.page) |p| {
            objc.setZig(p, null);
            objc.release(p);
            j.page = null;
        }
        const self = controller.alive(j.serial);
        if (j.stand_in) |c| {
            if (self) |s| _ = objc.msg(objc.BOOL, s.controller, "unloadExtensionContext:error:", .{ c, @as(?*anyopaque, null) });
            objc.release(c);
            j.stand_in = null;
        }
        if (j.folder) |f| install_ops.removeItem(f);
        if (self) |s| {
            if (ok) forgotten(s, j.id);
            // Loads of the same id waited for this.
            if (s.forgetting.fetchSwapRemove(j.id)) |kv| {
                var waiting = kv.value;
                s.gpa.free(kv.key);
                defer waiting.deinit(s.gpa);
                for (waiting.items) |l| l.go();
            }
        }
        if (j.then) |f| f(j.ctx.?, ok);
        j.release();
    }

    fn release(j: *Forget) void {
        j.refs -= 1;
        if (j.refs > 0) return;
        if (j.found) |f| objc.release(f);
        for ([_]?[]u8{ j.folder, j.why }) |s| if (s) |x| j.gpa.free(x);
        j.gpa.free(j.id);
        j.gpa.destroy(j);
    }
};

fn pageClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaForgetPage",
        .protocols = &.{"WKNavigationDelegate"},
        .methods = &.{
            .{ .name = "webView:didFinishNavigation:", .imp = &didFinish, .types = "v@:@@" },
            .{ .name = "webView:didFailNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
            .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &didFail, .types = "v@:@@@" },
        },
    });
}

fn didFinish(o: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    if (objc.getZig(Forget, o)) |j| j.loaded(true);
}

fn didFail(o: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object, _: objc.Object) callconv(.c) void {
    if (objc.getZig(Forget, o)) |j| j.loaded(false);
}
