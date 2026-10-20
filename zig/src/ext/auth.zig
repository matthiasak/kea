//! `ExtensionAuth` (ExtensionShims.swift 4351-4449):
//! chrome.identity.launchWebAuthFlow — a tab for the provider's sign-in, and
//! the moment it tries to go to https://<id>.chromiumapp.org/, that address
//! is the answer and the tab goes. The nav delegate asks `intercept` about
//! every navigation; nothing is ever loaded from chromiumapp.org.
const std = @import("std");
const objc = @import("nanoui").objc;
const value = @import("value.zig");
const Kea = @import("../app/kea.zig").Kea;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Parts = @import("../data/url.zig").Parts;
const controller = @import("controller.zig");

const suffix = ".chromiumapp.org";

/// `Declined`.
pub const declined = "The user did not approve access.";

const Waiting = struct { tab: u64, reply: value.Reply };
/// Flows by extension id (keys on the C allocator; main thread only).
var waiting: std.StringArrayHashMapUnmanaged(Waiting) = .empty;
const gpa = std.heap.c_allocator;

/// Takes the flow for `id` out of `waiting`, its key freed.
fn take(id: []const u8) ?Waiting {
    const kv = waiting.fetchSwapRemove(id) orelse return null;
    gpa.free(kv.key);
    return kv.value;
}

/// `run`: answers `reply` with the address the sign-in came back to (an
/// NSString), or fails with `declined` (or `mayOpen`'s refusal).
pub fn run(url: []const u8, ext_id: []const u8, browser: *Browser, reply: value.Reply) void {
    if (@import("controller_delegate_frames.zig").mayOpen(url)) |why| return reply.fail(why);
    if (take(ext_id)) |before| before.reply.fail(declined);
    const tab = browser.open(url, .{ .foreground = true });
    const key = gpa.dupe(u8, ext_id) catch return reply.fail(declined);
    waiting.put(gpa, key, .{ .tab = tab.id, .reply = reply }) catch {
        gpa.free(key);
        return reply.fail(declined);
    };
    // Closing the tab is saying no. Moved to another window, or to a space
    // not on screen, it is still there.
    const w = gpa.create(Watch) catch return;
    w.* = .{ .kea = browser.kea, .id = gpa.dupe(u8, ext_id) catch return gpa.destroy(w), .tab = tab.id, .started = now() };
    objc.dispatchAfter(std.time.ns_per_s, w, Watch.tick);
}

/// One per flow, ticking each second while its flow waits on its tab.
const Watch = struct {
    kea: *Kea,
    id: []u8,
    tab: u64,
    started: f64,

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Watch = @ptrCast(@alignCast(ctx.?));
        const entry = waiting.get(w.id);
        const live = entry != null and entry.?.tab == w.tab;
        // Ten minutes with nobody finishing: no longer watched for either.
        if (live and exists(w.kea, w.tab) and now() - w.started <= 600) {
            objc.dispatchAfter(std.time.ns_per_s, w, tick);
            return;
        }
        if (live) take(w.id).?.reply.fail(declined);
        gpa.free(w.id);
        gpa.destroy(w);
    }
};

fn now() f64 {
    return @import("../data/json.zig").now();
}

fn exists(kea: *Kea, id: u64) bool {
    for (kea.browsers.items) |b| {
        if (b.tabById(id) != null) return true;
        for (b.parked.values()) |row| for (row.tabs.items) |t| if (t.id == id) return true;
    }
    return false;
}

/// The extension id of an https://<id>.chromiumapp.org address, in `buf`.
fn flowId(buf: []u8, url: []const u8) ?[]const u8 {
    const p = Parts.parse(url) orelse return null;
    if (!p.schemeIs("https")) return null;
    const host = p.hostName() orelse return null;
    if (host.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf, host);
    if (!std.mem.endsWith(u8, lower, suffix)) return null;
    return lower[0 .. lower.len - suffix.len];
}

