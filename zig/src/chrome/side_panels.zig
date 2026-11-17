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
const platform = @import("../sys/platform.zig");
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");
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
    web,

    pub fn min(self: SidePanel) f32 {
        return if (self == .bookmarks) metrics.side_min else metrics.chat_min;
    }
    pub fn max(self: SidePanel) f32 {
        return if (self == .bookmarks) metrics.side_max else metrics.chat_max;
    }
    pub fn standard(self: SidePanel) f32 {
        return if (self == .bookmarks) metrics.side else metrics.chat;
    }
    /// Its width's prefs field (`ai.width`, `bookmarks.width`, `web_panel.width`).
    fn field(comptime self: SidePanel) []const u8 {
        return switch (self) {
            .chat => "chat_width",
            .bookmarks => "marks_width",
            .web => "web_width",
        };
    }
};

/// An edge being pulled: where the press was and the width then, so the
/// width follows the pointer's travel from there (`EdgeStripView`).
pub const EdgeField = enum { none, side_width, chat_width, marks_width, web_width };
pub const EdgeDrag = struct { id: u64, x: f32, width: f32, min: f32 = 0, max: f32 = 0, grows_right: bool = false, target: EdgeField = .none };

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
    if (panel == .web) return;
    b.let_out = panel;
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
    switch (panel) {
        .chat => b.prefs.set("chat_width", w),
        .bookmarks => b.prefs.set("marks_width", w),
        .web => b.prefs.set("web_width", w),
    }
    b.redraw();
}

/// Bookmarks › Show Bookmarks Sidebar (⌃⌘B, `bookmarks.sidebar`): every
/// window's, as the pref is.
pub fn toggleBookmarks(kea: *Kea) void {
    kea.prefs.set("bookmarks_sidebar", !kea.prefs.bookmarks_sidebar);
    redrawAll(kea);
}

pub fn openWebPanel(b: *Browser, url: []const u8) void {
    if (url.len == 0) return;
    if (b.web_panel_tab) |t| {
        t.go(url);
    } else {
        b.web_panel_tab = b.make(url, false);
    }
    b.redraw();
}

pub fn closeWebPanel(b: *Browser) void {
    const t = b.web_panel_tab orelse return;
    b.web_panel_tab = null;
    if (b.expanded_panel == .web) b.expanded_panel = null;
    if (b.stage_host) |sh| sh.setWebPanel(null);
    b.letGo(t);
    b.redraw();
}

pub fn keepWebPanelAsTab(b: *Browser) void {
    const t = b.web_panel_tab orelse return;
    b.web_panel_tab = null;
    if (b.expanded_panel == .web) b.expanded_panel = null;
    if (b.stage_host) |sh| sh.setWebPanel(null);
    b.insert(t, b.placeForNew());
    b.select(t);
    b.redraw();
}

