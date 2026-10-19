//! One line of text cut to fit its box (`TextStyle.truncate`): measured
//! at its whole width but flexible, so a row shrinks it; once arranged
//! narrower, its string is the longest prefix that fits, then "…".
const std = @import("std");
const types = @import("types.zig");
const Context = @import("context.zig").Context;

pub const ellipsis = "…";

/// Cuts text box `index` to `w` points (its padding included) if it is wider.
pub fn fit(c: *Context, index: u32, w: f32) void {
    const n = c.node(index);
    const t = &n.content.text;
    const room = w - n.style.padding.horizontal();
    if (c.text.width(t.str, t.style) <= room + 0.5) return;
    t.str = cut(c, t.str, t.style, room);
}

/// The longest prefix of `s` that fits `room` with "…" after it, in the frame's memory.
pub fn cut(c: *Context, s: []const u8, style: types.TextStyle, room: f32) []const u8 {
    const avail = room - c.text.width(ellipsis, style);
    var i: usize = if (avail <= 0) 0 else c.text.indexAt(s, style, avail);
    // The nearest caret may be past the room: step back a character at a time.
    while (i > 0 and c.text.width(s[0..i], style) > avail) {
        i -= 1;
        while (i > 0 and s[i] & 0xC0 == 0x80) i -= 1;
    }
    const out = c.alloc().alloc(u8, i + ellipsis.len) catch return s;
    @memcpy(out[0..i], s[0..i]);
    @memcpy(out[i..], ellipsis);
    return out;
}
