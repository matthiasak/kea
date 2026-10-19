//! `TabDrag`, `SplitDropZone` and `SplitDropPreview` (TabDrag.swift,
//! SplitView.swift 167-201): a tab carried along the strip or the column
//! asks what is under the hand. Over a page's edge band — a quarter of its
//! width, no less than 120 — and once the hand has come to rest there, the
//! stage shows the pair it would make; let go, the two are paired. A
//! pair's half carried onto another tab leaves its pair for that place.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");

pub const band: f32 = 120;
pub const band_share: f32 = 0.24;
/// How far out of the band the hand goes before a shown split lets go.
pub const slack: f32 = 20;
/// The hand at rest: moved less than `settle` in `still` seconds.
pub const settle: f32 = 6;
pub const still: f64 = 0.09;

pub const Preview = struct { target: u64, on_left: bool, source: u64 };

/// A place a carried tab may be let go of (`SplitDropZone.Marker`), in
/// window points: a page of the stage, a tab of the row (`tab` 0: the
/// strip itself).
pub const Marker = struct { tab: u64, rect: ui.Rect };

const Mark = struct { p: ui.Point, at: f64 };

pub const State = struct {
    preview: ?Preview = null,
    /// The tab under the hand, and the half of a pair it was picked up by.
    gesture: u64 = 0,
    source: u64 = 0,
    trail: [32]Mark = undefined,
    trail_n: usize = 0,
    /// The pages on the stage last frame.
    pages: [2]Marker = undefined,
    page_n: usize = 0,
    /// The row's places: last frame's, read; this frame's, being drawn.
    marks: std.ArrayList(Marker) = .empty,
    next: std.ArrayList(Marker) = .empty,
    /// A drop's work, done at the start of the next frame, never under
    /// the loop drawing the row.
    pending: ?Pending = null,
    /// The tab whose carrying Esc called off (`TabDrag.cancelledID`).
    cancelled: u64 = 0,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.marks.deinit(gpa);
        s.next.deinit(gpa);
    }
};

const Pending = union(enum) {
    pair: Preview,
    strip: Between,
    /// An open tab brought into a pair's empty page (`source` into `before`).
    fill: Between,
};

const Between = struct { source: u64, before: u64 };

pub const Drop = union(enum) {
    /// Not Split View's: the row's own drag decides.
    none,
    /// Paired, or out of its pair into the row.
    taken,
    /// Over nothing that takes it: the window's own outside test decides.
    outside: *Tab,
    /// Called off with Esc: the tab goes back where it was picked up.
    cancelled,
};

/// Each frame, before the row is drawn: last frame's places become the
/// ones read, and what was let go is done.
pub fn beginFrame(b: *Browser) void {
    const d = &b.stage.drop;
    std.mem.swap(std.ArrayList(Marker), &d.marks, &d.next);
    d.next.clearRetainingCapacity();
    const work = d.pending orelse return;
    d.pending = null;
    switch (work) {
        .pair => |p| if (b.tabById(p.source)) |s| if (b.tabById(p.target)) |t| b.pair(s, t, p.on_left),
        .strip => |s| if (b.tabById(s.source)) |t| b.dropTabIntoStrip(t, if (s.before == 0) null else b.tabById(s.before)),
        .fill => |f| if (b.tabById(f.source)) |t| if (b.tabById(f.before)) |blank| b.fill(blank, t),
    }
}

/// A place in the row this frame (`SplitDropZone(kind: .strip)`).
pub fn mark(b: *Browser, tab: u64, rect: ?ui.Rect) void {
    const r = rect orelse return;
    if (!b.prefs.split_view) return;
    b.stage.drop.next.append(b.gpa, .{ .tab = tab, .rect = r }) catch {};
}

/// While `tab` is carried, its press at `origin`: true while the hand is
/// over a page's edge, where the row keeps still (`TabDrag.update`).
pub fn update(b: *Browser, c: *ui.Context, tab: *Tab, origin: ui.Point) bool {
    if (!b.prefs.split_view) return false;
    const d = &b.stage.drop;
    if (d.gesture != tab.id) {
        d.* = .{ .marks = d.marks, .next = d.next, .pages = d.pages, .page_n = d.page_n, .pending = d.pending };
        d.gesture = tab.id;
        d.source = sourceHalf(b, tab, origin);
    }
    if (d.cancelled == tab.id) return true;
    const now = c.time;
    var k: usize = 0;
    for (d.trail[0..d.trail_n]) |m| if (now - m.at <= 0.5) {
        d.trail[k] = m;
        k += 1;
    };
    if (k == d.trail.len) {
        std.mem.copyForwards(Mark, d.trail[0 .. k - 1], d.trail[1..k]);
        k -= 1;
    }
    d.trail[k] = .{ .p = c.input.mouse, .at = now };
    d.trail_n = k + 1;
    return look(b, c, c.input.mouse);
}

/// The hand let go of `tab` (`TabDrag.finish`): a split only where one
/// was shown.
pub fn finish(b: *Browser, c: *ui.Context, tab: *Tab) Drop {
    const d = &b.stage.drop;
    if (!b.prefs.split_view or d.gesture != tab.id) return .none;
    defer {
        d.gesture = 0;
        d.preview = null;
        d.trail_n = 0;
        d.cancelled = 0;
    }
    if (d.cancelled == tab.id) return .cancelled;
    const source = b.tabById(d.source) orelse tab;
    switch (match(b, source, c.input.mouse)) {
        .stage => |s| {
            const shown = d.preview orelse return .{ .outside = source };
            if (shown.target != s.target or shown.on_left != s.on_left) return .{ .outside = source };
            d.pending = .{ .pair = .{ .target = s.target, .on_left = s.on_left, .source = source.id } };
            b.redraw();
            return .taken;
        },
        .strip => |before| {
            d.pending = .{ .strip = .{ .source = source.id, .before = before } };
            b.redraw();
            return .taken;
        },
        .outside => return .{ .outside = source },
    }
}

