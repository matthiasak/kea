//! The side panels (SidePanels.swift): Ubi Chat and the bookmarks, each in
//! a column of its own beside the page on the side it was put, let out
//! over the page, or popped into a window of its own (`popped.zig`); the
//! `EdgeHandle` that sizes them and the tab column, the header that moves
//! them, and their ⋯ menu. ContentView's placement (App.swift:430-446,
//! 541-560) is `beside` and `letOut`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const Room = @import("room.zig").Room;
const controls = @import("controls.zig");
const presence = @import("presence.zig");
const popped = @import("popped.zig");
const bookmarks_sidebar = @import("bookmarks/sidebar.zig");

fn px(n: f32) ui.Length {
    return .{ .px = n };
}

pub const SidePanel = enum {
    chat,
    bookmarks,

    pub fn min(self: SidePanel) f32 {
        return if (self == .chat) metrics.chat_min else metrics.side_min;
    }
    pub fn max(self: SidePanel) f32 {
        return if (self == .chat) metrics.chat_max else metrics.side_max;
    }
    pub fn standard(self: SidePanel) f32 {
        return if (self == .chat) metrics.chat else metrics.side;
    }
    /// Its width's prefs field (`ai.width`, `bookmarks.width`).
    fn field(comptime self: SidePanel) []const u8 {
        return if (self == .chat) "chat_width" else "marks_width";
    }
};

/// An edge being pulled: where the press was and the width then, so the
/// width follows the pointer's travel from there (`EdgeStripView`).
pub const EdgeDrag = struct { id: u64, x: f32, width: f32 };

/// A header held: where it was pressed, and whether it has gone the 12
/// points that make it a drag (`PanelHeaderGesture`).
pub const HeaderDrag = struct { id: u64, x: f32, y: f32, moving: bool = false };

// MARK: Browser's side (SidePanels.swift:210-263)

/// The side a panel sits on: the one chosen, or the one away from the tab column.
pub fn panelOnLeft(b: *const Browser, panel: SidePanel) bool {
    return (if (panel == .chat) b.prefs.effectiveChatSide() else b.prefs.effectiveMarksSide()) == .left;
}

pub fn movePanel(b: *Browser, panel: SidePanel, left: bool) void {
    const side: ?@import("../data/prefs.zig").SidePosition = if (left) .left else .right;
    if (panel == .chat) b.prefs.set("chat_side", side) else b.prefs.set("marks_side", side);
    redrawAll(b.kea);
}

/// A header let go of at window x `x` in a window `width` wide: the panel
/// goes to the half of the window it was let go in.
pub fn dropPanel(b: *Browser, panel: SidePanel, x: f32, width: f32) void {
    if (width <= 0) return;
    movePanel(b, panel, x < width / 2);
}

pub fn toggleExpanded(b: *Browser, panel: SidePanel) void {
    b.expanded_panel = if (b.expanded_panel == panel) null else panel;
    b.redraw();
}

pub fn togglePopped(b: *Browser, panel: SidePanel) void {
    if (b.expanded_panel == panel) b.expanded_panel = null;
    if (panel == .chat) b.prefs.set("chat_popped", !b.prefs.chat_popped) else b.prefs.set("marks_popped", !b.prefs.marks_popped);
    redrawAll(b.kea);
}

pub fn setPanelWidth(b: *Browser, panel: SidePanel, width: f32) void {
    const w = std.math.clamp(width, panel.min(), panel.max());
    if (panel == .chat) b.prefs.set("chat_width", w) else b.prefs.set("marks_width", w);
    b.redraw();
}

/// Bookmarks › Show Bookmarks Sidebar (⌃⌘B, `bookmarks.sidebar`): every
/// window's, as the pref is.
pub fn toggleBookmarks(kea: *Kea) void {
    kea.prefs.set("bookmarks_sidebar", !kea.prefs.bookmarks_sidebar);
    redrawAll(kea);
}

/// Esc's step for a panel let out over the page (`ContentView.take`):
/// back to its column, when it is open at all.
pub fn collapse(b: *Browser) bool {
    const panel = b.expanded_panel orelse return false;
    const open = if (panel == .chat) b.assisting != null else b.prefs.bookmarks_sidebar;
    if (!open) return false;
    toggleExpanded(b, panel);
    return true;
}

pub fn redrawAll(kea: *Kea) void {
    for (kea.browsers.items) |x| x.redraw();
    if (kea.marks_window) |w| w.redraw();
}

