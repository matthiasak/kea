//! Right-click on an image, Kea's own menu (ImageMenu.swift): WebKit's
//! Download Image and Copy Image do nothing on some sites, so the page's
//! menu steps aside for an `<img>` (`image_watch.js`) and this stands in:
//! Open Image in New Tab, Copy Image, Download Image, Copy Image Address.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Tab = @import("tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;
const config = @import("config.zig");
const cg = @import("../sys/cg.zig");
const urlsession = @import("../sys/urlsession.zig");

/// The most a copied picture may weigh, and unpack to.
const largest_image = 50_000_000;
const most_pixels = 100_000_000;

const Pick = struct { serial: u64, url: []u8, frame: objc.Object };

/// `showImageMenu(for:at:)`: popped where the pointer already is.
pub fn show(t: *Tab, src: []const u8, frame: objc.Object) void {
    const wv = t.web orelse return;
    const window = objc.msg(?objc.Object, wv, "window", .{}) orelse return;
    const a = std.heap.c_allocator;
    var pick: Pick = .{ .serial = t.serial, .url = a.dupe(u8, src) catch return, .frame = objc.retain(frame) };
    defer {
        a.free(pick.url);
        objc.release(pick.frame);
    }
    const M = nanoui.MenuItem;
    const menu = nanoui.Menu.create(a, "", &[_]M{
        .{ .label = "Open Image in New Tab", .click = .of(&pick, openImage) },
        M.separator,
        .{ .label = "Copy Image", .click = .of(&pick, copyImage) },
        .{ .label = "Download Image", .click = .of(&pick, downloadImage) },
        M.separator,
        .{ .label = "Copy Image Address", .click = .of(&pick, copyAddress) },
    }) catch return;
    defer menu.destroy();
    const screen = objc.msg(objc.CGPoint, objc.class("NSEvent"), "mouseLocation", .{});
    const in_window = objc.msg(objc.CGPoint, window, "convertPointFromScreen:", .{screen});
    const at = objc.msg(objc.CGPoint, wv, "convertPoint:fromView:", .{ in_window, @as(?objc.Object, null) });
    const flipped = objc.msg(objc.BOOL, wv, "isFlipped", .{});
    const h = objc.msg(objc.CGRect, wv, "bounds", .{}).size.height;
    menu.popup(wv, at.x, if (flipped) at.y else h - at.y);
}

fn openImage(p: *Pick, _: *nanoui.menu.Item) void {
    const t = Tab.alive(p.serial) orelse return;
    const b = t.browser orelse return;
    _ = b.open(p.url, .{ .foreground = true, .from = t });
}

fn copyAddress(p: *Pick, _: *nanoui.menu.Item) void {
    const board = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.msg(objc.NSInteger, board, "clearContents", .{});
    _ = objc.msg(objc.BOOL, board, "setString:forType:", .{ objc.nsString(p.url), objc.nsString("public.utf8-plain-text") });
}

/// The same WKDownload the window already finishes (P5.5 `keep`).
fn downloadImage(p: *Pick, _: *nanoui.menu.Item) void {
    const t = Tab.alive(p.serial) orelse return;
    const wv = t.web orelse return;
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(p.url)}) orelse return;
    const job = std.heap.c_allocator.create(Job) catch return;
    job.* = .{ .serial = t.serial };
    var block = DownloadBlock.init(job, started);
    objc.msg(void, wv, "startDownloadUsingRequest:completionHandler:", .{ objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl}), @as(*anyopaque, @ptrCast(&block)) });
}

const Job = struct { serial: u64 };
const DownloadBlock = objc.Block(Job, &.{objc.Object});
const BlobBlock = objc.Block(Job, &.{ ?objc.Object, ?objc.Object });

fn started(job: *Job, download: objc.Object) void {
    defer std.heap.c_allocator.destroy(job);
    const t = Tab.alive(job.serial) orelse return;
    const b = t.browser orelse return;
    if (@hasDecl(Browser, "keep")) b.keep(download, t.web);
}

/// For Copy Image: no cookies, nothing cached (`Browser.fetcher`).
fn fetcher() ?*urlsession.Session {
    const S = struct {
        var session: ?*urlsession.Session = null;
    };
    if (S.session == null) S.session = urlsession.Session.create(std.heap.c_allocator, .{ .request_timeout = 30, .resource_timeout = 7 * 86400, .keeps_nothing = true }) catch null;
    return S.session;
}

