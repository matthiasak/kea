//! Scenarios S1–S13 for the on-screen smoothness harness (`smooth.zig`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const main = @import("main.zig");
const Harness = main.Harness;
const web = @import("web.zig");
const smooth = @import("smooth.zig");
const ScenarioDef = smooth.ScenarioDef;
const SpanMark = smooth.SpanMark;

pub const all = [_]ScenarioDef{
    .{ .id = "S1", .name = "Sidebar on/off x4 (slide plus room)", .run = s1SidebarToggle },
    .{ .id = "S2", .name = "Open 5 tabs and close them (strip + column)", .run = s2TabsOpenClose },
    .{ .id = "S3", .name = "Drag a tab across the strip at 120 Hz", .run = s3DragTabStrip },
    .{ .id = "S4", .name = "Split enter, swap, leave", .run = s4SplitMoves },
    .{ .id = "S5", .name = "Split divider drag", .run = s5SplitDividerDrag },
    .{ .id = "S6", .name = "Omnibox open, type 6 chars, Esc", .run = s6OmniboxType },
    .{ .id = "S7", .name = "Ubi Chat open, expand, edge drag 300->700 pt", .run = s7UbiChat },
    .{ .id = "S8", .name = "Fold peek/unpeek", .run = s8FoldPeek },
    .{ .id = "S9", .name = "Live window resize, 16 ms steps", .report_only = true, .run = s9LiveResize },
    .{ .id = "S10", .name = "Scroll history (2000), bookmarks (2000), chat (200)", .run = s10ScrollLarge },
    .{ .id = "S11", .name = "Mock-stream a 4 KB answer at 30 chunks/s", .run = s11MockStream },
    .{ .id = "S12", .name = "Loading tab with a ring (slow loopback reply)", .run = s12LoadingRing },
    .{ .id = "S13", .name = "Idle blank tab for 3 s", .run = s13IdleBlank },
};

