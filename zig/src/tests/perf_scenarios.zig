//! The 11 performance-at-scale scenarios for `zig build perf` (P0.3).
const std = @import("std");
const app = @import("kea");
const seed = @import("ui/seed.zig");
const perf = @import("perf.zig");
const Harness = perf.Harness;
const Sample = perf.Sample;
const Metric = perf.Metric;
const steady_steps = perf.steady_steps;
const summarize = perf.summarize;

pub const runners = [_]*const fn (std.mem.Allocator) anyerror!Metric{
    s01Tabs,
    s02BookmarksSidebar,
    s03ManagerSearch,
    s04HistoryPanel,
    s05Chat,
    s06ChatList,
    s07Omnibox,
    s08Composer,
    s09Shortcuts,
    s10Downloads,
    s11Switcher,
    s12ColdIcons,
};

// Scenario 1: tabs hover-sweep and edge drag, in sidebar and strip (200 tabs).
fn s01Tabs(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedTabs(h.f.browser, 200);

    const cold = h.stepFrame();
    const t = &h.f.tester;
    for (0..20) |i| {
        t.ctx.input.mouse = .{ .x = 110, .y = 80.0 + @as(f32, @floatFromInt(i)) * 32.0 };
        t.ctx.updateHot();
        _ = h.stepFrame();
    }
    h.warmup(4);

    var samples: [steady_steps]Sample = undefined;
    // 0..20: sidebar hover sweep
    for (0..20) |i| {
        const y: f32 = 80.0 + @as(f32, @floatFromInt(i)) * 32.0;
        t.ctx.input.mouse = .{ .x = 110, .y = y };
        t.ctx.updateHot();
        samples[i] = h.stepFrame();
    }
    // 20..40: sidebar edge drag (232 -> 380 -> 232)
    const mid_y = t.size.h / 2;
    t.moveTo(h.f.kea.prefs.side_width - 4.5, mid_y);
    t.ctx.pointerDown();
    _ = h.stepFrame();
    for (0..20) |i| {
        const fi: f32 = @floatFromInt(i);
        const x: f32 = if (i < 10) 232.0 + (380.0 - 232.0) * (fi + 1.0) / 10.0 else 380.0 - (380.0 - 232.0) * (fi - 9.0) / 10.0;
        t.ctx.input.mouse = .{ .x = x, .y = mid_y };
        samples[20 + i] = h.stepFrameMut(i < 10);
    }
    t.ctx.pointerUp();
    _ = h.stepFrame();

    // Switch to strip mode, settle, then hover-sweep + drag across strip
    h.f.kea.prefs.set("sidebar", false);
    t.settle(1.0);
    h.warmup(3);
    for (0..20) |i| {
        const x: f32 = 140.0 + @as(f32, @floatFromInt(i)) * 52.0;
        t.ctx.input.mouse = .{ .x = x, .y = 19.0 };
        t.ctx.updateHot();
        samples[40 + i] = h.stepFrame();
    }
    t.moveTo(220.0, 19.0);
    t.ctx.pointerDown();
    _ = h.stepFrame();
    for (0..20) |i| {
        const x: f32 = 220.0 + @as(f32, @floatFromInt(i)) * 18.0;
        t.ctx.input.mouse = .{ .x = x, .y = 19.0 };
        samples[60 + i] = h.stepFrameMut(i < 5);
    }
    t.ctx.pointerUp();
    _ = h.stepFrame();

    return summarize("1. Tabs hover-sweep & edge drag (200 tabs)", false, cold, &samples);
}

// Scenario 2: bookmarks sidebar scroll and hover (2000 bookmarks).
fn s02BookmarksSidebar(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedFavicons(h.f.kea);
    seed.seedBookmarks(h.f.kea);
    h.f.kea.prefs.set("bookmarks_sidebar", true);
    h.f.browser.marks_ui.sidebar_ready = true;
    for (h.f.kea.bookmarks.roots) |f1| {
        h.f.browser.marks_ui.sidebar.put(gpa, f1.id);
        for (f1.kids()) |f2| if (f2.isFolder()) {
            h.f.browser.marks_ui.sidebar.put(gpa, f2.id);
            for (f2.kids()) |f3| if (f3.isFolder()) h.f.browser.marks_ui.sidebar.put(gpa, f3.id);
        };
    }

    const cold = h.stepFrame();
    const t = &h.f.tester;
    for (0..30) |_| {
        t.ctx.input.mouse = .{ .x = t.size.w - 110.0, .y = 300.0 };
        _ = t.ctx.applyScroll(-120.0);
        _ = h.stepFrame();
    }
    for (0..30) |_| _ = t.ctx.applyScroll(120.0);
    h.warmup(4);

    var samples: [steady_steps]Sample = undefined;
    const x = t.size.w - 110.0;
    for (0..40) |i| {
        t.ctx.input.mouse = .{ .x = x, .y = 300.0 };
        _ = t.ctx.applyScroll(if (i < 30) -120.0 else 120.0);
        t.ctx.updateHot();
        samples[i] = h.stepFrame();
    }
    for (0..40) |i| {
        const y: f32 = 80.0 + @as(f32, @floatFromInt(i % 20)) * 28.0;
        t.ctx.input.mouse = .{ .x = x, .y = y };
        t.ctx.updateHot();
        samples[40 + i] = h.stepFrame();
    }
    return summarize("2. Bookmarks sidebar scroll & hover (2000)", false, cold, &samples);
}

