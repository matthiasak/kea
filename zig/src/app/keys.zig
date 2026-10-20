//! The key monitor (`ContentView.watchKeys` and `take`, App.swift:1073-1538).
//! A page takes first responder and keeps most of the keyboard, so the
//! app's keys are caught before the event reaches anything: one local
//! monitor for the app, `.keyDown`, `.flagsChanged` and `.leftMouseDown`,
//! each event its own window's browser's, or the window in front's when it
//! is no browser's (a panel). The menus carry the same commands for anyone
//! looking for them (app/menus.zig); what isn't taken here goes on to them.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Kea = @import("kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const appkit = @import("../sys/appkit.zig");
const browsers = @import("browsers.zig");
const shortcuts = @import("shortcuts.zig");
const KeyCombo = shortcuts.KeyCombo;
const commands = @import("commands.zig");
const sheet = @import("../chrome/sheet.zig");
const side_panels = @import("../chrome/side_panels.zig");
const spaces_view = @import("../chrome/spaces_view.zig");
const hidden_panel = @import("../chrome/hidden_panel.zig");
const history_panel = @import("../chrome/history_panel.zig");
const downloads_panel = @import("../chrome/downloads_panel.zig");
const tab_switcher = @import("../chrome/tab_switcher.zig");
const manager = @import("../chrome/bookmarks/manager.zig");
const fold = @import("../chrome/fold.zig");
const page_find = @import("../web/page_find.zig");
const curtain_js = @import("../web/curtain_js.zig");
const little = @import("../web/little.zig");

const command = shortcuts.flag.command;
const shift = shortcuts.flag.shift;
const option = shortcuts.flag.option;
const control = shortcuts.flag.control;
const held = command | shift | option | control;

/// `NSEventMask`: left mouse down, key down, flags changed.
const watched: u64 = (1 << 1) | (1 << 10) | (1 << 12);

pub fn install(kea: *Kea) void {
    if (kea.key_monitor != null) return;
    kea.key_monitor = appkit.addLocalMonitor(watched, kea, seen);
}

pub fn uninstall(kea: *Kea) void {
    const m = kea.key_monitor orelse return;
    appkit.removeMonitor(m);
    kea.key_monitor = null;
}

fn seen(kea: *Kea, event: objc.Object) ?objc.Object {
    const window = objc.msg(?objc.Object, event, "window", .{});
    const b = browsers.browserFor(kea, window) orelse browsers.acting(kea) orelse return event;
    return switch (objc.msg(objc.NSUInteger, event, "type", .{})) {
        1 => if (clicked(b, event)) null else event,
        12 => {
            modifiers(b, event);
            return event;
        },
        else => if (take(b, event)) null else event,
    };
}

/// A click on the tab switcher, in this window only, in the top-left
/// points the chrome is drawn in (`Browser.clickTabSwitcher`).
pub fn clicked(b: *Browser, event: objc.Object) bool {
    if (!b.switcher.visible) return false;
    const w = b.window orelse return false;
    if (objc.msg(?objc.Object, event, "window", .{}) != w.nswindow) return false;
    const content = objc.msg(?objc.Object, w.nswindow, "contentView", .{}) orelse return false;
    const height = objc.msg(objc.CGRect, content, "bounds", .{}).size.height;
    const at = objc.msg(objc.CGPoint, event, "locationInWindow", .{});
    return tab_switcher.clickTabSwitcher(b, .{ .x = @floatCast(at.x), .y = @floatCast(height - at.y) });
}

/// A modifier let go of: ⌃ switches to the tab the switcher is on, ⌘ ends
/// a ⌘K walk wherever it stopped.
pub fn modifiers(b: *Browser, event: objc.Object) void {
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{});
    if (b.switcher.active() and flags & control == 0) b.commitTabSwitch(null);
    if (flags & command == 0) b.landSummon();
}

/// The last key handed to the page before KeaZig acted on it (`pageFirst`):
/// if WebKit sends it back unused, it is KeaZig's.
/// Swift's `PageView.same`: no two presses share a timestamp.
const Pressed = struct { at: f64, code: u16, kind: objc.NSUInteger };
var passed: ?Pressed = null;

/// Whether `event` is the press last handed to the page first, not back yet.
pub fn handedToPage(event: objc.Object) bool {
    const p = passed orelse return false;
    return p.at == objc.msg(f64, event, "timestamp", .{}) and p.code == objc.msg(u16, event, "keyCode", .{}) and
        p.kind == objc.msg(objc.NSUInteger, event, "type", .{});
}

