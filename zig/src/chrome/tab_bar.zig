//! `TabBar` (TabBar.swift 1-484): the strip across the top. Past the
//! lights: the helm when it leads, the space's dot, the run of tabs (a
//! sideways scroll once they no longer fit), the plus, empty strip to
//! move the window by, then the doors. The live tab's grey slides from
//! tab to tab; tabs coming and going scale from their leading edge.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const TabGroup = @import("../model/browser.zig").TabGroup;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const presence = @import("presence.zig");
const lights = @import("lights.zig");
const tab_width = @import("tab_width.zig");
const tab_pill = @import("tab_pill.zig");
const tab_drag = @import("tab_drag.zig");
const tab_menu = @import("tab_menu.zig");
const groups_view = @import("groups_view.zig");
const spaces_view = @import("spaces_view.zig");
const window_view = @import("window_view.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// The strip's memory from one frame to the next, on its `Browser`.
pub const Strip = struct {
    /// Every pill drawn last frame, where it was in the run.
    seen: std.ArrayList(Seen) = .empty,
    /// Pills gone from the row, fading where they stood.
    leaving: std.ArrayList(Seen) = .empty,
    /// The strip has drawn once: what is there then plays no transition.
    drawn: bool = false,
    /// The space whose row was drawn last.
    space: Uuid = Uuid.first,
    /// The tab whose menu was last asked for, here or in the column.
    menu_tab: u64 = 0,
    /// The tab the run last revealed, and whether it overflowed.
    active: u64 = 0,
    overflowing: bool = false,
    reveal: ?Reveal = null,
    gen: u32 = 0,
    /// The doors at the far end, as measured last frame (0 until then).
    doors: f32 = 0,
    /// Boxes last drawn, for what reads their rects (tests, the reveal).
    run_node: u64 = 0,
    doors_node: u64 = 0,
    /// What a click asked for, done once the strip is drawn: the row
    /// isn't changed under the loop drawing it.
    act: ?Act = null,

    pub fn deinit(s: *Strip, gpa: std.mem.Allocator) void {
        s.seen.deinit(gpa);
        s.leaving.deinit(gpa);
    }
};

pub const Seen = struct {
    id: u64,
    /// The pill's box, for its rect.
    node: u64,
    x: f32,
    w: f32,
    pin: bool,
};

const Reveal = struct { gen: u32, from: f32, to: f32 };

const Act = union(enum) {
    select: u64,
    close: u64,
    home: u64,
    edit: u64,
    /// The carried tab reached another place among its peers.
    move: struct { tab: u64, target: usize, within: bool, group: ?Uuid },
    /// Let go over the strip: a group heading under it takes the tab.
    drop: struct { tab: u64, at: ui.Point },
};

/// One thing in the run: a tab with its place among its peers, or a heading.
const Item = union(enum) {
    tab: struct { tab: *Tab, index: usize, count: usize, group: ?Uuid, within: bool },
    heading: *TabGroup,
};

fn pillId(id: u64) u64 {
    return std.hash.Wyhash.hash(0x7069_6c6c, std.mem.asBytes(&id));
}

const live_id: u64 = std.hash.Wyhash.hash(0, "kea.strip.live");
const plus_id: u64 = std.hash.Wyhash.hash(0, "kea.strip.plus");
const landing_id: u64 = std.hash.Wyhash.hash(0, "kea.strip.landing");
const reveal_id: u64 = std.hash.Wyhash.hash(0, "kea.strip.reveal");

/// What the run holds, in its order: with groups on, the pins, each group
/// (its heading, its visible tabs) and the ungrouped; else every tab.
fn items(b: *Browser, a: std.mem.Allocator) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    const shown = b.displayedTabs();
    if (!b.prefs.uses_tab_groups) {
        for (shown, 0..) |t, i| try out.append(a, .{ .tab = .{ .tab = t, .index = i, .count = shown.len, .group = null, .within = false } });
        return out.items;
    }
    var pins: usize = 0;
    for (shown) |t| pins += @intFromBool(t.pin != null);
    var n: usize = 0;
    for (shown) |t| if (t.pin != null) {
        try out.append(a, .{ .tab = .{ .tab = t, .index = n, .count = pins, .group = null, .within = false } });
        n += 1;
    };
    for (b.tab_groups.items) |*g| {
        try out.append(a, .{ .heading = g });
        const members = try b.visibleTabsIn(a, g.*);
        for (members, 0..) |t, i| try out.append(a, .{ .tab = .{ .tab = t, .index = i, .count = members.len, .group = g.id, .within = true } });
    }
    var loose: std.ArrayList(*Tab) = .empty;
    for (shown) |t| if (t.pin == null and b.groupOf(t) == null) try loose.append(a, t);
    for (loose.items, 0..) |t, i| try out.append(a, .{ .tab = .{ .tab = t, .index = i, .count = loose.items.len, .group = null, .within = true } });
    return out.items;
}