/// Esc while a tab is carried (`TabDrag.cancel`, from the key monitor): no
/// pair, and the tab back where it was picked up. Whether one was carried.
pub fn cancel(b: *Browser) bool {
    const d = &b.stage.drop;
    if (!b.prefs.split_view or d.gesture == 0 or d.cancelled == d.gesture) return false;
    d.cancelled = d.gesture;
    d.preview = null;
    b.redraw();
    return true;
}

const Match = union(enum) {
    stage: struct { target: u64, on_left: bool },
    strip: u64,
    outside,
};

fn look(b: *Browser, c: *ui.Context, at: ui.Point) bool {
    const d = &b.stage.drop;
    const source = b.tabById(d.source) orelse return false;
    const m = match(b, source, at);
    const s = switch (m) {
        .stage => |s| s,
        else => {
            d.preview = null;
            return false;
        },
    };
    if (d.preview) |p| if (p.target == s.target and p.on_left == s.on_left) return true;
    if (!settled(d, c.time, at)) {
        // Looked at again once it may have stopped: a hand at rest sends nothing.
        c.frameIn(@floatCast(still));
        return true;
    }
    d.preview = .{ .target = s.target, .on_left = s.on_left, .source = source.id };
    return true;
}

fn settled(d: *const State, now: f64, at: ui.Point) bool {
    for (d.trail[0..d.trail_n]) |m| if (now - m.at <= still) {
        if (std.math.hypot(m.p.x - at.x, m.p.y - at.y) >= settle) return false;
    };
    return true;
}

fn match(b: *Browser, source: *Tab, at: ui.Point) Match {
    const d = &b.stage.drop;
    for (d.pages[0..d.page_n]) |page| {
        if (!page.rect.contains(at)) continue;
        const t = b.tabById(page.tab) orelse continue;
        if (!b.canSplit(source, t)) continue;
        const reach = @max(band, page.rect.w * band_share);
        // The side shown keeps a little more room before it lets go.
        const shown: ?bool = if (d.preview) |p| (if (p.target == t.id) p.on_left else null) else null;
        const left = reach + if (shown == true) slack else 0;
        const right = reach + if (shown == false) slack else 0;
        if (at.x <= page.rect.x + left) return .{ .stage = .{ .target = t.id, .on_left = true } };
        if (at.x >= page.rect.x + page.rect.w - right) return .{ .stage = .{ .target = t.id, .on_left = false } };
    }
    const pair = b.splitFor(source) orelse return .outside;
    var strip = false;
    for (d.marks.items) |m| {
        if (!m.rect.contains(at)) continue;
        if (m.tab == 0) {
            strip = true;
        } else if (!pair.contains(m.tab)) {
            return .{ .strip = m.tab };
        } else return .outside;
    }
    return if (strip) .{ .strip = 0 } else .outside;
}

/// A pair can be picked up by either half: the one under the press.
fn sourceHalf(b: *Browser, gesture: *Tab, origin: ui.Point) u64 {
    const pair = b.splitFor(gesture) orelse return gesture.id;
    for (b.stage.drop.marks.items) |m| if (m.tab != 0 and pair.contains(m.tab) and m.rect.contains(origin)) return m.tab;
    return gesture.id;
}

/// `SplitDropPreview`, over the whole stage: the two halves the pair
/// would have, the carried tab's lit. In and out on `Motion.quick`.
pub fn preview(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const d = &b.stage.drop;
    const id = std.hash.Wyhash.hash(0, "kea.split.preview");
    const v = motion.quickTo(c, id, 0, if (d.preview != null) 1 else 0);
    if (v <= 0) return;
    const pv = d.preview orelse return c.frameIn(0);
    const carried = if (b.tabById(pv.source)) |t| t.label() else "";
    const target = if (b.tabById(pv.target)) |t| t.label() else "Page";
    ui.row(c, .{ .absolute = true, .width = .fill, .height = .fill, .padding = .all(10), .gap = 2, .background = p.ground.alpha(0.12), .opacity = v });
    defer ui.end(c);
    half(c, p, if (pv.on_left) carried else target, pv.on_left);
    half(c, p, if (pv.on_left) target else carried, !pv.on_left);
}

fn half(c: *ui.Context, p: *const Palette, title: []const u8, proposed: bool) void {
    ui.column(c, .{ .grow = 1, .height = .fill, .background = if (proposed) p.ink.alpha(0.06) else p.ground.alpha(0.42), .padding = .all(6) });
    defer ui.end(c);
    ui.column(c, .{ .width = .fill, .height = .fill, .radius = 10, .border = if (proposed) p.ink.alpha(0.3) else p.ink.alpha(0.12), .align_items = .center, .justify = .center, .padding = .xy(14, 0) });
    defer ui.end(c);
    ui.text(c, if (title.len == 0) "New Tab" else title, .{ .size = 13, .weight = if (proposed) .medium else .regular, .color = p.ink.alpha(if (proposed) 0.78 else 0.48), .truncate = true });
}
