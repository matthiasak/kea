//! The questions a page may ask, and the answers it gets (Dialogs.swift):
//! alert, confirm and prompt as the system's own sheets titled with the
//! asking site, a file to choose, a name and password, a certificate this
//! Mac doesn't trust, another app to open. A tab behind yours holds its
//! question until it is in front (`ask`); a page of the pair on screen asks
//! over its own pane (the card in `chrome/page_layers.zig`). Hidden runs
//! (`Options.hidden`) never show a sheet: the question waits on the tab
//! for `Tab.answerQuestion`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Tab = @import("tab.zig").Tab;
const registrable = @import("../data/registrable.zig");
const appkit = @import("../sys/appkit.zig");

/// Questions outlive the tab that asked (a sheet still up), so they are
/// not on its allocator.
const gpa = std.heap.c_allocator;

pub const Kind = enum { alert, confirm, prompt, open_panel, sign_in, trust, hand_off };

/// One question, answered exactly once (`HeldQuestion`, `PaneQuestion`).
pub const Ask = struct {
    kind: Kind,
    serial: u64,
    /// The site asking (the frame's own origin), and what it says.
    host: []u8,
    message: []u8,
    /// A prompt's typing (its default text to begin with).
    input: ui.TextBuffer = .{},
    /// WebKit's completion handler, copied.
    completion: ?objc.Object = null,
    /// What the answer needs: the challenge, the panel's parameters, the
    /// address to hand off. Retained.
    subject: ?objc.Object = null,
    /// The sheet while it is up, and its fields.
    alert: ?objc.Object = null,
    fields: [2]?objc.Object = .{ null, null },
    sheet_up: bool = false,
    answered: bool = false,
    /// Shown over its own pane (`PaneQuestion`).
    pane: bool = false,
};

extern "c" fn _Block_copy(block: ?*const anyopaque) ?objc.Object;
extern "c" fn _Block_release(block: objc.Object) void;
extern "c" fn SecTrustEvaluateWithError(trust: *anyopaque, err: ?*?*anyopaque) bool;

/// Calls a block WebKit or AppKit handed over with `args`.
pub fn call(block: *const anyopaque, args: anytype) void {
    const types = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const params = comptime blk: {
        var p: [types.len + 1]type = undefined;
        p[0] = *const anyopaque;
        for (types, 1..) |ty, i| p[i] = ty;
        break :blk p;
    };
    const F = @Fn(&params, &@splat(.{}), void, .{ .@"callconv" = .c });
    const raw: [*]const *const anyopaque = @ptrCast(@alignCast(block));
    const f: *const F = @ptrCast(@alignCast(raw[2]));
    @call(.auto, f, .{block} ++ args);
}

/// A question for `t`, its completion copied. `host`: the frame's origin.
pub fn make(t: *Tab, kind: Kind, host: []const u8, message: []const u8, completion: ?*const anyopaque) ?*Ask {
    const a = gpa.create(Ask) catch return null;
    const h = gpa.dupe(u8, host) catch {
        gpa.destroy(a);
        return null;
    };
    const m = gpa.dupe(u8, message) catch {
        gpa.free(h);
        gpa.destroy(a);
        return null;
    };
    a.* = .{ .kind = kind, .serial = t.serial, .host = h, .message = m, .completion = if (completion) |c| _Block_copy(c) else null };
    return a;
}

/// `ask(from:show:drop:)`: over its own page only. A tab in the
/// background — or in another space — waits until you go to it.
pub fn ask(t: *Tab, a: *Ask) void {
    const b = t.browser orelse return present(t, a);
    var known = b.indexOf(t) != null;
    for (b.parked.values()) |row| for (row.tabs.items) |p| {
        if (p == t) known = true;
    };
    if (b.active_id == t.id or !known) return present(t, a);
    t.held.append(t.gpa, a) catch answer(a, false, null);
}

