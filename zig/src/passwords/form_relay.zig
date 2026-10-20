//! What a tab's sign-in forms say (`FormRelay`, Tab.swift 829-948) and what
//! the window does with it (Browser.swift 699-803, 3806-3832): the accounts
//! hung from the box the caret is in, a sent password settled into an offer,
//! a pick filled in, and the page asked whether it holds unsaved entries.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Tab = @import("../web/tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const json = @import("../data/json.zig");
const url = @import("../data/url.zig");
const Vault = @import("vault.zig").Vault;
const forms = @import("forms.zig");
const accounts_model = @import("accounts_model.zig");
const ops = @import("browser_passwords.zig");
const appkit = @import("../sys/appkit.zig");
const Uuid = json.Uuid;

fn unixNow() f64 {
    return json.toUnix(json.now());
}

/// `pageAddress`: the page on screen, else where it is going.
pub fn pageAddress(t: *const Tab) ?[]const u8 {
    return t.committed orelse t.address;
}

/// `keaForms`' message, from the tab's delegate.
pub fn received(t: *Tab, body: objc.Object) void {
    const m = forms.message(body) orelse return;
    const now = unixNow();
    switch (m) {
        // `onSignIn`: no window listens.
        .form => {},
        .submit => |s| t.sign_in.sentSignIn(t.gpa, pageAddress(t), s.user, s.password, now),
        .name => |user| t.sign_in.gaveName(t.gpa, pageAddress(t), user, now),
        .settled => settle(t, false),
        .focus => |f| {
            // Set only when it changes (Swift: a published value redraws).
            if (t.typing != f.typing) t.typing = f.typing;
            hang(t, if (f.rect) |r| forms.spot(r, t.zoom) else null, f.passwords, f.name);
        },
        // The stage lays a pair out round it (`PaneStage.immersed`).
        .fullscreen => |on| if (t.immersed != on) {
            t.immersed = on;
            if (t.browser) |b| b.redraw();
        },
    }
}

/// `hang(from:)`: the window's list for the box at `spot` (null: it left).
pub fn hang(t: *Tab, spot: ?forms.Rect, passwords: bool, name: bool) void {
    const b = t.browser orelse return;
    const page = pageAddress(t);
    const token = b.passwords.accounts.hang(Vault.of(t.kea), .{
        .tab = t.id,
        .active = b.active_id == t.id,
        .page = page,
        .spot = spot,
        .passwords = passwords,
        .name = name,
        .fills = t.kea.prefs.fills_passwords,
        .given = t.sign_in.givenName(t.gpa, page, unixNow()),
        .passkeys = t.kea.passkeys.offered(t.web),
        .now = unixNow(),
    }) catch null;
    if (token) |tk| t.after(accounts_model.lowering_delay, lowered, @intCast(tk));
    b.redraw();
}

fn lowered(t: *Tab, token: usize) void {
    const b = t.browser orelse return;
    b.passwords.accounts.lowered(t.id, token);
    b.redraw();
}

/// `Passkeys.offeredChanged`: a page's passkeys arrived or went while the
/// caret is in its box; the list hangs again.
pub fn passkeysOffered(ctx: *anyopaque, web: objc.Object) void {
    const kea: *Kea = @ptrCast(@alignCast(ctx));
    for (kea.browsers.items) |b| for (b.tabs.items) |t| if (t.web == web) {
        const f = b.passwords.accounts.passkeysChanged(t.id) orelse return;
        return hang(t, f.spot, f.passwords, f.name);
    };
}

/// `prefs.$passkeys`: every tab's next page armed with the passkeys' script
/// or without it, keeping what each hides.
pub fn passkeysChanged(kea: *Kea) void {
    const curtain_js = @import("../web/curtain_js.zig");
    for (kea.browsers.items) |b| {
        const parked = b.parkedTabs(b.gpa) catch continue;
        defer b.gpa.free(parked);
        for ([_][]const *Tab{ b.tabs.items, parked }) |list| for (list) |t| curtain_js.armFor(t, t.url());
    }
}

// MARK: a sent sign-in, settled

/// `settleSignIn(navigated:)`.
pub fn settle(t: *Tab, navigated: bool) void {
    act(t, t.sign_in.settle(t.gpa, unixNow(), navigated));
}

fn act(t: *Tab, s: forms.SignIn.Settle) void {
    switch (s) {
        .nothing => {},
        .later => |stamp| t.after(1.5, settleLater, @bitCast(stamp)),
        .ask => t.evaluate(forms.has_password_script, .kea, asked, 0),
    }
}

fn settleLater(t: *Tab, stamp: usize) void {
    act(t, t.sign_in.settleLater(t.gpa, unixNow(), @bitCast(stamp)));
}

fn truthy(value: ?objc.Object) bool {
    const v = value orelse return false;
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSNumber")})) return false;
    return objc.msg(objc.BOOL, v, "boolValue", .{});
}

