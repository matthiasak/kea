//! The native view's side of AppKit's text input (NSTextInputClient): key
//! events go through `interpretKeyEvents:`, which answers with text to
//! insert, an input method's composition, or editing commands from the
//! system's key bindings. They become `TextOp`s for the focused field.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const ctx_mod = @import("context.zig");
const Surface = @import("surface.zig").Surface;

const NSRange = extern struct { location: usize, length: usize };
const not_found: usize = @as(usize, std.math.maxInt(isize));

extern "c" fn sel_getName(sel: objc.SEL) [*:0]const u8;

pub const methods = [_]objc.Method{
    .{ .name = "insertText:replacementRange:", .imp = &insertText, .types = "v@:@{_NSRange=QQ}" },
    .{ .name = "setMarkedText:selectedRange:replacementRange:", .imp = &setMarkedText, .types = "v@:@{_NSRange=QQ}{_NSRange=QQ}" },
    .{ .name = "unmarkText", .imp = &unmarkText, .types = "v@:" },
    .{ .name = "hasMarkedText", .imp = &hasMarkedText, .types = "c@:" },
    .{ .name = "markedRange", .imp = &markedRange, .types = "{_NSRange=QQ}@:" },
    .{ .name = "selectedRange", .imp = &selectedRange, .types = "{_NSRange=QQ}@:" },
    .{ .name = "validAttributesForMarkedText", .imp = &validAttributes, .types = "@@:" },
    .{ .name = "attributedSubstringForProposedRange:actualRange:", .imp = &attributedSubstring, .types = "@@:{_NSRange=QQ}^{_NSRange=QQ}" },
    .{ .name = "firstRectForCharacterRange:actualRange:", .imp = &firstRect, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}" },
    .{ .name = "characterIndexForPoint:", .imp = &characterIndex, .types = "Q@:{CGPoint=dd}" },
    .{ .name = "doCommandBySelector:", .imp = &doCommand, .types = "v@::" },
    .{ .name = "copy:", .imp = &copyAction, .types = "v@:@" },
    .{ .name = "cut:", .imp = &cutAction, .types = "v@:@" },
    .{ .name = "selectAll:", .imp = &selectAllAction, .types = "v@:@" },
};

/// Operations of the event being interpreted, run as one frame after it.
pub const Queue = struct {
    ops: std.ArrayList(ctx_mod.TextOp) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Inside `keyDown:`: operations wait for the end of the event.
    collecting: bool = false,

    pub fn init(gpa: std.mem.Allocator) Queue {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(q: *Queue, gpa: std.mem.Allocator) void {
        q.ops.deinit(gpa);
        q.arena.deinit();
    }
};

fn push(s: *Surface, op: ctx_mod.TextOp) void {
    s.text_queue.ops.append(s.gpa, op) catch return;
    if (!s.text_queue.collecting) flush(s);
}

fn dupe(s: *Surface, str: []const u8) []const u8 {
    return s.text_queue.arena.allocator().dupe(u8, str) catch "";
}

/// Runs a frame with the queued operations.
pub fn flush(s: *Surface) void {
    const q = &s.text_queue;
    if (q.ops.items.len == 0) return;
    s.ctx.input.ops = q.ops.items;
    s.frame();
    s.ctx.input.ops = &.{};
    q.ops.clearRetainingCapacity();
    _ = q.arena.reset(.retain_capacity);
}

/// Sends a key event through the input system; true if a text field
/// had the focus to receive it.
pub fn interpret(s: *Surface, event: objc.Object) bool {
    if (s.ctx.focused_text == null) return false;
    s.text_queue.collecting = true;
    const arr = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{event});
    objc.msg(void, s.nsview, "interpretKeyEvents:", .{arr});
    s.text_queue.collecting = false;
    flush(s);
    return true;
}

fn stringOf(obj: objc.Object) []const u8 {
    // An NSAttributedString or an NSString.
    if (objc.msg(objc.BOOL, obj, "isKindOfClass:", .{objc.class("NSAttributedString")}))
        return objc.fromNSString(objc.msg(?objc.Object, obj, "string", .{}));
    return objc.fromNSString(obj);
}

fn insertText(obj: objc.Object, _: objc.SEL, str: objc.Object, _: NSRange) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    const t = stringOf(str);
    // Control characters arrive as commands, not text.
    if (t.len == 1 and (t[0] < 0x20 or t[0] == 0x7f)) return;
    push(s, .{ .insert = dupe(s, t) });
}

fn setMarkedText(obj: objc.Object, _: objc.SEL, str: objc.Object, sel: NSRange, _: NSRange) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    const t = dupe(s, stringOf(str));
    const start = cf.byteOffset(t, @intCast(sel.location));
    const end = cf.byteOffset(t, @intCast(sel.location + sel.length));
    push(s, .{ .set_marked = .{ .text = t, .sel_start = start, .sel_len = end - start } });
}

fn unmarkText(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    push(s, .unmark);
}

fn hasMarkedText(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const s = objc.getZig(Surface, obj) orelse return objc.NO;
    const f = s.ctx.focused_text orelse return objc.NO;
    return f.marked != null;
}

