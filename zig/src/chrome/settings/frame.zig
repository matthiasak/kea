//! Settings (`SettingsPanel`, Settings.swift:8-170): pages down the left on
//! a washed rail, one page at a time on the right under its title and the
//! cross, scrolled on its own. The page you were on is remembered in
//! `settings.page`. A page joins the rail with one line in `pages`.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../../model/browser.zig").Browser;
const Palette = @import("../../design/palette.zig").Palette;
const card = @import("../../design/card.zig");
const motion = @import("../../design/motion.zig");
const controls = @import("../controls.zig");
const sheet = @import("../sheet.zig");

/// `SettingsPanel.Page`, every case Swift has (so a saved one reads).
pub const Page = enum { general, tabs, shortcuts, extensions, passwords, downloads, privacy, sync, ai, about };

pub const Entry = struct {
    page: Page,
    title: []const u8,
    icon: []const u8,
    draw: *const fn (*Browser, *ui.Context, *const Palette) void,
};

/// The rail, in Swift's order: the pages that exist. Passwords (P10),
/// Sync (P12), AI (P9) and Extensions (P13) add their line in place.
pub const pages = [_]Entry{
    .{ .page = .general, .title = "General", .icon = "macwindow", .draw = @import("general.zig").view },
    .{ .page = .tabs, .title = "Tabs", .icon = "rectangle.split.3x1", .draw = @import("tabs.zig").view },
    .{ .page = .shortcuts, .title = "Shortcuts", .icon = "keyboard", .draw = @import("shortcuts.zig").view },
    .{ .page = .downloads, .title = "Downloads", .icon = "arrow.down.circle", .draw = @import("downloads.zig").view },
    .{ .page = .privacy, .title = "Privacy", .icon = "hand.raised", .draw = @import("privacy.zig").view },
    .{ .page = .about, .title = "About", .icon = "info.circle", .draw = @import("about.zig").view },
};

pub const State = struct {
    /// The page on show; null until read from `settings.page` as it appears.
    page: ?Page = null,
    general: @import("general.zig").State = .{},
    shortcuts: @import("shortcuts.zig").State = .{},
    about: @import("about.zig").State = .{},

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.general.deinit(gpa);
        s.shortcuts.deinit();
    }

    /// As the panel appears or has gone: what it holds begins afresh (`@State`).
    pub fn reset(s: *State, gpa: std.mem.Allocator) void {
        s.deinit(gpa);
        s.* = .{};
    }
};

const key = "settings.page";
const rail: f32 = 168;
const width: f32 = 660;
const height: f32 = 500;

fn entry(page: Page) ?*const Entry {
    for (&pages) |*e| if (e.page == page) return e;
    return null;
}

/// `settingsPage`: the page Settings opens on next, from defaults; General
/// for one this build hasn't.
pub fn remembered(b: *const Browser) *const Entry {
    const saved = b.store.string(key) orelse return &pages[0];
    defer b.store.gpa.free(saved);
    const page = std.meta.stringToEnum(Page, saved) orelse return &pages[0];
    return entry(page) orelse &pages[0];
}

/// `settingsPage = page; tuning = true`.
pub fn open(b: *Browser, page: Page) void {
    b.store.setString(key, @tagName(page));
    sheet.show(b, .tuning);
}

fn pick(b: *Browser, page: Page) void {
    if (b.settings.page == page) return;
    b.settings.page = page;
    b.store.setString(key, @tagName(page));
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const on = if (b.settings.page) |pg| entry(pg) orelse &pages[0] else remembered(b);
    b.settings.page = on.page;
    // The key box listens only while it shows.
    if (on.page != .shortcuts) @import("shortcuts.zig").leave(&b.settings.shortcuts);
    _ = c.open(.{
        .direction = .row,
        .width = .{ .px = width },
        .height = .{ .px = height },
        .radius = 16,
        .clip = true,
        .background = p.ground,
        .border = p.hairline,
        .shadow = card.swiftShadow(0.16, 34, 12),
    }, null);
    defer c.end();
    railView(b, c, p, on.page);
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = p.hairline }, .none, null);
    content(b, c, p, on);
}

