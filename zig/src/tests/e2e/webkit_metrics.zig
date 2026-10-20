//! KeaZig-only WebKit performance and footprint report (`webkit metrics (report)`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const main = @import("main.zig");
const Case = main.Case;
const Harness = main.Harness;
const smooth = @import("smooth.zig");

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

pub const cases = [_]Case{
    .{ .name = "webkit metrics (report)", .run = webkitMetrics },
};

fn physFootprintMb(pid: c_int) f64 {
    var info: rusage_info_v4 = .{};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, &info) != 0) return 0;
    return @as(f64, @floatFromInt(info.ri_phys_footprint)) / (1024.0 * 1024.0);
}

fn waitLoadedAndPainted(h: *Harness, t: *app.Tab, timeout_s: f64) !f64 {
    const t0 = ui.clock.now();
    const deadline = t0 + timeout_s;
    while (true) {
        const wv_opt = t.web;
        const painted = if (wv_opt) |wv| !app.page_view.unpainted(wv) else false;
        if (!t.loading and painted and t.url().len > 0) {
            return (ui.clock.now() - t0) * 1000.0;
        }
        if (ui.clock.now() > deadline) return h.fail("timed out waiting for paint/load of '{s}'", .{t.url()});
        const pool = objc.Pool.push();
        nanoui.runFor(0.002);
        pool.pop();
        h.frame();
    }
}

fn webkitMetrics(h: *Harness) !void {
    const b = try h.startWith(.{ .measuring = true });

    const t0 = b.open("kea-test://site/page?title=M0", .{ .foreground = true });
    const first_paint_ms = try waitLoadedAndPainted(h, t0, 10.0);

    var nav_ms: [5]f64 = undefined;
    for (0..5) |i| {
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "kea-test://site/page?title=M{d}", .{i + 1});
        const t = b.open(url, .{ .foreground = true });
        nav_ms[i] = try waitLoadedAndPainted(h, t, 10.0);
    }
    std.mem.sort(f64, &nav_ms, {}, comptime std.sort.asc(f64));
    const nav_ms_p50 = nav_ms[2];
    const nav_ms_max = nav_ms[4];

    const cpu0 = smooth.cpuSeconds();
    const wall0 = ui.clock.now();
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        nanoui.runFor(3.0);
    }
    const wall_elapsed = @max(0.001, ui.clock.now() - wall0);
    const idle_cpu_pct = ((smooth.cpuSeconds() - cpu0) / wall_elapsed) * 100.0;

    var pids: [32]c_int = undefined;
    var pid_count: usize = 0;
    var web_mb: f64 = 0;
    for (b.tabs.items) |tab| {
        const wv = tab.web orelse continue;
        if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_webProcessIdentifier")})) continue;
        const pid = objc.msg(c_int, wv, "_webProcessIdentifier", .{});
        if (pid <= 0) continue;
        var seen = false;
        for (pids[0..pid_count]) |p| {
            if (p == pid) {
                seen = true;
                break;
            }
        }
        if (!seen and pid_count < pids.len) {
            pids[pid_count] = pid;
            pid_count += 1;
            web_mb += physFootprintMb(pid);
        }
    }
    const app_mb = physFootprintMb(std.c.getpid());

    std.debug.print(
        "webkit-metrics: first_paint_ms={d:.1} nav_ms_p50={d:.1} nav_ms_max={d:.1} idle_cpu={d:.2}% web_procs={d} web_mb={d:.1} app_mb={d:.1}\n",
        .{ first_paint_ms, nav_ms_p50, nav_ms_max, idle_cpu_pct, pid_count, web_mb, app_mb },
    );
}
