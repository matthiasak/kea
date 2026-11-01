//! Active-tab site/domain display, plain-HTTP warning, and lookalike/punycode host warning.
const std = @import("std");
const ui = @import("nanoui").ui;
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const tab_menu = @import("tab_menu.zig");
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const Parts = @import("../data/url.zig").Parts;

/// True if `host` uses punycode (`xn--`) or mixes non-ASCII bytes with ASCII letters in any label.
pub fn isLookalikeHost(host: []const u8) bool {
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (std.ascii.startsWithIgnoreCase(label, "xn--")) return true;
        var has_ascii = false;
        var has_non_ascii = false;
        for (label) |ch| {
            if (ch >= 0x80) has_non_ascii = true else if (std.ascii.isAlphabetic(ch)) has_ascii = true;
        }
        if (has_ascii and has_non_ascii) return true;
    }
    return false;
}

pub fn draw(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, live: bool, hovered: bool, colour: ui.Color, size: f32, fade: ?ui.Fade) void {
    const fallback = if (t.label().len == 0) "New Tab" else t.label();
    if (!hovered and !t.isBlank()) addr: {
        const u = t.url();
        const k = t.url_cache.of(u);
        if (!k.parsed) break :addr;
        const bare = k.bare(u);
        const plain_http = k.plain_http;
        const custom_named = t.name != null and t.name.?.len > 0;
        const show_addr = live and b.prefs.shows_tab_address and !custom_named;
        if (k.is_file and show_addr) {
            const base = k.base(u);
            if (base.len > 0) {
                ui.text(c, base, .{ .size = size, .color = colour, .truncate = .ellipsis, .fade = fade });
                return;
            }
        } else if (k.is_web and bare.len > 0 and (plain_http or k.lookalike or show_addr)) {
            const reg = k.site(c.alloc(), bare);
            if (plain_http) {
                const prefix = "Not secure — ";
                const full = c.print("{s}{s}", .{ prefix, reg });
                const spans = c.alloc().dupe(ui.Span, &.{.{ .start = 0, .end = @intCast(prefix.len), .color = p.muted }}) catch &.{};
                ui.richText(c, full, spans, .{ .size = size, .color = colour, .truncate = .ellipsis, .fade = fade });
                return;
            }
            if (bare.len > reg.len and std.ascii.endsWithIgnoreCase(bare, reg) and bare[bare.len - reg.len - 1] == '.') {
                const sub_len = bare.len - reg.len;
                const spans = c.alloc().dupe(ui.Span, &.{.{ .start = 0, .end = @intCast(sub_len), .color = p.muted }}) catch &.{};
                ui.richText(c, bare, spans, .{ .size = size, .color = colour, .truncate = .ellipsis, .fade = fade });
                return;
            }
            ui.text(c, bare, .{ .size = size, .color = colour, .truncate = .ellipsis, .fade = fade });
            return;
        }
    }
    ui.text(c, fallback, .{ .size = size, .color = colour, .truncate = .ellipsis, .fade = fade });
}

/// ⌘1–8's tabs and ⌘9's (the last), each with its split's right page, for
/// this frame while ⌘ is held (`window_view.view`): `cmdSlot` only looks.
pub fn cmdSlots(b: *Browser, arena: std.mem.Allocator) void {
    b.cmd_slots = @splat(null);
    if (!b.prefs.shows_cmd_numbers or !b.cmd_held) return;
    const shown = b.shownTabs(arena) catch return;
    for (shown, 0..) |st, idx| {
        const slot: usize = if (idx < 8) idx else if (idx == shown.len - 1) 8 else continue;
        b.cmd_slots[slot * 2] = st.id;
        b.cmd_slots[slot * 2 + 1] = if (b.splitFor(st)) |sp| sp.right() else null;
    }
}

pub fn cmdSlot(b: *const Browser, tab: *const Tab) ?u8 {
    if (!b.prefs.shows_cmd_numbers or !b.cmd_held) return null;
    for (b.cmd_slots, 0..) |id, k| if (id) |v| if (v == tab.id) return @intCast(k / 2 + 1);
    return null;
}

pub fn drawCmdBadge(b: *Browser, c: *ui.Context, p: *const Palette, tab: *const Tab) void {
    const slot = cmdSlot(b, tab) orelse return;
    ui.text(c, c.print("⌘{d}", .{slot}), .{ .size = 10.5, .weight = .medium, .color = p.muted, .tabular = true });
}

