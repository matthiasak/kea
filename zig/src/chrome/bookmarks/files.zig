//! A bookmarks file in and out (`data/bookmarks_file.zig`): the manager's
//! File… brings in a page another browser exported, or Kea's own list;
//! `exportFile` writes the list as such a page (or JSON, by its name).
//! Both are sheets on the window; a window off screen is asked nothing.
// ponytail: File… reads bookmarks only; P11's ImportFile takes over it with
// passwords (.csv) and Safari's export (.zip).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../../model/browser.zig").Browser;
const Kea = @import("../../app/kea.zig").Kea;
const Uuid = @import("../../data/json.zig").Uuid;
const bookmarks_file = @import("../../data/bookmarks_file.zig");
const appkit = @import("../../sys/appkit.zig");

const Pending = struct {
    kea: *Kea,
    record: Uuid,
    panel: objc.Object,
    saving: bool,

    fn done(self: *Pending, response: objc.NSInteger) void {
        defer {
            objc.release(self.panel);
            std.heap.c_allocator.destroy(self);
        }
        if (response != 1) return;
        const b = for (self.kea.browsers.items) |x| {
            if (x.record_id.eql(self.record)) break x;
        } else return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const url = objc.msg(?objc.Object, self.panel, "URL", .{}) orelse return;
        if (self.saving) save(b, url) else take(b, url);
        b.redraw();
    }
};

fn begin(b: *Browser, panel: objc.Object, saving: bool) void {
    const w = b.window orelse return;
    const p = std.heap.c_allocator.create(Pending) catch return;
    p.* = .{ .kea = b.kea, .record = b.record_id, .panel = objc.retain(panel), .saving = saving };
    appkit.beginSheet(panel, w.nswindow, p, Pending.done);
}

fn types(ids: []const []const u8) objc.Object {
    const list = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (ids) |id| if (objc.msg(?objc.Object, objc.class("UTType"), "typeWithIdentifier:", .{objc.nsString(id)})) |t|
        objc.msg(void, list, "addObject:", .{t});
    return list;
}

/// File…: a bookmarks page another browser exported, or Kea's own list.
pub fn importFile(b: *Browser) void {
    if (b.window == null) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{});
    objc.msg(void, panel, "setAllowedContentTypes:", .{types(&.{ "public.html", "public.json" })});
    objc.msg(void, panel, "setAllowsMultipleSelection:", .{objc.NO});
    objc.msg(void, panel, "setPrompt:", .{objc.nsString("Bring In")});
    objc.msg(void, panel, "setMessage:", .{objc.nsString("A file another browser exported: bookmarks (.html), or Kea's own list (.json).")});
    begin(b, panel, false);
}

/// The bookmarks written out as a bookmarks page every browser reads, or
/// as Kea's JSON list when the name ends in .json.
pub fn exportFile(b: *Browser) void {
    if (b.window == null) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSSavePanel"), "savePanel", .{});
    objc.msg(void, panel, "setAllowedContentTypes:", .{types(&.{ "public.html", "public.json" })});
    objc.msg(void, panel, "setNameFieldStringValue:", .{objc.nsString("Bookmarks.html")});
    begin(b, panel, true);
}

fn take(b: *Browser, url: objc.Object) void {
    const data = objc.msg(?objc.Object, objc.class("NSData"), "dataWithContentsOfURL:", .{url}) orelse
        return b.announce("That file couldn't be read");
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const ptr = objc.msg(?[*]const u8, data, "bytes", .{});
    const bytes = if (ptr) |q| q[0..len] else "";
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = (bookmarks_file.read(a, bytes) catch null) orelse &.{};
    if (nodes.len == 0) return b.announce("Nothing to bring in from that file");
    const name = objc.fromNSString(objc.msg(objc.Object, objc.msg(objc.Object, url, "URLByDeletingPathExtension", .{}), "lastPathComponent", .{}));
    const t = b.bookmarks.take(nodes, name);
    b.announce(said(a, t.added, t.already) catch return);
}

/// What came in, as the file import says it.
pub fn said(a: std.mem.Allocator, added: usize, already: usize) ![]const u8 {
    if (added == 0 and already == 0) return "Bookmark folders imported";
    if (already == 0) return if (added == 1) "1 bookmark" else std.fmt.allocPrint(a, "{d} bookmarks", .{added});
    const news = if (added == 1) "1 new bookmark" else try std.fmt.allocPrint(a, "{d} new bookmarks", .{added});
    return std.fmt.allocPrint(a, "{s}, {d} already here", .{ news, already });
}

fn save(b: *Browser, url: objc.Object) void {
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ext = objc.fromNSString(objc.msg(objc.Object, url, "pathExtension", .{}));
    const text = (if (std.ascii.eqlIgnoreCase(ext, "json")) bookmarks_file.jsonText(a, b.bookmarks.roots) else bookmarks_file.html(a, b.bookmarks.roots)) catch return;
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ text.ptr, @as(objc.NSUInteger, text.len) });
    if (!objc.msg(objc.BOOL, data, "writeToURL:atomically:", .{ url, objc.YES })) b.announce("That file couldn't be written");
}
