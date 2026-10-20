//! The sheets over the window (`ContentView.sheet`, App.swift:942-958):
//! a floor of black at .10 that closes it when pressed, and the panel in
//! the middle, arriving at .97 scale and fading in under `Motion.settle`
//! and leaving the same way. One at a time: Settings (`tuning`), the
//! bookmarks manager, Passwords (`managing`), Bring things over
//! (`bringing_in`), History and Downloads, each a `Browser` field opened
//! through `show`. The floor owns the cursor (`CursorGround`): the arrow.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const presence = @import("presence.zig");

/// Each is the `Browser` field of its name (`bringing` is `bringing_in`,
/// the browser it starts on), in `Browser.closePanel`'s order.
pub const Kind = enum { tuning, bookmarking, managing, bringing, recalling, hoarding };

pub const State = struct {
    /// The sheet last shown, drawn until it has left.
    last: ?Kind = null,
};

fn field(comptime k: Kind) []const u8 {
    return if (k == .bringing) "bringing_in" else @tagName(k);
}

fn isOn(b: *const Browser, comptime k: Kind) bool {
    const v = @field(b, field(k));
    return if (@TypeOf(v) == bool) v else v != null;
}

fn set(b: *Browser, comptime k: Kind, on: bool) void {
    const f = &@field(b, field(k));
    if (@TypeOf(f.*) == bool) f.* = on else if (!on) f.* = null else if (f.* == null) f.* = "";
}

/// The sheet up now.
pub fn current(b: *const Browser) ?Kind {
    inline for (comptime std.enums.values(Kind)) |k| if (isOn(b, k)) return k;
    return null;
}

/// Opens `kind` and closes any other.
pub fn show(b: *Browser, kind: Kind) void {
    inline for (comptime std.enums.values(Kind)) |k| set(b, k, k == kind);
    b.redraw();
}

pub fn close(b: *Browser, kind: Kind) void {
    switch (kind) {
        inline else => |k| set(b, k, false),
    }
    b.redraw();
}

/// `tuning.toggle()` and its kin.
pub fn toggle(b: *Browser, kind: Kind) void {
    if (current(b) == kind) close(b, kind) else show(b, kind);
}

/// `Browser.closePanel`: the sheet up, closed; whether there was one.
pub fn closePanel(b: *Browser) bool {
    const kind = current(b) orelse return false;
    close(b, kind);
    return true;
}

const sheet_id: u64 = std.hash.Wyhash.hash(0, "kea.sheet");

/// Draws the sheet, over everything but the tab switcher and the import's card.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const now = current(b);
    if (now) |k| {
        if (b.sheet.last != k) {
            // Swapped straight for another: the old one has gone too.
            if (b.sheet.last) |old| fresh(b, old);
            fresh(b, k);
        }
        b.sheet.last = k;
    }
    const kind = b.sheet.last orelse return;
    const t = presence.presence(c, sheet_id, now != null, motion.settle, null) orelse {
        fresh(b, kind);
        b.sheet.last = null;
        return;
    };
    const o = std.math.clamp(t, 0, 1);
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .opacity = o });
    defer ui.end(c);
    const floor = c.leaf(.{ .absolute = true, .width = .fill, .height = .fill, .background = ui.Color.black.alpha(0.10) }, .none, "kea.sheet.floor");
    const box = c.open(.{ .scale = 0.97 + 0.03 * t }, "kea.sheet.panel");
    defer c.end();
    // Leaving, it is only a picture: the window under it has the pointer.
    if (now != null) {
        c.cursor = .arrow;
        if (c.interact(floor, .{}).pressed) close(b, kind);
        // The panel takes its own clicks; the floor has only what's around it.
        _ = c.interact(box, .{});
    }
    panel(b, c, p, kind);
}

/// A panel's own state begins afresh each time it appears, and lets go of
/// what it held (a key monitor) once it has gone (`@State`, `onDisappear`).
fn fresh(b: *Browser, kind: Kind) void {
    if (kind == .tuning) b.settings.reset(b.gpa);
    if (kind == .recalling and b.recalling) @import("history_panel.zig").opened(b);
    if (kind == .managing) {
        // `managing`'s didSet: the list read again each time it opens.
        b.passwords.panel.deinit(b.gpa);
        b.passwords.panel = .{};
        if (b.managing) @import("../passwords/browser_passwords.zig").relist(b);
    }
    // The import's sheet begins afresh, looking again; gone, its jobs let go.
    if (kind == .bringing) @import("../import/bring.zig").closePanel(b);
}

/// What each sheet shows: the panel draws itself (`controls_plate.plate`
/// or its own frame) with `view(b, c, p)`.
fn panel(b: *Browser, c: *ui.Context, p: *const Palette, kind: Kind) void {
    switch (kind) {
        .tuning => @import("settings/frame.zig").view(b, c, p),
        .recalling => @import("history_panel.zig").view(b, c, p),
        .hoarding => @import("downloads_panel.zig").view(b, c, p),
        .bookmarking => @import("bookmarks/manager.zig").view(b, c, p),
        .managing => @import("../passwords/passwords_panel.zig").view(b, c, p),
        .bringing => @import("../import/panel.zig").view(b, c, p),
    }
}
