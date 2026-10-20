//! The window's downloads (Browser.swift 4522-4655 `keep` and on, and
//! "keeping files" 4957-5112): WebKit's `WKDownloadDelegate` — one for the
//! app — where a file goes (the space's folder, or a save panel on the
//! window when Settings › Downloads says to ask), resume and retry from the
//! Downloads panel, and what landed going to Loot with a "Saved" line that
//! shows it in the Finder.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("tab.zig").Tab;
const json = @import("../data/json.zig");
const appkit = @import("../sys/appkit.zig");
const dialogs = @import("dialogs.zig");
const dl = @import("downloads.zig");
const ext_downloads = @import("../ext/downloads.zig");
const Fetches = dl.Fetches;
const Entry = dl.Entry;
const Op = dl.Op;

extern "c" fn _Block_copy(block: ?*const anyopaque) ?*const anyopaque;

const ca = std.heap.c_allocator;

fn class() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigDownloads",
        .protocols = &.{"WKDownloadDelegate"},
        .methods = &.{
            .{ .name = "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:", .imp = &decideDestination, .types = "v@:@@@@?" },
            .{ .name = "downloadDidFinish:", .imp = &didFinish, .types = "v@:@" },
            .{ .name = "download:didFailWithError:resumeData:", .imp = &didFail, .types = "v@:@@@" },
        },
    });
}

fn delegate(f: *Fetches) objc.Object {
    if (f.delegate) |d| return d;
    const d = objc.msg(objc.Object, class(), "new", .{});
    objc.setZig(d, f);
    f.delegate = d;
    return d;
}

/// `downloadsFolder`: the space's own, when there are spaces and it has
/// one; otherwise Settings' (a test run's `<root>/Downloads`).
pub fn downloadsFolder(b: *Browser) []const u8 {
    return folderOf(b.kea, b);
}

fn folderOf(kea: *Kea, b: ?*Browser) []const u8 {
    if (b) |w| if (kea.prefs.uses_spaces) if (w.space().downloads) |d| return d;
    return kea.prefs.downloads;
}

/// `downloads.ask`; a test run never puts up the panel.
fn asks(kea: *Kea) bool {
    return kea.prefs.asks_where_to_save and kea.opts.root == null;
}

fn anyTab(kea: *Kea, wv: objc.Object) ?*Tab {
    for (kea.browsers.items) |b| for (b.tabs.items) |t| if (t.web == wv) return t;
    return null;
}

/// A private tab's, or one whose store keeps nothing. A test run's tabs
/// all keep nothing (`config.configuration`), so there only `shy` counts.
fn isPrivate(kea: *Kea, wv: objc.Object) bool {
    if (anyTab(kea, wv)) |t| if (t.shy) return true;
    if (kea.opts.root != null) return false;
    const store = objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "websiteDataStore", .{});
    return !objc.msg(objc.BOOL, store, "isPersistent", .{});
}

/// `keep`: every download this window has going, heard from until it ends.
pub fn keep(b: *Browser, download: objc.Object, web_view: ?objc.Object) void {
    keepWith(&b.kea.fetches, b, download, web_view, null, null, null);
}

fn keepWith(f: *Fetches, owner: ?*Browser, download: objc.Object, supplied: ?objc.Object, continuing: ?*Entry, operation_id: ?u64, helper: ?objc.Object) void {
    const wv = supplied orelse objc.msg(?objc.Object, download, "webView", .{});
    // Private is settled before the row is published: tracked, never listed.
    const private = continuing == null and if (wv) |v| isPrivate(f.kea, v) else false;
    objc.msg(void, download, "setDelegate:", .{delegate(f)});
    if (!f.start(download, owner, wv, !private, continuing, operation_id, helper))
        return cancelNow(download);
    // A true resume may go on to the file it had without being asked again.
    if (continuing) |e| if (e.destination) |d| f.going(download, d);
}

fn cancelNow(download: objc.Object) void {
    objc.msg(void, download, "cancel:", .{@as(?*const anyopaque, null)});
}

/// `announce`, by the window the download is from; one closed has no one to tell.
fn say(owner: ?*Browser, text: []const u8) void {
    if (owner) |b| b.announce(text);
}

fn sayName(owner: ?*Browser, comptime fmt: []const u8, name: []const u8, file: ?[]const u8) void {
    const b = owner orelse return;
    const text = std.fmt.allocPrint(b.gpa, fmt, .{name}) catch return;
    defer b.gpa.free(text);
    b.announceFile(text, file);
}

// MARK: WKDownloadDelegate