// MARK: the window's placement (App.swift:430-446, 541-560)

/// The panels on one side of the stage: Ubi Chat outermost, then the
/// bookmarks, then the page.
const col_id_base: u64 = std.hash.Wyhash.hash(0, "kea.panel.column");

fn columnWidth(b: *Browser, c: *ui.Context, panel: SidePanel, left: bool, width: f32, win_resized: bool) f32 {
    const pid = col_id_base ^ @as(u64, @intFromEnum(panel)) ^ (if (left) @as(u64, 0x100) else @as(u64, 0x200));
    if (b.edge_drag != null or win_resized) {
        ui.jump(c, pid, 1, width);
        return width;
    }
    return motion.glideTo(c, pid, 1, width);
}

pub fn beside(b: *Browser, c: *ui.Context, p: *const Palette, r: Room, left: bool) void {
    const st = &b.column;
    const win_resized = st.panel_win_w != 0 and st.panel_win_w != r.window_width;
    if (!left) st.panel_win_w = r.window_width;
    const chat = r.chatShown() and panelOnLeft(b, .chat) == left;
    const marks = r.marksShown() and panelOnLeft(b, .bookmarks) == left;
    if (left and chat) panelView(b, c, p, .chat, true, columnWidth(b, c, .chat, true, r.chatWidth(), win_resized), false, false);
    if (marks) panelView(b, c, p, .bookmarks, left, columnWidth(b, c, .bookmarks, left, r.marksWidth(), win_resized), false, false);
    if (!left and chat) panelView(b, c, p, .chat, false, columnWidth(b, c, .chat, false, r.chatWidth(), win_resized), false, false);
}

const let_out_id: u64 = std.hash.Wyhash.hash(0, "kea.panel.let-out");

/// The panel let out over the page (`letOut`), inside the stage's box;
/// it comes and goes on Motion.glide.
pub fn letOut(b: *Browser, c: *ui.Context, p: *const Palette, r: Room) void {
    const shown: ?SidePanel = if (b.expanded_panel) |e| switch (e) {
        .chat => if (r.chatColumn() and !r.chat_popped) e else null,
        .bookmarks => if (r.marksColumn() and !r.marks_popped) e else null,
    } else null;
    if (shown) |s| b.let_out = s;
    const v = presence.presence(c, let_out_id, shown != null, motion.glide, null) orelse return;
    const panel = b.let_out orelse return;
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .opacity = std.math.clamp(v, 0, 1) });
    defer ui.end(c);
    panelView(b, c, p, panel, panelOnLeft(b, panel), null, true, false);
}

/// One panel's view: `BookmarksSidebar` or `AssistantPanel`.
pub fn panelView(b: *Browser, c: *ui.Context, p: *const Palette, panel: SidePanel, on_left: bool, width: ?f32, expanded: bool, is_popped: bool) void {
    switch (panel) {
        .bookmarks => bookmarksView(b, c, p, on_left, width, expanded, is_popped),
        .chat => @import("../ai/chat_view.zig").view(b, c, p, on_left, width, expanded, is_popped),
    }
}

/// `BookmarksSidebar` (Bookmarks.swift:1508-1579): the header is the
/// panel's, the list the bookmarks' own (`bookmarks/sidebar.zig`).
fn bookmarksView(b: *Browser, c: *ui.Context, p: *const Palette, on_left: bool, width: ?f32, expanded: bool, is_popped: bool) void {
    begin(c, p, .bookmarks, width, expanded);
    const head = c.open(.{ .direction = .row, .width = .fill, .gap = 6, .align_items = .center, .padding = .{ .left = 12, .right = 6, .top = 6, .bottom = 6 } }, "kea.marks.head");
    headerGesture(b, c, head, .bookmarks, !is_popped);
    bookmarks_sidebar.headerLead(b, c, p);
    if (!is_popped) {
        const icon = if (expanded) "arrow.down.right.and.arrow.up.left" else "arrow.up.left.and.arrow.down.right";
        if (controls.door(c, p, icon, .{ .help = if (expanded) "Back to Sidebar Width" else "Expand" }).clicked) toggleExpanded(b, .bookmarks);
    }
    panelMenu(b, c, p, .bookmarks, is_popped);
    if (controls.door(c, p, "xmark", .{ .help = "Hide Bookmarks Sidebar" }).clicked) {
        b.prefs.set("bookmarks_sidebar", false);
        redrawAll(b.kea);
    }
    c.end();
    bookmarks_sidebar.content(b, c, p);
    end(b, c, p, .bookmarks, on_left, width);
}

