//! The side panel (a tab of its own: this window has one column) and the
//! button's popup (ExtensionShims.swift 3590-3605, 3795-3805).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");
const val = @import("../value.zig");
const offscreen = @import("../offscreen.zig");
const Extensions = @import("../controller.zig").Extensions;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    const first = c.first();
    const s = &c.owner.answer;
    const gpa = c.owner.gpa;
    if (eql(api, "sidePanel.setOptions")) {
        if (ans.str(ans.field(first, "path"))) |path| try ans.putString(gpa, &s.panel_path, c.id, path);
        return ans.none;
    }
    if (eql(api, "sidePanel.getOptions")) {
        const path = s.panel_path.get(c.id) orelse defaultPanel(c.a, c.context) orelse "";
        return try c.give(.{ .enabled = true, .path = path });
    }
    if (eql(api, "sidePanel.setPanelBehavior")) {
        if (ans.flag(ans.field(first, "openPanelOnActionClick"))) |on| {
            if (on) {
                if (!s.panel_on_click.contains(c.id)) {
                    const key = try gpa.dupe(u8, c.id);
                    errdefer gpa.free(key);
                    try s.panel_on_click.put(gpa, key, {});
                }
            } else if (s.panel_on_click.fetchRemove(c.id)) |kv| gpa.free(kv.key);
        }
        return ans.none;
    }
    if (eql(api, "sidePanel.getPanelBehavior")) return try c.give(.{ .openPanelOnActionClick = s.panel_on_click.contains(c.id) });
    if (eql(api, "sidePanel.open")) {
        openPanel(c.owner, c.context);
        return ans.none;
    }
    if (eql(api, "action.popup")) {
        const path = ans.str(first) orelse "";
        const index = ans.int(c.arg(1)) orelse -1;
        const tabs = try c.owner.visibleTabs(gpa, null);
        defer gpa.free(tabs);
        const gop = try s.popups.getOrPut(gpa, c.id);
        if (!gop.found_existing) {
            gop.key_ptr.* = gpa.dupe(u8, c.id) catch |e| {
                s.popups.removeByPtr(gop.key_ptr);
                return e;
            };
            gop.value_ptr.* = .empty;
        }
        const per = gop.value_ptr;
        if (index >= 0 and index < tabs.len) {
            var buf: [24]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{d}", .{tabs[@intCast(index)].id}) catch unreachable;
            try ans.putString(gpa, per, key, path);
        } else {
            try ans.putString(gpa, per, "*", path);
            // Only "*" left.
            var others: std.ArrayList([]const u8) = .empty;
            var it = per.keyIterator();
            while (it.next()) |k| if (!eql(k.*, "*")) try others.append(c.a, k.*);
            for (others.items) |k| if (per.fetchRemove(k)) |kv| {
                gpa.free(kv.value);
                gpa.free(kv.key);
            };
        }
        return ans.none;
    }
    return null;
}

/// The manifest's `side_panel.default_path`, on `a`.
pub fn defaultPanel(a: std.mem.Allocator, context: objc.Object) ?[]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ext = objc.msg(objc.Object, context, "webExtension", .{});
    const parsed = val.toJson(a, objc.msg(?objc.Object, ext, "manifest", .{})) orelse return null;
    return ans.str(ans.field(ans.field(parsed.value, "side_panel"), "default_path"));
}

/// `openPanel(_:owner:)`: the panel's page in a tab in front.
pub fn openPanel(owner: *Extensions, context: objc.Object) void {
    var arena = std.heap.ArenaAllocator.init(owner.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = objc.fromNSString(objc.msg(?objc.Object, context, "uniqueIdentifier", .{}));
    const path = owner.answer.panel_path.get(id) orelse defaultPanel(a, context) orelse return;
    const url = offscreen.page(path, context) orelse return;
    const b = owner.browser() orelse return;
    _ = b.open(objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{})), .{ .foreground = true });
}

/// Whether the button opens the side panel.
pub fn panelOnClick(owner: *Extensions, id: []const u8) bool {
    return owner.answer.panel_on_click.contains(id);
}

/// The popup set for the button in `tab_key` (decimal tab id), else for all tabs.
pub fn popupFor(owner: *Extensions, id: []const u8, tab_key: ?[]const u8) ?[]const u8 {
    const per = owner.answer.popups.get(id) orelse return null;
    if (tab_key) |k| if (per.get(k)) |p| return p;
    return per.get("*");
}
