//! Settings › Downloads (Settings.swift:537-553, 679-688): where files go,
//! whether to ask, and whether the downloads button always shows.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../../model/browser.zig").Browser;
const Kea = @import("../../app/kea.zig").Kea;
const Palette = @import("../../design/palette.zig").Palette;
const controls = @import("../controls.zig");
const plate = @import("../controls_plate.zig");
const frame = @import("frame.zig");

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    plate.cardBox(c, p);
    defer ui.end(c);
    plate.line(c, p, "Save to", homeShort(c, b.prefs.downloads));
    if (controls.pill(c, p, "Change…", .{}).clicked) objc.dispatchMain(b.kea, chooseFolder);
    ui.end(c);
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "asks_where_to_save", "Ask where to save each file", null);
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "always_shows_downloads", "Always show the downloads button", "Beside the other buttons, even with nothing downloading. Off, it shows only while a file comes in");
}

/// The path with the home folder written as ~.
fn homeShort(c: *ui.Context, path: []const u8) []const u8 {
    const home = std.c.getenv("HOME") orelse return path;
    const h = std.mem.span(home);
    if (h.len == 0 or !std.mem.startsWith(u8, path, h)) return path;
    return c.print("~{s}", .{path[h.len..]});
}

/// `chooseFolder`: an open panel for folders, on the next turn of the run
/// loop (its modal loop must not run inside a frame).
fn chooseFolder(ctx: ?*anyopaque) callconv(.c) void {
    const kea: *Kea = @ptrCast(@alignCast(ctx.?));
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{});
    objc.msg(void, panel, "setCanChooseDirectories:", .{true});
    objc.msg(void, panel, "setCanChooseFiles:", .{false});
    objc.msg(void, panel, "setCanCreateDirectories:", .{true});
    const now = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(kea.prefs.downloads)});
    objc.msg(void, panel, "setDirectoryURL:", .{now});
    objc.msg(void, panel, "setPrompt:", .{objc.nsString("Use this folder")});
    // NSModalResponseOK
    if (objc.msg(objc.NSInteger, panel, "runModal", .{}) != 1) return;
    const url = objc.msg(?objc.Object, panel, "URL", .{}) orelse return;
    kea.prefs.set("downloads", objc.fromNSString(objc.msg(objc.Object, url, "path", .{})));
    for (kea.browsers.items) |b| b.redraw();
}
