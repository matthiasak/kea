//! P5.7: links from other apps (Links.swift) and AppleScript (Scripting.swift,
//! Kea.sdef) against a hidden window.
const std = @import("std");
const objc = @import("nanoui").objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "open URLs land in the front browser", .run = openUrls },
    .{ .name = "scripting reads tabs through the sdef's classes", .run = scripting },
};

var urls: [3][]const u8 = undefined;

fn addressIs(t: *app.Tab, url: []const u8) bool {
    return std.mem.eql(u8, t.address orelse "", url);
}

fn bothArrived(b: *app.Browser) bool {
    return b.tabs.items.len == 2 and addressIs(b.tabs.items[0], urls[0]) and addressIs(b.tabs.items[1], urls[1]);
}

fn openUrls(h: *Harness) !void {
    const b = try h.start();
    const k = h.kea.?;
    var bufs: [3][128]u8 = undefined;
    for (&urls, &bufs, 0..) |*u, *buf, i| u.* = try std.fmt.bufPrint(buf, "{s}/arrived-{d}", .{ h.http, i });
    app.links.hand(k);
    // Before a window shows they wait; then the first goes into the blank
    // tab and the second behind it. Anything but the web's and files' is
    // left alone.
    app.links.onOpenURLs(k, &.{ urls[0], "ftp://example.com/x", urls[1] });
    h.waitFor(b, bothArrived, 5, "both links in the window") catch
        return h.fail("{d} tabs after two links", .{b.tabs.items.len});
    try h.expect(b.active_id == b.tabs.items[0].id, "the first link isn't the tab in front", .{});
    // From then on a link goes straight in, in front.
    app.links.onContinueActivity(k, urls[2]);
    try h.expect(b.tabs.items.len == 3, "a handed-off page made {d} tabs", .{b.tabs.items.len});
    try h.expect(addressIs(b.tabById(b.active_id).?, urls[2]), "the handed-off page isn't in front", .{});
    try h.expect(!app.links.isDefault(), "the test runner says it's the Mac's browser", .{});
}

/// Loaded and titled: WebKit tells the title in its own turn, which may
/// come after the load ends.
fn arrived(t: *app.Tab) bool {
    return t.committed != null and !t.loading and t.page_title.len > 0;
}

extern "c" fn NSClassFromString(name: objc.Object) ?objc.Class;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

fn property(container_desc: ?objc.Object, container: objc.Object, key: []const u8) objc.Object {
    const s = objc.msg(objc.Object, objc.alloc("NSPropertySpecifier"), "initWithContainerClassDescription:containerSpecifier:key:", .{ container_desc, container, objc.nsString(key) });
    objc.autorelease(s);
    return s;
}

var script_error: objc.NSInteger = 0;

/// Runs `command` on `receivers` as a script's Apple event would.
fn run(registry: objc.Object, comptime class: *const [4]u8, comptime code: *const [4]u8, receivers: objc.Object, arguments: ?objc.Object) ?objc.Object {
    const desc = objc.msg(?objc.Object, registry, "commandDescriptionWithAppleEventClass:andAppleEventCode:", .{ fourcc(class), fourcc(code) }) orelse return null;
    // Autoreleased: `create…` isn't one of Cocoa's owning names.
    const command = objc.msg(objc.Object, desc, "createCommandInstance", .{});
    objc.msg(void, command, "setReceiversSpecifier:", .{receivers});
    if (arguments) |a| objc.msg(void, command, "setArguments:", .{a});
    const result = objc.msg(?objc.Object, command, "executeCommand", .{});
    script_error = objc.msg(objc.NSInteger, command, "scriptErrorNumber", .{});
    return result;
}

/// A result as text: a string, or a descriptor's.
fn text(o: objc.Object) []const u8 {
    if (objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class("NSString")})) return objc.fromNSString(o);
    if (objc.msg(objc.BOOL, o, "respondsToSelector:", .{objc.sel("stringValue")})) return objc.fromNSString(objc.msg(?objc.Object, o, "stringValue", .{}));
    return objc.fromNSString(objc.msg(objc.Object, o, "description", .{}));
}

