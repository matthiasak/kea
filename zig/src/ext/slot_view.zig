//! `ExtensionSlot` (Extensions.swift 1685-1922): the pinned extensions'
//! buttons and the puzzle button, in the strip's far end or the column's
//! foot, and the list the puzzle button opens (`ExtensionMenu`, an overlay
//! of the window: `chrome/overlays.zig` `.extension_menu`). Each button's
//! place is handed to the controller every frame (`setAnchor`), so a popup
//! hangs from it. Nothing shows below macOS 15.4 (no `kea.ext`) or with
//! nothing installed.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("../chrome/controls.zig");
const overlays = @import("../chrome/overlays.zig");
const tab_menu = @import("../chrome/tab_menu.zig");
const appkit = @import("../sys/appkit.zig");
const controller = @import("controller.zig");
const Extensions = controller.Extensions;
const buttons = @import("controller_buttons.zig");
const Button = buttons.Button;
const store_relay = @import("store_relay.zig");
const ui_icons = @import("ui_icons.zig");

fn px(v: f32) ui.Length {
    return .{ .px = v };
}

/// The list is open over this window.
pub fn isOpen(b: *const Browser) bool {
    return if (b.overlay) |o| o == .extension_menu else false;
}

fn close(b: *Browser, e: *Extensions) void {
    if (isOpen(b)) b.overlay = null;
    e.del.menu_open = false;
    b.redraw();
}

/// Where the list hangs: out to the right of the column's foot, down from the strip.
pub fn place(b: *const Browser) overlays.Place {
    return .{ .edge = if (b.prefs.sidebar) .trailing else .below, .alignment = .center };
}

/// `ExtensionButtons`: up to `room` pinned buttons (all of them when null),
/// then the puzzle button.
pub fn slot(b: *Browser, c: *ui.Context, p: *const Palette, room: ?usize) void {
    const e = b.kea.ext orelse return;
    if (e.installed.items.len == 0) return;
    const a = c.alloc();
    const list = buttons.buttons(e, a) catch return;
    defer buttons.freeButtons(a, list);
    const win: ?objc.Object = if (b.window) |w| w.nswindow else null;
    // A button not drawn this frame has no place to hang a popup from.
    if (win != null) for (e.del.anchors.values()) |*an| if (an.window == win) {
        an.window = null;
    };
    if (e.browser() == b) e.del.menu_open = isOpen(b);
    ui.row(c, .{ .gap = 2, .align_items = .center });
    defer ui.end(c);
    var shown: usize = 0;
    for (list) |btn| {
        if (!btn.pinned) continue;
        if (room) |r| if (shown >= r) break;
        shown += 1;
        ui.key(c, btn.id);
        actionButton(b, e, c, p, btn, win);
    }
    const it = controls.door(c, p, "puzzlepiece.extension", .{ .on = isOpen(b), .help = "Extensions" });
    if (it.rect) |r| {
        anchor(e, buttons.menu_anchor, win, r);
        if (isOpen(b)) b.overlay_anchor = r;
    }
    if (it.clicked) {
        if (isOpen(b)) close(b, e) else {
            b.overlay = .extension_menu;
            if (it.rect) |r| b.overlay_anchor = r;
            e.del.menu_open = true;
        }
        c.changed = true;
    }
}

fn anchor(e: *Extensions, id: []const u8, win: ?objc.Object, r: ui.Rect) void {
    buttons.setAnchor(e, id, .{ .window = win, .rect = .{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = r.w, .height = r.h } } });
}

fn actionButton(b: *Browser, e: *Extensions, c: *ui.Context, p: *const Palette, btn: Button, win: ?objc.Object) void {
    const i = c.open(.{ .width = px(26), .height = px(26), .radius = 8, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, btn.label);
    c.addA11y(i, .button, btn.label, "", false, true);
    if (it.hovered) c.node(i).style.background = p.hover;
    icon(c, p, e, btn, 15);
    if (it.rect) |r| anchor(e, btn.id, win, r);
    if (it.clicked) pressLater(e, btn.id, 0);
    if (it.right_clicked) actionsMenu(b, c, e, btn.id);
}

/// `ExtensionIcon`: its picture (or its initial on wash), dimmed while
/// switched off, with its badge in the corner.
pub fn icon(c: *ui.Context, p: *const Palette, e: *Extensions, btn: Button, size: f32) void {
    const frame = size + 4;
    _ = c.open(.{ .width = px(frame), .height = px(frame) }, null);
    defer c.end();
    ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .opacity = if (btn.enabled) 1 else 0.4 });
    picture(c, p, e, btn.id, btn.name, btn.icon, size);
    ui.end(c);
    if (btn.badge.len == 0) return;
    const id = c.peekId("badge");
    const was = c.rects.get(id);
    const w: f32 = if (was) |r| r.w else 12;
    const h: f32 = if (was) |r| r.h else 11;
    _ = c.open(.{ .absolute = true, .offset = .{ .x = frame - w + 5, .y = frame - h + 3 }, .padding = .xy(3, 0), .min_width = 12, .min_height = 11, .radius = controls.capsule, .background = p.ink, .align_items = .center, .justify = .center }, "badge");
    ui.text(c, btn.badge, .{ .size = 8, .weight = .semibold, .color = p.ground });
    c.end();
}