fn decideDestination(self: objc.Object, _: objc.SEL, download: objc.Object, response: objc.Object, suggested: ?objc.Object, handler: *const anyopaque) callconv(.c) void {
    const f = objc.getZig(Fetches, self) orelse return dialogs.call(handler, .{@as(?objc.Object, null)});
    const pool = objc.Pool.push();
    defer pool.pop();
    const owner = if (f.item(download)) |it| it.owner else null;
    // The name an extension asked for (`namedDownloads`), else WebKit's.
    const asked = if (owner) |b| ext_downloads.takeName(b, objc.fromNSString(objc.msg(?objc.Object, objc.msg(?objc.Object, response, "URL", .{}), "absoluteString", .{}))) else null;
    defer if (asked) |a| owner.?.gpa.free(a);
    const name = dl.fileName(ca, asked orelse objc.fromNSString(suggested)) catch @panic("OOM");
    const op = f.hold(.{ .fetches = f, .owner = owner, .download = objc.retain(download), .handler = _Block_copy(handler), .name = name });
    if (f.destination(download)) |chosen| {
        op.chosen = true;
        return decided(op, chosen);
    }
    whereToSave(f, owner, name, op, decided);
}

fn decided(op: *Op, file: ?[]const u8) void {
    defer op.destroy();
    const handler = op.handler.?;
    const f = op.fetches orelse return dialogs.call(handler, .{@as(?objc.Object, null)});
    const download = op.download.?;
    const path = file orelse {
        _ = f.destinationCancelled(download);
        return dialogs.call(handler, .{@as(?objc.Object, null)});
    };
    f.going(download, path);
    // A retry is numbered afresh from the name asked for, or the one you
    // gave it: never from "report 2.pdf", whose own " 2" is not its name.
    if (!op.chosen) if (f.entry(download)) |e|
        dl.dupe(e.gpa, &e.retry_name, if (asks(f.kea)) std.fs.path.basename(path) else op.name);
    const pool = objc.Pool.push();
    defer pool.pop();
    dialogs.call(handler, .{@as(?objc.Object, objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)}))});
    sayName(op.owner, "Downloading {s}", std.fs.path.basename(path), null);
}

fn didFinish(self: objc.Object, _: objc.SEL, download: objc.Object) callconv(.c) void {
    const f = objc.getZig(Fetches, self) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const it = f.item(download);
    const e = if (it) |i| i.entry else null;
    const request = objc.msg(?objc.Object, download, "originalRequest", .{}) orelse if (e) |x| x.request else null;
    const source = if (request) |r| objc.msg(?objc.Object, r, "URL", .{}) else null;
    const host = f.gpa.dupe(u8, if (source) |u| objc.fromNSString(objc.msg(?objc.Object, u, "host", .{})) else "") catch return;
    defer f.gpa.free(host);
    const progress_url = objc.msg(?objc.Object, objc.msg(objc.Object, download, "progress", .{}), "fileURL", .{});
    const known: ?[]const u8 = if (progress_url) |u| objc.fromNSString(objc.msg(?objc.Object, u, "path", .{})) else if (e) |x| x.destination else null;
    const file = if (known) |k| f.gpa.dupe(u8, k) catch return else null;
    defer if (file) |p| f.gpa.free(p);
    const listed = if (it) |i| i.listed else true;
    const ended = f.finish(download, file) orelse return;
    const path = file orelse return say(ended.owner, "Download finished");
    if (!listed) return sayName(ended.owner, "Saved {s}", std.fs.path.basename(path), null);
    if (source) |u| ext_downloads.finished(objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{})), path);
    saved(f, ended.owner, path, host);
}

fn didFail(self: objc.Object, _: objc.SEL, download: objc.Object, err: objc.Object, resume_data: ?objc.Object) callconv(.c) void {
    const f = objc.getZig(Fetches, self) orelse return;
    const ended = f.fail(download, err, resume_data) orelse return;
    if (ended.announce_failure) say(ended.owner, "Download failed");
}

/// Kept: Loot remembers it, and the line shows it in the Finder.
fn saved(f: *Fetches, owner: ?*Browser, path: []const u8, host: []const u8) void {
    const name = std.fs.path.basename(path);
    f.kea.loot.add(.{ .name = name, .from = host, .path = path, .date = json.now() });
    sayName(owner, "Saved {s}", name, path);
}

