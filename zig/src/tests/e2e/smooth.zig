//! On-screen smoothness harness (`zig build smooth` / `keazig-e2e --onscreen`).
//! Places the window on the highest-refresh screen with `orderFrontRegardless`
//! (never taking focus), drives input directly into `s.nsview`, runs S1–S13
//! 3 times each, prints and writes `$TMPDIR/keazig-smooth/report.md`, and
//! checks the Verification § 3 gates.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const main = @import("main.zig");
const Harness = main.Harness;
const scenarios = @import("smooth_scenarios.zig");

extern "c" fn CGEventCreateScrollWheelEvent2(
    source: ?*anyopaque,
    units: u32,
    wheel_count: u32,
    wheel1: i32,
    wheel2: i32,
    wheel3: i32,
) ?*anyopaque;
extern "c" fn CGEventSetLocation(event: *anyopaque, location: objc.CGPoint) void;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" fn NSTemporaryDirectory() objc.Object;

pub const ExtraMetrics = struct {
    fps: f64 = 0,
    cpu_pct: f64 = 0,
    allocs: usize = 0,
};

pub const ScenarioDef = struct {
    id: []const u8,
    name: []const u8,
    report_only: bool = false,
    run: *const fn (*Harness, *app.Browser, *ui.Surface, *ui.FrameLog) anyerror![3]SpanMark,
};

pub const SpanMark = struct {
    start: usize,
    end: usize,
    extra: ExtraMetrics = .{},
};

pub const ScenarioReport = struct {
    id: []const u8,
    name: []const u8,
    report_only: bool,
    summary: ui.frame_log.Summary,
    extra: ExtraMetrics,
    passed: bool,
    fail_reason: [160]u8 = @splat(0),
    fail_len: usize = 0,
};

pub fn run(
    init: std.process.Init,
    gpa: std.mem.Allocator,
    _: *nanoui.App,
    handler: objc.Object,
    http: []const u8,
) !bool {
    const baseline = init.environ_map.get("KEAZIG_SMOOTH_BASELINE") != null;
    const only = init.environ_map.get("KEAZIG_SMOOTH");
    const env_tmp = init.environ_map.get("TMPDIR");

    var reports: [scenarios.all.len]ScenarioReport = undefined;
    var report_count: usize = 0;
    var all_passed = true;

    for (scenarios.all) |sc| {
        if (only) |filter| if (!std.mem.eql(u8, sc.id, filter) and std.mem.indexOf(u8, sc.name, filter) == null) continue;
        const pool = objc.Pool.push();
        defer pool.pop();

        var h: Harness = .{
            .gpa = gpa,
            .temp = try app.Temp.init(gpa),
            .handler = handler,
            .http = http,
        };
        defer {
            h.quit();
            nanoui.runFor(0.02);
            h.temp.deinit(gpa);
        }

        const start_res = h.startOnscreen();
        if (start_res) |b| {
            const s = b.window.?.surface.?;
            const fl = &s.frame_log.?;
            waitLoop(0.15);

            const spans_res = sc.run(&h, b, s, fl);
            s.renderer.waitIdle();

            if (spans_res) |spans| {
                var combined: std.ArrayList(ui.frame_log.Record) = .empty;
                defer combined.deinit(gpa);
                var extra: ExtraMetrics = .{};
                for (spans, 0..) |sp, i| {
                    const slice = fl.span(sp.start, sp.end);
                    if (slice.len > 0) {
                        const start_len = combined.items.len;
                        try combined.appendSlice(gpa, slice);
                        // First frame of each span is cold; zero interval_ms on span boundaries.
                        if (i > 0) combined.items[start_len].interval_ms = 0;
                    }
                    extra.fps += sp.extra.fps / 3.0;
                    extra.cpu_pct += sp.extra.cpu_pct / 3.0;
                    extra.allocs += sp.extra.allocs;
                }

                var summary = ui.FrameLog.summary(combined.items);
                computeMultiSpanSteady(spans, fl, &summary);

                var rep: ScenarioReport = .{
                    .id = sc.id,
                    .name = sc.name,
                    .report_only = sc.report_only,
                    .summary = summary,
                    .extra = extra,
                    .passed = true,
                };
                checkGates(&rep);
                if (!rep.passed and !rep.report_only) all_passed = false;
                reports[report_count] = rep;
            } else |err| {
                reports[report_count] = failReport(&h, sc, err);
                all_passed = false;
            }
        } else |err| {
            reports[report_count] = failReport(&h, sc, err);
            all_passed = false;
        }
        report_count += 1;
    }

    try writeAndPrintReport(gpa, env_tmp, reports[0..report_count]);
    return if (baseline) true else all_passed;
}