/// A picture coming in, read as it comes and let go past the limit.
const Copy = struct {
    serial: u64,
    bytes: std.ArrayList(u8) = .empty,
    task: ?*urlsession.Task = null,

    fn of(ctx: *anyopaque) *Copy {
        return @ptrCast(@alignCast(ctx));
    }

    /// Done with: copied, or a word that it couldn't be.
    fn finish(job: *Copy, ok: bool) void {
        const a = std.heap.c_allocator;
        defer {
            job.bytes.deinit(a);
            a.destroy(job);
        }
        const t = Tab.alive(job.serial) orelse return;
        if (!ok) return copied(t, null);
        const pool = objc.Pool.push();
        defer pool.pop();
        copied(t, objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ job.bytes.items.ptr, @as(objc.NSUInteger, job.bytes.items.len) }));
    }

    /// Stopped short: the task says nothing more, so it is finished here.
    fn refuse(job: *Copy) void {
        if (job.task) |task| task.cancel();
        job.finish(false);
    }

    fn status(ctx: *anyopaque, code: i64) void {
        if (code != 0 and (code < 200 or code >= 300)) of(ctx).refuse();
    }

    fn length(ctx: *anyopaque, n: i64) void {
        if (n > largest_image) of(ctx).refuse();
    }

    fn data(ctx: *anyopaque, bytes: []const u8) void {
        const job = of(ctx);
        if (job.bytes.items.len + bytes.len > largest_image) return job.refuse();
        job.bytes.appendSlice(std.heap.c_allocator, bytes) catch job.refuse();
    }

    fn done(ctx: *anyopaque, failure: ?urlsession.Failure) void {
        of(ctx).finish(failure == null);
    }
};

/// Copy Image from the network: read as it comes, stopped past 50 MB.
pub fn copyFrom(t: *Tab, url: []const u8) void {
    const job = std.heap.c_allocator.create(Copy) catch return;
    job.* = .{ .serial = t.serial };
    const session = fetcher() orelse return job.finish(false);
    job.task = session.start(.{ .url = url }, .{ .ctx = job, .response = Copy.status, .length = Copy.length, .data = Copy.data, .done = Copy.done }) orelse return job.finish(false);
}

/// Fetched once and written as an actual image; a blob: picture is read
/// in the frame that made it.
fn copyImage(p: *Pick, _: *nanoui.menu.Item) void {
    const t = Tab.alive(p.serial) orelse return;
    if (!std.ascii.startsWithIgnoreCase(p.url, "blob:")) return copyFrom(t, p.url);
    const job = std.heap.c_allocator.create(Job) catch return;
    job.* = .{ .serial = t.serial };
    const wv = t.web orelse return std.heap.c_allocator.destroy(job);
    const read =
        \\const found = await fetch(src);
        \\const blob = await found.blob();
        \\if (!blob.type.startsWith("image/") || blob.size > 50000000) return null;
        \\const bytes = new Uint8Array(await blob.arrayBuffer());
        \\let text = "";
        \\for (let i = 0; i < bytes.length; i += 32768) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
        \\return btoa(text);
    ;
    const args = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{ objc.nsString(p.url), objc.nsString("src") });
    var block = BlobBlock.init(job, blobRead);
    objc.msg(void, wv, "callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:", .{ objc.nsString(read), args, p.frame, config.world(), @as(*anyopaque, @ptrCast(&block)) });
}

fn blobRead(job: *Job, value: ?objc.Object, _: ?objc.Object) void {
    defer std.heap.c_allocator.destroy(job);
    const t = Tab.alive(job.serial) orelse return;
    const text = value orelse return copied(t, null);
    if (!objc.msg(objc.BOOL, text, "isKindOfClass:", .{objc.class("NSString")})) return copied(t, null);
    const data = objc.msg(?objc.Object, objc.alloc("NSData"), "initWithBase64EncodedString:options:", .{ text, @as(objc.NSUInteger, 0) });
    defer if (data) |d| objc.release(d);
    copied(t, data);
}

fn copied(t: *Tab, data: ?objc.Object) void {
    const b = t.browser orelse return;
    const d = data orelse return b.announce("Couldn't copy that image");
    const image = if (reasonable(d)) objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithData:", .{d}) else null;
    const picture = image orelse return b.announce("Couldn't copy that image");
    defer objc.release(picture);
    const board = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.msg(objc.NSInteger, board, "clearContents", .{});
    _ = objc.msg(objc.BOOL, board, "writeObjects:", .{objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{picture})});
    b.announce("Image copied");
}

/// A picture this process may decode, read from its header first.
fn reasonable(data: objc.Object) bool {
    const n = objc.msg(objc.NSUInteger, data, "length", .{});
    if (n == 0 or n > largest_image) return false;
    const source = cg.CGImageSourceCreateWithData(@ptrCast(data), null) orelse return false;
    defer cg.CFRelease(source);
    if (cg.CGImageSourceGetCount(source) == 0) return false;
    const props = cg.CGImageSourceCopyPropertiesAtIndex(source, 0, null) orelse return false;
    defer objc.release(props);
    const w = objc.msg(?objc.Object, props, "objectForKey:", .{@as(objc.Object, @ptrCast(@constCast(cg.kCGImagePropertyPixelWidth)))}) orelse return false;
    const h = objc.msg(?objc.Object, props, "objectForKey:", .{@as(objc.Object, @ptrCast(@constCast(cg.kCGImagePropertyPixelHeight)))}) orelse return false;
    const pixels = objc.msg(objc.NSInteger, w, "integerValue", .{}) * objc.msg(objc.NSInteger, h, "integerValue", .{});
    return pixels > 0 and pixels <= most_pixels;
}
