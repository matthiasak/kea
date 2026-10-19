//! Phase 0 Go/No-Go Benchmark (`zig build bench-drag`):
//! Renders a 40-tab sidebar, top toolbar, draggable Ubi Chat side panel,
//! floating opaque Omnibox dropdown (with analytical Gaussian shadow), and
//! 2 split WKWebView stage holes across an 80-step panel edge drag.
//! Measures CPU (`build_ms + layout_ms + paint_ms`), `encode_ms`, and `gpu_ms`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;

const SpikeState = struct {
    side_width: f32 = 220,
    chat_width: f32 = 500,
    active_tab: usize = 3,
    omni_buf: ui.TextBuffer = .{},
    chat_buf: ui.TextBuffer = .{},

    fn view(s: *SpikeState, c: *ui.Context) void {
        const ground = ui.Color.hex(0xFAF8F5);
        const frame_col = ui.Color.hex(0xF1EDE7);
        const wash = ui.Color.hex(0xE6E0D6);
        const ink = ui.Color.hex(0x1C1B19);
        const muted = ui.Color.hex(0x6E6A63);
        const hairline = ui.Color.hex(0xD8D2C9);

        // Root row: Left Sidebar + Center Stage + Right Ubi Chat Panel
        ui.row(c, .{ .width = .fill, .height = .fill });
        defer ui.end(c);

        // 1. Left Sidebar (40 tabs + pins + foot)
        ui.column(c, .{
            .width = .{ .px = s.side_width },
            .height = .fill,
            .background = frame_col,
            .padding = .{ .top = 38, .left = 8, .right = 8, .bottom = 10 },
            .gap = 6,
        });
        {
            // Address bar button in sidebar
            _ = ui.button(c, "docs.ziglang.org", .{ .width = .fill, .variant = .secondary, .icon = "magnifyingglass" });

            // Pin grid (4 pins)
            ui.row(c, .{ .width = .fill, .gap = 6 });
            for (0..4) |p| {
                ui.key(c, c.print("pin-{d}", .{p}));
                const it = ui.pressable(c, .{
                    .grow = 1,
                    .height = .{ .px = 36 },
                    .radius = 8,
                    .background = wash,
                    .align_items = .center,
                    .justify = .center,
                }, ground);
                _ = it;
                ui.textf(c, .{ .size = 13, .weight = .semibold, .color = ink }, "P{d}", .{p + 1});
                ui.end(c);
            }
            ui.end(c);

            // 40 visible tabs in a scrollable list
            ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 2 });
            for (0..40) |i| {
                ui.key(c, c.print("tab-{d}", .{i}));
                const selected = i == s.active_tab;
                const row_it = ui.pressable(c, .{
                    .direction = .row,
                    .width = .fill,
                    .height = .{ .px = 30 },
                    .padding = .xy(8, 5),
                    .radius = 8,
                    .background = if (selected) ground else null,
                    .shadow = if (selected) .{ .color = .{ .a = 0.08 }, .blur = 4, .y = 1 } else null,
                    .align_items = .center,
                    .gap = 8,
                }, wash);
                c.addA11y(c.stack.items[c.stack.items.len - 1], .tab, c.print("Page {d}", .{i}), "", selected, true);
                if (row_it.clicked) s.active_tab = i;
                ui.icon(c, "globe", .{ .size = 13, .color = if (selected) ink else muted });
                ui.textf(c, .{ .size = 13, .weight = if (selected) .medium else .regular, .color = ink }, "Page {d} — Benchmark Tab", .{i});
                ui.spacer(c);
                ui.end(c);
            }
            ui.end(c);

            // Bottom SideFoot
            ui.row(c, .{ .width = .fill, .height = .{ .px = 28 }, .align_items = .center, .gap = 6 });
            _ = ui.button(c, "", .{ .variant = .ghost, .icon = "circle.grid.2x2", .size = 13 });
            _ = ui.button(c, "", .{ .variant = .ghost, .icon = "book", .size = 13 });
            ui.spacer(c);
            _ = ui.button(c, "", .{ .variant = .ghost, .icon = "sparkles", .size = 13 });
            ui.end(c);
        }
        ui.end(c);

        // 2. Center Stage (Split View: 2 transparent WKWebView holes + floating opaque Omnibox card)
        ui.column(c, .{ .grow = 1, .height = .fill, .padding = .all(6), .gap = 6, .background = frame_col });
        {
            ui.row(c, .{ .width = .fill, .grow = 1, .gap = 7 });
            // Left pane hole
            const left_idx = c.open(.{ .grow = 1, .height = .fill, .radius = 10, .border = hairline }, "pane-left");
            const left_id = c.node(left_idx).id;
            if (c.rects.get(left_id)) |r| c.addStageHole(r);
            // Floating opaque Omnibox overlay with analytical Gaussian shadow (not .glass over transparent hole)
            ui.column(c, .{
                .width = .{ .px = 420 },
                .padding = .all(12),
                .radius = 12,
                .background = ground,
                .border = hairline,
                .shadow = .{ .color = .{ .a = 0.16 }, .blur = 28, .y = 8 },
                .gap = 6,
            });
            _ = ui.textField(c, &s.omni_buf, .{ .placeholder = "Search or enter address", .width = .fill });
            for (0..4) |k| {
                ui.row(c, .{ .width = .fill, .padding = .xy(8, 5), .radius = 6, .gap = 8, .align_items = .center });
                ui.icon(c, "magnifyingglass", .{ .size = 12, .color = muted });
                ui.textf(c, .{ .size = 13, .color = ink }, "Suggestion {d} — https://example.org/p{d}", .{ k, k });
                ui.end(c);
            }
            ui.end(c);
            c.end();

            // Right pane hole
            const right_idx = c.open(.{ .grow = 1, .height = .fill, .radius = 10, .border = hairline }, "pane-right");
            const right_id = c.node(right_idx).id;
            if (c.rects.get(right_id)) |r| c.addStageHole(r);
            c.end();
            ui.end(c);
        }
        ui.end(c);

        // 3. Right Ubi Chat Panel + 9 pt EdgeHandle
        const handle_idx = c.open(.{ .width = .{ .px = 9 }, .height = .fill, .align_items = .center, .justify = .center }, "chat-handle");
        const handle_it = c.interact(handle_idx, .{});
        c.addA11y(handle_idx, .splitter, "Resize Ubi Chat", "", false, true);
        if (handle_it.hovered or handle_it.pressed) c.cursor = .resize_left_right;
        _ = c.leaf(.{ .width = .{ .px = 2 }, .height = .fill, .background = if (handle_it.hovered or handle_it.pressed) muted else ColorTransparent }, .none, null);
        c.end();

        ui.column(c, .{
            .width = .{ .px = s.chat_width },
            .height = .fill,
            .background = ground,
            .border = hairline,
            .padding = .all(12),
            .gap = 10,
        });
        {
            ui.row(c, .{ .width = .fill, .align_items = .center });
            ui.text(c, "Ubi Chat", .{ .size = 14, .weight = .semibold, .color = ink });
            ui.spacer(c);
            _ = ui.button(c, "New", .{ .variant = .ghost, .size = 12, .icon = "plus" });
            ui.end(c);

            ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 8 });
            for (0..8) |m| {
                ui.card(c, .{ .width = .fill, .padding = .all(10), .radius = 10, .background = frame_col, .shadow = null });
                ui.textf(c, .{ .size = 13, .color = ink, .wrap = true }, "Message #{d}: Streaming immediate-mode response with zero AttributeGraph cascade.", .{m});
                ui.end(c);
            }
            ui.end(c);

            _ = ui.textField(c, &s.chat_buf, .{ .placeholder = "Ask Ubi Chat (@ to mention tab)...", .width = .fill });
        }
        ui.end(c);
    }
};

