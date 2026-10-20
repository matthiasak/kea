//! The buttons (Extensions.swift 1205-1336): one per loaded extension with
//! something to press, the puzzle button's list, pressing one, and the keys
//! extensions register. Views are the UI wave's: they read `buttons`,
//! `del.menu_open`, `del.anchors` and call `press`.
const std = @import("std");
const objc = @import("nanoui").objc;
const Extensions = @import("controller.zig").Extensions;
const ext = @import("ext.zig");
const state = @import("controller_delegate_state.zig");
const fence = @import("controller_fence.zig");
const adapters = @import("adapters.zig");
const answer = @import("shims/answer.zig");
const appkit = @import("../sys/appkit.zig");
const json = @import("../data/json.zig");

/// Where a popup hangs when its extension isn't pinned: the puzzle button.
pub const menu_anchor = "__menu";

pub const Button = struct {
    /// Borrowed from the installed row: valid until the list changes.
    id: []const u8,
    name: []const u8,
    /// gpa-owned.
    label: []u8,
    /// 16×16, retained.
    icon: ?objc.Object,
    /// gpa-owned.
    badge: []u8,
    enabled: bool,
    pinned: bool,
};

pub fn freeButtons(gpa: std.mem.Allocator, list: []Button) void {
    for (list) |b| {
        gpa.free(b.label);
        gpa.free(b.badge);
        if (b.icon) |i| objc.release(i);
    }
    gpa.free(list);
}

/// `buttons`: in install order, for the active tab of the browser in front.
/// Redraw when `actions_changed` moves.
pub fn buttons(self: *Extensions, gpa: std.mem.Allocator) ![]Button {
    const pool = objc.Pool.push();
    defer pool.pop();
    const tab: ?objc.Object = if (self.browser()) |b| adapters.activeAdapter(self, b) else null;
    var out: std.ArrayList(Button) = .empty;
    errdefer freeButtons(gpa, out.toOwnedSlice(gpa) catch &.{});
    for (self.installed.items) |*item| {
        const context = self.contexts.get(item.id) orelse continue;
        const action = objc.msg(?objc.Object, context, "actionForTab:", .{tab}) orelse continue;
        const label = objc.fromNSString(objc.msg(objc.Object, action, "label", .{}));
        const icon = objc.msg(?objc.Object, action, "iconForSize:", .{objc.CGSize{ .width = 16, .height = 16 }});
        try out.append(gpa, .{
            .id = item.id,
            .name = item.name,
            .label = try gpa.dupe(u8, if (label.len == 0) item.name else label),
            .icon = if (icon) |i| objc.retain(i) else null,
            .badge = try gpa.dupe(u8, objc.fromNSString(objc.msg(objc.Object, action, "badgeText", .{}))),
            .enabled = objc.msg(objc.BOOL, action, "isEnabled", .{}),
            .pinned = item.pinned orelse false,
        });
    }
    return out.toOwnedSlice(gpa);
}

/// `watchTouches`: a real click or key in one of an extension's pages (its
/// popup, or a page of its in a tab) stamps `touched`.
pub fn watchTouches(self: *Extensions) void {
    if (self.del.touching != null) return;
    const left_mouse_down: u64 = 1 << 1;
    self.del.touching = appkit.addLocalMonitor(left_mouse_down | appkit.mask.key_down, self, touchedBy);
}

fn touchedBy(self: *Extensions, event: objc.Object) ?objc.Object {
    const pool = objc.Pool.push();
    defer pool.pop();
    const window = objc.msg(?objc.Object, event, "window", .{}) orelse return event;
    const key_down: objc.NSUInteger = 10;
    var view: ?objc.Object = if (objc.msg(objc.NSUInteger, event, "type", .{}) == key_down)
        objc.msg(?objc.Object, window, "firstResponder", .{})
    else blk: {
        const content = objc.msg(?objc.Object, window, "contentView", .{}) orelse break :blk null;
        const frame = objc.msg(?objc.Object, content, "superview", .{}) orelse break :blk null;
        break :blk objc.msg(?objc.Object, frame, "hitTest:", .{objc.msg(objc.CGPoint, event, "locationInWindow", .{})});
    };
    const web_class = objc.class("WKWebView");
    while (view) |v| {
        if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSView")})) return event;
        if (objc.msg(objc.BOOL, v, "isKindOfClass:", .{web_class})) break;
        view = objc.msg(?objc.Object, v, "superview", .{});
    }
    const web = view orelse return event;
    const url = objc.msg(?objc.Object, web, "URL", .{}) orelse return event;
    const scheme = objc.fromNSString(objc.msg(?objc.Object, url, "scheme", .{}));
    if (!std.ascii.eqlIgnoreCase(scheme, ext.scheme)) return event;
    const host = objc.fromNSString(objc.msg(?objc.Object, url, "host", .{}));
    if (host.len > 0) state.stamp(self.gpa, &self.del.touched, host, json.now());
    return event;
}

