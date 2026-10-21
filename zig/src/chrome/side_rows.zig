//! A tab as a line in the column (`SideRow`, Side.swift:640-817), the
//! line between what is kept and what comes and goes (`KeepLine`), and the
//! column's sections of rows: listed pins, groups and loose tabs, each
//! carried among its own kind (`Carried`, TabDrag.swift).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const TabGroup = @import("../model/groups.zig").TabGroup;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const mark = @import("mark.zig");
const ring = @import("ring.zig");
const tab_menu = @import("tab_menu.zig");
const tab_drag = @import("tab_drag.zig");
const groups_view = @import("groups_view.zig");
const tab_address = @import("tab_address.zig");
const split_tab_item = @import("split_tab_item.zig");
const split_drop = @import("split_drop.zig");
const tab_leaving = @import("tab_leaving.zig");
const presence = @import("presence.zig");
const side_bar = @import("side_bar.zig");
const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// `SideBar.row`, `SideBar.gap`.
pub const row_height: f32 = 28;
pub const gap: f32 = 2;
/// `KeepLine.height`.
pub const keep_line: f32 = 18;
/// A group's rows are set in under its heading.
pub const group_indent: f32 = 14;

/// What a row is part of, for where a carried row may go.
pub const Section = union(enum) {
    /// The pins kept as rows: among themselves, after `squares` squares.
    listed: usize,
    /// The loose tabs.
    loose,
    /// A group's tabs.
    group: Uuid,
};

/// One section's rows, each carried among the others; a row let go over a
/// group's heading joins that group.
pub fn section(b: *Browser, c: *ui.Context, p: *const Palette, tabs: []const *Tab, which: Section, interactive: bool, live: u64) void {
    const step = row_height + gap;
    // A group's rows are set in under its heading, grounds and all.
    if (which == .group) _ = c.open(.{ .direction = .column, .width = .fill, .gap = gap, .padding = .{ .left = group_indent } }, null);
    defer if (which == .group) c.end();
    var held: ?struct { t: *Tab, slot: u32, shift: f32 } = null;
    const st = &b.column;
    const fresh = !st.drawn or !st.space.eql(b.space_id);
    const rows_box = c.rects.get(st.rows_node);
    const snappy: ui.Spring = .{ .response = 0.26, .damping = 0.86 };
    for (tabs, 0..) |t, index| {
        ui.key(c, c.print("row-{d}", .{t.id}));
        if (interactive) tab_leaving.keepIn(&st.snaps, b.gpa, b, t);
        const item = place(b, c, p, t, live, interactive);
        const row = item.row;
        if (!interactive) continue;
        const rid = side_bar.rowId(t.id);
        const known = for (st.last.items) |s| {
            if (s.id == t.id) break true;
        } else false;
        const v = presence.presenceFrom(c, rid, if (!fresh and !known) 0 else 1, true, if (which == .group) snappy else motion.bounce, null) orelse 1;
        const r = tab_drag.carried(b, c, row.it, t, index, tabs.len, step, true);
        const node = c.node(row.index);
        const landing = if (b.carry.landing) |l| l.tab == t.id else false;
        node.style.settle_y = if (r.held or landing) null else motion.glide;
        const arr_scale: f32 = if (which == .group) 0.94 + 0.06 * v else 0.85 + 0.15 * v;
        node.style.scale *= arr_scale;
        node.style.scale_anchor = if (v >= 0.999) .{ .x = 0.5, .y = 0.5 } else .{ .x = 0, .y = 0.5 };
        if (which != .group) node.style.motion_blur = true;
        if (r.held) {
            // Its place stays, empty; the row itself is drawn last, on top.
            node.style.opacity = 0;
            held = .{ .t = t, .slot = row.index, .shift = r.shift };
        } else {
            node.style.opacity = std.math.clamp(v, 0, 1);
            if (which != .group) {
                const dir: f32 = if (b.prefs.side_position == .right) 14 else -14;
                node.style.offset.x += dir * (1 - v);
            }
            node.style.offset.y = r.shift;
        }
        if (row.it.rect) |rr| {
            const rx = if (rows_box) |rb| rr.x - rb.x else 0;
            const ry = if (rows_box) |rb| rr.y - rb.y else rr.y;
            st.seen.append(b.gpa, .{ .id = t.id, .x = rx, .y = ry, .w = rr.w }) catch {};
        } else {
            st.seen.append(b.gpa, .{ .id = t.id, .x = if (which == .group) group_indent else 0, .y = 0, .w = b.prefs.side_width - 20 - (if (which == .group) group_indent else 0) }) catch {};
        }
        if (r.target) |to| move(b, t, which, to);
        if (r.dropped) |at| dropOnGroup(b, t, at);
        if (!r.swallowsClick()) act(b, c, item.asked, item.asked.id == live, item.asked_it, item.asked_close);
    }
    const h = held orelse return;
    const parent = c.node(h.slot).parent;
    const slot = c.rects.get(c.node(h.slot).id) orelse return;
    const box = c.rects.get(c.node(parent).id) orelse return;
    // Absolute boxes are placed from the parent's padded corner.
    const pad = c.node(parent).style.padding;
    var style = tab_drag.chipStyle(p);
    style.absolute = true;
    style.offset = .{ .x = slot.x - box.x - pad.left, .y = slot.y - box.y - pad.top + h.shift };
    style.width = px(slot.w);
    _ = c.open(style, "row-carried");
    _ = place(b, c, p, h.t, live, false);
    c.end();
}

