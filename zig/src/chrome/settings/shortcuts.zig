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
    /// The command whose key is being typed (its id owned on `gpa`: an
    /// extension command's lives only as long as a frame's list), and the
    /// monitor taking it.
    listening: ?[]u8 = null,
    monitor: ?objc.Object = null,
    /// Why that key won't do, until `note_until` (`json.now()`).
    note: ?[]const u8 = null,
    note_until: f64 = 0,
    /// A key another command has, pressed once: pressed again, it moves here.
    taking: ?KeyCombo = null,
    taking_key: [16]u8 = undefined,
    cached_hash: u64 = 0,
    any_shown: bool = false,
    shown_mask: [commands.all.len]bool = @splat(false),
    has_key: [commands.all.len]bool = @splat(false),
    changed_mask: [commands.all.len]bool = @splat(false),
    key_bufs: [commands.all.len][24]u8 = undefined,
    key_lens: [commands.all.len]u8 = @splat(0),

    pub fn deinit(s: *State) void {
        stop(s);
        s.hunt.deinit();
    }
};

fn browserOf(s: *State) *Browser {
    const fs: *frame.State = @fieldParentPtr("shortcuts", s);
    return @fieldParentPtr("settings", fs);
}

fn stateHash(b: *Browser, words: []const u8) u64 {
    var h = std.hash.Wyhash.init(1);
    h.update(words);
    h.update(&.{ @intFromBool(b.prefs.split_view), @intFromBool(b.prefs.ai) });
    const store = &b.kea.shortcuts;
    for (store.changed.keys(), store.changed.values()) |k, v| {
        h.update(k);
        if (v.key) |kc| {
            h.update(kc.key);
            h.update(&.{ @intFromBool(kc.command), @intFromBool(kc.shift), @intFromBool(kc.option), @intFromBool(kc.control) });
        } else h.update(&.{0xff});
    }
    return h.final();
}

