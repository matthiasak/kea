//! The strip's sums (TabBar.swift 330-428): how much room the tabs have,
//! how wide each loose tab is, and how wide the run of them comes to.
//! Pure, so the formulas are tested on their own.
const std = @import("std");
const metrics = @import("../design/metrics.zig");

/// What the run holds: pinned squares, loose tabs (with groups on, the
/// ungrouped ones and each group's visible ones), group headings and
/// their summed widths; how many of the loose places are pairs.
pub const Row = struct {
    pins: usize = 0,
    loose: usize = 0,
    groups: usize = 0,
    headings: f32 = 0,
    pairs: usize = 0,

    /// What the pairs add over a loose tab's `base` (`pairWidthExtra`).
    fn extra(r: Row, base: f32) f32 {
        return @as(f32, @floatFromInt(r.pairs)) * (pairWidth(base) - base);
    }

    /// Gaps between every item of the run.
    fn gaps(r: Row) f32 {
        const n = r.pins + r.loose + r.groups;
        return @as(f32, @floatFromInt(@max(1, n) - 1)) * metrics.tab_gap;
    }

    /// What the squares, the headings and the gaps take before the tabs share the rest.
    pub fn spent(r: Row) f32 {
        return @as(f32, @floatFromInt(r.pins)) * metrics.pin_width + r.headings + r.gaps();
    }

    /// `width(in:)`: every loose tab's width in `room`.
    pub fn each(r: Row, room_: f32) f32 {
        return tabWidth(room_, r.loose, r.spent() + r.extra(metrics.tab_min_width));
    }

    /// `content(in:)`: the whole run at `each_` a tab.
    pub fn content(r: Row, each_: f32) f32 {
        return r.spent() + @as(f32, @floatFromInt(r.loose)) * each_ + r.extra(each_);
    }
};

/// Every loose tab is the same width, so the cross is always in the same
/// place: their share of what `spent` leaves of `room`, from 36 up to 186;
/// 186 when there are none.
pub fn tabWidth(room_: f32, loose: usize, spent: f32) f32 {
    if (loose == 0) return metrics.tab_width;
    return @max(metrics.tab_min_width, @min(metrics.tab_width, (room_ - spent) / @as(f32, @floatFromInt(loose))));
}

/// A pair's one place (`splitItemWidth`): half again a tab and a bit,
/// between 136 and 210.
pub fn pairWidth(base: f32) f32 {
    return @min(210, @max(136, base * 1.55));
}

/// Wide enough to wear its title; narrower, its mark alone.
pub fn titled(width: f32) bool {
    return width >= metrics.tab_titled;
}

/// `room(in:)`: the strip less the lights, the space's dot, the helm when
/// it leads, the trailing 12, the plus, the doors (`far`) and three gaps.
pub fn room(strip: f32, lights: f32, dot: f32, leading: f32, far_end: f32) f32 {
    return @max(0, strip - lights - dot - leading - 12 - metrics.plus_width - far_end - 3 * metrics.tab_gap);
}

/// `far`: the doors as measured; until they are, the helm and the
/// bookmarks stand in — unless the helm leads, when 0 may be real.
pub fn far(doors: f32, navigation_left: bool) f32 {
    return if (doors > 0 or navigation_left) doors else metrics.helm + 26;
}

test "tabWidth follows TabBar.swift: 186 cap, 36 floor, 80 titled" {
    const T = struct { room: f32, loose: usize, spent: f32, want: f32, titled: bool };
    const table = [_]T{
        .{ .room = 1000, .loose = 0, .spent = 0, .want = 186, .titled = true },
        .{ .room = 1000, .loose = 3, .spent = 4, .want = 186, .titled = true },
        .{ .room = 1000, .loose = 5, .spent = 0, .want = 186, .titled = true },
        .{ .room = 1000, .loose = 6, .spent = 0, .want = 1000.0 / 6.0, .titled = true },
        .{ .room = 1000, .loose = 10, .spent = 0, .want = 100, .titled = true },
        .{ .room = 818, .loose = 10, .spent = 18, .want = 80, .titled = true },
        .{ .room = 808, .loose = 10, .spent = 18, .want = 79, .titled = false },
        .{ .room = 1000, .loose = 40, .spent = 78, .want = 36, .titled = false },
        .{ .room = 0, .loose = 2, .spent = 2, .want = 36, .titled = false },
        .{ .room = 600, .loose = 4, .spent = 3 * 30 + 6 * 2, .want = (600.0 - 102.0) / 4.0, .titled = true },
    };
    for (table) |r| {
        const w = tabWidth(r.room, r.loose, r.spent);
        try std.testing.expectApproxEqAbs(r.want, w, 0.001);
        try std.testing.expectEqual(r.titled, titled(w));
    }
}

test "row spends squares, headings and gaps; room leaves the chrome" {
    const r: Row = .{ .pins = 2, .loose = 5, .groups = 1, .headings = 60 };
    // 2·30 + 60 + 7 gaps of 2.
    try std.testing.expectApproxEqAbs(@as(f32, 134), r.spent(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 134 + 5 * 100), r.content(100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), (Row{}).spent(), 0.001);
    // 1440 − 100 − 0 − 0 − 12 − 30 − (90 + 26) − 6.
    try std.testing.expectApproxEqAbs(@as(f32, 1176), room(1440, 100, 0, 0, far(0, false)), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), far(0, true), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), room(100, 100, 28, 84, 140), 0.001);
}

test "a pair takes one place, 1.55 tabs between 136 and 210" {
    try std.testing.expectApproxEqAbs(@as(f32, 136), pairWidth(36), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 155), pairWidth(100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 210), pairWidth(186), 0.001);
    const r: Row = .{ .loose = 3, .pairs = 1 };
    // 3 places of 100, one of them a pair 55 wider, and 2 gaps.
    try std.testing.expectApproxEqAbs(@as(f32, 300 + 55 + 4), r.content(100), 0.001);
}
