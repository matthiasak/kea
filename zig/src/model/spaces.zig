//! Spaces, switching (`Spaces.swift` 167-341, 600-615): separate rows of
//! tabs in one window, each with its own sign-ins unless it shares the
//! first's. Switching parks the row on screen as it is and brings the
//! other's back — from memory, or asleep from its file. The list itself is
//! `kea.spaces` (`data/spaces.zig`); writing it tells every window.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const Tab = @import("../web/tab.zig").Tab;
const Uuid = @import("../data/json.zig").Uuid;
const data = @import("../data/spaces.zig");
const Space = data.Space;
const session = @import("../data/session.zig");
const groups_ops = @import("groups.zig");
const TabGroup = groups_ops.TabGroup;
const Pair = @import("browser_rows.zig").Pair;

/// A space's row of tabs while another space is on screen.
pub const Parked = struct {
    tabs: std.ArrayList(*Tab) = .empty,
    active: u64 = 0,
    pair: ?Pair = null,
    /// Its groups as its file has them; null when unknown, for the file to say.
    groups: ?std.ArrayList(TabGroup) = null,

    /// Its tabs let go (they are on no stage), and its groups.
    pub fn deinit(row: *Parked, gpa: std.mem.Allocator) void {
        for (row.tabs.items) |t| t.destroy();
        row.tabs.deinit(gpa);
        if (row.groups) |*g| groups_ops.freeGroups(gpa, g);
    }
};

/// The space on screen.
pub fn space(self: *Browser) Space {
    return self.kea.spaces.value[self.kea.spaceIndex(self.space_id) orelse 0];
}

/// Every tab of the spaces not on screen, on `gpa`.
pub fn parkedTabs(self: *Browser, gpa: std.mem.Allocator) ![]*Tab {
    var out: std.ArrayList(*Tab) = .empty;
    errdefer out.deinit(gpa);
    for (self.parked.values()) |row| try out.appendSlice(gpa, row.tabs.items);
    return out.toOwnedSlice(gpa);
}

/// ⌃1–⌃9, and the menu on the space's dot.
pub fn switchSpace(self: *Browser, id: Uuid) void {
    if (!self.prefs.uses_spaces) return;
    enter(self, id);
}

pub fn switchSpaceIndex(self: *Browser, index: usize) void {
    if (index >= self.kea.spaces.value.len) return;
    self.switchSpace(self.kea.spaces.value[index].id);
}

fn enter(self: *Browser, id: Uuid) void {
    if (id.eql(self.space_id)) return;
    const to = self.kea.spaceIndex(id) orelse return;
    if (!self.making_space) self.space_step = if (to > (self.kea.spaceIndex(self.space_id) orelse 0)) 1 else -1;
    self.cancelTabEdit();
    self.writeSession(true);
    const visible = self.visibleTabIDs();
    for (visible) |vid| if (self.tabById(vid)) |t| t.touch();

    // The row on screen is parked as it is, sound and all.
    const leaving: Parked = .{ .tabs = self.tabs, .active = self.active_id, .pair = self.currentPair(), .groups = self.tab_groups };
    self.tabs = .empty;
    self.tab_groups = .empty;
    self.split_right_id = null;
    self.focused_pane = .left;
    const gop = self.parked.getOrPut(self.gpa, self.space_id) catch @panic("OOM");
    if (gop.found_existing) gop.value_ptr.deinit(self.gpa);
    gop.value_ptr.* = leaving;

    self.space_id = id;
    if (self.uses_files) self.store.setString("space.current", &id.string());
    if (self.parked.fetchSwapRemove(id)) |kv| {
        var back = kv.value;
        if (back.tabs.items.len > 0) {
            if (back.groups) |g| self.tab_groups = g;
            self.showRow(back.tabs, back.active, back.pair);
            for (self.visibleTabIDs()) |vid| if (self.tabById(vid)) |t| {
                _ = t.wake();
            };
        } else {
            back.deinit(self.gpa);
            self.showRow(.empty, 0, null);
            self.restoreSession();
        }
    } else {
        self.showRow(.empty, 0, null);
        self.restoreSession();
    }
    self.setEditing(if (self.tabById(self.active_id)) |t| t.isBlank() else true);
    self.setTyped("");
    self.askFocus();
    self.redraw();
}

/// Every other space's row, made ahead of time, for the swipe's preview.
pub fn preloadSpaces(self: *Browser) void {
    for (self.kea.spaces.value) |sp| {
        if (sp.id.eql(self.space_id) or self.parked.contains(sp.id)) continue;
        const row = self.loadRow(sp.id);
        self.parked.put(self.gpa, sp.id, row) catch @panic("OOM");
    }
}