/// `take`: whether the key was the app's, and done.
pub fn take(b: *Browser, event: objc.Object) bool {
    const window = objc.msg(?objc.Object, event, "window", .{});
    // A question hanging from the window (Ask) answers its own keys.
    if (window) |w| if (objc.msg(?objc.Object, w, "sheetParent", .{}) != null) return false;
    // A small window's keys are its own (web/little.zig has its monitor).
    if (little.owning(window) != null) return false;
    // An extension's popup window: ⌘W closes it, not a tab of the window
    // menus act on; every other key is its page's.
    if (browsers.browserFor(b.kea, window)) |pw| if (pw.ext.popup != null) {
        const pool = objc.Pool.push();
        defer pool.pop();
        const chars = objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{});
        const w_key = if (chars) |s| std.mem.eql(u8, objc.fromNSString(objc.msg(objc.Object, s, "lowercaseString", .{})), "w") else false;
        if (!w_key or objc.msg(objc.NSUInteger, event, "modifierFlags", .{}) & held != command) return false;
        if (pw.window) |w| objc.msg(void, w.nswindow, "performClose:", .{@as(?objc.Object, null)});
        return true;
    };
    // A key being typed into Settings › Shortcuts is for the box.
    if (b.kea.shortcuts.recording) return false;
    const pool = objc.Pool.push();
    defer pool.pop();
    const flags = objc.msg(objc.NSUInteger, event, "modifierFlags", .{}) & held;
    const code = objc.msg(u16, event, "keyCode", .{});
    const chars = objc.msg(?objc.Object, event, "charactersIgnoringModifiers", .{});
    const key = if (chars) |s| objc.fromNSString(objc.msg(objc.Object, s, "lowercaseString", .{})) else "";
    const own = if (b.window) |w| window == w.nswindow else window == null;
    const control_tab = code == 48 and flags & control != 0 and flags & (command | option) == 0;

    // Esc while a tab is carried over the pages: put back (`TabDrag.cancel`).
    if (code == 53 and @import("../chrome/split_drop.zig").cancel(b)) return true;

    // While the tab switcher is up, ⌃ and the arrows move through it and
    // ⌃Tab goes on below; any other key puts it away, and Escape does
    // nothing else.
    if (b.switcher.active() and !control_tab) {
        if (flags & control != 0 and flags & (command | option) == 0) {
            const direction: ?tab_switcher.Direction = switch (code) {
                123 => .left,
                124 => .right,
                125 => .down,
                126 => .up,
                else => null,
            };
            if (direction) |d| {
                tab_switcher.move(b, d);
                return true;
            }
        }
        tab_switcher.cancel(b);
        if (code == 53) return true;
    }

    // The bookmarks manager's keys, while its search is empty and has no use for them.
    if (b.bookmarking and own and b.marks_ui.picks.query.text().len == 0 and !proposing(b) and manager.take(b, event)) return true;

    // Escape puts the page back, one thing at a time.
    if (code == 53) return escape(b);

    var buf: [32]u8 = undefined;
    const combo = shortcuts.fromEvent(event, &buf);
    const sc = &b.kea.shortcuts;

    // Split focus ahead of WebKit's arrow keys: its panes keep the keyboard.
    if (b.prefs.split_view and b.activeSplit() != null) if (combo) |kc| {
        if (same(sc.effective("tabs.focusLeftPane"), kc)) return done(b.focusPaneSide(true));
        if (same(sc.effective("tabs.focusRightPane"), kc)) return done(b.focusPaneSide(false));
        if (same(sc.effective("tabs.focusOtherPane"), kc)) return done(b.focusOtherPane());
    };

    // ⌘Return keeps a peek, Return or the keypad's Enter; ⌥⌘Return, with
    // Split View on, keeps it beside the page. Not while typing in it.
    if (code == 36 or code == 76) if (b.peek_tab) |page| {
        const beside = b.prefs.split_view and flags == command | option;
        if ((flags == command or beside) and !page.typing and !editable(page)) {
            b.keepPeek(flags & option != 0);
            return true;
        }
    };

    // Tab is the page's. ⌃Tab brings up the switcher, or walks the row when
    // something is over the page; in the address field Tab walks its list.
    if (code == 48 and flags & (command | option) == 0) {
        const back = flags & shift != 0;
        if (flags & control != 0) {
            if (own and tab_switcher.canSwitch(b)) {
                // A Tab held down doesn't race through them.
                if (!objc.msg(objc.BOOL, event, "isARepeat", .{})) b.switchTabs(back);
                return true;
            }
            return done(b.step(if (back) -1 else 1));
        }
        if (b.editing_tab != null) return true;
        // "red" then Tab: Reddit, in the field (SiteSearch.swift).
        if (b.fieldShowing() and !back and b.lockSiteOffer()) return true;
        if (b.fieldShowing() and b.omni.offers.len > 0) return done(b.walk(if (back) -1 else 1));
        return false;
    }

    // ⌃1–⌃9 go to that space, by the key, when there are spaces.
    if (b.prefs.uses_spaces and flags == control) if (digit(code)) |n| if (n > 0) return done(b.switchSpaceIndex(n - 1));

    // Your own keys (Settings › Shortcuts), before the ones below: a command
    // you moved runs on its new key; a key you took off one goes to the page.
    if (sc.anyChanged()) if (combo) |kc| {
        if (sc.changedCommand(kc)) |cmd| {
            if (commands.isIn(&commands.split, cmd.id) and !b.prefs.split_view) return false;
            if (commands.isIn(&commands.ai, cmd.id) and !b.prefs.ai) return false;
            return done(cmd.run(b));
        }
        if (sc.isFreed(kc)) return false;
    };
    // A shortcut an extension registered — ⌥⇧D, ⌃⇧Y — before ours, since
    // none of ours use those. Never one of ours, nor one of the Mac's.
    if (flags & (command | option | control) != 0) if (b.kea.ext) |x| {
        const free = if (combo) |kc| !sc.keepsFromExtensions(kc) else true;
        if (free and @import("../ext/controller_buttons.zig").take(x, event)) return true;
    };

    if (flags & command == 0) return false;
    const shifted = flags & shift != 0;

    if (flags & option != 0 and !shifted and flags & control == 0 and plainIs(event, "r")) {
        if (pageFirst(b, event, "r", false)) return false;
        if (b.activeTab()) |t| t.reload(true);
        return true;
    }
    // Other shortcuts with ⌥ or ⌃ on top are somebody else's: the menus'.
    if (flags & (option | control) != 0) return false;

    // ⌘Return in the address field is the field's own (chrome/omnibox.zig):
    // no menu item takes it, so AppKit hands it to the chrome as typed.

    // ⌘1–⌘9 and ⌘0 by the key, not what it types (AZERTY's top row). The
    // ninth is the last tab on screen, however many.
    if (!shifted) if (digit(code)) |n| {
        if (n == 0) {
            if (b.activeTab()) |t| t.resetZoom();
        } else if (n == 9) {
            const shown = b.shownTabs(b.gpa) catch return true;
            defer b.gpa.free(shown);
            if (shown.len > 0) b.selectIndex(shown.len - 1);
        } else b.selectIndex(n - 1);
        return true;
    };

    // Clearing, reachable from a page's editor.
    if (shifted and code == 51) return done(history_panel.showClearing(b));

    // The page's turn first, for the keys it may want.
    if (pageFirst(b, event, key, shifted)) return false;

    const one: u8 = if (key.len == 1) key[0] else 0;
    switch (one) {
        't' => if (shifted) b.reopen() else b.newTab(),
        'c' => if (shifted) b.copyAddress() else return arrows(b, event, code, shifted),
        'd' => if (!shifted) b.duplicate() else return arrows(b, event, code, shifted),
        'n' => if (shifted) b.newShyTab() else return arrows(b, event, code, shifted),
        '.' => {
            if (shifted) return arrows(b, event, code, shifted);
            const t = b.activeTab() orelse return false;
            if (!t.loading) return false;
            t.stopLoading();
        },
        'y' => if (!shifted) history_panel.toggle(b) else {
            if (!b.prefs.ai) return false;
            commands.named("view.ask").?.run(b);
        },
        'j' => if (shifted) downloads_panel.toggle(b) else return arrows(b, event, code, shifted),
        'v' => if (shifted) paste(b, event) else return arrows(b, event, code, shifted),
        'p' => if (shifted) @import("../web/float.zig").toggle(b) else b.printPage(),
        'f' => if (!shifted) page_find.openFind(b) else return arrows(b, event, code, shifted),
        'g' => page_find.look(b, !shifted),
        'm' => if (shifted) b.pauseMedia() else return arrows(b, event, code, shifted),
        'k' => if (!shifted) commands.named("tabs.search").?.run(b) else return arrows(b, event, code, shifted),
        's' => if (shifted) commands.named("view.sidebar").?.run(b) else fold.toggleFold(b),
        'b' => if (shifted) b.bookmarkCurrent() else return arrows(b, event, code, shifted),
        ',' => if (!shifted) sheet.toggle(b, .tuning) else return arrows(b, event, code, shifted),
        'h' => if (shifted) curtain_js.toggleHiding(b) else return arrows(b, event, code, shifted),
        'u' => if (shifted) hidden_panel.toggle(b) else return arrows(b, event, code, shifted),
        'z' => {
            if (shifted) return arrows(b, event, code, shifted);
            // Only while pointing: everywhere else undo is the page's.
            if (!b.veiling) return false;
            curtain_js.undoHiding(b);
        },
        // ⌘+ arrives as "=" or "+" depending on the keyboard.
        '=', '+' => if (b.activeTab()) |t| t.magnifyBy(1.1),
        '-' => if (b.activeTab()) |t| t.magnifyBy(1.0 / 1.1),
        '0' => if (b.activeTab()) |t| t.resetZoom(),
        'w' => if (!shifted) b.closeFront() else return arrows(b, event, code, shifted),
        'l' => if (!shifted) b.edit() else return arrows(b, event, code, shifted),
        'r' => if (shifted) @import("../web/reader.zig").toggleReader(b) else if (b.activeTab()) |t| t.reload(false),
        '[' => if (shifted) b.step(-1) else if (b.activeTab()) |t| t.goBack(),
        ']' => if (shifted) b.step(1) else if (b.activeTab()) |t| t.goForward(),
        else => return arrows(b, event, code, shifted),
    }
    return true;
}

