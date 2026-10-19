//! `TabAddressField` (TabBar.swift 855-978): the address, short form, or the
//! name being given, typed into the tab itself — the live pill in the strip
//! or the live row in the column. Return keeps it (or, refused, shakes and
//! stays); a click anywhere else keeps it too (`finishTabEdit`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("controls.zig");
const site_card = @import("site_card.zig");

/// The field's own state across frames, on its `Browser`.
pub const State = struct {
    /// The tab whose field took the keys (`claimed`), and whether it has had them.
    claimed: ?u64 = null,
    had_focus: bool = false,
    /// Refusals seen, and the shakes they gave.
    refusals: u32 = 0,
    shakes: u32 = 0,
};

const shake_id: u64 = std.hash.Wyhash.hash(0, "kea.tab.address");

/// The pill's or row's sideways shake while its address is refused.
pub fn shake(b: *Browser, c: *ui.Context) f32 {
    const st = &b.tab_field;
    if (b.refusals != st.refusals) {
        st.refusals = b.refusals;
        st.shakes +%= 1;
    }
    return controls.shake(c, shake_id, st.shakes);
}

/// The field, 16 high, filling what the pill or row leaves it.
pub fn field(b: *Browser, c: *ui.Context, p: *const Palette, tab: *Tab) void {
    const st = &b.tab_field;
    const box = c.open(.{ .grow = 1, .height = .{ .px = 16 }, .align_items = .center }, "kea.tab.address");
    defer c.end();
    if (st.claimed != tab.id) {
        // The name or address it arrives with, selected whole.
        st.claimed = tab.id;
        st.had_focus = false;
        st.refusals = b.refusals;
        ui.focusNext(c, true);
    }
    const text_id = c.peekId(null);
    const m = c.input.mouse;
    const res = ui.textField(c, &b.tab_draft, .{ .bare = true, .size = 12.5, .width = .fill, .selection_color = p.ink.alpha(0.11), .caret_color = p.ink });
    if (c.rects.get(c.node(box).id)) |r| b.tab_field_rect = r;
    if (res.submitted) return b.commitTabEdit();
    const focused = c.focus == text_id;
    // The keys gone elsewhere, or a press anywhere but here — on something
    // that takes no keys too: what was typed is kept, as Return keeps it.
    const outside = c.input.pressed and !b.tab_field_rect.contains(m) and !site_card.under(b, m);
    if ((st.had_focus and !focused) or outside) return b.finishTabEdit();
    st.had_focus = st.had_focus or focused;
}
