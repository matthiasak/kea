//! Settings › Shortcuts (ShortcutsPage.swift): every menu command with its
//! key, a card to a menu, narrowed by name or key. Click a key and press
//! the new one (`KeyBox`, through a local key monitor); Esc stops, ⌫ takes
//! it off; right-click to clear it or put the default back.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../../model/browser.zig").Browser;
const Palette = @import("../../design/palette.zig").Palette;
const json = @import("../../data/json.zig");
const appkit = @import("../../sys/appkit.zig");
const commands = @import("../../app/commands.zig");
const Command = commands.Command;
const shortcuts = @import("../../app/shortcuts.zig");
const KeyCombo = shortcuts.KeyCombo;
const controls = @import("../controls.zig");
const plate = @import("../controls_plate.zig");
const tab_menu = @import("../tab_menu.zig");
const frame = @import("frame.zig");
const ext_commands = @import("../../ext/commands.zig");

pub const State = struct {
    hunt: ui.TextBuffer = .{},
    /// The command whose key is being typed (its id kept in `listening_id`),
    /// and the monitor taking it.
    listening: ?[]const u8 = null,
    listening_id: [160]u8 = undefined,
    monitor: ?objc.Object = null,
    /// Why that key won't do, until `note_until` (`json.now()`).
    note: ?[]const u8 = null,
    note_until: f64 = 0,
    /// A key another command has, pressed once: pressed again, it moves here.
    taking: ?KeyCombo = null,
    taking_key: [16]u8 = undefined,

    pub fn deinit(s: *State) void {
        stop(s);
        s.hunt.deinit();
    }
};

fn browserOf(s: *State) *Browser {
    const fs: *frame.State = @fieldParentPtr("shortcuts", s);
    return @fieldParentPtr("settings", fs);
}

/// By name, or by key as the menus write it: "tab" and "⌘T" both find New Tab.
fn shown(b: *Browser, c: *ui.Context, cmd: *const Command, words: []const u8) bool {
    if (commands.isIn(&commands.split, cmd.id) and !b.prefs.split_view) return false;
    if (commands.isIn(&commands.ai, cmd.id) and !b.prefs.ai) return false;
    if (words.len == 0) return true;
    if (std.ascii.findIgnoreCase(cmd.title, words) != null) return true;
    const key = if (b.kea.shortcuts.effective(cmd.id)) |k| c.print("{f}", .{k}) else "";
    const bare = std.mem.replaceOwned(u8, c.alloc(), words, " ", "") catch return false;
    return std.ascii.findIgnoreCase(key, bare) != null;
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.settings.shortcuts;
    const store = &b.kea.shortcuts;
    if (s.note != null) {
        const left = s.note_until - json.now();
        if (left <= 0) s.note = null else c.frameIn(@floatCast(left));
    }
    _ = plate.hunt(c, p, &s.hunt, "Search commands or keys");
    const words = std.mem.trim(u8, s.hunt.text(), " ");
    var any = false;
    for (&commands.all) |*cmd| if (shown(b, c, cmd, words)) {
        any = true;
    };
    if (!any) plate.nothing(c, p, "No command called that, or on that key");
    inline for (@typeInfo(commands.Section).@"enum".field_names) |name| {
        const section = @field(commands.Section, name);
        var first = true;
        for (&commands.all, 0..) |*cmd, n| {
            if (cmd.section != section or !shown(b, c, cmd, words)) continue;
            if (first) {
                ui.key(c, name);
                ui.column(c, .{ .gap = 6, .width = .fill });
                plate.caption(c, p, section.title());
                plate.cardBox(c, p);
            } else frame.rule(c, p);
            first = false;
            ui.key(c, cmd.id);
            const row = c.open(.{ .width = .fill }, null);
            if (c.interact(row, .{}).right_clicked) tab_menu.later(b, c.input.mouse, n, menu);
            plate.line(c, p, cmd.title, null);
            keyBox(b, c, p, cmd.id);
            ui.end(c);
            c.end();
        }
        if (!first) {
            ui.end(c);
            ui.end(c);
        }
    }
    if (b.kea.ext) |e| extensionCommands(b, c, p, e, words);
    if (store.anyChanged() and s.hunt.text().len == 0) {
        if (controls.pill(c, p, "Reset All to Defaults", .{}).clicked) store.resetAll();
    }
}