// MARK: a panel's frame

/// A panel's box: `width` wide in its column, or the whole room when let
/// out (its content at most 760 wide, centred) or in a window of its own.
/// Close with `end`.
pub fn begin(c: *ui.Context, p: *const Palette, panel: SidePanel, width: ?f32, expanded: bool) void {
    const outer = c.open(.{
        .width = if (width) |w| px(w) else .fill,
        .height = .fill,
        .align_items = .center,
        .background = p.ground,
    }, if (panel == .chat) "kea.panel.chat" else "kea.panel.marks");
    // Clicks on the panel are its own, not the page's under a let-out one.
    _ = c.interact(outer, .{});
    ui.column(c, .{ .width = .fill, .height = .fill, .max_width = if (expanded) 760 else std.math.inf(f32) });
}

/// Ends `begin`'s box: in a column, the hairline and the edge on the page's side.
pub fn end(b: *Browser, c: *ui.Context, p: *const Palette, panel: SidePanel, on_left: bool, width: ?f32) void {
    ui.end(c);
    if (width) |w| {
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = if (on_left) w - 1 else 0 }, .width = px(1), .height = .fill, .background = p.hairline }, .none, null);
        switch (panel) {
            inline else => |pn| edgeHandle(b, c, p, comptime pn.field(), pn.min(), pn.max(), pn.standard(), on_left, if (on_left) w - 9 else 0),
        }
    }
    c.end();
}

/// `PanelHeaderGesture` on header box `index`: pulled 12 points or more,
/// it carries the panel to the half of the window it is let go in; a
/// double click lets it out over the page and back.
pub fn headerGesture(b: *Browser, c: *ui.Context, index: u32, panel: SidePanel, active: bool) void {
    if (!active) return;
    const it = c.interact(index, .{});
    if (it.double_clicked) {
        b.header_drag = null;
        return toggleExpanded(b, panel);
    }
    if (it.pressed) {
        if (b.header_drag == null or b.header_drag.?.id != it.id)
            b.header_drag = .{ .id = it.id, .x = c.input.mouse.x, .y = c.input.mouse.y };
        const d = &b.header_drag.?;
        if (!d.moving and std.math.hypot(c.input.mouse.x - d.x, c.input.mouse.y - d.y) >= 12) d.moving = true;
        if (d.moving) c.cursor = .closed_hand;
        return;
    }
    const d = b.header_drag orelse return;
    if (d.id != it.id) return;
    b.header_drag = null;
    if (d.moving) dropPanel(b, panel, c.input.mouse.x, c.size.w);
}

/// `PanelMenu`: the ⋯ door, its menu under it.
pub fn panelMenu(b: *Browser, c: *ui.Context, p: *const Palette, panel: SidePanel, is_popped: bool) void {
    const i = c.open(.{ .width = px(26), .height = px(26), .align_items = .center, .justify = .center, .control = true }, null);
    const it = c.interact(i, .{});
    c.addA11y(i, .menu_button, "More", "", false, true);
    ui.icon(c, "ellipsis", .{ .size = 11, .color = p.muted });
    c.end();
    if (!it.clicked) return;
    const r = it.rect orelse return;
    menuLater(b, panel, is_popped, .{ .x = r.x, .y = r.y + r.h });
}

/// The menu's items, in PanelMenu's order (titles static).
pub fn menuItems(arena: std.mem.Allocator, b: *Browser, panel: SidePanel, is_popped: bool) ![]MenuItem {
    var out: std.ArrayList(MenuItem) = .empty;
    if (panel == .chat) try out.appendSlice(arena, try @import("../ai/chat_view.zig").menuExtra(arena, b));
    if (!is_popped) {
        const left = panelOnLeft(b, panel);
        try out.append(arena, try pick(arena, b, panel, if (left) .right else .left, if (left) "Move to Right Side" else "Move to Left Side"));
        try out.append(arena, try pick(arena, b, panel, .expand, if (b.expanded_panel == panel) "Back to Sidebar Width" else "Expand"));
    }
    try out.append(arena, try pick(arena, b, panel, .pop, if (is_popped) "Back to the Window" else "Open in Separate Window"));
    return out.items;
}

