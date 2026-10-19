//! Where a link goes, at the bottom of the page while the pointer is on it
//! (StatusLine.swift): `LinkStatus`, the window's one destination, fed by
//! the `link` relay (`HoveredLink`, `tab_scripts.received`), and
//! `LinkBubble`, the click-through capsule over the page it is on — at the
//! other corner when the pointer is in its own.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");

/// The bubble's box, found by tests.
pub const key = "kea.link-bubble";
const style: ui.TextStyle = .{ .size = 12 };
const padding: f32 = 11;

/// `LinkStatus`. The address is kept after it is dismissed, so the
/// bubble can fade out still saying it.
pub const Status = struct {
    destination: ?[]u8 = null,
    shown: bool = false,
    on_right: bool = false,
    /// The page it is on (`Tab.serial`): with two pages up, the bubble
    /// stands over that one.
    page: u64 = 0,
    /// Bumped by every show, so a hide waiting out its 0.12 s is called off.
    hiding: u32 = 0,

    pub fn deinit(s: *Status, gpa: std.mem.Allocator) void {
        if (s.destination) |d| gpa.free(d);
        s.* = .{};
    }

    /// Shown, over `page`, in its corner.
    pub fn set(s: *Status, gpa: std.mem.Allocator, address: []const u8, page: u64, on_right: bool) void {
        s.hiding +%= 1;
        if (s.destination == null or !std.mem.eql(u8, s.destination.?, address)) {
            const copy = gpa.dupe(u8, address) catch return;
            if (s.destination) |d| gpa.free(d);
            s.destination = copy;
        }
        s.shown = true;
        s.page = page;
        s.on_right = on_right;
    }

    /// A tab change or navigation clears the old destination without waiting.
    pub fn dismiss(s: *Status) void {
        s.hiding +%= 1;
        s.shown = false;
    }
};

/// `place(over:)`'s rule: a link under the bubble's corner — the pointer
/// within 50 pt of the page's bottom and left of where the widest bubble
/// would end — gets the bubble in the other one.
pub fn cornerJump(x: f64, from_bottom: f64, width: f64) bool {
    return from_bottom < 50 and x < @min(width * 0.6, 640) + 22;
}

/// `HoveredLink` → `tab.onLink` → `linkStatus.show(_:over:)`: only while
/// Settings says so, and only for a page on screen.
pub fn relayed(t: *Tab, address: []const u8) void {
    const b = t.browser orelse return;
    if (!b.prefs.shows_links) return;
    const ids = b.visibleTabIDs();
    if (t.id == 0 or (ids[0] != t.id and ids[1] != t.id)) return;
    const s = &b.link_status;
    if (address.len == 0) {
        s.hiding +%= 1;
        return t.after(0.12, hideFired, s.hiding);
    }
    s.set(b.gpa, address, t.serial, if (t.web) |wv| pointerInCorner(wv) else false);
    b.redraw();
}

fn hideFired(t: *Tab, generation: usize) void {
    const b = t.browser orelse return;
    if (b.link_status.hiding != @as(u32, @truncate(generation))) return;
    dismiss(b);
}

/// `linkStatus.dismiss()`, and the window drawn again if it showed.
pub fn dismiss(b: *Browser) void {
    const was = b.link_status.shown;
    b.link_status.dismiss();
    if (was) b.redraw();
}

/// The pointer, asked once as the link changes rather than followed.
fn pointerInCorner(page: objc.Object) bool {
    const window = objc.msg(?objc.Object, page, "window", .{}) orelse return false;
    const at = objc.msg(objc.CGPoint, window, "mouseLocationOutsideOfEventStream", .{});
    const point = objc.msg(objc.CGPoint, page, "convertPoint:fromView:", .{ at, @as(?objc.Object, null) });
    const size = objc.msg(objc.CGRect, page, "bounds", .{}).size;
    const from_bottom = if (objc.msg(objc.BOOL, page, "isFlipped", .{})) size.height - point.y else point.y;
    return cornerJump(point.x, from_bottom, size.width);
}

/// `LinkBubble`, inside page box `pane` showing `t`: 12 pt on the page's
/// ground, 26 high, no wider than `min(0.6·page, 640)`, cut in the middle,
/// 10 in from the page's bottom corner. Never in the way of a click.
pub fn draw(b: *Browser, c: *ui.Context, p: *const Palette, t: *const Tab, pane: u32) void {
    if (!b.prefs.shows_links) return;
    const s = &b.link_status;
    const address = s.destination orelse return;
    const here = s.page == t.serial;
    const pane_id = c.node(pane).id;
    const fade = ui.tween(c, pane_id, 0x6c69_6e6b, if (here and s.shown) 1 else 0, 0.12, .ease_out);
    if (fade <= 0 or !here) return;
    // The page's width from the last layout; its first frame asks for another.
    const room = c.rects.get(pane_id) orelse return c.frameIn(0);
    const widest = @min(room.w * 0.6, 640);
    ui.row(c, .{
        .absolute = true,
        .width = .fill,
        .height = .fill,
        .padding = .{ .left = 10, .right = 10, .bottom = 10 },
        .align_items = .end,
        .justify = if (s.on_right) .end else .start,
        .opacity = fade,
    });
    defer ui.end(c);
    _ = c.open(.{
        .height = .{ .px = 26 },
        .padding = .xy(padding, 0),
        .radius = 13,
        .align_items = .center,
        .background = p.ground,
        .border = p.hairline,
        .shadow = card.swiftShadow(0.08, 12, 3),
    }, key);
    defer c.end();
    ui.text(c, middleCut(c, address, widest - 2 * padding), .{ .size = style.size, .color = p.ink });
}

/// `.truncationMode(.middle)`: the start and the end of `s`, "…" between,
/// in `room` points; `s` itself when it fits.
pub fn middleCut(c: *ui.Context, s: []const u8, room: f32) []const u8 {
    if (c.text.width(s, style) <= room) return s;
    const avail = room - c.text.width("…", style);
    if (avail <= 0) return "…";
    var head = c.text.indexAt(s, style, avail / 2);
    while (head > 0 and c.text.width(s[0..head], style) > avail / 2) head = back(s, head);
    const left = avail - c.text.width(s[0..head], style);
    // The shortest tail that fits what the head left.
    var lo = head;
    var hi = s.len;
    while (lo < hi) {
        const mid = start(s, lo + (hi - lo) / 2);
        if (mid >= hi) break;
        if (c.text.width(s[mid..], style) <= left) hi = mid else lo = mid + 1;
    }
    const tail = start(s, hi);
    return c.print("{s}…{s}", .{ s[0..head], s[tail..] });
}

/// The start of the UTF-8 character at or after `i`.
fn start(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and s[j] & 0xC0 == 0x80) j += 1;
    return j;
}

fn back(s: []const u8, i: usize) usize {
    var j = i - 1;
    while (j > 0 and s[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

test "the bubble jumps only for a pointer in its corner" {
    try std.testing.expect(cornerJump(100, 20, 1440));
    try std.testing.expect(!cornerJump(100, 60, 1440));
    try std.testing.expect(!cornerJump(700, 20, 1440));
    try std.testing.expect(cornerJump(500, 20, 800));
    try std.testing.expect(!cornerJump(503, 20, 800));
}