fn done(_: void) bool {
    return true;
}

/// ⌘← and ⌘→, for hands that never learned the brackets — not while the
/// caret is in an editor, where they move through the text.
fn arrows(b: *Browser, event: objc.Object, code: u16, shifted: bool) bool {
    if (shifted or caretIn(b, event)) return false;
    const t = b.activeTab() orelse return code == 123 or code == 124;
    if (code == 123) return done(t.goBack());
    if (code == 124) return done(t.goForward());
    return false;
}

/// Escape (`take`'s chain), in Swift's order, after the overlay over the
/// window (a popover in Swift, closed by its own Escape). False when
/// nothing wanted it: it goes on to the page or the field.
pub fn escape(b: *Browser) bool {
    defer b.redraw();
    if (b.overlay != null) {
        b.overlay = null;
        return true;
    }
    if (b.editing_tab != null) return done(b.cancelTabEdit());
    if (b.peek_tab != null) return done(b.closePeek());
    if (b.making_space) return done(spaces_view.cancel(b));
    // The same panels in the same order as ⌘W (`closeFront`).
    if (sheet.closePanel(b)) return true;
    if (b.passwords.accounts.suggesting != null) return done(@import("../passwords/browser_passwords.zig").dropChoice(b));
    if (side_panels.collapse(b)) return true;
    if (b.assisting != null) return done(b.closeAssistant());
    if (b.veiling) return done(curtain_js.toggleHiding(b));
    if (b.reviewing) return done(hidden_panel.setReviewing(b, false));
    if (b.finder.finding) return done(page_find.closeFind(b));
    // One step at a time: the list first, then the field.
    if (b.omni.picked != null) {
        b.omni.picked = null;
        return true;
    }
    // A new tab never sent anywhere is itself what is open: Escape takes it
    // away, back to the tab touched last. Anything typed keeps it; so does
    // being the last tab.
    const front = b.activeTab();
    if (front) |blank| if (blank.isBlank() and b.omni.typed.items.len == 0) {
        var back: ?*Tab = null;
        for (b.tabs.items) |t| if (t != blank and (back == null or t.touched > back.?.touched)) {
            back = t;
        };
        if (back) |t| {
            b.select(t);
            b.close(blank);
            return true;
        }
    };
    if (!b.editing or front == null or front.?.isBlank()) return false;
    return done(b.dismiss());
}

