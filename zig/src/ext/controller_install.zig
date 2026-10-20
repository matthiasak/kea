//! Installing and reloading (Extensions.swift 131-152, 528-684, 738-771,
//! 876-888): from the store by id or link, from a folder, taken up again
//! from where it came; asked about, moved into place and loaded. Swift's
//! `async` chains are jobs here, one step per callback.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const controller = @import("controller.zig");
const Extensions = controller.Extensions;
const Installed = controller.Installed;
const json = @import("../data/json.zig");
const disk = @import("../data/disk.zig");
const crx = @import("crx.zig");
const files = @import("files.zig");
const fence = @import("controller_fence.zig");
const asking = @import("controller_asking.zig");
const load_ops = @import("controller_load.zig");
const shims = @import("shims/install.zig");
const Tab = @import("../web/tab.zig").Tab;

// MARK: files

fn fileManager() objc.Object {
    return objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
}

fn exists(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return objc.msg(objc.BOOL, fileManager(), "fileExistsAtPath:", .{objc.nsString(path)});
}

pub fn removeItem(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.BOOL, fileManager(), "removeItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) });
}

/// `copyItem(at: source.resolvingSymlinksInPath(), to:)`: the folder
/// itself, wherever a link to it leads. The error's description on `gpa`.
fn copyResolved(gpa: std.mem.Allocator, source: []const u8, to: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const from = objc.msg(objc.Object, objc.nsString(source), "stringByResolvingSymlinksInPath", .{});
    var err: ?objc.Object = null;
    if (objc.msg(objc.BOOL, fileManager(), "copyItemAtPath:toPath:error:", .{ from, objc.nsString(to), &err })) return null;
    const why = if (err) |e| objc.fromNSString(objc.msg(objc.Object, e, "localizedDescription", .{})) else "couldn't copy";
    return gpa.dupe(u8, why) catch null;
}

/// `unlinkOutside(_:)`: a link stays only if what it names is there and
/// inside the package; one leading anywhere else, or nowhere, is taken
/// out. Fails if one couldn't be. Safe off the main thread.
pub fn unlinkOutside(gpa: std.mem.Allocator, root: []const u8) !void {
    const base = crx.realPath(gpa, root) catch return;
    defer gpa.free(base);
    const inside = try std.mem.concat(gpa, u8, &.{ base, "/" });
    defer gpa.free(inside);
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = fileManager();
    const found = objc.msg(?objc.Object, fm, "enumeratorAtPath:", .{objc.nsString(root)}) orelse return;
    while (objc.msg(?objc.Object, found, "nextObject", .{})) |rel| {
        const attrs = objc.msg(?objc.Object, found, "fileAttributes", .{}) orelse continue;
        const kind = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("NSFileType")});
        if (!std.mem.eql(u8, objc.fromNSString(kind), "NSFileTypeSymbolicLink")) continue;
        const item = try std.fs.path.join(gpa, &.{ root, objc.fromNSString(rel) });
        defer gpa.free(item);
        const z = try gpa.dupeSentinel(u8, item, 0);
        defer gpa.free(z);
        var kept = false;
        if (realpath(z, null)) |real| {
            kept = std.mem.startsWith(u8, std.mem.span(real), inside);
            std.c.free(real);
        }
        if (!kept and !objc.msg(objc.BOOL, fm, "removeItemAtPath:error:", .{ objc.nsString(item), @as(?*anyopaque, null) })) return error.Unlink;
    }
}

extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;

