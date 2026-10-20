//! The menu bar (`KeaApp.commands`, App.swift:46-297): the same menus,
//! order, titles, separators and conditions, each command's key the one it
//! has now (app/shortcuts.zig). Each menu is made again as it opens — or as
//! AppKit looks through it for a key — from the window in front, so titles,
//! ticks and what can be chosen are always as things stand; History's lists
//! and the bookmarks (`BookmarkMenu`) come with it, their folders filling as
//! they open. A key moved in Settings › Shortcuts moves on the bar at once.
const std = @import("std");
const nanoui = @import("nanoui");
const MenuItem = nanoui.MenuItem;
const Item = nanoui.menu.Item;
const kea_mod = @import("kea.zig");
const Kea = kea_mod.Kea;
const Browser = @import("../model/browser.zig").Browser;
const browsers = @import("browsers.zig");
const commands = @import("commands.zig");
const shortcuts = @import("shortcuts.zig");
const KeyCombo = shortcuts.KeyCombo;
const sheet = @import("../chrome/sheet.zig");
const address = @import("../model/address.zig");
const Glyph = @import("../data/prefs.zig").Glyph;
const substitutions = @import("../web/substitutions.zig");
const Substitution = substitutions.Substitution;
const bookmarks_menu = @import("../chrome/bookmarks/menu.zig");
const send = @import("../sync/send.zig");

/// The bar's own menus, in its order.
pub const Top = enum { app, file, edit, view, tabs, bookmarks, history, window };
const top_count = @typeInfo(Top).@"enum".field_names.len;

pub const State = struct {
    /// What each menu's items were made of (titles, what a click does),
    /// replaced each time it is made again.
    arenas: [top_count]?*std.heap.ArenaAllocator = @splat(null),
    installed: bool = false,
};

/// The bar, from now on, for the window in front.
pub fn install(kea: *Kea) void {
    const app = kea.ui_app orelse return;
    var made: [top_count]MenuItem = undefined;
    for (std.enums.values(Top), 0..) |top, i| {
        const arena = fresh(kea) orelse return;
        made[i] = holder(arena.allocator(), kea, browsers.acting(kea), top) catch return;
        kea.menus.arenas[i] = arena;
    }
    app.setMenu(&made) catch return;
    kea.menus.installed = true;
    kea.shortcuts.on_change = keysChanged;
}

/// The app's own bar back: the menus' clicks are this `Kea`'s.
pub fn uninstall(kea: *Kea) void {
    if (kea.menus.installed) if (kea.ui_app) |app| app.setMenu(&nanoui.App.default_menu) catch {};
    kea.menus.installed = false;
    kea.shortcuts.on_change = null;
    for (&kea.menus.arenas) |*slot| if (slot.*) |a| {
        a.deinit();
        kea.gpa.destroy(a);
        slot.* = null;
    };
}

fn fresh(kea: *Kea) ?*std.heap.ArenaAllocator {
    const a = kea.gpa.create(std.heap.ArenaAllocator) catch return null;
    a.* = .init(kea.gpa);
    return a;
}

/// The whole bar's templates on `a`, for `b` (null: no window yet). Nothing
/// is shown: what `install` and each opening build from.
pub fn bar(a: std.mem.Allocator, kea: *Kea, b: ?*Browser) ![]const MenuItem {
    const out = try a.alloc(MenuItem, top_count);
    for (std.enums.values(Top), out) |top, *m| m.* = try holder(a, kea, b, top);
    return out;
}

fn holder(a: std.mem.Allocator, kea: *Kea, b: ?*Browser, top: Top) !MenuItem {
    const sub = if (b) |br| try items(a, kea, br, top) else &.{};
    return switch (top) {
        .app => .{ .label = kea_mod.app_name, .role = .app_menu, .id = "menu.app", .submenu = sub, .on_open = .of(kea, opened) },
        .edit => .{ .label = "Edit", .role = .edit_menu, .id = "menu.edit", .submenu = sub, .on_open = .of(kea, opened) },
        .window => .{ .label = "Window", .role = .window_menu, .id = "menu.window", .submenu = &.{
            .{ .role = .minimize }, .{ .role = .zoom }, .separator, .{ .role = .front },
        } },
        inline else => |t| .{ .label = title(t), .id = "menu." ++ @tagName(t), .submenu = sub, .on_open = .of(kea, opened) },
    };
}

fn title(top: Top) []const u8 {
    return switch (top) {
        .file => "File",
        .view => "View",
        .tabs => "Tabs",
        .bookmarks => "Bookmarks",
        .history => "History",
        else => unreachable,
    };
}

