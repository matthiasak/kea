//! Browser.swift's taking things in from another browser (197-264, 872-1052):
//! its bookmarks (`takeBookmarks`), passwords (`keep(found)`), history
//! (`takePlaces`) and the icons behind them, and a file another browser
//! exported, read in the background with its card in the corner
//! (`importFile`, `takeFile`, `FileImportJob`). Quitting waits a moment for
//! a file still being read (`cancelAllFileImports`, Links.swift:25-45).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("browser.zig").Browser;
const Bookmarks = @import("../data/bookmarks.zig").Bookmarks;
const sources = @import("../import/sources.zig");
const file = @import("../import/file.zig");
const files = @import("../import/files.zig");
const record = @import("../import/record.zig");
const vault = @import("../passwords/vault.zig");
const dispatch = @import("../sys/dispatch.zig");
const favicons = @import("../web/favicons.zig");

/// Jobs cross threads: what they hold is on the C heap.
const heap = std.heap.c_allocator;

// MARK: another browser's

pub const Marks = struct { added: usize = 0, already: usize = 0, kept: bool = false };

/// Another browser's bookmarks, folders and all — one profile's, or every
/// profile's when null — and the icons it had for them. `replacing`: what
/// came from it before, as recorded, goes first; only when every profile
/// read cleanly, else what came before stays and `kept` says so (#375).
pub fn takeBookmarks(b: *Browser, source: sources.Source, profile: ?[]const u8, replacing: bool) Marks {
    var arena: std.heap.ArenaAllocator = .init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const base = sources.Base.of(a, b.kea.opts.root) catch return .{};
    const read = source.bookmarkRead(a, base, profile) catch sources.BookmarkRead{ .nodes = &.{}, .complete = false };
    const name = source.name();
    var kept = false;
    if (replacing) if (record.of(a, b.store, name)) |earlier| if (earlier.bookmarkIDs.len > 0) {
        if (read.complete) {
            _ = b.bookmarks.withdraw(earlier.bookmarkIDs);
            record.forgetBookmarks(b.gpa, b.store, name) catch {};
        } else kept = true;
    };
    const t = b.bookmarks.takeNoting(a, read.nodes, name);
    record.note(b.gpa, b.store, name, .{ .ids = t.ids, .bookmarks = @intCast(t.added) }) catch {};
    const told = if (kept)
        std.fmt.allocPrint(a, "Couldn't read all of {s}'s bookmarks: what came from it before was kept", .{name})
    else if (Bookmarks.count(read.nodes) == 0)
        std.fmt.allocPrint(a, "No bookmarks in {s}", .{name})
    else if (t.added == 0)
        std.fmt.allocPrint(a, "The bookmarks from {s} were all here already", .{name})
    else if (t.already == 0)
        std.fmt.allocPrint(a, "{d} bookmarks from {s}", .{ t.added, name })
    else
        std.fmt.allocPrint(a, "{d} new bookmarks from {s}, {d} already here", .{ t.added, name, t.already });
    if (told) |text| b.announce(text) else |_| {}
    if (Bookmarks.urls(a, read.nodes)) |urls| adoptIcons(b, urls, source, profile) else |_| {}
    return .{ .added = t.added, .already = t.already, .kept = kept };
}

/// What came back from another browser's store, put in the keychain, with
/// the sites it was told never to ask about. Saving one already kept
/// updates it. How many were kept.
pub fn keepFound(b: *Browser, found: sources.Found) usize {
    const v = vault.Vault.of(b.kea);
    var kept: usize = 0;
    for (found.logins) |l| {
        if (v.save(l.host, l.user, l.password, l.used, l.clear)) kept += 1;
    }
    if (found.never.len > 0) if (v.never()) |had| {
        defer {
            for (had) |s| b.gpa.free(s);
            b.gpa.free(had);
        }
        if (std.mem.concat(b.gpa, []const u8, &.{ @as([]const []const u8, @ptrCast(had)), found.never })) |all| {
            defer b.gpa.free(all);
            v.setNever(all);
        } else |_| {}
    } else |_| {};
    relist(b);
    return kept;
}

/// The passwords list read again (`relist()`).
pub fn relist(b: *Browser) void {
    @import("../passwords/browser_passwords.zig").relist(b);
}

/// The other browser's history, read off the main thread by the caller,
/// into this one's; the merge itself is a moment. How many places.
pub fn takePlaces(b: *Browser, name: []const u8, places: []const sources.Place) usize {
    for (places) |place| b.history.take(place.url, place.title, place.count, place.last);
    b.history.settle();
    record.note(b.gpa, b.store, name, .{ .places = @intCast(places.len) }) catch {};
    return places.len;
}

