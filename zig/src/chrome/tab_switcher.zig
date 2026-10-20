//! ⌃Tab's switcher (TabSwitcher.swift, Browser.switchTabs and kin): the
//! tabs of the space on screen as pictures, the one you are on first and
//! then the ones you last left, latest first. One gesture's order stays
//! fixed until ⌃ is let go of. The overlay is `tab_switcher_view.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const cg = @import("../sys/cg.zig");
const dispatch = @import("../sys/dispatch.zig");

extern "c" fn CGImageRetain(image: cg.Image) cg.Image;

pub const Direction = enum { left, right, up, down };

/// A tab's picture (PNG), of the page at `address`; `serial` names it for
/// the image cache, `w`/`h` are its pixels.
pub const Preview = struct { address: []u8, png: []u8, w: f32, h: f32, serial: u32 };

pub const TabSwitcher = struct {
    /// The tabs left, latest first, in every space: going back to a space
    /// finds its order where it was.
    recent: std.ArrayList(u64) = .empty,
    /// This gesture's tabs, fixed until it ends; none: not switching.
    candidates: std.ArrayList(u64) = .empty,
    selected: ?u64 = null,
    visible: bool = false,
    /// A pair's other page, by its first (`{first, second}`): one card.
    partners: std.ArrayList([2]u64) = .empty,
    previews: std.AutoArrayHashMapUnmanaged(u64, Preview) = .empty,
    /// The picture asked of each tab, by token.
    requests: std.AutoArrayHashMapUnmanaged(u64, u64) = .empty,
    /// Where the pointer was when the panel first felt it, and whether it
    /// has gone anywhere since.
    rest: ?ui.Point = null,
    /// The pointer last frame: a card is picked only by the pointer moving.
    pointer: ui.Point = .{},
    moved: bool = false,
    /// The 0.15 s before the panel shows: asked by the first ⌃Tab, timed
    /// from the next frame.
    reveal_asked: bool = false,
    reveal_at: ?f64 = null,
    previews_requested: bool = false,
    generation: u64 = 0,
    /// The pick the 120 ms wait before pictures is for (`.task(id: selectedID)`).
    waited_for: ?u64 = null,
    capture_at: f64 = 0,
    /// Pictures to ask for, one every 0.04 s from `queue_at`; `queued` asked.
    queue: std.ArrayList(u64) = .empty,
    queue_at: f64 = 0,
    queued: usize = 0,
    pictures: u32 = 0,
    /// Where the panel and its cards were drawn last, in the window's own
    /// top-left points: a click is taken by the key monitor (`clickTabSwitcher`).
    panel_frame: ?ui.Rect = null,
    cards: [10]struct { id: u64, rect: ui.Rect } = undefined,
    card_count: usize = 0,

    pub fn active(s: *const TabSwitcher) bool {
        return s.candidates.items.len > 0;
    }

    pub fn partnerOf(s: *const TabSwitcher, id: u64) ?u64 {
        for (s.partners.items) |p| if (p[0] == id) return p[1];
        return null;
    }

    /// Its picture, if one is kept of the page at `address`.
    pub fn preview(s: *const TabSwitcher, id: u64, address: ?[]const u8) ?Preview {
        const p = s.previews.get(id) orelse return null;
        const a = address orelse return null;
        return if (std.mem.eql(u8, p.address, a)) p else null;
    }

    fn has(list: []const u64, id: u64) bool {
        return std.mem.indexOfScalar(u64, list, id) != null;
    }

    /// One of the ten tabs left last: its picture is kept between gestures.
    fn kept(s: *const TabSwitcher, id: u64) bool {
        return has(s.recent.items[0..@min(10, s.recent.items.len)], id);
    }

    /// In this gesture, as a card or a pair's second page.
    fn shown(s: *const TabSwitcher, id: u64) bool {
        if (has(s.candidates.items, id)) return true;
        for (s.candidates.items) |c| if (s.partnerOf(c) == id) return true;
        return false;
    }

    fn prune(s: *TabSwitcher, gpa: std.mem.Allocator, comptime keep: fn (*const TabSwitcher, u64) bool) void {
        var i: usize = 0;
        while (i < s.requests.count()) {
            if (keep(s, s.requests.keys()[i])) i += 1 else s.requests.swapRemoveAt(i);
        }
        i = 0;
        while (i < s.previews.count()) {
            if (keep(s, s.previews.keys()[i])) {
                i += 1;
            } else {
                free(gpa, s.previews.values()[i]);
                s.previews.swapRemoveAt(i);
            }
        }
    }

    fn free(gpa: std.mem.Allocator, p: Preview) void {
        gpa.free(p.address);
        gpa.free(p.png);
    }

    pub fn deinit(s: *TabSwitcher, gpa: std.mem.Allocator) void {
        for (s.previews.values()) |p| free(gpa, p);
        s.previews.deinit(gpa);
        s.requests.deinit(gpa);
        s.recent.deinit(gpa);
        s.candidates.deinit(gpa);
        s.partners.deinit(gpa);
        s.queue.deinit(gpa);
    }
};

