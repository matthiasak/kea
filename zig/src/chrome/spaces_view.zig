//! Spaces on screen (Spaces.swift:343-607, SpaceSwipe.swift:209-353): the
//! dot that stands for the space on screen and opens its menu, the name
//! shown for a moment after a switch, the card a new space is made with,
//! and the questions the menu asks as sheets on the window.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const data = @import("../data/spaces.zig");
const Uuid = @import("../data/json.zig").Uuid;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");
const controls = @import("controls.zig");
const overlays = @import("overlays.zig");
const tab_menu = @import("tab_menu.zig");
const space_swipe = @import("space_swipe.zig");
const appkit = @import("../sys/appkit.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// `SpaceDot.width`.
pub const dot_width: f32 = 26;
/// How long the name stays after a switch.
pub const name_shown: f64 = 1.4;

/// What the dot and the card keep between frames (on `Browser.spaces_ui`).
pub const State = struct {
    /// The space the dot last showed, and what it wore then.
    seen: ?Uuid = null,
    shown_key: u64 = 0,
    shown_symbol: []const u8 = "",
    /// The icon turning over: the one going, and how many turns so far.
    going_symbol: []const u8 = "",
    turns: u32 = 0,
    /// The name shown beside the dot, and until when.
    named: ?Uuid = null,
    named_until: f64 = 0,
    // The new space's card.
    card_open: bool = false,
    name: ui.TextBuffer = .{},
    icon: []const u8 = "briefcase",
    /// 0: signed in where the other spaces are; 1: signed out.
    shared: usize = 0,
    /// Swipe: the fingers' travel while a gesture is this window's, and
    /// the slide under way once let go (`SpaceSwipe.slide`).
    slide: ?space_swipe.Slide = null,
    settling: bool = false,
    /// The name field takes the keys on the next frame it is drawn.
    focus_name: bool = false,

    pub fn deinit(s: *State) void {
        s.name.deinit();
    }
};

// MARK: the dot

/// `SpaceDot`: the space's icon; a click opens the space's menu.
pub fn spaceDot(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.spaces_ui;
    const here = b.space();
    const symbol = if (b.making_space) "plus" else here.symbol();
    const key = if (b.making_space) 1 else std.hash.Wyhash.hash(here.id.bytes[0], symbol) ^ std.hash.Wyhash.hash(0, &here.id.bytes);
    if (st.shown_key == 0) {
        st.shown_key = key;
        st.shown_symbol = symbol;
    } else if (key != st.shown_key) {
        st.going_symbol = st.shown_symbol;
        st.shown_key = key;
        st.shown_symbol = symbol;
        st.turns +%= 1;
    }
    // The name, the moment you get there (not for the card).
    if (st.seen) |seen| if (!seen.eql(b.space_id)) if (!b.making_space) {
        st.named = b.space_id;
        st.named_until = c.time + name_shown;
    };
    st.seen = b.space_id;

    const side = b.prefs.sidebar;
    const i = c.open(.{ .width = px(dot_width), .height = px(26), .radius = 8, .clip = true, .control = true }, "space-dot");
    const it = c.interact(i, .{});
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = p.hover.alpha(h);
    c.help(i, c.print("{s} — ⌃1–⌃9, or two fingers {s} over the tabs, to switch", .{ here.name, if (side) "sideways" else "up or down" }));
    c.addA11y(i, .menu_button, here.name, "", false, true);
    const ink = p.muted.mix(p.ink, h);
    // Turning over the way the spaces went: sideways in the column, up for
    // the next space in the bar, down going back.
    const g: f32 = @floatFromInt(st.turns);
    const t = std.math.clamp(1 - (g - ui.tween(c, it.id, 1, g, 0.22, .ease_out)), 0, 1);
    const dir: f32 = if (b.space_step > 0) 1 else -1;
    if (t < 1) dotIcon(c, st.going_symbol, ink, side, -t * dot_width * dir);
    dotIcon(c, st.shown_symbol, ink, side, (1 - t) * dot_width * dir);
    c.end();
    if (it.clicked) tab_menu.later(b, c.input.mouse, 0, menuItems);
    nameCapsule(b, c, p, side);
}

fn dotIcon(c: *ui.Context, symbol: []const u8, ink: ui.Color, side: bool, shift: f32) void {
    _ = c.open(.{
        .absolute = true,
        .width = .fill,
        .height = .fill,
        .align_items = .center,
        .justify = .center,
        .offset = if (side) .{ .x = shift } else .{ .y = shift },
    }, null);
    ui.icon(c, symbol, .{ .size = 12, .weight = .medium, .color = ink });
    c.end();
}

/// The name beside the icon that stands for it: right of it in the bar,
/// above it at the column's foot; taking no click, moving nothing.
fn nameCapsule(b: *Browser, c: *ui.Context, p: *const Palette, side: bool) void {
    const st = &b.spaces_ui;
    const showing = st.named != null and c.time < st.named_until;
    if (st.named != null and showing) c.frameIn(@floatCast(st.named_until - c.time));
    const k = c.peekId("space-name");
    const v = motion.quickTo(c, k, 0, if (showing) 1 else 0);
    if (v <= 0) {
        if (!showing) st.named = null;
        return;
    }
    const id = st.named orelse return;
    const name = (b.kea.spaces.value[b.kea.spaceIndex(id) orelse return]).name;
    const i = c.open(.{
        .absolute = true,
        .offset = if (side) .{ .y = -30 } else .{ .x = dot_width + 4 },
        .padding = .xy(9, 5),
        .radius = controls.capsule,
        .background = p.ground,
        .border = p.hairline,
        .shadow = card.swiftShadow(0.10, 10, 3),
        .opacity = v,
        .scale = 0.94 + 0.06 * v,
        .scale_anchor = if (side) .{ .x = 0, .y = 1 } else .{ .x = 0, .y = 0.5 },
    }, "space-name");
    _ = i;
    ui.text(c, name, .{ .size = 11.5, .weight = .medium, .color = p.ink });
    c.end();
}

// MARK: the menu (`SpaceMenu`)

const Pick = struct {
    kea: *Kea,
    record: Uuid,
    space: Uuid,
    what: union(enum) { go, new, rename, icon: []const u8, left: usize, right: usize, folder, settings_folder, delete },

    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const b = browserOf(self.kea, self.record) orelse return;
        switch (self.what) {
            .go => b.switchSpace(self.space),
            .new => space_swipe.askForSpace(b),
            .rename => ask(b, .rename, self.space),
            .icon => |s| b.setSpaceIcon(self.space, s),
            .left => |at| b.moveSpace(self.space, at - 1),
            .right => |at| b.moveSpace(self.space, at + 1),
            .folder => askFolder(b, self.space),
            .settings_folder => b.setSpaceDownloads(self.space, null),
            .delete => ask(b, .delete, self.space),
        }
        b.redraw();
    }
};

