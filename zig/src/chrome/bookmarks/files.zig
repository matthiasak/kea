//! A file in: File… brings in what another browser exported — a
//! bookmarks page, a passwords file, Safari's export or a folder of them
//! (`importFile`, read by `model/browser_import.zig` `takeFile`), asked
//! as a sheet on the window; a window off screen is asked nothing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const platform = @import("../../sys/platform.zig");
const Browser = @import("../../model/browser.zig").Browser;
const Kea = @import("../../app/kea.zig").Kea;
const Uuid = @import("../../data/json.zig").Uuid;
const appkit = @import("../../sys/appkit.zig");
const takers = @import("../../model/browser_import.zig");

const Pending = struct {
    kea: *Kea,
    record: Uuid,
    panel: objc.Object,

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
        _ = takers.takeFile(b, objc.fromNSString(objc.msg(objc.Object, url, "path", .{})));
        b.redraw();
    }
};

const IosPick = struct {
    kea: *Kea,
    record: Uuid,
    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const self: *IosPick = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(self);
        const b0 = for (self.kea.browsers.items) |x| {
            if (x.record_id.eql(self.record)) break x;
        } else return;
        const paths = (nanoui.dialog.open(b0.gpa, .{
            .title = "Bring In",
            .extensions = &.{ "html", "htm", "csv", "txt", "zip", "json" },
        }) catch null) orelse return;
        defer nanoui.dialog.freePaths(b0.gpa, paths);
        if (paths.len == 0) return;
        const b = for (self.kea.browsers.items) |x| {
            if (x.record_id.eql(self.record)) break x;
        } else return;
        _ = takers.takeFile(b, paths[0]);
        b.redraw();
    }
};

fn begin(b: *Browser, panel: objc.Object) void {
    if (comptime platform.is_ios) return;
    const w = b.window orelse return;
    const p = std.heap.c_allocator.create(Pending) catch return;
    p.* = .{ .kea = b.kea, .record = b.record_id, .panel = objc.retain(panel) };
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
    if (comptime platform.is_ios) {
        const pick = std.heap.c_allocator.create(IosPick) catch return;
        pick.* = .{ .kea = b.kea, .record = b.record_id };
        objc.dispatchMain(pick, IosPick.run);
        return;
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{});
    objc.msg(void, panel, "setAllowedContentTypes:", .{types(&.{ "public.html", "public.comma-separated-values-text", "public.plain-text", "public.zip-archive", "public.json" })});
    objc.msg(void, panel, "setCanChooseDirectories:", .{objc.YES});
    objc.msg(void, panel, "setAllowsMultipleSelection:", .{objc.NO});
    objc.msg(void, panel, "setPrompt:", .{objc.nsString("Bring In")});
    objc.msg(void, panel, "setMessage:", .{objc.nsString("A file another browser exported: bookmarks (.html), passwords (.csv), or Safari's File › Export Browsing Data (.zip).")});
    begin(b, panel);
}