// MARK: the gesture (Browser.swift:3303-3336, TabSwitcher)

/// Kept by the browser with nothing over the page it would have to cover
/// (`canSwitchTabs`); otherwise ⌃Tab walks the row. The find bar isn't one.
pub fn canSwitch(b: *Browser) bool {
    inline for (.{ "tuning", "recalling", "hoarding", "bookmarking", "welcoming", "managing", "bringing_in", "reviewing", "asking" }) |f| {
        if (@hasField(Browser, f)) if (truthy(@field(b, f))) return false;
    }
    if (b.passwords.offering != null or b.passwords.accounts.suggesting != null) return false;
    // `bookmarksOpen`: the bookmarks' dropdown.
    if (b.overlay) |o| if (o == .bookmarks_dropdown) return false;
    return !b.veiling and !b.summoning and !b.making_space and
        b.peek_tab == null and b.editing_tab == null;
}

fn truthy(v: anytype) bool {
    return switch (@typeInfo(@TypeOf(v))) {
        .bool => v,
        .optional => v != null,
        else => false,
    };
}

/// ⌃Tab with nothing over the page: the space's tabs, the most recently
/// used first. Nothing changes until ⌃ is let go of (`commitTabSwitch`).
pub fn switchTabs(b: *Browser, backwards: bool) void {
    if (b.active_id == 0) return;
    const s = &b.switcher;
    // A pair once, under its first page, pictured with its other one.
    s.partners.clearRetainingCapacity();
    if (b.prefs.split_view) for (b.splits.items) |p| if (s.partnerOf(p.left()) == null) {
        s.partners.append(b.gpa, .{ p.left(), p.right() }) catch {};
    };
    var row: std.ArrayList(u64) = .empty;
    defer row.deinit(b.gpa);
    for (b.tabs.items) |t| if (b.standsInRow(t)) row.append(b.gpa, t.id) catch return;
    const current = if (b.activeSplit()) |p| p.left() else b.active_id;
    step(b, row.items, current, backwards);
    b.redraw();
}

/// The first ⌃Tab of a gesture takes the space's tabs in that order, the
/// ones never left after them in the row's order, and stops on the one
/// before this one: a quick press goes back to the last tab. ⇧ starts
/// from the far end.
pub fn step(b: *Browser, row: []const u64, current: u64, backwards: bool) void {
    const s = &b.switcher;
    if (!s.active()) {
        if (!TabSwitcher.has(row, current)) return;
        for ([_][]const u64{ &.{current}, s.recent.items, row }) |part| for (part) |id| {
            if (s.candidates.items.len == 10) break;
            if (TabSwitcher.has(row, id) and !TabSwitcher.has(s.candidates.items, id)) s.candidates.append(b.gpa, id) catch return;
        };
        if (s.candidates.items.len <= 1) return s.candidates.clearRetainingCapacity();
        const c = s.candidates.items;
        s.selected = if (backwards) c[c.len - 1] else c[1];
        s.reveal_asked = true;
        return;
    }
    const c = s.candidates.items;
    const index = std.mem.indexOfScalar(u64, c, s.selected orelse return) orelse return;
    const n: isize = @intCast(c.len);
    s.selected = c[@intCast(@mod(@as(isize, @intCast(index)) + @as(isize, if (backwards) -1 else 1), n))];
    show(b);
}