fn failReport(h: *Harness, sc: ScenarioDef, err: anyerror) ScenarioReport {
    var rep: ScenarioReport = .{
        .id = sc.id,
        .name = sc.name,
        .report_only = sc.report_only,
        .summary = .{},
        .extra = .{},
        .passed = false,
    };
    const why = if (err == error.CaseFailed) h.reason else @errorName(err);
    var fbs = std.Io.Writer.fixed(&rep.fail_reason);
    fbs.print("FAIL: {s}", .{why}) catch {};
    rep.fail_len = fbs.end;
    std.debug.print("FAIL {s} ({s}): {s}\n", .{ sc.id, sc.name, why });
    return rep;
}

fn computeMultiSpanSteady(spans: [3]SpanMark, fl: *ui.FrameLog, summary: *ui.frame_log.Summary) void {
    var cpu_steady: [8192]f64 = undefined;
    var n: usize = 0;
    for (spans) |sp| {
        const slice = fl.span(sp.start, sp.end);
        const start_idx: usize = if (slice.len > 1) 1 else 0;
        for (slice[start_idx..]) |r| {
            if (n < cpu_steady.len) {
                cpu_steady[n] = r.cpuMs();
                n += 1;
            }
        }
    }
    if (n == 0) return;
    std.mem.sort(f64, cpu_steady[0..n], {}, comptime std.sort.asc(f64));
    const idx_f = 0.99 * @as(f64, @floatFromInt(n - 1));
    const lo: usize = @intFromFloat(@floor(idx_f));
    const hi: usize = @min(n - 1, lo + 1);
    const frac = idx_f - @as(f64, @floatFromInt(lo));
    summary.cpu.steady_p99 = cpu_steady[lo] * (1.0 - frac) + cpu_steady[hi] * frac;
    summary.cpu.steady_max = cpu_steady[n - 1];
}

fn checkGates(rep: *ScenarioReport) void {
    if (rep.report_only) return;
    const s = rep.summary;
    var fbs = std.Io.Writer.fixed(&rep.fail_reason);
    var first = true;
    const sep = struct {
        fn add(w: *std.Io.Writer, is_first: *bool) void {
            if (!is_first.*) w.writeAll("; ") catch {};
            is_first.* = false;
        }
    }.add;

    if (s.frames == 0) {
        rep.passed = false;
        sep(&fbs, &first);
        fbs.writeAll("0 frames drawn") catch {};
    }
    if (s.missed_share > 0.02) {
        rep.passed = false;
        sep(&fbs, &first);
        fbs.print("missed {d:.1}% > 2%", .{s.missed_share * 100}) catch {};
    }
    if (s.cpu.steady_p99 > 6.0) {
        rep.passed = false;
        sep(&fbs, &first);
        fbs.print("cpu p99 {d:.2}ms > 6ms", .{s.cpu.steady_p99}) catch {};
    }
    if (s.cpu.steady_max > 16.0) {
        rep.passed = false;
        sep(&fbs, &first);
        fbs.print("cpu max {d:.2}ms > 16ms", .{s.cpu.steady_max}) catch {};
    }
    if (s.drawable_wait.p99 > 1.0) {
        rep.passed = false;
        sep(&fbs, &first);
        fbs.print("wait p99 {d:.2}ms > 1ms", .{s.drawable_wait.p99}) catch {};
    }
    if (std.mem.eql(u8, rep.id, "S12")) {
        if (rep.extra.fps > 61.0) {
            rep.passed = false;
            sep(&fbs, &first);
            fbs.print("fps {d:.1} > 61", .{rep.extra.fps}) catch {};
        }
    }
    if (std.mem.eql(u8, rep.id, "S13")) {
        if (rep.extra.fps > 31.0) {
            rep.passed = false;
            sep(&fbs, &first);
            fbs.print("fps {d:.1} > 31", .{rep.extra.fps}) catch {};
        }
        if (rep.extra.cpu_pct >= 2.0) {
            rep.passed = false;
            sep(&fbs, &first);
            fbs.print("cpu {d:.2}% >= 2%", .{rep.extra.cpu_pct}) catch {};
        }
        if (rep.extra.allocs != 0) {
            rep.passed = false;
            sep(&fbs, &first);
            fbs.print("allocs {d} != 0", .{rep.extra.allocs}) catch {};
        }
    }
    rep.fail_len = fbs.end;
}

