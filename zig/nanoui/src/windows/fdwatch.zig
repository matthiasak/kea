//! Watching file descriptors is a POSIX idea: Windows apps wait on handles
//! instead. Not supported yet (nanoterm needs ConPTY first).
const std = @import("std");

pub const Handler = *const fn (ctx: ?*anyopaque) callconv(.c) void;

pub const Watch = struct {
    pub fn cancel(_: Watch) void {}
};

pub fn readable(fd: anytype, ctx: ?*anyopaque, handler: Handler) !Watch {
    _ = fd;
    _ = ctx;
    _ = handler;
    return error.Unsupported;
}

pub fn exited(pid: anytype, ctx: ?*anyopaque, handler: Handler) !Watch {
    _ = pid;
    _ = ctx;
    _ = handler;
    return error.Unsupported;
}
