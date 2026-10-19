//! Raw AppKit the chrome needs beside nanoui: `NSEvent` monitors, the
//! pointer's place on screen, and the few questions asked as alert sheets
//! (`Ask`, Spaces.swift:509-607) with their completion blocks.
const std = @import("std");
const objc = @import("nanoui").objc;

// MARK: event monitors

/// `NSEventMask` bits.
pub const mask = struct {
    pub const mouse_moved: u64 = 1 << 5;
    pub const left_mouse_dragged: u64 = 1 << 6;
    pub const scroll_wheel: u64 = 1 << 22;
};

/// `NSEvent.addLocalMonitorForEvents(matching:)`: `func(ctx, event)` sees
/// each matching event of this app first and returns it to let it go on,
/// or null to keep it. `ctx` must outlive the monitor. The monitor
/// (retained) goes to `removeMonitor`.
pub fn addLocalMonitor(events: u64, ctx: anytype, comptime func: fn (@TypeOf(ctx), objc.Object) ?objc.Object) ?objc.Object {
    const Ctx = std.meta.Child(@TypeOf(ctx));
    var block = objc.BlockRet(Ctx, &.{objc.Object}, ?objc.Object).init(ctx, func);
    const m = objc.msg(?objc.Object, objc.class("NSEvent"), "addLocalMonitorForEventsMatchingMask:handler:", .{ events, &block }) orelse return null;
    return objc.retain(m);
}

/// `addGlobalMonitorForEvents(matching:)`: other apps' events, seen only.
pub fn addGlobalMonitor(events: u64, ctx: anytype, comptime func: fn (@TypeOf(ctx), objc.Object) void) ?objc.Object {
    const Ctx = std.meta.Child(@TypeOf(ctx));
    var block = objc.Block(Ctx, &.{objc.Object}).init(ctx, func);
    const m = objc.msg(?objc.Object, objc.class("NSEvent"), "addGlobalMonitorForEventsMatchingMask:handler:", .{ events, &block }) orelse return null;
    return objc.retain(m);
}

pub fn removeMonitor(monitor: objc.Object) void {
    objc.msg(void, objc.class("NSEvent"), "removeMonitor:", .{monitor});
    objc.release(monitor);
}

/// `NSEvent.mouseLocation`: screen points, y up.
pub fn mouseLocation() objc.CGPoint {
    return objc.msg(objc.CGPoint, objc.class("NSEvent"), "mouseLocation", .{});
}

/// The number of the window at `screen` point, whichever app's (`windowNumber(at:belowWindowWithWindowNumber: 0)`).
pub fn windowNumberAt(screen: objc.CGPoint) objc.NSInteger {
    return objc.msg(objc.NSInteger, objc.class("NSWindow"), "windowNumberAtPoint:belowWindowWithWindowNumber:", .{ screen, @as(objc.NSInteger, 0) });
}

/// The point is on some screen's visible frame (not the Dock, not the menu bar).
pub fn onVisibleScreen(screen: objc.CGPoint) bool {
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const n = objc.msg(objc.NSUInteger, screens, "count", .{});
    for (0..n) |i| {
        const s = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const f = objc.msg(objc.CGRect, s, "visibleFrame", .{});
        if (screen.x >= f.origin.x and screen.x < f.origin.x + f.size.width and
            screen.y >= f.origin.y and screen.y < f.origin.y + f.size.height) return true;
    }
    return false;
}