fn writeAndPrintReport(gpa: std.mem.Allocator, env_tmp: ?[]const u8, reports: []const ScenarioReport) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &out);
    const w = &aw.writer;

    const screen_hz = fastestScreenHz();
    try w.print("# KeaZig On-Screen Smoothness Report ({d} Hz target)\n\n", .{screen_hz});
    try w.writeAll("| # | Scenario | Frames | Anim | Missed % | Int p50 | Int p90 | Int p99 | Int max | CPU p50 | CPU p99* | CPU max* | Wait p99 | GPU p50 | GPU p99 | Sync % | Gate |\n");
    try w.writeAll("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|\n");

    for (reports) |r| {
        const s = r.summary;
        const gate_str = if (r.report_only and r.passed)
            "REPORT"
        else if (r.passed)
            "PASS"
        else
            r.fail_reason[0..r.fail_len];

        try w.print(
            "| {s} | {s} | {d} | {d} | {d:.1}% | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.2} | {d:.0}% | {s} |\n",
            .{
                r.id,                   r.name,
                s.frames,               s.animating_frames,
                s.missed_share * 100.0, s.interval.p50,
                s.interval.p90,         s.interval.p99,
                s.interval.max,         s.cpu.p50,
                s.cpu.steady_p99,       s.cpu.steady_max,
                s.drawable_wait.p99,    s.gpu.p50,
                s.gpu.p99,              s.sync_share * 100.0,
                gate_str,
            },
        );
    }

    for (reports) |r| {
        if (std.mem.eql(u8, r.id, "S12") or std.mem.eql(u8, r.id, "S13")) {
            try w.print("\n- **{s} extra:** {d:.1} fps, {d:.2}% CPU, {d} steady allocations", .{
                r.id, r.extra.fps, r.extra.cpu_pct, r.extra.allocs,
            });
        }
    }
    try w.writeAll("\n");

    out = aw.toArrayList();
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.File.stdout().writeStreamingAll(io, out.items) catch {
        std.debug.print("{s}", .{out.items});
    };

    const pool = objc.Pool.push();
    defer pool.pop();
    const raw_tmp = env_tmp orelse objc.fromNSString(NSTemporaryDirectory());
    const tmp = std.mem.trimEnd(u8, raw_tmp, "/");
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/keazig-smooth", .{tmp});
    defer gpa.free(dir_path);
    const file_path = try std.fmt.allocPrint(gpa, "{s}/report.md", .{dir_path});
    defer gpa.free(file_path);

    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    _ = objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
        objc.nsString(dir_path), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
    });
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = out.items }) catch |err| {
        std.debug.print("failed to write {s}: {s}\n", .{ file_path, @errorName(err) });
    };
}

fn fastestScreenHz() objc.NSInteger {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const count = objc.msg(objc.NSUInteger, screens, "count", .{});
    var best: objc.NSInteger = 60;
    for (0..count) |i| {
        const scr = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (objc.msg(objc.BOOL, scr, "respondsToSelector:", .{objc.sel("maximumFramesPerSecond")})) {
            const fps = objc.msg(objc.NSInteger, scr, "maximumFramesPerSecond", .{});
            if (fps > best) best = fps;
        }
    }
    return best;
}

// MARK: Target lookup and direct NSView input helpers (never move the system cursor or steal focus)

pub const ScrollBox = struct {
    id: u64,
    rect: ui.Rect,
};

pub fn a11yRect(s: *ui.Surface, role: ui.A11yRole, label: []const u8) ?ui.Rect {
    for (s.ctx.a11y_items.items) |it| {
        if (it.role == role and std.mem.eql(u8, it.label, label)) {
            if (s.ctx.rects.get(it.id)) |r| return r;
        }
    }
    return null;
}

pub fn scrollBoxes(s: *ui.Surface, out: *[8]ScrollBox) []ScrollBox {
    var n: usize = 0;
    for (s.ctx.hits.items) |hit| {
        if (hit.scroll and n < out.len) {
            out[n] = .{ .id = hit.id, .rect = hit.rect };
            n += 1;
        }
    }
    return out[0..n];
}

