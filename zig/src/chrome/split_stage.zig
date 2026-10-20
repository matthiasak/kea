//! The stage (`SplitStage` and `PaneStage`, SplitView.swift and
//! PaneStage.swift): every page on screen, one or a pair's two, each a hole
//! the web view shows through — a card of its own with the tabs down the
//! side — the divider between two, the hairline round the page with the
//! keys, and over each page what is drawn there alone (`PaneLayers`).
//! A change the eye should follow — a page arriving beside another, one
//! leaving, the two swapping, the divider moving by itself — moves: each
//! page's x and width ease over 0.32 s, an arriving page fades in over
//! 0.3 s and a leaving one out over 0.12 s, its hole kept until it is gone.
//! Anything else (a tab switch, the window resized, the divider dragged)
//! is a cut, as Swift's is.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const TabSplit = @import("../model/split.zig").TabSplit;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");
const Room = @import("room.zig").Room;
const divider = @import("pane_divider.zig");
const split_drop = @import("split_drop.zig");
const page_layers = @import("page_layers.zig");
const link_bubble = @import("link_bubble.zig");
const omnibox = @import("omnibox.zig");
const find_bar = @import("find_bar.zig");
const mark = @import("mark.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// A page on the stage this frame, in hole order, and its opacity.
pub const Pane = struct { tab: u64, alpha: f32 = 1 };

/// The stage's memory from one frame to the next, on its `Browser`.
pub const State = struct {
    panes: [3]Pane = undefined,
    count: usize = 0,
    /// What was on the stage last frame, and the pair it was.
    was: [2]u64 = .{ 0, 0 },
    was_n: usize = 0,
    was_split: ?TabSplit = null,
    /// Last frame's boxes (stage points), for a page leaving.
    boxes: [2]Box = undefined,
    box_n: usize = 0,
    /// Until when a move is shown moving (`c.time`), and the page arriving.
    moving_until: f64 = 0,
    leaving: ?Box = null,
    divider: divider.State = .{},
    drop: split_drop.State = .{},

    /// The panes as the stage last drew their holes.
    pub fn shown(s: *const State) []const Pane {
        return s.panes[0..s.count];
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.drop.deinit(gpa);
    }
};

const Box = struct { tab: u64, rect: ui.Rect };

/// `PaneStage.Move`: what the change from last frame is, to the eye.
const Move = union(enum) { none, enter: u64, leave: u64, swap, resize };

/// Kea's glide as near as a curve comes: quick away, settling without a bounce.
const glide_curve: ui.Curve = .{ .bezier = .{ 0.22, 1, 0.36, 1 } };
const glide_duration: f32 = 0.32;

fn paneId(tab: u64) u64 {
    return std.hash.Wyhash.hash(0x7061_6e65, std.mem.asBytes(&tab));
}

/// The stage, `size` big, inside its box: the pages, the divider, the
/// drop preview. `cards`: each page a card.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, r: Room, size: ui.Size) void {
    const st = &b.stage;
    split_drop.beginFrame(b);
    const split = b.activeSplit();
    var tabs: [2]*Tab = undefined;
    var n: usize = 0;
    if (split) |s| if (b.tabById(s.left())) |l| if (b.tabById(s.right())) |rt| {
        tabs = .{ l, rt };
        n = 2;
    };
    if (n == 0) if (b.tabById(b.active_id)) |t| {
        tabs[0] = t;
        n = 1;
    };
    const roomy = size.w - divider.gutter >= 2 * divider.narrowest;
    // A page lent to WebKit's full screen window has the stage (`immersed`).
    const immersed: ?usize = if (n == 2) for (tabs[0..n], 0..) |t, i| {
        if (t.immersed) break i;
    } else null else null;
    const paired = n == 2 and roomy and immersed == null;

    const move = motionOf(st, tabs[0..n], split, roomy);
    st.divider.dragged = false;
    switch (move) {
        .none => {},
        else => st.moving_until = c.time + glide_duration,
    }
    switch (move) {
        .leave => |id| st.leaving = for (st.boxes[0..st.box_n]) |bx| {
            if (bx.tab == id) break bx;
        } else null,
        else => {},
    }
    const moving = c.time < st.moving_until;

    // Where each page goes (`layout`).
    var frames: [2]?ui.Rect = .{ null, null };
    const area: ui.Rect = .{ .w = size.w, .h = size.h };
    var room: f32 = 0;
    if (paired) {
        room = size.w - divider.gutter;
        const share: f32 = @floatCast(st.divider.live orelse split.?.fraction());
        const left = divider.clampLeft(room * share, room);
        frames = .{
            .{ .w = left, .h = size.h },
            .{ .x = left + divider.gutter, .w = room - left, .h = size.h },
        };
    } else for (tabs[0..n], 0..) |t, i| {
        // `shown`: the full-screen page alone; too narrow for two, the page
        // with the keys alone, still a pair.
        const show = if (n < 2) true else if (immersed) |im| i == im else t.id == b.active_id;
        if (show) frames[i] = area;
    }
    if (n == 2 and frames[0] == null and frames[1] == null) frames[0] = area;

    st.count = 0;
    st.box_n = 0;
    st.drop.page_n = 0;
    var left_w: f32 = 0;
    for (tabs[0..n], 0..) |t, i| {
        const f = frames[i] orelse continue;
        const id = paneId(t.id);
        // Only a page already on the stage moves; one arriving is where it goes.
        const known = std.mem.indexOfScalar(u64, st.was[0..st.was_n], t.id) != null;
        const d: f32 = if (moving and known) glide_duration else 0;
        const x = ui.tween(c, id, 1, f.x, d, glide_curve);
        const w = ui.tween(c, id, 2, f.w, d, glide_curve);
        if (move == .enter and move.enter == t.id) _ = ui.tween(c, id, 3, 0, 0, .linear);
        const alpha = ui.tween(c, id, 3, 1, 0.3, .ease_out);
        if (i == 0) left_w = w;
        const focused = t.id == b.active_id;
        const box = pane(b, c, p, t, .{ .x = x, .w = w, .h = size.h }, r.cards(), paired, focused);
        st.panes[st.count] = .{ .tab = t.id, .alpha = alpha };
        st.count += 1;
        st.boxes[st.box_n] = .{ .tab = t.id, .rect = f };
        st.box_n += 1;
        if (c.rects.get(c.node(box).id)) |wr| {
            st.drop.pages[st.drop.page_n] = .{ .tab = t.id, .rect = wr };
            st.drop.page_n += 1;
        }
    }
    leavingPane(b, c, r.cards());
    if (paired) {
        const did = paneId(split.?.right() ^ split.?.left());
        if (move == .enter) _ = ui.tween(c, did, 5, 0, 0, .linear);
        const shown = ui.tween(c, did, 5, 1, motion.quick_duration, .linear);
        divider.view(b, c, p, split.?, left_w, room, shown);
    }
    split_drop.preview(b, c, p);

    st.was_n = n;
    for (tabs[0..n], 0..) |t, i| st.was[i] = t.id;
    st.was_split = split;
    // This frame's pages into their holes, in the same order.
    b.syncStageHost();
}