fn rebuildCache(b: *Browser, s: *State, words: []const u8) void {
    const hash = stateHash(b, words);
    if (s.cached_hash == hash) return;
    s.cached_hash = hash;
    s.any_shown = false;
    const store = &b.kea.shortcuts;
    var bare_buf: [128]u8 = undefined;
    var bare_len: usize = 0;
    for (words) |ch| if (ch != ' ' and bare_len < bare_buf.len) {
        bare_buf[bare_len] = ch;
        bare_len += 1;
    };
    const bare = bare_buf[0..bare_len];
    for (&commands.all, 0..) |*cmd, n| {
        const eff = store.effective(cmd.id);
        s.has_key[n] = eff != null;
        s.changed_mask[n] = store.isChanged(cmd.id);
        var kslice: []const u8 = "None";
        if (eff) |kc| {
            var w: std.Io.Writer = .fixed(&s.key_bufs[n]);
            w.print("{f}", .{kc}) catch {};
            s.key_lens[n] = @intCast(w.end);
            kslice = s.key_bufs[n][0..w.end];
        } else {
            @memcpy(s.key_bufs[n][0..4], "None");
            s.key_lens[n] = 4;
        }
        var is_shown = true;
        if (commands.isIn(&commands.split, cmd.id) and !b.prefs.split_view) {
            is_shown = false;
        } else if (commands.isIn(&commands.ai, cmd.id) and !b.prefs.ai) {
            is_shown = false;
        } else if (words.len > 0) {
            const match_title = std.ascii.findIgnoreCase(cmd.title, words) != null;
            const match_key = eff != null and bare.len > 0 and std.ascii.findIgnoreCase(kslice, bare) != null;
            is_shown = match_title or match_key;
        }
        s.shown_mask[n] = is_shown;
        if (is_shown) s.any_shown = true;
    }
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
    rebuildCache(b, s, words);
    if (!s.any_shown) plate.nothing(c, p, "No command called that, or on that key");
    inline for (@typeInfo(commands.Section).@"enum".field_names) |name| {
        const section = @field(commands.Section, name);
        var first = true;
        for (&commands.all, 0..) |*cmd, n| {
            if (cmd.section != section or !s.shown_mask[n]) continue;
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
            keyBox(b, c, p, cmd.id, n);
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
        keyBox(b, c, p, item.id, null);
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
/// The title of the command that has `kc`, copied onto `a`.
fn usedBy(b: *Browser, kc: KeyCombo, id: []const u8, a: std.mem.Allocator) ?[]const u8 {
    const store = &b.kea.shortcuts;
    if (store.owner(kc, id)) |other| return a.dupe(u8, other.title) catch null;
    const e = b.kea.ext orelse return null;
    const other = ext_commands.owner(e, kc, id) orelse return null;
    defer store.gpa.free(other.id);
    defer store.gpa.free(other.title);
    return a.dupe(u8, other.title) catch null;
}

fn label(b: *Browser, c: *ui.Context, id: []const u8) []const u8 {
    const s = &b.settings.shortcuts;
    const store = &b.kea.shortcuts;
    const mine = s.listening != null and std.mem.eql(u8, s.listening.?, id);
    if (mine) {
        if (s.taking) |t| if (usedBy(b, t, id, c.alloc())) |other| return c.print("Used by {s} — press again", .{other});
        if (s.note) |n| return n;
        return "Type a shortcut";
    }
    return if (store.effective(id)) |k| c.print("{f}", .{k}) else "None";
}

fn keyBox(b: *Browser, c: *ui.Context, p: *const Palette, id: []const u8, cached_idx: ?usize) void {
    const s = &b.settings.shortcuts;
    const store = &b.kea.shortcuts;
    const listening = s.listening != null and std.mem.eql(u8, s.listening.?, id);
    const i = c.open(.{ .padding = .{ .left = 10, .right = 10 }, .min_width = 64, .min_height = 24, .radius = 7, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const said = if (!listening and cached_idx != null) s.key_bufs[cached_idx.?][0..s.key_lens[cached_idx.?]] else label(b, c, id);
    c.addA11y(i, .button, said, "", listening, true);
    const st = &c.node(i).style;
    st.background = if (listening or it.hovered) p.hover else p.ground;
    st.border = if (listening) p.ink.alpha(0.4) else p.hairline;
    const lit = listening or (if (cached_idx) |idx| s.has_key[idx] else store.effective(id) != null);
    const is_changed = if (cached_idx) |idx| s.changed_mask[idx] else store.isChanged(id);
    ui.text(c, said, .{ .size = 12, .weight = if (is_changed) .semibold else .regular, .color = if (lit) p.ink else p.muted, .truncate = true });
    if (it.clicked) {
        if (listening) stop(s) else listen(s, id);
        c.changed = true;
    }
}

fn listen(s: *State, id: []const u8) void {
    stop(s);
    s.listening = browserOf(s).gpa.dupe(u8, id) catch return;
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
    const other = usedBy(b, kc, id, b.gpa);
    defer if (other) |o| b.gpa.free(o);
    if (other != null and !(if (s.taking) |t| t.eql(kc) else false)) {
        @memcpy(s.taking_key[0..kc.key.len], kc.key);
        s.taking = kc;
        s.taking.?.key = s.taking_key[0..kc.key.len];
        return null;
    }
    store.assign(kc, id);
    stop(s);
    if (other) |o| {
        const said = std.fmt.allocPrint(b.gpa, "{f} moved from {s}", .{ kc, o }) catch return null;
        defer b.gpa.free(said);
        b.announce(said);
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
    if (s.listening) |id| {
        const b = browserOf(s);
        b.kea.shortcuts.recording = false;
        b.gpa.free(id);
    }
    s.monitor = null;
    s.listening = null;
    s.note = null;
    s.taking = null;
}

/// The box stops listening when it goes (`onDisappear`): another page, or Settings closed.
pub fn leave(s: *State) void {
    stop(s);
}
