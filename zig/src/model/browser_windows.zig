//! Browser.swift "a tab to another window" (3047-3125): Move to New
//! Window, to another window, or dragged out of the row and let go
//! outside this window. The tab goes as it is, page and all; never a pin,
//! which every window already has.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const WindowRecord = @import("../data/windows_file.zig").WindowRecord;
const browsers = @import("../app/browsers.zig");

/// Into `target`'s row after the tab it's on, in front there; with no
/// target, into a new window — at `point` (screen coordinates, bottom-left
/// origin) when dragged out, its row under the hand.
pub fn moveToWindow(self: *Browser, tab: *Tab, target: ?*Browser, point: ?objc.CGPoint) void {
    if (tab.pin != null or self.indexOf(tab) == null) return;
    if (target) |t| if (t == self) return;
    if (target == null and self.tabs.items.len <= 1 and tab.isBlank()) return;
    const destination = target orelse made: {
        var frame: ?objc.CGRect = null;
        if (point) |p| {
            const size = if (self.window) |w| objc.msg(objc.CGRect, w.nswindow, "frame", .{}).size else browsers.default_size;
            frame = .{ .origin = .{ .x = p.x - 120, .y = p.y - size.height + 20 }, .size = size };
        }
        const record: WindowRecord = .{ .id = Uuid.random(), .space = self.space_id };
        break :made browsers.open(self.kea, &record, frame) catch return;
    };
    detach(self, tab);
    destination.receive(tab);
    if (target != null) browsers.show(destination);
}

/// Let go outside this window: into the window it was let go over, or a
/// new one there. False when over this window, where the drag keeps its
/// meaning, or when it can't leave (a pin, or the window's only tab).
pub fn dragOut(self: *Browser, tab: *Tab, point: objc.CGPoint) bool {
    if (tab.pin != null) return false;
    const w = self.window orelse return false;
    const frame = objc.msg(objc.CGRect, w.nswindow, "frame", .{});
    if (contains(frame, point, 12)) return false;
    if (under(self.kea, self, point) == null and self.tabs.items.len <= 1) return false;
    // After the drag has let go, not inside it.
    const later = std.heap.c_allocator.create(Later) catch return false;
    later.* = .{ .kea = self.kea, .from = self.record_id, .tab = tab.id, .point = point };
    objc.dispatchMain(later, Later.fire);
    return true;
}

const Later = struct {
    kea: *Kea,
    from: Uuid,
    tab: u64,
    point: objc.CGPoint,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Later = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(l);
        for (l.kea.browsers.items) |b| if (b.record_id.eql(l.from)) {
            const t = b.tabById(l.tab) orelse return;
            return b.moveToWindow(t, under(l.kea, b, l.point), l.point);
        };
    }
};

/// The open window under `point`, other than `self`'s.
fn under(kea: *Kea, self: *Browser, point: objc.CGPoint) ?*Browser {
    for (kea.browsers.items) |b| {
        if (b == self or b.shut) continue;
        const w = b.window orelse continue;
        if (contains(objc.msg(objc.CGRect, w.nswindow, "frame", .{}), point, 0)) return b;
    }
    return null;
}

fn contains(r: objc.CGRect, p: objc.CGPoint, outset: f64) bool {
    return p.x >= r.origin.x - outset and p.x < r.origin.x + r.size.width + outset and
        p.y >= r.origin.y - outset and p.y < r.origin.y + r.size.height + outset;
}

/// Out of this row, not closed: it is on its way to another window.
fn detach(self: *Browser, tab: *Tab) void {
    const index = self.indexOf(tab) orelse return;
    const partner = self.partnerOf(tab);
    self.detachSplit(tab);
    if (self.active_id == tab.id) {
        if (partner) |p| {
            self.select(p);
        } else if (self.tabs.items.len > 1) {
            self.select(self.tabs.items[if (index == self.tabs.items.len - 1) index - 1 else index + 1]);
        } else self.active_id = 0;
    }
    _ = self.tabs.orderedRemove(index);
    self.removeEmptyGroup(tab.group_id);
    tab.group_id = null;
    if (self.stage_host) |sh| if (tab.web) |wv| sh.forget(wv);
    if (self.tabs.items.len == 0) self.adopt(self.make("", false));
    if (self.active_id == 0) self.active_id = self.tabs.items[0].id;
    self.writeSession(true);
    self.redraw();
}

/// A tab from another window, in front here. The empty tab a new window
/// starts with makes way for it.
pub fn receive(self: *Browser, tab: *Tab) void {
    self.prepare(tab);
    if (!tab.shy) tab.rehome(self.kea.dataStore(self.space_id));
    var blanks: std.ArrayList(u64) = .empty;
    defer blanks.deinit(self.gpa);
    for (self.tabs.items) |t| if (t.isBlank() and !self.inSplit(t)) blanks.append(self.gpa, t.id) catch return;
    self.tabs.insert(self.gpa, self.placeForNew(), tab) catch @panic("OOM");
    self.select(tab);
    if (self.tabs.items.len - blanks.items.len == 1 + self.pinnedCount()) {
        for (blanks.items) |id| if (self.tabById(id)) |blank| {
            _ = self.tabs.orderedRemove(self.indexOf(blank).?);
            self.letGo(blank);
        };
    }
    if (self.active_id == tab.id) _ = tab.wake();
    self.writeSession(true);
    self.redraw();
}
