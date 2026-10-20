//! chrome.privacy/proxy settings (`setting`/`defaultSetting`,
//! ExtensionShims.swift 4222-4251) and chrome.permissions (3840-3899).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");
const asking = @import("../controller_asking.zig");
const fencing = @import("../controller_fence.zig");

const Value = ans.Value;
const granted_explicitly: objc.NSInteger = 3; // WKWebExtensionContextPermissionStatusGrantedExplicitly

/// `setting`: `c.api` is `setting.get|set|clear:<name>`.
pub fn setting(c: *ans.Call, name: []const u8) ans.Error!Value {
    const colon = std.mem.indexOfScalar(u8, c.api, ':') orelse return .null;
    const verb = c.api[0..colon];
    const parsed = c.owner.settings(c.id);
    defer if (parsed) |p| p.deinit();
    var mine: std.json.ObjectMap = .empty;
    if (parsed) |p| if (p.value == .object) {
        var it = p.value.object.iterator();
        while (it.next()) |e| try mine.put(c.a, e.key_ptr.*, e.value_ptr.*);
    };
    if (std.mem.eql(u8, verb, "setting.set")) {
        const details = c.first();
        const v: ?Value = if (details != null and details.? == .object) details.?.object.get("value") else null;
        if (v) |x| try mine.put(c.a, name, x) else _ = mine.orderedRemove(name);
    } else if (std.mem.eql(u8, verb, "setting.clear")) {
        _ = mine.orderedRemove(name);
    } else {
        const own = mine.get(name);
        var out: std.json.ObjectMap = .empty;
        try out.put(c.a, "value", try c.of(own orelse defaultSetting(c, name)));
        try out.put(c.a, "levelOfControl", .{ .string = if (own != null) "controlled_by_this_extension" else "controllable_by_this_extension" });
        return .{ .object = out };
    }
    c.owner.setSettings(c.id, .{ .object = mine });
    // `owner.objectWillChange.send()`: Settings › Extensions draws again.
    c.owner.actions_changed +%= 1;
    return .null;
}

fn defaultSetting(c: *ans.Call, name: []const u8) Value {
    const eql = std.mem.eql;
    if (eql(u8, name, "privacy.services.passwordSavingEnabled"))
        return .{ .bool = if (c.owner.browser()) |b| b.kea.prefs.saves_passwords else true };
    if (eql(u8, name, "privacy.network.webRTCIPHandlingPolicy")) return .{ .string = "default" };
    for ([_][]const u8{
        "privacy.websites.doNotTrackEnabled",  "privacy.websites.adMeasurementEnabled",
        "privacy.websites.fledgeEnabled",      "privacy.websites.topicsEnabled",
        "privacy.services.safeBrowsingExtendedReportingEnabled",
    }) |n| if (eql(u8, name, n)) return .{ .bool = false };
    if (eql(u8, name, "proxy.settings")) {
        var o: std.json.ObjectMap = .empty;
        o.put(c.a, "mode", .{ .string = "system" }) catch return .null;
        return .{ .object = o };
    }
    return .{ .bool = true };
}

/// Those Chrome grants without a word, having nothing to warn of.
const silent = [_][]const u8{
    "tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search",
    "system.cpu", "system.memory", "system.display", "favicon",
};

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    if (!std.mem.startsWith(u8, api, "permissions.")) return null;
    if (std.mem.eql(u8, api, "permissions.granted")) return try c.give(try ans.granted(c.a, c.owner, c.id));
    if (std.mem.eql(u8, api, "permissions.remove")) {
        const gone = try ans.allStrings(c.a, c.first()) orelse &.{};
        var keep: std.ArrayList([]const u8) = .empty;
        for (try ans.granted(c.a, c.owner, c.id)) |g| if (!ans.contains(gone, g)) try keep.append(c.a, g);
        ans.setGranted(c.a, c.owner, c.id, keep.items) catch return error.OutOfMemory;
        return .{ .value = .{ .bool = true } };
    }
    if (std.mem.eql(u8, api, "permissions.request")) return try request(c);
    if (std.mem.eql(u8, api, "permissions.afterClick")) return try afterClick(c);
    return null;
}

const Asked = struct {
    c: *ans.Call,
    wanted: []const []const u8 = &.{},
    /// afterClick: what's missing (retained NSArrays of NSString / match patterns).
    missing: ?objc.Object = null,
    unreached: ?objc.Object = null,
};

fn request(c: *ans.Call) ans.Error!?ans.Out {
    const wanted = try ans.allStrings(c.a, c.first()) orelse &.{};
    const m = c.manifest();
    var named: std.ArrayList([]const u8) = .empty;
    try named.appendSlice(c.a, try ans.strings(c.a, ans.field(m, "permissions")));
    try named.appendSlice(c.a, try ans.strings(c.a, ans.field(m, "optional_permissions")));
    for (wanted) |w| if (!ans.contains(named.items, w)) return c.fail("Only permissions specified in the manifest may be requested.", .{});
    const s = try c.a.create(Asked);
    s.* = .{ .c = c, .wanted = wanted };
    for (wanted) |w| {
        if (!ans.contains(&silent, w)) break;
    } else {
        requested(s, true);
        return .later;
    }
    var names: std.ArrayList(u8) = .empty;
    for (wanted, 0..) |w, i| {
        if (i > 0) try names.appendSlice(c.a, ", ");
        const at = names.items.len;
        try names.appendSlice(c.a, w);
        std.mem.replaceScalar(u8, names.items[at..], '.', ' ');
    }
    asking.askMore(c.owner, names.items, c.context, s, requestedCb);
    return .later;
}