const NavPick = struct {
    b: *Browser,
    is_fwd: bool,
    idx: usize,
    from_origin: bool = false,
    is_reload: bool = false,

    fn fire(self: *NavPick, _: *nanoui.menu.Item) void {
        const tab = self.b.activeTab() orelse return;
        if (self.is_reload) {
            tab.reload(self.from_origin);
            return;
        }
        const wv = tab.web orelse return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const bfl = objc.msg(?objc.Object, wv, "backForwardList", .{}) orelse return;
        const list = objc.msg(?objc.Object, bfl, if (self.is_fwd) "forwardList" else "backList", .{}) orelse return;
        const count = objc.msg(objc.NSUInteger, list, "count", .{});
        if (self.idx >= count) return;
        const item = objc.msg(objc.Object, list, "objectAtIndex:", .{self.idx});
        _ = objc.msg(?objc.Object, wv, "goToBackForwardListItem:", .{item});
    }
};

pub fn backMenu(arena: std.mem.Allocator, b: *Browser, is_fwd_u64: u64) anyerror![]const nanoui.MenuItem {
    const is_fwd = is_fwd_u64 != 0;
    const tab = b.activeTab() orelse return &.{};
    const wv = tab.web orelse return &.{};
    const pool = objc.Pool.push();
    defer pool.pop();
    const bfl = objc.msg(?objc.Object, wv, "backForwardList", .{}) orelse return &.{};
    const list = objc.msg(?objc.Object, bfl, if (is_fwd) "forwardList" else "backList", .{}) orelse return &.{};
    const count = objc.msg(objc.NSUInteger, list, "count", .{});
    if (count == 0) return &.{};
    var out: std.ArrayList(nanoui.MenuItem) = .empty;
    for (0..count) |k| {
        const idx = if (is_fwd) k else count - 1 - k;
        const item = objc.msg(objc.Object, list, "objectAtIndex:", .{idx});
        const title_raw = objc.fromNSString(objc.msg(?objc.Object, item, "title", .{}));
        const u_obj = objc.msg(?objc.Object, item, "URL", .{});
        const url_raw = if (u_obj) |u| objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{})) else "";
        const label = try arena.dupe(u8, if (title_raw.len > 0) title_raw else if (url_raw.len > 0) @import("site_card.zig").site(url_raw) else "Page");
        const png = if (b.kea.favicons.icon(url_raw)) |ic| ic.png else "";
        const pick = try arena.create(NavPick);
        pick.* = .{ .b = b, .is_fwd = is_fwd, .idx = idx };
        try out.append(arena, .{ .label = label, .image_png = png, .click = .of(pick, NavPick.fire) });
    }
    return out.items;
}

