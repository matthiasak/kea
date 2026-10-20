//! A file in and out: File… brings in what another browser exported — a
//! bookmarks page, a passwords file, Safari's export or a folder of them
//! (`importFile`, read by `model/browser_import.zig` `takeFile`); `exportFile`
//! writes the list as a bookmarks page (or JSON, by its name). Both are
//! sheets on the window; a window off screen is asked nothing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../../model/browser.zig").Browser;
const Kea = @import("../../app/kea.zig").Kea;
const Uuid = @import("../../data/json.zig").Uuid;
const bookmarks_file = @import("../../data/bookmarks_file.zig");
const appkit = @import("../../sys/appkit.zig");
const takers = @import("../../model/browser_import.zig");

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
        if (self.saving) save(b, url) else _ = takers.takeFile(b, objc.fromNSString(objc.msg(objc.Object, url, "path", .{})));
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

/// File… (`Browser.importFile`): something another browser exported. Read
/// once, never copied. Nothing while a file is already coming in.
pub fn importFile(b: *Browser) void {
    if (b.window == null or b.importing.file != null) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{});
    objc.msg(void, panel, "setAllowedContentTypes:", .{types(&.{ "public.html", "public.comma-separated-values-text", "public.plain-text", "public.zip-archive", "public.json" })});
    objc.msg(void, panel, "setCanChooseDirectories:", .{objc.YES});
    objc.msg(void, panel, "setAllowsMultipleSelection:", .{objc.NO});
    objc.msg(void, panel, "setPrompt:", .{objc.nsString("Bring In")});
    objc.msg(void, panel, "setMessage:", .{objc.nsString("A file another browser exported: bookmarks (.html), passwords (.csv), or Safari's File › Export Browsing Data (.zip).")});
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

fn save(b: *Browser, url: objc.Object) void {
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ext = objc.fromNSString(objc.msg(objc.Object, url, "pathExtension", .{}));
    const text = (if (std.ascii.eqlIgnoreCase(ext, "json")) bookmarks_file.jsonText(a, b.bookmarks.roots) else bookmarks_file.html(a, b.bookmarks.roots)) catch return;
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ text.ptr, @as(objc.NSUInteger, text.len) });
    if (!objc.msg(objc.BOOL, data, "writeToURL:atomically:", .{ url, objc.YES })) b.announce("That file couldn't be written");
}
