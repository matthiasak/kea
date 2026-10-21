//! Reading mode (Reader.swift, `Tab.toggleReader`, `Browser.toggleReader`):
//! the piece of the page carrying the most prose, and nothing arranged
//! around it. Leaving it reloads: putting the old markup back would give a
//! page that looks right and does nothing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Tab = @import("tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;

/// `Reader.script`, run in the page's own world; answers "read" or "none".
const script = @embedFile("js/reader.js");

/// ⇧⌘R.
pub fn toggleReader(b: *Browser) void {
    const t = b.activeTab() orelse return;
    toggle(t);
}

/// `Tab.toggleReader`: says "Nothing to read on this page" when it can't.
pub fn toggle(t: *Tab) void {
    if (t.isBlank()) return nothing(t);
    if (t.reader) {
        t.reader = false;
        t.reload(false);
        return;
    }
    t.evaluate(script, .page, answered, 0);
}

fn answered(t: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const worked = if (value) |v|
        objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")}) and std.mem.eql(u8, objc.fromNSString(v), "read")
    else
        false;
    if (!worked) return nothing(t);
    t.reader = true;
    apply(t);
    t.changed(.state);
}

fn apply(t: *Tab) void {
    const p = &t.kea.prefs;
    const em: u32 = switch (p.reader_width) {
        .narrow => 32,
        .medium => 38,
        .wide => 46,
    };
    const size: u32 = @intFromFloat(@round(std.math.clamp(p.reader_size, 14, 26)));
    var buf: [256]u8 = undefined;
    const js = std.fmt.bufPrint(
        &buf,
        "document.documentElement.dataset.krTheme='{s}';document.documentElement.style.setProperty('--kr-size','{d}px');document.documentElement.style.setProperty('--kr-width','{d}em');",
        .{ @tagName(p.reader_theme), size, em },
    ) catch return;
    t.evaluate(js, .page, null, 0);
}

pub fn restyleAll(kea: *@import("../app/kea.zig").Kea) void {
    for (kea.browsers.items) |w| {
        const parked = w.parkedTabs(w.gpa) catch continue;
        defer w.gpa.free(parked);
        for ([_][]const *Tab{ w.tabs.items, parked }) |list| for (list) |t| {
            if (t.reader and t.web != null) apply(t);
        };
    }
}

fn nothing(t: *Tab) void {
    if (t.browser) |b| b.announce("Nothing to read on this page");
}