/// Esc's step for a panel let out over the page (`ContentView.take`):
/// back to its column, when it is open at all.
pub fn collapse(b: *Browser) bool {
    const panel = b.expanded_panel orelse return false;
    const open = switch (panel) {
        .chat => b.assisting != null,
        .bookmarks => b.prefs.bookmarks_sidebar,
        .web => b.web_panel_tab != null,
    };
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

const pres_salt: u32 = 0x7072_6573;

fn canDrawLeave(b: *const Browser, panel: SidePanel) bool {
    if (b.let_out == panel) return false;
    return switch (panel) {
        .bookmarks => !b.prefs.marks_popped,
        .chat => b.assisting != null and !b.prefs.chat_popped,
        .web => b.web_panel_tab != null,
    };
}

fn columnSlot(b: *Browser, c: *ui.Context, p: *const Palette, panel: SidePanel, left: bool, shown: bool, target_w: f32, win_resized: bool, cards: bool) void {
    const pid = col_id_base ^ @as(u64, @intFromEnum(panel)) ^ (if (left) @as(u64, 0x100) else @as(u64, 0x200));
    if (shown) {
        if (win_resized or b.edge_drag != null) ui.jump(c, pid, pres_salt, 1);
        const t = presence.presenceFrom(c, pid, if (win_resized or b.edge_drag != null) 1 else 0, true, motion.settle, motion.lift) orelse 1;
        const a = std.math.clamp(t, 0, 1);
        const slide = if (t < 0.999) (if (left) @as(f32, -1) else @as(f32, 1)) * (1 - a) * 14 else 0;
        _ = c.open(.{
            .width = px(target_w),
            .height = .fill,
            .offset = .{ .x = slide },
            .opacity = a,
            .group = t < 0.999,
        }, null);
        defer c.end();
        panelViewWithCards(b, c, p, panel, left, target_w, false, false, cards);
        return;
    }
    if (win_resized or !canDrawLeave(b, panel) or target_w <= 0.5) {
        ui.jump(c, pid, pres_salt, 0);
        return;
    }
    const t = presence.presenceFrom(c, pid, 0, false, motion.settle, motion.lift) orelse return;
    if (t <= 0.005) {
        ui.jump(c, pid, pres_salt, 0);
        return;
    }
    const a = std.math.clamp(t, 0, 1);
    const slide = (if (left) @as(f32, -1) else @as(f32, 1)) * (1 - a) * 14;
    _ = c.open(.{ .width = px(0), .height = .fill }, if (left) "kea.panel.leave.l" else "kea.panel.leave.r");
    defer c.end();
    _ = c.open(.{
        .absolute = true,
        .offset = .{ .x = (if (left) @as(f32, 0) else -target_w) + slide },
        .width = px(target_w),
        .height = .fill,
        .opacity = a,
        .group = true,
    }, null);
    defer c.end();
    panelViewWithCards(b, c, p, panel, left, target_w, false, false, cards);
}

pub fn beside(b: *Browser, c: *ui.Context, p: *const Palette, r: Room, left: bool) void {
    const st = &b.column;
    const win_resized = st.panel_win_w != 0 and st.panel_win_w != r.window_width;
    if (!left) st.panel_win_w = r.window_width;
    const cards = r.cards();
    const chat = r.chatShown() and panelOnLeft(b, .chat) == left;
    const marks = r.marksShown() and panelOnLeft(b, .bookmarks) == left;
    const web = r.webShown() and panelOnLeft(b, .web) == left;
    if (left) columnSlot(b, c, p, .chat, true, chat, r.chatWidth(), win_resized, cards);
    columnSlot(b, c, p, .bookmarks, left, marks, r.marksWidth(), win_resized, cards);
    columnSlot(b, c, p, .web, left, web, r.webWidth(), win_resized, cards);
    if (!left) columnSlot(b, c, p, .chat, false, chat, r.chatWidth(), win_resized, cards);
}

const let_out_id: u64 = std.hash.Wyhash.hash(0, "kea.panel.let-out");

/// The panel let out over the page (`letOut`), inside the stage's box;
/// it comes and goes on Motion.glide.
pub fn letOut(b: *Browser, c: *ui.Context, p: *const Palette, r: Room) void {
    const narrow = @import("compact_bar.zig").isNarrowOverlay(r.window_width);
    const chosen: ?SidePanel = b.expanded_panel orelse if (narrow)
        (if (r.chatColumn() and !r.chat_popped) SidePanel.chat else if (r.marksColumn() and !r.marks_popped) SidePanel.bookmarks else if (r.webColumn()) SidePanel.web else null)
    else
        null;
    const shown: ?SidePanel = if (chosen) |e| switch (e) {
        .chat => if (r.chatColumn() and !r.chat_popped) e else null,
        .bookmarks => if (r.marksColumn() and !r.marks_popped) e else null,
        .web => if (r.webColumn()) e else null,
    } else null;
    if (shown) |s| b.let_out = s;
    if (shown == null) if (b.let_out) |lo| {
        const alive = switch (lo) {
            .bookmarks => !r.marks_popped,
            .chat => b.assisting != null and !r.chat_popped,
            .web => b.web_panel_tab != null,
        };
        if (!alive) {
            b.let_out = null;
            ui.jump(c, let_out_id, pres_salt, 0);
            return;
        }
    };
    const v = presence.presence(c, let_out_id, shown != null, motion.glide, motion.settle) orelse {
        b.let_out = null;
        return;
    };
    const panel = b.let_out orelse return;
    const a = std.math.clamp(v, 0, 1);
    ui.column(c, .{
        .absolute = true,
        .width = .fill,
        .height = .fill,
        .offset = .{ .y = (1 - a) * 8 },
        .opacity = a,
        .group = v < 0.999,
    });
    defer ui.end(c);
    panelViewWithCards(b, c, p, panel, panelOnLeft(b, panel), null, true, false, r.cards());
}

/// One panel's view: `BookmarksSidebar` or `AssistantPanel`.
pub fn panelView(b: *Browser, c: *ui.Context, p: *const Palette, panel: SidePanel, on_left: bool, width: ?f32, expanded: bool, is_popped: bool) void {
    panelViewWithCards(b, c, p, panel, on_left, width, expanded, is_popped, false);
}

pub fn panelViewWithCards(b: *Browser, c: *ui.Context, p: *const Palette, panel: SidePanel, on_left: bool, width: ?f32, expanded: bool, is_popped: bool, cards: bool) void {
    switch (panel) {
        .bookmarks => bookmarksView(b, c, p, on_left, width, expanded, is_popped, cards),
        .chat => @import("../ai/chat_view.zig").viewWithCards(b, c, p, on_left, width, expanded, is_popped, cards),
        .web => webPanelView(b, c, p, on_left, width, expanded, cards),
    }
}

/// `BookmarksSidebar` (Bookmarks.swift:1508-1579): the header is the
/// panel's, the list the bookmarks' own (`bookmarks/sidebar.zig`).
fn bookmarksView(b: *Browser, c: *ui.Context, p: *const Palette, on_left: bool, width: ?f32, expanded: bool, is_popped: bool, cards: bool) void {
    beginWithCards(c, p, .bookmarks, on_left, width, expanded, cards);
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
    endWithCards(b, c, p, .bookmarks, on_left, width, cards);
}

fn webPanelView(b: *Browser, c: *ui.Context, p: *const Palette, on_left: bool, width: ?f32, expanded: bool, cards: bool) void {
    beginWithCards(c, p, .web, on_left, width, expanded, cards);
    const head = c.open(.{ .direction = .row, .width = .fill, .gap = 6, .align_items = .center, .padding = .{ .left = 12, .right = 6, .top = 6, .bottom = 6 }, .background = p.ground }, "kea.web_panel.head");
    headerGesture(b, c, head, .web, true);
    const label = if (b.web_panel_tab) |wt| @import("site_card.zig").site(wt.url()) else "Side Panel";
    ui.text(c, label, .{ .size = 12.5, .weight = .medium, .color = p.ink, .truncate = .ellipsis });
    ui.spacer(c);
    if (controls.door(c, p, "arrow.up.left.and.arrow.down.right", .{ .help = "Open in a Tab" }).clicked) {
        c.end();
        endWithCards(b, c, p, .web, on_left, width, cards);
        keepWebPanelAsTab(b);
        return;
    }
    if (controls.door(c, p, "xmark", .{ .help = "Close Side Panel" }).clicked) {
        c.end();
        endWithCards(b, c, p, .web, on_left, width, cards);
        closeWebPanel(b);
        return;
    }
    c.end();
    _ = c.leaf(.{ .width = .fill, .height = px(1), .background = p.hairline }, .none, null);
    const hole = c.leaf(.{ .width = .fill, .grow = 1 }, .none, "kea.web_panel.hole");
    b.web_panel_hole_node = hole;
    endWithCards(b, c, p, .web, on_left, width, cards);
}

// MARK: a panel's frame

/// A panel's box: `width` wide in its column, or the whole room when let
/// out (its content at most 760 wide, centred) or in a window of its own.
/// Close with `end`.
pub fn begin(c: *ui.Context, p: *const Palette, panel: SidePanel, width: ?f32, expanded: bool) void {
    beginWithCards(c, p, panel, false, width, expanded, false);
}

pub fn beginWithCards(c: *ui.Context, p: *const Palette, panel: SidePanel, on_left: bool, width: ?f32, expanded: bool, cards: bool) void {
    if (width) |w| _ = c.open(.{ .width = px(w), .height = .fill }, null);
    const outer = c.open(.{
        .width = if (width) |w| (if (cards) px(@max(0, w - metrics.card_gap)) else .fill) else .fill,
        .height = .fill,
        .offset = .{ .x = if (width != null and cards and !on_left) metrics.card_gap else 0 },
        .align_items = .center,
        .background = if (panel == .web) null else p.ground,
        .clip = cards,
    }, switch (panel) { .chat => "kea.panel.chat", .bookmarks => "kea.panel.marks", .web => "kea.panel.web" });
    if (cards) card.cardEdge(c, outer);
    // Clicks on the panel are its own, not the page's under a let-out one.
    if (panel != .web) _ = c.interact(outer, .{});
    ui.column(c, .{ .width = .fill, .height = .fill, .max_width = if (expanded and panel == .bookmarks) 760 else std.math.inf(f32) });
}

/// Ends `begin`'s box: in a column, the hairline and the edge on the page's side.
pub fn end(b: *Browser, c: *ui.Context, p: *const Palette, panel: SidePanel, on_left: bool, width: ?f32) void {
    endWithCards(b, c, p, panel, on_left, width, false);
}

pub fn endWithCards(b: *Browser, c: *ui.Context, p: *const Palette, panel: SidePanel, on_left: bool, width: ?f32, cards: bool) void {
    ui.end(c);
    if (width) |w| {
        if (!cards) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = if (on_left) w - 1 else 0 }, .width = px(1), .height = .fill, .background = p.hairline }, .none, null);
        c.end();
        const hw: f32 = if (cards) 16 else 9;
        const hx: f32 = if (on_left) w - hw else 0;
        switch (panel) {
            inline else => |pn| edgeHandleSpan(b, c, p, comptime pn.field(), pn.min(), if (pn == .chat) @max(pn.min(), c.size.w - metrics.page_min) else pn.max(), pn.standard(), on_left, hx, hw),
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
        if (comptime platform.is_ios) {
            const m = nanoui.Menu.create(b.gpa, template) catch return;
            defer m.destroy();
            if (platform.nativeView(s)) |v| m.popup(v, l.at.x, l.at.y);
        } else {
            const m = nanoui.Menu.create(b.gpa, @import("../app/kea.zig").app_name, template) catch return;
            defer m.destroy();
            m.popup(s.nsview, l.at.x, l.at.y);
        }
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
    edgeHandleSpan(b, c, p, field, min, max, standard, grows_right, x, 9);
}
pub fn followEdgeDrag(b: *Browser, c: *ui.Context) void {
    if (!c.input.down) return;
    const d = b.edge_drag orelse return;
    const max_w = if (d.target == .chat_width) @max(SidePanel.chat.min(), c.size.w - metrics.page_min) else d.max;
    const dx = c.input.mouse.x - d.x;
    const next = std.math.clamp(@round(d.width + if (d.grows_right) dx else -dx), d.min, max_w);
    switch (d.target) {
        .none => {},
        inline else => |tg| {
            const cur = &@field(b.prefs.*, @tagName(tg));
            if (@abs(cur.* - next) >= 0.5) {
                cur.* = next;
                c.changed = true;
            }
        },
    }
}