/// An extension's picture at `size`, or its initial rather than a puzzle
/// piece that would pass for the button the list opens from.
pub fn picture(c: *ui.Context, p: *const Palette, e: *Extensions, id: []const u8, name: []const u8, image: ?objc.Object, size: f32) void {
    if (image) |img| {
        const key = c.print("{s}@{d}", .{ id, size });
        if (ui_icons.png(key, img, size, e.serial, e.actions_changed)) |bytes| {
            if (ui.image(c, .{ .key = c.print("ext.icon.{s}.{d}.{d}", .{ key, e.serial, e.actions_changed }), .bytes = bytes, .max_width = size, .max_height = size, .radius = 0 })) return;
        }
    }
    _ = c.open(.{ .width = px(size), .height = px(size), .radius = size * 0.28, .background = p.wash, .align_items = .center, .justify = .center }, null);
    defer c.end();
    const n = if (name.len > 0) std.unicode.utf8ByteSequenceLength(name[0]) catch 1 else 0;
    const first = if (n > 0 and n <= name.len) name[0..n] else "?";
    ui.text(c, std.ascii.allocUpperString(c.alloc(), first) catch first, .{ .size = size * 0.62, .weight = .semibold, .color = p.muted });
}

// MARK: pressing

const Later = struct {
    serial: u64,
    id: []u8,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Later = @ptrCast(@alignCast(ctx.?));
        defer {
            std.heap.c_allocator.free(l.id);
            std.heap.c_allocator.destroy(l);
        }
        const e = controller.alive(l.serial) orelse return;
        buttons.press(e, l.id);
    }
};

/// `press(id)` once this frame is done (a popup is a window of its own),
/// or `seconds` later.
fn pressLater(e: *Extensions, id: []const u8, seconds: f64) void {
    const heap = std.heap.c_allocator;
    const l = heap.create(Later) catch return;
    l.* = .{ .serial = e.serial, .id = heap.dupe(u8, id) catch return heap.destroy(l) };
    if (seconds == 0) objc.dispatchMain(l, Later.fire) else objc.dispatchAfter(@intFromFloat(seconds * std.time.ns_per_s), l, Later.fire);
}

// MARK: ExtensionActions

fn actionsMenu(b: *Browser, c: *ui.Context, e: *Extensions, id: []const u8) void {
    const at = e.rowIndex(id) orelse return;
    tab_menu.later(b, c.input.mouse, at, actionItems);
}

const Act = struct {
    b: *Browser,
    id: []const u8,
    name: []const u8,
    what: enum { pin, options, reload, remove },

    fn fire(self: *Act, _: *nanoui.menu.Item) void {
        const e = self.b.kea.ext orelse return;
        const row = e.row(self.id) orelse return;
        switch (self.what) {
            .pin => e.setPinned(self.id, !(row.pinned orelse false)),
            .options => e.openOptions(self.id),
            .reload => e.reload(self.id),
            .remove => confirmRemove(e, self.id, self.name),
        }
    }
};

/// What a right-click on an extension offers, in the row and in the list.
fn actionItems(arena: std.mem.Allocator, b: *Browser, at: u64) anyerror![]const MenuItem {
    const e = b.kea.ext orelse return &.{};
    if (at >= e.installed.items.len) return &.{};
    const row = e.installed.items[@intCast(at)];
    const id = try arena.dupe(u8, row.id);
    const name = try arena.dupe(u8, row.name);
    var out: std.ArrayList(MenuItem) = .empty;
    const Make = struct {
        fn act(a: std.mem.Allocator, bb: *Browser, i: []const u8, n: []const u8, what: @FieldType(Act, "what")) !*Act {
            const x = try a.create(Act);
            x.* = .{ .b = bb, .id = i, .name = n, .what = what };
            return x;
        }
    };
    const pinned = row.pinned orelse false;
    try out.append(arena, .{ .label = if (pinned) "Unpin" else "Pin to Toolbar", .click = .of(try Make.act(arena, b, id, name, .pin), Act.fire) });
    const pool = objc.Pool.push();
    defer pool.pop();
    if (e.context(id)) |ctx| if (objc.msg(?objc.Object, ctx, "optionsPageURL", .{}) != null)
        try out.append(arena, .{ .label = "Options…", .click = .of(try Make.act(arena, b, id, name, .options), Act.fire) });
    try out.append(arena, .{ .label = "Reload", .click = .of(try Make.act(arena, b, id, name, .reload), Act.fire) });
    try out.append(arena, .separator);
    try out.append(arena, .{ .label = try std.fmt.allocPrint(arena, "Remove “{s}”…", .{name}), .click = .of(try Make.act(arena, b, id, name, .remove), Act.fire) });
    return out.items;
}