/// `press`: its button or its line in the menu.
pub fn press(self: *Extensions, id: []const u8) void {
    const context = self.contexts.get(id) orelse return;
    if (self.del.popup_closes) |closes| if (closes(self, id)) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const now = json.now();
    state.stamp(self.gpa, &self.del.clicked, id, now);
    state.stamp(self.gpa, &self.del.pressed, id, now);
    const tab: ?objc.Object = if (self.browser()) |b| adapters.activeAdapter(self, b) else null;
    if (tab) |t| objc.msg(void, context, "userGesturePerformedInTab:", .{t});
    const action = objc.msg(?objc.Object, context, "actionForTab:", .{tab});
    const presents = if (action) |a| objc.msg(objc.BOOL, a, "presentsPopup", .{}) else false;
    // An extension that asked for its button to open its side panel.
    if (answer.panelOnClick(self, id) and !presents) return answer.openPanel(self, context);
    // A popup is opened here, straight away: left to WebKit, its own popup
    // built first lost the new popup's first messages to its worker.
    if (presents) if (popupURL(self, context)) |url| {
        defer self.gpa.free(url);
        return showPopup(self, url, context, id);
    };
    objc.msg(void, context, "performActionForTab:", .{tab});
}

/// `ExtensionPopup.shared.show(url, for:, from: anchor(for:))`: recorded on
/// the model and handed to the UI wave.
pub fn showPopup(self: *Extensions, url: []const u8, context: objc.Object, id: []const u8) void {
    const anchor = anchorFor(self, id);
    state.setPopupRequest(self, url, id, anchor);
    if (self.del.on_popup) |show| show(self, url, context, anchor);
}

/// `anchor(for:)`: its own button in the row when on screen, else the
/// puzzle button. Returns a key of `del.anchors`.
pub fn anchorFor(self: *Extensions, id: []const u8) []const u8 {
    if (self.del.anchors.getEntry(id)) |e| if (e.value_ptr.window != null) return e.key_ptr.*;
    return menu_anchor;
}

/// The UI wave records a button's place (`anchors[id] = WeakView(view)`).
pub fn setAnchor(self: *Extensions, id: []const u8, a: state.Anchor) void {
    if (self.del.anchors.getPtr(id)) |v| {
        v.* = a;
        return;
    }
    const key = self.gpa.dupe(u8, id) catch return;
    self.del.anchors.put(self.gpa, key, a) catch self.gpa.free(key);
}

/// `popupURL(for:)` (instance): the page the extension set for this tab or
/// all of them, else its manifest's. gpa-owned.
pub fn popupURL(self: *Extensions, context: objc.Object) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = objc.fromNSString(objc.msg(objc.Object, context, "uniqueIdentifier", .{}));
    var buf: [24]u8 = undefined;
    const key: ?[]const u8 = if (self.browser()) |b| if (b.activeTab()) |t| std.fmt.bufPrint(&buf, "{d}", .{t.id}) catch null else null else null;
    const path = answer.popupFor(self, id, key) orelse return fence.popupURL(self.gpa, context);
    if (path.len == 0) return null;
    return fence.relative(self.gpa, context, path);
}

/// `take(_:)`: a keystroke an extension registered.
pub fn take(self: *Extensions, event: objc.Object) bool {
    for (self.contexts.values()) |context| {
        if (objc.msg(?objc.Object, context, "commandForEvent:", .{event}) != null)
            return objc.msg(objc.BOOL, context, "performCommandForEvent:", .{event});
    }
    return false;
}
