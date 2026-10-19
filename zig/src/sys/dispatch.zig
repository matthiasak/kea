//! libdispatch and CoreFoundation externs (no blocks: the `_f` variants).
const objc = @import("nanoui").objc;

pub const Queue = objc.dispatch_queue_t;
pub const Work = *const fn (?*anyopaque) callconv(.c) void;

/// `attr` null is a serial queue (`DISPATCH_QUEUE_SERIAL`).
pub extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) Queue;
pub extern "c" fn dispatch_async_f(queue: Queue, context: ?*anyopaque, work: Work) void;
pub extern "c" fn dispatch_sync_f(queue: Queue, context: ?*anyopaque, work: Work) void;
pub extern "c" fn dispatch_release(object: *anyopaque) void;

/// Seconds since 2001-01-01 00:00:00 UTC (Foundation's reference date).
pub extern "c" fn CFAbsoluteTimeGetCurrent() f64;
