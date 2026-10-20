//! `HistoryPanel` (Recall.swift 42-246): everywhere you have been, by day,
//! newest first, narrowed by the Hunt field; a line goes there, or is
//! removed. Its foot counts the pages and opens the clearing cards, three
//! separate things worded so nobody has to guess which one signs them out
//! of their bank. A sheet (`chrome/sheet.zig`, `recalling`).
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const plate = @import("controls_plate.zig");
const controls = @import("controls.zig");
const mark = @import("mark.zig");
const sheet = @import("sheet.zig");
const when = @import("when.zig");
const address = @import("../model/address.zig");
const json = @import("../data/json.zig");
const motion = @import("../design/motion.zig");
const presence = @import("presence.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

const Row = struct { key: []const u8, url: []const u8, title: []const u8, address: []const u8, last: json.SwiftDate, clock: []const u8 = "" };
const Day = struct { name: []const u8, rows: []Row };
/// `Browser.recall`: the hunt (`recallHunt`), the mode, and the list as
/// drawn — worked out when the history or the search changes, not each
/// time the panel is drawn.
pub const State = struct {
    hunt: ui.TextBuffer = .{},
    /// `recallMode == .clearing`.
    clearing: bool = false,
    /// Opened straight into clearing (Clear Browsing Data…, ⇧⌘⌫).
    want_clearing: bool = false,
    /// Just appeared: the Hunt takes the keys.
    fresh: bool = false,
    arena: ?std.heap.ArenaAllocator = null,
    days: []Day = &.{},
    count: usize = 0,
    built_generation: u64 = 0,
    built_hunt: []const u8 = "",
    pub fn deinit(st: *State) void {
        st.hunt.deinit();
        if (st.arena) |*a| a.deinit();
        st.arena = null;
    }
};

/// ⌘Y: Show History… (`recalling.toggle()`).
pub fn toggle(b: *Browser) void {
    sheet.toggle(b, .recalling);
}

/// ⇧⌘⌫: Clear Browsing Data… (`recallMode = .clearing`).
pub fn showClearing(b: *Browser) void {
    if (b.recalling) {
        b.recall.clearing = true;
        return b.redraw();
    }
    b.recall.want_clearing = true;
    sheet.show(b, .recalling);
}

/// The sheet has just appeared (`onAppear`): its mode as asked, the Hunt focused.
pub fn opened(b: *Browser) void {
    b.recall.clearing = b.recall.want_clearing;
    b.recall.want_clearing = false;
    b.recall.fresh = true;
}

/// `refresh()`: the traces grouped by day, days newest first, each day's
/// newest first — `everything` is already newest first, so a day is a run.
fn refresh(b: *Browser) void {
    const st = &b.recall;
    if (st.arena == null) {
        st.arena = std.heap.ArenaAllocator.init(b.gpa);
    } else {
        _ = st.arena.?.reset(.retain_capacity);
    }
    const arena = st.arena.?.allocator();
    st.days = &.{};
    st.count = 0;
    st.built_generation = b.kea.history.generation;
    st.built_hunt = arena.dupe(u8, st.hunt.text()) catch "";
    const traces = b.kea.history.everything(arena, st.hunt.text(), std.math.maxInt(usize)) catch return;
    st.count = traces.len;
    var days: std.ArrayList(Day) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    var start: json.SwiftDate = std.math.inf(f64);
    for (traces) |t| {
        if (t.last < start) {
            if (rows.items.len > 0) days.items[days.items.len - 1].rows = rows.toOwnedSlice(arena) catch &.{};
            start = when.startOfDay(t.last);
            days.append(arena, .{ .name = when.day(arena, start), .rows = &.{} }) catch return;
        }
        const addr = address.withoutWWW(t.address);
        rows.append(arena, .{
            .key = t.key,
            .url = t.url,
            .title = if (t.title.len == 0) addr else t.title,
            .address = addr,
            .last = t.last,
        }) catch return;
    }
    if (rows.items.len > 0) days.items[days.items.len - 1].rows = rows.toOwnedSlice(arena) catch &.{};
    st.days = days.items;
}

/// What a line asked for, done once the list is drawn.
const Act = union(enum) { none, go: []const u8, forget: []const u8 };

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.recall;
    if (st.arena == null or st.built_generation != b.kea.history.generation or !std.mem.eql(u8, st.built_hunt, st.hunt.text())) refresh(b);
    var pl = plate.plate(c, p, "History", 600);
    if (pl.closed) sheet.close(b, .recalling);
    ui.column(c, .{ .width = .fill, .gap = 14 });
    _ = plate.huntFocus(c, p, &st.hunt, "Search everywhere you have been", st.fresh);
    st.fresh = false;
    var act: Act = .none;
    if (st.count == 0) {
        plate.cardBox(c, p);
        plate.nothing(c, p, if (st.hunt.text().len == 0) "Nothing yet — not a single footprint in the snow." else "Nothing matches. The kea checked under every rock.");
        ui.end(c);
    } else act = list(b, c, p);
    ui.end(c);
    pl.foot(c, p);
    foot(b, c, p);
    pl.end(c);
    switch (act) {
        .none => {},
        .go => |u| {
            sheet.close(b, .recalling);
            if (b.activeTab()) |t| t.go(u);
        },
        .forget => |k| {
            // Other Macs forget it too (`Sync.historyForgot`); first, while `k` lives.
            b.kea.sync.historyForgot(k);
            b.kea.history.forget(k);
        },
    }
}

