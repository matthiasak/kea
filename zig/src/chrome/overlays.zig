//! Kea's popovers and borderless child windows (SiteCard, BookmarkCard,
//! AccountList, the history hold list…) as one box over the window at a
//! time: anchored to what opened it, drawn last so it takes the clicks
//! over it, closed by a press outside it or Esc.
const ui = @import("nanoui").ui;

/// What is open over the window.
pub const Overlay = union(enum) {
    bookmarks_dropdown,
    bookmark_card,
    /// The site card of tab id.
    site_card: u64,
    account_list,
    extension_menu,
    /// The back or forward list held open, of tab id.
    history_hold: u64,
    space_name,
};

pub const Place = struct {
    /// Hanging under the opener, or beside it on its right.
    edge: enum { below, trailing } = .below,
    /// Points between the opener and the overlay.
    gap: f32 = 6,
    /// Along the opener: their starts lined up, centred, or their ends.
    alignment: enum { start, center, end } = .start,
    /// The least room kept to the window's edges.
    margin: f32 = 8,
};

const key = "kea.overlay";

/// Opens the box of the open overlay over everything, from the root view
/// after all else; true when there is one, then the caller builds its
/// content and calls `ui.end`. `style` is the box's own (size, fill,
/// radius, shadow); its place comes from `anchor` (the opener's rect,
/// a press on which is left to the opener). A press outside it or Esc
/// sets `open` to null.
pub fn begin(c: *ui.Context, open: *?Overlay, anchor: ui.Rect, style: ui.Style, place: Place) bool {
    if (open.* == null) return false;
    const id = c.peekId(key);
    const last = c.rects.get(id);
    const m = c.input.mouse;
    if (c.shortcut(.{ .key = ui.Shortcut.escape }) or
        (c.input.pressed and last != null and !last.?.contains(m) and !anchor.contains(m)))
    {
        open.* = null;
        c.changed = true;
        return false;
    }
    var s = style;
    s.absolute = true;
    const size: ui.Size = if (last) |r| .{ .w = r.w, .h = r.h } else .{};
    // Unseen until its size is known, so it never shows in the wrong place.
    if (last == null) s.opacity = 0;
    s.offset = at(c.size, anchor, size, place);
    const i = c.open(s, key);
    _ = c.interact(i, .{});
    c.addA11y(i, .popover, @tagName(open.*.?), "", false, true);
    return true;
}

/// Where an overlay of `size` goes for `anchor` in a window of `window`.
pub fn at(window: ui.Size, anchor: ui.Rect, size: ui.Size, place: Place) ui.Point {
    var p: ui.Point = switch (place.edge) {
        .below => .{ .x = along(anchor.x, anchor.w, size.w, place), .y = anchor.y + anchor.h + place.gap },
        .trailing => .{ .x = anchor.x + anchor.w + place.gap, .y = along(anchor.y, anchor.h, size.h, place) },
    };
    p.x = @max(place.margin, @min(p.x, window.w - size.w - place.margin));
    p.y = @max(place.margin, @min(p.y, window.h - size.h - place.margin));
    return p;
}

fn along(start: f32, len: f32, own: f32, place: Place) f32 {
    return switch (place.alignment) {
        .start => start,
        .center => start + (len - own) / 2,
        .end => start + len - own,
    };
}
