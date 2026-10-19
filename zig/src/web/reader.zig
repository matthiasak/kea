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
        t.reload();
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
    t.changed(.state);
}

fn nothing(t: *Tab) void {
    if (t.browser) |b| b.announce("Nothing to read on this page");
}
