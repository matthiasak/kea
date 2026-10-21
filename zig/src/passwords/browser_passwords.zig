//! A window's passwords (Browser.swift 624-887, "passwords"): the offer to
//! keep what a page just sent (`offering`, the `keepAsking` bar), the
//! accounts hanging from the sign-in box (`accounts`, Accounts.swift), and
//! the list the Passwords panel shows (`saved`, `hunting`, `managing`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const json = @import("../data/json.zig");
const vault = @import("vault.zig");
const Vault = vault.Vault;
const Kept = vault.Kept;
const forms = @import("forms.zig");
const Accounts = @import("accounts_model.zig").Accounts;
const Uuid = json.Uuid;

pub const State = struct {
    /// A name and password a page just sent, until you answer.
    offering: ?forms.Offer = null,
    accounts: Accounts,
    /// The list, without secrets (`Vault.all()`), on `gpa`.
    saved: []Kept = &.{},
    hunting: ui.TextBuffer = .{},
    panel: @import("passwords_panel.zig").State = .{},

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.offering) |o| o.deinit(gpa);
        s.offering = null;
        s.accounts.deinit();
        vault.freeKept(gpa, s.saved);
        s.saved = &.{};
        s.hunting.deinit();
        s.panel.deinit(gpa);
    }
};

fn unixNow() f64 {
    return json.toUnix(json.now());
}

/// The offer to put up, in place of any before it.
pub fn offer(b: *Browser, o: forms.Offer) void {
    if (b.passwords.offering) |old| old.deinit(b.gpa);
    b.passwords.offering = o;
    b.redraw();
}

/// `keepOffer`: into the keychain, used now.
pub fn keepOffer(b: *Browser) void {
    const o = b.passwords.offering orelse return;
    b.passwords.offering = null;
    defer o.deinit(b.gpa);
    const said = forms.keep(Vault.of(b.kea), o, unixNow()) catch return;
    defer b.gpa.free(said);
    if (!std.mem.startsWith(u8, said, "The keychain")) relist(b);
    b.announce(said);
}

pub fn dropOffer(b: *Browser) void {
    if (b.passwords.offering) |o| o.deinit(b.gpa);
    b.passwords.offering = null;
    b.redraw();
}

/// `neverOffer`: never for this site.
pub fn neverOffer(b: *Browser) void {
    const o = b.passwords.offering orelse return;
    b.passwords.offering = null;
    defer o.deinit(b.gpa);
    const said = forms.neverFor(Vault.of(b.kea), o) catch return;
    defer b.gpa.free(said);
    b.announce(said);
}

/// `dropChoice`: the account list taken down.
pub fn dropChoice(b: *Browser) void {
    b.passwords.accounts.dropChoice();
    b.redraw();
}

pub fn step(b: *Browser, dir: i2) void {
    const a = &b.passwords.accounts;
    const s = if (a.suggesting) |*x| x else return;
    const count: i64 = @intCast(s.passkeys.len + s.logins.len);
    if (count == 0) return;
    s.shown = 0;
    if (a.selected) |here| {
        const next = @as(i64, @intCast(here)) + dir;
        a.selected = if (next < 0 or next >= count) null else @intCast(next);
    } else {
        a.selected = if (dir > 0) 0 else @intCast(count - 1);
    }
    b.redraw();
}

pub fn takeSelected(b: *Browser) bool {
    const a = &b.passwords.accounts;
    const s = a.suggesting orelse return false;
    const sel = a.selected orelse return false;
    const pk_len = s.passkeys.len;
    if (sel < pk_len) {
        @import("form_relay.zig").pick(b, sel, true);
        return true;
    }
    if (sel - pk_len < s.logins.len) {
        @import("form_relay.zig").pick(b, sel - pk_len, false);
        return true;
    }
    return false;
}

// MARK: the list of what is kept

/// `relist()`: read again from the keychain, without secrets.
pub fn relist(b: *Browser) void {
    const fresh = Vault.of(b.kea).all() catch return;
    vault.freeKept(b.gpa, b.passwords.saved);
    b.passwords.saved = fresh;
    b.redraw();
}

/// `keep(host:user:password:)`: typed in by hand.
pub fn keepTyped(b: *Browser, host: []const u8, user: []const u8, password: []const u8) void {
    if (!Vault.of(b.kea).save(host, user, password, null, false)) return b.announce("The keychain refused it");
    relist(b);
    const said = std.fmt.allocPrint(b.gpa, "Kept for {s}", .{host}) catch return;
    defer b.gpa.free(said);
    b.announce(said);
}