/// A row's place: the tab's row, or its pair's two lines (`SplitTabItem`);
/// `asked` the line a click, a cross or a menu was for.
const Place = struct { row: Row, asked: *Tab, asked_it: ui.Interaction, asked_close: ui.Interaction };

fn place(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, live: u64, interactive: bool) Place {
    const right = split_tab_item.partner(b, t) orelse {
        const row = sideRow(b, c, p, t, t.id == live, interactive);
        if (interactive) split_drop.mark(b, t.id, row.it.rect);
        return .{ .row = row, .asked = t, .asked_it = row.it, .asked_close = row.close };
    };
    const d = split_tab_item.stacked(b, c, p, t, right, row_height, interactive);
    var close = no_press;
    const hit = d.hit orelse return .{ .row = .{ .index = d.index, .it = d.it, .close = close }, .asked = t, .asked_it = no_press, .asked_close = close };
    close.clicked = hit.close;
    return .{ .row = .{ .index = d.index, .it = d.it, .close = close }, .asked = hit.tab, .asked_it = if (hit.close) no_press else hit.it, .asked_close = close };
}

const no_press: ui.Interaction = .{ .id = 0, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };

fn move(b: *Browser, t: *Tab, which: Section, to: usize) void {
    switch (which) {
        .listed => |squares| b.moveDisplayedTab(t, to + squares),
        .loose => if (b.prefs.uses_tab_groups) b.moveWithin(t, null, to) else b.moveDisplayedTab(t, to + b.pinnedCount()),
        .group => |id| b.moveWithin(t, id, to),
    }
}

/// `SideBar.drop`: let go over a group's heading, a loose tab joins it.
fn dropOnGroup(b: *Browser, t: *Tab, at: ui.Point) void {
    if (!b.prefs.uses_tab_groups or t.pin != null) return;
    for (b.column.heading_rects.items) |h| if (h.rect.contains(at)) return b.moveToGroup(t, h.id);
}

/// A click selects, or on the live row starts editing its address; the
/// wheel and the cross close; a right click opens the tab's menu.
fn act(b: *Browser, c: *ui.Context, t: *Tab, live: bool, it: ui.Interaction, close: ui.Interaction) void {
    if (close.clicked or it.middle_clicked) return b.close(t);
    if (it.right_clicked) return tab_menu.popup(b, c, t);
    if (!it.clicked) return;
    if (live) b.beginTabEdit(t) else b.select(t);
}

pub const Row = struct { index: u32, it: ui.Interaction, close: ui.Interaction };