const Pick = struct {
    b: *Browser,
    id: []const u8,
    reset: bool,
    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const store = &self.b.kea.shortcuts;
        if (self.reset) store.reset(self.id) else store.clear(self.id);
        self.b.redraw();
    }
};

/// The line's menu: Clear Shortcut, Reset to Default. Past Kea's own
/// commands, `n` counts the extensions' (`extensionCommands`).
fn menu(arena: std.mem.Allocator, b: *Browser, n: u64) anyerror![]const MenuItem {
    const id = if (n < commands.all.len) commands.all[@intCast(n)].id else blk: {
        const e = b.kea.ext orelse return &.{};
        const list = try ext_commands.list(e, arena);
        const at: usize = @intCast(n - commands.all.len);
        if (at >= list.len) return &.{};
        break :blk list[at].id;
    };
    const store = &b.kea.shortcuts;
    const clear = try arena.create(Pick);
    clear.* = .{ .b = b, .id = id, .reset = false };
    const reset = try arena.create(Pick);
    reset.* = .{ .b = b, .id = id, .reset = true };
    const out = try arena.alloc(MenuItem, 2);
    out[0] = .{ .label = "Clear Shortcut", .disabled = store.effective(id) == null, .click = .of(clear, Pick.fire) };
    out[1] = .{ .label = "Reset to Default", .disabled = !store.isChanged(id), .click = .of(reset, Pick.fire) };
    return out;
}

/// The commands extensions bring, with the keys their manifests ask for
/// unless you gave them others (ShortcutsPage.swift:62-91).
fn extensionCommands(b: *Browser, c: *ui.Context, p: *const Palette, e: *@import("../../ext/controller.zig").Extensions, words: []const u8) void {
    const store = &b.kea.shortcuts;
    const list = ext_commands.list(e, c.alloc()) catch return;
    const bare = std.mem.replaceOwned(u8, c.alloc(), words, " ", "") catch return;
    var first = true;
    for (list, 0..) |item, n| {
        const key = if (store.effective(item.id)) |k| c.print("{f}", .{k}) else "";
        const finds = std.ascii.findIgnoreCase;
        if (words.len > 0 and finds(item.title, words) == null and finds(item.extension_name, words) == null and finds(key, bare) == null) continue;
        if (first) {
            ui.key(c, "extensions");
            ui.column(c, .{ .gap = 6, .width = .fill });
            plate.caption(c, p, "Extensions");
            plate.cardBox(c, p);
        } else frame.rule(c, p);
        first = false;
        ui.key(c, item.id);
        const row = c.open(.{ .width = .fill }, null);
        if (c.interact(row, .{}).right_clicked) tab_menu.later(b, c.input.mouse, commands.all.len + n, menu);
        plate.line(c, p, item.title, item.extension_name);
        keyBox(b, c, p, item.id);
        ui.end(c);
        c.end();
    }
    if (!first) {
        ui.end(c);
        ui.end(c);
    }
}

// MARK: KeyBox

/// The command, Kea's or an extension's, that has `kc` (other than `id`):
/// its title in `buf`.
fn usedBy(b: *Browser, kc: KeyCombo, id: []const u8, buf: []u8) ?[]const u8 {
    const store = &b.kea.shortcuts;
    if (store.owner(kc, id)) |other| return other.title;
    const e = b.kea.ext orelse return null;
    const other = ext_commands.owner(e, kc, id) orelse return null;
    defer store.gpa.free(other.id);
    defer store.gpa.free(other.title);
    const n = @min(buf.len, other.title.len);
    @memcpy(buf[0..n], other.title[0..n]);
    return buf[0..n];
}

fn label(b: *Browser, c: *ui.Context, id: []const u8) []const u8 {
    const s = &b.settings.shortcuts;
    const store = &b.kea.shortcuts;
    const mine = s.listening != null and std.mem.eql(u8, s.listening.?, id);
    if (mine) {
        var buf: [160]u8 = undefined;
        if (s.taking) |t| if (usedBy(b, t, id, &buf)) |other| return c.print("Used by {s} — press again", .{other});
        if (s.note) |n| return n;
        return "Type a shortcut";
    }
    return if (store.effective(id)) |k| c.print("{f}", .{k}) else "None";
}

