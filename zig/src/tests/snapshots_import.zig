//! P11 snapshot state: Bring things over, with a made-up Chrome and Firefox
//! found and counted, Chrome picked.
const std = @import("std");
const nanoui = @import("nanoui");
const app = @import("kea");
const Fixture = @import("ui/fixture.zig").Fixture;
const madeUp = @import("ui/import.zig").madeUp;

pub fn sheet(f: *Fixture) void {
    var arena: std.heap.ArenaAllocator = .init(f.gpa);
    defer arena.deinit();
    madeUp(arena.allocator(), f.temp.root) catch return;
    app.sheet.show(f.browser, .bringing);
    // Looked for and counted off the main thread: waited for here.
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        nanoui.runFor(0.02);
        f.tester.frame();
        const s = f.browser.importing.panel orelse continue;
        if (s.looking) continue;
        var all = true;
        for (0..s.found.len) |i| if (s.preview(i) == null) {
            all = false;
        };
        if (all) break;
    }
}
