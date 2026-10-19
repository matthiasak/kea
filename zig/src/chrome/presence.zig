//! Arriving and leaving, as SwiftUI's transitions do: an item's progress
//! from 0 (gone) to 1 (here), which the caller maps to the transition's
//! scale, opacity or offset; a leaving item is drawn until it is gone.
const ui = @import("nanoui").ui;

/// The progress of item `id`: springing toward 1 while `shown` (from 0 the
/// first time) with `in_`, toward 0 while not with `out` (`in_` when null);
/// null once a hidden item has fully left, or was never there. A spring
/// may overshoot 1 a little, as SwiftUI's does.
pub fn presence(c: *ui.Context, id: u64, shown: bool, in_: ui.Spring, out: ?ui.Spring) ?f32 {
    return presenceFrom(c, id, 0, shown, in_, out);
}

/// As `presence`, but the first call starts at `from`: 1 for an item that
/// was already there when its view first drew, as SwiftUI's first render
/// plays no transition.
pub fn presenceFrom(c: *ui.Context, id: u64, from: f32, shown: bool, in_: ui.Spring, out: ?ui.Spring) ?f32 {
    const v = ui.springFrom(c, id, 0x7072_6573, from, if (shown) 1 else 0, if (shown) in_ else out orelse in_);
    if (!shown and v == 0) return null;
    return v;
}