/// `stagingFolder(for:)`: `.staging-<id>-<UUID>` beside the installed ones.
pub fn stagingFolder(self: *Extensions, id: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const uuid = objc.fromNSString(objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSUUID"), "UUID", .{}), "UUIDString", .{}));
    return std.fmt.allocPrint(self.gpa, "{s}/Extensions/.staging-{s}-{s}", .{ self.kea.store.folder, id, uuid });
}

/// Every one of `a` in `b`.
pub fn isSubset(a: []const []const u8, b: []const []const u8) bool {
    outer: for (a) |x| {
        for (b) |y| if (std.mem.eql(u8, x, y)) continue :outer;
        return false;
    }
    return true;
}

// MARK: the job

pub const Kind = enum { store, folder, reload, update };

/// One install, reload or update on its way (Swift's `Task`).
pub const Job = struct {
    serial: u64,
    gpa: std.mem.Allocator,
    kind: Kind,
    id: []u8,
    target: []u8,
    staged: ?[]u8 = null,
    /// A folder loaded unpacked: where (links resolved).
    source: ?[]u8 = null,
    confirm: bool = true,
    /// The off-main step's failure, said.
    failed: ?[]u8 = null,
    found: ?objc.Object = null,
    why: ?[]u8 = null,
    bytes: ?[]u8 = null,
    /// Reload/update: the row as it was.
    original: ?Installed = null,
    wants: ?[]const []u8 = null,
    /// Update: the version the store offers.
    version: ?[]u8 = null,
    ctx: ?*anyopaque = null,
    then: ?*const fn (*anyopaque) void = null,

    pub fn make(self: *Extensions, kind: Kind, id: []const u8) !*Job {
        const j = try self.gpa.create(Job);
        errdefer self.gpa.destroy(j);
        const own = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(own);
        j.* = .{ .serial = self.serial, .gpa = self.gpa, .kind = kind, .id = own, .target = try self.folderFor(id) };
        return j;
    }

    /// Done: what was staged goes, and whoever waits hears.
    pub fn finish(j: *Job) void {
        const gpa = j.gpa;
        if (j.staged) |s| {
            removeItem(s);
            gpa.free(s);
        }
        if (controller.alive(j.serial)) |self| switch (j.kind) {
            .store => self.setBusy(null),
            .reload => self.reloading.remove(gpa, j.id),
            else => {},
        };
        for ([_]?[]u8{ j.source, j.failed, j.why, j.bytes, j.version }) |s| if (s) |x| gpa.free(x);
        if (j.found) |f| objc.release(f);
        if (j.original) |r| controller.freeRow(gpa, r);
        if (j.wants) |w| fence.freeAll(gpa, w);
        gpa.free(j.id);
        gpa.free(j.target);
        const ctx = j.ctx;
        const then = j.then;
        gpa.destroy(j);
        if (then) |f| f(ctx.?);
    }

    /// The step went wrong: said as Swift's `catch` says it.
    pub fn fail(j: *Job, why: []const u8) void {
        if (controller.alive(j.serial)) |self| switch (j.kind) {
            .store => self.announceFmt("{s}", .{why}),
            .folder => self.announceFmt("Couldn't install the extension: {s}", .{why}),
            .update => std.log.scoped(.extensions).warn("Extensions: update of {s} failed: {s}", .{ j.id, why }),
            .reload => self.announceFmt("{s}", .{why}),
        };
        j.finish();
    }

    /// The staged copy's own name, or the id.
    fn name(j: *Job) []const u8 {
        if (j.found) |f| if (load_ops.text(f, "displayName")) |n| return n;
        return j.id;
    }
};

// MARK: from the store

/// `install(from:confirm:)`: a store link or an id, from the field in
/// Settings or the bar on a store page. `confirm` false is the test
/// bench's only — the real browser never passes it.
pub fn installFrom(self: *Extensions, text: []const u8, confirm: bool) void {
    const id = crx.id(text) orelse return self.announceFmt("{s}", .{crx.not_an_id});
    if (self.row(&id) != null) return self.announceFmt("Already installed", .{});
    self.setBusy(&id);
    installId(self, &id, confirm, null, null);
}

/// `install(id:confirm:)`: one from the store, done — asked about, and
/// installed or not — before `then(ctx)`, so several brought over from
/// another browser go one after another.
pub fn installId(self: *Extensions, id: []const u8, confirm: bool, ctx: ?*anyopaque, then: ?*const fn (*anyopaque) void) void {
    const valid = id.len == 32 and for (id) |c| {
        if (c < 'a' or c > 'p') break false;
    } else true;
    if (!valid or self.row(id) != null) return if (then) |f| f(ctx.?);
    const j = Job.make(self, .store, id) catch return if (then) |f| f(ctx.?);
    j.ctx = ctx;
    j.then = then;
    j.confirm = confirm or self.kea.opts.root == null;
    self.setBusy(id);
    j.staged = stagingFolder(self, id) catch return j.finish();
    crx.fetch(self.gpa, id, j, fetched);
}

/// The .crx came (or didn't): checked, unpacked and shimmed off the main thread.
pub fn fetched(j: *Job, got: crx.Fetched) void {
    switch (got) {
        .fail => |why| {
            defer j.gpa.free(why);
            j.fail(why);
        },
        .ok => |bytes| {
            j.bytes = bytes;
            load_ops.offMain(Job, j, unpackStaged, staged);
        },
    }
}

/// Off the main thread: checked, unpacked and shimmed into `staged`.
fn unpackStaged(j: *Job) void {
    const zip = crx.verifiedZip(j.gpa, j.bytes.?, j.id) catch |e| return failWith(j, crx.describe(e));
    defer j.gpa.free(zip);
    crx.unpack(j.gpa, zip, j.staged.?) catch |e| return failWith(j, crx.describe(e));
    shims.prepare(j.gpa, j.staged.?, true) catch |e| return failWith(j, crx.describe(e));
}

fn failWith(j: *Job, why: []const u8) void {
    j.failed = j.gpa.dupe(u8, why) catch null;
    if (j.failed == null) j.failed = &.{};
}

fn staged(j: *Job) void {
    if (controller.alive(j.serial) == null) return j.finish();
    // Reload says its own failure ("Couldn't copy … again").
    if (j.kind == .reload) return reloadOpen(j);
    if (j.failed) |why| return j.fail(why);
    switch (j.kind) {
        .store, .folder => admit(j),
        .reload => reloadOpen(j),
        .update => @import("controller_updates.zig").unpacked(j),
    }
}

// MARK: from a folder

/// `installFolder()`: an unpacked extension from disk, chosen.
pub fn installFolder(self: *Extensions) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{});
    objc.msg(void, panel, "setCanChooseDirectories:", .{objc.YES});
    objc.msg(void, panel, "setCanChooseFiles:", .{objc.NO});
    objc.msg(void, panel, "setPrompt:", .{objc.nsString("Load Extension")});
    objc.msg(void, panel, "setMessage:", .{objc.nsString("Choose the folder that holds the extension's manifest.json.")});
    if (objc.msg(objc.NSInteger, panel, "runModal", .{}) != 1) return;
    const url = objc.msg(?objc.Object, panel, "URL", .{}) orelse return;
    installFolderAt(self, objc.fromNSString(objc.msg(objc.Object, url, "path", .{})), true);
}

