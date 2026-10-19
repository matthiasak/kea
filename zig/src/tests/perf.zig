//! `zig build perf`: CPU and GPU frame times while the sidebar edge is dragged
//! (40 headless tabs, sidebar on, 1440×900 at 2×, 80 steps 232 → 400 → 232).
//! Fails when the CPU p90 reaches 4.0 ms.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Fixture = @import("ui/fixture.zig").Fixture;

const steps = 80;
const cpu_gate_ms = 4.0;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true, .tabs = 39 });
    defer f.deinit();
    const t = &f.tester;

    const target = t.renderer.newTarget(t.size, t.scale);
    defer objc.release(target);
    for (0..5) |_| {
        t.frame();
        _ = t.renderer.drawTimed(target, t.instances.items, t.text.texture(), t.size, ui.Color.transparent);
    }

    // Press the edge handle (the 9 points over the column's inner edge), then drag it.
    const y = t.size.h / 2;
    t.moveTo(f.kea.prefs.side_width - 4.5, y);
    t.ctx.pointerDown();
    t.frame();

    var cpu: [steps]f64 = undefined;
    var gpu: [steps]f64 = undefined;
    var widest: f32 = 0;
    for (0..steps) |step| {
        const half: f32 = steps / 2;
        const i: f32 = @floatFromInt(step);
        const x: f32 = if (step < steps / 2) 232 + (400 - 232) * (i + 1) / half else 400 - (400 - 232) * (i + 1 - half) / half;
        t.ctx.input.mouse = .{ .x = x, .y = y };
        t.frame();
        const timing = t.renderer.drawTimed(target, t.instances.items, t.text.texture(), t.size, ui.Color.transparent);
        const st = t.ctx.stats;
        cpu[step] = st.build_ms + st.layout_ms + st.paint_ms;
        gpu[step] = timing.gpu_ms;
        widest = @max(widest, f.kea.prefs.side_width);
    }
    t.ctx.pointerUp();
    t.frame();
    // The numbers only count if the edge followed the pointer out and back
    // (out past 355, back near 232).
    const final = f.kea.prefs.side_width;
    if (widest < 355 or final > 245) {
        std.debug.print("perf: the drag missed the edge (widest {d:.0}, final {d:.0})\n", .{ widest, final });
        std.process.exit(1);
    }

    std.mem.sort(f64, &cpu, {}, comptime std.sort.asc(f64));
    std.mem.sort(f64, &gpu, {}, comptime std.sort.asc(f64));
    const cpu_med = (cpu[39] + cpu[40]) * 0.5;
    const gpu_med = (gpu[39] + gpu[40]) * 0.5;
    const cpu_p90 = cpu[72];
    const gpu_p90 = gpu[72];
    std.debug.print("perf: cpu median={d:.3} p90={d:.3} | gpu median={d:.3} p90={d:.3} (ms; {d} tabs, side width {d:.0})\n", .{
        cpu_med, cpu_p90, gpu_med, gpu_p90, f.browser.tabs.items.len, f.kea.prefs.side_width,
    });
    if (cpu_p90 >= cpu_gate_ms) {
        std.debug.print("perf: cpu p90 {d:.3} ms is at or over {d:.1} ms\n", .{ cpu_p90, cpu_gate_ms });
        std.process.exit(1);
    }
}