const Pick = struct {
    kea: *Kea,
    window: @import("../data/json.zig").Uuid,
    panel: SidePanel,
    what: enum { left, right, expand, pop },

    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const b = for (self.kea.browsers.items) |x| {
            if (x.record_id.eql(self.window)) break x;
        } else return;
        switch (self.what) {
            .left => movePanel(b, self.panel, true),
            .right => movePanel(b, self.panel, false),
            .expand => toggleExpanded(b, self.panel),
            .pop => togglePopped(b, self.panel),
        }
    }
};

fn pick(arena: std.mem.Allocator, b: *Browser, panel: SidePanel, what: @FieldType(Pick, "what"), label: []const u8) !MenuItem {
    const s = try arena.create(Pick);
    s.* = .{ .kea = b.kea, .window = b.record_id, .panel = panel, .what = what };
    return .{ .label = label, .click = .of(s, Pick.fire) };
}

/// Shown on the next turn of the run loop (`popUpMenu` runs a loop of its
/// own, not to run inside the frame that asked), in the window the door
/// is in: the browser's, or the panel's own.
const Later = struct {
    kea: *Kea,
    window: @import("../data/json.zig").Uuid,
    panel: SidePanel,
    is_popped: bool,
    at: ui.Point,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Later = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(l);
        const b = for (l.kea.browsers.items) |x| {
            if (x.record_id.eql(l.window)) break x;
        } else return;
        const win = if (l.is_popped) popped.windowOf(b, l.panel) else b.window;
        const s = (win orelse return).surface orelse return;
        var arena = std.heap.ArenaAllocator.init(b.gpa);
        defer arena.deinit();
        const template = menuItems(arena.allocator(), b, l.panel, l.is_popped) catch return;
        const m = nanoui.Menu.create(b.gpa, @import("../app/kea.zig").app_name, template) catch return;
        defer m.destroy();
        m.popup(s.nsview, l.at.x, l.at.y);
    }
};

fn menuLater(b: *Browser, panel: SidePanel, is_popped: bool, at: ui.Point) void {
    if (b.kea.ui_app == null) return;
    const l = std.heap.c_allocator.create(Later) catch return;
    l.* = .{ .kea = b.kea, .window = b.record_id, .panel = panel, .is_popped = is_popped, .at = at };
    objc.dispatchMain(l, Later.fire);
}

// MARK: EdgeHandle (SidePanels.swift:16-184)

/// `EdgeHandle`: 9 points over the inner edge of a column `x` from its
/// start, setting prefs `field` within `min…max` as it is pulled, back to
/// `standard` on a double click; VoiceOver steps it by 10.
pub fn edgeHandle(b: *Browser, c: *ui.Context, p: *const Palette, comptime field: []const u8, min: f32, max: f32, standard: f32, grows_right: bool, x: f32) void {
    const width = @field(b.prefs.*, field);
    const i = c.open(.{ .absolute = true, .offset = .{ .x = x }, .width = px(9), .height = .fill, .align_items = .center, .justify = .center }, field ++ ".edge");
    const it = c.interact(i, .{});
    c.adjustable(i, .{ .role = .splitter, .label = "Column width", .value = c.print("{d}", .{@round(width)}) });
    if (it.a11y_step != 0) {
        b.prefs.set(field, std.math.clamp(width + 10 * @as(f32, @floatFromInt(it.a11y_step)), min, max));
        c.changed = true;
    }
    if (it.hovered or it.pressed) c.cursor = .resize_left_right;
    if (it.hovered and c.input.pressed) b.edge_drag = .{ .id = it.id, .x = c.input.mouse.x, .width = width };
    if (it.double_clicked) {
        b.edge_drag = null;
        b.prefs.set(field, standard);
        c.changed = true;
    } else if (it.pressed) if (b.edge_drag) |d| if (d.id == it.id) {
        const dx = c.input.mouse.x - d.x;
        const next = std.math.clamp(@round(d.width + if (grows_right) dx else -dx), min, max);
        if (@abs(width - next) >= 0.5) {
            // ponytail: written to defaults when the drag ends, not every frame as
            // Swift's didSet does: a defaults write costs ~1 ms of each drag frame.
            @field(b.prefs.*, field) = next;
            c.changed = true;
        }
    };
    if (!c.input.down) if (b.edge_drag) |d| if (d.id == it.id) {
        b.edge_drag = null;
        if (width != d.width) b.prefs.set(field, width);
    };
    _ = c.leaf(.{ .width = px(2), .height = .fill, .background = if (it.hovered or it.pressed) p.muted else ui.Color.transparent }, .none, null);
    c.end();
}