pub fn waitLoop(seconds: f64) void {
    const deadline = ui.clock.now() + seconds;
    while (true) {
        const rem = deadline - ui.clock.now();
        if (rem <= 0) break;
        const pool = objc.Pool.push();
        nanoui.runFor(@min(rem, 0.004));
        pool.pop();
    }
}

pub fn waitUntilSettled(s: *ui.Surface, max_seconds: f64) void {
    s.frame();
    const deadline = ui.clock.now() + max_seconds;
    var quiet: usize = 0;
    while (ui.clock.now() < deadline) {
        const pool = objc.Pool.push();
        nanoui.runFor(1.0 / 120.0);
        pool.pop();
        if (!s.ctx.animating) {
            quiet += 1;
            if (quiet >= 3) break;
        } else {
            quiet = 0;
        }
    }
}

fn makeMouseEvent(view: objc.Object, kind: objc.NSUInteger, x: f64, y: f64, flags: objc.NSUInteger, clicks: objc.NSInteger) ?objc.Object {
    const window = objc.msg(?objc.Object, view, "window", .{}) orelse return null;
    const at = objc.msg(objc.CGPoint, view, "convertPoint:toView:", .{ objc.CGPoint{ .x = x, .y = y }, @as(?objc.Object, null) });
    const number = objc.msg(objc.NSInteger, window, "windowNumber", .{});
    return objc.msg(?objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
        kind, at, flags, ui.clock.now(), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), clicks, @as(f32, if (kind == 2 or kind == 5) 0 else 1),
    });
}

pub fn mouseDownAt(s: *ui.Surface, x: f64, y: f64) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ev = makeMouseEvent(s.nsview, 1, x, y, 0, 1) orelse return;
    objc.msg(void, s.nsview, "mouseDown:", .{ev});
}

pub fn mouseDraggedTo(s: *ui.Surface, x: f64, y: f64) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ev = makeMouseEvent(s.nsview, 6, x, y, 0, 1) orelse return;
    objc.msg(void, s.nsview, "mouseDragged:", .{ev});
}

pub fn mouseUpAt(s: *ui.Surface, x: f64, y: f64) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ev = makeMouseEvent(s.nsview, 2, x, y, 0, 1) orelse return;
    objc.msg(void, s.nsview, "mouseUp:", .{ev});
}

pub fn mouseMovedTo(s: *ui.Surface, x: f64, y: f64) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ev = makeMouseEvent(s.nsview, 5, x, y, 0, 0) orelse return;
    objc.msg(void, s.nsview, "mouseMoved:", .{ev});
}

pub fn clickAt(s: *ui.Surface, x: f64, y: f64) void {
    mouseDownAt(s, x, y);
    mouseUpAt(s, x, y);
}

fn primaryScreenHeight() f64 {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    if (objc.msg(objc.NSUInteger, screens, "count", .{}) == 0) return 900;
    const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    return objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
}

pub fn scrollAt(s: *ui.Surface, x: f64, y: f64, dy: i32) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const window = objc.msg(?objc.Object, s.nsview, "window", .{}) orelse return;
    const at = objc.msg(objc.CGPoint, s.nsview, "convertPoint:toView:", .{ objc.CGPoint{ .x = x, .y = y }, @as(?objc.Object, null) });
    const ph = primaryScreenHeight();
    const screen_pt = objc.msg(objc.CGPoint, window, "convertPointToScreen:", .{at});
    const candidates = [2]objc.CGPoint{
        .{ .x = at.x, .y = ph - at.y },
        .{ .x = screen_pt.x, .y = ph - screen_pt.y },
    };
    const cg = CGEventCreateScrollWheelEvent2(null, 0, 1, dy, 0, 0) orelse return;
    defer CFRelease(cg);
    for (candidates) |cand| {
        CGEventSetLocation(cg, cand);
        if (objc.msg(?objc.Object, objc.class("NSEvent"), "eventWithCGEvent:", .{@as(objc.Object, @ptrCast(cg))})) |ev| {
            const loc = objc.msg(objc.CGPoint, ev, "locationInWindow", .{});
            if (@abs(loc.x - at.x) < 1.0 and @abs(loc.y - at.y) < 1.0) {
                objc.msg(void, s.nsview, "scrollWheel:", .{ev});
                return;
            }
        }
    }
    CGEventSetLocation(cg, candidates[0]);
    if (objc.msg(?objc.Object, objc.class("NSEvent"), "eventWithCGEvent:", .{@as(objc.Object, @ptrCast(cg))})) |ev| {
        objc.msg(void, s.nsview, "scrollWheel:", .{ev});
    }
}

