//! Running the message loop for a while, between headless frames.
const w = @import("win32.zig");
const clock = @import("../ui/clock.zig");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

pub fn runFor(seconds: f64) void {
    const end = clock.now() + seconds;
    var msg: w.MSG = undefined;
    while (clock.now() < end) {
        if (w.PeekMessageW(&msg, null, 0, 0, 1) != 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        } else Sleep(2);
    }
}
