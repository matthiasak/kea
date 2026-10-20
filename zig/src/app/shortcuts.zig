//! Your own keys for the menu commands (Settings › Shortcuts, Shortcuts.swift):
//! a key and its modifiers (`KeyCombo`), the keys never given away
//! (`isReserved`, `isBrowserOnly`), and what you changed on top of the
//! defaults (`ShortcutStore`), kept in defaults `shortcuts` as the JSON of
//! `[id: {key?}]` — only the differences, so a default that changes later
//! still reaches everyone who never touched it.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const Store = @import("../data/store.zig").Store;
const commands = @import("commands.zig");
const Command = commands.Command;
const ext_commands = @import("../ext/commands.zig");

pub const defaults_key = "shortcuts";

/// A key and the modifiers held with it. `key` is a lowercased character,
/// or the name of a key that has none: left, right, up, down, return,
/// delete, space, tab, escape, f1…f12.
pub const KeyCombo = struct {
    key: []const u8,
    command: bool = false,
    shift: bool = false,
    option: bool = false,
    control: bool = false,

    pub fn eql(a: KeyCombo, b: KeyCombo) bool {
        return a.command == b.command and a.shift == b.shift and a.option == b.option and
            a.control == b.control and std.mem.eql(u8, a.key, b.key);
    }

    fn isFunctionKey(self: KeyCombo) bool {
        if (self.key.len < 2 or self.key[0] != 'f') return false;
        _ = std.fmt.parseInt(u8, self.key[1..], 10) catch return false;
        return true;
    }

    /// A key alone, or with only ⇧, is typing — never a shortcut.
    pub fn isUsable(self: KeyCombo) bool {
        return self.command or self.option or self.control or self.isFunctionKey();
    }

    /// As a menu shows it: ⌃⌥⇧⌘ then the key (`display`); `{f}`.
    pub fn format(self: KeyCombo, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.control) try w.writeAll("⌃");
        if (self.option) try w.writeAll("⌥");
        if (self.shift) try w.writeAll("⇧");
        if (self.command) try w.writeAll("⌘");
        for (symbols) |s| if (std.mem.eql(u8, s[0], self.key)) return w.writeAll(s[1]);
        // `uppercased()`; past ASCII the key is shown as it is.
        for (self.key) |ch| try w.writeByte(std.ascii.toUpper(ch));
    }
};

const symbols = [_][2][]const u8{
    .{ "left", "←" },   .{ "right", "→" }, .{ "up", "↑" },       .{ "down", "↓" },  .{ "return", "↩" },
    .{ "delete", "⌫" }, .{ "space", "Space" }, .{ "tab", "⇥" }, .{ "escape", "⎋" },
};

pub const Mods = struct { command: bool = true, shift: bool = false, option: bool = false, control: bool = false };

/// `KeyCombo.init`: ⌘+ is ⇧⌘= on some keyboards and a key of its own on
/// others; both are kept as "+" with nothing about ⇧. `key` is lowercase.
pub fn combo(key: []const u8, m: Mods) KeyCombo {
    const plus = std.mem.eql(u8, key, "=") or std.mem.eql(u8, key, "+");
    return .{ .key = if (plus) "+" else key, .command = m.command, .shift = if (plus) false else m.shift, .option = m.option, .control = m.control };
}

/// Key codes of the keys that have no character.
const names = [_]struct { u16, []const u8 }{
    .{ 123, "left" },  .{ 124, "right" }, .{ 125, "down" }, .{ 126, "up" },   .{ 36, "return" }, .{ 76, "return" },
    .{ 51, "delete" }, .{ 117, "delete" }, .{ 49, "space" }, .{ 48, "tab" }, .{ 53, "escape" },
    .{ 122, "f1" },    .{ 120, "f2" },    .{ 99, "f3" },    .{ 118, "f4" },  .{ 96, "f5" },     .{ 97, "f6" },
    .{ 98, "f7" },     .{ 100, "f8" },    .{ 101, "f9" },   .{ 109, "f10" }, .{ 103, "f11" },   .{ 111, "f12" },
};

/// `ContentView.digits`: the top row by where it sits.
pub const digits = [_]struct { u16, u8 }{
    .{ 18, '1' }, .{ 19, '2' }, .{ 20, '3' }, .{ 21, '4' }, .{ 23, '5' }, .{ 22, '6' }, .{ 26, '7' }, .{ 28, '8' }, .{ 25, '9' }, .{ 29, '0' },
};

/// `NSEvent.ModifierFlags` bits.
pub const flag = struct {
    pub const shift: u64 = 1 << 17;
    pub const control: u64 = 1 << 18;
    pub const option: u64 = 1 << 19;
    pub const command: u64 = 1 << 20;
};