// Scenario 3: manager search: type 1–5 characters (2000 bookmarks).
fn s03ManagerSearch(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedFavicons(h.f.kea);
    seed.seedBookmarks(h.f.kea);
    app.sheet.show(h.f.browser, .bookmarking);

    const cold = h.stepFrame();
    const t = &h.f.tester;
    h.f.browser.marks_ui.picks.query.set("a");
    _ = h.stepFrame();
    t.moveTo(640.0, 260.0);
    h.f.tester.settle(0.6);
    h.warmup(3);

    const queries = [_][]const u8{ "a", "al", "alp", "alpi", "alpin" };
    var samples: [steady_steps]Sample = undefined;
    for (0..steady_steps) |i| {
        const q = queries[(i / 16) % queries.len];
        const mut = (i % 16 == 0);
        if (mut) {
            h.f.browser.marks_ui.picks.query.set(q);
            _ = h.stepFrameMut(true);
        }
        t.ctx.input.mouse = .{ .x = 640.0, .y = 260.0 + @as(f32, @floatFromInt(i % 12)) * 26.0 };
        t.ctx.updateHot();
        samples[i] = h.stepFrameMut(mut);
    }
    return summarize("3. Manager search type 1-5 chars (2000 bm)", false, cold, &samples);
}

// Scenario 4: history panel: open, scroll, type a hunt query (2000 visits).
fn s04HistoryPanel(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedFavicons(h.f.kea);
    seed.seedHistory(h.f.kea);
    app.sheet.show(h.f.browser, .recalling);

    const cold = h.stepFrame();
    const t = &h.f.tester;
    for (0..30) |_| {
        t.ctx.input.mouse = .{ .x = 720.0, .y = 360.0 };
        _ = t.ctx.applyScroll(-140.0);
        _ = h.stepFrame();
    }
    for (0..30) |_| _ = t.ctx.applyScroll(140.0);
    h.f.tester.settle(0.6);
    h.warmup(3);

    var samples: [steady_steps]Sample = undefined;
    for (0..40) |i| {
        t.ctx.input.mouse = .{ .x = 720.0, .y = 360.0 };
        _ = t.ctx.applyScroll(if (i < 30) -140.0 else 140.0);
        t.ctx.updateHot();
        samples[i] = h.stepFrame();
    }
    const hunts = [_][]const u8{ "a", "al", "alp", "alpi" };
    for (0..40) |i| {
        const mut = (i % 10 == 0);
        if (mut) h.f.browser.recall.hunt.set(hunts[(i / 10) % hunts.len]);
        t.ctx.input.mouse = .{ .x = 720.0, .y = 280.0 + @as(f32, @floatFromInt(i % 10)) * 28.0 };
        t.ctx.updateHot();
        samples[40 + i] = h.stepFrameMut(mut);
    }
    return summarize("4. History panel open, scroll & hunt (2000)", false, cold, &samples);
}