// MARK: icons

const IconsIn = struct {
    arena: std.heap.ArenaAllocator,
    /// Counted in its `pending`, so it outlives the app's state if need be.
    favicons: *favicons.Favicons,
    base: sources.Base,
    source: sources.Source,
    profile: ?[]const u8,
    urls: []const []const u8,
};
const Adopted = struct { host: []const u8, png: []u8 };
const IconsJob = sources.Job(*IconsIn, []Adopted);

/// The icons another browser had for `urls`, adopted as if each site had
/// handed its own over, so menus and pins wear them from the start
/// (`adoptIcons`, `Favicons.adopt`). Read and decoded off the main thread.
pub fn adoptIcons(b: *Browser, urls: []const []const u8, source: ?sources.Source, profile: ?[]const u8) void {
    const s = source orelse return;
    if (urls.len == 0) return;
    const in = heap.create(IconsIn) catch return;
    in.* = .{ .arena = .init(heap), .favicons = b.kea.favicons, .base = undefined, .source = s, .profile = null, .urls = &.{} };
    const a = in.arena.allocator();
    const ok = blk: {
        in.base = sources.Base.of(a, b.kea.opts.root) catch break :blk false;
        in.profile = if (profile) |p| a.dupe(u8, p) catch break :blk false else null;
        const list = a.alloc([]const u8, urls.len) catch break :blk false;
        for (list, urls) |*d, u| d.* = a.dupe(u8, u) catch break :blk false;
        in.urls = list;
        b.kea.favicons.pending += 1;
        IconsJob.start(heap, in, iconsWork, null, iconsDone) catch {
            b.kea.favicons.pending -= 1;
            break :blk false;
        };
        break :blk true;
    };
    if (!ok) {
        in.arena.deinit();
        heap.destroy(in);
    }
}

fn iconsWork(a: std.mem.Allocator, in: *IconsIn) ![]Adopted {
    var got = try in.source.icons(a, in.base, in.profile, in.urls);
    var out: std.ArrayList(Adopted) = .empty;
    for (got.keys(), got.values()) |host, bytes| {
        const png = favicons.square(heap, bytes) orelse continue;
        try out.append(a, .{ .host = host, .png = png });
    }
    got.deinit(a);
    return out.items;
}

fn iconsDone(_: ?*anyopaque, job: *IconsJob) void {
    const in = job.input;
    defer {
        job.deinit();
        in.arena.deinit();
        heap.destroy(in);
    }
    const list = job.output catch &.{};
    const f = in.favicons;
    f.pending -= 1;
    const kea = f.kea orelse {
        for (list) |x| heap.free(x.png);
        if (f.pending == 0) heap.destroy(f);
        return;
    };
    for (list) |x| f.adopt(x.host, x.png);
    if (list.len > 0) kea.iconsChanged();
}

// MARK: a file another browser exported

/// The file being brought in (`FileImportJob`), shown in the window's corner.
pub const FileImport = struct {
    browser: ?*Browser,
    path: []u8,
    filename: []u8,
    message: []u8,
    completed: usize = 0,
    total: ?usize = null,
    cancelling: bool = false,
    control: file.Control = .{},
    read_job: ?*ReadJob = null,
    added: usize = 0,
    already: usize = 0,
    places: usize = 0,
    kept: usize = 0,
    skipped: usize = 0,
    safari: bool = false,
    failed: bool = false,
    merged: bool = false,
    /// Resolved on the main thread for the worker that saves the passwords.
    vault: ?vault.Vault = null,

    fn say(f: *FileImport, message: []const u8) void {
        const copy = heap.dupe(u8, message) catch return;
        heap.free(f.message);
        f.message = copy;
    }

    fn destroy(f: *FileImport) void {
        if (f.read_job) |j| j.deinit();
        heap.free(f.path);
        heap.free(f.filename);
        heap.free(f.message);
        heap.destroy(f);
    }
};

const ReadJob = sources.Job(*FileImport, file.Found);
const SaveJob = sources.Job(*FileImport, vault.Taken);

/// Every file import running, every window's (`activeFileImports`), and
/// whether the app is on its way out (`fileImportTerminating`). Main thread.
var active: std.ArrayListUnmanaged(*FileImport) = .empty;
var terminating = false;

/// `cancelAllFileImports`: from now on nothing new starts; whether any was
/// running.
pub fn cancelAll() bool {
    terminating = true;
    for (active.items) |f| f.control.cancel();
    return active.items.len > 0;
}