const ColorTransparent = ui.Color.transparent;

fn sortF64(items: []f64) void {
    std.mem.sort(f64, items, {}, comptime std.sort.asc(f64));
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var state: SpikeState = .{};
    state.omni_buf.set("https://ziglang.org/documentation/");
    const view = ui.View.init(&state, SpikeState.view);

    var tester: ui.Tester = undefined;
    try tester.init(gpa, view, .{ .width = 1440, .height = 900, .scale = 2 });
    defer tester.deinit();
    tester.ctx.transparent_root = true;

    const target = tester.renderer.newTarget(tester.size, tester.scale);
    defer objc.release(target);

    for (0..5) |_| {
        tester.frame();
        _ = tester.renderer.drawTimed(target, tester.instances.items, tester.text.texture(), tester.size, ui.Color.transparent);
    }

    var cpu_totals: [80]f64 = undefined;
    var build_ms: [80]f64 = undefined;
    var layout_ms: [80]f64 = undefined;
    var paint_ms: [80]f64 = undefined;
    var encode_ms: [80]f64 = undefined;
    var gpu_ms: [80]f64 = undefined;

    for (0..80) |step| {
        const delta: f32 = if (step < 40) -3.5 else 3.5;
        state.chat_width = std.math.clamp(state.chat_width + delta, 280, 720);
        tester.frame();
        const gpu_t = tester.renderer.drawTimed(target, tester.instances.items, tester.text.texture(), tester.size, ui.Color.transparent);
        const st = tester.ctx.stats;
        build_ms[step] = st.build_ms;
        layout_ms[step] = st.layout_ms;
        paint_ms[step] = st.paint_ms;
        cpu_totals[step] = st.build_ms + st.layout_ms + st.paint_ms;
        encode_ms[step] = gpu_t.encode_ms;
        gpu_ms[step] = gpu_t.gpu_ms;
    }

    sortF64(&cpu_totals);
    sortF64(&build_ms);
    sortF64(&layout_ms);
    sortF64(&paint_ms);
    sortF64(&encode_ms);
    sortF64(&gpu_ms);

    const med_cpu = (cpu_totals[39] + cpu_totals[40]) * 0.5;
    const p90_cpu = cpu_totals[72];
    const med_build = (build_ms[39] + build_ms[40]) * 0.5;
    const med_layout = (layout_ms[39] + layout_ms[40]) * 0.5;
    const med_paint = (paint_ms[39] + paint_ms[40]) * 0.5;
    const med_enc = (encode_ms[39] + encode_ms[40]) * 0.5;
    const med_gpu = (gpu_ms[39] + gpu_ms[40]) * 0.5;
    const p90_gpu = gpu_ms[72];

    std.debug.print(
        "nanoui Phase-0 drag benchmark (n=80, 40 tabs, split stage + omnibox + Ubi Chat):\n" ++
            "  CPU frame : median={d:.3} ms, p90={d:.3} ms (gate < 0.300 ms)\n" ++
            "  breakdown : build={d:.3} ms, layout={d:.3} ms, paint={d:.3} ms\n" ++
            "  Metal GPU : encode median={d:.3} ms, GPU median={d:.3} ms, GPU p90={d:.3} ms (gate < 0.500 ms)\n" ++
            "  nodes={d}, instances={d}, stage_holes={d}, a11y_items={d}\n",
        .{
            med_cpu,
            p90_cpu,
            med_build,
            med_layout,
            med_paint,
            med_enc,
            med_gpu,
            p90_gpu,
            tester.ctx.stats.nodes,
            tester.ctx.stats.instances,
            tester.ctx.stage_count,
            tester.ctx.a11y_items.items.len,
        },
    );
}
