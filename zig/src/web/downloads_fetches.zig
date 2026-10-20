//! `Fetches` (Fetching.swift 245-605): the app's downloads under way, one
//! list for every window. Private downloads are tracked for cleanup and
//! the overall progress, but never become rows in the shared panel.
//! Successful files move to Loot and leave the list.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const clock = nanoui.ui.clock;
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const dl = @import("downloads.zig");
const Entry = dl.Entry;
const StopAction = dl.StopAction;

extern "c" const NSProgressKindFile: objc.Object;
extern "c" const NSProgressFileOperationKindDownloading: objc.Object;
extern "c" fn _Block_release(block: *const anyopaque) void;

/// A pause or cancel on its way: WebKit's cancel completion decides it.
pub const Stop = struct { download: objc.Object, entry_id: u64, operation_id: u64 };

pub const Ended = struct { owner: ?*Browser, announce_failure: bool };

/// One running WKDownload. Its window (`owner`) hears how it ends; a
/// closed window's downloads go on with no one to tell.
pub const Running = struct {
    fetches: *Fetches,
    download: objc.Object,
    progress: objc.Object,
    entry: *Entry,
    owner: ?*Browser,
    /// The view made for a resume or retry whose page is gone: kept for
    /// this attempt only. A tab's own view is never kept here.
    helper: ?objc.Object,
    listed: bool,
    /// KVO on `progress.fractionCompleted`; also the Finder's cancel.
    watch: objc.Object,
    /// The Finder's bar under the file and in the Dock's Downloads stack.
    shown: ?objc.Object = null,
    shown_file: ?[]u8 = null,
    stop_action: ?StopAction = null,
    operation_id: u64 = 0,
};

/// A completion WebKit or AppKit will call later. Off `c_allocator`, and
/// let go of by `Fetches.deinit` (`fetches` = null) if it outlives the app.
pub const Op = struct {
    fetches: ?*Fetches,
    owner: ?*Browser = null,
    download: ?objc.Object = null,
    entry_id: u64 = 0,
    operation_id: u64 = 0,
    web_view: ?objc.Object = null,
    helper: bool = false,
    request: ?objc.Object = null,
    data: ?objc.Object = null,
    /// A copied completion block (`decideDestination`'s).
    handler: ?*const anyopaque = null,
    panel: ?objc.Object = null,
    name: []u8 = &.{},
    chosen: bool = false,
    source: []u8 = &.{},

    pub fn destroy(op: *Op) void {
        if (op.fetches) |f| for (f.ops.items, 0..) |o, i| if (o == op) {
            _ = f.ops.swapRemove(i);
            break;
        };
        for ([_]?objc.Object{ op.download, op.web_view, op.request, op.data, op.panel }) |o| if (o) |x| objc.release(x);
        if (op.handler) |h| _Block_release(h);
        std.heap.c_allocator.free(op.name);
        std.heap.c_allocator.free(op.source);
        std.heap.c_allocator.destroy(op);
    }
};

fn watchClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaDownloadWatch",
        .methods = &.{
            .{ .name = "observeValueForKeyPath:ofObject:change:context:", .imp = &observed, .types = "v@:@@@^v" },
        },
    });
}

/// From any thread: measured again on the main one, if still running.
fn observed(self: objc.Object, _: objc.SEL, _: ?objc.Object, _: ?objc.Object, _: ?objc.Object, _: ?*anyopaque) callconv(.c) void {
    objc.dispatchMain(objc.retain(self), measureLater);
}

fn measureLater(ctx: ?*anyopaque) callconv(.c) void {
    const watch: objc.Object = @ptrCast(ctx.?);
    defer objc.release(watch);
    if (objc.getZig(Running, watch)) |item| item.fetches.measure();
}

/// The Finder's Cancel on the file's bar, from any thread.
fn finderCancel(watch: *anyopaque) void {
    objc.dispatchMain(objc.retain(@ptrCast(watch)), finderCancelLater);
}

