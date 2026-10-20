//! scripting.file and chrome.userScripts (ExtensionShims.swift 3807-3838).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");
const install = @import("install.zig");
const files = @import("install_files.zig");

const Value = ans.Value;

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    const eql = std.mem.eql;
    const known = eql(u8, api, "scripting.file") or eql(u8, api, "userScripts.file") or eql(u8, api, "userScripts.list") or
        eql(u8, api, "userScripts.save") or eql(u8, api, "userScripts.world") or eql(u8, api, "userScripts.worlds");
    if (!known) return null;
    const folder = blk: {
        const f = c.owner.folderFor(c.id) catch return error.OutOfMemory;
        defer c.owner.gpa.free(f);
        break :blk try c.a.dupe(u8, f);
    };
    if (eql(u8, api, "scripting.file")) {
        const rel = install.scriptingFile(c.a, ans.str(c.first()) orelse "", ans.list(c.arg(1)) orelse &.{}, folder) catch |e|
            return if (e == error.OutOfMemory) error.OutOfMemory else c.fail(files.invalid_script, .{});
        return .{ .value = .{ .string = rel } };
    }
    if (eql(u8, api, "userScripts.file")) {
        const rel = install.userScriptFile(c.a, object(c.first()), folder) catch |e| return c.fail("{s}", .{@errorName(e)});
        return .{ .value = .{ .string = rel } };
    }
    const kea_dir = try std.fs.path.join(c.a, &.{ folder, "_kea" });
    if (eql(u8, api, "userScripts.list"))
        return .{ .value = readJson(c.a, try std.fs.path.join(c.a, &.{ kea_dir, "userscripts.json" })) orelse .{ .array = .init(c.a) } };
    if (eql(u8, api, "userScripts.save")) {
        try makeDir(c, kea_dir);
        try save(c, kea_dir, folder, objects(c.first()));
        return ans.none;
    }
    // userScripts.world / worlds
    const path = try std.fs.path.join(c.a, &.{ kea_dir, "worlds.json" });
    var worlds: std.json.Array = .init(c.a);
    try worlds.appendSlice(objects(readJson(c.a, path)));
    if (eql(u8, api, "userScripts.worlds")) return .{ .value = .{ .array = worlds } };
    const props = c.first();
    const world = ans.str(ans.field(props, "worldId")) orelse "";
    var i: usize = 0;
    while (i < worlds.items.len) {
        if (eql(u8, ans.str(ans.field(worlds.items[i], "worldId")) orelse "", world)) _ = worlds.orderedRemove(i) else i += 1;
    }
    if (ans.flag(ans.field(props, "reset")) != true)
        try worlds.append(if (ans.isObject(props)) props.? else .{ .object = .empty });
    try makeDir(c, kea_dir);
    try writeJson(c, path, .{ .array = worlds });
    return ans.none;
}

/// `userScripts.save`: the list written, then files no saved script is
/// written in any more removed once a minute has passed.
fn save(c: *ans.Call, kea_dir: []const u8, folder: []const u8, scripts: []const Value) ans.Error!void {
    var list: std.json.Array = .init(c.a);
    try list.appendSlice(scripts);
    try writeJson(c, try std.fs.path.join(c.a, &.{ kea_dir, "userscripts.json" }), .{ .array = list });
    var keep: std.ArrayList([]const u8) = .empty;
    for (scripts) |s| if (install.userScriptFile(c.a, s.object, folder)) |rel| try keep.append(c.a, std.fs.path.basename(rel)) else |_| {};
    var entries: std.ArrayList(files.Entry) = .empty;
    try files.walk(c.a, kea_dir, &entries);
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    for (entries.items) |e| {
        const name = std.fs.path.basename(e.path);
        if (e.dir or !std.mem.eql(u8, std.fs.path.dirname(e.path) orelse "", kea_dir)) continue;
        if (!std.mem.startsWith(u8, name, "us-") or ans.contains(keep.items, name)) continue;
        const attrs = objc.msg(?objc.Object, fm, "attributesOfItemAtPath:error:", .{ objc.nsString(e.path), @as(?*anyopaque, null) });
        const date = if (attrs) |a| objc.msg(?objc.Object, a, "fileModificationDate", .{}) else null;
        const age = if (date) |d| -objc.msg(f64, d, "timeIntervalSinceNow", .{}) else 999;
        if (age > 60) files.remove(c.a, e.path);
    }
}

fn object(v: ?Value) std.json.ObjectMap {
    if (v) |x| if (x == .object) return x.object;
    return .empty;
}

fn readJson(a: std.mem.Allocator, path: []const u8) ?Value {
    const text = files.read(a, path) orelse return null;
    return std.json.parseFromSliceLeaky(Value, a, text, .{}) catch null;
}

/// `as? [[String: Any]] ?? []`.
fn objects(v: ?Value) []const Value {
    const items = ans.list(v) orelse return &.{};
    for (items) |x| if (x != .object) return &.{};
    return items;
}

fn writeJson(c: *ans.Call, path: []const u8, v: Value) ans.Error!void {
    const text = try std.json.Stringify.valueAlloc(c.a, v, .{});
    files.write(c.a, path, text) catch |e| return c.fail("{s}", .{@errorName(e)});
}

fn makeDir(c: *ans.Call, dir: []const u8) ans.Error!void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    if (!objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
        objc.nsString(dir), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
    })) return c.fail("Couldn\u{2019}t create the folder \u{201C}_kea\u{201D}", .{});
}