pub fn keyPress(s: *ui.Surface, chars: []const u8, code: u16, flags: objc.NSUInteger) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const window = objc.msg(?objc.Object, s.nsview, "window", .{}) orelse return;
    const number = objc.msg(objc.NSInteger, window, "windowNumber", .{});
    const ev = objc.msg(?objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
        @as(objc.NSUInteger, 10), objc.CGPoint{}, flags, ui.clock.now(), number, @as(?objc.Object, null),
        objc.nsString(chars), objc.nsString(chars), objc.NO, code,
    }) orelse return;
    objc.msg(void, s.nsview, "keyDown:", .{ev});
}

// MARK: Seed helpers for S6 and S10

pub fn cpuSeconds() f64 {
    const r = std.posix.getrusage(0);
    const sec = r.utime.sec + r.stime.sec;
    const usec = r.utime.usec + r.stime.usec;
    return @as(f64, @floatFromInt(sec)) + @as(f64, @floatFromInt(usec)) / 1e6;
}

pub fn seedHistory(b: *app.Browser, count: usize) void {
    const now = app.json.now();
    for (0..count) |i| {
        var u_buf: [128]u8 = undefined;
        var t_buf: [128]u8 = undefined;
        const u = std.fmt.bufPrint(&u_buf, "https://site-{d}.example.com/search/article-{d}", .{ i % 80, i }) catch continue;
        const t = std.fmt.bufPrint(&t_buf, "Search Browser Smoothness Article {d}", .{i}) catch continue;
        b.history.take(u, t, @intCast((i % 15) + 1), now - @as(f64, @floatFromInt(i * 1800)));
    }
    b.history.ensureIndexed();
}

pub fn seedBookmarks(b: *app.Browser, total: usize) !void {
    var w = b.bookmarks.begin() orelse return;
    const a = w.allocator();
    const folders_n = 20;
    const per_folder = total / folders_n;
    const roots = try a.alloc(app.bookmarks_data.Bookmark, folders_n);
    var idx: usize = 0;
    for (roots, 0..) |*folder, f_i| {
        const kids = try a.alloc(app.bookmarks_data.Bookmark, per_folder);
        for (kids, 0..) |*kid, k_i| {
            kid.* = .{
                .id = app.json.Uuid.random(),
                .title = try std.fmt.allocPrint(a, "Bookmark Item {d} in Folder {d}", .{ idx, f_i }),
                .url = try std.fmt.allocPrint(a, "https://marks.example.com/{d}/{d}", .{ f_i, k_i }),
            };
            idx += 1;
        }
        folder.* = .{ .id = app.json.Uuid.random(), .title = try std.fmt.allocPrint(a, "Folder {d}", .{f_i}), .children = kids };
    }
    w.roots = roots;
    b.bookmarks.set(&w);
    b.marks_ui.sidebar.clear();
    for (b.bookmarks.roots) |r| b.marks_ui.sidebar.put(b.gpa, r.id);
    b.marks_ui.sidebar_ready = true;
}

pub fn seedChatTurns(b: *app.Browser, count: usize) !void {
    const a = b.openChat() orelse return;
    const Chat = @TypeOf(a.chat);
    const Turn = std.meta.Child(@TypeOf(a.chat.turns));
    a.mutate(count, struct {
        fn build(n: usize, alloc: std.mem.Allocator, c: *Chat) error{OutOfMemory}!void {
            const list = try alloc.alloc(Turn, n);
            for (list, 0..) |*t, i| {
                t.* = .{
                    .id = app.json.Uuid.random(),
                    .question = try std.fmt.allocPrint(alloc, "Question {d}: How does frame pacing work at 120 Hz?", .{i + 1}),
                    .answer = try std.fmt.allocPrint(
                        alloc,
                        "### Turn {d}\n- Display link target timestamp\n- Sub-step remainder on springs\n- Async Metal drawable presentation with `presentDrawable:`\n",
                        .{i + 1},
                    ),
                    .done = true,
                    .place = "Local · m",
                };
            }
            c.turns = list;
        }
    }.build);
}