fn rowOf(c: *ui.Context, list: []const Item) tab_width.Row {
    var r: tab_width.Row = .{};
    for (list) |it| switch (it) {
        .tab => |t| if (t.tab.pin != null) {
            r.pins += 1;
        } else {
            r.loose += 1;
        },
        .heading => |g| {
            r.groups += 1;
            r.headings += groups_view.headingWidth(c, g.name);
        },
    };
    return r;
}

fn fullScreen(b: *Browser) bool {
    const w = b.window orelse return false;
    return w.isFullScreen();
}

/// The strip, at the window's top, full width, 52 high.
pub fn tabBar(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.strip;
    const prefs = b.prefs;
    // The swipe between spaces watches this window (`SpaceSwipe.shared.start`).
    b.kea.swipe.start(b);
    const lights_w: f32 = if (fullScreen(b)) 12 else metrics.lights;
    const leading: f32 = if (prefs.navigation_left) metrics.helm - 8 + metrics.tab_gap else 0;
    const dot: f32 = if (prefs.uses_spaces) spaces_view.dot_width + metrics.tab_gap else 0;
    const strip_w = c.size.w;
    const room = tab_width.room(strip_w, lights_w, dot, leading, tab_width.far(st.doors, prefs.navigation_left));
    const list = items(b, c.alloc()) catch return;
    const row = rowOf(c, list);
    const each = row.each(room);
    const content = row.content(each);
    const run = @min(content, room);
    const overflowing = content > room + 0.5;
    const making = prefs.uses_spaces and b.making_space;
    const run_w = if (making) @min(540, room) else run;

    const root = c.open(.{ .absolute = true, .width = .fill, .height = px(metrics.strip) }, "kea.strip");
    const rect = c.rects.get(c.node(root).id);
    const nearby = if (rect) |r| r.contains(c.input.mouse) else false;
    // A link dragged onto the row opens there.
    c.acceptDrop(root);
    const over = if (c.input.drag_over) |at| (if (rect) |r| r.contains(at) else false) else false;
    c.node(root).style.background = p.hover.alpha(motion.quickTo(c, landing_id, 0, if (over) 1 else 0));
    if (c.dropAt(root)) |d| _ = b.take(d);

    // The empty strip moves the window; past the tabs a double click opens
    // one. The lights' corner is title bar too.
    const reserved = lights_w + dot + leading + run_w + metrics.tab_gap + metrics.plus_width;
    lights.dragStrip(b, c, .{ .absolute = true, .offset = .{ .x = reserved }, .width = px(@max(0, strip_w - reserved - st.doors - 12)), .height = .fill }, .new_tab);
    lights.dragStrip(b, c, .{ .absolute = true, .width = px(lights_w), .height = .fill }, .zoom);

    ui.row(c, .{ .width = .fill, .height = .fill, .align_items = .center, .gap = metrics.tab_gap, .padding = .{ .left = lights_w, .right = 12 } });
    if (prefs.navigation_left) helm(b, c, p);
    if (prefs.uses_spaces) spaces_view.spaceDot(b, c, p);

    // The run, and the neighbouring spaces' rows passing above or below it.
    _ = c.open(.{ .width = px(run_w), .height = px(metrics.strip) }, null);
    const swipe: f32 = b.swipe;
    if (making) {
        ui.row(c, .{ .height = .fill, .align_items = .center, .offset = .{ .y = swipe } });
        spaces_view.newSpaceCard(b, c, p, true);
        ui.end(c);
    } else {
        drawRun(b, c, p, list, each, run, overflowing, swipe);
    }
    neighbours(b, c, p, strip_w - lights_w - dot - leading, swipe);
    c.end();

    plus(b, c, p, nearby);
    ui.spacer(c);
    // Back, forward, reload, and the bookmarks, at the far end. The
    // download door arrives with P8, the extensions' with P13.
    const doors = c.open(.{ .direction = .row, .gap = metrics.tab_gap, .align_items = .center }, null);
    st.doors_node = c.node(doors).id;
    if (c.rects.get(st.doors_node)) |r| st.doors = r.w;
    if (!prefs.navigation_left) {
        ui.row(c, .{ .padding = .{ .right = 8 } });
        helm(b, c, p);
        ui.end(c);
    }
    bookmarkDoor(b, c, p);
    c.end();
    ui.end(c);
    c.end();

    st.drawn = true;
    act(b);
}