/// True when `url` is an extension's OAuth redirect arriving in the tab
/// that began the sign-in (or a window that tab's page opened — some
/// providers finish in a popup), which is then handed over and never
/// loaded. Any page can go to such an address; only those may finish it.
pub fn intercept(url: []const u8, browser: *Browser, from: *Tab) bool {
    var buf: [256]u8 = undefined;
    const id = flowId(&buf, url) orelse return false;
    const entry = waiting.get(id) orelse return false;
    if (!(from.id == entry.tab or from.opener == entry.tab)) return false;
    _ = take(id);
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        entry.reply.ok(objc.nsString(url));
    }
    // The popup, when the answer came in one, goes with the flow's tab:
    // left behind, it would hold a redirect that never loads. Closed once
    // WebKit is out of this navigation's decision.
    const c = gpa.create(Closing) catch return true;
    c.* = .{ .kea = browser.kea, .popup = if (from.id != entry.tab) from.serial else null, .flow = entry.tab };
    objc.dispatchMain(c, Closing.run);
    return true;
}

const Closing = struct {
    kea: *Kea,
    popup: ?u64,
    flow: u64,

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const c: *Closing = @ptrCast(@alignCast(ctx.?));
        defer gpa.destroy(c);
        if (c.popup) |serial| if (Tab.alive(serial)) |t| if (t.browser) |b| b.close(t);
        // The flow's tab, in whichever window it is now.
        for (c.kea.browsers.items) |home| if (home.tabById(c.flow)) |t| home.close(t);
    }
};

/// The same redirect with no launchWebAuthFlow waiting for it (an extension
/// that opened the provider with tabs.create and watches the tab's address,
/// Figma's): the tab takes the address without loading anything, for an
/// installed extension that asked for identity. Left open, it says what
/// Chrome's would.
pub fn handOver(url: []const u8, main_frame: bool, from: *Tab) bool {
    if (!main_frame) return false;
    var buf: [256]u8 = undefined;
    const id = flowId(&buf, url) orelse return false;
    const owner = controller.of(from.kea) orelse return false;
    const context = owner.contexts.get(id) orelse return false;
    if (!@import("shims/answer.zig").allows(owner, id, context, "identity")) return false;
    hold(from, url);
    const copy = gpa.dupeSentinel(u8, url, 0) catch return true;
    from.afterOwned(4, unheld, @intFromPtr(copy.ptr), dropCopy);
    return true;
}

fn unpack(arg: usize) [:0]u8 {
    const ptr: [*:0]u8 = @ptrFromInt(arg);
    return std.mem.span(ptr);
}

fn dropCopy(arg: usize) void {
    gpa.free(unpack(arg));
}

fn unheld(t: *Tab, arg: usize) void {
    const url = unpack(arg);
    defer gpa.free(url);
    const held = t.held_url orelse return;
    if (!std.mem.eql(u8, held, url)) return;
    t.setFailure("Nothing lives at that address — not even a kea.");
    t.changed(.state);
}

/// `Tab.hold`: an address the tab shows, and reports to extensions,
/// without loading it. The page on screen stays; WebKit going back to that
/// page's address as the cancelled load unwinds is not a move (`heldStays`).
pub fn hold(t: *Tab, url: []const u8) void {
    t.own(&t.held_url, url);
    var over: ?[]const u8 = null;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (t.web) |wv| if (objc.msg(?objc.Object, objc.msg(objc.Object, wv, "backForwardList", .{}), "currentItem", .{})) |item| {
        if (objc.msg(?objc.Object, item, "URL", .{})) |u| over = objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
    };
    t.own(&t.held_over, over);
    t.own(&t.address, url);
    t.setFailure(null);
    t.changed(.address);
}

/// The URL observer's half (Tab.swift 667-670): true when `fresh` is only
/// the held-over page coming back, which is no move; else the hold ends.
pub fn heldStays(t: *Tab, fresh: []const u8) bool {
    if (t.held_url == null) return false;
    if (t.held_over) |over| if (std.mem.eql(u8, over, fresh)) return true;
    t.own(&t.held_url, null);
    return false;
}

/// `didCommit`'s half (Tab.swift 297-301): a page arrived after all, so
/// the address is its own again.
pub fn arrived(t: *Tab, url: ?[]const u8) void {
    if (t.held_url == null) return;
    const u = url orelse return;
    if (u.len == 0 or std.mem.eql(u8, u, "about:blank")) return;
    t.own(&t.held_url, null);
    t.own(&t.address, u);
}