/// ⌃ and the arrows, through the five columns.
pub fn move(b: *Browser, direction: Direction) void {
    const s = &b.switcher;
    const c = s.candidates.items;
    const index = std.mem.indexOfScalar(u64, c, s.selected orelse return) orelse return;
    show(b);
    const next = switch (direction) {
        .left => (index + c.len - 1) % c.len,
        .right => (index + 1) % c.len,
        .up => if (index >= 5) index - 5 else return,
        .down => if (index < 5 and c.len > 5) @min(index + 5, c.len - 1) else return,
    };
    s.selected = c[next];
    b.redraw();
}

/// ⌃ let go of, or a card clicked: that tab, or the pick.
pub fn commitTabSwitch(b: *Browser, picking: ?u64) void {
    const s = &b.switcher;
    const target = picking orelse s.selected;
    const valid = if (target) |id| (if (TabSwitcher.has(s.candidates.items, id)) id else null) else null;
    cancel(b);
    const tab = b.tabById(valid orelse return) orelse return;
    b.select(b.entry(tab));
}

/// The gesture ends with nothing picked: the pictures of the ten tabs left
/// last stay.
pub fn cancel(b: *Browser) void {
    const s = &b.switcher;
    if (!s.active() and !s.reveal_asked and s.reveal_at == null and !s.visible) return;
    s.reveal_asked = false;
    s.reveal_at = null;
    s.generation +%= 1;
    s.candidates.clearRetainingCapacity();
    s.selected = null;
    s.visible = false;
    s.rest = null;
    s.moved = false;
    s.waited_for = null;
    s.queue.clearRetainingCapacity();
    s.queued = 0;
    s.prune(b.gpa, TabSwitcher.kept);
    s.previews_requested = false;
    b.redraw();
}

/// A click while the switcher is up, at a point in the window's top-left
/// points: on a card, that card; outside the panel, the switcher goes. True
/// when the click was the switcher's. Taken before any view sees it: ⌃ is
/// held, and a ⌃-click is a right-click to AppKit.
pub fn clickTabSwitcher(b: *Browser, at: ui.Point) bool {
    const s = &b.switcher;
    if (!s.visible) return false;
    const panel = s.panel_frame orelse return true;
    if (!panel.contains(at)) {
        cancel(b);
        return true;
    }
    // Between two cards: the switcher's, and nothing happens.
    for (s.cards[0..s.card_count]) |card| if (card.rect.contains(at)) {
        commitTabSwitch(b, card.id);
        break;
    };
    return true;
}

/// Turned off, or memory short: nothing kept, not the order and not the pictures.
pub fn reset(b: *Browser) void {
    cancel(b);
    const s = &b.switcher;
    s.recent.clearRetainingCapacity();
    s.requests.clearRetainingCapacity();
    for (s.previews.values()) |p| TabSwitcher.free(b.gpa, p);
    s.previews.clearRetainingCapacity();
}

/// `activeID.didSet`, the switcher's part: the tab just left goes to the
/// front of the order. Focus moving within a pair isn't leaving it; a
/// pair left is one entry, under its first page.
pub fn leftTab(b: *Browser, old: u64) void {
    const left = b.tabById(old) orelse return cancel(b);
    if (b.splitFor(left)) |pair| {
        if (pair.contains(b.active_id)) return;
        cancel(b);
        return remember(b, pair.left());
    }
    cancel(b);
    remember(b, old);
}

/// `left(_:alive:)`: to the front; tabs that are gone fall out, and only
/// the ten latest keep a picture.
fn remember(b: *Browser, id: u64) void {
    const s = &b.switcher;
    if (b.tabById(id) == null) return;
    var i: usize = 0;
    while (i < s.recent.items.len) {
        const r = s.recent.items[i];
        if (r == id or !alive(b, r)) _ = s.recent.orderedRemove(i) else i += 1;
    }
    s.recent.insert(b.gpa, 0, id) catch return;
    s.prune(b.gpa, TabSwitcher.kept);
}