/// The tabs in their run: a sideways scroll once they overflow, the live
/// grey under them, each carried by the hand, the leaving ones fading.
fn drawRun(b: *Browser, c: *ui.Context, p: *const Palette, list: []const Item, each: f32, run: f32, overflowing: bool, swipe: f32) void {
    const st = &b.strip;
    const run_i = c.open(.{
        .direction = .row,
        .width = px(run),
        .height = px(metrics.strip),
        .gap = metrics.tab_gap,
        .align_items = .center,
        .scroll_x = overflowing,
        .scroll_bar = false,
        .clip = true,
        .offset = .{ .y = swipe },
    }, "kea.strip.run");
    defer c.end();
    const run_id = c.node(run_i).id;
    st.run_node = run_id;

    // The live grey: one box, sliding from the tab you left to the one you
    // picked (`matchedGeometryEffect(id: "live")`). Drawn first, under all.
    const live_box = c.open(.{ .absolute = true, .radius = 9, .clip = true, .opacity = 0 }, null);
    const live_fill = c.leaf(.{ .height = .fill }, .none, null);
    c.end();

    var last: std.ArrayList(Seen) = .empty;
    std.mem.swap(std.ArrayList(Seen), &last, &st.seen);
    defer last.deinit(b.gpa);
    st.seen.clearRetainingCapacity();
    // A row put in wholesale (the window's first frame, another space)
    // arrives as it is, as SwiftUI's first render plays no transition.
    const fresh = !st.drawn or !st.space.eql(b.space_id);
    st.space = b.space_id;

    var target_x: f32 = 0;
    var flow_x: f32 = 0;
    var live_rect: ?ui.Rect = null;
    var live_tab: ?*Tab = null;
    var held: ?struct { tab: *Tab, x: f32, r: tab_drag.Result } = null;
    for (list) |item| {
        switch (item) {
            .heading => |g| {
                const w = groups_view.headingWidth(c, g.name);
                const x = motion.settleTo(c, std.hash.Wyhash.hash(1, &g.id.bytes), 0, target_x);
                ui.row(c, .{ .offset = .{ .x = x - flow_x } });
                const it = groups_view.groupHeading(b, c, p, g, true);
                ui.end(c);
                flow_x += (if (it.rect) |r| r.w else w) + metrics.tab_gap;
                target_x += w + metrics.tab_gap;
            },
            .tab => |ti| {
                const t = ti.tab;
                const pid = pillId(t.id);
                const w = tab_pill.span(t, each);
                const shown_w = motion.settleTo(c, pid, 1, w);
                const x = motion.settleTo(c, pid, 0, target_x);
                const known = for (last.items) |s| {
                    if (s.id == t.id) break true;
                } else false;
                const v = presence.presenceFrom(c, pid, if (!fresh and !known) 0 else 1, true, motion.settle, null) orelse 1;
                const live = t.id == b.active_id;
                const step = w + metrics.tab_gap;
                ui.key(c, c.print("strip-tab-{d}", .{t.id}));
                if (b.carry.hand) |h| if (h.tab == t.id and h.held) {
                    // Held: its place stays empty in the row, the pill
                    // itself is drawn over the others below.
                    const slot = c.open(.{ .width = px(shown_w), .height = px(28), .offset = .{ .x = x - flow_x } }, null);
                    const it = c.interact(slot, .{});
                    c.end();
                    const r = tab_drag.carried(b, c, it, t, ti.index, ti.count, step, false);
                    if (r.target) |to| st.act = .{ .move = .{ .tab = t.id, .target = to, .within = ti.within and t.pin == null, .group = ti.group } };
                    if (r.held) {
                        held = .{ .tab = t, .x = x + r.shift, .r = r };
                    } else onRelease(b, t, r);
                    if (live) {
                        live_rect = .{ .x = x + r.shift, .y = 0, .w = shown_w, .h = 28 };
                        live_tab = t;
                    }
                    st.seen.append(b.gpa, .{ .id = t.id, .node = c.node(slot).id, .x = x, .w = shown_w, .pin = t.pin != null }) catch {};
                    flow_x += shown_w + metrics.tab_gap;
                    target_x += step;
                    continue;
                };
                const d = tab_pill.pill(b, c, p, t, .{ .live = live, .each = each, .width = shown_w, .place = .{
                    .offset = .{ .x = x - flow_x },
                    .opacity = std.math.clamp(v, 0, 1),
                    .scale = 0.9 + 0.1 * v,
                } });
                const r = tab_drag.carried(b, c, d.it, t, ti.index, ti.count, step, false);
                const shift = r.shift;
                if (shift != 0) c.node(d.index).style.offset.x += shift;
                if (r.target) |to| st.act = .{ .move = .{ .tab = t.id, .target = to, .within = ti.within and t.pin == null, .group = ti.group } };
                if (r.let_go) onRelease(b, t, r);
                if (r.held) held = .{ .tab = t, .x = x + shift, .r = r };
                if (live) {
                    live_rect = .{ .x = x + shift, .y = 0, .w = shown_w, .h = if (d.it.rect) |pr| pr.h else 28 };
                    live_tab = t;
                }
                click(b, c, t, d, r, live);
                st.seen.append(b.gpa, .{ .id = t.id, .node = d.it.id, .x = x, .w = shown_w, .pin = t.pin != null }) catch {};
                flow_x += shown_w + metrics.tab_gap;
                target_x += step;
            },
        }
    }

    if (live_rect) |lr| liveGround(b, c, p, live_box, live_fill, lr, live_tab.?, each);
    if (fresh) st.leaving.clearRetainingCapacity() else leaving(b, c, p, last.items, each);
    if (held) |h| {
        // Over its neighbours, on the drop chip; the live one keeps its grey.
        const live = h.tab.id == b.active_id;
        var chip = tab_drag.chipStyle(p);
        if (live) chip.background = if (h.tab.pin != null) p.pin_live else p.wash;
        _ = tab_pill.pill(b, c, p, h.tab, .{ .live = live, .each = each, .interactive = false, .place = .{ .absolute = true, .offset = .{ .x = h.x, .y = (metrics.strip - 28) / 2 }, .chip = chip } });
    }
    revealActive(b, c, run_id, run, overflowing);
}