/// A bookmarks proposal (P9's organiser) on screen keeps the manager's keys from it.
fn proposing(b: *const Browser) bool {
    if (comptime @hasField(@TypeOf(b.marks_ui.picks), "proposal")) return b.marks_ui.picks.proposal != null;
    return false;
}

/// `pageFirst`: a key a page may want — ⌘K in Slack, ⌘F in a Google Doc —
/// goes to the page first while it has the keyboard, and is the app's only
/// if WebKit sends it back unused. Making and closing tabs, moving between
/// them and ⌘K stay the app's; so do ⌘← and ⌘→ while nothing is typed.
fn pageFirst(b: *Browser, event: objc.Object, key: []const u8, shifted: bool) bool {
    const eq = std.mem.eql;
    const code = objc.msg(u16, event, "keyCode", .{});
    const bracket = eq(u8, key, "[") or eq(u8, key, "]") or eq(u8, key, "{") or eq(u8, key, "}");
    const reserved = eq(u8, key, "t") or (eq(u8, key, "w") and !shifted) or (eq(u8, key, "n") and shifted) or
        (bracket and shifted) or (eq(u8, key, "z") and b.veiling) or (eq(u8, key, "k") and !shifted) or
        (!shifted and (code == 123 or code == 124) and !caretIn(b, event));
    if (reserved or !pageHasKeys(event)) return false;
    const me: Pressed = .{
        .at = objc.msg(f64, event, "timestamp", .{}),
        .code = code,
        .kind = objc.msg(objc.NSUInteger, event, "type", .{}),
    };
    if (passed) |p| if (p.at == me.at and p.code == me.code and p.kind == me.kind) {
        passed = null;
        return false;
    };
    passed = me;
    return true;
}

