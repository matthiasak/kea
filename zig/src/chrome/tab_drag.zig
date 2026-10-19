//! `Carried` (TabBar.swift 756-853): a tab picked up and carried along its
//! row, the others making way as it passes them — across the strip or down
//! the column alike. The hand's travel is the tab's own; the row only
//! changes when the tab passes another. With Split View on, the stage is
//! asked first (chrome/split_drop.zig): over a page's edge, a pair.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const motion = @import("../design/motion.zig");
const split_drop = @import("split_drop.zig");

/// `DragGesture(minimumDistance: 5)`.
pub const min_distance: f32 = 5;

/// One window's hand: the tab pressed on, and the one let go.
pub const State = struct {
    hand: ?Hand = null,
    landing: ?Landing = null,
    gen: u32 = 0,
};

const Hand = struct {
    tab: u64,
    /// Its place in the row when the hand took it (`from`).
    from: usize,
    /// Where the press was, in the window: the travel is measured from it.
    origin: ui.Point,
    held: bool = false,
    shift: f32 = 0,
};

/// The tab let go, its shift springing home from `from` on `Motion.settle`.
const Landing = struct { tab: u64, gen: u32, from: f32 };

pub const Result = struct {
    /// Along the row, from the tab's laid-out place: under the hand while
    /// held, springing back to 0 once let go.
    shift: f32 = 0,
    /// Being carried: drawn on the drop chip, over its neighbours.
    held: bool = false,
    /// The place the hand has reached this frame, when it isn't the tab's
    /// own: the caller moves the tab there.
    target: ?usize = null,
    /// Let go inside the window, here (window points): a group heading
    /// under it takes the tab.
    dropped: ?ui.Point = null,
    /// Let go outside the window, and taken to another window or a new one.
    outside: bool = false,
    /// This frame let go of a drag.
    let_go: bool = false,

    /// The release that ends a drag is not a click on the tab.
    pub fn swallowsClick(r: Result) bool {
        return r.held or r.let_go;
    }
};

/// The chip under a carried tab: ground, radius 9, shadow α.14 r12 y4.
pub fn chipStyle(p: *const Palette) ui.Style {
    return .{ .background = p.ground, .radius = 9, .shadow = card.swiftShadow(0.14, 12, 4) };
}

fn springId(tab: u64) u64 {
    return std.hash.Wyhash.hash(0x6361_7272, std.mem.asBytes(&tab));
}

/// The hand on `tab`, at `index` of the `count` places its row lets it move
/// among, each `step` long (its length and the gap after it); `it` is the
/// tab's own interaction. Call once a frame for every tab of the row.
pub fn carried(b: *Browser, c: *ui.Context, it: ui.Interaction, tab: *Tab, index: usize, count: usize, step: f32, vertical: bool) Result {
    const st = &b.carry;
    const mouse = c.input.mouse;
    // The press: where it was, and where the tab stood.
    if (it.pressed and c.input.pressed) st.hand = .{ .tab = tab.id, .from = index, .origin = mouse };

    var r: Result = .{};
    if (st.landing) |l| if (l.tab == tab.id) {
        r.shift = ui.springFrom(c, springId(tab.id), l.gen, l.from, 0, motion.settle);
        if (r.shift == 0) st.landing = null;
    };
    const h = if (st.hand) |*h| h else return r;
    if (h.tab != tab.id) return r;
    const travel = if (vertical) mouse.y - h.origin.y else mouse.x - h.origin.x;

    if (c.input.down) {
        if (!h.held) {
            const dx = mouse.x - h.origin.x;
            const dy = mouse.y - h.origin.y;
            if (dx * dx + dy * dy < min_distance * min_distance) return r;
            h.held = true;
            h.from = index;
            st.landing = null;
        }
        // Called off with Esc: back where it was picked up, held no more.
        if (b.stage.drop.cancelled == tab.id) {
            h.shift = 0;
            if (index != h.from) r.target = h.from;
            return r;
        }
        r.held = true;
        const from: f32 = @floatFromInt(h.from);
        r.shift = travel - (@as(f32, @floatFromInt(index)) - from) * step;
        h.shift = r.shift;
        // Over a page's edge the row keeps still: the stage shows the pair.
        if (split_drop.update(b, c, tab, h.origin)) return r;
        const last: f32 = @floatFromInt(@max(1, count) - 1);
        const target: usize = @intFromFloat(std.math.clamp(from + @round(travel / step), 0, last));
        if (target != index) r.target = target;
        return r;
    }

    // Let go.
    const was = h.*;
    st.hand = null;
    if (!was.held) return r;
    r.let_go = true;
    // Paired, or a pair's half put back in the row; else the half picked
    // up (or the tab) may go to another window.
    const source = switch (split_drop.finish(b, c, tab)) {
        .none => tab,
        .outside => |s| s,
        .taken, .cancelled => null,
    };
    if (source) |s| {
        if (b.dragOut(s, objc.msg(objc.CGPoint, objc.class("NSEvent"), "mouseLocation", .{}))) {
            r.outside = true;
        } else if (s == tab) r.dropped = mouse;
    }
    st.gen +%= 1;
    st.landing = .{ .tab = tab.id, .gen = st.gen, .from = was.shift };
    r.shift = ui.springFrom(c, springId(tab.id), st.gen, was.shift, 0, motion.settle);
    return r;
}