/// A menu of the bar is about to show, or be searched for a key: made
/// again as things stand now.
fn opened(kea: *Kea, item: *Item) void {
    const top = std.meta.stringToEnum(Top, item.id["menu.".len..]) orelse return;
    const b = browsers.acting(kea) orelse return;
    const arena = fresh(kea) orelse return;
    const made = items(arena.allocator(), kea, b, top) catch return drop(kea, arena);
    item.setSubmenu(made) catch return drop(kea, arena);
    const i = @intFromEnum(top);
    if (kea.menus.arenas[i]) |old| drop(kea, old);
    kea.menus.arenas[i] = arena;
}

fn drop(kea: *Kea, a: *std.heap.ArenaAllocator) void {
    a.deinit();
    kea.gpa.destroy(a);
}

/// Settings › Shortcuts changed a key: every command's item wears its own now.
fn keysChanged(s: *const shortcuts.Shortcuts) void {
    const kea: *const Kea = @alignCast(@fieldParentPtr("shortcuts", s));
    const app = kea.ui_app orelse return;
    // An ArrayList's first allocation is a cache line (128 bytes here).
    var buf: [512]u8 = undefined;
    for (commands.all) |cmd| if (app.menuItem(cmd.id)) |it| {
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        it.setAccelerator(accel(fba.allocator(), s.effective(cmd.id)) catch continue);
    };
}

/// A key as an accelerator: "Cmd+Shift+T", "Ctrl+Cmd+Left".
pub fn accel(a: std.mem.Allocator, key: ?KeyCombo) ![]const u8 {
    const kc = key orelse return "";
    var out: std.ArrayList(u8) = .empty;
    if (kc.command) try out.appendSlice(a, "Cmd+");
    if (kc.shift) try out.appendSlice(a, "Shift+");
    if (kc.option) try out.appendSlice(a, "Alt+");
    if (kc.control) try out.appendSlice(a, "Ctrl+");
    const named = [_][2][]const u8{
        .{ "left", "Left" },     .{ "right", "Right" }, .{ "up", "Up" },   .{ "down", "Down" }, .{ "return", "Return" },
        .{ "delete", "Backspace" }, .{ "space", "Space" }, .{ "tab", "Tab" }, .{ "escape", "Esc" }, .{ "+", "Plus" },
    };
    for (named) |n| if (std.mem.eql(u8, n[0], kc.key)) {
        try out.appendSlice(a, n[1]);
        return out.items;
    };
    try out.appendSlice(a, kc.key);
    return out.items;
}

// MARK: what each menu holds

/// What a click does, for the window in front when it comes.
const Act = struct {
    kea: *Kea,
    what: What,

    fn fire(self: *Act, _: *Item) void {
        const b = browsers.acting(self.kea) orelse return;
        switch (self.what) {
            .command => |id| run(id, b),
            .close_both => b.closeSplit(),
            .pin => |listed| if (b.activeTab()) |t| b.pin(t, listed),
            .set_listed => |listed| if (b.activeTab()) |t| b.setListed(t, listed),
            .change_letter => if (b.activeTab()) |t| b.editLetter(t),
            .unpin => if (b.activeTab()) |t| b.unpin(t),
            .glyph => |g| b.prefs.set("glyph", g),
            .show_substitutions => substitutions.showPanel(),
            .substitution => |s| substitutions.toggleSubstitution(b, s),
            .visit => |url| {
                _ = b.open(url, .{ .foreground = true });
            },
            .ghost => |at| if (at < b.ghosts.items.len) b.reopenGhost(at),
        }
        b.redraw();
    }
};

const What = union(enum) {
    command: []const u8,
    close_both,
    pin: bool,
    set_listed: bool,
    change_letter,
    unpin,
    glyph: Glyph,
    show_substitutions,
    substitution: Substitution,
    visit: []const u8,
    ghost: usize,
};

/// A command from its menu: as `Command.run`, but the menu's own Settings…,
/// Show History… and Downloads… only ever open their sheet.
fn run(id: []const u8, b: *Browser) void {
    const eq = std.mem.eql;
    if (eq(u8, id, "app.settings")) return sheet.show(b, .tuning);
    if (eq(u8, id, "history.show")) return sheet.show(b, .recalling);
    if (eq(u8, id, "history.downloads")) return sheet.show(b, .hoarding);
    if (commands.named(id)) |cmd| cmd.run(b);
}

