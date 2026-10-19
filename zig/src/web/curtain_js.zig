//! Curtain's page side (Curtain.swift `Veiling`, `VeilRelay`; Browser.swift
//! "taking things off pages"): the pointing mode, ⌘⇧H to start and stop
//! it, ⌘Z while pointing to bring the last thing back, and the hidden
//! things' stylesheet for the page up now and the one that loads next
//! (`tab_scripts.arm`). A private tab writes nothing down: what it hides
//! is kept for its page only (`passing_veils`).
const std = @import("std");
const objc = @import("nanoui").objc;
const Tab = @import("tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;
const Curtain = @import("../data/curtain.zig").Curtain;
const scripts = @import("tab_scripts.zig");
const hidden_panel = @import("../chrome/hidden_panel.zig");

/// `Veiling.picker`: loaded on every page, asleep until asked for.
pub const picker_script = @embedFile("js/veil_picker.js");

/// What a private tab took off its page, by tab id; selectors on `gpa`.
pub const Passing = std.AutoHashMapUnmanaged(u64, std.ArrayList([]u8));

pub fn deinit(b: *Browser) void {
    var it = b.passing_veils.valueIterator();
    while (it.next()) |list| {
        for (list.items) |s| b.gpa.free(s);
        list.deinit(b.gpa);
    }
    b.passing_veils.deinit(b.gpa);
}

// MARK: the tab's half

/// Runs `head` + each of `quoted` between backticks + `tail` in Kea's world.
fn call(t: *Tab, parts: []const []const u8) void {
    var js: std.ArrayList(u8) = .empty;
    defer js.deinit(t.gpa);
    for (parts, 0..) |p, i| {
        // Odd parts are text for between backticks.
        if (i % 2 == 1) scripts.escapeInto(&js, t.gpa, p) catch return else js.appendSlice(t.gpa, p) catch return;
    }
    t.evaluate(js.items, .kea, null, 0);
}

/// `applyVeils`: the same stylesheet, for the page that is already up.
pub fn applyVeils(t: *Tab, css: []const u8) void {
    const js = scripts.veilStyle(t.gpa, css) catch return;
    defer t.gpa.free(js);
    t.evaluate(js, .kea, null, 0);
}

pub fn startPicking(t: *Tab) void {
    t.evaluate("window.__keaVeil && window.__keaVeil.on()", .kea, null, 0);
}

pub fn stopPicking(t: *Tab) void {
    t.evaluate("window.__keaVeil && window.__keaVeil.off()", .kea, null, 0);
}

/// One hidden thing shown, outlined, while its row is hovered.
pub fn peekOn(t: *Tab, selector: []const u8, keeping: []const u8) void {
    call(t, &.{ "window.__keaVeil && window.__keaVeil.peek(`", keeping, "`, `", selector, "`)" });
}

pub fn unpeekOn(t: *Tab, css: []const u8) void {
    call(t, &.{ "window.__keaVeil && window.__keaVeil.unpeek(`", css, "`)" });
}

/// At each main-frame navigation: the next document gets its site's sheet.
pub fn armFor(t: *Tab, address: []const u8) void {
    const host = Curtain.hostOf(t.gpa, address);
    defer if (host) |h| t.gpa.free(h);
    const css = t.kea.curtain.css(t.gpa, host, null) catch return;
    defer t.gpa.free(css);
    scripts.arm(t, css);
}

/// `decidePolicyFor`, main frame: the next document's sheet, and the
/// blocker on or off for the site it is heading to.
pub fn navigating(t: *Tab, wv: objc.Object, address: []const u8) void {
    const host = Curtain.hostOf(t.gpa, address);
    defer if (host) |h| t.gpa.free(h);
    const css = t.kea.curtain.css(t.gpa, host, null) catch return;
    defer t.gpa.free(css);
    scripts.arm(t, css);
    const ucc = objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "userContentController", .{});
    t.kea.shield.tune(ucc, host);
}

// MARK: the window's half

/// `hereHost`: the front tab's site as lists are kept. On `b.gpa`.
pub fn hereHost(b: *Browser) ?[]u8 {
    const t = b.activeTab() orelse return null;
    return Curtain.hostOf(b.gpa, t.address);
}

fn hereCss(b: *Browser, spared: ?[]const u8) ?[]u8 {
    const host = hereHost(b);
    defer if (host) |h| b.gpa.free(h);
    return b.kea.curtain.css(b.gpa, host, spared) catch null;
}

/// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
pub fn toggleHiding(b: *Browser) void {
    const t = b.activeTab() orelse return;
    if (t.isBlank()) return;
    if (b.veiling) {
        b.veiling = false;
        stopPicking(t);
    } else {
        hidden_panel.setReviewing(b, false);
        b.veiling = true;
        startPicking(t);
    }
    b.redraw();
}

fn passingCss(b: *Browser, id: u64, out: *std.ArrayList(u8)) !void {
    const list = b.passing_veils.get(id) orelse return;
    for (list.items) |s| try out.print(b.gpa, "\n{s} {{ display: none !important; }}", .{s});
}

/// The site's sheet plus what this private tab took off its page.
fn applyPassing(b: *Browser, t: *Tab, host: ?[]const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(b.gpa);
    const css = b.kea.curtain.css(b.gpa, host, null) catch return;
    defer b.gpa.free(css);
    out.appendSlice(b.gpa, css) catch return;
    passingCss(b, t.id, &out) catch return;
    applyVeils(t, out.items);
}

/// ⌘Z, while pointing: the last thing taken off comes back.
pub fn undoHiding(b: *Browser) void {
    const t = b.activeTab() orelse return;
    const host = hereHost(b);
    defer if (host) |h| b.gpa.free(h);
    if (t.shy) {
        const list = b.passing_veils.getPtr(t.id) orelse return;
        const last = list.pop() orelse return;
        b.gpa.free(last);
        applyPassing(b, t, host);
        return b.announce("It's back");
    }
    const back = b.kea.curtain.undo(b.gpa, host orelse return) orelse return;
    defer {
        b.gpa.free(back.selector);
        b.gpa.free(back.label);
        if (back.note) |n| b.gpa.free(n);
    }
    redress(b);
    var said: std.ArrayList(u8) = .empty;
    defer said.deinit(b.gpa);
    said.print(b.gpa, "{s} is back", .{back.label}) catch return;
    b.announce(said.items);
}

/// `onPick`: what the pointer chose, gone from this page and the next.
pub fn picked(b: *Browser, t: *Tab, selector: []const u8, label: []const u8, note: []const u8) void {
    const host = Curtain.hostOf(b.gpa, t.address) orelse return;
    defer b.gpa.free(host);
    if (t.shy) {
        const gop = b.passing_veils.getOrPut(b.gpa, t.id) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const copy = b.gpa.dupe(u8, selector) catch return;
        gop.value_ptr.append(b.gpa, copy) catch return b.gpa.free(copy);
        applyPassing(b, t, host);
        return b.announce("Hidden on this page — ⌘Z puts it back");
    }
    b.kea.curtain.hide(selector, label, note, host);
    const css = b.kea.curtain.css(b.gpa, host, null) catch return;
    defer b.gpa.free(css);
    scripts.arm(t, css);
    applyVeils(t, css);
    b.announce("Hidden — ⌘Z puts it back");
}

/// `onPickEnd`: the page stopped pointing (Esc on the page, or `off`).
pub fn ended(b: *Browser) void {
    b.veiling = false;
    b.redraw();
}

/// `onPickTrouble`.
pub fn trouble(b: *Browser, reason: []const u8) void {
    var said: std.ArrayList(u8) = .empty;
    defer said.deinit(b.gpa);
    said.print(b.gpa, "Couldn't hide that — {s}", .{reason}) catch return;
    b.announce(said.items);
}

/// The pointer on a row of the hidden list: that one thing back, outlined.
pub fn peek(b: *Browser, selector: []const u8) void {
    const t = b.activeTab() orelse return;
    const css = hereCss(b, selector) orelse return;
    defer b.gpa.free(css);
    peekOn(t, selector, css);
}

pub fn stopPeeking(b: *Browser) void {
    const t = b.activeTab() orelse return;
    const css = hereCss(b, null) orelse return;
    defer b.gpa.free(css);
    unpeekOn(t, css);
}

pub fn restore(b: *Browser, selector: []const u8) void {
    const host = hereHost(b) orelse return;
    defer b.gpa.free(host);
    b.kea.curtain.restore(selector, host);
    redress(b);
}

pub fn restoreAll(b: *Browser) void {
    const host = hereHost(b) orelse return;
    defer b.gpa.free(host);
    b.kea.curtain.restoreAll(host);
    redress(b);
    hidden_panel.setReviewing(b, false);
    b.announce("Everything is back");
}

/// Both the page in front of you and the one that loads next time.
fn redress(b: *Browser) void {
    const t = b.activeTab() orelse return;
    const css = hereCss(b, null) orelse return;
    defer b.gpa.free(css);
    scripts.arm(t, css);
    applyVeils(t, css);
}
