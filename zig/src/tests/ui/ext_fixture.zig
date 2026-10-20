//! An unpacked extension installed into a headless fixture, as the e2e
//! cases install theirs: the controller made by hand (a headless `Kea`
//! makes none), the extension written into the fixture's root and loaded.
//! Null below macOS 15.4.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

pub const manifest =
    \\{
    \\  "manifest_version": 3,
    \\  "name": "Kea Fixture",
    \\  "version": "1.0",
    \\  "action": { "default_popup": "popup.html", "default_title": "Kea Fixture" }
    \\}
;
pub const popup = "<!doctype html><title>Fixture Popup</title><body>The fixture's popup</body>";

/// The controller with the fixture extension loaded in it.
pub fn install(f: *Fixture) !?*app.ext_controller.Extensions {
    if (!app.ext.available()) return null;
    const k = f.kea;
    const e = k.ext orelse made: {
        const made = try app.ext_controller.Extensions.create(k);
        k.ext = made;
        made.start(f.browser);
        break :made made;
    };
    const dir = try f.temp.path(f.gpa, "Kea Fixture");
    defer f.gpa.free(dir);
    app.disk.makePath(f.gpa, dir);
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        for ([_][2][]const u8{ .{ "manifest.json", manifest }, .{ "popup.html", popup } }) |file| {
            const p = try std.fs.path.join(f.gpa, &.{ dir, file[0] });
            defer f.gpa.free(p);
            const d = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ file[1].ptr, file[1].len });
            if (!objc.msg(objc.BOOL, d, "writeToFile:atomically:", .{ objc.nsString(p), objc.YES })) return error.CouldNotWrite;
        }
    }
    e.installFolderAt(dir, false);
    const deadline = nanoui.ui.clock.now() + 20;
    while (e.contexts.count() == 0) {
        if (nanoui.ui.clock.now() > deadline) return error.NotLoaded;
        nanoui.runFor(0.05);
    }
    f.tester.frame();
    return e;
}