/// `KeyCombo(event:)`: the key as the keyboard's layout names it with
/// nothing held — ⇧⌘] is "]" with shift — and the top row by place. The
/// key's text goes in `buf` when it isn't a name.
pub fn fromEvent(event: objc.Object, buf: []u8) ?KeyCombo {
    const code = objc.msg(u16, event, "keyCode", .{});
    const flags: u64 = objc.msg(objc.NSUInteger, event, "modifierFlags", .{});
    const m: Mods = .{
        .command = flags & flag.command != 0,
        .shift = flags & flag.shift != 0,
        .option = flags & flag.option != 0,
        .control = flags & flag.control != 0,
    };
    for (names) |n| if (n[0] == code) return combo(n[1], m);
    for (digits) |d| if (d[0] == code) {
        buf[0] = d[1];
        return combo(buf[0..1], m);
    };
    const pool = objc.Pool.push();
    defer pool.pop();
    const chars = objc.msg(?objc.Object, event, "charactersByApplyingModifiers:", .{@as(objc.NSUInteger, 0)}) orelse return null;
    const text = objc.fromNSString(objc.msg(objc.Object, chars, "lowercaseString", .{}));
    if (text.len == 0 or text.len > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    return combo(buf[0..text.len], m);
}

/// macOS's own, the ones every text field relies on, and the ones Kea
/// keeps for itself: ⌘1–⌘9 for tabs, ⌃1–⌃9 for spaces, Tab and Escape
/// with anything.
pub fn isReserved(kc: KeyCombo) bool {
    const system = [_]KeyCombo{
        combo("q", .{}),                       combo("q", .{ .option = true }),                           combo("q", .{ .control = true }),
        combo("q", .{ .shift = true }),        combo("q", .{ .shift = true, .option = true }),           combo("h", .{}),
        combo("h", .{ .option = true }),       combo("m", .{}),                                           combo("m", .{ .option = true }),
        combo("c", .{}),                       combo("v", .{}),                                           combo("x", .{}),
        combo("a", .{}),                       combo("z", .{}),                                           combo("z", .{ .shift = true }),
        combo("`", .{}),                       combo("`", .{ .shift = true }),                            combo("f", .{ .control = true }),
        combo("space", .{}),                   combo("space", .{ .command = false, .control = true }),    combo("space", .{ .option = true }),
        combo("space", .{ .command = false, .option = true, .control = true }),
    };
    for (system) |s| if (s.eql(kc)) return true;
    if (std.mem.eql(u8, kc.key, "tab") or std.mem.eql(u8, kc.key, "escape")) return true;
    const digit = kc.key.len == 1 and kc.key[0] >= '1' and kc.key[0] <= '9';
    return digit and !kc.option and !kc.shift and (kc.command != kc.control);
}

/// Keys an extension never has: closing, and opening a tab or a window.
pub fn isBrowserOnly(kc: KeyCombo) bool {
    const kept = [_]KeyCombo{
        combo("w", .{}), combo("w", .{ .shift = true }), combo("w", .{ .option = true }),
        combo("t", .{}), combo("t", .{ .shift = true }), combo("n", .{}),
        combo("n", .{ .shift = true }),
    };
    for (kept) |s| if (s.eql(kc)) return true;
    return false;
}

/// A change: a new key, or none.
pub const Override = struct { key: ?KeyCombo = null };

/// `ShortcutStore`: what you changed, for the whole app. Ids and keys on `gpa`.
pub const Shortcuts = struct {
    gpa: std.mem.Allocator,
    store: *const Store,
    changed: std.StringArrayHashMapUnmanaged(Override) = .empty,
    /// A key is being typed into Settings; the app's own keys stand aside.
    recording: bool = false,
    /// Told after every change, saved (the menu bar's keys follow, app/menus.zig).
    on_change: ?*const fn (*const Shortcuts) void = null,
    /// The keys loaded extensions' manifests asked for, by `ext:` id, kept
    /// for this run (`manifest`, Shortcuts.swift:253).
    manifest: std.StringArrayHashMapUnmanaged(Override) = .empty,
    /// The extensions, while there are (ext/commands.zig hands keys to WebKit).
    ext: ?*@import("../ext/controller.zig").Extensions = null,

    pub fn init(gpa: std.mem.Allocator, store: *const Store) Shortcuts {
        var s: Shortcuts = .{ .gpa = gpa, .store = store };
        s.read();
        return s;
    }

    pub fn deinit(self: *Shortcuts) void {
        self.clearAll();
        self.changed.deinit(self.gpa);
        for (self.manifest.keys(), self.manifest.values()) |id, o| {
            self.gpa.free(id);
            if (o.key) |kc| self.gpa.free(kc.key);
        }
        self.manifest.deinit(self.gpa);
    }

    /// `manifest[id] = Override(key:)`: what an extension's command came with.
    pub fn noteManifest(self: *Shortcuts, id: []const u8, kc: ?KeyCombo) void {
        var copy: Override = .{ .key = kc };
        if (kc) |k| copy.key.?.key = self.gpa.dupe(u8, k.key) catch return;
        const got = self.manifest.getOrPut(self.gpa, id) catch {
            if (copy.key) |k| self.gpa.free(k.key);
            return;
        };
        if (got.found_existing) {
            if (got.value_ptr.key) |old| self.gpa.free(old.key);
        } else got.key_ptr.* = self.gpa.dupe(u8, id) catch {
            self.manifest.swapRemoveAt(got.index);
            if (copy.key) |k| self.gpa.free(k.key);
            return;
        };
        got.value_ptr.* = copy;
    }

    pub fn reload(self: *Shortcuts) void {
        self.clearAll();
        self.read();
    }

    /// With the rules the Settings box keeps: a key that isn't ours to
    /// give stays the Mac's, whatever the file says.
    fn read(self: *Shortcuts) void {
        const bytes = self.store.data(defaults_key) orelse return;
        defer self.store.gpa.free(bytes);
        const parsed = json.decode(json.Map(Override), self.gpa, bytes) catch return;
        defer parsed.deinit();
        var it = parsed.value.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.key) |kc| {
                if (isReserved(kc) or (std.mem.startsWith(u8, e.key_ptr.*, "ext:") and isBrowserOnly(kc))) continue;
            }
            self.put(e.key_ptr.*, e.value_ptr.*) catch return;
        }
    }

    fn put(self: *Shortcuts, id: []const u8, o: Override) !void {
        const key = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(key);
        var copy = o;
        if (o.key) |kc| copy.key.?.key = try self.gpa.dupe(u8, kc.key);
        errdefer if (copy.key) |kc| self.gpa.free(kc.key);
        self.drop(key);
        try self.changed.put(self.gpa, key, copy);
    }

    fn drop(self: *Shortcuts, id: []const u8) void {
        const kv = self.changed.fetchOrderedRemove(id) orelse return;
        self.gpa.free(kv.key);
        if (kv.value.key) |kc| self.gpa.free(kc.key);
    }

    fn clearAll(self: *Shortcuts) void {
        for (self.changed.keys(), self.changed.values()) |id, o| {
            self.gpa.free(id);
            if (o.key) |kc| self.gpa.free(kc.key);
        }
        self.changed.clearRetainingCapacity();
    }

    /// `key(for:)`: the key `id` has as things stand.
    pub fn effective(self: *const Shortcuts, id: []const u8) ?KeyCombo {
        if (self.changed.get(id)) |o| return o.key;
        return self.defaultKey(id);
    }

    /// An extension command's is what its manifest asked for, while no key
    /// of Kea's is in the way: checked each time, so moving or resetting
    /// one of Kea's commands frees or takes an extension's key at once.
    fn defaultKey(self: *const Shortcuts, id: []const u8) ?KeyCombo {
        if (!std.mem.startsWith(u8, id, "ext:")) return if (commands.named(id)) |cmd| cmd.default_key else null;
        const kc = (self.manifest.get(id) orelse return null).key orelse return null;
        return if (self.keepsFromExtensions(kc)) null else kc;
    }

    pub fn isChanged(self: *const Shortcuts, id: []const u8) bool {
        return self.changed.contains(id);
    }

    pub fn anyChanged(self: *const Shortcuts) bool {
        return self.changed.count() > 0;
    }

    /// A command you gave `kc`, for the key monitor to run.
    pub fn changedCommand(self: *const Shortcuts, kc: KeyCombo) ?*const Command {
        for (&commands.all) |*cmd| if (self.changed.contains(cmd.id) and same(self.effective(cmd.id), kc)) return cmd;
        return null;
    }

    /// A key an extension may not have: the Mac's, or one of Kea's commands' now.
    pub fn keepsFromExtensions(self: *const Shortcuts, kc: KeyCombo) bool {
        if (isReserved(kc) or isBrowserOnly(kc)) return true;
        for (commands.all) |cmd| if (same(self.effective(cmd.id), kc)) return true;
        return false;
    }

    /// A key the menus had that no command has now: the page's again —
    /// unless you gave it to an extension's command.
    pub fn isFreed(self: *const Shortcuts, kc: KeyCombo) bool {
        var moved = false;
        for (commands.all) |cmd| {
            if (same(cmd.default_key, kc) and self.changed.contains(cmd.id)) moved = true;
            if (same(self.effective(cmd.id), kc)) return false;
        }
        if (moved) if (self.ext) |e| if (ext_commands.owner(e, kc, "")) |c| {
            self.gpa.free(c.id);
            self.gpa.free(c.title);
            return false;
        };
        return moved;
    }

    /// The command already on `kc`, other than `except`.
    pub fn owner(self: *const Shortcuts, kc: KeyCombo, except: []const u8) ?*const Command {
        for (&commands.all) |*cmd| if (!std.mem.eql(u8, cmd.id, except) and same(self.effective(cmd.id), kc)) return cmd;
        return null;
    }

    /// `kc` for `id`, taken from whichever command had it.
    pub fn assign(self: *Shortcuts, kc: KeyCombo, id: []const u8) void {
        // `kc` may be one this store returned (`effective`), freed by the drop below.
        var buf: [32]u8 = undefined;
        if (kc.key.len > buf.len) return;
        @memcpy(buf[0..kc.key.len], kc.key);
        var own = kc;
        own.key = buf[0..kc.key.len];
        if (self.owner(own, id)) |other| self.setOverride(other.id, null) else if (self.ext) |e| if (ext_commands.owner(e, own, id)) |c| {
            defer self.gpa.free(c.id);
            defer self.gpa.free(c.title);
            self.setOverride(c.id, null);
        };
        self.setOverride(id, own);
    }

    pub fn clear(self: *Shortcuts, id: []const u8) void {
        self.setOverride(id, null);
    }

    /// `set(_:for:)`: only a difference from the default is kept.
    pub fn setOverride(self: *Shortcuts, id: []const u8, kc: ?KeyCombo) void {
        if (sameOpt(kc, self.defaultKey(id))) self.drop(id) else self.put(id, .{ .key = kc }) catch return;
        self.save();
    }

    pub fn reset(self: *Shortcuts, id: []const u8) void {
        self.drop(id);
        self.save();
    }

    pub fn resetAll(self: *Shortcuts) void {
        self.clearAll();
        self.save();
    }

    fn save(self: *const Shortcuts) void {
        defer if (self.ext) |e| ext_commands.applyAll(e);
        defer if (self.on_change) |f| f(self);
        if (self.changed.count() == 0) return self.store.remove(defaults_key);
        const bytes = json.encode(self.gpa, json.Map(Override){ .map = self.changed }) catch return;
        defer self.gpa.free(bytes);
        self.store.setData(defaults_key, bytes);
    }
};

