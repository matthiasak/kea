//! A group's quiet name above its tabs (`GroupHeading`, TabGroups.swift),
//! in the column or the strip: a click folds the group, a right click
//! opens its menu, a drag onto another heading moves it there, and its
//! name is typed in place while it is being renamed.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const groups = @import("../model/groups.zig");
const TabGroup = groups.TabGroup;
const Uuid = @import("../data/json.zig").Uuid;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const tab_menu = @import("tab_menu.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// Its height in the column, a little under a tab's.
pub const height: f32 = 24;

const name_style: ui.TextStyle = .{ .size = 12.5, .weight = .medium };

/// `GroupHeading.width(for:)`: its width in the strip.
pub fn headingWidth(c: *ui.Context, name: []const u8) f32 {
    return @ceil(c.text.width(name, name_style)) + 20;
}

/// A heading held and carried toward another (`onDrag`/`onDrop`).
pub const Held = struct { id: Uuid, origin: ui.Point, moved: bool = false };

/// Where each heading was last frame, for rows and headings let go over one.
pub const HeadingRect = struct { id: Uuid, rect: ui.Rect };

/// Once a frame, before the strip or the column: last frame's headings are
/// where drops land; this frame's are gathered afresh.
pub fn beginFrame(b: *Browser) void {
    const st = &b.column;
    std.mem.swap(std.ArrayList(HeadingRect), &st.heading_rects, &st.heading_next);
    st.heading_next.clearRetainingCapacity();
}

pub fn groupHeading(b: *Browser, c: *ui.Context, p: *const Palette, group: *const TabGroup, horizontal: bool) ui.Interaction {
    const st = &b.column;
    const editing = if (b.editing_group_id) |e| e.eql(group.id) else false;
    const i = c.open(.{
        .direction = .row,
        .gap = 8,
        .padding = .xy(10, 0),
        .width = if (horizontal) .auto else .fill,
        .height = px(if (horizontal) 28 else height),
        .radius = 9,
        .align_items = .center,
        .control = true,
    }, null);
    defer c.end();
    const it = c.interact(i, .{});
    if (it.rect) |r| st.heading_next.append(b.gpa, .{ .id = group.id, .rect = r }) catch {};
    c.addA11y(i, .button, group.name, if (group.collapsed) "Collapsed" else "Expanded", false, true);

    // A heading carried over this one: it would land here.
    const held_here = if (st.group_held) |h| h.moved and !h.id.eql(group.id) and it.hovered else false;
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = if (held_here) p.side_wash else p.side_hover.alpha(h);

    if (editing) {
        nameField(b, c, p, group, horizontal);
    } else {
        ui.text(c, group.name, .{ .size = name_style.size, .weight = name_style.weight, .color = p.muted, .truncate = true });
    }
    if (!horizontal) ui.spacer(c);
    if (!editing and !horizontal) {
        // nanoui can't turn a glyph: the folded group's chevron points right.
        _ = c.open(.{ .opacity = h }, null);
        ui.icon(c, if (group.collapsed) "chevron.right" else "chevron.down", .{ .size = 9, .weight = .medium, .color = p.muted });
        c.end();
    }

    if (carry(b, c, group, it)) return it;
    if (it.right_clicked) {
        tab_menu.later(b, c.input.mouse, groups.number(group.id), menuItems);
    } else if (it.clicked and !editing) {
        b.toggleTabGroup(group.id);
    }
    return it;
}

/// The name being typed: Return renames, Esc leaves it as it was.
fn nameField(b: *Browser, c: *ui.Context, p: *const Palette, group: *const TabGroup, horizontal: bool) void {
    const st = &b.column;
    const claim = st.group_claimed == null or !st.group_claimed.?.eql(group.id);
    if (claim) {
        st.group_claimed = group.id;
        st.group_draft.set(group.name);
    }
    const w: ui.Length = if (horizontal) px(@max(60, headingWidth(c, group.name) - 20)) else .fill;
    const placeholder = st.group_draft.text().len == 0;
    _ = c.open(.{ .width = w }, null);
    if (placeholder) _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = "Group name", .style = name_style, .color = p.faint } }, null);
    if (claim) ui.focusNext(c, false);
    const res = ui.textField(c, &st.group_draft, .{ .bare = true, .size = name_style.size, .width = .fill, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
    c.end();
    if (res.submitted) {
        b.renameTabGroup(group.id, st.group_draft.text());
        b.editing_group_id = null;
        st.group_claimed = null;
        c.changed = true;
    } else if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
        b.editing_group_id = null;
        st.group_claimed = null;
        c.changed = true;
    }
}

/// A heading pressed and pulled 5 points is carried; let go over another
/// heading, its group takes that one's place. True while carried and on
/// the release that ends it: no click.
fn carry(b: *Browser, c: *ui.Context, group: *const TabGroup, it: ui.Interaction) bool {
    const st = &b.column;
    if (it.pressed and st.group_held == null) st.group_held = .{ .id = group.id, .origin = c.input.mouse };
    const h = if (st.group_held) |*held| held else return false;
    if (!h.id.eql(group.id)) return false;
    if (!c.input.down) {
        const was = h.moved;
        st.group_held = null;
        if (!was) return false;
        c.changed = true;
        for (st.heading_rects.items) |r| if (!r.id.eql(group.id) and r.rect.contains(c.input.mouse)) {
            const to = for (b.tab_groups.items, 0..) |g, index| {
                if (g.id.eql(r.id)) break index;
            } else break;
            b.moveTabGroup(group.id, to);
            break;
        };
        return true;
    }
    if (!h.moved and std.math.hypot(c.input.mouse.x - h.origin.x, c.input.mouse.y - h.origin.y) < 5) return false;
    if (!h.moved) c.changed = true;
    h.moved = true;
    c.cursor = .closed_hand;
    return true;
}

// MARK: the menu (TabGroups.swift:105-111)

const Pick = struct {
    b: *Browser,
    id: Uuid,
    what: enum { rename, toggle, ungroup, close },

    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const b = self.b;
        switch (self.what) {
            .rename => b.editing_group_id = self.id,
            .toggle => b.toggleTabGroup(self.id),
            .ungroup => b.removeTabGroup(self.id),
            .close => b.closeTabGroup(self.id),
        }
        b.redraw();
    }
};

/// The heading's menu for the group numbered `number`.
pub fn menuItems(arena: std.mem.Allocator, b: *Browser, number: u64) anyerror![]const nanoui.MenuItem {
    const g = for (b.tab_groups.items) |g| {
        if (groups.number(g.id) == number) break g;
    } else return &.{};
    const out = try arena.alloc(nanoui.MenuItem, 5);
    const labels = [_][]const u8{ "Rename Group", if (g.collapsed) "Expand Group" else "Collapse Group", "", "Ungroup Tabs", "Close Group" };
    const whats = [_]@FieldType(Pick, "what"){ .rename, .toggle, .rename, .ungroup, .close };
    for (out, labels, whats, 0..) |*item, label, what, n| {
        if (n == 2) {
            item.* = .separator;
            continue;
        }
        const pick = try arena.create(Pick);
        pick.* = .{ .b = b, .id = g.id, .what = what };
        item.* = .{ .label = label, .click = .of(pick, Pick.fire) };
    }
    return out;
}