fn browserOf(kea: *Kea, record: Uuid) ?*Browser {
    for (kea.browsers.items) |b| if (b.record_id.eql(record)) return b;
    return null;
}

/// The dot's menu: the spaces, then what can be done to the one on screen.
pub fn menuItems(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const nanoui.MenuItem {
    var out: std.ArrayList(nanoui.MenuItem) = .empty;
    const spaces = b.kea.spaces.value;
    const here = b.space();
    const P = struct {
        fn item(a: std.mem.Allocator, br: *Browser, label: []const u8, space: Uuid, what: @FieldType(Pick, "what")) !nanoui.MenuItem {
            const chosen = try a.create(Pick);
            chosen.* = .{ .kea = br.kea, .record = br.record_id, .space = space, .what = what };
            return .{ .label = label, .click = .of(chosen, Pick.fire) };
        }
    };
    for (spaces, 0..) |s, n| {
        var it = try P.item(arena, b, s.name, s.id, .go);
        if (n < 9) it.accelerator = try std.fmt.allocPrint(arena, "Ctrl+{d}", .{n + 1});
        it.checked = s.id.eql(b.space_id);
        it.kind = .checkbox;
        it.image_symbol = s.symbol();
        try out.append(arena, it);
    }
    try out.append(arena, .separator);
    try out.append(arena, try P.item(arena, b, "New Space…", here.id, .new));
    try out.append(arena, .separator);
    try out.append(arena, try P.item(arena, b, try std.fmt.allocPrint(arena, "Rename “{s}”…", .{here.name}), here.id, .rename));
    var icons = try arena.alloc(nanoui.MenuItem, data.icons.len);
    for (data.icons, data.icon_names, 0..) |symbol, name, n| {
        icons[n] = try P.item(arena, b, name, here.id, .{ .icon = symbol });
        icons[n].kind = .checkbox;
        icons[n].checked = std.mem.eql(u8, here.symbol(), symbol);
        icons[n].image_symbol = symbol;
    }
    try out.append(arena, .{ .label = "Icon", .submenu = icons });
    // The order is the swipe's, and ⌃1–⌃9's.
    if (b.kea.spaceIndex(here.id)) |at| {
        if (at > 0) try out.append(arena, try P.item(arena, b, "Move Left", here.id, .{ .left = at }));
        if (at < spaces.len - 1) try out.append(arena, try P.item(arena, b, "Move Right", here.id, .{ .right = at }));
    }
    const folder = if (here.downloads) |d| std.fs.path.basename(d) else null;
    try out.append(arena, try P.item(arena, b, if (folder) |f| try std.fmt.allocPrint(arena, "Downloads to “{s}”…", .{f}) else "Downloads Folder…", here.id, .folder));
    if (folder != null) try out.append(arena, try P.item(arena, b, "Downloads to the Folder in Settings", here.id, .settings_folder));
    if (!here.isFirst()) {
        try out.append(arena, .separator);
        try out.append(arena, try P.item(arena, b, try std.fmt.allocPrint(arena, "Delete “{s}”…", .{here.name}), here.id, .delete));
    }
    return out.items;
}

// MARK: the questions (`Ask`)

const Asked = struct {
    kea: *Kea,
    record: Uuid,
    space: Uuid,
    kind: enum { rename, delete, new },

    fn done(self: *Asked, a: appkit.Answer) void {
        defer std.heap.c_allocator.destroy(self);
        const b = browserOf(self.kea, self.record) orelse return;
        switch (self.kind) {
            .rename => if (a.ok and a.text.len > 0) b.renameSpace(self.space, a.text),
            .delete => if (a.ok) b.deleteSpace(self.space),
            .new => if (a.ok and a.text.len > 0) b.addSpace(a.text, null, !a.checked) else space_swipe.cancelSpaceCreation(b),
        }
        b.redraw();
    }

    fn folder(self: *Asked, path: ?[]const u8) void {
        defer std.heap.c_allocator.destroy(self);
        const b = browserOf(self.kea, self.record) orelse return;
        if (path) |f| b.setSpaceDownloads(self.space, f);
    }
};

fn asked(b: *Browser, kind: @FieldType(Asked, "kind"), space: Uuid) ?*Asked {
    const a = std.heap.c_allocator.create(Asked) catch return null;
    a.* = .{ .kea = b.kea, .record = b.record_id, .space = space, .kind = kind };
    return a;
}

fn window(b: *Browser) ?objc.Object {
    return if (b.window) |w| w.nswindow else null;
}

pub fn ask(b: *Browser, kind: @FieldType(Asked, "kind"), space: Uuid) void {
    const a = asked(b, kind, space) orelse return;
    const s = b.kea.spaces.value[b.kea.spaceIndex(space) orelse 0];
    var title_buf: [256]u8 = undefined;
    const q: appkit.Question = switch (kind) {
        .rename => .{ .title = "Rename Space", .field = .{ .placeholder = s.name, .initial = s.name }, .confirm = "Rename" },
        .delete => .{
            .title = std.fmt.bufPrint(&title_buf, "Delete “{s}”?", .{s.name}) catch "Delete Space?",
            .detail = "Its tabs close, and its cookies and sign-ins are erased from this Mac. History and bookmarks stay.",
            .confirm = "Delete",
            .destructive = true,
        },
        .new => .{
            .title = "New Space",
            .detail = "Its own tabs. Signed in where your other spaces are, unless it starts afresh.",
            .field = .{ .placeholder = "Work" },
            .checkbox = "Start signed out, with its own cookies",
            .confirm = "Create",
        },
    };
    appkit.ask(window(b), q, a, Asked.done);
}

fn askFolder(b: *Browser, space: Uuid) void {
    const w = window(b) orelse return;
    const a = asked(b, .rename, space) orelse return;
    appkit.askFolder(w, "Use for This Space", "Downloads in this space go here. Cancel keeps the folder it has.", a, Asked.folder);
}

// MARK: the card (`NewSpaceCard`)

/// A new space, made where the next one would have been: its name, its
/// icon, signed in or not, and on its way. `inline` is the bar's one row.
pub fn newSpaceCard(b: *Browser, c: *ui.Context, p: *const Palette, inline_: bool) void {
    const st = &b.spaces_ui;
    if (!st.card_open) {
        st.card_open = true;
        st.icon = b.freeIcon();
        st.name.clear();
        st.shared = 0;
        st.focus_name = true;
    }
    const saying = if (st.shared == 0) "Signed in wherever your other spaces are." else "Its own cookies and sign-ins, starting from none.";
    const options = [_][]const u8{ "Signed in", "Signed out" };
    if (inline_) {
        _ = c.open(.{ .direction = .row, .gap = 8, .height = px(52), .align_items = .center }, "new-space");
        pick(b, c, p, 13, .{ .w = 28, .h = 26 }, true);
        field(b, c, p, true);
        const seg = c.open(.{}, null);
        _ = controls.segmented(c, p, &options, &st.shared, false);
        c.help(seg, saying);
        c.end();
        buttons(b, c, p);
        c.end();
    } else {
        _ = c.open(.{ .direction = .column, .gap = 12, .padding = .all(16), .width = .fill, .align_items = .center }, "new-space");
        pick(b, c, p, 20, .{ .w = 44, .h = 40 }, false);
        _ = c.open(.{ .direction = .column, .gap = 4, .align_items = .center }, null);
        ui.text(c, "New space", .{ .size = 13, .weight = .semibold, .color = p.ink });
        ui.text(c, "Its own tabs.", .{ .size = 11, .color = p.muted });
        c.end();
        field(b, c, p, false);
        _ = c.open(.{ .direction = .column, .gap = 6, .width = .fill, .align_items = .center }, null);
        _ = controls.segmented(c, p, &options, &st.shared, true);
        ui.text(c, saying, .{ .size = 11, .color = p.muted, .wrap = true });
        c.end();
        _ = c.open(.{ .direction = .row, .gap = 8 }, null);
        buttons(b, c, p);
        c.end();
        c.end();
    }
}

fn buttons(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (controls.pill(c, p, "Cancel", .{}).clicked) cancel(b);
    if (controls.pill(c, p, "Create", .{ .filled = true }).clicked) create(b, c);
}

fn pick(b: *Browser, c: *ui.Context, p: *const Palette, size: f32, box: ui.Size, inline_: bool) void {
    const st = &b.spaces_ui;
    const choosing = if (b.overlay) |o| o == .space_icons else false;
    const i = c.open(.{ .width = px(box.w), .height = px(box.h), .radius = if (inline_) 8 else 10, .align_items = .center, .justify = .center, .control = true }, "space-pick");
    const it = c.interact(i, .{});
    c.help(i, if (inline_) "New space — choose its icon" else "Choose an icon");
    c.addA11y(i, .button, "Choose an icon", "", false, true);
    c.node(i).style.background = if (it.hovered or choosing) p.hover else null;
    ui.icon(c, st.icon, .{ .size = size, .weight = .medium, .color = p.ink });
    c.end();
    if (it.clicked) {
        b.overlay = .space_icons;
        if (it.rect) |r| b.overlay_anchor = r;
    }
}

fn field(b: *Browser, c: *ui.Context, p: *const Palette, inline_: bool) void {
    const st = &b.spaces_ui;
    _ = c.open(.{ .padding = .xy(10, 0), .width = if (inline_) px(170) else .fill, .height = px(if (inline_) 26 else 30), .radius = 8, .background = p.wash, .justify = .center }, null);
    const size: f32 = if (inline_) 12.5 else 13;
    if (st.name.text().len == 0) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 10 }, .height = .fill, .justify = .center }, .{ .text = .{ .str = if (inline_) "New space" else "Name", .style = .{ .size = size }, .color = p.ink.alpha(0.3) } }, null);
    if (st.focus_name) {
        st.focus_name = false;
        ui.focusNext(c, false);
    }
    const res = ui.textField(c, &st.name, .{ .bare = true, .size = size, .width = .fill, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
    c.end();
    if (res.submitted) create(b, c);
}

/// Every icon, six to a row, the chosen one on a grey of its own; picking
/// one puts the list away (the card's popover, `Overlay.space_icons`).
pub fn iconsPopover(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.spaces_ui;
    _ = c.open(.{ .direction = .column, .gap = 4, .padding = .all(10) }, null);
    defer c.end();
    var n: usize = 0;
    while (n < data.icons.len) : (n += 6) {
        _ = c.open(.{ .direction = .row, .gap = 4 }, null);
        for (data.icons[n..@min(n + 6, data.icons.len)], data.icon_names[n..@min(n + 6, data.icons.len)]) |symbol, name| {
            const on = std.mem.eql(u8, symbol, st.icon);
            const i = c.open(.{ .width = px(28), .height = px(28), .radius = 7, .align_items = .center, .justify = .center, .background = if (on) p.wash else null, .control = true }, null);
            const it = c.interact(i, .{});
            c.help(i, name);
            c.addA11y(i, .button, name, "", on, true);
            ui.icon(c, symbol, .{ .size = 13, .weight = .medium, .color = if (on) p.ink else p.muted });
            c.end();
            if (it.clicked) {
                st.icon = symbol;
                b.overlay = null;
                st.focus_name = true;
                c.changed = true;
            }
        }
        c.end();
    }
}

fn create(b: *Browser, c: *ui.Context) void {
    const st = &b.spaces_ui;
    const named = std.mem.trim(u8, st.name.text(), " \t\r\n");
    if (named.len == 0) {
        st.focus_name = true;
        return;
    }
    const copy = b.gpa.dupe(u8, named) catch return;
    defer b.gpa.free(copy);
    st.card_open = false;
    b.addSpace(copy, st.icon, st.shared == 0);
    c.changed = true;
}

/// Back to the space it was made from, the way it came (Esc, from the key monitor).
pub fn cancel(b: *Browser) void {
    b.spaces_ui.card_open = false;
    space_swipe.cancelSpaceCreation(b);
    const back = b.kea.spaceIndex(b.space_id) orelse 0;
    space_swipe.slide(b, back, b.kea.spaces.value.len);
}