/// The tab has come in front: what it held is asked now
/// (`activeID.didSet`, a turn later).
pub fn presentHeld(t: *Tab) void {
    if (t.held.items.len == 0) return;
    t.after(0, presentLater, 0);
}

fn presentLater(t: *Tab, _: usize) void {
    const held = t.held.toOwnedSlice(t.gpa) catch return;
    defer t.gpa.free(held);
    for (held) |a| present(t, a);
}

fn present(t: *Tab, a: *Ask) void {
    if (a.pane or t.kea.opts.hidden) {
        t.questions.append(t.gpa, a) catch return answer(a, false, null);
        return t.changed(.state);
    }
    sheet(t, a);
}

/// Everything `t` asked, answered as dismissed: it closed or went away.
pub fn dropAll(t: *Tab) void {
    while (t.held.pop()) |a| answer(a, false, null);
    while (t.questions.items.len > 0) answer(t.questions.items[0], false, null);
}

fn removeFrom(list: *std.ArrayList(*Ask), a: *Ask) void {
    for (list.items, 0..) |x, i| if (x == a) {
        _ = list.orderedRemove(i);
        return;
    };
}

/// `NSURLSessionAuthChallengeDisposition`.
const use_credential: objc.NSInteger = 0;
const default_handling: objc.NSInteger = 1;
const cancel_challenge: objc.NSInteger = 2;

/// The answer, given once; `text` overrides what was typed.
pub fn answer(a: *Ask, ok: bool, text: ?[]const u8) void {
    if (a.answered) return;
    a.answered = true;
    const t = Tab.alive(a.serial);
    if (t) |tab| {
        removeFrom(&tab.questions, a);
        removeFrom(&tab.held, a);
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    if (a.completion) |blk| {
        switch (a.kind) {
            .alert => call(blk, .{}),
            .confirm => call(blk, .{ok}),
            .prompt => call(blk, .{if (ok) objc.nsString(text orelse typed(a)) else @as(?objc.Object, null)}),
            .open_panel => call(blk, .{if (ok and a.alert != null) objc.msg(?objc.Object, a.alert.?, "URLs", .{}) else @as(?objc.Object, null)}),
            .sign_in => if (ok) call(blk, .{ use_credential, signInCredential(a) }) else call(blk, .{ cancel_challenge, @as(?objc.Object, null) }),
            .trust => if (ok) {
                excuse(a.host);
                call(blk, .{ use_credential, trustCredential(a.subject.?) });
            } else call(blk, .{ cancel_challenge, @as(?objc.Object, null) }),
            .hand_off => {},
        }
    }
    if (a.kind == .hand_off and ok) if (a.subject) |u| {
        _ = objc.msg(objc.BOOL, objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{u});
    };
    if (t) |tab| tab.changed(.state);
    if (!a.sheet_up) free(a);
}

fn typed(a: *Ask) []const u8 {
    if (a.fields[0]) |f| return objc.fromNSString(objc.msg(?objc.Object, f, "stringValue", .{}));
    return a.input.text();
}

fn free(a: *Ask) void {
    if (a.completion) |c| _Block_release(c);
    if (a.subject) |s| objc.release(s);
    if (a.alert) |al| objc.release(al);
    for (a.fields) |f| if (f) |o| objc.release(o);
    a.input.deinit();
    gpa.free(a.host);
    gpa.free(a.message);
    gpa.destroy(a);
}

fn signInCredential(a: *Ask) ?objc.Object {
    const name = objc.fromNSString(objc.msg(?objc.Object, a.fields[0] orelse return null, "stringValue", .{}));
    const pass = objc.fromNSString(objc.msg(?objc.Object, a.fields[1] orelse return null, "stringValue", .{}));
    // NSURLCredentialPersistenceForSession = 1.
    return objc.msg(objc.Object, objc.class("NSURLCredential"), "credentialWithUser:password:persistence:", .{ objc.nsString(name), objc.nsString(pass), @as(objc.NSUInteger, 1) });
}

fn serverTrust(challenge: objc.Object) ?*anyopaque {
    return @ptrCast(objc.msg(?objc.Object, objc.msg(objc.Object, challenge, "protectionSpace", .{}), "serverTrust", .{}));
}

fn trustCredential(challenge: objc.Object) ?objc.Object {
    const trust = serverTrust(challenge) orelse return null;
    return objc.msg(objc.Object, objc.class("NSURLCredential"), "credentialForTrust:", .{trust});
}

// MARK: certificates

/// `Dialogs.excused`: sites with bad certificates accepted, this launch.
var excused: std.StringHashMapUnmanaged(void) = .empty;

fn excuse(host: []const u8) void {
    if (excused.contains(host)) return;
    const copy = std.heap.c_allocator.dupe(u8, host) catch return;
    excused.put(std.heap.c_allocator, copy, {}) catch std.heap.c_allocator.free(copy);
}

pub fn isExcused(host: []const u8) bool {
    return excused.contains(host);
}

/// `Dialogs.isLoopback`: localhost and the loopback addresses written as
/// addresses — 127.0.0.1.example.com is a website like any other.
pub fn isLoopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "[::1]")) return true;
    var parts = std.mem.splitScalar(u8, host, '.');
    var n: usize = 0;
    var first = true;
    while (parts.next()) |p| : (n += 1) {
        _ = std.fmt.parseInt(u8, p, 10) catch return false;
        if (p.len == 0) return false;
        if (first and !std.mem.eql(u8, p, "127")) return false;
        first = false;
    }
    return n == 4;
}