pub fn reloadMenu(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const nanoui.MenuItem {
    const out = try arena.alloc(nanoui.MenuItem, 2);
    for ([_]bool{ false, true }, [_][]const u8{ "Reload Page", "Reload Page From Origin" }, 0..) |origin, label, i| {
        const pick = try arena.create(NavPick);
        pick.* = .{ .b = b, .is_fwd = false, .idx = 0, .is_reload = true, .from_origin = origin };
        out[i] = .{ .label = label, .click = .of(pick, NavPick.fire) };
    }
    return out;
}

pub fn helmAction(b: *Browser, c: *ui.Context, tab: *Tab, back_it: ui.Interaction, back_on: bool, fwd_it: ui.Interaction, fwd_on: bool, rel_it: ui.Interaction, loading: bool) void {
    const anchor = struct {
        fn pt(it: ui.Interaction, fallback: ui.Point) ui.Point {
            return if (it.rect) |r| .{ .x = r.x, .y = r.y + r.h + 4 } else fallback;
        }
    }.pt;
    if (back_on) {
        if (back_it.right_clicked) {
            tab_menu.later(b, anchor(back_it, c.input.mouse), 0, backMenu);
        } else if (back_it.pressed) {
            if (b.helm_hold_at == null or b.helm_hold_fwd) {
                b.helm_hold_at = c.time;
                b.helm_hold_fwd = false;
                c.frameIn(0.28);
            } else if (c.time - b.helm_hold_at.? >= 0.28 and c.time - b.helm_hold_at.? < 500) {
                b.helm_hold_at = c.time - 1000;
                tab_menu.later(b, anchor(back_it, c.input.mouse), 0, backMenu);
            } else if (c.time - b.helm_hold_at.? < 0.28) {
                c.frameIn(@floatCast(@max(0.01, 0.28 - (c.time - b.helm_hold_at.?))));
            }
        } else if (back_it.clicked) {
            if (b.helm_hold_at == null or c.time - b.helm_hold_at.? < 0.28) tab.goBack();
        }
    }
    if (fwd_on) {
        if (fwd_it.right_clicked) {
            tab_menu.later(b, anchor(fwd_it, c.input.mouse), 1, backMenu);
        } else if (fwd_it.pressed) {
            if (b.helm_hold_at == null or !b.helm_hold_fwd) {
                b.helm_hold_at = c.time;
                b.helm_hold_fwd = true;
                c.frameIn(0.28);
            } else if (c.time - b.helm_hold_at.? >= 0.28 and c.time - b.helm_hold_at.? < 500) {
                b.helm_hold_at = c.time - 1000;
                tab_menu.later(b, anchor(fwd_it, c.input.mouse), 1, backMenu);
            } else if (c.time - b.helm_hold_at.? < 0.28) {
                c.frameIn(@floatCast(@max(0.01, 0.28 - (c.time - b.helm_hold_at.?))));
            }
        } else if (fwd_it.clicked) {
            if (b.helm_hold_at == null or c.time - b.helm_hold_at.? < 0.28) tab.goForward();
        }
    }
    if (!back_it.pressed and !fwd_it.pressed) b.helm_hold_at = null;
    if (!tab.isBlank()) {
        if (rel_it.right_clicked and !loading) {
            tab_menu.later(b, anchor(rel_it, c.input.mouse), 0, reloadMenu);
        } else if (rel_it.clicked) {
            if (loading) tab.stopLoading() else tab.reload(false);
        }
    }
}

const PopupPick = struct {
    b: *Browser,
    tab_id: u64,
    idx: ?usize,

    fn fire(self: *PopupPick, _: *nanoui.menu.Item) void {
        const b = self.b;
        const tab = b.tabById(self.tab_id) orelse return;
        if (self.idx) |i| {
            if (i < tab.blocked_popups.items.len) {
                const u = tab.blocked_popups.orderedRemove(i);
                defer tab.gpa.free(u);
                _ = b.open(u, .{ .foreground = true, .from = tab });
            }
        } else {
            const host = if (Parts.parse(tab.url())) |p| p.hostName() orelse "" else "";
            @import("../web/delegates_ui.zig").setPopupAllowed(&b.kea.store, true, host);
            for (tab.blocked_popups.items) |u| {
                _ = b.open(u, .{ .foreground = true, .from = tab });
            }
            tab.clearBlockedPopups();
        }
        b.redraw();
    }
};

pub fn popupMenu(arena: std.mem.Allocator, b: *Browser, tab_id: u64) anyerror![]const nanoui.MenuItem {
    const tab = b.tabById(tab_id) orelse return &.{};
    if (tab.blocked_popups.items.len == 0) return &.{};
    var out: std.ArrayList(nanoui.MenuItem) = .empty;
    for (tab.blocked_popups.items, 0..) |u, i| {
        const pick = try arena.create(PopupPick);
        pick.* = .{ .b = b, .tab_id = tab_id, .idx = i };
        const label = try std.fmt.allocPrint(arena, "Open “{s}”", .{u});
        try out.append(arena, .{ .label = label, .click = .of(pick, PopupPick.fire) });
    }
    const host = if (Parts.parse(tab.url())) |p| p.hostName() orelse "" else "";
    if (host.len > 0) {
        try out.append(arena, .separator);
        const pick = try arena.create(PopupPick);
        pick.* = .{ .b = b, .tab_id = tab_id, .idx = null };
        const label = try std.fmt.allocPrint(arena, "Always Allow Pop-ups from {s}", .{host});
        try out.append(arena, .{ .label = label, .click = .of(pick, PopupPick.fire) });
    }
    return out.items;
}

pub fn drawPopupBadge(b: *Browser, c: *ui.Context, p: *const Palette, tab: *Tab, interactive: bool) void {
    if (tab.blocked_popups.items.len == 0) return;
    const i = c.open(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 }, .radius = 4, .align_items = .center, .justify = .center, .control = interactive }, null);
    defer c.end();
    const it = if (interactive) c.interact(i, .{}) else ui.Interaction{ .id = 0, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };
    if (interactive) {
        c.help(i, "Pop-up blocked");
        if (it.hovered) c.node(i).style.background = p.hover;
        if (it.clicked) tab_menu.later(b, c.input.mouse, tab.id, popupMenu);
    }
    ui.icon(c, "uiwindow.split.2x1", .{ .size = 10, .color = p.muted });
}
test "lookalike host detection" {
    try std.testing.expect(isLookalikeHost("xn--pple-43d.com"));
    try std.testing.expect(isLookalikeHost("аpple.com")); // Cyrillic 'а' + ASCII "pple"
    try std.testing.expect(!isLookalikeHost("docs.github.com"));
}