/// `matchedGeometryEffect`'s grey: gliding to the live pill's place and width.
fn liveGround(b: *Browser, c: *ui.Context, p: *const Palette, box: u32, fill: u32, at: ui.Rect, tab: *Tab, each: f32) void {
    // The glide follows the pill even while it is carried, so it is where
    // the pill is when it takes over again.
    const gx = motion.glideTo(c, live_id, 0, at.x);
    const gw = motion.glideTo(c, live_id, 1, at.w);
    if (b.carry.hand) |h| if (h.tab == tab.id and h.held) return;
    // Landing, it follows the pill exactly; else it glides.
    const carried = if (b.carry.landing) |l| l.tab == tab.id else false;
    const x = if (carried) at.x else gx;
    const w = if (carried) at.w else gw;
    const pinned = tab.pin != null;
    const s = &c.node(box).style;
    s.opacity = 1;
    s.offset = .{ .x = x, .y = (metrics.strip - at.h) / 2 };
    s.width = px(w);
    s.height = px(at.h);
    s.background = if (pinned) p.pin_live else p.wash;
    // The grey fills from the left as you read down the page.
    if (pinned or tab_pill.compact(tab, each) or !b.prefs.shows_reading) return;
    const read = ui.tween(c, live_id, 2, std.math.clamp(tab.reading, 0, 1), 0.15, .ease_out);
    const f = &c.node(fill).style;
    f.width = px(w * read);
    f.background = p.ink.alpha(0.055);
}

