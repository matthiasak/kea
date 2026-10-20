//! Every window, followed (Extensions.swift 344-446): a window's row and
//! its tab in front told to WebKit — tabs opened, closed, moved within a
//! row or between windows, changed, activated. Swift subscribes to each
//! browser's `$tabs`/`$activeID` and each tab's title/address/loading/pin;
//! here `follow(b)` runs when a tab's address, title or loading state
//! changes (`delegates_nav.zig` `tabChanged`) or when the row/active tab
//! changes (`browser_rows.zig` `rememberSession`), diffing what WebKit last
//! heard against what is there now.
const std = @import("std");
const objc = @import("nanoui").objc;
const Extensions = @import("controller.zig").Extensions;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const adapters = @import("adapters.zig");

/// WKWebExtensionTabChangedProperties.
const loading_changed: objc.NSUInteger = 1 << 1;
const pinned_changed: objc.NSUInteger = 1 << 3;
const title_changed: objc.NSUInteger = 1 << 7;
const url_changed: objc.NSUInteger = 1 << 8;

/// A window's row as WebKit last heard it, and its tab in front.
const Row = struct {
    order: std.ArrayList(u64) = .empty,
    active: u64 = 0,
};

/// What a tab looked like when WebKit last heard of it.
const Seen = struct { title: u64, url: u64, loading: bool, pinned: bool };

pub const State = struct {
    /// The windows followed (`following`, `orders`).
    rows: std.AutoArrayHashMapUnmanaged(*Browser, Row) = .empty,
    /// A tab gone from one window's row into another's, and where it was.
    in_transit: std.AutoHashMapUnmanaged(u64, struct { browser: *Browser, index: usize }) = .empty,
    /// `watching`: each tab told about, as it was.
    seen: std.AutoHashMapUnmanaged(u64, Seen) = .empty,
    /// The row now, reused.
    scratch: std.ArrayList(u64) = .empty,
    /// Telling WebKit can call back into a redraw.
    busy: bool = false,
};

pub fn deinit(self: *Extensions) void {
    const s = &self.following;
    for (s.rows.values()) |*r| r.order.deinit(self.gpa);
    s.rows.deinit(self.gpa);
    s.in_transit.deinit(self.gpa);
    s.seen.deinit(self.gpa);
    s.scratch.deinit(self.gpa);
}

fn snapshot(t: *const Tab) Seen {
    const H = std.hash.Wyhash;
    return .{
        .title = H.hash(0, t.page_title),
        .url = H.hash(0, t.address orelse ""),
        .loading = t.loading,
        .pinned = t.pin != null,
    };
}

/// `attach(_:)`: a window told to WebKit and followed from now on.
pub fn attach(self: *Extensions, b: *Browser) void {
    if (self.following.rows.contains(b)) return;
    objc.msg(void, self.controller, "didOpenWindow:", .{adapters.windowOf(self, b)});
    self.following.rows.put(self.gpa, b, .{}) catch return;
    // As a subscription hears the current value at once.
    follow(self, b);
}

/// `detach(_:)`: its window closed for good — its tabs, then the window,
/// gone for WebKit.
pub fn detach(self: *Extensions, b: *Browser) void {
    var kv = self.following.rows.fetchSwapRemove(b) orelse return;
    defer kv.value.order.deinit(self.gpa);
    for (kv.value.order.items) |id| {
        if (adapters.known(self, id)) |a| objc.msg(void, self.controller, "didCloseTab:windowIsClosing:", .{ a, objc.YES });
        adapters.forgetAdapter(self, id);
        _ = self.following.seen.remove(id);
    }
    // Nothing keeps pointing at a browser that is going.
    var it = self.following.in_transit.iterator();
    var stale: std.ArrayList(u64) = .empty;
    defer stale.deinit(self.gpa);
    while (it.next()) |e| if (e.value_ptr.browser == b) stale.append(self.gpa, e.key_ptr.*) catch {};
    for (stale.items) |id| _ = self.following.in_transit.remove(id);
    if (self.del.windows.get(b)) |w| objc.msg(void, self.controller, "didCloseWindow:", .{w});
    adapters.forgetWindow(self, b);
}

/// `focused(_:)`: a window came to the front (windows.onFocusChanged).
pub fn focused(self: *Extensions, b: *Browser) void {
    if (!self.following.rows.contains(b)) return;
    objc.msg(void, self.controller, "didFocusWindow:", .{adapters.windowOf(self, b)});
}

fn indexIn(list: []const u64, id: u64) ?usize {
    return std.mem.indexOfScalar(u64, list, id);
}

/// What changed in `b`'s row since WebKit last heard, told.
pub fn followRow(self: *Extensions, b: *Browser) void {
    const s = &self.following;
    if (s.busy) return;
    const r0 = s.rows.getPtr(b) orelse return;
    if (r0.active == b.active_id and r0.order.items.len == b.tabs.items.len) {
        var same = true;
        for (r0.order.items, b.tabs.items) |id, t| {
            if (!self.seen(t) or id != t.id) {
                same = false;
                break;
            }
        }
        if (same) return;
    }
    follow(self, b);
}