/// `installFolder(at:confirm:)`: copied in, so moving the original breaks
/// nothing.
pub fn installFolderAt(self: *Extensions, path: []const u8, confirm: bool) void {
    const manifest = std.fs.path.join(self.gpa, &.{ path, "manifest.json" }) catch return;
    defer self.gpa.free(manifest);
    if (!exists(manifest)) return self.announceFmt("That folder has no manifest.json", .{});
    const source = crx.realPath(self.gpa, path) catch return;
    const id = crx.unpackedID(self.gpa, source) catch {
        self.gpa.free(source);
        return;
    };
    if (self.row(&id) != null) {
        self.gpa.free(source);
        return self.announceFmt("Already installed. Press Reload to take its changes", .{});
    }
    const j = Job.make(self, .folder, &id) catch return self.gpa.free(source);
    j.source = source;
    j.confirm = confirm or self.kea.opts.root == null;
    j.staged = stagingFolder(self, &id) catch return j.finish();
    load_ops.offMain(Job, j, copyStaged, staged);
}

/// Off the main thread: the folder copied, unlinked and shimmed.
fn copyStaged(j: *Job) void {
    const parent = std.fs.path.dirname(j.staged.?).?;
    disk.makePath(j.gpa, parent);
    if (copyResolved(j.gpa, j.source.?, j.staged.?)) |why| {
        j.failed = why;
        return;
    }
    unlinkOutside(j.gpa, j.staged.?) catch return failWith(j, "a link in it couldn't be taken out");
    shims.prepare(j.gpa, j.staged.?, true) catch |e| return failWith(j, crx.describe(e));
}