/// Pills gone since last frame fade and shrink where they stood. Only a
/// closed tab's title is still known (its ghost); a tab moved elsewhere
/// simply goes.
fn leaving(b: *Browser, c: *ui.Context, p: *const Palette, last: []const Seen, each: f32) void {
    const st = &b.strip;
    for (last) |s| {
        const still = for (st.seen.items) |n| {
            if (n.id == s.id) break true;
        } else false;
        if (!still) st.leaving.append(b.gpa, s) catch {};
    }
    var k: usize = 0;
    for (st.leaving.items) |s| {
        const v = presence.presence(c, pillId(s.id), false, motion.settle, null) orelse continue;
        const ghost = for (b.ghosts.items) |g| {
            if (g.was == s.id) break g;
        } else continue;
        st.leaving.items[k] = s;
        k += 1;
        const o = std.math.clamp(v, 0, 1);
        _ = c.open(.{ .absolute = true, .offset = .{ .x = s.x, .y = (metrics.strip - 28) / 2 }, .width = px(s.w), .height = px(28), .padding = .{ .left = 11, .right = 7 }, .align_items = .center, .opacity = o, .scale = 0.9 + 0.1 * o, .scale_anchor = .{ .x = 0, .y = 0.5 } }, null);
        if (!s.pin and tab_width.titled(each)) ui.text(c, ghost.title, .{ .size = 12.5, .color = p.muted, .truncate = true });
        c.end();
    }
    st.leaving.shrinkRetainingCapacity(k);
}

/// A carried tab let go: over a group heading it joins that group.
fn onRelease(b: *Browser, t: *Tab, r: tab_drag.Result) void {
    if (r.dropped) |at| b.strip.act = .{ .drop = .{ .tab = t.id, .at = at } };
}

/// One gesture per tab: the live pin's double click goes home; the live
/// tab's click edits its address; any other picks it. The cross and the
/// middle button close; the right one opens its menu.
fn click(b: *Browser, c: *ui.Context, t: *Tab, d: tab_pill.Drawn, r: tab_drag.Result, live: bool) void {
    const st = &b.strip;
    if (d.close or d.it.middle_clicked) {
        st.act = .{ .close = t.id };
        return;
    }
    if (d.it.right_clicked) {
        tab_menu.popup(b, c, t);
        return;
    }
    if (r.swallowsClick() or !d.it.clicked) return;
    if (live and t.pin != null) {
        if (d.it.double_clicked) st.act = .{ .home = t.id };
    } else if (live) {
        st.act = .{ .edit = t.id };
    } else st.act = .{ .select = t.id };
}

