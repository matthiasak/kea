//! P13's extensions: an unpacked one installed from a folder, as a
//! developer loads one, runs its content script on the pages it matches.
//! The page is the harness's own `kea-test://site/page`: the scheme is
//! registered for match patterns as Kea registers chrome-extension
//! (Extensions.swift:155), so the fixture's `kea-test://site/*` matches.
//! Below macOS 15.4 there is no extension engine and the case is skipped.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;
const web = @import("web.zig");

pub const cases = [_]Case{
    .{ .name = "unpacked fixture extension injects content script", .run = injects },
};

const files = [_]struct { []const u8, []const u8 }{
    .{ "manifest.json", @embedFile("fixtures/ext/manifest.json") },
    .{ "content.js", @embedFile("fixtures/ext/content.js") },
};

fn loaded(e: *app.ext_controller.Extensions) bool {
    return e.contexts.count() > 0;
}

fn injects(h: *Harness) !void {
    if (!app.ext.available()) return error.Skipped;
    const b = try h.start();
    const e = h.kea.?.ext orelse return h.fail("no extensions controller", .{});
    // The fixture as a folder on disk, inside the case's own root.
    const dir = try h.temp.path(h.gpa, "fixture-ext");
    defer h.gpa.free(dir);
    app.disk.makePath(h.gpa, dir);
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        for (files) |f| {
            const p = try std.fs.path.join(h.gpa, &.{ dir, f[0] });
            defer h.gpa.free(p);
            const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ f[1].ptr, f[1].len });
            try h.expect(objc.msg(objc.BOOL, d, "writeToFile:atomically:", .{ objc.nsString(p), objc.YES }), "couldn't write {s}", .{f[0]});
        }
    }
    objc.msg(void, objc.class("WKWebExtensionMatchPattern"), "registerCustomURLScheme:", .{objc.nsString("kea-test")});
    // As Swift's bench does: no question asked.
    e.installFolderAt(dir, false);
    h.waitFor(e, loaded, 20, "the extension to load") catch {
        // What the controller knows, so a refusal explains itself.
        var said: std.ArrayList(u8) = .empty;
        defer said.deinit(h.gpa);
        for (e.errors.keys(), e.errors.values()) |id, list| for (list.items) |s| {
            said.print(h.gpa, "[{s}] {s}; ", .{ id, s }) catch {};
        };
        return h.fail("not loaded: installed {d}, busy {s}, said '{s}', errors: {s}", .{ e.installed.items.len, e.busy orelse "-", b.announcement orelse "", said.items });
    };
    try h.expect(e.installed.items.len == 1 and e.installed.items[0].source != null, "installed {d}", .{e.installed.items.len});
    const url = "kea-test://site/page?title=E";
    const t = try web.open(h, b, url);
    // document_idle: soon after the page finished.
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        if (std.mem.eql(u8, try web.eval(h, t, "document.body.dataset.ext"), "1")) return;
        h.pump(0.1);
    }
    return h.fail("content script didn't run: dataset.ext is {s}", .{try web.eval(h, t, "String(document.body.dataset.ext)")});
}