/// The days, only the lines in view (and a screenful around) made: two
/// thousand of them, each with its icon, are too many to lay out a frame.
fn list(b: *Browser, c: *ui.Context, p: *const Palette) Act {
    const st = &b.recall;
    const max_h: f32 = 420;
    const i = c.open(.{ .scroll = true, .direction = .column, .width = .fill, .max_height = max_h, .scroll_bar = false, .padding = .{ .bottom = 2 } }, "history-list");
    defer c.end();
    const off = c.scroll.get(c.node(i).id) orelse 0;
    const lo = off - 200;
    const hi = off + max_h + 200;
    const cap_h = c.text.lineHeight(.{ .size = 11.5, .weight = .medium });
    const row_h = 18 + c.text.lineHeight(.{ .size = 13 }) + 2 + c.text.lineHeight(.{ .size = 11.5 });
    var act: Act = .none;
    var y: f32 = 0;
    var skipped_days: f32 = 0;
    for (st.days, 0..) |*day, d| {
        const head_h = (if (d == 0) @as(f32, 0) else 14) + cap_h + 6;
        const card_h = @as(f32, @floatFromInt(day.rows.len)) * (row_h + 1) - 1;
        const total_h = head_h + card_h;
        if (y + total_h < lo or y > hi) {
            skipped_days += total_h;
            y += total_h;
            continue;
        }
        if (skipped_days > 0) {
            _ = c.leaf(.{ .width = .fill, .height = px(skipped_days) }, .none, null);
            skipped_days = 0;
        }
        ui.key(c, c.print("day-{d}", .{d}));
        ui.column(c, .{ .width = .fill, .padding = .{ .top = if (d == 0) 0 else 14, .bottom = 6 } });
        plate.caption(c, p, day.name);
        ui.end(c);
        y += head_h;
        plate.cardBox(c, p);
        var skipped: f32 = 0;
        for (day.rows, 0..) |*row, n| {
            const top = y + @as(f32, @floatFromInt(n)) * (row_h + 1);
            const h = if (n == 0) row_h else row_h + 1;
            if (top + row_h < lo or top > hi) {
                skipped += h;
                continue;
            }
            if (skipped > 0) _ = c.leaf(.{ .width = .fill, .height = px(skipped) }, .none, null);
            skipped = 0;
            if (n > 0) plate.rule(c, p, 14);
            ui.key(c, row.key);
            const a = line(b, c, p, row, row_h);
            if (a != .none) act = a;
        }
        if (skipped > 0) _ = c.leaf(.{ .width = .fill, .height = px(skipped) }, .none, null);
        ui.end(c);
        y += card_h;
    }
    if (skipped_days > 0) _ = c.leaf(.{ .width = .fill, .height = px(skipped_days) }, .none, null);
    return act;
}