/// `SideRow`: 28 high, radius 9; its mark, its private and recording
/// signs, its title; the ring or the speaker at its end while the page
/// loads or plays; the cross under the pointer, over the title's faded end.
pub fn sideRow(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, live: bool, interactive: bool) Row {
    const speaker = !t.loading and (t.noisy or t.muted);
    // Its address typed into it: a field where the title was, nothing at its end.
    const editing = interactive and b.editing_tab == t.id;
    const status = !editing and (t.loading or speaker);
    const i = c.open(.{
        .direction = .row,
        .gap = 8,
        .padding = .{ .left = 10, .right = if (status) 7 else 10 },
        .width = .fill,
        .height = px(row_height),
        .radius = 9,
        .align_items = .center,
        .clip = true,
        .control = true,
    }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const hovering = interactive and it.hovered;
    const h = motion.quickTo(c, it.id, 0, if (hovering) 1 else 0);
    const lift = if (c.reduce_motion or !interactive) 0 else motion.liftTo(c, it.id, 6, if (hovering) 1 else 0);
    const press = if (c.reduce_motion or !interactive) 0 else motion.liftTo(c, it.id, 7, if (it.pressed) 1 else 0);
    c.node(i).style.scale *= 1 + 0.012 * lift - 0.03 * press;
    const label = if (t.label().len == 0) "New Tab" else t.label();
    c.help(i, @import("tab_pill.zig").helpText(b, c, t, hovering));
    c.addA11y(i, .tab, label, if (live) "Selected" else "", live, true);

    // The ground: the sliding grey when live (`matchedGeometryEffect`), the
    // hover's otherwise; the reading fill over the live one.
    const st = &b.column;
    if (live and interactive) st.live(it.id, p.side_wash, 9);
    c.node(i).style.background = if (live)
        (if (interactive and st.pill_drawn) null else p.side_wash)
    else
        p.side_hover.alpha(h);
    if (live and b.prefs.shows_reading) {
        const fill = std.math.clamp(t.reading, 0, 1);
        const w = if (it.rect) |r| r.w else 0;
        _ = c.leaf(.{ .absolute = true, .width = px(w * fill), .height = .fill, .background = p.ink.alpha(0.055) }, .none, null);
    }

    const base = p.muted.mix(p.ink.alpha(0.7), h);
    const lv = std.math.clamp(motion.liveTo(c, it.id, 2, if (live) 1 else 0), 0, 1);
    const colour = base.mix(p.ink, lv);
    if (editing) {
        tab_address.field(b, c, p, t);
        c.node(i).style.offset.x += tab_address.shake(b, c);
    } else {
        if (b.prefs.glyph == .icons and !t.isBlank()) {
            var buf: [4]u8 = undefined;
            mark.mark(c, p, iconOf(b, t), t.monogram(&buf), 15, false);
        }
        if (t.shy) ui.icon(c, "eye.slash", .{ .size = 9, .color = colour.alpha(colour.a * 0.7) });
        if (t.recording) {
            const dot = c.open(.{}, null);
            c.help(dot, "Recording");
            ui.icon(c, "record.circle", .{ .size = 10, .color = colour.alpha(colour.a * 0.8) });
            c.end();
        }
        // The title keeps its length under the pointer and fades out beneath
        // the cross, rather than being cut shorter.
        const f_t = motion.quickTo(c, it.id, 4, if (hovering and !status) 1 else 0);
        ui.text(c, label, .{ .size = 12.5, .color = colour, .truncate = true, .fade = if (f_t > 0.001) .{ .clear = 26 * f_t, .ramp = 16 * f_t } else null });
    }

    var close: ui.Interaction = .{ .id = 0, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };
    if (status) {
        ui.spacer(c);
        // The cross takes this place while the pointer is here; the speaker
        // moves one place in, clear of the cross's reach.
        const slot = c.open(.{
            .width = px(15),
            .height = px(15),
            .align_items = .center,
            .justify = .center,
            .opacity = motion.quickTo(c, it.id, 3, if (hovering and !speaker) 0 else 1),
            .offset = .{ .x = -23 * motion.quickTo(c, it.id, 5, if (hovering and speaker) 1 else 0) },
        }, null);
        if (t.loading) ring.ring(c, 10) else if (controls.speaker(c, p, t.muted).clicked and interactive) t.toggleMute();
        c.end();
        _ = slot;
    }
    if (interactive and !editing) {
        // A pinned row is put down, not closed, and says so.
        _ = c.open(.{ .absolute = true, .width = .fill, .height = .fill, .direction = .row, .justify = .end, .align_items = .center, .padding = .{ .right = 7 } }, null);
        close = controls.closeDiscIcon(c, p, hovering, controls.close_zone, if (t.pin != null) "minus" else "xmark");
        c.end();
    }
    return .{ .index = i, .it = it, .close = close };
}

fn iconOf(b: *Browser, t: *Tab) ?mark.Icon {
    return b.kea.favicons.icon(t.url());
}

/// `KeepLine`: a hairline with Clear at its end under the pointer, which
/// closes the tabs under the line.
pub fn keepLine(b: *Browser, c: *ui.Context, p: *const Palette, clears: bool, interactive: bool) void {
    const i = c.open(.{ .direction = .row, .gap = 6, .padding = .xy(10, 0), .width = .fill, .height = px(keep_line), .align_items = .center }, "keep-line");
    defer c.end();
    const line = c.interact(i, .{});
    const hovering = interactive and line.hovered;
    if (interactive) c.cursor_hand = false;
    _ = c.leaf(.{ .grow = 1, .height = px(1), .background = p.hairline }, .none, null);
    const alpha = motion.quickTo(c, line.id, 1, if (clears and hovering) 1 else 0);
    if (alpha < 0.01) return;
    const btn = c.open(.{ .direction = .row, .gap = 3, .align_items = .center, .opacity = alpha, .control = true }, null);
    const it = c.interact(btn, .{});
    c.help(btn, "Close the tabs under the line. Pins and groups stay; ⇧⌘T brings them all back.");
    c.addA11y(btn, .button, "Clear", "", false, true);
    ui.icon(c, "arrow.down", .{ .size = 8, .weight = .semibold, .color = p.muted });
    ui.text(c, "Clear", .{ .size = 11, .color = p.muted });
    c.end();
    if (it.clicked) b.clearTabs();
}

/// The heading of each group and its rows, then the line, then the loose
/// tabs (`SideBar.loose`).
pub fn loose(b: *Browser, c: *ui.Context, p: *const Palette, listed_count: usize) void {
    const arena = c.alloc();
    if (b.prefs.uses_tab_groups) {
        // A copy: a heading's menu or click may change the list mid-frame.
        const list = arena.dupe(TabGroup, b.tab_groups.items) catch @panic("OOM");
        for (list) |*g| {
            ui.key(c, c.print("group-{s}", .{&g.id.string()}));
            _ = c.open(.{ .width = .fill, .gap = gap, .settle_y = motion.glide }, null);
            _ = groups_view.groupHeading(b, c, p, g, false);
            const members = b.visibleTabsIn(arena, g.*) catch @panic("OOM");
            section(b, c, p, members, .{ .group = g.id }, true, b.active_id);
            c.end();
        }
    }
    const rest = looseTabs(b, arena);
    if (showsLine(b, listed_count, rest.len)) keepLine(b, c, p, rest.len > 0, true);
    section(b, c, p, rest, .loose, true, b.active_id);
}

/// The tabs that are neither pins nor (with groups on) in a group.
pub fn looseTabs(b: *Browser, arena: std.mem.Allocator) []*Tab {
    var out: std.ArrayList(*Tab) = .empty;
    for (b.displayedTabs()) |t| {
        if (t.pin != null) continue;
        if (b.prefs.uses_tab_groups and b.groupOf(t) != null) continue;
        out.append(arena, t) catch break;
    }
    return out.items;
}

/// With the pinned rows on, the line shows when there is anything either side of it.
pub fn showsLine(b: *Browser, listed: usize, loose_count: usize) bool {
    return b.prefs.showsPinRows() and listed + loose_count > 0;
}
