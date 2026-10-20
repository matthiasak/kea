//! The page in front, elsewhere (Sharing.swift, and Browser.swift's
//! `printPage`): offered to your other devices (Handoff), sent through the
//! Mac's share picker (File › Share…), and printed (⌘P).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;

extern "c" var NSUserActivityTypeBrowsingWeb: objc.Object;

/// `handOff`: the page in front, offered to your other devices. Only from
/// the key window; never a private tab, never a test run.
pub fn handOff(b: *Browser) void {
    if (b.kea.opts.root != null or b.kea.opts.hidden) return;
    const w = b.window orelse return;
    if (!objc.msg(objc.BOOL, w.nswindow, "isKeyWindow", .{})) return;
    if (activity(b)) |a| objc.msg(void, a, "becomeCurrent", .{});
}

/// The browser's activity brought up to its tab in front, or let go (null)
/// when Handoff is off or the tab may not be offered.
pub fn activity(b: *Browser) ?objc.Object {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = offered(b) orelse {
        forget(b);
        return null;
    };
    const t = b.tabById(b.active_id).?;
    const a = b.handoff_activity orelse made: {
        const a = objc.msg(objc.Object, objc.alloc("NSUserActivity"), "initWithActivityType:", .{NSUserActivityTypeBrowsingWeb});
        b.handoff_activity = a;
        break :made a;
    };
    objc.msg(void, a, "setWebpageURL:", .{url});
    objc.msg(void, a, "setTitle:", .{objc.nsString(t.page_title)});
    return a;
}

/// The tab in front's http(s) address, when Handoff may offer it.
fn offered(b: *Browser) ?objc.Object {
    if (!b.prefs.handoff) return null;
    const t = b.tabById(b.active_id) orelse return null;
    if (isPrivatePage(t)) return null;
    const address = t.address orelse return null;
    const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(address)}) orelse return null;
    const s = objc.fromNSString(objc.msg(?objc.Object, url, "scheme", .{}));
    if (!std.ascii.eqlIgnoreCase(s, "http") and !std.ascii.eqlIgnoreCase(s, "https")) return null;
    return url;
}

/// `isPrivatePage`: a private tab, or a page that keeps nothing.
pub fn isPrivatePage(t: *const Tab) bool {
    if (t.shy) return true;
    const wv = t.web orelse return false;
    const store = objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "websiteDataStore", .{});
    return !objc.msg(objc.BOOL, store, "isPersistent", .{});
}

/// The activity invalidated and let go (`Browser.destroy` too).
pub fn forget(b: *Browser) void {
    const a = b.handoff_activity orelse return;
    objc.msg(void, a, "invalidate", .{});
    objc.release(a);
    b.handoff_activity = null;
}

/// File › Share…: the picker hangs from the top right corner of the page,
/// about where Safari keeps its Share button, a few points in so its arrow
/// points at the page; the window's own corner is the fallback.
pub fn share(b: *Browser) void {
    const t = b.tabById(b.active_id) orelse return;
    const address = t.address orelse return;
    const w = b.window orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(address)}) orelse return;
    const in_window = if (t.web) |wv| objc.msg(?objc.Object, wv, "window", .{}) == w.nswindow else false;
    const view = if (in_window) t.web.? else objc.msg(?objc.Object, w.nswindow, "contentView", .{}) orelse return;
    const bounds = objc.msg(objc.CGRect, view, "bounds", .{});
    const flipped = objc.msg(objc.BOOL, view, "isFlipped", .{});
    const inset: f64 = 12;
    const anchor: objc.CGRect = .{
        .origin = .{ .x = bounds.origin.x + bounds.size.width - inset, .y = if (flipped) inset else bounds.origin.y + bounds.size.height - inset },
        .size = .{ .width = 1, .height = 1 },
    };
    const items = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{url});
    const picker = objc.msg(objc.Object, objc.alloc("NSSharingServicePicker"), "initWithItems:", .{items});
    defer objc.release(picker);
    // NSRectEdge: below the anchor, flipped or not.
    const edge: objc.NSUInteger = if (flipped) 3 else 1;
    objc.msg(void, picker, "showRelativeToRect:ofView:preferredEdge:", .{ anchor, view, edge });
}

/// ⌘P. The system's own sheet, which is also where "save as PDF" lives.
/// Runs as a sheet on the key window; never in a test run.
pub fn printPage(b: *Browser) void {
    if (b.kea.opts.root != null or b.kea.opts.hidden) return;
    const t = b.tabById(b.active_id) orelse return;
    if (t.isBlank()) return;
    const wv = t.web orelse return;
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const window = objc.msg(?objc.Object, app, "keyWindow", .{}) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    objc.msg(void, printing(wv, null), "runOperationModalForWindow:delegate:didRunSelector:contextInfo:", .{
        window, @as(?objc.Object, null), @as(?objc.SEL, null), @as(?*anyopaque, null),
    });
}

/// The print job (autoreleased) for a page, or for one frame of it when
/// WebKit names one: a page's own print() in a frame prints that frame.
/// The frame's printing is outside the public framework, so it is asked
/// for first, and a WebKit without it prints the whole page.
pub fn printing(wv: objc.Object, frame: ?objc.Object) objc.Object {
    const info = objc.msg(objc.Object, objc.class("NSPrintInfo"), "sharedPrintInfo", .{});
    objc.msg(void, info, "setHorizontalPagination:", .{@as(objc.NSInteger, 1)}); // NSPrintingPaginationModeFit
    objc.msg(void, info, "setHorizontallyCentered:", .{objc.NO});
    const job = if (frame != null and objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_printOperationWithPrintInfo:forFrame:")}))
        objc.msg(objc.Object, wv, "_printOperationWithPrintInfo:forFrame:", .{ info, frame.? })
    else
        objc.msg(objc.Object, wv, "printOperationWithPrintInfo:", .{info});
    if (objc.msg(?objc.Object, job, "view", .{})) |v| objc.msg(void, v, "setFrame:", .{objc.msg(objc.CGRect, wv, "bounds", .{})});
    return job;
}