/// `motion(to:split:)`: nil (`.none`) for a cut.
fn motionOf(st: *const State, now: []const *Tab, split: ?TabSplit, roomy: bool) Move {
    if (!roomy) return .none;
    const old = st.was[0..st.was_n];
    if (old.len == 1 and now.len == 2) {
        if (now[0].id == old[0]) return .{ .enter = now[1].id };
        if (now[1].id == old[0]) return .{ .enter = now[0].id };
    }
    if (old.len == 2 and now.len == 1) {
        if (old[0] == now[0].id) return .{ .leave = old[1] };
        if (old[1] == now[0].id) return .{ .leave = old[0] };
    }
    if (old.len == 2 and now.len == 2) {
        if (old[0] == now[1].id and old[1] == now[0].id) return .swap;
        if (old[0] == now[0].id and old[1] == now[1].id and !st.divider.dragged) {
            const was = st.was_split orelse return .none;
            const is = split orelse return .none;
            if (was.id.eql(is.id) and @abs(was.fraction() - is.fraction()) > 0.001) return .resize;
        }
    }
    return .none;
}

/// A page gone from beside the other keeps its hole while it fades.
fn leavingPane(b: *Browser, c: *ui.Context, cards: bool) void {
    const st = &b.stage;
    const l = st.leaving orelse return;
    for (st.shown()) |s| if (s.tab == l.tab) {
        st.leaving = null;
        return;
    };
    if (b.tabById(l.tab) == null) {
        st.leaving = null;
        return;
    }
    const alpha = ui.tween(c, paneId(l.tab), 3, 0, 0.12, .ease_out);
    if (alpha <= 0 or st.count >= st.panes.len) {
        st.leaving = null;
        return;
    }
    const i = c.open(.{ .absolute = true, .offset = .{ .x = l.rect.x, .y = l.rect.y }, .width = px(l.rect.w), .height = px(l.rect.h) }, null);
    c.addStageHoleNode(i);
    if (cards) card.cardEdge(c, i);
    c.node(i).style.opacity = alpha;
    c.end();
    st.panes[st.count] = .{ .tab = l.tab, .alpha = alpha };
    st.count += 1;
}