/// In this window's row or one of its other spaces'.
fn alive(b: *Browser, id: u64) bool {
    if (b.tabById(id) != null) return true;
    for (b.parked.values()) |row| for (row.tabs.items) |t| if (t.id == id) return true;
    return false;
}

pub fn show(b: *Browser) void {
    const s = &b.switcher;
    if (!s.active() or s.visible) return;
    s.reveal_asked = false;
    s.reveal_at = null;
    s.prune(b.gpa, TabSwitcher.shown);
    s.visible = true;
    b.redraw();
}

// MARK: pictures

/// The order pictures are asked in: the pick first, each card's pair page
/// after it; only tabs without one of their present page, and the one on
/// screen, whose picture is always fresh. `now` is the view's clock.
pub fn capture(b: *Browser, now: f64) void {
    const s = &b.switcher;
    if (!s.visible or s.previews_requested) return;
    s.previews_requested = true;
    s.queue.clearRetainingCapacity();
    s.queued = 0;
    s.queue_at = now;
    var firsts: [10]u64 = undefined;
    var n: usize = 0;
    if (s.selected) |id| {
        firsts[0] = id;
        n = 1;
    }
    for (s.candidates.items) |id| if (id != s.selected and n < firsts.len) {
        firsts[n] = id;
        n += 1;
    };
    for (firsts[0..n]) |id| for ([_]?u64{ id, s.partnerOf(id) }) |maybe| if (maybe) |each| if (b.tabById(each)) |t| {
        if (t.id == b.active_id or s.preview(t.id, t.address) == null) s.queue.append(b.gpa, t.id) catch {};
    };
}

/// Asks for the pictures now due; the time the next is due, if any.
pub fn pump(b: *Browser, now: f64) ?f64 {
    const s = &b.switcher;
    while (s.queued < s.queue.items.len) {
        const due = s.queue_at + @as(f64, @floatFromInt(s.queued)) * 0.04;
        if (due > now) return due;
        const id = s.queue.items[s.queued];
        s.queued += 1;
        if (!s.visible) continue;
        const t = b.tabById(id) orelse continue;
        if (t.id == b.active_id or s.preview(t.id, t.address) == null) request(b, t);
    }
    return null;
}

var tokens: u64 = 0;

const Job = struct {
    serial: u64,
    id: u64,
    token: u64,
    generation: u64,
    address: []u8,
    jpeg: ?[]u8 = null,
    cgimage: ?cg.Image = null,
    png: ?[]u8 = null,
    w: f32 = 0,
    h: f32 = 0,
};
const SnapBlock = objc.Block(Job, &.{ ?objc.Object, ?objc.Object });

/// `tab.preview(width: 180)`: a sleeping tab's from the picture kept for
/// waking it; a tab with no page built has none.
fn request(b: *Browser, t: *Tab) void {
    const address = t.address orelse return;
    tokens += 1;
    b.switcher.requests.put(b.gpa, t.id, tokens) catch return;
    const ca = std.heap.c_allocator;
    const job = ca.create(Job) catch return;
    job.* = .{ .serial = t.serial, .id = t.id, .token = tokens, .generation = b.switcher.generation, .address = ca.dupe(u8, address) catch return ca.destroy(job) };
    if (t.picture) |jpeg| {
        job.jpeg = ca.dupe(u8, jpeg) catch return dropJob(job);
        return dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), job, encodeBg);
    }
    const wv = t.web orelse return dropJob(job);
    const pool = objc.Pool.push();
    defer pool.pop();
    const config = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("WKSnapshotConfiguration"), "alloc", .{}), "init", .{});
    defer objc.release(config);
    objc.msg(void, config, "setSnapshotWidth:", .{objc.msg(objc.Object, objc.class("NSNumber"), "numberWithDouble:", .{@as(f64, 180)})});
    var block = SnapBlock.init(job, snapped);
    objc.msg(void, wv, "takeSnapshotWithConfiguration:completionHandler:", .{ config, @as(*anyopaque, @ptrCast(&block)) });
}

fn dropJob(job: *Job) void {
    const ca = std.heap.c_allocator;
    if (job.jpeg) |j| ca.free(j);
    if (job.png) |p| ca.free(p);
    if (job.cgimage) |i| cg.CGImageRelease(i);
    ca.free(job.address);
    ca.destroy(job);
}