/// `applicationShouldTerminate`: the running imports cancelled, and up to
/// five seconds for them to stop.
pub fn waitForImports() void {
    if (!cancelAll()) return;
    const until = dispatch.CFAbsoluteTimeGetCurrent() + 5;
    while (active.items.len > 0 and dispatch.CFAbsoluteTimeGetCurrent() < until) nanoui.runFor(0.05);
}

pub fn running() bool {
    return active.items.len > 0;
}

/// The leftovers of an import that stopped half way, at launch, on a utility
/// queue (Links.swift:105).
pub fn sweepLater() void {
    dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(0x11, 0), null, sweep);
}

fn sweep(_: ?*anyopaque) callconv(.c) void {
    files.sweepScratch(heap);
}

pub fn cancelFileImport(b: *Browser) void {
    const f = b.importing.file orelse return;
    f.cancelling = true;
    f.say("Cancelling…");
    f.control.cancel();
    b.redraw();
}

/// The window going: its import is stopped and finishes on its own.
pub fn forget(b: *Browser) void {
    const f = b.importing.file orelse return;
    f.browser = null;
    f.control.cancel();
    b.importing.file = null;
}

/// A bookmarks page, a passwords file, Safari's export or a folder of them,
/// taken in as a browser's are. Says what came in once done. False when one
/// is running already.
pub fn takeFile(b: *Browser, path: []const u8) bool {
    if (terminating or b.importing.file != null) {
        b.announce("An import is already running");
        return false;
    }
    const f = heap.create(FileImport) catch return false;
    f.* = .{ .browser = b, .path = &.{}, .filename = &.{}, .message = &.{} };
    f.path = heap.dupe(u8, path) catch {
        f.destroy();
        return false;
    };
    f.filename = heap.dupe(u8, std.fs.path.basename(path)) catch &.{};
    f.say("Reading…");
    f.control = .{ .ctx = f, .progress = progressed };
    active.append(heap, f) catch {
        f.destroy();
        return false;
    };
    b.importing.file = f;
    ReadJob.start(heap, f, readWork, f, readDone) catch {
        f.failed = true;
        finish(f);
        return false;
    };
    b.redraw();
    return true;
}

fn readWork(a: std.mem.Allocator, f: *FileImport) !file.Found {
    return file.read(a, f.path, &f.control);
}

const Hop = struct { f: *FileImport, message: []u8, completed: usize, total: ?usize };

/// The worker's progress, carried to the main thread. The job's own
/// delivery comes after every hop it sent, so `f` is still there.
fn progressed(ctx: ?*anyopaque, p: file.Progress) void {
    const hop = heap.create(Hop) catch return;
    hop.* = .{ .f = @ptrCast(@alignCast(ctx.?)), .message = heap.dupe(u8, p.message) catch return heap.destroy(hop), .completed = p.completed, .total = p.total };
    objc.dispatchMain(hop, landed);
}

fn landed(ctx: ?*anyopaque) callconv(.c) void {
    const hop: *Hop = @ptrCast(@alignCast(ctx.?));
    defer {
        heap.free(hop.message);
        heap.destroy(hop);
    }
    const f = hop.f;
    if (f.cancelling) return;
    f.say(hop.message);
    f.completed = hop.completed;
    f.total = hop.total;
    if (f.browser) |b| b.redraw();
}

fn readDone(ctx: ?*anyopaque, job: *ReadJob) void {
    const f: *FileImport = @ptrCast(@alignCast(ctx.?));
    f.read_job = job;
    const found = job.output catch {
        f.failed = !f.control.isCancelled();
        return finish(f);
    };
    f.safari = found.from_safari;
    const b = f.browser orelse return finish(f);
    if (f.control.isCancelled()) return finish(f);
    if (found.bookmarks.items.len > 0) {
        f.say("Merging bookmarks…");
        const stem = std.fs.path.stem(f.filename);
        const t = b.bookmarks.take(found.bookmarks.items, if (found.from_safari) "Safari" else stem);
        f.merged = true;
        f.added = t.added;
        f.already = t.already;
    }
    if (found.places.items.len > 0 and !f.control.isCancelled()) {
        f.say("Adding history…");
        f.completed = 0;
        f.total = found.places.items.len;
        return addPlaces(f);
    }
    afterPlaces(f);
}

/// 200 places a run-loop turn, as Swift yields between batches: the window
/// draws, and Cancel is heard, while a long history goes in.
fn addPlaces(f: *FileImport) void {
    const b = f.browser orelse return finish(f);
    const all = (f.read_job.?.output catch unreachable).places.items;
    if (!f.control.isCancelled() and f.places < all.len) {
        const end = @min(f.places + 200, all.len);
        for (all[f.places..end]) |place| b.history.take(place.url, place.title, place.count, place.last);
        f.places = end;
        f.completed = end;
        f.total = all.len;
        b.redraw();
        if (end < all.len) return objc.dispatchMain(f, addPlacesLater);
    }
    if (f.places > 0) b.history.settle();
    afterPlaces(f);
}