/// What changed in `b`'s row since WebKit last heard, told.
pub fn follow(self: *Extensions, b: *Browser) void {
    const s = &self.following;
    if (s.busy) return;
    if (!s.rows.contains(b)) return;
    s.busy = true;
    defer s.busy = false;
    const pool = objc.Pool.push();
    defer pool.pop();
    s.scratch.clearRetainingCapacity();
    for (b.tabs.items) |t| if (self.seen(t)) s.scratch.append(self.gpa, t.id) catch return;
    const row = s.rows.getPtr(b).?;
    if (!std.mem.eql(u64, row.order.items, s.scratch.items)) rowChanged(self, b) catch return;
    // Title, address, loading, pin (`watch`).
    for (b.tabs.items) |t| {
        const was = s.seen.getPtr(t.id) orelse continue;
        const now = snapshot(t);
        var props: objc.NSUInteger = 0;
        if (now.title != was.title) props |= title_changed;
        if (now.url != was.url) props |= url_changed;
        if (now.loading != was.loading) props |= loading_changed;
        if (now.pinned != was.pinned) props |= pinned_changed;
        if (props == 0) continue;
        was.* = now;
        if (adapters.known(self, t.id)) |a| objc.msg(void, self.controller, "didChangeTabProperties:forTab:", .{ props, a });
    }
    // The tab in front (`activated`), heard however it changed.
    const r = s.rows.getPtr(b).?;
    if (r.active != b.active_id) {
        const old = r.active;
        r.active = b.active_id;
        activated(self, old, b.active_id, b);
    }
}

fn rowChanged(self: *Extensions, b: *Browser) !void {
    const s = &self.following;
    const gpa = self.gpa;
    const ids = s.scratch.items;
    const order = try gpa.dupe(u64, s.rows.getPtr(b).?.order.items);
    defer gpa.free(order);
    for (order, 0..) |id, at| {
        if (indexIn(ids, id) != null) continue;
        // Moved to another window rather than closed: that window says so
        // when it takes it.
        const elsewhere = for (self.kea.browsers.items) |o| {
            if (o != b and o.tabById(id) != null) break true;
        } else false;
        if (elsewhere) {
            try s.in_transit.put(gpa, id, .{ .browser = b, .index = at });
            continue;
        }
        if (adapters.known(self, id)) |a| objc.msg(void, self.controller, "didCloseTab:windowIsClosing:", .{ a, objc.NO });
        adapters.forgetAdapter(self, id);
        _ = s.seen.remove(id);
    }
    for (b.tabs.items) |t| {
        if (!self.seen(t) or indexIn(order, t.id) != null) continue;
        var from: ?struct { browser: *Browser, index: usize } = null;
        if (s.in_transit.fetchRemove(t.id)) |kv| from = .{ .browser = kv.value.browser, .index = kv.value.index } else {
            for (s.rows.keys(), s.rows.values()) |o, other| if (o != b) if (indexIn(other.order.items, t.id)) |at| {
                from = .{ .browser = o, .index = at };
                break;
            };
        }
        if (from) |f| if (self.del.windows.get(f.browser)) |other| {
            // From another window: a move between windows, as WebKit has it.
            if (s.rows.getPtr(f.browser)) |r| if (indexIn(r.order.items, t.id)) |at| {
                _ = r.order.orderedRemove(at);
            };
            objc.msg(void, self.controller, "didMoveTab:fromIndex:inWindow:", .{ adapters.adapter(self, t), @as(objc.NSUInteger, f.index), other });
            continue;
        };
        objc.msg(void, self.controller, "didOpenTab:", .{adapters.adapter(self, t)});
        try s.seen.put(gpa, t.id, snapshot(t));
    }
    // Moves: anything whose position changed among the ones that stayed.
    var stayed: std.ArrayList(u64) = .empty;
    defer stayed.deinit(gpa);
    for (order) |id| if (indexIn(ids, id) != null) try stayed.append(gpa, id);
    var position: usize = 0;
    for (ids) |id| {
        if (indexIn(stayed.items, id) == null) continue;
        defer position += 1;
        const was = indexIn(stayed.items, id).?;
        if (was == position) continue;
        if (adapters.known(self, id)) |a| objc.msg(void, self.controller, "didMoveTab:fromIndex:inWindow:", .{ a, @as(objc.NSUInteger, was), adapters.windowOf(self, b) });
    }
    const row = s.rows.getPtr(b).?;
    row.order.clearRetainingCapacity();
    try row.order.appendSlice(gpa, ids);
}

/// `activated(from:to:in:)`.
fn activated(self: *Extensions, old: u64, new: u64, b: *Browser) void {
    const tab = b.tabById(new) orelse return;
    if (!self.seen(tab)) return;
    const previous: ?objc.Object = if (b.tabById(old)) |t| adapters.adapter(self, t) else null;
    objc.msg(void, self.controller, "didActivateTab:previousActiveTab:", .{ adapters.adapter(self, tab), previous });
    self.actions_changed += 1;
}