fn railView(b: *Browser, c: *ui.Context, p: *const Palette, on: Page) void {
    ui.column(c, .{ .gap = 2, .padding = .all(8), .width = .{ .px = rail }, .height = .fill, .background = p.wash.alpha(0.45) });
    defer ui.end(c);
    ui.row(c, .{ .padding = .{ .left = 10, .right = 10, .top = 14, .bottom = 12 } });
    ui.text(c, "Settings", .{ .size = 13, .weight = .semibold, .color = p.ink });
    ui.end(c);
    for (pages) |e| {
        ui.key(c, @tagName(e.page));
        if (pageRow(c, p, e, e.page == on)) pick(b, e.page);
    }
}

/// `PageRow`: the page you are on lifted out in ground, as the tab you are on.
fn pageRow(c: *ui.Context, p: *const Palette, e: Entry, on: bool) bool {
    const i = c.open(.{ .direction = .row, .gap = 9, .padding = .{ .left = 10, .right = 10 }, .width = .fill, .height = .{ .px = 30 }, .radius = 8, .align_items = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .tab, e.title, "", on, true);
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    const s = &c.node(i).style;
    if (on) {
        s.background = p.ground;
        s.shadow = card.swiftShadow(0.06, 3, 1);
    } else s.background = p.hover.alpha(h);
    const ink = if (on) p.ink else p.muted.mix(p.ink.alpha(0.75), h);
    ui.icon(c, e.icon, .{ .size = 12, .weight = .medium, .frame = 16, .color = ink });
    ui.text(c, e.title, .{ .size = 13, .weight = if (on) .medium else .regular, .color = ink });
    return it.clicked;
}

fn content(b: *Browser, c: *ui.Context, p: *const Palette, on: *const Entry) void {
    ui.column(c, .{ .grow = 1, .height = .fill, .padding = .{ .left = 22, .right = 22, .top = 18, .bottom = 18 } });
    defer ui.end(c);
    ui.row(c, .{ .width = .fill, .padding = .{ .bottom = 16 }, .align_items = .center });
    ui.text(c, on.title, .{ .size = 17, .weight = .semibold, .color = p.ink });
    ui.spacer(c);
    if (controls.door(c, p, "xmark", .{ .help = "Done   esc" }).clicked) sheet.close(b, .tuning);
    ui.end(c);
    // A page of its own opens at its top: one scroll per page.
    ui.key(c, @tagName(on.page));
    ui.column(c, .{ .gap = 18, .width = .fill, .grow = 1, .scroll = true, .scroll_bar = false, .padding = .{ .bottom = 4 } });
    defer ui.end(c);
    on.draw(b, c, p);
}

// MARK: pieces the pages share

const plate = @import("../controls_plate.zig");

/// A `Line` with a `Switch`; true when flipped (the new value is `!on`).
pub fn switchLine(c: *ui.Context, p: *const Palette, title: []const u8, detail: ?[]const u8, on: bool) bool {
    plate.line(c, p, title, detail);
    defer ui.end(c);
    var v = on;
    return controls.switch_(c, p, &v, title);
}

/// A `Line` whose `Switch` is the pref `field`, written through when flipped.
pub fn prefLine(b: *Browser, c: *ui.Context, p: *const Palette, comptime field: []const u8, title: []const u8, detail: ?[]const u8) bool {
    const on = @field(b.prefs, field);
    if (!switchLine(c, p, title, detail, on)) return false;
    b.prefs.set(field, !on);
    return true;
}

/// The rule between two lines of a card.
pub fn rule(c: *ui.Context, p: *const Palette) void {
    plate.rule(c, p, 14);
}