/// `whereToSave`: the downloads folder, or wherever you say when Settings
/// says to ask — a sheet on this window, not a dialog that stops every
/// window. `then` gets null when the question was cancelled.
fn whereToSave(f: *Fetches, owner: ?*Browser, name: []const u8, op: *Op, comptime then: fn (*Op, ?[]const u8) void) void {
    const folder = folderOf(f.kea, owner);
    if (!asks(f.kea)) {
        const path = dl.free(f.gpa, name, folder) catch @panic("OOM");
        defer f.gpa.free(path);
        return then(op, path);
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.retain(objc.msg(objc.Object, objc.class("NSSavePanel"), "savePanel", .{}));
    objc.msg(void, panel, "setNameFieldStringValue:", .{objc.nsString(name)});
    objc.msg(void, panel, "setDirectoryURL:", .{objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:isDirectory:", .{ objc.nsString(folder), objc.YES })});
    objc.msg(void, panel, "setCanCreateDirectories:", .{objc.YES});
    op.panel = panel;
    const window = if (owner) |b| if (b.window) |w| w.nswindow else null else null;
    appkit.beginSheet(panel, window, op, struct {
        fn answered(o: *Op, response: objc.NSInteger) void {
            const p2 = objc.Pool.push();
            defer p2.pop();
            // Let go after AppKit is done with it, not inside its own completion.
            const sheet = o.panel.?;
            o.panel = null;
            _ = objc.msg(objc.Object, sheet, "autorelease", .{});
            const url = if (response == 1) objc.msg(?objc.Object, sheet, "URL", .{}) else null;
            then(o, if (url) |u| objc.fromNSString(objc.msg(?objc.Object, u, "path", .{})) else null);
        }
    }.answered);
}

/// `_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:`:
/// the download button WebKit draws over a PDF, which has the file whole.
/// An imp on the tab's `KeaZigWebDelegate` (`delegates_nav.zig`).
pub fn saveDataToFile(self: objc.Object, _: objc.SEL, _: objc.Object, data: ?objc.Object, suggested: ?objc.Object, _: ?objc.Object, origin: ?objc.Object) callconv(.c) void {
    const t = objc.getZig(Tab, self) orelse return;
    const d = data orelse return;
    const f = &t.kea.fetches;
    const pool = objc.Pool.push();
    defer pool.pop();
    const name = dl.fileName(ca, objc.fromNSString(suggested)) catch @panic("OOM");
    const host = ca.dupe(u8, if (origin) |u| objc.fromNSString(objc.msg(?objc.Object, u, "host", .{})) else "") catch @panic("OOM");
    const op = f.hold(.{ .fetches = f, .owner = t.browser, .data = objc.retain(d), .name = name, .source = host });
    whereToSave(f, t.browser, name, op, wrote);
}

fn wrote(op: *Op, file: ?[]const u8) void {
    defer op.destroy();
    const f = op.fetches orelse return;
    const path = file orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (!objc.msg(objc.BOOL, op.data.?, "writeToFile:atomically:", .{ objc.nsString(path), objc.NO }))
        return say(op.owner, "Download failed");
    saved(f, op.owner, path, op.source);
}

// MARK: from the Downloads panel

pub fn pauseDownload(b: *Browser, e: *Entry) void {
    b.kea.fetches.pause(e);
}

pub fn cancelDownload(b: *Browser, e: *Entry) void {
    b.kea.fetches.cancel(e);
}

pub fn resumeDownload(b: *Browser, e: *Entry) void {
    const op = b.kea.fetches.beginResume(e) orelse return;
    op.owner = b;
    var block = objc.Block(Op, &.{?objc.Object}).init(op, continued);
    objc.msg(void, op.web_view.?, "resumeDownloadFromResumeData:completionHandler:", .{ op.data.?, &block });
}

/// From the start, to the folder it went to, under the name it was asked for.
pub fn retryDownload(b: *Browser, e: *Entry) void {
    const folder = if (e.destination) |d| std.fs.path.dirname(d) orelse downloadsFolder(b) else downloadsFolder(b);
    const op = b.kea.fetches.beginRetry(e, folder) orelse return;
    op.owner = b;
    var block = objc.Block(Op, &.{?objc.Object}).init(op, continued);
    objc.msg(void, op.web_view.?, "startDownloadUsingRequest:completionHandler:", .{ op.request.?, &block });
}

/// The new WKDownload joins its row; an obsolete one is cancelled before
/// it can replace newer work.
fn continued(op: *Op, download: ?objc.Object) void {
    defer op.destroy();
    const d = download orelse return;
    const f = op.fetches orelse return cancelNow(d);
    const e = f.accepts(op) orelse return cancelNow(d);
    keepWith(f, op.owner, d, op.web_view, e, op.operation_id, if (op.helper) op.web_view else null);
}

/// Show in Finder.
pub fn reveal(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const list = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{url});
    objc.msg(void, objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "activateFileViewerSelectingURLs:", .{list});
}