pub fn forget(b: *Browser, login: Kept) void {
    Vault.of(b.kea).forget(login.host, login.user);
    relist(b);
}

pub const SiteRow = struct { host: []const u8, logins: []const Kept };

/// `shownSites`: grouped by site, filtered by what has been typed; on
/// `arena` (rows borrow `saved`, which `Vault.all` sorts by host then user).
pub fn shownSites(b: *Browser, arena: std.mem.Allocator) ![]SiteRow {
    const needle = try std.ascii.allocLowerString(arena, std.mem.trim(u8, b.passwords.hunting.text(), " "));
    var picked: std.ArrayList(Kept) = .empty;
    for (b.passwords.saved) |k| {
        if (needle.len > 0) {
            const user = try std.ascii.allocLowerString(arena, k.user);
            if (std.mem.indexOf(u8, k.host, needle) == null and std.mem.indexOf(u8, user, needle) == null) continue;
        }
        try picked.append(arena, k);
    }
    var rows: std.ArrayList(SiteRow) = .empty;
    var i: usize = 0;
    while (i < picked.items.len) {
        var j = i + 1;
        while (j < picked.items.len and std.mem.eql(u8, picked.items[j].host, picked.items[i].host)) j += 1;
        try rows.append(arena, .{ .host = picked.items[i].host, .logins = picked.items[i..j] });
        i = j;
    }
    return rows.items;
}

// MARK: copying one

const Copying = struct { kea: *Kea, record: Uuid, host: []u8, user: []u8 };

/// `copy(_:)`: asked for the way one shown is, then on this Mac's
/// clipboard only, concealed and transient, taken off after 90 s unless
/// something else was copied since.
pub fn copy(b: *Browser, login: Kept) void {
    const gpa = std.heap.c_allocator;
    const host = gpa.dupe(u8, login.host) catch return;
    const user = gpa.dupe(u8, login.user) catch return gpa.free(host);
    const c = gpa.create(Copying) catch {
        gpa.free(host);
        return gpa.free(user);
    };
    c.* = .{ .kea = b.kea, .record = b.record_id, .host = host, .user = user };
    const reason = std.fmt.allocPrint(b.gpa, "copy the password for {s}", .{login.host}) catch return copied(c, false);
    defer b.gpa.free(reason);
    Vault.of(b.kea).prove(reason, c, copiedAny);
}

fn copiedAny(ctx: *anyopaque, ok: bool) void {
    copied(@ptrCast(@alignCast(ctx)), ok);
}

fn copied(c: *Copying, ok: bool) void {
    const gpa = std.heap.c_allocator;
    defer {
        gpa.free(c.host);
        gpa.free(c.user);
        gpa.destroy(c);
    }
    if (!ok) return;
    const b = for (c.kea.browsers.items) |x| {
        if (x.record_id.eql(c.record)) break x;
    } else return;
    const secret = Vault.of(c.kea).secretOf(.{ .host = c.host, .user = c.user }) orelse return b.announce("The keychain refused it");
    defer {
        std.crypto.secureZero(u8, secret);
        c.kea.gpa.free(secret);
    }
    toClipboard(secret);
    b.announce("Password copied");
}

var clipboard_count: objc.NSInteger = 0;

fn toClipboard(secret: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const board = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    // NSPasteboardContentsCurrentHostOnly
    _ = objc.msg(objc.NSInteger, board, "prepareForNewContentsWithOptions:", .{@as(objc.NSUInteger, 1)});
    _ = objc.msg(objc.BOOL, board, "setString:forType:", .{ objc.nsString(secret), objc.nsString("public.utf8-plain-text") });
    const empty = objc.msg(objc.Object, objc.class("NSData"), "data", .{});
    for ([_][]const u8{ "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType" }) |kind|
        _ = objc.msg(objc.BOOL, board, "setData:forType:", .{ empty, objc.nsString(kind) });
    clipboard_count = objc.msg(objc.NSInteger, board, "changeCount", .{});
    objc.dispatchAfter(90 * std.time.ns_per_s, null, clearClipboard);
}

fn clearClipboard(_: ?*anyopaque) callconv(.c) void {
    const board = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    if (objc.msg(objc.NSInteger, board, "changeCount", .{}) == clipboard_count)
        _ = objc.msg(objc.NSInteger, board, "clearContents", .{});
}
