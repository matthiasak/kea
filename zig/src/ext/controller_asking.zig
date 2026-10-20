//! Asking (Extensions.swift 1138-1203): one question at a time, as a sheet
//! on the browser's window — a modal alert would stop every page and
//! extension while it waits. In a test run `answer_for_tests` answers.
const std = @import("std");
const objc = @import("nanoui").objc;
const Extensions = @import("controller.zig").Extensions;
const app_name = @import("../app/kea.zig").app_name;
const appkit = @import("../sys/appkit.zig");
const json = @import("../data/json.zig");

pub const Callback = *const fn (ctx: *anyopaque, yes: bool) void;

/// A question waiting its turn (Swift's `question` task chain).
pub const Pending = struct {
    owner: *Extensions,
    title: []u8,
    detail: []u8,
    icon: ?objc.Object,
    yes: []const u8,
    no: []const u8,
    ctx: *anyopaque,
    cb: Callback,
    alert: ?objc.Object = null,

    /// Freed without an answer (the controller going away).
    pub fn drop(p: *Pending) void {
        const gpa = p.owner.gpa;
        if (p.icon) |i| objc.release(i);
        if (p.alert) |a| objc.release(a);
        gpa.free(p.title);
        gpa.free(p.detail);
        gpa.destroy(p);
    }

    fn finish(p: *Pending, response: objc.NSInteger) void {
        const owner = p.owner;
        const yes = response == 1000; // NSAlertFirstButtonReturn
        const ctx = p.ctx;
        const cb = p.cb;
        // Still at the front while `cb` runs, so a question it asks waits.
        cb(ctx, yes);
        _ = owner.del.questions.orderedRemove(0);
        p.drop();
        next(owner);
    }
};

/// `ask(install:wants:icon:)`.
pub fn askInstall(self: *Extensions, name: []const u8, wants: []const []const u8, icon: ?objc.Object, ctx: *anyopaque, cb: Callback) void {
    const gpa = self.gpa;
    const title = std.fmt.allocPrint(gpa, "Add “{s}” to " ++ app_name ++ "?", .{name}) catch return cb(ctx, false);
    defer gpa.free(title);
    const joined = std.mem.join(gpa, "\n• ", wants) catch return cb(ctx, false);
    defer gpa.free(joined);
    const detail = if (wants.len == 0)
        gpa.dupe(u8, "It doesn't ask for anything special.") catch return cb(ctx, false)
    else
        std.mem.concat(gpa, u8, &.{ "It will be able to:\n• ", joined }) catch return cb(ctx, false);
    defer gpa.free(detail);
    put(self, title, detail, icon, "Add Extension", "Cancel", ctx, cb);
}

/// `ask(more:context:)`: permissions.request for an API Kea answers.
pub fn askMore(self: *Extensions, names: []const u8, context: objc.Object, ctx: *anyopaque, cb: Callback) void {
    ask(self, "asks for more access", names, context, ctx, cb);
}

/// `ask(capture:)`: recording the screen, asked once, naming the extension.
pub fn askCapture(self: *Extensions, context: objc.Object, ctx: *anyopaque, cb: Callback) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const name = displayName(context);
    const title = std.fmt.allocPrint(self.gpa, "“{s}” wants to record your screen or a window.", .{name}) catch return cb(ctx, false);
    defer self.gpa.free(title);
    const detail = std.fmt.allocPrint(self.gpa, "macOS will ask what to share. " ++ app_name ++ " remembers your answer for {s}; Settings › Extensions takes it back.", .{name}) catch return cb(ctx, false);
    defer self.gpa.free(detail);
    put(self, title, detail, icon64(context), "Continue", "Don't Allow", ctx, cb);
}

/// `ask(_:detail:context:)`: "<name> <question>", Allow / Don't Allow.
pub fn ask(self: *Extensions, question: []const u8, detail: []const u8, context: objc.Object, ctx: *anyopaque, cb: Callback) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const title = std.fmt.allocPrint(self.gpa, "{s} {s}", .{ displayName(context), question }) catch return cb(ctx, false);
    defer self.gpa.free(title);
    put(self, title, detail, icon64(context), "Allow", "Don't Allow", ctx, cb);
}