/// `confirmRemove`: asked first, modally.
pub fn confirmRemove(e: *Extensions, id: []const u8, name: []const u8) void {
    const Ask = struct {
        serial: u64,
        id: []const u8,
        fn answered(self: *@This(), a: appkit.Answer) void {
            if (!a.ok) return;
            if (controller.alive(self.serial)) |x| x.remove(self.id);
        }
    };
    var ask: Ask = .{ .serial = e.serial, .id = id };
    var buf: [400]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "Remove “{s}”?", .{name}) catch return;
    // No window: `runModal`, answered before this returns.
    appkit.ask(null, .{ .title = title, .detail = "Its settings and data go with it.", .confirm = "Remove" }, &ask, Ask.answered);
}

// MARK: ExtensionMenu

/// The list behind the puzzle button, inside the open overlay's box:
/// every running extension, a pin for each, and the way to Settings.
pub fn menu(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const e = b.kea.ext orelse {
        b.overlay = null;
        return;
    };
    ui.column(c, .{ .width = px(280) });
    defer ui.end(c);
    const a = c.alloc();
    const list: []Button = buttons.buttons(e, a) catch &.{};
    defer buttons.freeButtons(a, list);
    if (list.len == 0) {
        ui.column(c, .{ .width = .fill, .padding = .all(14) });
        ui.text(c, "None of your extensions is on — all asleep on the perch", .{ .size = 12.5, .color = p.muted, .wrap = true });
        ui.end(c);
    } else {
        ui.scroll(c, .{ .width = .fill, .max_height = 360, .gap = 1, .padding = .all(6) });
        for (list) |btn| {
            ui.key(c, btn.id);
            menuRow(b, e, c, p, btn);
        }
        ui.end(c);
    }
    _ = c.leaf(.{ .width = .fill, .height = px(1), .background = p.hairline }, .none, null);
    ui.column(c, .{ .width = .fill, .gap = 1, .padding = .all(6) });
    defer ui.end(c);
    if (foot(c, p, "storefront", "Chrome Web Store…")) {
        close(b, e);
        if (e.browser()) |x| _ = x.open(store_relay.web_store, .{ .foreground = true });
    }
    if (foot(c, p, "folder", "Load Unpacked…")) {
        close(b, e);
        objc.dispatchMain(@ptrFromInt(e.serial), loadUnpacked);
    }
    if (foot(c, p, "gearshape", "Manage Extensions…")) {
        close(b, e);
        if (e.browser()) |x| @import("../chrome/settings/frame.zig").open(x, .extensions);
    }
}

fn loadUnpacked(ctx: ?*anyopaque) callconv(.c) void {
    if (controller.alive(@intFromPtr(ctx))) |e| e.installFolder();
}

fn menuRow(b: *Browser, e: *Extensions, c: *ui.Context, p: *const Palette, btn: Button) void {
    const i = c.open(.{ .direction = .row, .gap = 9, .padding = .{ .left = 8, .right = 4 }, .width = .fill, .height = px(30), .radius = 8, .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, btn.label);
    c.addA11y(i, .button, btn.name, "", false, true);
    // Over the row or one of its tools.
    const over = if (it.rect) |r| r.contains(c.input.mouse) else false;
    if (over) c.node(i).style.background = p.wash;
    icon(c, p, e, btn, 16);
    ui.text(c, btn.name, .{ .size = 12.5, .color = if (btn.enabled) p.ink else p.muted, .truncate = true });
    _ = c.leaf(.{ .grow = 1, .min_width = 4 }, .none, null);
    const from_folder = if (e.row(btn.id)) |r| r.source != null else false;
    if (over and from_folder and tool(c, p, "arrow.clockwise", "Reload from its folder", false)) e.reload(btn.id);
    if ((over or btn.pinned) and tool(c, p, if (btn.pinned) "pin.fill" else "pin", if (btn.pinned) "Unpin" else "Pin to toolbar", btn.pinned)) e.setPinned(btn.id, !btn.pinned);
    if (it.clicked) {
        // The list goes first; the popup, if there is one, then hangs from
        // the puzzle button it came out of.
        close(b, e);
        pressLater(e, btn.id, 0.15);
    }
    if (it.right_clicked) actionsMenu(b, c, e, btn.id);
}

/// A small icon button at the end of a row.
fn tool(c: *ui.Context, p: *const Palette, symbol: []const u8, help: []const u8, on: bool) bool {
    const i = c.open(.{ .width = px(22), .height = px(22), .radius = 6, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, help);
    c.addA11y(i, .button, help, "", on, true);
    if (it.hovered) c.node(i).style.background = p.hover;
    ui.icon(c, symbol, .{ .size = 10.5, .weight = .medium, .color = if (on or it.hovered) p.ink else p.muted });
    return it.clicked;
}

fn foot(c: *ui.Context, p: *const Palette, symbol: []const u8, title: []const u8) bool {
    const i = c.open(.{ .direction = .row, .gap = 8, .padding = .xy(10, 6), .width = .fill, .radius = 8, .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, title, "", false, true);
    if (it.hovered) c.node(i).style.background = p.wash;
    ui.icon(c, symbol, .{ .size = 11, .color = p.muted, .frame = 14 });
    ui.text(c, title, .{ .size = 12.5, .color = p.ink });
    return it.clicked;
}
