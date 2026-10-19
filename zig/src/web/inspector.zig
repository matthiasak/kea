//! The Web Inspector (Inspector.swift): WebKit's own, on the tab in front —
//! ⌥⌘I for the inspector, ⌥⌘J for the console, ⌥⌘C to pick an element.
//! WebKit answers for its inspector only through private names, so each is
//! asked for before it is used; a WebKit without them does nothing.
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../model/browser.zig").Browser;

/// ⌥⌘I: the inspector, or put away if it is up.
pub fn toggleInspector(b: *Browser) void {
    const inspector = of(b) orelse return;
    send(inspector, if (asks(inspector, "isVisible")) "close" else "show");
}

/// ⌥⌘J: the inspector, at its console.
pub fn showConsole(b: *Browser) void {
    send(of(b) orelse return, "showConsole");
}

/// ⌥⌘C: the inspector, and the next click on the page picks what it
/// shows. Again, and the picking stops.
pub fn inspectElement(b: *Browser) void {
    const inspector = of(b) orelse return;
    if (!asks(inspector, "isVisible")) send(inspector, "show");
    send(inspector, "toggleElementSelection");
}

/// The inspector of the tab in front — none for a blank tab, which has no
/// page to look at.
fn of(b: *Browser) ?objc.Object {
    const tab = b.activeTab() orelse return null;
    if (tab.isBlank()) return null;
    const web = tab.web orelse return null;
    if (!responds(web, "_inspector")) return null;
    return objc.msg(?objc.Object, web, "_inspector", .{});
}

fn responds(o: objc.Object, name: [:0]const u8) bool {
    return objc.msg(objc.BOOL, o, "respondsToSelector:", .{objc.sel(name)});
}

fn send(inspector: objc.Object, name: [:0]const u8) void {
    if (responds(inspector, name)) objc.msg(void, inspector, name, .{});
}

fn asks(inspector: objc.Object, name: [:0]const u8) bool {
    return responds(inspector, name) and objc.msg(objc.BOOL, inspector, name, .{});
}