fn finderCancelLater(ctx: ?*anyopaque) callconv(.c) void {
    const watch: objc.Object = @ptrCast(ctx.?);
    defer objc.release(watch);
    const item = objc.getZig(Running, watch) orelse return;
    const f = item.fetches;
    const s = f.beginFinderStop(item.download) orelse return;
    f.stop(s);
}

pub const Fetches = struct {
    kea: *Kea,
    gpa: std.mem.Allocator,
    /// The panel's rows: running, paused and failed downloads.
    entries: std.ArrayList(*Entry) = .empty,
    running: std.AutoArrayHashMapUnmanaged(objc.Object, *Running) = .empty,
    /// A running download, or one just done: the circle is up.
    showing: bool = false,
    /// How far the running ones are, together; null while any has no size.
    fraction: ?f64 = null,
    /// When the last one landed: the circle says so `linger` seconds.
    done_at: ?f64 = null,
    /// WebKit's `WKDownloadDelegate` (`downloads_keep.zig`), made once.
    delegate: ?objc.Object = null,
    ops: std.ArrayList(*Op) = .empty,

    pub const linger: f64 = 5;

    pub fn deinit(f: *Fetches) void {
        if (f.delegate) |d| objc.setZig(d, null);
        while (f.running.count() > 0) {
            const download = f.running.keys()[0];
            objc.msg(void, download, "setDelegate:", .{@as(?objc.Object, null)});
            objc.msg(void, download, "cancel:", .{@as(?*const anyopaque, null)});
            _ = f.take(download);
        }
        for (f.entries.items) |e| e.destroy();
        f.entries.deinit(f.gpa);
        f.running.deinit(f.gpa);
        for (f.ops.items) |op| op.fetches = null;
        f.ops.deinit(f.gpa);
        if (f.delegate) |d| objc.release(d);
        f.delegate = null;
    }

    /// A closed window's downloads go on, with no window to tell.
    pub fn unbind(f: *Fetches, b: *Browser) void {
        for (f.running.values()) |it| if (it.owner == b) {
            it.owner = null;
        };
        for (f.ops.items) |op| if (op.owner == b) {
            op.owner = null;
        };
    }

    pub fn hold(f: *Fetches, fields: Op) *Op {
        const op = std.heap.c_allocator.create(Op) catch @panic("OOM");
        op.* = fields;
        op.fetches = f;
        f.ops.append(f.gpa, op) catch @panic("OOM");
        return op;
    }

    fn expire(f: *Fetches) void {
        const at = f.done_at orelse return;
        if (clock.now() - at < linger or f.running.count() > 0) return;
        f.showing = false;
        f.done_at = null;
        f.fraction = null;
    }

    /// Whether the circle is up (`showing`).
    pub fn isShowing(f: *Fetches) bool {
        f.expire();
        return f.showing;
    }

    /// Everything finished: an arrow a moment before the circle goes (`done`).
    pub fn isDone(f: *Fetches) bool {
        f.expire();
        return f.done_at != null;
    }

    /// Seconds until a finished circle goes, for the view's next frame.
    pub fn lingerLeft(f: *Fetches) ?f64 {
        f.expire();
        const at = f.done_at orelse return null;
        return @max(0, linger - (clock.now() - at));
    }

    fn changed(f: *Fetches) void {
        for (f.kea.browsers.items) |b| b.redraw();
    }

    pub fn item(f: *Fetches, download: objc.Object) ?*Running {
        return f.running.get(download);
    }

    pub fn entry(f: *Fetches, download: objc.Object) ?*Entry {
        return if (f.item(download)) |i| i.entry else null;
    }

    pub fn entryById(f: *Fetches, id: u64) ?*Entry {
        for (f.entries.items) |e| if (e.id == id) return e;
        return null;
    }

    /// Where the browser chose, or a resumed attempt remembers.
    pub fn destination(f: *Fetches, download: objc.Object) ?[]const u8 {
        return if (f.entry(download)) |e| e.destination else null;
    }

    /// A download has begun.
    pub fn start(f: *Fetches, download: objc.Object, owner: ?*Browser, web_view: ?objc.Object, listed: bool, continuing: ?*Entry, operation_id: ?u64, helper: ?objc.Object) bool {
        if (continuing) |c| if (operation_id) |id| if (c.operation_id != id) return false;
        const pool = objc.Pool.push();
        defer pool.pop();
        const request = objc.msg(?objc.Object, download, "originalRequest", .{});
        const e = if (continuing) |c| blk: {
            if (c.request == null) dl.swap(&c.request, request);
            c.began(download, operation_id);
            break :blk c;
        } else blk: {
            const url = if (request) |r| objc.msg(?objc.Object, r, "URL", .{}) else null;
            const suggested = if (url) |u| objc.fromNSString(objc.msg(?objc.Object, u, "lastPathComponent", .{})) else "";
            const made = Entry.create(f.gpa, if (suggested.len > 0) suggested else "download", request, web_view);
            made.download = download;
            if (listed) f.entries.append(f.gpa, made) catch @panic("OOM");
            break :blk made;
        };
        const progress = objc.retain(objc.msg(objc.Object, download, "progress", .{}));
        const it = f.gpa.create(Running) catch @panic("OOM");
        it.* = .{
            .fetches = f,
            .download = objc.retain(download),
            .progress = progress,
            .entry = e,
            .owner = owner,
            .helper = if (helper) |h| objc.retain(h) else null,
            .listed = listed or continuing != null,
            .watch = objc.msg(objc.Object, watchClass(), "new", .{}),
        };
        objc.setZig(it.watch, it);
        f.running.put(f.gpa, download, it) catch @panic("OOM");
        f.done_at = null;
        f.showing = true;
        objc.msg(void, progress, "addObserver:forKeyPath:options:context:", .{ it.watch, objc.nsString("fractionCompleted"), @as(objc.NSUInteger, 0), @as(?*anyopaque, null) });
        f.measure();
        return true;
    }

    /// Where the file is going, known: its progress is put on it, for the
    /// Finder's bar under the file and the Dock's Downloads stack.
    pub fn going(f: *Fetches, download: objc.Object, file: []const u8) void {
        const it = f.item(download) orelse return;
        const completed = objc.msg(i64, it.progress, "completedUnitCount", .{});
        if (it.shown_file) |s| if (std.mem.eql(u8, s, file)) {
            if (it.shown) |p| objc.msg(void, p, "setCompletedUnitCount:", .{completed});
            it.entry.record(it.progress, true);
            return f.changed();
        };
        it.entry.reached(file);
        unpublish(it);
        dl.dupe(f.gpa, &it.shown_file, file);
        // Tests leave the Finder and the Dock alone.
        if (f.kea.opts.root == null) {
            const pool = objc.Pool.push();
            defer pool.pop();
            const total = objc.msg(i64, it.progress, "totalUnitCount", .{});
            const p = objc.msg(objc.Object, objc.alloc("NSProgress"), "initWithParent:userInfo:", .{ @as(?objc.Object, null), @as(?objc.Object, null) });
            objc.msg(void, p, "setTotalUnitCount:", .{@as(i64, @max(1, total))});
            objc.msg(void, p, "setKind:", .{NSProgressKindFile});
            objc.msg(void, p, "setFileOperationKind:", .{NSProgressFileOperationKindDownloading});
            objc.msg(void, p, "setFileURL:", .{objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(file)})});
            objc.msg(void, p, "setCancellable:", .{objc.YES});
            // The Finder's Cancel can come without WebKit's failure callback,
            // so it takes the same way out.
            var block = objc.Block(anyopaque, &.{}).init(@ptrCast(it.watch), finderCancel);
            objc.msg(void, p, "setCancellationHandler:", .{&block});
            objc.msg(void, p, "setCompletedUnitCount:", .{completed});
            objc.msg(void, p, "publish", .{});
            it.shown = p;
        }
        it.entry.record(it.progress, true);
        f.changed();
    }

    fn unpublish(it: *Running) void {
        const p = it.shown orelse return;
        objc.msg(void, p, "setCancellationHandler:", .{@as(?*const anyopaque, null)});
        objc.msg(void, p, "unpublish", .{});
        objc.release(p);
        it.shown = null;
    }

    pub fn beginStop(f: *Fetches, e: *Entry, action: StopAction) ?Stop {
        if (e.state != .downloading) return null;
        const download = e.download orelse return null;
        const it = f.item(download) orelse return null;
        if (it.entry != e) return null;
        const token = e.preparingToStop(action);
        it.stop_action = action;
        it.operation_id = token;
        f.changed();
        return .{ .download = download, .entry_id = e.id, .operation_id = token };
    }

    /// The Finder's Cancel: a pause under way becomes a discard.
    pub fn beginFinderStop(f: *Fetches, download: objc.Object) ?Stop {
        const it = f.item(download) orelse return null;
        if (it.entry.state == .pausing) {
            _ = f.upgradeStopToCancel(it.entry);
            return null;
        }
        return f.beginStop(it.entry, .cancel);
    }

    /// `stopDownload`: WebKit's cancel completion is the authoritative
    /// source of resume data, and owns the cleanup.
    pub fn stop(f: *Fetches, s: Stop) void {
        const op = f.hold(.{ .fetches = f, .download = objc.retain(s.download), .entry_id = s.entry_id, .operation_id = s.operation_id });
        var block = objc.Block(Op, &.{?objc.Object}).init(op, stopHeard);
        objc.msg(void, s.download, "cancel:", .{&block});
    }

    fn stopHeard(op: *Op, data: ?objc.Object) void {
        if (data) |d| op.data = objc.retain(d);
        objc.dispatchMain(op, stopLanded);
    }

    fn stopLanded(ctx: ?*anyopaque) callconv(.c) void {
        const op: *Op = @ptrCast(@alignCast(ctx.?));
        defer op.destroy();
        const f = op.fetches orelse return;
        _ = f.stopped(.{ .download = op.download.?, .entry_id = op.entry_id, .operation_id = op.operation_id }, op.data);
    }

    /// A pause or cancel finished, even with no delegate callback. The
    /// token turns away a late completion from an older attempt.
    pub fn stopped(f: *Fetches, s: Stop, resume_data: ?objc.Object) ?Ended {
        const it = f.item(s.download) orelse return null;
        if (it.operation_id != s.operation_id) return null;
        const action = it.stop_action orelse return null;
        const e = it.entry;
        if (e.operation_id != s.operation_id or e.pending_stop != action) return null;
        e.recordTerminal(it.progress);
        if (action == .cancel) e.discardOwnedPartialFile();
        e.stopped(action, resume_data);
        if (action == .cancel) f.remove(e);
        const owner = f.take(s.download) orelse return null;
        f.settle(false);
        return .{ .owner = owner, .announce_failure = false };
    }

    /// For `resumeDownload`: the op carries the view and the data.
    pub fn beginResume(f: *Fetches, e: *Entry) ?*Op {
        if (!e.canResume()) return null;
        const data = e.resume_data.?;
        const store = e.store.?;
        if (!e.partialFileIsOurs()) {
            e.lostPartialFile();
            f.changed();
            return null;
        }
        const view, const helper = dl.viewFor(f.kea, e, store);
        const token = e.preparingToStart(null);
        f.changed();
        return f.hold(.{ .fetches = f, .entry_id = e.id, .operation_id = token, .web_view = view, .helper = helper, .data = objc.retain(data) });
    }

    /// From the start, into `folder`, numbered afresh once the last
    /// attempt's half-written file is let go.
    pub fn beginRetry(f: *Fetches, e: *Entry, folder: []const u8) ?*Op {
        if (!e.canRetry()) return null;
        const request = e.request.?;
        const store = e.store.?;
        e.discardOwnedPartialFile();
        const view, const helper = dl.viewFor(f.kea, e, store);
        const target = dl.free(f.gpa, e.retry_name orelse "download", folder) catch @panic("OOM");
        defer f.gpa.free(target);
        const token = e.preparingToStart(target);
        dl.swap(&e.resume_data, null);
        e.fraction = 0;
        e.completed_bytes = 0;
        e.total_bytes = 0;
        f.changed();
        return f.hold(.{ .fetches = f, .entry_id = e.id, .operation_id = token, .web_view = view, .helper = helper, .request = objc.retain(request) });
    }

    /// A WKDownload back from a resume or retry joins its row, unless the
    /// row moved on meanwhile.
    pub fn accepts(f: *Fetches, op: *const Op) ?*Entry {
        const e = f.entryById(op.entry_id) orelse return null;
        return if (e.state == .resuming and e.operation_id == op.operation_id) e else null;
    }

    pub fn removeStarting(f: *Fetches, e: *Entry) void {
        if (e.state != .resuming) return;
        e.discardOwnedPartialFile();
        f.remove(e);
    }

    /// A pause under way becomes a discard, keeping its completion token.
    pub fn upgradeStopToCancel(f: *Fetches, e: *Entry) bool {
        if (e.state != .pausing) return false;
        const download = e.download orelse return false;
        const it = f.item(download) orelse return false;
        if (it.entry != e) return false;
        e.pending_stop = .cancel;
        it.stop_action = .cancel;
        return true;
    }

    /// Arrived. The Dock's Downloads stack is told, as Safari tells it.
    pub fn finish(f: *Fetches, download: objc.Object, file: ?[]const u8) ?Ended {
        const it = f.item(download) orelse return null;
        f.remove(it.entry);
        const owner = f.take(download) orelse return null;
        if (file) |path| if (f.kea.opts.root == null) {
            const pool = objc.Pool.push();
            defer pool.pop();
            const center = objc.msg(objc.Object, objc.class("NSDistributedNotificationCenter"), "defaultCenter", .{});
            objc.msg(void, center, "postNotificationName:object:", .{ objc.nsString("com.apple.DownloadFileFinished"), objc.nsString(path) });
        };
        f.settle(true);
        return .{ .owner = owner, .announce_failure = false };
    }

    /// Failed. A pause or cancel under way waits for its own completion.
    pub fn fail(f: *Fetches, download: objc.Object, err: objc.Object, resume_data: ?objc.Object) ?Ended {
        const it = f.item(download) orelse return null;
        if (it.stop_action != null) return null;
        it.entry.recordTerminal(it.progress);
        it.entry.failed(err, resume_data);
        // A private download has no row to resume it from.
        if (!it.listed) it.entry.discardOwnedPartialFile();
        const owner = f.take(download) orelse return null;
        f.settle(false);
        return .{ .owner = owner, .announce_failure = true };
    }

    /// The save panel was cancelled: no row, no error.
    pub fn destinationCancelled(f: *Fetches, download: objc.Object) ?Ended {
        const it = f.item(download) orelse return null;
        f.remove(it.entry);
        const owner = f.take(download) orelse return null;
        f.settle(false);
        return .{ .owner = owner, .announce_failure = false };
    }

    pub fn removeStopped(f: *Fetches, e: *Entry) void {
        if (e.state != .paused and e.state != .failed) return;
        e.discardOwnedPartialFile();
        f.remove(e);
    }

    /// Pause an active download.
    pub fn pause(f: *Fetches, e: *Entry) void {
        if (!e.canPause()) return;
        f.stop(f.beginStop(e, .pause) orelse return);
    }

    /// `cancelDownload`: active rows stop; paused and failed ones go.
    pub fn cancel(f: *Fetches, e: *Entry) void {
        switch (e.state) {
            .downloading => f.stop(f.beginStop(e, .cancel) orelse return),
            .pausing => _ = f.upgradeStopToCancel(e),
            .resuming => f.removeStarting(e),
            .paused, .failed => f.removeStopped(e),
        }
    }

    /// `forgetDownloads(of:)`: a deleted space's downloads go with it.
    pub fn forgetStore(f: *Fetches, store: objc.Object) void {
        var i = f.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (i < f.entries.items.len and f.entries.items[i].store == store) f.cancel(f.entries.items[i]);
        }
    }

    /// Off the list and emptied; freed unless a running download holds it.
    fn remove(f: *Fetches, e: *Entry) void {
        for (f.entries.items, 0..) |x, i| if (x == e) {
            _ = f.entries.orderedRemove(i);
            break;
        };
        var held = false;
        for (f.running.values()) |it| held = held or it.entry == e;
        e.clear();
        if (!held) e.destroy();
        f.changed();
    }

    /// The running download let go: null when it wasn't running, else its
    /// window, if it still has one.
    fn take(f: *Fetches, download: objc.Object) ??*Browser {
        const kv = f.running.fetchSwapRemove(download) orelse return null;
        const it = kv.value;
        objc.setZig(it.watch, null);
        objc.msg(void, it.progress, "removeObserver:forKeyPath:", .{ it.watch, objc.nsString("fractionCompleted") });
        objc.release(it.watch);
        unpublish(it);
        dl.dupe(f.gpa, &it.shown_file, null);
        it.entry.download = null;
        if (f.entryById(it.entry.id) == null) it.entry.destroy();
        if (it.helper) |h| objc.release(h);
        objc.release(it.progress);
        objc.release(it.download);
        const owner = it.owner;
        f.gpa.destroy(it);
        return owner;
    }

    /// The last one in: the circle says so, then goes. A failure with
    /// nothing else running takes it away at once.
    fn settle(f: *Fetches, succeeded: bool) void {
        if (f.running.count() > 0) return f.measure();
        if (succeeded) {
            f.fraction = 1;
            f.done_at = clock.now();
        } else {
            f.showing = false;
            f.done_at = null;
            f.fraction = null;
        }
        f.changed();
    }

    /// The running downloads, together, in whole percents; each file's own
    /// progress and row brought up to date on the way.
    pub fn measure(f: *Fetches) void {
        var total: i64 = 0;
        var completed: i64 = 0;
        var sized = true;
        // KVO fires per chunk written: windows redraw only when a percent moves.
        var moved = false;
        for (f.running.values()) |it| {
            const t = objc.msg(i64, it.progress, "totalUnitCount", .{});
            const c = objc.msg(i64, it.progress, "completedUnitCount", .{});
            if (t > 0) {
                total += t;
                completed += c;
            } else sized = false;
            if (it.shown) |p| {
                if (t > 0 and objc.msg(i64, p, "totalUnitCount", .{}) != t) objc.msg(void, p, "setTotalUnitCount:", .{t});
                objc.msg(void, p, "setCompletedUnitCount:", .{c});
            }
            const was = percent(it.entry.fraction);
            it.entry.record(it.progress, true);
            moved = moved or was != percent(it.entry.fraction);
        }
        if (f.running.count() == 0) return;
        const now: ?f64 = if (sized and total > 0)
            @round(@as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(total)) * 100) / 100
        else
            null;
        if (moved or percent(now) != percent(f.fraction)) {
            f.fraction = now;
            f.changed();
        }
    }
};

/// Whole percents, -1 for no size.
fn percent(fraction: ?f64) i32 {
    return if (fraction) |x| @intFromFloat(@round(x * 100)) else -1;
}

test {
    // P8's panel is the first caller of most of this: analysed now.
    std.testing.refAllDecls(Fetches);
    std.testing.refAllDecls(@import("downloads_keep.zig"));
}