fn s1SidebarToggle(_: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    b.prefs.set("sidebar", false);
    b.redraw();
    smooth.waitUntilSettled(s, 0.5);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const m0 = fl.mark();
        for (0..4) |_| {
            b.prefs.set("sidebar", !b.prefs.sidebar);
            b.redraw();
            // Let slide + room give-up (0.42 s) play out.
            smooth.waitLoop(0.48);
        }
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s2TabsOpenClose(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    _ = try web.open(h, b, "kea-test://site/page?title=Base");
    smooth.waitUntilSettled(s, 0.4);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const m0 = fl.mark();
        for ([_]bool{ false, true }) |sidebar_mode| {
            b.prefs.set("sidebar", sidebar_mode);
            b.redraw();
            smooth.waitUntilSettled(s, 0.45);
            for (0..5) |i| {
                var buf: [64]u8 = undefined;
                const url = try std.fmt.bufPrint(&buf, "kea-test://site/page?title=Tab{d}", .{i + 1});
                _ = b.open(url, .{ .foreground = true });
                b.redraw();
                smooth.waitLoop(0.12);
            }
            while (b.tabs.items.len > 1) {
                b.close(b.tabs.items[b.tabs.items.len - 1]);
                b.redraw();
                smooth.waitLoop(0.12);
            }
            smooth.waitUntilSettled(s, 0.35);
        }
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s3DragTabStrip(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    b.prefs.set("sidebar", false);
    for (0..5) |i| {
        var buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&buf, "kea-test://site/page?title=Drag{d}", .{i + 1});
        _ = try web.open(h, b, url);
    }
    if (b.tabs.items.len > 5) b.close(b.tabs.items[0]);
    b.select(b.tabs.items[0]);
    b.setEditing(false);
    b.redraw();
    smooth.waitUntilSettled(s, 0.8);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        try h.expect(b.strip.seen.items.len > 1, "strip has {d} seen pills", .{b.strip.seen.items.len});
        const first = b.strip.seen.items[0];
        const first_id = first.id;
        const r = s.ctx.rects.get(first.node) orelse return h.fail("no rect for first strip pill", .{});
        const x0: f64 = r.x + r.w * 0.5;
        const y0: f64 = r.y + r.h * 0.5;
        const x1: f64 = x0 + 520;
        const steps = 45;

        const m0 = fl.mark();
        smooth.mouseMovedTo(s, x0, y0);
        smooth.mouseDownAt(s, x0, y0);
        for (0..steps) |step| {
            const t = @as(f64, @floatFromInt(step + 1)) / @as(f64, steps);
            smooth.mouseDraggedTo(s, x0 + (x1 - x0) * t, y0);
            smooth.waitLoop(1.0 / 120.0);
        }
        try h.expect(b.strip.seen.items[0].id != first_id, "tab order did not change at right end of drag", .{});
        for (0..steps) |step| {
            const t = @as(f64, @floatFromInt(step + 1)) / @as(f64, steps);
            smooth.mouseDraggedTo(s, x1 - (x1 - x0) * t, y0);
            smooth.waitLoop(1.0 / 120.0);
        }
        smooth.mouseUpAt(s, x0, y0);
        smooth.waitUntilSettled(s, 0.8);
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s4SplitMoves(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    b.prefs.set("split_view", true);
    const left = try web.open(h, b, "kea-test://site/page?title=SplitLeft");
    const right = try web.open(h, b, "kea-test://site/page?title=SplitRight");
    b.select(left);
    b.redraw();
    smooth.waitUntilSettled(s, 0.4);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const m0 = fl.mark();
        b.pair(right, left, false);
        b.redraw();
        smooth.waitLoop(0.38);
        try h.expect(b.activeSplit() != null, "split did not enter", .{});
        b.swapSplit();
        b.redraw();
        smooth.waitLoop(0.38);
        b.detachSplit(right);
        b.redraw();
        smooth.waitLoop(0.38);
        try h.expect(b.activeSplit() == null, "split did not detach", .{});
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s5SplitDividerDrag(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    b.prefs.set("split_view", true);
    const left = try web.open(h, b, "kea-test://site/page?title=DivLeft");
    const right = try web.open(h, b, "kea-test://site/page?title=DivRight");
    b.pair(right, left, false);
    b.redraw();
    smooth.waitLoop(0.4);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        if (b.activeSplit()) |sp| b.setSplitFraction(sp.id, 0.5);
        b.redraw();
        smooth.waitUntilSettled(s, 0.45);
        const r = smooth.a11yRect(s, .splitter, "Divider between the pages") orelse
            return h.fail("no splitter a11y item for pane divider", .{});
        const cx: f64 = r.x + r.w * 0.5;
        const cy: f64 = r.y + r.h * 0.5;

        const m0 = fl.mark();
        smooth.mouseMovedTo(s, cx, cy);
        smooth.mouseDownAt(s, cx, cy);
        const steps = 40;
        var max_dev: f64 = 0;
        for (0..steps) |step| {
            const phase = @as(f64, @floatFromInt(step + 1)) / @as(f64, steps);
            const dx = @sin(phase * std.math.pi * 1.5) * 180.0;
            smooth.mouseDraggedTo(s, cx + dx, cy);
            if (b.stage.divider.live) |lv| max_dev = @max(max_dev, @abs(lv - 0.5));
            smooth.waitLoop(1.0 / 120.0);
        }
        const end_x = cx - 180.0;
        smooth.mouseUpAt(s, end_x, cy);
        const after_frac = if (b.activeSplit()) |sp| sp.fraction() else 0.5;
        try h.expect(max_dev > 0.05 and @abs(after_frac - 0.5) > 0.05, "divider fraction did not move (dev {d:.3}, final {d:.3})", .{ max_dev, after_frac });
        smooth.waitUntilSettled(s, 0.25);
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s6OmniboxType(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    _ = try web.open(h, b, "kea-test://site/page?title=OmniBase");
    smooth.seedHistory(b, 200);
    smooth.waitUntilSettled(s, 0.3);

    const chars = [_][]const u8{ "s", "e", "a", "r", "c", "h" };
    const codes = [_]u16{ 1, 14, 0, 15, 8, 4 };
    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const m0 = fl.mark();
        b.edit();
        b.redraw();
        smooth.waitLoop(0.18);
        for (chars, codes) |ch, code| {
            smooth.keyPress(s, ch, code, 0);
            smooth.waitLoop(0.035);
        }
        try h.expect(std.mem.startsWith(u8, b.omni.typed.items, "search"), "omnibox typed '{s}', want 'search'", .{b.omni.typed.items});
        b.dismiss();
        b.redraw();
        smooth.waitUntilSettled(s, 0.25);
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s7UbiChat(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    _ = try web.open(h, b, "kea-test://site/page?title=ChatPage");
    b.prefs.set("sidebar", false);
    b.prefs.set("chat_popped", false);
    b.redraw();
    smooth.waitUntilSettled(s, 0.3);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        b.closeAssistant();
        b.prefs.set("chat_width", 300);
        b.redraw();
        smooth.waitUntilSettled(s, 0.2);

        const m0 = fl.mark();
        _ = b.openChat();
        smooth.waitLoop(0.2);
        app.side_panels.toggleExpanded(b, .chat);
        smooth.waitLoop(0.36);
        app.side_panels.toggleExpanded(b, .chat);
        smooth.waitLoop(0.36);
        s.frame();

        const r = smooth.a11yRect(s, .splitter, "Column width") orelse
            return h.fail("no splitter a11y item for chat edge handle", .{});
        const ex: f64 = r.x + r.w * 0.5;
        const ey: f64 = r.y + r.h * 0.5;
        const on_left = app.side_panels.panelOnLeft(b, .chat);
        smooth.mouseMovedTo(s, ex, ey);
        smooth.mouseDownAt(s, ex, ey);
        const steps = 40;
        for (0..steps) |step| {
            const frac = @as(f64, @floatFromInt(step + 1)) / @as(f64, steps);
            const delta = 400.0 * frac;
            const nx = if (on_left) ex + delta else ex - delta;
            smooth.mouseDraggedTo(s, nx, ey);
            smooth.waitLoop(1.0 / 120.0);
        }
        smooth.mouseUpAt(s, if (on_left) ex + 400 else ex - 400, ey);
        try h.expect(@abs(b.prefs.chat_width - 700) <= 15, "chat_width is {d:.1} after 300->700 drag", .{b.prefs.chat_width});
        b.closeAssistant();
        smooth.waitUntilSettled(s, 0.2);
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s8FoldPeek(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    _ = try web.open(h, b, "kea-test://site/page?title=FoldPage");
    b.prefs.set("sidebar", true);
    b.prefs.set("side_hides", false);
    s.frame();
    b.folded = true;
    b.peeking = false;
    b.redraw();
    smooth.waitUntilSettled(s, 0.4);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const m0 = fl.mark();
        app.fold.followAt(b, .{
            .point = .{ .x = 2, .y = s.size.h * 0.5 },
            .size = s.size,
            .on_window = true,
        });
        try h.expect(b.peeking, "fold did not peek on edge hover", .{});
        smooth.waitLoop(0.38);
        app.fold.followAt(b, .{
            .point = .{ .x = s.size.w * 0.6, .y = s.size.h * 0.5 },
            .size = s.size,
            .on_window = true,
        });
        // Wait past the 0.3 s grace + glide out.
        smooth.waitLoop(0.68);
        try h.expect(!b.peeking, "fold did not unpeek after grace", .{});
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s9LiveResize(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    _ = try web.open(h, b, "kea-test://site/page?title=ResizePage");
    b.prefs.set("sidebar", true);
    b.folded = false;
    b.redraw();
    smooth.waitUntilSettled(s, 0.3);

    const w = b.window.?;
    const base_w = s.size.w;
    const base_h = s.size.h;
    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const m0 = fl.mark();
        objc.msg(void, s.nsview, "viewWillStartLiveResize", .{});
        const steps = 24;
        for (0..steps) |step| {
            const phase = @sin(@as(f64, @floatFromInt(step + 1)) / @as(f64, steps) * std.math.pi);
            w.setSize(base_w - 240.0 * phase, base_h - 140.0 * phase);
            smooth.waitLoop(0.016);
        }
        w.setSize(base_w, base_h);
        objc.msg(void, s.nsview, "viewDidEndLiveResize", .{});
        smooth.waitLoop(0.05);
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s10ScrollLarge(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    b.prefs.set("sidebar", false);
    smooth.seedHistory(b, 2000);
    try smooth.seedBookmarks(b, 2000);
    try smooth.seedChatTurns(b, 200);
    b.prefs.set("bookmarks_sidebar", true);
    b.prefs.set("marks_popped", false);
    b.prefs.set("chat_popped", false);
    _ = b.openChat();
    app.sheet.show(b, .recalling);
    b.redraw();
    smooth.waitUntilSettled(s, 0.45);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const m0 = fl.mark();
        // 1. Scroll History panel (sheet is topmost scroll box)
        if (!b.recalling) {
            app.sheet.show(b, .recalling);
            b.redraw();
            smooth.waitUntilSettled(s, 0.35);
        }
        s.frame();
        var sboxes: [8]smooth.ScrollBox = undefined;
        const list_with_sheet = smooth.scrollBoxes(s, &sboxes);
        try h.expect(list_with_sheet.len >= 3, "expected >= 3 scroll boxes with history sheet open, got {d}", .{list_with_sheet.len});
        const hist_box = list_with_sheet[list_with_sheet.len - 1];
        s.ctx.scroll.put(s.gpa, hist_box.id, 0) catch {};
        s.frame();
        for (0..20) |_| {
            smooth.scrollAt(s, hist_box.rect.x + hist_box.rect.w * 0.5, hist_box.rect.y + hist_box.rect.h * 0.5, -36);
            smooth.waitLoop(1.0 / 120.0);
        }
        const hist_off = s.ctx.scroll.get(hist_box.id) orelse 0;
        try h.expect(hist_off > 0, "history scroll offset stayed {d:.1}", .{hist_off});
        for (0..20) |_| {
            smooth.scrollAt(s, hist_box.rect.x + hist_box.rect.w * 0.5, hist_box.rect.y + hist_box.rect.h * 0.5, 36);
            smooth.waitLoop(1.0 / 120.0);
        }
        app.sheet.close(b, .recalling);
        b.redraw();
        smooth.waitUntilSettled(s, 0.35);

        // 2. Scroll Bookmarks sidebar and 3. Scroll Chat transcript (200 turns)
        s.frame();
        const side_boxes = smooth.scrollBoxes(s, &sboxes);
        try h.expect(side_boxes.len >= 2, "expected >= 2 scroll boxes for bookmarks + chat, got {d}", .{side_boxes.len});
        const marks_first = side_boxes[0].rect.w <= side_boxes[1].rect.w;
        const marks_box = if (marks_first) side_boxes[0] else side_boxes[1];
        const chat_box = if (marks_first) side_boxes[1] else side_boxes[0];

        s.ctx.scroll.put(s.gpa, marks_box.id, 0) catch {};
        s.frame();
        for (0..20) |_| {
            smooth.scrollAt(s, marks_box.rect.x + marks_box.rect.w * 0.5, marks_box.rect.y + marks_box.rect.h * 0.5, -36);
            smooth.waitLoop(1.0 / 120.0);
        }
        const marks_off = s.ctx.scroll.get(marks_box.id) orelse 0;
        try h.expect(marks_off > 0, "bookmarks scroll offset stayed {d:.1}", .{marks_off});
        for (0..20) |_| {
            smooth.scrollAt(s, marks_box.rect.x + marks_box.rect.w * 0.5, marks_box.rect.y + marks_box.rect.h * 0.5, 36);
            smooth.waitLoop(1.0 / 120.0);
        }

        // Chat starts pinned to bottom; scroll up then back down.
        const chat_before = s.ctx.scroll.get(chat_box.id) orelse 0;
        for (0..20) |_| {
            smooth.scrollAt(s, chat_box.rect.x + chat_box.rect.w * 0.5, chat_box.rect.y + chat_box.rect.h * 0.5, 48);
            smooth.waitLoop(1.0 / 120.0);
        }
        const chat_mid = s.ctx.scroll.get(chat_box.id) orelse 0;
        try h.expect(@abs(chat_mid - chat_before) > 10, "chat scroll offset did not move ({d:.1} -> {d:.1})", .{ chat_before, chat_mid });
        for (0..20) |_| {
            smooth.scrollAt(s, chat_box.rect.x + chat_box.rect.w * 0.5, chat_box.rect.y + chat_box.rect.h * 0.5, -48);
            smooth.waitLoop(1.0 / 120.0);
        }
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

const StreamStub = struct {
    sink: ?app.ai_client.Sink = null,
    stopped: bool = false,
};
var stream_stub: StreamStub = .{};

fn stubStream(_: ?*anyopaque, _: *app.ai_core.Ai, q: app.ai_client.Ask, sink: app.ai_client.Sink) ?app.ai_client.Handle {
    if (std.mem.startsWith(u8, q.system, "Name this chat")) {
        sink.piece(sink.ctx, "Streamed");
        sink.done(sink.ctx, null);
        return null;
    }
    stream_stub = .{ .sink = sink, .stopped = false };
    return .{ .ctx = &stream_stub, .stop = stubStop };
}

fn stubStop(_: *anyopaque) void {
    stream_stub.stopped = true;
    stream_stub.sink = null;
}

fn s11MockStream(h: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    const m = b.kea.ai;
    m.client = .{ .stream = stubStream };
    m.prefs.set("ai", true);
    m.prefs.set("ai_provider", "ollama");
    m.prefs.setAIModel("m", "ollama");

    var url_buf: [128]u8 = undefined;
    _ = try web.open(h, b, try std.fmt.bufPrint(&url_buf, "{s}/words/kea-stream-test", .{h.http}));
    _ = b.openChat();
    smooth.waitUntilSettled(s, 0.3);

    // 32 chunks * 128 bytes = 4096 bytes at 30 chunks/s (~1.07 s per run).
    const chunk = "### Smoothness Section\n- **Bullet point:** inline `code` and a [link](https://example.com) with some words to wrap nicely.\n\n";
    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const a = b.assisting orelse b.openChat().?;
        a.new(false);
        s.frame();

        const m0 = fl.mark();
        b.summarizePage();
        const deadline = ui.clock.now() + 2.0;
        while (stream_stub.sink == null and ui.clock.now() < deadline) {
            smooth.waitLoop(0.01);
        }
        try h.expect(stream_stub.sink != null, "summarizePage did not start stream", .{});
        if (stream_stub.sink) |sk| {
            for (0..32) |_| {
                if (stream_stub.stopped) break;
                sk.piece(sk.ctx, chunk);
                smooth.waitLoop(1.0 / 30.0);
            }
            if (!stream_stub.stopped) {
                stream_stub.sink = null;
                sk.done(sk.ctx, null);
            }
        }
        smooth.waitLoop(0.05);
        spans[iter] = .{ .start = m0, .end = fl.mark() };
    }
    return spans;
}

fn s12LoadingRing(_: *Harness, b: *app.Browser, s: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    b.prefs.set("sidebar", true);
    b.redraw();
    smooth.waitUntilSettled(s, 0.35);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const tab = b.open("kea-test://site/slow", .{ .foreground = true });
        b.redraw();
        smooth.waitLoop(0.1);

        const t0 = ui.clock.now();
        const m0 = fl.mark();
        const pool = objc.Pool.push();
        nanoui.runFor(1.0);
        pool.pop();
        const m1 = fl.mark();
        const elapsed = @max(0.001, ui.clock.now() - t0);
        const fps = @as(f64, @floatFromInt(m1 - m0)) / elapsed;
        b.close(tab);
        b.redraw();
        smooth.waitUntilSettled(s, 0.3);
        spans[iter] = .{ .start = m0, .end = m1, .extra = .{ .fps = fps } };
    }
    return spans;
}

fn s13IdleBlank(_: *Harness, b: *app.Browser, _: *ui.Surface, fl: *ui.FrameLog) ![3]SpanMark {
    while (b.tabs.items.len > 1) b.close(b.tabs.items[b.tabs.items.len - 1]);
    b.prefs.set("sidebar", false);
    b.redraw();
    smooth.waitLoop(0.8);

    var spans: [3]SpanMark = undefined;
    for (0..3) |iter| {
        const m0 = fl.mark();
        const a0 = @atomicLoad(usize, &main.allocations, .monotonic);
        const cpu0 = smooth.cpuSeconds();
        const t0 = ui.clock.now();
        const pool = objc.Pool.push();
        nanoui.runFor(3.0);
        pool.pop();
        const spent = @max(0.001, ui.clock.now() - t0);
        const cpu = smooth.cpuSeconds() - cpu0;
        const allocs = @atomicLoad(usize, &main.allocations, .monotonic) - a0;
        const m1 = fl.mark();
        const frames = m1 - m0;
        spans[iter] = .{
            .start = m0,
            .end = m1,
            .extra = .{
                .fps = @as(f64, @floatFromInt(frames)) / spent,
                .cpu_pct = (cpu / spent) * 100.0,
                .allocs = allocs,
            },
        };
    }
    return spans;
}
