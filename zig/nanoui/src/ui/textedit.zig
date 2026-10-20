//! Shared text-editing helpers for `textField` and `textArea`: word and
//! line selection by click count and drag granularity, `.system` undo/redo
//! shortcuts, and caret blink timing.
const std = @import("std");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const EditState = ctx_mod.EditState;
const tf = @import("textfield.zig");
const keymap = @import("keymap.zig");

pub const Granularity = enum { char, word, line };
pub const UndoOp = enum { none, undo, redo };

pub fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

pub fn prevWord(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and !isWordByte(s[j - 1])) j -= 1;
    while (j > 0 and isWordByte(s[j - 1])) j -= 1;
    return j;
}

pub fn nextWord(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and !isWordByte(s[j])) j += 1;
    while (j < s.len and isWordByte(s[j])) j += 1;
    return j;
}

pub fn lineStart(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j > 0 and s[j - 1] != '\n') j -= 1;
    return j;
}

pub fn lineEnd(s: []const u8, i: usize) usize {
    var j = @min(i, s.len);
    while (j < s.len and s[j] != '\n') j += 1;
    return j;
}

pub fn pointerSelect(c: *Context, e: *EditState, s: []const u8, at: usize, multiline: bool) void {
    e.undo.group = false;
    c.caret_moved_at = c.time;
    if (c.input.click_count >= 3) {
        c.select_granularity = .line;
        const lo: usize = if (multiline) lineStart(s, at) else 0;
        const hi: usize = if (multiline) lineEnd(s, at) else s.len;
        e.anchor = lo;
        e.caret = hi;
        c.select_origin = .{ lo, hi };
    } else if (c.input.click_count == 2) {
        c.select_granularity = .word;
        const lo = prevWord(s, at);
        const hi = nextWord(s, at);
        e.anchor = lo;
        e.caret = hi;
        c.select_origin = .{ lo, hi };
    } else {
        c.select_granularity = .char;
        e.caret = at;
        if (!c.input.shift) e.anchor = at;
        c.select_origin = .{ e.anchor, e.anchor };
    }
    e.marked = null;
    c.selection.blocked = true;
    e.selecting = true;
}

pub fn pointerDrag(c: *Context, e: *EditState, s: []const u8, at: usize, multiline: bool) void {
    const orig0 = @min(c.select_origin[0], s.len);
    const orig1 = @min(c.select_origin[1], s.len);
    switch (c.select_granularity) {
        .char => e.caret = at,
        .word => if (at >= orig0) {
            e.anchor = orig0;
            e.caret = @max(orig1, nextWord(s, at));
        } else {
            e.anchor = orig1;
            e.caret = prevWord(s, at);
        },
        .line => if (!multiline) {
            e.anchor = 0;
            e.caret = s.len;
        } else if (at >= orig0) {
            e.anchor = orig0;
            e.caret = @max(orig1, lineEnd(s, at));
        } else {
            e.anchor = orig1;
            e.caret = lineStart(s, at);
        },
    }
    c.caret_moved_at = c.time;
}

pub fn handleUndoShortcuts(c: *Context, b: *tf.TextBuffer, e: *EditState, r: *tf.Result) bool {
    if (c.undo_op != .none) {
        const redo = c.undo_op == .redo;
        c.undo_op = .none;
        keymap.undoStep(b, e, r, redo);
        c.changed = true;
        return true;
    }
    if (c.shortcut(.{ .key = 'z', .cmd = true, .shift = true }) or c.shortcut(.{ .key = 'y', .cmd = true })) {
        keymap.undoStep(b, e, r, true);
        return true;
    }
    if (c.shortcut(.{ .key = 'z', .cmd = true })) {
        keymap.undoStep(b, e, r, false);
        return true;
    }
    return false;
}

pub fn commitUndo(c: *Context, b: *tf.TextBuffer, e: *EditState, r: *const tf.Result, took_text: bool, took_key: bool) void {
    if (c.paste_op) e.undo.group = false;
    var typing = !c.paste_op and !took_text and !took_key and c.input.key == null and (c.input.chars.len > 0 or c.input.ops.len > 0);
    for (c.input.ops) |op| typing = typing and op == .insert;
    e.undo.commit(b.text(), e.caret, r.changed, typing);
}

pub fn updateCaretBlink(c: *Context, was_focused: bool, changed: bool, moved: bool) void {
    if (!was_focused or changed or moved or c.input.pressed) c.caret_moved_at = c.time;
}

pub fn caretVisible(c: *Context) bool {
    if (!c.window_focused) return false;
    const elapsed = @max(0.0, c.time - c.caret_moved_at);
    const rem: f32 = 0.5 - @mod(@as(f32, @floatCast(elapsed)), 0.5);
    c.frameIn(@max(0.01, rem));
    return elapsed < 0.5 or @mod(elapsed, 1.0) < 0.5;
}