// MARK: admitting

/// `admit(_:as:…)`: reads what was unpacked, asks, and — on yes — moves
/// it into place and loads it. On no, nothing is left behind.
fn admit(j: *Job) void {
    load_ops.openExtension(Job, j, j.staged.?, admitOpened);
}

fn admitOpened(j: *Job) void {
    const self = controller.alive(j.serial) orelse return j.finish();
    const found = j.found orelse return j.fail(j.why orelse "");
    if (!j.confirm) return admitAnswered(j, true);
    const pool = objc.Pool.push();
    defer pool.pop();
    const wants = fence.describe(self.gpa, found, j.staged.?) catch return j.finish();
    defer fence.freeAll(self.gpa, wants);
    const icon = objc.msg(?objc.Object, found, "iconForSize:", .{objc.CGSize{ .width = 64, .height = 64 }});
    asking.askInstall(self, j.name(), @ptrCast(wants), icon, j, admitAsked);
}

fn admitAsked(p: *anyopaque, yes: bool) void {
    admitAnswered(@ptrCast(@alignCast(p)), yes);
}

fn admitAnswered(j: *Job, yes: bool) void {
    const self = controller.alive(j.serial) orelse return j.finish();
    if (!yes or self.row(j.id) != null) return j.finish();
    const gpa = self.gpa;
    const pool = objc.Pool.push();
    defer pool.pop();
    const found = j.found.?;
    const permissions = fence.grants(gpa, found, j.staged.?) catch return j.finish();
    files.replace(j.staged.?, j.target) catch |e| {
        fence.freeAll(gpa, permissions);
        const why = files.describe(gpa, e, j.target) catch return j.finish();
        defer gpa.free(why);
        return j.fail(why);
    };
    load_ops.unload(self, j.id);
    self.clearErrors(j.id);
    load_ops.workersChanged(self);
    const item: Installed = .{
        .id = gpa.dupe(u8, j.id) catch return j.finish(),
        .name = gpa.dupe(u8, j.name()) catch return j.finish(),
        .version = gpa.dupe(u8, load_ops.text(found, "version") orelse "?") catch return j.finish(),
        .enabled = true,
        .fromStore = j.kind == .store,
        .permissions = @ptrCast(permissions),
        .source = if (j.source) |s| gpa.dupe(u8, s) catch null else null,
    };
    if (self.rowIndex(j.id)) |i| controller.freeRow(gpa, self.installed.orderedRemove(i));
    self.installed.append(gpa, item) catch return controller.freeRow(gpa, item);
    self.save();
    load_ops.load(self, j.id, j, admitLoaded);
}

fn admitLoaded(p: *anyopaque, ok: bool) void {
    const j: *Job = @ptrCast(@alignCast(p));
    if (controller.alive(j.serial)) |self| {
        const name = if (self.row(j.id)) |r| r.name else j.id;
        if (ok) self.announceFmt("{s} is installed", .{name}) else self.announceFmt("{s} is installed, but WebKit couldn't start it", .{name});
    }
    j.finish();
}

// MARK: reloading

