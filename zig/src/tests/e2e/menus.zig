//! P8.9: the menu bar's items do what they say, and a key moved in
//! Settings › Shortcuts moves on the live item.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "menu Reload Page reloads", .run = reloadItem },
    .{ .name = "a moved key moves on the menu bar's item", .run = movedKey },
};

/// The live bar's item with `id`, by AppKit's own lookup.
fn item(h: *Harness, id: []const u8) ?*nanoui.menu.Item {
    const a = h.kea.?.ui_app orelse return null;
    return a.menuItem(id);
}

fn reloadItem(h: *Harness) !void {
    const b = try h.start();
    const t = try web.open(h, b, "kea-test://site/page?title=Again");
    try h.expect(!t.loading, "the page is still loading", .{});
    const ns = (item(h, "view.reload") orelse return h.fail("no Reload Page item", .{})).ns;
    // The View menu opens (made again as it is), then the item is chosen.
    const menu = objc.msg(objc.Object, ns, "menu", .{});
    objc.msg(void, menu, "update", .{});
    const fresh = item(h, "view.reload") orelse return h.fail("Reload Page went with the update", .{});
    const index = objc.msg(objc.NSInteger, menu, "indexOfItem:", .{fresh.ns});
    try h.expect(index >= 0, "Reload Page isn't in its menu", .{});
    objc.msg(void, menu, "performActionForItemAtIndex:", .{index});
    try h.expect(t.loading, "Reload Page left the tab not loading", .{});
}

fn movedKey(h: *Harness) !void {
    _ = try h.start();
    const k = h.kea.?;
    const before = item(h, "file.newTab") orelse return h.fail("no New Tab item", .{});
    try h.expect(objc.msg(objc.NSUInteger, before.ns, "keyEquivalentModifierMask", .{}) == 1 << 20, "New Tab isn't on ⌘T", .{});
    k.shortcuts.setOverride("file.newTab", app.shortcuts.combo("t", .{ .option = true }));
    const after = item(h, "file.newTab") orelse return h.fail("no New Tab item", .{});
    const mask = objc.msg(objc.NSUInteger, after.ns, "keyEquivalentModifierMask", .{});
    try h.expect(mask == (1 << 20) | (1 << 19), "New Tab's item is on mask {x}, not ⌥⌘", .{mask});
    const pool = objc.Pool.push();
    defer pool.pop();
    const key = objc.fromNSString(objc.msg(objc.Object, after.ns, "keyEquivalent", .{}));
    try h.expect(std.mem.eql(u8, key, "t"), "New Tab's item is on '{s}'", .{key});
}