fn keyBox(b: *Browser, c: *ui.Context, p: *const Palette, id: []const u8) void {
    const s = &b.settings.shortcuts;
    const store = &b.kea.shortcuts;
    const listening = s.listening != null and std.mem.eql(u8, s.listening.?, id);
    const i = c.open(.{ .padding = .{ .left = 10, .right = 10 }, .min_width = 64, .min_height = 24, .radius = 7, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const said = label(b, c, id);
    c.addA11y(i, .button, said, "", listening, true);
    const st = &c.node(i).style;
    st.background = if (listening or it.hovered) p.hover else p.ground;
    st.border = if (listening) p.ink.alpha(0.4) else p.hairline;
    const lit = listening or store.effective(id) != null;
    ui.text(c, said, .{ .size = 12, .weight = if (store.isChanged(id)) .semibold else .regular, .color = if (lit) p.ink else p.muted, .truncate = true });
    if (it.clicked) {
        if (listening) stop(s) else listen(s, id);
        c.changed = true;
    }
}

fn listen(s: *State, id: []const u8) void {
    stop(s);
    // An extension command's id lives only as long as this frame's list.
    const n = @min(id.len, s.listening_id.len);
    @memcpy(s.listening_id[0..n], id[0..n]);
    s.listening = s.listening_id[0..n];
    browserOf(s).kea.shortcuts.recording = true;
    s.monitor = appkit.addLocalMonitor(appkit.mask.key_down, s, take);
}

/// The monitor's: every key while listening is the box's, none goes on.
pub fn take(s: *State, event: objc.Object) ?objc.Object {
    const b = browserOf(s);
    defer b.redraw();
    const id = s.listening orelse return event;
    const store = &b.kea.shortcuts;
    const f = shortcuts.flag;
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{}) & (f.command | f.option | f.control | f.shift);
    const code = objc.msg(u16, event, "keyCode", .{});
    if (code == 53 and flags == 0) {
        stop(s);
        return null;
    }
    if ((code == 51 or code == 117) and flags == 0) {
        store.clear(id);
        stop(s);
        return null;
    }
    var buf: [16]u8 = undefined;
    const kc = shortcuts.fromEvent(event, &buf) orelse return null;
    if (!kc.isUsable()) return say(s, "Add ⌘, ⌥ or ⌃");
    if (shortcuts.isReserved(kc)) return say(s, "Can’t be changed");
    // An extension's command takes a key as its manifest would.
    const ext = std.mem.startsWith(u8, id, "ext:");
    if (ext and (kc.key.len != 1 or shortcuts.isBrowserOnly(kc))) return say(s, "Not for an extension");
    var title_buf: [160]u8 = undefined;
    const other = usedBy(b, kc, id, &title_buf);
    if (other != null and !(if (s.taking) |t| t.eql(kc) else false)) {
        @memcpy(s.taking_key[0..kc.key.len], kc.key);
        s.taking = kc;
        s.taking.?.key = s.taking_key[0..kc.key.len];
        return null;
    }
    store.assign(kc, id);
    stop(s);
    if (other) |o| {
        var said: [200]u8 = undefined;
        b.announce(std.fmt.bufPrint(&said, "{f} moved from {s}", .{ kc, o }) catch return null);
    }
    return null;
}

/// Why that key won't do, for a moment, still listening.
fn say(s: *State, text: []const u8) ?objc.Object {
    s.note = text;
    s.note_until = json.now() + 1.2;
    return null;
}

fn stop(s: *State) void {
    if (s.monitor) |m| appkit.removeMonitor(m);
    if (s.listening != null) browserOf(s).kea.shortcuts.recording = false;
    s.monitor = null;
    s.listening = null;
    s.note = null;
    s.taking = null;
}

/// The box stops listening when it goes (`onDisappear`): another page, or Settings closed.
pub fn leave(s: *State) void {
    stop(s);
}