fn edgeHandleSpan(b: *Browser, c: *ui.Context, p: *const Palette, comptime field: []const u8, min: f32, max: f32, standard: f32, grows_right: bool, x: f32, span: f32) void {
    const width = @field(b.prefs.*, field);
    const gap_pad: ui.Edges = if (span > 9) (if (grows_right) .{ .left = span - metrics.card_gap } else .{ .right = span - metrics.card_gap }) else .{};
    const i = c.open(.{ .absolute = true, .offset = .{ .x = x }, .width = px(span), .height = .fill, .padding = gap_pad, .align_items = .center, .justify = .center }, field ++ ".edge");
    const it = c.interact(i, .{});
    c.adjustable(i, .{ .role = .splitter, .label = "Column width", .value = c.print("{d}", .{@round(width)}) });
    if (it.a11y_step != 0) {
        b.prefs.set(field, std.math.clamp(width + 10 * @as(f32, @floatFromInt(it.a11y_step)), min, max));
        c.changed = true;
    }
    if (it.hovered or it.pressed) c.cursor = .resize_left_right;
    if (it.hovered and c.input.pressed) b.edge_drag = .{ .id = it.id, .x = c.input.mouse.x, .width = width, .min = min, .max = max, .grows_right = grows_right, .target = comptime (std.meta.stringToEnum(EdgeField, field) orelse .none) };
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
    const active = it.hovered or (b.edge_drag != null and b.edge_drag.?.id == it.id);
    const a = motion.quickTo(c, it.id, 1, if (active) 1 else 0);
    if (a > 0.001) {
        const h_px: f32 = 28 + 8 * a;
        _ = c.leaf(.{ .width = px(4), .height = px(h_px), .radius = 2, .background = p.muted.alpha(0.55 + 0.35 * a) }, .none, null);
    }
    c.end();
}