// Scenario 5: chat: scroll, hover, panel resize, streaming (200-turn chat).
fn s05Chat(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    const a = seed.seedChat200Turns(h.f.browser);

    const cold = h.stepFrame();
    const t = &h.f.tester;
    const chat_x = t.size.w - 190.0;
    for (0..15) |_| {
        t.ctx.input.mouse = .{ .x = chat_x, .y = 320.0 };
        _ = t.ctx.applyScroll(-180.0);
        _ = h.stepFrame();
    }
    for (0..15) |_| _ = t.ctx.applyScroll(180.0);
    h.f.tester.settle(0.6);
    h.warmup(4);

    var samples: [steady_steps]Sample = undefined;
    // 0..20: scroll transcript
    for (0..20) |i| {
        t.ctx.input.mouse = .{ .x = chat_x, .y = 320.0 };
        _ = t.ctx.applyScroll(if (i < 15) -180.0 else 180.0);
        t.ctx.updateHot();
        samples[i] = h.stepFrame();
    }
    // 20..40: hover sweep across transcript
    for (0..20) |i| {
        t.ctx.input.mouse = .{ .x = chat_x, .y = 120.0 + @as(f32, @floatFromInt(i)) * 24.0 };
        t.ctx.updateHot();
        samples[20 + i] = h.stepFrame();
    }
    // 40..60: panel resize (380 -> 540 -> 380)
    const mid_y = t.size.h / 2;
    const edge_start = t.size.w - h.f.kea.prefs.chat_width + 2.0;
    t.moveTo(edge_start, mid_y);
    t.ctx.pointerDown();
    _ = h.stepFrame();
    for (0..20) |i| {
        const fi: f32 = @floatFromInt(i);
        const w: f32 = if (i < 10) 380.0 + 16.0 * (fi + 1.0) else 540.0 - 16.0 * (fi - 9.0);
        t.ctx.input.mouse = .{ .x = t.size.w - w, .y = mid_y };
        samples[40 + i] = h.stepFrameMut(i < 10);
    }
    t.ctx.pointerUp();
    _ = h.stepFrame();

    // 60..80: streaming chunks into live turn
    a.live = .{
        .id = seed.uuid(0xC999, 0),
        .question = try gpa.dupe(u8, "Stream a live analysis of frame pacing."),
        .place = try gpa.dupe(u8, "on this Mac · Ollama · llama3.2"),
    };
    try a.live.?.answer.ensureTotalCapacity(gpa, 4096);
    for (0..20) |i| {
        a.live.?.answer.appendSliceAssumeCapacity("Streaming chunk of **markdown** with `inline_code` and bullet items.\n");
        samples[60 + i] = h.stepFrameMut(true);
    }
    return summarize("5. Chat scroll, hover, resize & stream (200)", true, cold, &samples);
}

// Scenario 6: chat list: hover and search (300 chats).
fn s06ChatList(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedChatsList(h.f.kea);
    const a = h.f.browser.openChat() orelse unreachable;
    a.listing = true;

    const cold = h.stepFrame();
    const t = &h.f.tester;
    const x = t.size.w - 180.0;
    h.f.browser.chat.search.set("a");
    _ = h.stepFrame();
    t.moveTo(x, 166.0);
    h.f.browser.chat.search.set("");
    h.f.tester.settle(0.6);
    h.warmup(3);

    var samples: [steady_steps]Sample = undefined;
    for (0..40) |i| {
        const y: f32 = 120.0 + @as(f32, @floatFromInt(i % 20)) * 26.0;
        t.ctx.input.mouse = .{ .x = x, .y = y };
        t.ctx.updateHot();
        samples[i] = h.stepFrame();
    }
    const queries = [_][]const u8{ "a", "al", "alp", "alpi" };
    for (0..40) |i| {
        const mut = (i % 10 == 0);
        if (mut) {
            h.f.browser.chat.search.set(queries[(i / 10) % queries.len]);
            _ = h.stepFrameMut(true);
        }
        t.ctx.input.mouse = .{ .x = x, .y = 140.0 + @as(f32, @floatFromInt(i % 15)) * 26.0 };
        t.ctx.updateHot();
        samples[40 + i] = h.stepFrameMut(mut);
    }
    return summarize("6. Chat list hover & search (300 chats)", false, cold, &samples);
}

// Scenario 7: omnibox typing (2000 visits, 2000 bookmarks, 200 tabs).
fn s07Omnibox(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedTabs(h.f.browser, 200);
    seed.seedBookmarks(h.f.kea);
    seed.seedHistory(h.f.kea);
    h.f.browser.setEditing(true);

    const cold = h.stepFrame();
    h.f.tester.settle(0.6);
    h.warmup(3);

    const typed = [_][]const u8{ "a", "al", "alp", "alpi", "alpin", "alpine" };
    var samples: [steady_steps]Sample = undefined;
    const t = &h.f.tester;
    for (0..steady_steps) |i| {
        const mut = (i % 14 == 0);
        if (mut) h.f.browser.setTyped(typed[(i / 14) % typed.len]);
        t.ctx.input.mouse = .{ .x = 720.0, .y = 320.0 + @as(f32, @floatFromInt(i % 8)) * 32.0 };
        t.ctx.updateHot();
        samples[i] = h.stepFrameMut(mut);
    }
    return summarize("7. Omnibox typing (2000 hist, 2000 bm, 200 tabs)", false, cold, &samples);
}