const Build = struct {
    a: std.mem.Allocator,
    kea: *Kea,
    b: *Browser,
    out: std.ArrayList(MenuItem) = .empty,

    fn act(self: *Build, what: What) !nanoui.menu.Click {
        const it = try self.a.create(Act);
        it.* = .{ .kea = self.kea, .what = what };
        return .of(it, Act.fire);
    }

    fn add(self: *Build, item: MenuItem) !void {
        try self.out.append(self.a, item);
    }

    fn line(self: *Build) !void {
        try self.add(.separator);
    }

    fn role(self: *Build, r: nanoui.menu.Role) !void {
        try self.add(.{ .role = r });
    }

    const Opts = struct { label: ?[]const u8 = null, disabled: bool = false, checked: ?bool = null };

    /// A command's item: its title (or `o.label`), its key now, ticked when `o.checked`.
    fn command(self: *Build, id: []const u8, o: Opts) !void {
        const cmd = commands.named(id).?;
        try self.add(.{
            .label = o.label orelse cmd.title,
            .id = cmd.id,
            .accelerator = try accel(self.a, self.kea.shortcuts.effective(id)),
            .disabled = o.disabled,
            .kind = if (o.checked != null) .checkbox else .normal,
            .checked = o.checked orelse false,
            .click = try self.act(.{ .command = id }),
        });
    }

    fn plain(self: *Build, label: []const u8, what: What, disabled: bool) !void {
        try self.add(.{ .label = label, .disabled = disabled, .click = try self.act(what) });
    }

    /// A page as a line in a menu: its icon if one is known, and its name (`MenuLine`).
    fn page(self: *Build, label: []const u8, url: []const u8, what: What) !void {
        const png = if (self.kea.favicons.icon(url)) |ic| ic.png else "";
        try self.add(.{ .label = label, .image_png = png, .click = try self.act(what) });
    }

    /// A section's name over its lines (`Section("…")`).
    fn header(self: *Build, label: []const u8) !void {
        try self.add(.{ .label = label, .disabled = true });
    }
};

/// The items of one menu, for `b`, on `a`.
pub fn items(a: std.mem.Allocator, kea: *Kea, b: *Browser, top: Top) ![]const MenuItem {
    var m: Build = .{ .a = a, .kea = kea, .b = b };
    const active = b.activeTab();
    const blank = if (active) |t| t.isBlank() else true;
    switch (top) {
        .app => {
            try m.role(.about);
            try m.line();
            try m.command("app.settings", .{});
            try m.command("app.welcome", .{});
            try m.command("app.passwords", .{});
            try m.line();
            try m.role(.hide);
            try m.role(.hide_others);
            try m.role(.unhide);
            try m.line();
            try m.role(.quit);
        },
        .file => {
            try m.command("file.newWindow", .{});
            try m.command("file.newTab", .{});
            try m.command("file.newPrivateTab", .{});
            var buf: [64]u8 = undefined;
            try m.command("file.reopen", .{
                .label = try a.dupe(u8, b.reopenTitle(&buf)),
                .disabled = b.ghosts.items.len == 0 and browsers.lastClosedAt(kea) == null,
            });
            try m.line();
            try m.command("file.openAddress", .{});
            try m.line();
            try m.command("file.import", .{});
            try m.line();
            try m.command("file.closeTab", .{});
            try m.line();
            try m.command("file.share", .{ .disabled = blank });
            try m.command("file.print", .{ .disabled = blank });
        },
        .edit => {
            for ([_]nanoui.menu.Role{ .undo, .redo }) |r| try m.role(r);
            try m.line();
            for ([_]nanoui.menu.Role{ .cut, .copy, .paste, .select_all }) |r| try m.role(r);
            try m.line();
            try m.command("edit.find", .{ .disabled = blank });
            try m.command("edit.findNext", .{ .disabled = !b.finder.finding });
            try m.command("edit.findPrevious", .{ .disabled = !b.finder.finding });
            try m.line();
            var subs: Build = .{ .a = a, .kea = kea, .b = b };
            try subs.plain("Show Substitutions", .show_substitutions, false);
            try subs.line();
            for (std.enums.values(Substitution)) |s|
                try subs.add(.{ .label = s.title(), .kind = .checkbox, .checked = substitutions.substitutes(b, s), .click = try subs.act(.{ .substitution = s }) });
            try m.add(.{ .label = "Substitutions", .submenu = subs.out.items });
        },
        .view => {
            const p = b.prefs;
            try m.command("view.sidebar", .{ .checked = p.sidebar });
            // Folded away, not moved (Fold.swift): the column, or the strip.
            const fold_title = if (p.sidebar)
                (if (b.folded) "Show Sidebar" else "Hide Sidebar")
            else
                (if (b.folded) "Show Tab Bar" else "Hide Tab Bar");
            try m.command("view.fold", .{ .label = fold_title });
            var wear: Build = .{ .a = a, .kea = kea, .b = b };
            for ([_]Glyph{ .letters, .icons }, [_][]const u8{ "Letters", "Site icons" }) |g, t|
                try wear.add(.{ .label = t, .kind = .radio, .checked = p.glyph == g, .click = try wear.act(.{ .glyph = g }) });
            try m.add(.{ .label = "Tabs Wear", .submenu = wear.out.items });
            try m.line();
            try m.command("view.reload", .{});
            try m.command("view.reloadOrigin", .{});
            try m.command("view.stop", .{});
            try m.command("view.reader", .{});
            try m.command("view.float", .{});
            // The AI add-on's, only once it is on.
            if (p.ai) {
                try m.line();
                try m.command("view.summarize", .{ .disabled = blank });
                try m.command("view.ask", .{});
            }
            try m.line();
            try m.command("view.hide", .{});
            try m.command("view.hidden", .{});
            try m.line();
            try m.command("view.zoomIn", .{});
            try m.command("view.zoomOut", .{});
            try m.command("view.actualSize", .{});
            try m.line();
            try m.command("view.inspector", .{});
            try m.command("view.console", .{});
            try m.command("view.inspect", .{});
            try m.line();
            try m.role(.toggle_full_screen);
        },
        .tabs => try tabs(&m, active, blank),
        .bookmarks => {
            try m.command("bookmarks.add", .{ .label = if (b.pageKept()) "Edit Bookmark\u{2026}" else null, .disabled = blank });
            try m.command("bookmarks.show", .{});
            try m.command("bookmarks.bar", .{ .checked = b.prefs.bookmarks_bar });
            try m.command("bookmarks.sidebar", .{ .checked = b.prefs.bookmarks_sidebar });
            // The bookmarks themselves follow (`BookmarkMenu.fill`).
            if (b.bookmarks.roots.len > 0) {
                try m.line();
                try m.out.appendSlice(a, try bookmarks_menu.items(a, b, b.bookmarks.roots));
            }
        },
        .history => {
            try m.header("Recently Visited");
            for (kea.history.recent()) |trace| {
                const label = if (trace.title.len == 0) address.withoutWWW(trace.address) else trace.title;
                try m.page(label, trace.url, .{ .visit = try a.dupe(u8, trace.url) });
            }
            if (b.ghosts.items.len > 0) {
                try m.line();
                try m.header("Recently Closed");
                const ghosts = b.ghosts.items;
                var i = ghosts.len;
                while (i > 0 and ghosts.len - i < 10) {
                    i -= 1;
                    const g = ghosts[i];
                    const label = if (g.title.len > 0) g.title else try address.pretty(a, g.url);
                    try m.page(label, g.url, .{ .ghost = i });
                }
            }
            try send.otherMacs(a, b, &m.out);
            try m.line();
            try m.command("history.show", .{});
            try m.command("history.downloads", .{});
            try m.line();
            try m.command("history.clearData", .{});
            try m.command("history.clear", .{});
        },
        .window => {},
    }
    return m.out.items;
}

