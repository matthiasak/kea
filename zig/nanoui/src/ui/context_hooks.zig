//! What a view asks of the window beyond drawing, on `Context`: the
//! focus given by the app, tooltips, drops from other apps, boxes
//! that move the window, and what VoiceOver sees of them.
const types = @import("types.zig");
const input = @import("input.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

/// Focuses the next box (a `textField` or `textArea` called right after),
/// as a click on it would; `select_all` selects its text.
pub fn focusNext(c: *Context, select_all: bool) void {
    c.focus = c.peekId(null);
    c.focus_select_all = select_all;
}

/// The tooltip of box `index`, shown while the pointer rests on it or on a
/// box inside it. A box that takes no clicks (a marker icon) shows its own
/// over that of the clickable box it is drawn in, as AppKit's tooltip
/// rects do.
pub fn help(c: *Context, index: u32, s: []const u8) void {
    c.helps.put(c.gpa, c.node(index).id, c.alloc().dupe(u8, s) catch return) catch {};
}

/// The help of the smallest quiet box under the pointer inside the hot
/// box, else of the hot box, or of the nearest box it is in that has one.
pub fn hotHelp(c: *const Context) ?[]const u8 {
    if (c.rects.get(c.hot)) |hot| {
        var best: ?[]const u8 = null;
        var area = hot.w * hot.h;
        var it = c.helps.iterator();
        while (it.next()) |e| {
            const r = c.rects.get(e.key_ptr.*) orelse continue;
            if (e.key_ptr.* == c.hot or !r.contains(c.input.mouse) or r.w * r.h >= area) continue;
            if (r.x < hot.x or r.y < hot.y or r.x + r.w > hot.x + hot.w or r.y + r.h > hot.y + hot.h) continue;
            best = e.value_ptr.*;
            area = r.w * r.h;
        }
        if (best) |s| return s;
    }
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

/// Box `index` as VoiceOver sees it (a button, a field…).
pub fn addA11y(c: *Context, index: u32, role: ctx_mod.A11yRole, label: []const u8, value: []const u8, selected: bool, enabled: bool) void {
    c.a11y_items.append(c.gpa, .{
        .id = c.nodes.items[index].id,
        .node_index = index,
        .role = role,
        .label = if (label.len > 0) (c.alloc().dupe(u8, label) catch label) else "",
        .value = if (value.len > 0) (c.alloc().dupe(u8, value) catch value) else "",
        .selected = selected,
        .enabled = enabled,
    }) catch {};
}

/// Box `index` as an element VoiceOver increments and decrements (a
/// splitter, a slider): its `interact` then reports `a11y_step`.
pub fn adjustable(c: *Context, index: u32, opts: struct { role: ctx_mod.A11yRole = .slider, label: []const u8, value: []const u8 = "", enabled: bool = true }) void {
    const n = c.a11y_items.items.len;
    c.addA11y(index, opts.role, opts.label, opts.value, false, opts.enabled);
    if (c.a11y_items.items.len > n) c.a11y_items.items[n].adjustable = true;
}

/// VoiceOver incremented (`dir` +1) or decremented (−1) box `id`: the
/// next frame's `interact` of it reports the step.
pub fn a11yStep(c: *Context, id: u64, dir: i8) void {
    c.input.a11y_step = .{ .id = id, .dir = dir };
}
