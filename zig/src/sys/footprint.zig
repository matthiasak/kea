//! Process physical footprint (`proc_pid_rusage` `RUSAGE_INFO_V4`) and
//! `WKWebView._webProcessIdentifier` lookup.
const objc = @import("nanoui").objc;

const RUSAGE_INFO_V4: c_int = 4;

const rusage_info_v4 = extern struct {
    ri_uuid: [16]u8 = @splat(0),
    ri_user_time: u64 = 0,
    ri_system_time: u64 = 0,
    ri_pkg_idle_wkups: u64 = 0,
    ri_interrupt_wkups: u64 = 0,
    ri_pageins: u64 = 0,
    ri_wired_size: u64 = 0,
    ri_resident_size: u64 = 0,
    ri_phys_footprint: u64 = 0,
    rest: [27]u64 = @splat(0),
};

extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;

pub fn mb(pid: c_int) ?f64 {
    if (pid <= 0) return null;
    var info: rusage_info_v4 = .{};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, &info) != 0) return null;
    return @as(f64, @floatFromInt(info.ri_phys_footprint)) / (1024.0 * 1024.0);
}

pub fn webPid(view: ?objc.Object) ?c_int {
    const wv = view orelse return null;
    if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_webProcessIdentifier")})) return null;
    const pid = objc.msg(c_int, wv, "_webProcessIdentifier", .{});
    return if (pid > 0) pid else null;
}