/// One page's hole at `at` (stage points), and over it what is drawn
/// there alone. Returns the hole's box.
fn pane(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, at: ui.Rect, cards: bool, paired: bool, focused: bool) u32 {
    ui.key(c, c.print("kea.pane.{d}", .{t.id}));
    const i = c.open(.{ .absolute = true, .offset = .{ .x = at.x, .y = at.y }, .width = px(at.w), .height = px(at.h) }, null);
    defer c.end();
    c.addStageHoleNode(i);
    if (cards) card.cardEdge(c, i);
    // `CardEdge`'s ground behind the page: seen only where no page is shown
    // (Stage.swift `Page`: blank, asleep, floating), never over a live one.
    if (cards and (t.isBlank() or t.asleep() or t.floating)) c.node(i).style.background = p.ground;
    // Watched, never taken: a click here is the page's.
    const hovered = if (c.rects.get(c.node(i).id)) |rr| rr.contains(c.input.mouse) else false;

    // The page's own layers — its cover, the floating video's line, its
    // trouble, the history disc, its question — without the page.
    page_layers.draw(c, p, t);
    if (b.prefs.split_view and focused) omnibox.view(b, c, p, .{ .w = at.w, .h = at.h }, .{ .fitted = true, .facts = !paired });
    // An empty page of a pair: the tabs already open, to bring one in.
    if (paired and t.isBlank() and b.omni.typed.items.len == 0) openTabs(b, c, p, t, at);
    link_bubble.draw(b, c, p, t, i);
    whose(c, p, t, paired and !focused and (hovered or b.folded));
    if (paired) focusCue(c, p, t.id, focused, cards);
    if (focused) find_bar.view(b, c, p, if (paired) at.w else null);
    return i;
}

/// `FocusCue`: a hairline round the page the keys go to, with two up.
fn focusCue(c: *ui.Context, p: *const Palette, tab: u64, lit: bool, cards: bool) void {
    const v = ui.tween(c, paneId(tab), 4, if (lit) 1 else 0, motion.quick_duration, .linear);
    if (v <= 0) return;
    _ = c.leaf(.{ .absolute = true, .width = .fill, .height = .fill, .radius = if (cards) metrics.card_radius else 0, .border = p.muted.alpha(0.55), .border_width = 1, .opacity = v }, .none, null);
}