/// `reload(_:)`: taken up again — the way Chrome's reload button does in
/// developer mode. One loaded from a folder is copied in afresh first.
pub fn reload(self: *Extensions, id: []const u8) void {
    const r = self.row(id) orelse return;
    if (!self.reloading.put(self.gpa, id)) return;
    const j = Job.make(self, .reload, id) catch return self.reloading.remove(self.gpa, id);
    j.original = json.clone(self.gpa, r.*) catch return j.finish();
    const original = j.original.?;
    const path = original.source orelse return reloadOpen(j);
    j.staged = stagingFolder(self, id) catch return j.finish();
    const manifest = std.fs.path.join(self.gpa, &.{ path, "manifest.json" }) catch return j.finish();
    defer self.gpa.free(manifest);
    if (!exists(manifest)) {
        self.announceFmt("The folder {s} was loaded from is gone", .{original.name});
        return j.finish();
    }
    if (!sourceKeepsID(self.gpa, original)) {
        self.announceFmt("{s} wasn't reloaded — its folder now leads somewhere else", .{original.name});
        return j.finish();
    }
    j.source = self.gpa.dupe(u8, path) catch return j.finish();
    load_ops.offMain(Job, j, copyStaged, staged);
}

/// `Installed.sourceKeepsID`: whether Reload may copy from `source` under
/// this id — a link put on the way since would bring in another folder.
pub fn sourceKeepsID(gpa: std.mem.Allocator, r: Installed) bool {
    const source = r.source orelse return true;
    if (r.fromStore or std.mem.startsWith(u8, r.id, "local-")) return true;
    const id = crx.unpackedID(gpa, source) catch return false;
    return std.mem.eql(u8, &id, r.id);
}

fn reloadOpen(j: *Job) void {
    const self = controller.alive(j.serial) orelse return j.finish();
    if (j.failed) |why| {
        self.announceFmt("Couldn't copy {s} again: {s}", .{ j.original.?.name, why });
        return j.finish();
    }
    if (self.row(j.id) == null) return j.finish();
    load_ops.openExtension(Job, j, j.staged orelse j.target, reloadOpened);
}

fn reloadOpened(j: *Job) void {
    const self = controller.alive(j.serial) orelse return j.finish();
    const original = j.original.?;
    const found = j.found orelse {
        if (j.staged != null) {
            self.announceFmt("{s} wasn't reloaded — its manifest couldn't be read", .{original.name});
            return j.finish();
        }
        return reloadAnswered(j, true);
    };
    const resource = j.staged orelse j.target;
    const pool = objc.Pool.push();
    defer pool.pop();
    j.wants = fence.grants(self.gpa, found, resource) catch return j.finish();
    if (isSubset(@ptrCast(j.wants.?), original.permissions)) return reloadAnswered(j, true);
    const name = if (load_ops.text(found, "version")) |v|
        std.fmt.allocPrint(self.gpa, "{s} {s}", .{ load_ops.text(found, "displayName") orelse original.name, v }) catch return j.finish()
    else
        self.gpa.dupe(u8, load_ops.text(found, "displayName") orelse original.name) catch return j.finish();
    defer self.gpa.free(name);
    const wants = fence.describe(self.gpa, found, resource) catch return j.finish();
    defer fence.freeAll(self.gpa, wants);
    const icon = objc.msg(?objc.Object, found, "iconForSize:", .{objc.CGSize{ .width = 64, .height = 64 }});
    asking.askInstall(self, name, @ptrCast(wants), icon, j, reloadAsked);
}

fn reloadAsked(p: *anyopaque, yes: bool) void {
    const j: *Job = @ptrCast(@alignCast(p));
    if (!yes) {
        if (controller.alive(j.serial)) |self| self.announceFmt("{s} wasn't reloaded — it asks for more than before", .{j.original.?.name});
        return j.finish();
    }
    reloadAnswered(j, true);
}