/// `displayName ?? "An extension"` (valid inside the caller's pool).
pub fn displayName(context: objc.Object) []const u8 {
    const found = objc.msg(objc.Object, context, "webExtension", .{});
    const n = objc.msg(?objc.Object, found, "displayName", .{}) orelse return "An extension";
    return objc.fromNSString(n);
}

fn icon64(context: objc.Object) ?objc.Object {
    const found = objc.msg(objc.Object, context, "webExtension", .{});
    return objc.msg(?objc.Object, found, "iconForSize:", .{objc.CGSize{ .width = 64, .height = 64 }});
}

pub fn put(self: *Extensions, title: []const u8, detail: []const u8, icon: ?objc.Object, yes: []const u8, no: []const u8, ctx: *anyopaque, cb: Callback) void {
    const gpa = self.gpa;
    const p = gpa.create(Pending) catch return cb(ctx, false);
    const t = gpa.dupe(u8, title) catch {
        gpa.destroy(p);
        return cb(ctx, false);
    };
    const dt = gpa.dupe(u8, detail) catch {
        gpa.free(t);
        gpa.destroy(p);
        return cb(ctx, false);
    };
    p.* = .{
        .owner = self,
        .title = t,
        .detail = dt,
        .icon = if (icon) |i| objc.retain(i) else null,
        .yes = yes,
        .no = no,
        .ctx = ctx,
        .cb = cb,
    };
    self.del.questions.append(gpa, p) catch {
        p.drop();
        return cb(ctx, false);
    };
    if (self.del.questions.items.len == 1) next(self);
}

/// Asks the question at the front, if any.
fn next(self: *Extensions) void {
    const p = if (self.del.questions.items.len > 0) self.del.questions.items[0] else return;
    if (self.gpa.dupe(u8, p.title)) |t| self.del.asked.append(self.gpa, t) catch self.gpa.free(t) else |_| {}
    if (self.kea.opts.root != null) if (self.del.answer_for_tests) |a| return p.finish(if (a) 1000 else 1001);
    const pool = objc.Pool.push();
    defer pool.pop();
    const alert = objc.new("NSAlert");
    p.alert = alert;
    objc.msg(void, alert, "setMessageText:", .{objc.nsString(p.title)});
    objc.msg(void, alert, "setInformativeText:", .{objc.nsString(p.detail)});
    if (p.icon) |i| objc.msg(void, alert, "setIcon:", .{i});
    _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString(p.yes)});
    _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString(p.no)});
    appkit.beginSheet(alert, sheetWindow(), p, Pending.finish);
}

/// `NSApp.mainWindow ?? first visible window that can become main`.
fn sheetWindow() ?objc.Object {
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    if (objc.msg(?objc.Object, app, "mainWindow", .{})) |w| return w;
    const windows = objc.msg(objc.Object, app, "windows", .{});
    const n = objc.msg(objc.NSUInteger, windows, "count", .{});
    for (0..n) |i| {
        const w = objc.msg(objc.Object, windows, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (objc.msg(objc.BOOL, w, "isVisible", .{}) and objc.msg(objc.BOOL, w, "canBecomeMainWindow", .{})) return w;
    }
    return null;
}

// MARK: when it was last used (Extensions.swift 1240-1280)

/// `justUsed`: its button, menu line, or a click or key in one of its
/// pages within the last five seconds — Chrome's "user gesture".
pub fn justUsed(self: *Extensions, id: []const u8) bool {
    const latest = @max(self.del.clicked.get(id) orelse -std.math.inf(f64), self.del.touched.get(id) orelse -std.math.inf(f64));
    return json.now() - latest < 5;
}

/// `Extensions.pressed[id]` less than `seconds` ago (ExtensionCapture).
pub fn pressedWithin(self: *Extensions, id: []const u8, seconds: i64) bool {
    const at = self.del.pressed.get(id) orelse return false;
    return json.now() - at < @as(f64, @floatFromInt(seconds));
}

/// permissions.request uses up a click (`clicked`) within `within_s`.
pub fn takeClick(self: *Extensions, id: []const u8, within_s: f64) bool {
    const i = self.del.clicked.getIndex(id) orelse return false;
    const recent = json.now() - self.del.clicked.values()[i] < within_s;
    const key = self.del.clicked.keys()[i];
    self.del.clicked.swapRemoveAt(i);
    self.gpa.free(key);
    return recent;
}