/// The box still there is a refused sign-in; gone, it took: `onCredentials`.
fn asked(t: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const sent = t.sign_in.answered(t.gpa, truthy(value)) orelse return;
    const b = t.browser orelse return sent.deinit(t.gpa);
    const gate: forms.Gate = .{
        .saves = t.kea.prefs.saves_passwords,
        .shy = t.shy,
        .extension_page = extensionPage(t.address),
        // A password manager extension that asked to do the saving itself.
        .extension_saves = if (t.kea.ext) |x| x.passwordSavingTakenBy() != null else false,
    };
    const o = forms.offerFor(Vault.of(t.kea), gate, sent, b.passwords.offering, unixNow()) catch return;
    if (o) |made| ops.offer(b, made);
}

/// `Browser.extensionHost(of:)` != nil: an extension's own page.
fn extensionPage(address: ?[]const u8) bool {
    const p = url.Parts.parse(address orelse return false) orelse return false;
    return p.schemeIs("chrome-extension") or p.schemeIs("webkit-extension");
}

// MARK: a pick, filled in

/// A row of the account list: the `i`th passkey or account.
pub fn pick(b: *Browser, i: usize, passkey: bool) void {
    defer b.redraw();
    const list = b.passwords.accounts.suggesting orelse return;
    const t = b.tabById(list.tab) orelse return;
    const page = pageAddress(t);
    const now = unixNow();
    const choice = (if (passkey) b.passwords.accounts.choosePasskey(i, page, now) else b.passwords.accounts.choose(Vault.of(b.kea), i, page, now)) catch return;
    switch (choice) {
        .none => {},
        .fill => |login| {
            defer login.deinit(b.gpa);
            const js = forms.fillScript(b.gpa, login.user, login.password) catch return;
            defer {
                std.crypto.secureZero(u8, js);
                b.gpa.free(js);
            }
            t.evaluate(js, .kea, filled, 0);
        },
        .name => |user| {
            defer b.gpa.free(user);
            const js = forms.nameScript(b.gpa, user) catch return;
            defer b.gpa.free(js);
            t.evaluate(js, .kea, filled, 0);
        },
        .passkey => |id| {
            defer b.gpa.free(id);
            if (t.web) |wv| t.kea.passkeys.sign(wv, id);
        },
    }
}

fn filled(t: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    if (truthy(value)) return;
    if (t.browser) |b| b.announce(forms.fields_gone);
}

// MARK: unsaved entries

const unsaved_script = "!!(window.__keaForms && window.__keaForms.unsaved && window.__keaForms.unsaved())";

/// `unsaved(_:)`: whether the page holds something typed and not yet
/// sent; a page that can't answer holds nothing. `then` runs on main
/// while the tab lives.
pub fn unsaved(t: *Tab, comptime then: fn (t: *Tab, unsaved: bool, arg: usize) void, arg: usize) void {
    if (t.web == null) return then(t, false, arg);
    t.evaluate(unsaved_script, .kea, struct {
        fn answered(tab: *Tab, value: ?objc.Object, _: ?objc.Object, a: usize) void {
            then(tab, truthy(value), a);
        }
    }.answered, arg);
}

/// A move into another space, asked about (`move(_:toSpace:)`'s closure).
const Moving = struct { serial: u64, from: Uuid, to: Uuid };

/// The page asked first: holding unsaved entries, it moves only once you
/// say so, as it reopens with that space's sign-ins.
// ponytail: a tab closed before its page answers leaves its 40-byte `Moving` behind.
pub fn moveAsking(b: *Browser, t: *Tab, to: Uuid) void {
    const m = std.heap.c_allocator.create(Moving) catch return;
    m.* = .{ .serial = t.serial, .from = b.space_id, .to = to };
    unsaved(t, moveAnswered, @intFromPtr(m));
}

fn moveAnswered(t: *Tab, holds: bool, arg: usize) void {
    const m: *Moving = @ptrFromInt(arg);
    const b = t.browser orelse return moveDone(m, false);
    const at = b.kea.spaceIndex(m.to) orelse return moveDone(m, false);
    if (!b.space_id.eql(m.from) or b.indexOf(t) == null) return moveDone(m, false);
    if (!holds) return moveDone(m, true);
    const detail = std.fmt.allocPrint(b.gpa, "This page has unsaved form entries. It will reopen in \u{201C}{s}\u{201D} with that Space\u{2019}s sign-ins, so the entries may be lost.", .{b.kea.spaces.value[at].name}) catch return moveDone(m, false);
    defer b.gpa.free(detail);
    appkit.ask(if (b.window) |w| w.nswindow else null, .{ .title = "Move Tab?", .detail = detail, .confirm = "Move" }, m, sure);
}

fn sure(m: *Moving, a: appkit.Answer) void {
    moveDone(m, a.ok);
}

fn moveDone(m: *Moving, go: bool) void {
    defer std.heap.c_allocator.destroy(m);
    if (!go) return;
    const t = Tab.alive(m.serial) orelse return;
    const b = t.browser orelse return;
    @import("../model/browser_tabs.zig").finishMove(b, t, m.to);
}
