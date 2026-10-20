//! Tab groups for extensions (ExtensionShims.swift 4046-4102, `listedGroups`
//! 3301-3320). Only while they are on (Settings › Tabs): off, they sleep,
//! for extensions as on screen. A group without a tab is never shown.
const std = @import("std");
const ans = @import("answer.zig");
const groups = @import("../../model/groups.zig");
const Browser = @import("../../model/browser.zig").Browser;
const Tab = @import("../../web/tab.zig").Tab;
const Uuid = @import("../../data/json.zig").Uuid;
const located = @import("tabs.zig").located;
const Call = ans.Call;
pub const TabGroup = groups.TabGroup;

/// A group as Chrome describes it. Kea's groups have no colour; grey is Chrome's first.
pub const ChromeGroup = struct {
    id: u32,
    title: []const u8,
    collapsed: bool,
    color: []const u8 = "grey",
    windowId: i64 = 1,
    shared: bool = false,
};

pub fn chromeGroup(g: TabGroup) ChromeGroup {
    return .{ .id = groups.number(g.id), .title = g.name, .collapsed = g.collapsed };
}

/// The groups an extension is shown: none while groups are off, never one without a tab.
fn listedGroups(a: std.mem.Allocator, browser: *Browser) ![]TabGroup {
    var out: std.ArrayList(TabGroup) = .empty;
    if (!browser.prefs.uses_tab_groups) return out.items;
    for (browser.tab_groups.items) |g| {
        const members = try browser.tabsIn(a, g.id);
        if (members.len > 0) try out.append(a, g);
    }
    return out.items;
}

fn listedGroup(c: *Call, number: ?std.json.Value, browser: *Browser) ans.Error!TabGroup {
    if (ans.int(number)) |n| for (try listedGroups(c.a, browser)) |g| {
        if (groups.number(g.id) == n) return g;
    };
    if (ans.int(number)) |n| return c.fail("No group with id: {d}.", .{n});
    if (ans.str(number)) |s| return c.fail("No group with id: {s}.", .{s});
    if (ans.num(number)) |f| return c.fail("No group with id: {d}.", .{f});
    return c.fail("No group with id: none.", .{});
}

pub fn run(c: *Call) ans.Error!?ans.Out {
    const eql = std.mem.eql;
    const api = c.api;
    const browser = c.browser;
    const a = c.a;
    if (eql(u8, api, "tabs.groups")) {
        const places = ans.list(c.first()) orelse &.{};
        const out = try a.alloc(i64, places.len);
        for (places, out) |place, *o| {
            o.* = -1;
            if (!browser.prefs.uses_tab_groups) continue;
            const tab = located(c.owner, place) orelse continue;
            const home = c.owner.browserOf(tab) orelse continue;
            if (home.groupOf(tab)) |g| o.* = groups.number(g);
        }
        return c.give(out);
    } else if (eql(u8, api, "tabGroups.query")) {
        const spec = c.first();
        var out: std.ArrayList(ChromeGroup) = .empty;
        for (try listedGroups(a, browser)) |g| {
            if (ans.str(ans.field(spec, "title"))) |t| if (!eql(u8, t, g.name)) continue;
            if (ans.flag(ans.field(spec, "collapsed"))) |f| if (f != g.collapsed) continue;
            if (ans.str(ans.field(spec, "color"))) |col| if (!eql(u8, col, "grey")) continue;
            try out.append(a, chromeGroup(g));
        }
        return c.give(out.items);
    } else if (eql(u8, api, "tabGroups.get")) {
        return c.give(chromeGroup(try listedGroup(c, c.first(), browser)));
    } else if (eql(u8, api, "tabGroups.update")) {
        const g = try listedGroup(c, c.first(), browser);
        const props = c.arg(1);
        if (ans.str(ans.field(props, "title"))) |t| browser.renameTabGroup(g.id, t);
        if (ans.flag(ans.field(props, "collapsed"))) |f| if (f != g.collapsed) browser.toggleTabGroup(g.id);
        // Read again: renaming frees the old name.
        const now = browser.groupById(g.id) orelse return c.fail("No group with id: {d}.", .{groups.number(g.id)});
        return c.give(chromeGroup(now.*));
    } else if (eql(u8, api, "tabGroups.move")) {
        return c.fail(ans.app_name ++ " can't move a tab group for an extension", .{});
    } else if (eql(u8, api, "tabs.group")) {
        if (!browser.prefs.uses_tab_groups) return c.fail("Tab groups are off in " ++ ans.app_name ++ "'s settings", .{});
        var tabs: std.ArrayList(*Tab) = .empty;
        for (ans.list(c.first()) orelse &.{}) |place| if (located(c.owner, place)) |t| try tabs.append(a, t);
        if (tabs.items.len == 0) return c.fail("No tabs to group", .{});
        // A group is one window's, as in Chrome.
        const home = c.owner.browserOf(tabs.items[0]) orelse return c.fail("Tabs from different windows can't share a group", .{});
        for (tabs.items) |t| if (c.owner.browserOf(t) != home) return c.fail("Tabs from different windows can't share a group", .{});
        // Pins and private tabs are never in a group in Kea.
        for (tabs.items) |t| if (t.pin != null or t.shy) return c.fail("Pinned and private tabs can't be grouped", .{});
        const n = ans.int(c.arg(1)) orelse -1;
        const target: Uuid = if (n != -1) (try listedGroup(c, c.arg(1), home)).id else fresh(home, tabs.items[0]);
        for (tabs.items) |t| home.moveToGroup(t, target);
        return c.give(groups.number(target));
    } else if (eql(u8, api, "tabs.ungroup")) {
        if (!browser.prefs.uses_tab_groups) return ans.none;
        for (ans.list(c.first()) orelse &.{}) |place| if (located(c.owner, place)) |t| {
            if (c.owner.browserOf(t)) |home| home.moveToGroup(t, null);
        };
        return ans.none;
    }
    return null;
}

/// A new group, as its menu makes one, without its name to type.
fn fresh(browser: *Browser, tab: *Tab) Uuid {
    const id = browser.addTabGroup(tab);
    browser.editing_group_id = null;
    return id;
}