/// Some window of this app has that number (a popover, a panel).
pub fn ownWindowNumbered(number: objc.NSInteger) bool {
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const windows = objc.msg(objc.Object, nsapp, "windows", .{});
    const n = objc.msg(objc.NSUInteger, windows, "count", .{});
    for (0..n) |i| {
        const w = objc.msg(objc.Object, windows, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (objc.msg(objc.NSInteger, w, "windowNumber", .{}) == number) return true;
    }
    return false;
}

// MARK: questions (`Ask`)

/// What an alert asks: its fields' values come back to `done`.
pub const Question = struct {
    title: []const u8,
    detail: ?[]const u8 = null,
    /// A text field: its placeholder and what it starts with.
    field: ?struct { placeholder: []const u8, initial: []const u8 = "" } = null,
    /// A checkbox under the field, off at first.
    checkbox: ?[]const u8 = null,
    confirm: []const u8,
    destructive: bool = false,
};

pub const Answer = struct {
    ok: bool,
    /// The field's text, trimmed (borrowed until `done` returns).
    text: []const u8 = "",
    checked: bool = false,
};

const NSAlertFirstButtonReturn: objc.NSInteger = 1000;

fn Pending(comptime Ctx: type) type {
    return struct {
        alert: objc.Object,
        field: ?objc.Object,
        box: ?objc.Object,
        ctx: *Ctx,
        func: *const fn (*Ctx, Answer) void,

        fn finish(self: *@This(), response: objc.NSInteger) void {
            const pool = objc.Pool.push();
            defer pool.pop();
            var answer: Answer = .{ .ok = response == NSAlertFirstButtonReturn };
            if (self.field) |f| answer.text = std.mem.trim(u8, objc.fromNSString(objc.msg(objc.Object, f, "stringValue", .{})), " \t\r\n");
            if (self.box) |b| answer.checked = objc.msg(objc.NSInteger, b, "state", .{}) == 1;
            self.func(self.ctx, answer);
            if (self.field) |f| objc.release(f);
            if (self.box) |b| objc.release(b);
            objc.release(self.alert);
            std.heap.c_allocator.destroy(self);
        }
    };
}

/// `Ask.show`: the alert as a sheet on `window`, or modal with none.
/// `ctx` must live until `func` is called.
pub fn ask(window: ?objc.Object, q: Question, ctx: anytype, comptime func: fn (@TypeOf(ctx), Answer) void) void {
    const Ctx = std.meta.Child(@TypeOf(ctx));
    const pool = objc.Pool.push();
    defer pool.pop();
    const alert = objc.new("NSAlert");
    objc.msg(void, alert, "setMessageText:", .{objc.nsString(q.title)});
    if (q.detail) |d| objc.msg(void, alert, "setInformativeText:", .{objc.nsString(d)});
    var field: ?objc.Object = null;
    var box: ?objc.Object = null;
    if (q.field) |f| {
        const both = q.checkbox != null;
        const tf = objc.msg(objc.Object, objc.alloc("NSTextField"), "initWithFrame:", .{objc.CGRect{ .origin = .{ .y = if (both) 30 else 0 }, .size = .{ .width = if (both) 260 else 240, .height = 24 } }});
        objc.msg(void, tf, "setPlaceholderString:", .{objc.nsString(f.placeholder)});
        objc.msg(void, tf, "setStringValue:", .{objc.nsString(f.initial)});
        field = tf;
        if (q.checkbox) |title| {
            const cb = objc.retain(objc.msg(objc.Object, objc.class("NSButton"), "checkboxWithTitle:target:action:", .{ objc.nsString(title), @as(?objc.Object, null), @as(?objc.SEL, null) }));
            objc.msg(void, cb, "setFrame:", .{objc.CGRect{ .size = .{ .width = 260, .height = 22 } }});
            box = cb;
            const holder = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{ .size = .{ .width = 260, .height = 56 } }});
            objc.msg(void, holder, "addSubview:", .{tf});
            objc.msg(void, holder, "addSubview:", .{cb});
            objc.msg(void, alert, "setAccessoryView:", .{holder});
            objc.release(holder);
        } else objc.msg(void, alert, "setAccessoryView:", .{tf});
    }
    const confirm = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString(q.confirm)});
    if (q.destructive) objc.msg(void, confirm, "setHasDestructiveAction:", .{objc.YES});
    _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString("Cancel")});
    if (field) |f| objc.msg(void, objc.msg(objc.Object, alert, "window", .{}), "setInitialFirstResponder:", .{f});

    const P = Pending(Ctx);
    const pending = std.heap.c_allocator.create(P) catch return objc.release(alert);
    pending.* = .{ .alert = alert, .field = field, .box = box, .ctx = ctx, .func = &func };
    const w = window orelse return pending.finish(objc.msg(objc.NSInteger, alert, "runModal", .{}));
    var block = objc.Block(P, &.{objc.NSInteger}).init(pending, P.finish);
    objc.msg(void, alert, "beginSheetModalForWindow:completionHandler:", .{ w, &block });
}

/// Any alert or panel (`NSAlert`, `NSOpenPanel`) as a sheet on `window`,
/// or modal with none; `func` hears the response. `ctx` must live until
/// then. Used by the page's questions (`web/dialogs.zig`).
pub fn beginSheet(sheet: objc.Object, window: ?objc.Object, ctx: anytype, comptime func: fn (@TypeOf(ctx), objc.NSInteger) void) void {
    const Ctx = std.meta.Child(@TypeOf(ctx));
    const w = window orelse return func(ctx, objc.msg(objc.NSInteger, sheet, "runModal", .{}));
    var block = objc.Block(Ctx, &.{objc.NSInteger}).init(ctx, func);
    objc.msg(void, sheet, "beginSheetModalForWindow:completionHandler:", .{ w, &block });
}

/// `Ask.folder`: a folder chosen in an open panel sheet on `window`;
/// `func` gets its path, or null when cancelled.
pub fn askFolder(window: objc.Object, prompt: []const u8, message: []const u8, ctx: anytype, comptime func: fn (@TypeOf(ctx), ?[]const u8) void) void {
    const Ctx = std.meta.Child(@TypeOf(ctx));
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.retain(objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{}));
    objc.msg(void, panel, "setCanChooseDirectories:", .{objc.YES});
    objc.msg(void, panel, "setCanChooseFiles:", .{objc.NO});
    objc.msg(void, panel, "setCanCreateDirectories:", .{objc.YES});
    objc.msg(void, panel, "setPrompt:", .{objc.nsString(prompt)});
    objc.msg(void, panel, "setMessage:", .{objc.nsString(message)});
    const P = struct {
        panel: objc.Object,
        ctx: *Ctx,
        fn finish(self: *@This(), response: objc.NSInteger) void {
            const p2 = objc.Pool.push();
            defer p2.pop();
            const url = if (response == 1) objc.msg(?objc.Object, self.panel, "URL", .{}) else null;
            func(self.ctx, if (url) |u| objc.fromNSString(objc.msg(objc.Object, u, "path", .{})) else null);
            objc.release(self.panel);
            std.heap.c_allocator.destroy(self);
        }
    };
    const pending = std.heap.c_allocator.create(P) catch return objc.release(panel);
    pending.* = .{ .panel = panel, .ctx = ctx };
    var block = objc.Block(P, &.{objc.NSInteger}).init(pending, P.finish);
    objc.msg(void, panel, "beginSheetModalForWindow:completionHandler:", .{ window, &block });
}
