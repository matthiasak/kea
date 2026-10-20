//! Extension commands in Settings › Shortcuts (#189, Shortcuts.swift:375-430):
//! the keys an extension's manifest asks for, set otherwise there as WebKit
//! means them to be — it matches the key it is given (`activationKey`,
//! `modifierFlags`), and the app keeps it. Only single keys, as a manifest
//! has them. Ids are "ext:<extension id>:<command id>".
const std = @import("std");
const objc = @import("nanoui").objc;
const shortcuts = @import("../app/shortcuts.zig");
const KeyCombo = shortcuts.KeyCombo;
const Shortcuts = shortcuts.Shortcuts;
const Extensions = @import("controller.zig").Extensions;

/// `ExtensionCommand`. `id` and `title` are owned (free with `freeList`);
/// `extension_name` is the installed row's; `command` is WebKit's.
pub const ExtCommand = struct {
    id: []u8,
    extension_name: []const u8,
    title: []u8,
    command: objc.Object,
};

fn commandsOf(context: objc.Object) objc.Object {
    return objc.msg(objc.Object, context, "commands", .{});
}

/// `extensionCommands()`: every loaded extension's commands, by extension id.
pub fn list(self: *Extensions, gpa: std.mem.Allocator) ![]ExtCommand {
    const ids = try gpa.dupe([]const u8, self.contexts.keys());
    defer gpa.free(ids);
    std.mem.sort([]const u8, ids, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var out: std.ArrayList(ExtCommand) = .empty;
    errdefer freeList(gpa, out.items);
    errdefer out.deinit(gpa);
    for (ids) |ext| {
        const cmds = commandsOf(self.contexts.get(ext).?);
        const name = if (self.row(ext)) |r| r.name else ext;
        for (0..objc.msg(objc.NSUInteger, cmds, "count", .{})) |i| {
            const c = objc.msg(objc.Object, cmds, "objectAtIndex:", .{i});
            const id = try idFor(gpa, ext, c);
            errdefer gpa.free(id);
            const title = try gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, c, "title", .{})));
            try out.append(gpa, .{ .id = id, .extension_name = name, .title = title, .command = c });
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeList(gpa: std.mem.Allocator, items: []const ExtCommand) void {
    for (items) |c| {
        gpa.free(c.id);
        gpa.free(c.title);
    }
    gpa.free(items);
}

fn idFor(gpa: std.mem.Allocator, ext: []const u8, command: objc.Object) ![]u8 {
    return std.fmt.allocPrint(gpa, "ext:{s}:{s}", .{ ext, objc.fromNSString(objc.msg(?objc.Object, command, "identifier", .{})) });
}

/// `KeyCombo(activation:flags:)`: the key WebKit holds, lowercased into `buf`.
fn keyOf(command: objc.Object, buf: []u8) ?KeyCombo {
    const pool = objc.Pool.push();
    defer pool.pop();
    const key = objc.msg(?objc.Object, command, "activationKey", .{}) orelse return null;
    const text = objc.fromNSString(objc.msg(objc.Object, key, "lowercaseString", .{}));
    if (text.len == 0 or text.len > buf.len) return null;
    @memcpy(buf[0..text.len], text);
    const flags: u64 = objc.msg(objc.NSUInteger, command, "modifierFlags", .{});
    const f = shortcuts.flag;
    return shortcuts.combo(buf[0..text.len], .{ .command = flags & f.command != 0, .shift = flags & f.shift != 0, .option = flags & f.option != 0, .control = flags & f.control != 0 });
}

/// An extension command's key, handed to WebKit, which matches it.
fn hand(command: objc.Object, kc: ?KeyCombo) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const f = shortcuts.flag;
    var flags: u64 = 0;
    if (kc) |k| {
        if (k.command) flags |= f.command;
        if (k.shift) flags |= f.shift;
        if (k.option) flags |= f.option;
        if (k.control) flags |= f.control;
    }
    objc.msg(void, command, "setActivationKey:", .{if (kc) |k| objc.nsString(k.key) else @as(?objc.Object, null)});
    objc.msg(void, command, "setModifierFlags:", .{@as(objc.NSUInteger, flags)});
}

/// `adopt(_:id:)`: an extension just loaded — the keys it came with noted,
/// and yours put in their place. A key its manifest asks for that is the
/// Mac's, or one of Kea's commands', it doesn't get.
pub fn adopt(self: *Extensions, context: objc.Object, ext: []const u8) void {
    const s = &self.kea.shortcuts;
    const cmds = commandsOf(context);
    for (0..objc.msg(objc.NSUInteger, cmds, "count", .{})) |i| {
        const c = objc.msg(objc.Object, cmds, "objectAtIndex:", .{i});
        const id = idFor(s.gpa, ext, c) catch continue;
        defer s.gpa.free(id);
        var buf: [32]u8 = undefined;
        // What WebKit holds is the manifest's on a fresh load, or an
        // update's; once applied here, it is ours, and not taken again.
        const current = keyOf(c, &buf);
        if (!s.manifest.contains(id) or !same(current, s.effective(id))) s.noteManifest(id, current);
        hand(c, s.effective(id));
    }
}

/// `applyExtensions()`: every extension command's key as it now stands —
/// a change to one of Kea's can free or take an extension's.
pub fn applyAll(self: *Extensions) void {
    const s = &self.kea.shortcuts;
    const all = list(self, s.gpa) catch return;
    defer freeList(s.gpa, all);
    for (all) |c| hand(c.command, s.effective(c.id));
}

/// The extension command on `kc`, other than `except` (owned id), for
/// `owner(of:except:)`'s second half.
pub fn owner(self: *Extensions, kc: KeyCombo, except: []const u8) ?ExtCommand {
    const s = &self.kea.shortcuts;
    const all = list(self, s.gpa) catch return null;
    var found: ?ExtCommand = null;
    for (all) |c| {
        if (found == null and !std.mem.eql(u8, c.id, except) and same(s.effective(c.id), kc)) {
            found = c;
            continue;
        }
        s.gpa.free(c.id);
        s.gpa.free(c.title);
    }
    s.gpa.free(all);
    return found;
}

fn same(a: ?KeyCombo, b: ?KeyCombo) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}