fn requestedCb(ctx: *anyopaque, yes: bool) void {
    requested(@ptrCast(@alignCast(ctx)), yes);
}

fn requested(s: *Asked, yes: bool) void {
    const c = s.c;
    if (!yes) return c.pending.value(.{ .bool = false });
    var all: std.ArrayList([]const u8) = .empty;
    const had = ans.granted(c.a, c.owner, c.id) catch &.{};
    for ([_][]const []const u8{ had, s.wanted }) |part| for (part) |n|
        if (!ans.contains(all.items, n)) all.append(c.a, n) catch return c.pending.fail("Out of memory");
    sortStrings(all.items);
    ans.setGranted(c.a, c.owner, c.id, all.items) catch return c.pending.fail("Out of memory");
    c.pending.value(.{ .bool = true });
}

fn afterClick(c: *ans.Call) ans.Error!?ans.Out {
    if (!asking.takeClick(c.owner, c.id, 10))
        return c.fail("Invalid call to permissions.request(). Must be called during a user gesture.", .{});
    const pool = objc.Pool.push();
    defer pool.pop();
    const found = c.webExtension();
    const wanted = try ans.allStrings(c.a, c.first()) orelse &.{};
    const named_set = objc.msg(objc.Object, objc.msg(objc.Object, found, "requestedPermissions", .{}), "setByAddingObjectsFromSet:", .{
        objc.msg(objc.Object, found, "optionalPermissions", .{}),
    });
    const place_set = objc.msg(objc.Object, objc.msg(objc.Object, found, "allRequestedMatchPatterns", .{}), "setByAddingObjectsFromSet:", .{
        objc.msg(objc.Object, found, "optionalPermissionMatchPatterns", .{}),
    });
    const places = objc.msg(objc.Object, place_set, "valueForKey:", .{objc.nsString("string")});
    const missing = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    const unreached = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (wanted) |w| {
        const p = objc.nsString(w);
        if (!objc.msg(objc.BOOL, named_set, "containsObject:", .{p}))
            return c.fail("Only permissions specified in the manifest may be requested.", .{});
        if (objc.msg(objc.NSInteger, c.context, "permissionStatusForPermission:", .{p}) != granted_explicitly)
            objc.msg(void, missing, "addObject:", .{p});
    }
    var every = false;
    var sites: std.ArrayList([]const u8) = .empty;
    for (try ans.allStrings(c.a, c.arg(1)) orelse &.{}) |o| {
        const pattern = objc.msg(?objc.Object, objc.class("WKWebExtensionMatchPattern"), "matchPatternWithString:", .{objc.nsString(o)}) orelse continue;
        if (fencing.withheld(pattern)) continue;
        const text = objc.msg(objc.Object, pattern, "string", .{});
        if (!objc.msg(objc.BOOL, places, "containsObject:", .{text}))
            return c.fail("Only permissions specified in the manifest may be requested.", .{});
        if (objc.msg(objc.NSInteger, c.context, "permissionStatusForMatchPattern:", .{pattern}) == granted_explicitly) continue;
        objc.msg(void, unreached, "addObject:", .{pattern});
        every = every or objc.msg(objc.BOOL, pattern, "matchesAllHosts", .{}) or objc.msg(objc.BOOL, pattern, "matchesAllURLs", .{});
        try sites.append(c.a, try c.a.dupe(u8, objc.fromNSString(text)));
    }
    const n_missing = objc.msg(objc.NSUInteger, missing, "count", .{});
    if (n_missing == 0 and sites.items.len == 0) return .{ .value = .{ .bool = true } };
    var wants: std.ArrayList([]const u8) = .empty;
    for (wanted) |w| if (objc.msg(objc.NSInteger, c.context, "permissionStatusForPermission:", .{objc.nsString(w)}) != granted_explicitly)
        try wants.append(c.a, w);
    sortStrings(sites.items);
    sortStrings(wants.items);
    const question = if (sites.items.len == 0) "asks for more access" else try std.fmt.allocPrint(c.a, "wants to read and change {s}", .{
        if (every) "every website" else try std.mem.join(c.a, ", ", sites.items),
    });
    const detail = if (wants.items.len == 0) "Until you remove the extension." else try std.mem.join(c.a, ", ", wants.items);
    const s = try c.a.create(Asked);
    s.* = .{ .c = c, .missing = objc.retain(missing), .unreached = objc.retain(unreached) };
    asking.ask(c.owner, question, detail, c.context, s, clicked);
    return .later;
}

fn clicked(ctx: *anyopaque, yes: bool) void {
    const s: *Asked = @ptrCast(@alignCast(ctx));
    const c = s.c;
    const missing = s.missing.?;
    const unreached = s.unreached.?;
    defer objc.release(missing);
    defer objc.release(unreached);
    if (!yes) return c.pending.value(.{ .bool = false });
    const pool = objc.Pool.push();
    defer pool.pop();
    for ([_]struct { objc.Object, [:0]const u8 }{
        .{ missing, "setPermissionStatus:forPermission:" },
        .{ unreached, "setPermissionStatus:forMatchPattern:" },
    }) |pair| {
        const n = objc.msg(objc.NSUInteger, pair[0], "count", .{});
        var i: objc.NSUInteger = 0;
        while (i < n) : (i += 1) objc.msg(void, c.context, pair[1], .{ granted_explicitly, objc.msg(objc.Object, pair[0], "objectAtIndex:", .{i}) });
    }
    fencing.fence(c.context);
    c.pending.value(.{ .bool = true });
}

fn sortStrings(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}
