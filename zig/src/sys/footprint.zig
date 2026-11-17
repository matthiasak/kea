//! Process physical footprint (`platform.processFootprintMb`) and
//! `WKWebView._webProcessIdentifier` lookup (macOS only; omitted on iOS).
const objc = @import("nanoui").objc;
const platform = @import("platform.zig");

pub fn mb(pid: c_int) ?f64 {
    return platform.processFootprintMb(pid);
}

pub fn webPid(view: ?objc.Object) ?c_int {
    if (comptime platform.is_ios) return null;
    const wv = view orelse return null;
    if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_webProcessIdentifier")})) return null;
    const pid = objc.msg(c_int, wv, "_webProcessIdentifier", .{});
    return if (pid > 0) pid else null;
}