/// The icon a new space gets unless told: the first no space wears yet.
pub fn freeIcon(self: *Browser) []const u8 {
    for (data.icons) |icon| {
        const used = for (self.kea.spaces.value) |sp| {
            if (std.mem.eql(u8, sp.symbol(), icon)) break true;
        } else false;
        if (!used) return icon;
    }
    return "briefcase";
}

/// The list, changed by `edit` on a copy, written for every window.
fn rewrite(self: *Browser, comptime edit: anytype, args: anytype) void {
    var list: std.ArrayList(Space) = .empty;
    defer list.deinit(self.gpa);
    list.appendSlice(self.gpa, self.kea.spaces.value) catch return;
    if (!@call(.auto, edit, .{&list} ++ args)) return;
    data.write(self.kea, list.items);
}

/// A new space, signed in where the others are or with its own sign-ins;
/// on screen, unless a tab was waiting to be sent into it.
pub fn addSpace(self: *Browser, name: []const u8, icon: ?[]const u8, shares_sign_ins: bool) void {
    self.making_space = false;
    const made: Space = .{ .id = Uuid.random(), .name = name, .colour = 0, .icon = icon orelse self.freeIcon(), .sharesSignIns = shares_sign_ins };
    var list: std.ArrayList(Space) = .empty;
    defer list.deinit(self.gpa);
    list.appendSlice(self.gpa, self.kea.spaces.value) catch return;
    list.append(self.gpa, made) catch return;
    data.write(self.kea, list.items);
    if (self.after_space_created) |tid| {
        self.after_space_created = null;
        if (self.tabById(tid)) |t| return self.moveToSpace(t, made.id);
        return;
    }
    self.switchSpace(made.id);
}

/// Dragged to another place among the dots. ⌃1–⌃9 follow the order.
pub fn moveSpace(self: *Browser, id: Uuid, index: usize) void {
    rewrite(self, struct {
        fn f(list: *std.ArrayList(Space), sid: Uuid, to: usize) bool {
            const from = for (list.items, 0..) |s, i| {
                if (s.id.eql(sid)) break i;
            } else return false;
            if (to >= list.items.len or from == to) return false;
            const s = list.orderedRemove(from);
            list.insertAssumeCapacity(to, s);
            return true;
        }
    }.f, .{ id, index });
}

pub fn renameSpace(self: *Browser, id: Uuid, name: []const u8) void {
    if (name.len == 0) return;
    rewrite(self, struct {
        fn f(list: *std.ArrayList(Space), sid: Uuid, n: []const u8) bool {
            for (list.items) |*s| if (s.id.eql(sid)) {
                s.name = n;
                return true;
            };
            return false;
        }
    }.f, .{ id, name });
}

pub fn setSpaceIcon(self: *Browser, id: Uuid, icon: []const u8) void {
    rewrite(self, struct {
        fn f(list: *std.ArrayList(Space), sid: Uuid, i: []const u8) bool {
            for (list.items) |*s| if (s.id.eql(sid)) {
                s.icon = i;
                return true;
            };
            return false;
        }
    }.f, .{ id, icon });
}

/// Where its downloads go; null for the folder in Settings.
pub fn setSpaceDownloads(self: *Browser, id: Uuid, folder: ?[]const u8) void {
    rewrite(self, struct {
        fn f(list: *std.ArrayList(Space), sid: Uuid, path: ?[]const u8) bool {
            for (list.items) |*s| if (s.id.eql(sid)) {
                s.downloads = path;
                return true;
            };
            return false;
        }
    }.f, .{ id, folder });
}

/// A space, its tabs, and its cookies and sign-ins, gone. Never the first.
pub fn deleteSpace(self: *Browser, id: Uuid) void {
    if (id.eql(Uuid.first)) return;
    const at = self.kea.spaceIndex(id) orelse return;
    if (self.space_id.eql(id)) self.switchSpace(Uuid.first);
    dropParked(self, id);
    const shared = self.kea.spaces.value[at].sharesSignIns == true;
    rewrite(self, struct {
        fn f(list: *std.ArrayList(Space), i: usize) bool {
            _ = list.orderedRemove(i);
            return true;
        }
    }.f, .{at});
    session.erase(self.store, id);
    for (self.kea.browsers.items) |other| if (other != self) other.forgetSpace(id);
    self.kea.pins.forget(id);
    // A space signed in with the others has nothing of its own to erase.
    if (!shared) erase(self.kea, id);
}

/// Spaces turned off: back to the first. The others are kept on disk.
pub fn leaveSpaces(self: *Browser) void {
    enter(self, Uuid.first);
    while (self.parked.count() > 0) dropParked(self, self.parked.keys()[0]);
}