fn same(a: ?KeyCombo, b: KeyCombo) bool {
    return if (a) |x| x.eql(b) else false;
}

fn sameOpt(a: ?KeyCombo, b: ?KeyCombo) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

test "reserved keys and display" {
    try std.testing.expect(isReserved(combo("q", .{})));
    try std.testing.expect(isReserved(combo("3", .{})));
    try std.testing.expect(isReserved(combo("3", .{ .command = false, .control = true })));
    try std.testing.expect(!isReserved(combo("3", .{ .control = true })));
    try std.testing.expect(isReserved(combo("tab", .{ .option = true })));
    try std.testing.expect(!isReserved(combo("t", .{})));
    try std.testing.expect(combo("=", .{ .shift = true }).eql(combo("+", .{})));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("⌃⌥⇧⌘T", try std.fmt.bufPrint(&buf, "{f}", .{combo("t", .{ .shift = true, .option = true, .control = true })}));
    try std.testing.expectEqualStrings("⇧⌘⌫", try std.fmt.bufPrint(&buf, "{f}", .{combo("delete", .{ .shift = true })}));
    try std.testing.expect(!combo("a", .{ .command = false, .shift = true }).isUsable());
    try std.testing.expect(combo("f5", .{ .command = false }).isUsable());
}

test "an extension command keeps its manifest key unless Kea has it" {
    var s: Shortcuts = .{ .gpa = std.testing.allocator, .store = undefined };
    defer s.deinit();
    const free_a = combo("j", .{ .command = false, .control = true, .shift = true });
    const free_b = combo("k", .{ .command = false, .control = true, .shift = true });
    s.noteManifest("ext:a:go", free_a);
    s.noteManifest("ext:a:new", combo("t", .{}));
    s.noteManifest("ext:a:none", null);
    try std.testing.expect(s.effective("ext:a:go").?.eql(free_a));
    // ⌘T is New Tab's: the extension doesn't get it.
    try std.testing.expect(s.effective("ext:a:new") == null);
    try std.testing.expect(s.effective("ext:a:none") == null);
    s.noteManifest("ext:a:go", free_b);
    try std.testing.expect(s.effective("ext:a:go").?.eql(free_b));
}
