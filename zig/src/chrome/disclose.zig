//! Content that arrives or leaves inside a box SwiftUI animates
//! (`.transition(.opacity)` under `.animation(settle)`): it fades, and the
//! room it takes springs between none and its own height, so what sits
//! below settles into place rather than jumping.
const ui = @import("nanoui").ui;
const presence = @import("presence.zig").presence;

/// Opens the box when item `id` is to be drawn — arriving, here, or still
/// leaving — and returns whether it did; draw the content, then `end`.
pub fn begin(c: *ui.Context, id: u64, shown: bool, s: ui.Spring) bool {
    const t = @min(presence(c, id, shown, s, null) orelse return false, 1);
    const outer = c.open(.{ .width = .fill, .clip = true, .opacity = t }, null);
    const inner = c.open(.{ .width = .fill }, null);
    // Its height the frame before, at full size inside the clip; none yet
    // on the first frame, so it starts from nothing.
    if (t < 1) c.node(outer).style.max_height = if (c.rects.get(c.node(inner).id)) |r| r.h * t else 0;
    return true;
}

pub fn end(c: *ui.Context) void {
    c.end();
    c.end();
}