/// Whether the system trusts the certificate as it is.
pub fn trusted(challenge: objc.Object) bool {
    const trust = serverTrust(challenge) orelse return true;
    return SecTrustEvaluateWithError(trust, null);
}

// MARK: the sheets

/// `Dialogs.window(for:)`.
fn windowFor(t: *Tab) ?objc.Object {
    if (t.web) |wv| if (objc.msg(?objc.Object, wv, "window", .{})) |w| return w;
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    if (objc.msg(?objc.Object, app, "mainWindow", .{})) |w| return w;
    if (t.browser) |b| if (b.window) |w| return w.nswindow;
    return null;
}

fn sheetEnded(a: *Ask, response: objc.NSInteger) void {
    a.sheet_up = false;
    // NSAlertFirstButtonReturn 1000, second 1001; NSModalResponseOK 1.
    const ok = switch (a.kind) {
        .open_panel => response == 1,
        .trust => response == 1001,
        else => response == 1000,
    };
    if (a.answered) return free(a);
    answer(a, ok, null);
}

fn newAlert(title: []const u8, info: []const u8, style: objc.NSUInteger, buttons: []const []const u8) objc.Object {
    const alert = objc.new("NSAlert");
    objc.msg(void, alert, "setMessageText:", .{objc.nsString(title)});
    objc.msg(void, alert, "setInformativeText:", .{objc.nsString(info)});
    objc.msg(void, alert, "setAlertStyle:", .{style});
    for (buttons) |label| _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString(label)});
    return alert;
}

fn field(secure: bool, y: f64, placeholder: []const u8, value: []const u8) objc.Object {
    const rect: objc.CGRect = .{ .origin = .{ .y = y }, .size = .{ .width = 260, .height = 24 } };
    const raw = if (secure) objc.alloc("NSSecureTextField") else objc.alloc("NSTextField");
    const f = objc.msg(objc.Object, raw, "initWithFrame:", .{rect});
    objc.msg(void, f, "setStringValue:", .{objc.nsString(value)});
    if (placeholder.len > 0) objc.msg(void, f, "setPlaceholderString:", .{objc.nsString(placeholder)});
    return f;
}