/// Done after the drawing, so the row isn't changed under it.
fn act(b: *Browser) void {
    const a = b.strip.act orelse return;
    b.strip.act = null;
    switch (a) {
        .select => |id| if (b.tabById(id)) |t| b.select(t),
        .close => |id| if (b.tabById(id)) |t| b.close(t),
        .home => |id| if (b.tabById(id)) |t| b.goHome(t),
        // The address in the tab itself arrives with P6.
        .edit => |id| if (comptime @hasDecl(Browser, "beginTabEdit")) if (b.tabById(id)) |t| b.beginTabEdit(t),
        .move => |m| if (b.tabById(m.tab)) |t| {
            if (m.within) b.moveWithin(t, m.group, m.target) else b.moveDisplayedTab(t, m.target);
        },
        .drop => |d| if (b.tabById(d.tab)) |t| {
            if (!b.prefs.uses_tab_groups or t.pin != null) return;
            for (b.column.heading_rects.items) |h| if (h.rect.contains(d.at)) return b.moveToGroup(t, h.id);
        },
    }
}

/// Brings the live tab into view once the run scrolls: at once when it
/// first overflows, on the glide when another tab is picked.
fn revealActive(b: *Browser, c: *ui.Context, run_id: u64, run: f32, overflowing: bool) void {
    const st = &b.strip;
    defer st.active = b.active_id;
    defer st.overflowing = overflowing;
    if (st.reveal) |r| {
        const v = ui.springFrom(c, reveal_id, r.gen, r.from, r.to, motion.glide);
        c.setScroll(run_id, .x, v);
        if (v == r.to) st.reveal = null;
    }
    if (!overflowing) return;
    const changed = st.active != b.active_id;
    if (!changed and st.overflowing) return;
    const s = for (st.seen.items) |s| {
        if (s.id == b.active_id) break s;
    } else return;
    const now = c.scroll_x.get(run_id) orelse 0;
    const to = if (s.x < now) s.x else if (s.x + s.w > now + run) s.x + s.w - run else return;
    if (changed and st.drawn and st.overflowing) {
        st.gen +%= 1;
        st.reveal = .{ .gen = st.gen, .from = now, .to = to };
        _ = ui.springFrom(c, reveal_id, st.gen, now, to, motion.glide);
    } else {
        st.reveal = null;
        c.setScroll(run_id, .x, to);
    }
}

/// The other spaces' rows, drawn with the same pills while a swipe brings
/// one in — never pressed until it is the one on screen.
fn neighbours(b: *Browser, c: *ui.Context, p: *const Palette, width: f32, swipe: f32) void {
    if (swipe == 0 or !b.prefs.uses_spaces) return;
    const spaces = b.kea.spaces.value;
    const at = if (b.making_space) spaces.len else b.kea.spaceIndex(b.space_id) orelse 0;
    // Only up and down: a neighbour's row may run wider than this one.
    _ = c.open(.{ .absolute = true, .width = px(width), .height = px(metrics.strip), .clip = true }, null);
    defer c.end();
    if (swipe > 0 and at > 0) page(b, c, p, at - 1, swipe - metrics.strip);
    if (swipe < 0 and at < spaces.len) page(b, c, p, at + 1, swipe + metrics.strip);
}

fn page(b: *Browser, c: *ui.Context, p: *const Palette, index: usize, y: f32) void {
    const spaces = b.kea.spaces.value;
    ui.row(c, .{ .absolute = true, .height = px(metrics.strip), .gap = metrics.tab_gap, .align_items = .center, .offset = .{ .y = y } });
    defer ui.end(c);
    if (index == spaces.len) return spaces_view.newSpaceCard(b, c, p, true);
    const id = spaces[index].id;
    const here = id.eql(b.space_id);
    const parked = b.parked.get(id);
    const tabs: []const *Tab = if (here) b.tabs.items else if (parked) |r| r.tabs.items else &.{};
    const active = if (here) b.active_id else if (parked) |r| r.active else 0;
    var row: tab_width.Row = .{};
    for (tabs) |t| {
        if (t.pin != null) row.pins += 1 else row.loose += 1;
    }
    const lights_w: f32 = if (fullScreen(b)) 12 else metrics.lights;
    const each = row.each(tab_width.room(c.size.w, lights_w, 0, 0, tab_width.far(b.strip.doors, b.prefs.navigation_left)));
    for (tabs) |t| {
        const live = t.id == active;
        var chip: ?ui.Style = null;
        if (live) chip = .{ .background = if (t.pin != null) p.pin_live else p.wash };
        _ = tab_pill.pill(b, c, p, t, .{ .live = live, .each = each, .interactive = false, .place = .{ .chip = chip } });
    }
}

