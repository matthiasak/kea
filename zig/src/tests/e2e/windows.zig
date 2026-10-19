//! P3's windows: ⌘N cascades from the window in front and quitting writes
//! it to `windows.json`; a window closed with others open comes back, and
//! the last one closed is kept.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "second window cascades and persists", .run = cascades },
    .{ .name = "closed window reopens and the last one is kept", .run = closing },
    .{ .name = "lights sit centred in the strip and follow a right column", .run = lights },
};

fn frameOf(b: *app.Browser) objc.CGRect {
    return objc.msg(objc.CGRect, b.window.?.nswindow, "frame", .{});
}

/// A test run's window is never ordered in, and stays far off every screen.
fn offScreen(h: *Harness, b: *app.Browser, what: []const u8) !void {
    const ns = b.window.?.nswindow;
    const f = frameOf(b);
    try h.expect(!objc.msg(objc.BOOL, ns, "isVisible", .{}) and f.origin.x < -10000, "{s}: visible or on screen at {d},{d}", .{ what, f.origin.x, f.origin.y });
}

fn cascades(h: *Harness) !void {
    const first = try h.start();
    const k = h.kea.?;
    const a = frameOf(first);
    const second = try app.browsers.newWindow(k);
    h.frame();
    const b = frameOf(second);
    try h.expect(k.browsers.items.len == 2, "{d} browsers", .{k.browsers.items.len});
    try h.expect(b.size.width == a.size.width and b.size.height == a.size.height, "size {d}x{d}, front {d}x{d}", .{ b.size.width, b.size.height, a.size.width, a.size.height });
    // Down and to the right: AppKit's y runs up, so the top edge is lower.
    try h.expect(b.origin.x > a.origin.x and b.origin.y + b.size.height < a.origin.y + a.size.height, "not cascaded: {d},{d} from {d},{d}", .{ b.origin.x, b.origin.y, a.origin.x, a.origin.y });
    try offScreen(h, first, "first");
    try offScreen(h, second, "cmd-N");
    h.quit();

    const bytes = h.readFile("windows.json") orelse return h.fail("no windows.json", .{});
    defer h.gpa.free(bytes);
    const recs = try app.json.decode([]app.windows_file.WindowRecord, h.gpa, bytes);
    defer recs.deinit();
    try h.expect(recs.value.len == 2, "{d} records: {s}", .{ recs.value.len, bytes });
    // The oldest window's line holds its frame only; the other's its rows too.
    try h.expect(recs.value[0].rows.map.count() == 0, "first line has rows", .{});
    const saved = app.browsers.rect(recs.value[1].frame) orelse return h.fail("second line's frame: {s}", .{bytes});
    try h.expect(std.meta.eql(saved, b), "saved frame differs: {s}", .{bytes});
    try h.expect(recs.value[1].rows.map.count() == 1, "second line rows: {s}", .{bytes});
}

fn closing(h: *Harness) !void {
    const first = try h.start();
    const k = h.kea.?;
    const second = try app.browsers.newWindow(k);
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "{s}/page?title=W", .{h.http});
    _ = second.openTab(url, true, false);
    objc.msg(void, second.window.?.nswindow, "performClose:", .{@as(?objc.Object, null)});
    h.pump(0.1);
    try h.expect(k.browsers.items.len == 1 and k.windows.closed.items.len == 1, "{d} browsers, {d} closed", .{ k.browsers.items.len, k.windows.closed.items.len });
    try h.expect(app.browsers.reopenClosedWindow(k), "nothing to reopen", .{});
    try h.expect(k.browsers.items.len == 2, "{d} browsers after reopen", .{k.browsers.items.len});
    const back = k.browsers.items[1];
    try offScreen(h, back, "reopened");
    var found = false;
    for (back.tabs.items) |t| found = found or std.mem.eql(u8, t.url(), url);
    try h.expect(found, "reopened window lost its tab", .{});
    // Closing the oldest makes the other the oldest: its tabs go to the files.
    objc.msg(void, first.window.?.nswindow, "performClose:", .{@as(?objc.Object, null)});
    h.pump(0.1);
    try h.expect(k.browsers.items.len == 1 and k.browsers.items[0] == back and back.uses_files, "primary not handed on", .{});
    // The last one closed stays, tabs and all, and ⌘N brings it back.
    objc.msg(void, back.window.?.nswindow, "performClose:", .{@as(?objc.Object, null)});
    h.pump(0.1);
    try h.expect(k.browsers.items.len == 1 and back.shut and back.window != null, "last window not kept", .{});
    try h.expect(try app.browsers.newWindow(k) == back and !back.shut, "cmd-N didn't bring the kept window back", .{});
    try offScreen(h, back, "kept and shown again");
}

/// The close button's centre from the window's top-left.
fn closeCentre(b: *app.Browser) objc.CGPoint {
    const ns = b.window.?.nswindow;
    const close = objc.msg(objc.Object, ns, "standardWindowButton:", .{@as(objc.NSUInteger, 0)});
    const r = objc.msg(objc.CGRect, close, "convertRect:toView:", .{ objc.msg(objc.CGRect, close, "bounds", .{}), @as(?objc.Object, null) });
    const h = objc.msg(objc.CGRect, ns, "frame", .{}).size.height;
    return .{ .x = r.origin.x + r.size.width / 2, .y = h - (r.origin.y + r.size.height / 2) };
}

fn lights(h: *Harness) !void {
    const b = try h.start();
    b.prefs.set("sidebar", false);
    h.pump(0.1);
    var c = closeCentre(b);
    try h.expect(@abs(c.x - 26) < 0.5 and @abs(c.y - 26) < 0.5, "close centre {d},{d}, want 26,26", .{ c.x, c.y });
    b.prefs.set("sidebar", true);
    b.prefs.set("side_position", .right);
    b.redraw();
    h.pump(0.1);
    c = closeCentre(b);
    const want = objc.msg(objc.CGRect, b.window.?.nswindow, "frame", .{}).size.width - b.prefs.side_width + 26;
    try h.expect(@abs(c.x - want) < 0.5 and @abs(c.y - 26) < 0.5, "close centre {d},{d}, want {d},26", .{ c.x, c.y, want });
    // The title bar draws above the content, not under it (`dress`).
    const ns = b.window.?.nswindow;
    const close = objc.msg(objc.Object, ns, "standardWindowButton:", .{@as(objc.NSUInteger, 0)});
    const container = objc.msg(objc.Object, objc.msg(objc.Object, close, "superview", .{}), "superview", .{});
    const content = objc.msg(objc.Object, ns, "contentView", .{});
    const subs = objc.msg(objc.Object, objc.msg(objc.Object, content, "superview", .{}), "subviews", .{});
    const above = objc.msg(objc.NSUInteger, subs, "indexOfObject:", .{container}) > objc.msg(objc.NSUInteger, subs, "indexOfObject:", .{content});
    const z = objc.msg(f64, objc.msg(objc.Object, container, "layer", .{}), "zPosition", .{});
    try h.expect(above and z == 10, "title bar above content {}, zPosition {d}", .{ above, z });
    // AppKit's spacing kept, not the fallback squeezed in.
    const zoom = objc.msg(objc.Object, ns, "standardWindowButton:", .{@as(objc.NSUInteger, 2)});
    const gap = (objc.msg(objc.CGRect, zoom, "frame", .{}).origin.x - objc.msg(objc.CGRect, close, "frame", .{}).origin.x) / 2;
    try h.expect(gap >= 16 and gap <= 32, "spacing {d}", .{gap});
}