fn range16(text: []const u8, lo: usize, hi: usize) NSRange {
    const a: usize = @intCast(cf.utf16Offset(text, lo));
    const b: usize = @intCast(cf.utf16Offset(text, hi));
    return .{ .location = a, .length = b - a };
}

fn markedRange(obj: objc.Object, _: objc.SEL) callconv(.c) NSRange {
    const s = objc.getZig(Surface, obj) orelse return .{ .location = not_found, .length = 0 };
    const f = s.ctx.focused_text orelse return .{ .location = not_found, .length = 0 };
    const m = f.marked orelse return .{ .location = not_found, .length = 0 };
    return range16(f.text, m[0], m[1]);
}

fn selectedRange(obj: objc.Object, _: objc.SEL) callconv(.c) NSRange {
    const s = objc.getZig(Surface, obj) orelse return .{ .location = not_found, .length = 0 };
    const f = s.ctx.focused_text orelse return .{ .location = not_found, .length = 0 };
    return range16(f.text, @min(f.caret, f.anchor), @max(f.caret, f.anchor));
}

fn validAttributes(_: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
}

fn attributedSubstring(_: objc.Object, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) ?objc.Object {
    return null;
}

/// Where the input method's candidate window goes: under the caret, in
/// screen coordinates.
fn firstRect(obj: objc.Object, _: objc.SEL, _: NSRange, _: ?*NSRange) callconv(.c) objc.CGRect {
    const s = objc.getZig(Surface, obj) orelse return .{};
    const f = s.ctx.focused_text orelse return .{};
    const r: objc.CGRect = .{ .origin = .{ .x = f.caret_rect.x, .y = f.caret_rect.y }, .size = .{ .width = f.caret_rect.w, .height = f.caret_rect.h } };
    const in_window = objc.msg(objc.CGRect, obj, "convertRect:toView:", .{ r, @as(?objc.Object, null) });
    return objc.msg(objc.CGRect, s.window.nswindow, "convertRectToScreen:", .{in_window});
}

fn characterIndex(_: objc.Object, _: objc.SEL, _: objc.CGPoint) callconv(.c) usize {
    return not_found;
}

const commands = .{
    .{ "deleteBackward:", .delete_backward },
    .{ "deleteBackwardByDecomposingPreviousCharacter:", .delete_backward },
    .{ "deleteForward:", .delete_forward },
    .{ "deleteWordBackward:", .delete_word_backward },
    .{ "deleteToBeginningOfLine:", .delete_to_line_start },
    .{ "deleteToEndOfLine:", .delete_to_line_end },
    .{ "deleteToEndOfParagraph:", .delete_to_line_end },
    .{ "deleteWordForward:", .delete_word_forward },
    .{ "moveToBeginningOfParagraph:", .move_line_start },
    .{ "moveToEndOfParagraph:", .move_line_end },
    .{ "moveLeft:", .move_left },
    .{ "moveRight:", .move_right },
    .{ "moveBackward:", .move_left },
    .{ "moveForward:", .move_right },
    .{ "moveWordLeft:", .move_word_left },
    .{ "moveWordRight:", .move_word_right },
    .{ "moveToBeginningOfLine:", .move_line_start },
    .{ "moveToLeftEndOfLine:", .move_line_start },
    .{ "moveToBeginningOfDocument:", .move_line_start },
    .{ "moveUp:", .move_line_start },
    .{ "moveToEndOfLine:", .move_line_end },
    .{ "moveToRightEndOfLine:", .move_line_end },
    .{ "moveToEndOfDocument:", .move_line_end },
    .{ "moveDown:", .move_line_end },
    .{ "moveLeftAndModifySelection:", .select_left },
    .{ "moveRightAndModifySelection:", .select_right },
    .{ "moveWordLeftAndModifySelection:", .select_word_left },
    .{ "moveWordRightAndModifySelection:", .select_word_right },
    .{ "moveToBeginningOfLineAndModifySelection:", .select_line_start },
    .{ "moveToLeftEndOfLineAndModifySelection:", .select_line_start },
    .{ "moveUpAndModifySelection:", .select_line_start },
    .{ "moveToEndOfLineAndModifySelection:", .select_line_end },
    .{ "moveToRightEndOfLineAndModifySelection:", .select_line_end },
    .{ "moveDownAndModifySelection:", .select_line_end },
    .{ "selectAll:", .select_all },
    .{ "insertNewline:", .insert_newline },
    .{ "insertLineBreak:", .insert_newline },
    .{ "insertTab:", .insert_tab },
    .{ "cancelOperation:", .cancel },
};

fn doCommand(obj: objc.Object, _: objc.SEL, sel: objc.SEL) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    const name = std.mem.span(sel_getName(sel));
    inline for (commands) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return push(s, .{ .command = entry[1] });
    }
}

fn copyAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    // A page's selection may take it where no field does.
    push(s, .{ .command = .copy });
}

fn cutAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text != null) push(s, .{ .command = .cut });
}

fn selectAllAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.ctx.focused_text != null) push(s, .{ .command = .select_all });
}

/// Pasted text, as if typed.
pub fn paste(s: *Surface, text: []const u8) void {
    push(s, .{ .insert = dupe(s, text) });
}
