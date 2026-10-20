//! A tab swapped where it stands for one built from another configuration
//! (Browser.swift 2617-2630, 3382-3418): an extension's page needs a view
//! made from that extension's configuration, a website one made from the
//! web's — WebKit keeps each to its own.
const std = @import("std");
const objc = @import("nanoui").objc;
const Browser = @import("browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const ext = @import("../ext/ext.zig");
const configurationFor = @import("../ext/controller.zig").configurationFor;

/// `Browser.page(_:)`: the chrome-extension:// address of a
/// webkit-extension:// one; else `url` itself. Free when `ptr` differs.
fn page(gpa: std.mem.Allocator, url: []const u8) []const u8 {
    return ext.current(gpa, url) catch url;
}

/// A window's extension state (`Browser.extensionPopup`, `namedDownloads`).
pub const State = struct {
    /// A popup window's extension (windows.create "popup"); gpa.
    popup: ?[]u8 = null,
    /// url → the name an extension asked it be saved as (ext/downloads.zig).
    named_downloads: std.StringHashMapUnmanaged([]u8) = .empty,
};

/// The window going: WebKit told, its extension state let go.
pub fn destroy(self: *Browser) void {
    if (self.kea.ext) |e| e.detach(self);
    if (self.ext.popup) |p| self.gpa.free(p);
    @import("../ext/downloads.zig").deinit(self);
}

/// `Tab.onCross` (Tab.swift:984-992): a tab in a window's row going between
/// the web and an extension's pages, or between two extensions', judged by
/// the page it shows, is swapped for one built for where it goes. The swap
/// waits a turn: `go`'s caller may still touch the tab, which it frees.
/// True when it will be swapped (nothing loads in it now).
pub fn crosses(tab: *Tab, target: []const u8) bool {
    const b = tab.browser orelse return false;
    if (b.indexOf(tab) == null) return false;
    const pool = objc.Pool.push();
    defer pool.pop();
    const shown: ?objc.Object = if (tab.web) |w| objc.msg(?objc.Object, w, "URL", .{}) else null;
    const here = if (shown) |u| objc.fromNSString(objc.msg(objc.Object, u, "absoluteString", .{})) else tab.address orelse return false;
    const from = ext.idOf(here);
    const to = ext.idOf(target);
    if (from == null and to == null) return false;
    if (from != null and to != null and std.mem.eql(u8, from.?, to.?)) return false;
    const c = std.heap.c_allocator.create(Cross) catch return false;
    c.* = .{ .tab = tab.serial, .url = std.heap.c_allocator.dupe(u8, target) catch {
        std.heap.c_allocator.destroy(c);
        return false;
    } };
    objc.dispatchMain(c, Cross.fire);
    return true;
}

const Cross = struct {
    tab: u64,
    url: []u8,

    fn fire(p: ?*anyopaque) callconv(.c) void {
        const c: *Cross = @ptrCast(@alignCast(p.?));
        defer {
            std.heap.c_allocator.free(c.url);
            std.heap.c_allocator.destroy(c);
        }
        const tab = Tab.alive(c.tab) orelse return;
        const b = tab.browser orelse return;
        replace(b, tab, c.url);
    }
};

/// `replace(_:going:)`: an extension's page sending its own tab to a
/// website (1Password's "Sign in"), or a website's tab to an extension's
/// page. Swapped for a fresh tab that keeps what you made of it.
pub fn replace(self: *Browser, tab: *Tab, url_: []const u8) void {
    const index = self.indexOf(tab) orelse return;
    const url = page(self.gpa, url_);
    defer if (url.ptr != url_.ptr) self.gpa.free(url);
    const pool = objc.Pool.push();
    defer pool.pop();
    const kea = self.kea;
    const id = kea.tabId();
    const fresh = blk: {
        if (configurationFor(kea, url)) |c| break :blk Tab.createWith(self.gpa, id, tab.shy, c, kea);
        if (!tab.shy) break :blk Tab.create(self.gpa, id, false, kea.dataStore(self.space_id), kea);
        // A private tab stays private, and keeps its own sign-ins when it
        // had them; an extension's page it showed was in that extension's store.
        const c = @import("../web/config.zig").configuration(kea, true, null);
        defer objc.release(c);
        if (tab.configuration) |old| {
            const store = objc.msg(objc.Object, old, "websiteDataStore", .{});
            if (!objc.msg(objc.BOOL, store, "isPersistent", .{})) objc.msg(void, c, "setWebsiteDataStore:", .{store});
        }
        break :blk Tab.createWith(self.gpa, id, true, c, kea);
    } catch @panic("OOM");
    // The sign-in popup's link to its opener, and a pin or name, kept.
    fresh.opener = tab.opener;
    fresh.popup = tab.popup;
    fresh.own(&fresh.pin, tab.pin);
    fresh.pin_id = tab.pin_id;
    fresh.listed = tab.listed;
    fresh.setName(tab.name);
    self.prepare(fresh);
    fresh.group_id = tab.group_id;
    swapIn(self, index, tab, fresh, url);
}

/// `replaceBlank(_:with:)`: a blank tab given an extension's new tab page.
pub fn replaceBlank(self: *Browser, tab: *Tab, url_: []const u8) void {
    const index = self.indexOf(tab) orelse return;
    const url = page(self.gpa, url_);
    defer if (url.ptr != url_.ptr) self.gpa.free(url);
    const pool = objc.Pool.push();
    defer pool.pop();
    const kea = self.kea;
    const id = kea.tabId();
    const fresh = (if (configurationFor(kea, url)) |c|
        Tab.createWith(self.gpa, id, false, c, kea)
    else
        Tab.create(self.gpa, id, false, kea.dataStore(self.space_id), kea)) catch @panic("OOM");
    self.prepare(fresh);
    fresh.group_id = tab.group_id;
    if (self.active_id == tab.id) self.setEditing(false);
    swapIn(self, index, tab, fresh, url);
}

fn swapIn(self: *Browser, index: usize, old: *Tab, fresh: *Tab, url: []const u8) void {
    const was_active = self.active_id == old.id;
    @import("split.zig").replaceSplitMember(self, old.id, fresh.id);
    self.tabs.items[index] = fresh;
    fresh.go(url);
    if (was_active) self.setActive(fresh.id);
    self.letGo(old);
    self.rememberSession();
    self.redraw();
}
