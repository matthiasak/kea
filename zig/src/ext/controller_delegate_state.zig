//! What the delegate half of `Extensions` keeps (Extensions.swift
//! 1004-1684): the adapters WebKit is handed for tabs and windows, the
//! question being asked, when each extension was last used, where its
//! button is, and what the UI wave hangs off it. One field of `Extensions`
//! (`del`); freed by `deinit` before the contexts go.
const std = @import("std");
const objc = @import("nanoui").objc;
const Extensions = @import("controller.zig").Extensions;
const Browser = @import("../model/browser.zig").Browser;
const asking = @import("controller_asking.zig");

/// Where a button sits, in its window's coordinates, as the row last drew it
/// (Swift kept the NSView; the UI wave fills this each frame).
pub const Anchor = struct {
    /// The NSWindow it is drawn in (not retained); null: not on screen.
    window: ?objc.Object,
    rect: objc.CGRect,
};

/// A popup asked for, waiting on the UI wave's `on_popup`.
pub const PopupRequest = struct {
    url: []u8,
    id: []u8,
    /// A key of `anchors`: the extension's own id, or `menu_anchor`.
    anchor: []u8,
};

const Dates = std.StringArrayHashMapUnmanaged(f64);

pub const State = struct {
    /// `ExtensionTab`s by `Tab.id`, retained.
    tabs: std.AutoArrayHashMapUnmanaged(u64, objc.Object) = .empty,
    /// `ExtensionWindow`s by browser, retained.
    windows: std.AutoArrayHashMapUnmanaged(*Browser, objc.Object) = .empty,

    /// Questions waiting their turn, the first being asked (`question`).
    questions: std.ArrayList(*asking.Pending) = .empty,
    /// For the bench, in a test run only: every question answered this way.
    answer_for_tests: ?bool = null,
    /// What was asked, for the bench (gpa strings).
    asked: std.ArrayList([]u8) = .empty,

    /// The list behind the puzzle button is open.
    menu_open: bool = false,
    /// `Extensions.clicked/pressed/touched` (Swift date, by extension id).
    clicked: Dates = .empty,
    pressed: Dates = .empty,
    touched: Dates = .empty,
    /// `watchTouches`' local monitor.
    touching: ?objc.Object = null,
    /// Where each button (and the puzzle button, `menu_anchor`) sits.
    anchors: std.StringArrayHashMapUnmanaged(Anchor) = .empty,

    /// UI wave: shows an extension's popup (ExtensionPopup.show). Null: no
    /// popup is shown; the request stays in `popup_request`.
    on_popup: ?*const fn (*Extensions, url: []const u8, context: objc.Object, anchor: []const u8) void = null,
    /// UI wave: `ExtensionPopup.shared.closes(id)` — a press on a button
    /// whose popup is open closes it instead.
    popup_closes: ?*const fn (*Extensions, id: []const u8) bool = null,
    /// The last popup asked for.
    popup_request: ?PopupRequest = null,
};

/// Sets a date for `id` in one of the maps (key copied once).
pub fn stamp(gpa: std.mem.Allocator, map: *Dates, id: []const u8, when: f64) void {
    if (map.getPtr(id)) |v| {
        v.* = when;
        return;
    }
    const key = gpa.dupe(u8, id) catch return;
    map.put(gpa, key, when) catch gpa.free(key);
}

pub fn setPopupRequest(self: *Extensions, url: []const u8, id: []const u8, anchor: []const u8) void {
    clearPopupRequest(self);
    const u = self.gpa.dupe(u8, url) catch return;
    const i = self.gpa.dupe(u8, id) catch return self.gpa.free(u);
    const a = self.gpa.dupe(u8, anchor) catch {
        self.gpa.free(u);
        return self.gpa.free(i);
    };
    self.del.popup_request = .{ .url = u, .id = i, .anchor = a };
}

pub fn clearPopupRequest(self: *Extensions) void {
    if (self.del.popup_request) |r| {
        self.gpa.free(r.url);
        self.gpa.free(r.id);
        self.gpa.free(r.anchor);
    }
    self.del.popup_request = null;
}

pub fn deinit(self: *Extensions) void {
    const d = &self.del;
    const gpa = self.gpa;
    @import("adapters.zig").forgetAll(self);
    for (d.questions.items) |p| p.drop();
    d.questions.deinit(gpa);
    for (d.asked.items) |s| gpa.free(s);
    d.asked.deinit(gpa);
    inline for (.{ &d.clicked, &d.pressed, &d.touched }) |m| {
        for (m.keys()) |k| gpa.free(k);
        m.deinit(gpa);
    }
    if (d.touching) |m| @import("../sys/appkit.zig").removeMonitor(m);
    for (d.anchors.keys()) |k| gpa.free(k);
    d.anchors.deinit(gpa);
    clearPopupRequest(self);
}