fn tabs(m: *Build, active: ?*@import("../web/tab.zig").Tab, blank: bool) !void {
    const b = m.b;
    try m.command("tabs.back", .{ .disabled = if (active) |t| !t.can_go_back else true });
    try m.command("tabs.forward", .{ .disabled = if (active) |t| !t.can_go_forward else true });
    try m.line();
    try m.command("tabs.next", .{});
    try m.command("tabs.previous", .{});
    try m.command("tabs.search", .{});
    try m.line();
    if (b.prefs.split_view) {
        const none = b.activeSplit() == null;
        try m.command("tabs.split", .{ .disabled = active == null });
        try m.command("tabs.focusLeftPane", .{ .disabled = none });
        try m.command("tabs.focusRightPane", .{ .disabled = none });
        try m.command("tabs.swapSplit", .{ .disabled = none });
        try m.command("tabs.separateSplit", .{ .disabled = none });
        try m.plain("Close Both Pages", .close_both, none);
        try m.line();
    }
    if (active) |t| {
        const rows = b.prefs.showsPinRows();
        if (t.pin == null) {
            try m.plain("Pin Tab", .{ .pin = false }, t.isBlank() or t.shy);
            if (rows) try m.plain("Pin Tab as Row", .{ .pin = true }, t.isBlank() or t.shy);
        } else {
            if (rows) try m.plain(if (t.listed) "Show Pin as Square" else "Show Pin as Row", .{ .set_listed = !t.listed }, false);
            if (!(rows and t.listed)) try m.plain("Change Letter", .change_letter, false);
            try m.plain("Unpin Tab", .unpin, false);
        }
    }
    try m.command("tabs.rename", .{ .disabled = active == null });
    try m.command("tabs.duplicate", .{ .disabled = blank });
    try m.command("tabs.copyAddress", .{ .disabled = blank });
    try m.command("tabs.copyMarkdown", .{ .disabled = blank });
    if (active) |t| try m.add(try send.menu(m.a, b, t));
    try m.command("tabs.pasteAndGo", .{});
    try m.line();
    try m.command("tabs.closeOthers", .{ .disabled = b.tabs.items.len < 2 });
    try m.command("tabs.mute", .{});
}