fn sheet(t: *Tab, a: *Ask) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    var buf: [512]u8 = undefined;
    // NSAlertStyleWarning 0, Informational 1.
    const page_title = if (a.host.len == 0) "This page says" else a.host;
    a.alert = switch (a.kind) {
        .alert => newAlert(page_title, a.message, 1, &.{"OK"}),
        .confirm, .prompt => newAlert(page_title, a.message, 1, &.{ "OK", "Cancel" }),
        .hand_off => newAlert(
            std.fmt.bufPrint(&buf, "Open \u{201C}{s}\u{201D}?", .{a.message}) catch "Open?",
            std.fmt.bufPrint(buf[256..], "{s} wants to open {s}.", .{ if (a.host.len == 0) "This page" else a.host, a.message }) catch "",
            1,
            &.{ "Open", "Cancel" },
        ),
        .trust => newAlert(
            std.fmt.bufPrint(&buf, "{s} can't prove who it is", .{a.host}) catch "This site can't prove who it is",
            "Its certificate isn't trusted by this Mac. Someone could be reading what you send. Continue only if you know why it looks like this.",
            0,
            &.{ "Go Back", "Continue Anyway" },
        ),
        .sign_in => newAlert(std.fmt.bufPrint(&buf, "{s} asks you to sign in", .{a.host}) catch "Sign in", a.message, 1, &.{ "Sign In", "Cancel" }),
        .open_panel => openPanel(a),
    };
    const alert = a.alert.?;
    if (a.kind == .prompt) {
        const f = field(false, 0, "", a.input.text());
        a.fields[0] = f;
        objc.msg(void, alert, "setAccessoryView:", .{f});
        objc.msg(void, objc.msg(objc.Object, alert, "window", .{}), "setInitialFirstResponder:", .{f});
    } else if (a.kind == .sign_in) {
        const box = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{ .size = .{ .width = 260, .height = 56 } }});
        defer objc.release(box);
        const name = field(false, 32, "Name", "");
        const pass = field(true, 0, "Password", "");
        objc.msg(void, name, "setNextKeyView:", .{pass});
        objc.msg(void, box, "addSubview:", .{name});
        objc.msg(void, box, "addSubview:", .{pass});
        a.fields = .{ name, pass };
        objc.msg(void, alert, "setAccessoryView:", .{box});
        objc.msg(void, objc.msg(objc.Object, alert, "window", .{}), "setInitialFirstResponder:", .{name});
    }
    a.sheet_up = true;
    appkit.beginSheet(alert, windowFor(t), a, sheetEnded);
}

fn openPanel(a: *Ask) objc.Object {
    const panel = objc.retain(objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{}));
    const params = a.subject.?;
    objc.msg(void, panel, "setCanChooseFiles:", .{objc.YES});
    objc.msg(void, panel, "setCanChooseDirectories:", .{objc.msg(objc.BOOL, params, "allowsDirectories", .{})});
    objc.msg(void, panel, "setAllowsMultipleSelection:", .{objc.msg(objc.BOOL, params, "allowsMultipleSelection", .{})});
    objc.msg(void, panel, "setResolvesAliases:", .{objc.YES});
    var buf: [300]u8 = undefined;
    const msg = if (a.host.len == 0) "Choose a file for this page" else std.fmt.bufPrint(&buf, "Choose a file for {s}", .{a.host}) catch "Choose a file for this page";
    objc.msg(void, panel, "setMessage:", .{objc.nsString(msg)});
    return panel;
}

/// The same registrable domain (`Vault.registrable`), for handing off.
pub fn sameSite(a: []const u8, b: []const u8) bool {
    const ra = registrable.registrable(gpa, a) catch return false;
    defer gpa.free(ra);
    const rb = registrable.registrable(gpa, b) catch return false;
    defer gpa.free(rb);
    return std.mem.eql(u8, ra, rb);
}

test "loopback is this Mac only" {
    const t = std.testing;
    try t.expect(isLoopback("localhost"));
    try t.expect(isLoopback("127.0.0.1"));
    try t.expect(isLoopback("[::1]"));
    try t.expect(!isLoopback("127.0.0.1.example.com"));
    try t.expect(!isLoopback("10.0.0.1"));
    try t.expect(!isLoopback("127.0.0"));
}