fn reloadAnswered(j: *Job, _: bool) void {
    const self = controller.alive(j.serial) orelse return j.finish();
    const gpa = self.gpa;
    const original = j.original.?;
    // Loading and asking both waited: a removed extension stays removed.
    if (self.row(j.id) == null) return j.finish();
    if (j.staged) |s| files.replace(s, j.target) catch |e| {
        const why = files.describe(gpa, e, j.target) catch return j.finish();
        defer gpa.free(why);
        self.announceFmt("Couldn't replace {s}: {s}", .{ original.name, why });
        return j.finish();
    };
    load_ops.unload(self, j.id);
    self.clearErrors(j.id);
    load_ops.workersChanged(self);
    if (j.found) |found| if (j.wants) |wants| if (self.row(j.id)) |r| {
        const pool = objc.Pool.push();
        defer pool.pop();
        if (load_ops.text(found, "displayName")) |n| if (gpa.dupe(u8, n)) |v| {
            gpa.free(r.name);
            r.name = v;
        } else |_| {};
        if (load_ops.text(found, "version")) |n| if (gpa.dupe(u8, n)) |v| {
            gpa.free(r.version);
            r.version = v;
        } else |_| {};
        for (r.permissions) |x| gpa.free(x);
        gpa.free(r.permissions);
        r.permissions = @ptrCast(wants);
        j.wants = null;
        self.save();
    };
    const r = self.row(j.id) orelse return j.finish();
    if (!r.enabled) return j.finish();
    load_ops.load(self, j.id, j, reloadLoaded);
}

fn reloadLoaded(p: *anyopaque, ok: bool) void {
    const j: *Job = @ptrCast(@alignCast(p));
    if (controller.alive(j.serial)) |self| {
        const name = if (self.row(j.id)) |r| r.name else j.original.?.name;
        if (ok) self.announceFmt("{s} reloaded", .{name}) else self.announceFmt("{s} couldn't start — see Settings › Extensions", .{name});
    }
    j.finish();
}

// MARK: new tab pages

/// `offerNewTabPage(into:)`: asked the first time an extension's page
/// takes the place of the new tab; on yes, shown in the tab just opened.
pub fn offerNewTabPage(self: *Extensions, tab: *Tab) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const c = self.newTabCandidate() orelse return;
    if (self.newTabAsked(c.id)) return;
    const r = self.row(c.id) orelse return;
    const job = self.gpa.create(Offer) catch return;
    job.* = .{
        .serial = self.serial,
        .tab = tab.serial,
        .id = self.gpa.dupe(u8, c.id) catch return self.gpa.destroy(job),
        .url = self.gpa.dupe(u8, objc.fromNSString(objc.msg(objc.Object, c.url, "absoluteString", .{}))) catch {
            self.gpa.free(job.id);
            return self.gpa.destroy(job);
        },
    };
    const title = std.fmt.allocPrint(self.gpa, "Show “{s}” in new tabs?", .{r.name}) catch return job.drop(self.gpa);
    defer self.gpa.free(title);
    const icon = if (self.context(c.id)) |ctx| objc.msg(?objc.Object, objc.msg(objc.Object, ctx, "webExtension", .{}), "iconForSize:", .{objc.CGSize{ .width = 64, .height = 64 }}) else null;
    asking.put(self, title, "It asked to replace the new tab page. You can change this later in Settings › Extensions.", icon, "Keep It", "Don't Allow", job, Offer.answered);
}

const Offer = struct {
    serial: u64,
    tab: u64,
    id: []u8,
    url: []u8,

    fn drop(o: *Offer, gpa: std.mem.Allocator) void {
        gpa.free(o.id);
        gpa.free(o.url);
        gpa.destroy(o);
    }

    fn answered(p: *anyopaque, yes: bool) void {
        const o: *Offer = @ptrCast(@alignCast(p));
        // Questions are dropped unanswered when the controller goes.
        const self = controller.alive(o.serial) orelse return;
        defer o.drop(self.gpa);
        self.setNewTab(o.id, yes);
        if (!yes) return;
        const tab = Tab.alive(o.tab) orelse return;
        if (!tab.isBlank()) return;
        const b = self.browser() orelse return;
        @import("../model/browser_ext.zig").replaceBlank(b, tab, o.url);
    }
};
