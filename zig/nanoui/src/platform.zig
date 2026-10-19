//! What differs by operating system below nanoui's own code, chosen at
//! compile time: macOS (AppKit, CoreText, Metal), Linux (GTK, nanoui's own
//! text, the CPU renderer) and Windows (Win32, likewise).
const std = @import("std");
const builtin = @import("builtin");

pub const os = builtin.os.tag;

extern "c" fn CFRunLoopRunInMode(mode: *const anyopaque, seconds: f64, return_after: bool) i32;
extern "c" const kCFRunLoopDefaultMode: *const anyopaque;

/// Runs the event loop for `seconds`: replies, processes and timers get
/// handled (headless tests use it between frames).
pub fn runFor(seconds: f64) void {
    switch (os) {
        .macos => _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false),
        .linux => @import("linux/loop.zig").runFor(seconds),
        .windows => @import("windows/loop.zig").runFor(seconds),
        else => {},
    }
}

/// Writes text to the system's clipboard.
pub fn clipboardWrite(text: []const u8) void {
    switch (os) {
        .macos => @import("desktop.zig").clipboard.writeText(text),
        .linux => @import("linux/desktop.zig").clipboard.writeText(text),
        .windows => @import("windows/desktop.zig").clipboard.writeText(text),
        else => {},
    }
}