/// Whose page the other one is, said on the page: under the pointer, or
/// all the time while the tabs are folded away.
fn whose(c: *ui.Context, p: *const Palette, t: *Tab, wanted: bool) void {
    const host = if (t.isBlank()) null else hostOf(t.url());
    const v = motion.quickTo(c, paneId(t.id), 6, if (wanted and host != null) 1 else 0);
    if (v <= 0) return;
    ui.row(c, .{ .absolute = true, .width = .fill, .justify = .end, .padding = .all(10), .opacity = v });
    defer ui.end(c);
    ui.row(c, .{ .height = px(22), .padding = .xy(10, 0), .radius = 11, .align_items = .center, .background = p.ground, .border = p.hairline });
    defer ui.end(c);
    ui.text(c, host orelse "", .{ .size = 11.5, .color = p.muted, .truncate = true });
}

/// The address's host, less a leading "www.".
fn hostOf(url: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, url, "://") orelse return null) + 3;
    var end = start;
    while (end < url.len and url[end] != '/' and url[end] != ':' and url[end] != '?' and url[end] != '#') end += 1;
    const host = url[start..end];
    if (host.len == 0) return null;
    return if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
}

/// `OpenTabs`: the open tabs an empty page of a pair can take, most
/// recently used first, under the field. A click brings one in.
fn openTabs(b: *Browser, c: *ui.Context, p: *const Palette, blank: *Tab, at: ui.Rect) void {
    const pair = b.splitFor(blank) orelse return;
    var list: [6]*Tab = undefined;
    var n: usize = 0;
    for (b.tabs.items) |t| {
        if (t.id == blank.id or pair.contains(t.id) or t.isBlank() or t.shy != blank.shy) continue;
        // In by when it was last looked at, newest first, six at most.
        var k = @min(n, list.len - 1);
        if (n == list.len and t.touched <= list[k].touched) continue;
        while (k > 0 and list[k - 1].touched < t.touched) : (k -= 1) list[k] = list[k - 1];
        list[k] = t;
        n = @min(n + 1, list.len);
    }
    if (n == 0) return;
    const w = @min(metrics.field_width, @max(0, at.w - 28));
    ui.column(c, .{ .absolute = true, .offset = .{ .x = (at.w - w) / 2, .y = at.h / 2 + 10 }, .width = px(w), .padding = .xy(12, 0), .gap = 2 });
    defer ui.end(c);
    ui.row(c, .{ .padding = .{ .left = 10, .right = 10, .bottom = 4 } });
    ui.text(c, "Or bring in an open tab", .{ .size = 11.5, .color = p.muted });
    ui.end(c);
    for (list[0..n]) |t| {
        ui.key(c, c.print("kea.open-tab.{d}", .{t.id}));
        const i = c.open(.{ .direction = .row, .gap = 8, .padding = .xy(10, 0), .width = .fill, .height = px(28), .radius = 8, .align_items = .center, .control = true }, null);
        const it = c.interact(i, .{});
        const label = if (t.label().len == 0) "New Tab" else t.label();
        c.addA11y(i, .button, label, "Bring this tab into the split", false, true);
        if (it.hovered) c.node(i).style.background = p.hover;
        var buf: [4]u8 = undefined;
        const icon = if (b.kea.favicons.icon(t.url())) |ic| mark.Icon{ .key = ic.key, .png = ic.png } else null;
        mark.mark(c, p, icon, t.monogram(&buf), 15, false);
        ui.text(c, label, .{ .size = 12.5, .color = if (it.hovered) p.ink else p.ink.alpha(0.75), .truncate = true });
        c.end();
        // Done next frame: the empty page goes, and it is being drawn.
        if (it.clicked) {
            b.stage.drop.pending = .{ .fill = .{ .source = t.id, .before = blank.id } };
            b.redraw();
        }
    }
}

test "hostOf drops www and the path" {
    try std.testing.expectEqualStrings("example.com", hostOf("https://www.example.com/a?b").?);
    try std.testing.expectEqualStrings("kea-test.site", hostOf("kea-test://kea-test.site:80/").?);
    try std.testing.expect(hostOf("about:blank") == null);
}