fn scripting(h: *Harness) !void {
    const b = try h.start();
    var buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "{s}/scripted", .{h.http});
    b.newShyTab();
    const shy = b.tabById(b.active_id).?;
    const t = b.open(url, .{ .foreground = true });
    h.waitFor(t, arrived, 10, "the page") catch return h.fail("the page never arrived: {s}", .{t.failure orelse ""});
    const pool = objc.Pool.push();
    defer pool.pop();

    // The classes Kea.sdef names resolve, and its dictionary maps onto them.
    for ([_][]const u8{ "ScriptTab", "NSCountCommand", "NSApplication", "NSWindow" }) |name|
        try h.expect(NSClassFromString(objc.nsString(name)) != null, "no class {s}", .{name});
    const registry = objc.msg(objc.Object, objc.class("NSScriptSuiteRegistry"), "sharedScriptSuiteRegistry", .{});
    // The dictionary the bundle ships, loaded as AppKit loads an app's.
    // Outside a launched app its types stay unresolved (it includes no
    // standard suite), which only `count` below notices.
    objc.msg(void, registry, "_loadSuitesForAlreadyLoadedBundles", .{});
    const sdef = @embedFile("kea_sdef");
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ sdef.ptr, sdef.len });
    objc.msg(void, registry, "_loadSuitesFromSDEFData:bundle:", .{ data, objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{}) });
    const tab_desc = objc.msg(?objc.Object, registry, "classDescriptionWithAppleEventCode:", .{fourcc("bTab")}) orelse
        return h.fail("the sdef's tab class isn't registered", .{});
    const class_name = objc.fromNSString(objc.msg(?objc.Object, tab_desc, "implementationClassName", .{}));
    try h.expect(std.mem.eql(u8, class_name, "ScriptTab"), "tab is cocoa class {s}", .{class_name});
    const count_desc = objc.msg(?objc.Object, registry, "commandDescriptionWithAppleEventClass:andAppleEventCode:", .{ fourcc("core"), fourcc("cnte") }) orelse
        return h.fail("the sdef's count isn't registered", .{});
    const command_name = objc.fromNSString(objc.msg(?objc.Object, count_desc, "commandClassName", .{}));
    try h.expect(std.mem.eql(u8, command_name, "NSCountCommand"), "count is cocoa class {s}", .{command_name});

    const window = b.window.?.nswindow;
    const win_spec = objc.msg(?objc.Object, window, "objectSpecifier", .{}) orelse return h.fail("the window has no specifier", .{});
    const win_desc = objc.msg(?objc.Object, win_spec, "keyClassDescription", .{});

    // get URL of current tab of window id …
    const got = run(registry, "core", "getd", property(tab_desc, property(win_desc, win_spec, "scriptCurrentTab"), "url"), null) orelse
        return h.fail("get URL of current tab answered nothing (error {d})", .{script_error});
    try h.expect(std.mem.eql(u8, text(got), url), "URL of current tab is {s}", .{text(got)});
    // get name of current tab
    const name = run(registry, "core", "getd", property(tab_desc, property(win_desc, win_spec, "scriptCurrentTab"), "name"), null) orelse
        return h.fail("get name of current tab answered nothing (error {d})", .{script_error});
    try h.expect(std.mem.eql(u8, text(name), "Local /scripted"), "name of current tab is {s}", .{text(name)});
    // count tabs of window id …, sent as AppleScript does (the window, each
    // tab): the private one is left out. Outside a launched app the sdef's
    // element type stays unresolved (Kea.sdef includes no standard suite),
    // so Cocoa answers -1708 (errAEEventNotHandled) for the to-many
    // relationship; then the sdef's key itself is read, as Cocoa would.
    const each = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObject:forKey:", .{
        objc.msg(objc.Object, objc.class("NSNumber"), "numberWithUnsignedInt:", .{fourcc("bTab")}), objc.nsString("ObjectClass"),
    });
    if (run(registry, "core", "cnte", win_spec, each)) |counted| {
        const n = std.fmt.parseInt(i64, text(counted), 10) catch -1;
        try h.expect(n == 2, "count tabs is {s}, of {d}", .{ text(counted), b.tabs.items.len });
    } else try h.expect(script_error == -1708, "count tabs failed with {d}", .{script_error});
    const every = objc.msg(objc.Object, window, "valueForKey:", .{objc.nsString("scriptTabs")});
    const listed = objc.msg(objc.NSUInteger, every, "count", .{});
    try h.expect(listed == 2, "scriptTabs lists {d} of {d}", .{ listed, b.tabs.items.len });
    const last = objc.msg(objc.Object, every, "objectAtIndex:", .{@as(objc.NSUInteger, 1)});
    const last_url = objc.fromNSString(objc.msg(?objc.Object, last, "valueForKey:", .{objc.nsString("url")}));
    try h.expect(std.mem.eql(u8, last_url, url), "tab 2's URL is {s}", .{last_url});
    // A tab names itself as tab N of its window, once the window's class is
    // known to the dictionary (Swift's guard: no class description, no
    // specifier — the unresolved case above).
    const current = objc.msg(?objc.Object, window, "valueForKey:", .{objc.nsString("scriptCurrentTab")}).?;
    const spec = objc.msg(?objc.Object, current, "objectSpecifier", .{});
    if (win_desc == null) {
        try h.expect(spec == null, "a tab named itself without its window's class", .{});
    } else {
        const s = spec orelse return h.fail("the tab has no specifier", .{});
        const index = objc.msg(objc.NSInteger, s, "index", .{});
        try h.expect(index == 1, "current tab is tab index {d}", .{index});
    }

    // A private tab in front: no current tab (missing value).
    b.select(shy);
    try h.expect(objc.msg(?objc.Object, window, "valueForKey:", .{objc.nsString("scriptCurrentTab")}) == null, "a private tab was shown to a script", .{});
}