fn addPlacesLater(ctx: ?*anyopaque) callconv(.c) void {
    addPlaces(@ptrCast(@alignCast(ctx.?)));
}

fn afterPlaces(f: *FileImport) void {
    const found = f.read_job.?.output catch unreachable;
    const b = f.browser orelse return finish(f);
    if (found.passwords.items.len > 0 and !f.control.isCancelled()) {
        f.say("Saving passwords…");
        f.completed = 0;
        f.total = null;
        b.redraw();
        f.vault = vault.Vault.of(b.kea);
        SaveJob.start(heap, f, saveWork, f, saveDone) catch return finish(f);
        return;
    }
    finish(f);
}

fn saveWork(_: std.mem.Allocator, f: *FileImport) !vault.Taken {
    const found = f.read_job.?.output catch unreachable;
    const v = f.vault.?;
    var all: vault.Taken = .{};
    const progress: vault.Progress = .{ .ctx = f, .report = report, .cancelled = cancelled };
    for (found.passwords.items) |text| {
        if (f.control.isCancelled()) break;
        const t = v.takeCsv(text, progress) catch continue;
        all.kept += t.kept;
        all.skipped += t.skipped;
    }
    return all;
}

fn report(ctx: *anyopaque, message: []const u8, completed: usize, total: ?usize) void {
    const f: *FileImport = @ptrCast(@alignCast(ctx));
    f.control.report(.{ .message = message, .completed = completed, .total = total });
}

fn cancelled(ctx: *anyopaque) bool {
    const f: *FileImport = @ptrCast(@alignCast(ctx));
    return f.control.isCancelled();
}

fn saveDone(ctx: ?*anyopaque, job: *SaveJob) void {
    const f: *FileImport = @ptrCast(@alignCast(ctx.?));
    defer job.deinit();
    if (job.output) |t| {
        f.kept = t.kept;
        f.skipped = t.skipped;
    } else |_| {}
    finish(f);
}

/// The card goes, and what came in is said (`FileTake.said`).
fn finish(f: *FileImport) void {
    defer f.destroy();
    for (active.items, 0..) |x, i| if (x == f) {
        _ = active.swapRemove(i);
        break;
    };
    const b = f.browser orelse return;
    b.importing.file = null;
    if (f.kept > 0 or f.skipped > 0) relist(b);
    var arena: std.heap.ArenaAllocator = .init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    b.announce(said(a, f, f.control.isCancelled()) catch "");
    b.redraw();
}

fn count(a: std.mem.Allocator, n: usize, one: []const u8, many: []const u8) ![]const u8 {
    return if (n == 1) std.fmt.allocPrint(a, "1 {s}", .{one}) else std.fmt.allocPrint(a, "{d} {s}", .{ n, many });
}

fn said(a: std.mem.Allocator, f: *const FileImport, was_cancelled: bool) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (f.added > 0 or f.already > 0) try parts.append(a, if (f.already == 0)
        try count(a, f.added, "bookmark", "bookmarks")
    else
        try std.fmt.allocPrint(a, "{s}, {d} already here", .{ try count(a, f.added, "new bookmark", "new bookmarks"), f.already }));
    if (f.places > 0) try parts.append(a, try count(a, f.places, "place", "places"));
    if (f.kept > 0 or f.skipped > 0) try parts.append(a, if (f.skipped == 0)
        try count(a, f.kept, "password", "passwords")
    else
        try std.fmt.allocPrint(a, "{s}, {d} skipped", .{ try count(a, f.kept, "password", "passwords"), f.skipped }));
    var text: []const u8 = try std.mem.join(a, " · ", parts.items);
    if (was_cancelled) {
        text = if (text.len == 0)
            (if (f.merged) "Import cancelled after merging bookmarks" else "Import cancelled; nothing was changed")
        else
            try std.mem.concat(a, u8, &.{ "Import cancelled after ", text });
    } else if (f.failed) {
        text = if (text.len == 0) "That file couldn't be read" else try std.mem.concat(a, u8, &.{ "Import stopped after ", text });
    } else if (text.len == 0) {
        text = if (f.merged) "Bookmark folders imported" else "Nothing to bring in from that file";
    }
    if (f.safari and f.kept > 0) text = try std.mem.concat(a, u8, &.{ text, " — the exported file holds your passwords in the clear: delete it now" });
    return text;
}
