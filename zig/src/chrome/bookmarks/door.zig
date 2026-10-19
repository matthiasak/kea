//! `BookmarkDoor` (Bookmarks.swift 1226-1265): the bookmark button, in the
//! strip or at the foot of the column — filled on a page that is kept —
//! and what hangs off it: the card for one bookmark when ⇧⌘B opened it,
//! the list otherwise (`chrome/overlays.zig`).
const ui = @import("nanoui").ui;
const Browser = @import("../../model/browser.zig").Browser;
const Palette = @import("../../design/palette.zig").Palette;
const controls = @import("../controls.zig");
const overlays = @import("../overlays.zig");
const actions = @import("actions.zig");
const dropdown = @import("dropdown.zig");
const card = @import("card.zig");

/// Which way the popover hangs: under the strip's door, beside the foot's.
pub const Edge = enum { below, trailing };

pub fn door(b: *Browser, c: *ui.Context, p: *const Palette, edge: Edge) void {
    const it = controls.door(c, p, if (actions.pageKept(b)) "bookmark.fill" else "bookmark", .{ .help = "Bookmarks" });
    const s = &b.marks_ui;
    if (it.rect) |r| {
        s.door = r;
        s.door_edge = if (edge == .below) .below else .trailing;
        // The popover follows its button as the window changes.
        if (actions.isOpen(b)) b.overlay_anchor = r;
    }
    if (it.clicked) actions.toggleBookmarks(b);
}

/// Where the list or the card goes from the button.
pub fn place(b: *const Browser) overlays.Place {
    return .{ .edge = if (b.marks_ui.door_edge == .below) .below else .trailing, .alignment = .center };
}

/// The list or the card, inside the open overlay's box.
pub fn overlay(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (b.overlay.? == .bookmark_card) card.view(b, c, p) else dropdown.view(b, c, p);
}