// Scenario 8: composer `@` and `history/` (200 tabs, 2000 visits).
fn s08Composer(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedTabs(h.f.browser, 200);
    seed.seedHistory(h.f.kea);
    const a = h.f.browser.openChat() orelse unreachable;
    a.setDraft("@al");

    const cold = h.stepFrame();
    h.f.tester.settle(0.6);
    h.warmup(3);

    const drafts = [_][]const u8{ "@a", "@al", "@alp", "history/a", "history/al", "history/alp" };
    var samples: [steady_steps]Sample = undefined;
    const t = &h.f.tester;
    for (0..steady_steps) |i| {
        const mut = (i % 14 == 0);
        if (mut) a.setDraft(drafts[(i / 14) % drafts.len]);
        t.ctx.input.mouse = .{ .x = t.size.w - 180.0, .y = t.size.h - 140.0 - @as(f32, @floatFromInt(i % 6)) * 22.0 };
        t.ctx.updateHot();
        samples[i] = h.stepFrameMut(mut);
    }
    return summarize("8. Composer @ and history/ (200 tabs, 2000 hist)", false, cold, &samples);
}

// Scenario 9: Settings › Shortcuts with a search.
fn s09Shortcuts(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    app.settings.open(h.f.browser, .shortcuts);

    const cold = h.stepFrame();
    h.f.tester.settle(0.6);
    h.warmup(3);

    const queries = [_][]const u8{ "", "t", "ta", "tab", "b", "bo", "boo", "book" };
    var samples: [steady_steps]Sample = undefined;
    const t = &h.f.tester;
    for (0..steady_steps) |i| {
        const mut = (i % 10 == 0);
        if (mut) h.f.browser.settings.shortcuts.hunt.set(queries[(i / 10) % queries.len]);
        t.ctx.input.mouse = .{ .x = 720.0, .y = 260.0 + @as(f32, @floatFromInt(i % 12)) * 28.0 };
        t.ctx.updateHot();
        samples[i] = h.stepFrameMut(mut);
    }
    return summarize("9. Settings > Shortcuts with search", false, cold, &samples);
}

// Scenario 10: downloads panel idle (50 kept + 3 active).
fn s10Downloads(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedDownloads(h.f.kea);
    app.sheet.show(h.f.browser, .hoarding);

    const cold = h.stepFrame();
    h.f.tester.settle(0.6);
    h.warmup(3);

    var samples: [steady_steps]Sample = undefined;
    for (0..steady_steps) |i| {
        samples[i] = h.stepFrame();
    }
    return summarize("10. Downloads panel idle (50 kept + 3 active)", false, cold, &samples);
}

// Scenario 11: ⌃Tab switcher with 120 candidates.
fn s11Switcher(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedTabs(h.f.browser, 120);
    const s = &h.f.browser.switcher;
    app.tab_switcher.switchTabs(h.f.browser, false);
    app.tab_switcher.show(h.f.browser);

    const cold = h.stepFrame();
    h.f.tester.settle(0.6);
    h.warmup(3);

    var samples: [steady_steps]Sample = undefined;
    const t = &h.f.tester;
    for (0..steady_steps) |i| {
        if (i % 8 == 0) {
            s.selected = s.candidates.items[(i / 8) % s.candidates.items.len];
        }
        t.ctx.input.mouse = .{ .x = 500.0 + @as(f32, @floatFromInt(i % 5)) * 120.0, .y = 360.0 };
        t.ctx.updateHot();
        samples[i] = h.stepFrame();
    }
    return summarize("11. Ctrl+Tab switcher (120 candidates)", false, cold, &samples);
}

// Scenario 12: cold icons (200 distinct hosts adopted via Favicons.adopt).
fn s12ColdIcons(gpa: std.mem.Allocator) !Metric {
    var h: Harness = undefined;
    try h.init(gpa, .{ .sidebar = true });
    defer h.deinit();
    seed.seedColdIcons200(h.f.browser);

    const cold = h.stepFrame();
    const t = &h.f.tester;
    // Drain budgeted icon decodes across the scroll range before steady-state sampling.
    for (0..36) |_| {
        t.ctx.input.mouse = .{ .x = 110.0, .y = 300.0 };
        _ = t.ctx.applyScroll(-120.0);
        _ = h.stepFrame();
    }
    for (0..36) |_| {
        t.ctx.input.mouse = .{ .x = 110.0, .y = 300.0 };
        _ = t.ctx.applyScroll(120.0);
        _ = h.stepFrame();
    }
    h.f.tester.settle(0.6);
    h.warmup(4);

    var samples: [steady_steps]Sample = undefined;
    for (0..40) |i| {
        const y: f32 = 80.0 + @as(f32, @floatFromInt(i % 20)) * 32.0;
        t.ctx.input.mouse = .{ .x = 110.0, .y = y };
        t.ctx.updateHot();
        samples[i] = h.stepFrame();
    }
    for (0..40) |i| {
        t.ctx.input.mouse = .{ .x = 110.0, .y = 300.0 };
        _ = t.ctx.applyScroll(if (i < 20) -120.0 else 120.0);
        t.ctx.updateHot();
        samples[40 + i] = h.stepFrame();
    }
    return summarize("12. Cold icons (200 distinct hosts)", false, cold, &samples);
}