/// A space deleted in another window: this window's row there goes.
pub fn forgetSpace(self: *Browser, id: Uuid) void {
    dropParked(self, id);
    const key = id.string();
    if (self.record_rows.fetchSwapRemove(&key)) |kv| {
        self.gpa.free(kv.key);
        self.gpa.free(kv.value);
    }
}

fn dropParked(self: *Browser, id: Uuid) void {
    var kv = self.parked.fetchSwapRemove(id) orelse return;
    kv.value.deinit(self.gpa);
}

// MARK: a deleted space's store (`Spaces.erase`, `Spaces.sweep`)

const erasing_key = "spaces.erasing";
var nothing: u8 = 0;

/// What the store holds — cookies, sign-ins, storage, caches — emptied
/// now; the store itself, which WebKit won't remove while this run holds
/// it, written down and removed by a sweep, now or at the next launch.
pub fn erase(kea: *Kea, id: Uuid) void {
    if (id.eql(Uuid.first)) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    if (kea.dataStore(id)) |store| {
        // The space's downloads would have kept its store, and asked with
        // its cookies again: they go with it (`forgetDownloads(of:)`).
        kea.fetches.forgetStore(store);
        const cls = objc.class("WKWebsiteDataStore");
        const every = objc.msg(objc.Object, cls, "allWebsiteDataTypes", .{});
        const since = objc.msg(objc.Object, objc.class("NSDate"), "distantPast", .{});
        var done = objc.Block(u8, &.{}).init(&nothing, struct {
            fn f(_: *u8) void {}
        }.f);
        objc.msg(void, store, "removeDataOfTypes:modifiedSince:completionHandler:", .{ every, since, &done });
        if (kea.stores.fetchSwapRemove(id)) |kv| objc.release(kv.value);
    }
    // Tests keep their hands off WebKit's stores and the list.
    if (kea.opts.root != null) return;
    const defaults = kea.store.defaults;
    const list = objc.msg(?objc.Object, defaults, "stringArrayForKey:", .{objc.nsString(erasing_key)});
    const set = objc.msg(objc.Object, objc.class("NSMutableSet"), "set", .{});
    if (list) |l| objc.msg(void, set, "addObjectsFromArray:", .{l});
    objc.msg(void, set, "addObject:", .{objc.nsString(&id.string())});
    const sorted = objc.msg(objc.Object, objc.msg(objc.Object, set, "allObjects", .{}), "sortedArrayUsingSelector:", .{objc.sel("compare:")});
    objc.msg(void, defaults, "setObject:forKey:", .{ sorted, objc.nsString(erasing_key) });
    sweep(kea);
}

/// Every deleted space's store still there, tried again; one gone comes
/// off the list. ponytail: tried at launch and on deleting, not again at 3
/// and 15 s; what's left waits for the next launch.
pub fn sweep(kea: *Kea) void {
    if (kea.opts.root != null or kea.opts.headless) return;
    const cls = objc.class("WKWebsiteDataStore");
    if (!objc.msg(objc.BOOL, cls, "respondsToSelector:", .{objc.sel("removeDataStoreForIdentifier:completionHandler:")})) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const list = objc.msg(?objc.Object, kea.store.defaults, "stringArrayForKey:", .{objc.nsString(erasing_key)}) orelse return;
    const n = objc.msg(objc.NSUInteger, list, "count", .{});
    for (0..n) |i| {
        const text = objc.msg(objc.Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const id = Uuid.parse(objc.fromNSString(text)) catch continue;
        const ctx = std.heap.c_allocator.create(Swept) catch return;
        ctx.* = .{ .defaults = objc.retain(kea.store.defaults), .id = id };
        const uuid = objc.msg(objc.Object, objc.alloc("NSUUID"), "initWithUUIDBytes:", .{&id.bytes});
        defer objc.release(uuid);
        var done = objc.Block(Swept, &.{?objc.Object}).init(ctx, Swept.done);
        objc.msg(void, cls, "removeDataStoreForIdentifier:completionHandler:", .{ uuid, &done });
    }
}

const Swept = struct {
    defaults: objc.Object,
    id: Uuid,

    fn done(s: *Swept, err: ?objc.Object) void {
        defer std.heap.c_allocator.destroy(s);
        defer objc.release(s.defaults);
        if (err != null) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const list = objc.msg(?objc.Object, s.defaults, "stringArrayForKey:", .{objc.nsString(erasing_key)}) orelse return;
        const left = objc.msg(objc.Object, list, "mutableCopy", .{});
        defer objc.release(left);
        objc.msg(void, left, "removeObject:", .{objc.nsString(&s.id.string())});
        objc.msg(void, s.defaults, "setObject:forKey:", .{ left, objc.nsString(erasing_key) });
    }
};