fn responder(event: objc.Object) ?objc.Object {
    const w = objc.msg(?objc.Object, event, "window", .{}) orelse return null;
    return objc.msg(?objc.Object, w, "firstResponder", .{});
}

fn pageHasKeys(event: objc.Object) bool {
    const r = responder(event) orelse return false;
    const cls = objc.class("KeaZigPageView");
    return objc.msg(objc.BOOL, r, "isKindOfClass:", .{cls});
}

/// Whether the caret is in something editable: a text box of the chrome's,
/// a field editor, or one on the page in any frame (the view has an input
/// context only then).
fn caretIn(b: *Browser, event: objc.Object) bool {
    if (responder(event)) |r| {
        if (objc.msg(objc.BOOL, r, "isKindOfClass:", .{objc.class("NSTextView")})) return true;
        if (b.window) |w| if (w.surface) |s| if (r == s.nsview and s.ctx.focus != 0) return true;
    }
    const t = b.activeTab() orelse return false;
    return t.typing or editable(t);
}

fn editable(t: *const Tab) bool {
    const wv = t.web orelse return false;
    return objc.msg(?objc.Object, wv, "inputContext", .{}) != null;
}

/// ⇧⌘V: paste without formatting while something is being typed (a Google
/// Doc, a form, the address field), Paste and Go otherwise.
fn paste(b: *Browser, event: objc.Object) void {
    const typing = b.editing or caretIn(b, event);
    if (!typing) return b.pasteAndGo();
    const r = responder(event) orelse return;
    if (!objc.msg(objc.BOOL, r, "tryToPerform:with:", .{ objc.sel("pasteAsPlainText:"), @as(?objc.Object, null) }))
        _ = objc.msg(objc.BOOL, r, "tryToPerform:with:", .{ objc.sel("paste:"), @as(?objc.Object, null) });
}

/// The key as it types with nothing held (`characters(byApplyingModifiers: [])`).
fn plainIs(event: objc.Object, want: []const u8) bool {
    const s = objc.msg(?objc.Object, event, "charactersByApplyingModifiers:", .{@as(objc.NSUInteger, 0)}) orelse return false;
    return std.mem.eql(u8, objc.fromNSString(objc.msg(objc.Object, s, "lowercaseString", .{})), want);
}

/// `ContentView.digits`: the top row by where it sits, 1…9 and 0.
fn digit(code: u16) ?u8 {
    for (shortcuts.digits) |d| if (d[0] == code) return d[1] - '0';
    return null;
}

fn same(a: ?KeyCombo, b: KeyCombo) bool {
    return if (a) |x| x.eql(b) else false;
}
