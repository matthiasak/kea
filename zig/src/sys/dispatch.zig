//! libdispatch and CoreFoundation externs (no blocks: the `_f` variants).
const objc = @import("nanoui").objc;

pub const Queue = objc.dispatch_queue_t;
pub const Work = *const fn (?*anyopaque) callconv(.c) void;

/// `attr` null is a serial queue (`DISPATCH_QUEUE_SERIAL`).
pub extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) Queue;
pub extern "c" fn dispatch_async_f(queue: Queue, context: ?*anyopaque, work: Work) void;
pub extern "c" fn dispatch_sync_f(queue: Queue, context: ?*anyopaque, work: Work) void;
pub extern "c" fn dispatch_release(object: *anyopaque) void;
/// `QOS_CLASS_USER_INITIATED`, as `dispatch_get_global_queue`'s identifier.
pub const qos_user_initiated: isize = 0x19;
pub extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) Queue;

/// `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` and what a source takes and says.
pub extern "c" const _dispatch_source_type_memorypressure: anyopaque;
pub const pressure_warning: usize = 2;
pub const pressure_critical: usize = 4;
pub extern "c" fn dispatch_source_create(kind: *const anyopaque, handle: usize, mask: usize, queue: Queue) ?*anyopaque;
pub extern "c" fn dispatch_set_context(object: *anyopaque, ctx: ?*anyopaque) void;
pub extern "c" fn dispatch_source_set_event_handler_f(source: *anyopaque, handler: Work) void;
pub extern "c" fn dispatch_source_get_data(source: *anyopaque) usize;
pub extern "c" fn dispatch_source_cancel(source: *anyopaque) void;
pub extern "c" fn dispatch_resume(object: *anyopaque) void;

/// Seconds since 2001-01-01 00:00:00 UTC (Foundation's reference date).
pub extern "c" fn CFAbsoluteTimeGetCurrent() f64;