/// `Row`: a title, where it came from, and when — the three things you
/// scan for, in the order you scan them. Under the pointer, Remove.
fn line(b: *Browser, c: *ui.Context, p: *const Palette, row: *Row, h: f32) Act {
    if (row.clock.len == 0) row.clock = when.clock(b.recall.arena.?.allocator(), row.last);
    const i = c.open(.{ .direction = .row, .gap = 12, .width = .fill, .height = px(h), .padding = .xy(14, 9), .align_items = .center }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .row, row.title, row.address, false, true);
    const hover = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = p.hover.alpha(hover);
    const icon = b.kea.favicons.icon(row.url);
    const letter = mark.initial(c, row.address);
    mark.mark(c, p, if (icon) |ic| .{ .key = ic.key, .png = ic.png } else null, letter, 16, false);
    ui.column(c, .{ .gap = 2, .grow = 1, .min_width = 0 });
    ui.text(c, row.title, .{ .size = 13, .color = p.ink, .truncate = true });
    ui.text(c, row.address, .{ .size = 11.5, .color = p.muted, .truncate_middle = true });
    ui.end(c);
    _ = c.leaf(.{ .min_width = 8, .width = px(8) }, .none, null);
    ui.row(c, .{ .min_width = 56, .align_items = .center, .justify = .end });
    var forget = false;
    if (hover > 0.001) {
        ui.row(c, .{ .absolute = !it.hovered, .width = if (!it.hovered) .fill else .auto, .height = if (!it.hovered) .fill else .auto, .align_items = .center, .justify = .end, .opacity = hover });
        if (plate.quick(c, p, "Remove", p.red.alpha(0.75)).clicked and it.hovered) forget = true;
        ui.end(c);
    }
    if (1 - hover > 0.001) {
        ui.row(c, .{ .absolute = it.hovered, .width = if (it.hovered) .fill else .auto, .height = if (it.hovered) .fill else .auto, .align_items = .center, .justify = .end, .opacity = 1 - hover });
        ui.text(c, row.clock, .{ .size = 11.5, .color = p.muted, .tabular = true });
        ui.end(c);
    }
    ui.end(c);
    if (forget) return .{ .forget = row.key };
    return if (it.clicked) .{ .go = row.url } else .none;
}

/// The three clearing cards, and Back.
const foot_id: u64 = std.hash.Wyhash.hash(0, "kea.recall.foot");

/// The count and Clear…, or the clearing cards: one fades out as the other
/// fades in, where it stood, and the foot's height settles between them
/// (`.animation(Motion.settle, value: clearing)`, `.transition(.opacity)`).
fn foot(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.recall;
    const box = c.open(.{ .width = .fill, .clip = true }, "recall-foot");
    defer c.end();
    const now: u1 = @intFromBool(st.clearing);
    var ts: [2]?f32 = undefined;
    for (&ts, 0..) |*v, k| {
        const shown = k == now;
        // Already there when the panel first draws: no transition then.
        v.* = presence.presenceFrom(c, foot_id +% k, if (shown) 1 else 0, shown, motion.settle, null);
    }
    var h: f32 = 0;
    var known = true;
    // The one leaving, over the one in the flow, at the top.
    for ([2]u1{ now ^ 1, now }) |k| {
        const v = @min(ts[k] orelse continue, 1);
        const i = c.open(.{ .width = .fill, .absolute = k != now, .opacity = v }, if (k == 0) "recall-count" else "recall-sweeps");
        if (k == 0) count(b, c, p) else sweeps(b, c, p);
        c.end();
        if (c.rects.get(c.node(i).id)) |r| h += r.h * v else known = false;
    }
    if (known and (ts[now ^ 1] != null or ts[now].? < 1)) c.node(box).style.height = px(h);
}

fn count(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.recall;
    ui.row(c, .{ .width = .fill, .align_items = .center });
    defer ui.end(c);
    ui.text(c, if (st.count == 1) "1 page" else c.print("{d} pages", .{st.count}), .{ .size = 12, .color = p.muted });
    ui.spacer(c);
    if (controls.pill(c, p, "Clear…", .{}).clicked) st.clearing = true;
}

fn sweeps(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.recall;
    ui.column(c, .{ .width = .fill, .gap = 10 });
    defer ui.end(c);
    plate.cardBox(c, p);
    plate.line(c, p, "History", "Everywhere you have been");
    if (controls.pill(c, p, "Clear", .{}).clicked) {
        b.clearHistory();
        st.clearing = false;
    }
    ui.end(c);
    plate.rule(c, p, 14);
    plate.line(c, p, "Cookies and sign-ins", "Signs you out of every site");
    if (controls.pill(c, p, "Sign out of everything", .{}).clicked) b.clearSites();
    ui.end(c);
    plate.rule(c, p, 14);
    plate.line(c, p, "Cache", "Only what was fetched to draw pages");
    if (controls.pill(c, p, "Clear", .{}).clicked) b.clearCache();
    ui.end(c);
    ui.end(c);
    ui.row(c, .{ .width = .fill });
    ui.spacer(c);
    if (controls.pill(c, p, "Back", .{}).clicked) st.clearing = false;
    ui.end(c);
}