fn snapped(job: *Job, image: ?objc.Object, _: ?objc.Object) void {
    const img = image orelse return dropJob(job);
    const pool = objc.Pool.push();
    defer pool.pop();
    const raw: ?cg.Image = @ptrCast(objc.msg(?*anyopaque, img, "CGImageForProposedRect:context:hints:", .{ @as(?*anyopaque, null), @as(?objc.Object, null), @as(?objc.Object, null) }));
    job.cgimage = if (raw) |r| CGImageRetain(r) else return dropJob(job);
    dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), job, encodeBg);
}

/// The kept JPEG, made small (`CGImageSourceCreateThumbnailAtIndex`, 360 px).
fn thumbnail(jpeg: []const u8) ?cg.Image {
    const data = cg.CFDataCreate(null, jpeg.ptr, @intCast(jpeg.len)) orelse return null;
    defer cg.CFRelease(data);
    const source = cg.CGImageSourceCreateWithData(data, null) orelse return null;
    defer cg.CFRelease(source);
    const keys = [_]objc.Object{ @ptrCast(@constCast(cg.kCGImageSourceCreateThumbnailFromImageAlways)), @ptrCast(@constCast(cg.kCGImageSourceThumbnailMaxPixelSize)) };
    const values = [_]objc.Object{ objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES}), objc.msg(objc.Object, objc.class("NSNumber"), "numberWithInt:", .{@as(c_int, 360)}) };
    const options = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, 2) });
    return cg.CGImageSourceCreateThumbnailAtIndex(source, 0, options);
}

fn encodeBg(p: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(p.?));
    const pool = objc.Pool.push();
    defer pool.pop();
    if (job.jpeg) |j| job.cgimage = thumbnail(j);
    if (job.cgimage) |cgimage| {
        defer {
            cg.CGImageRelease(cgimage);
            job.cgimage = null;
        }
        job.w = @floatFromInt(cg.CGImageGetWidth(cgimage));
        job.h = @floatFromInt(cg.CGImageGetHeight(cgimage));
        const rep = objc.msg(objc.Object, objc.msg(objc.Object, objc.class("NSBitmapImageRep"), "alloc", .{}), "initWithCGImage:", .{@as(*anyopaque, @ptrCast(cgimage))});
        defer objc.release(rep);
        // NSBitmapImageFileTypePNG.
        if (objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) })) |data| {
            const bytes: [*]const u8 = @ptrCast(objc.msg(*const anyopaque, data, "bytes", .{}));
            job.png = std.heap.c_allocator.dupe(u8, bytes[0..objc.msg(objc.NSUInteger, data, "length", .{})]) catch null;
        }
    }
    objc.dispatchMain(job, deliverFg);
}

/// The picture, as PNG, to the switcher that asked — if it still wants it.
fn deliverFg(p: ?*anyopaque) callconv(.c) void {
    const job: *Job = @ptrCast(@alignCast(p.?));
    defer dropJob(job);
    const t = Tab.alive(job.serial) orelse return;
    const b = t.browser orelse return;
    const s = &b.switcher;
    if (s.requests.get(job.id) != job.token) return;
    _ = s.requests.swapRemove(job.id);
    const png_bytes = job.png orelse return;
    if (!std.mem.eql(u8, t.address orelse "", job.address) or s.generation != job.generation or !s.visible) return;
    if (!(s.kept(job.id) or s.shown(job.id))) return;
    const png = b.gpa.dupe(u8, png_bytes) catch return;
    const address = b.gpa.dupe(u8, job.address) catch return b.gpa.free(png);
    s.pictures +%= 1;
    const entry = s.previews.getOrPut(b.gpa, job.id) catch {
        b.gpa.free(png);
        return b.gpa.free(address);
    };
    if (entry.found_existing) TabSwitcher.free(b.gpa, entry.value_ptr.*);
    entry.value_ptr.* = .{
        .address = address,
        .png = png,
        .w = job.w,
        .h = job.h,
        .serial = s.pictures,
    };
    b.redraw();
}