/// The way to a new page, right after the tabs: out of sight until the
/// pointer is in the strip.
fn plus(b: *Browser, c: *ui.Context, p: *const Palette, nearby: bool) void {
    const t = motion.settleTo(c, plus_id, 0, if (nearby) 1 else 0);
    const i = c.open(.{
        .padding = .xy(7, 6),
        .radius = 9,
        .align_items = .center,
        .justify = .center,
        .opacity = std.math.clamp(t, 0, 1),
        .scale = 0.7 + 0.3 * t,
        .scale_anchor = .{ .x = 0, .y = 0.5 },
        .control = nearby,
    }, "kea.strip.plus");
    defer c.end();
    if (nearby) {
        const it = c.interact(i, .{});
        c.help(i, "New Tab   ⌘T");
        c.addA11y(i, .button, "New Tab", "", false, true);
        if (it.hovered) c.node(i).style.background = p.hover;
        if (it.clicked) window_view.newTab(b);
    }
    ui.icon(c, "plus", .{ .size = 10, .weight = .medium, .frame = 15, .color = p.muted });
}

/// `Helm`: back, forward, and reload or stop, greyed where there is
/// nowhere to go; with no tab, all three greyed and still.
pub fn helm(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.row(c, .{ .gap = 4, .align_items = .center });
    defer ui.end(c);
    const tab = b.activeTab() orelse {
        ui.row(c, .{ .gap = 4, .opacity = 0.3 });
        for ([_][]const u8{ "chevron.left", "chevron.right", "arrow.clockwise" }) |icon| {
            _ = c.open(.{ .width = px(26), .height = px(26), .align_items = .center, .justify = .center }, null);
            ui.icon(c, icon, .{ .size = 11, .weight = .medium, .color = p.muted });
            c.end();
        }
        ui.end(c);
        return;
    };
    const back = !tab.isBlank() and tab.can_go_back;
    const forward = !tab.isBlank() and tab.can_go_forward;
    if (door(c, p, "chevron.left", "Back   ⌘[", back)) tab.goBack();
    if (door(c, p, "chevron.right", "Forward   ⌘]", forward)) tab.goForward();
    const loading = tab.loading;
    if (door(c, p, if (loading) "xmark" else "arrow.clockwise", if (loading) "Stop   ⌘." else "Reload   ⌘R", !tab.isBlank())) {
        if (loading) tab.stopLoading() else tab.reload();
    }
}

/// A door that can't be used fades to .3 (`Motion.quick`) and takes no clicks.
fn door(c: *ui.Context, p: *const Palette, icon: []const u8, help: []const u8, enabled: bool) bool {
    const id = c.peekId(null);
    ui.row(c, .{ .opacity = motion.quickTo(c, id, 0x6f6e, if (enabled) 1 else 0.3) });
    defer ui.end(c);
    return controls.door(c, p, icon, .{ .help = help }).clicked and enabled;
}

/// `BookmarkDoor`: filled while the page in front is kept.
// ponytail: opens the bookmarks side panel until P8.7's dropdown (BookmarksDropdown) replaces it.
fn bookmarkDoor(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const kept = if (b.activeTab()) |t| !t.isBlank() and b.bookmarks.bookmarkFor(t.url()) != null else false;
    if (controls.door(c, p, if (kept) "bookmark.fill" else "bookmark", .{ .help = "Bookmarks" }).clicked) {
        b.marks_open = !b.marks_open;
        b.syncStageHost();
    }
}
