//! Running the message loop for a while, between headless frames: messages
//! (input, timers, fdwatch's posts) are handled as they come, and the wait
//! between them sleeps in MsgWaitForMultipleObjects.
const w = @import("win32.zig");
const clock = @import("../ui/clock.zig");

extern "user32" fn MsgWaitForMultipleObjects(n: u32, handles: ?[*]const *anyopaque, all: w.BOOL, ms: u32, wake: u32) callconv(.winapi) u32;
const QS_ALLINPUT = 0x04FF;

pub fn runFor(seconds: f64) void {
    const end = clock.now() + seconds;
    var msg: w.MSG = undefined;
    while (true) {
        while (w.PeekMessageW(&msg, null, 0, 0, 1) != 0) {
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        const left = end - clock.now();
        if (left <= 0) return;
        _ = MsgWaitForMultipleObjects(0, null, 0, @intFromFloat(@ceil(left * 1000)), QS_ALLINPUT);
    }
}
