//! What a view asks of the window beyond drawing, on `Context`: the
//! focus given by the app, tooltips, drops from other apps, and boxes
//! that move the window.
const types = @import("types.zig");
const input = @import("input.zig");
const Context = @import("context.zig").Context;

/// Focuses the next box (a `textField` or `textArea` called right after),
/// as a click on it would; `select_all` selects its text.
pub fn focusNext(c: *Context, select_all: bool) void {
    c.focus = c.peekId(null);
    c.focus_select_all = select_all;
}

/// The tooltip of box `index` (one that interacts), shown while the
/// pointer rests on it or on a box inside it.
pub fn help(c: *Context, index: u32, s: []const u8) void {
    c.helps.put(c.gpa, c.node(index).id, c.alloc().dupe(u8, s) catch return) catch {};
}

/// The help of the hot box, or of the nearest box it is in that has one.
pub fn hotHelp(c: *const Context) ?[]const u8 {
    for (c.hot_path.items) |id| if (c.helps.get(id)) |s| return s;
    return null;
}

/// Box `index` takes drops (links, files, text): a drag over it is offered
/// a copy, and `dropAt` gives it what lands.
pub fn acceptDrop(c: *Context, index: u32) void {
    c.drop_targets.append(c.gpa, c.node(index).id) catch {};
}

/// Whether a box that takes drops was under `p` in the last frame.
pub fn acceptsDropAt(c: *const Context, p: types.Point) bool {
    for (c.drop_targets.items) |id| if (c.rects.get(id)) |r| if (r.contains(p)) return true;
    return false;
}

/// What was dropped on box `index` in this event, if anything was.
pub fn dropAt(c: *Context, index: u32) ?input.Drop {
    const d = c.input.drop orelse return null;
    const r = c.rects.get(c.node(index).id) orelse return null;
    if (!r.contains(d.point)) return null;
    c.changed = true;
    return d;
}

/// Whether this press moves the window: a single click on a box with
/// `window_drag` (a second one comes to it as a double click).
pub fn startsWindowDrag(c: *const Context) bool {
    if (c.input.click_count != 1 or c.hot_index >= c.nodes.items.len) return false;
    const n = c.nodes.items[c.hot_index];
    return n.id == c.hot and n.style.window_drag;
}
