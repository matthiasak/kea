//! The ad blocker (Shield.swift): one content rule list, compiled once per
//! rule change into `WKContentRuleListStore` and looked up after that, put on
//! every tab's controller, and taken off for the sites it is paused on
//! (`shield.paused`). Tests (`opts.root` set) compile into a store under the
//! temp root, never the app's.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("../data/json.zig");
const Store = @import("../data/store.zig").Store;
const Kea = @import("../app/kea.zig").Kea;

/// Third parties whose only job is to watch or to sell.
const unwanted = [_][]const u8{
    "doubleclick.net",       "googlesyndication.com", "googleadservices.com",
    "googletagservices.com", "google-analytics.com",  "googletagmanager.com",
    "adservice.google.com",  "amazon-adsystem.com",   "adnxs.com",
    "adsrvr.org",            "criteo.com",            "criteo.net",
    "taboola.com",           "outbrain.com",          "rubiconproject.com",
    "pubmatic.com",          "openx.net",             "casalemedia.com",
    "smartadserver.com",     "sharethrough.com",      "indexww.com",
    "bidswitch.net",         "33across.com",          "teads.tv",
    "moatads.com",           "adroll.com",            "scorecardresearch.com",
    "quantserve.com",        "chartbeat.com",         "hotjar.com",
    "mouseflow.com",         "fullstory.com",         "clarity.ms",
    "mixpanel.com",          "amplitude.com",         "segment.com",
    "segment.io",            "branch.io",             "appsflyer.com",
    "adjust.com",            "analytics.tiktok.com",  "connect.facebook.net",
    "ads-twitter.com",       "analytics.twitter.com",
};

/// The few slots that are reliably an advertisement, and the boxes a site
/// keeps open for one (whole EasyList class names).
const slots = [_][]const u8{
    ".adsbygoogle",                      "ins.adsbygoogle",                 "[id^=\"google_ads_\"]",
    "[id^=\"div-gpt-ad\"]",              "[id^=\"taboola-\"]",              "#taboola-below-article",
    "iframe[src*=\"doubleclick.net\"]",  "iframe[src*=\"googlesyndication\"]",
    "iframe[src*=\"amazon-adsystem\"]",  ".ad-slot",
    ".ad-slot-container",                ".top-banner-ad-container",        ".ad-leaderboard",
    ".ad-billboard",                     ".ad-giga",                        ".ad-mpu",
    ".ad-mrec",                          ".ad-unit",                        ".adunit",
    ".adslot",                           ".dfp-ad",                         ".gpt-ad",
    ".w_ad",
};

/// Slots too plain to hide everywhere, hidden only where EasyList does.
const slots_by_site = [_]struct { sites: []const []const u8, selector: []const u8 }{
    .{ .sites = &.{ "*as.com", "*elpais.com" }, .selector = ".ad" },
    .{ .sites = &.{"*theguardian.com"}, .selector = ".top-fronts-banner-ad-container" },
    .{ .sites = &.{ "*independent.co.uk", "*the-independent.com" }, .selector = "#billboard-wrapper" },
    .{ .sites = &.{"*cnn.com"}, .selector = ".ad-slot-header__wrapper" },
};

const Trigger = struct {
    @"url-filter": []const u8,
    @"load-type": ?[]const []const u8 = null,
    @"if-domain": ?[]const []const u8 = null,
};
const Action = struct { type: []const u8, selector: ?[]const u8 = null };
const Rule = struct { trigger: Trigger, action: Action };

/// The rules as WebKit reads them, keys sorted (`.sortedKeys`). On `a`.
pub fn rulesJson(a: std.mem.Allocator) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    var rules: std.ArrayList(Rule) = .empty;
    for (unwanted) |domain| {
        const escaped = try std.mem.replaceOwned(u8, ar, domain, ".", "\\.");
        try rules.append(ar, .{
            .trigger = .{ .@"url-filter" = try std.fmt.allocPrint(ar, "^https?://([^/]+\\.)?{s}", .{escaped}), .@"load-type" = &.{"third-party"} },
            .action = .{ .type = "block" },
        });
    }
    try rules.append(ar, .{ .trigger = .{ .@"url-filter" = ".*" }, .action = .{ .type = "css-display-none", .selector = try std.mem.join(ar, ", ", &slots) } });
    for (slots_by_site) |entry| try rules.append(ar, .{
        .trigger = .{ .@"url-filter" = ".*", .@"if-domain" = entry.sites },
        .action = .{ .type = "css-display-none", .selector = entry.selector },
    });
    return json.encodeSorted(a, rules.items);
}

/// Shields still alive, for answers WebKit gives after a Kea has gone.
var live: std.AutoHashMapUnmanaged(*Shield, void) = .empty;
const ca = std.heap.c_allocator;

pub const Shield = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    /// The temp root under tests: the rule store lives there.
    root: ?[]const u8,
    /// The compiled list (retained), once there is one.
    list: ?objc.Object = null,
    /// Controllers that asked before it was ready (retained).
    waiting: std.ArrayList(objc.Object) = .empty,
    /// On or off, per controller (`NSMapTable`, weak keys).
    tuned: objc.Object,
    /// Why compiling didn't work, the one thing worth telling (on `gpa`).
    trouble: ?[]u8 = null,
    enabled: bool = true,
    /// Sites it is off for (`shield.paused`).
    paused: std.ArrayList([]u8) = .empty,

    pub fn init(self: *Shield, gpa: std.mem.Allocator, store: *Store, root: ?[]const u8, enabled: bool) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        self.* = .{
            .gpa = gpa,
            .store = store,
            .root = root,
            .enabled = enabled,
            .tuned = objc.retain(objc.msg(objc.Object, objc.class("NSMapTable"), "weakToStrongObjectsMapTable", .{})),
        };
        if (objc.msg(?objc.Object, store.defaults, "stringArrayForKey:", .{objc.nsString("shield.paused")})) |list| {
            const n = objc.msg(objc.NSUInteger, list, "count", .{});
            for (0..n) |i| {
                const host = gpa.dupe(u8, objc.fromNSString(objc.msg(objc.Object, list, "objectAtIndex:", .{i}))) catch continue;
                self.paused.append(gpa, host) catch gpa.free(host);
            }
        }
        live.put(ca, self, {}) catch {};
    }

    pub fn deinit(self: *Shield) void {
        _ = live.remove(self);
        if (self.list) |l| objc.release(l);
        for (self.waiting.items) |c| objc.release(c);
        self.waiting.deinit(self.gpa);
        objc.release(self.tuned);
        for (self.paused.items) |h| self.gpa.free(h);
        self.paused.deinit(self.gpa);
        self.setTrouble(null);
    }

    fn setTrouble(self: *Shield, said: ?[]const u8) void {
        if (self.trouble) |t| self.gpa.free(t);
        self.trouble = if (said) |s| self.gpa.dupe(u8, s) catch null else null;
    }

    pub fn isPaused(self: *const Shield, host: ?[]const u8) bool {
        const h = host orelse return false;
        for (self.paused.items) |p| if (std.mem.eql(u8, p, h)) return true;
        return false;
    }

    pub fn pause(self: *Shield, host: []const u8, off: bool) void {
        const at = for (self.paused.items, 0..) |p, i| {
            if (std.mem.eql(u8, p, host)) break i;
        } else null;
        if (at) |i| {
            if (!off) self.gpa.free(self.paused.orderedRemove(i));
        } else if (off) {
            const copy = self.gpa.dupe(u8, host) catch return;
            self.paused.append(self.gpa, copy) catch return self.gpa.free(copy);
        }
        std.mem.sort([]u8, self.paused.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        const pool = objc.Pool.push();
        defer pool.pop();
        const array = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
        for (self.paused.items) |h| objc.msg(void, array, "addObject:", .{objc.nsString(h)});
        objc.msg(void, self.store.defaults, "setObject:forKey:", .{ array, objc.nsString("shield.paused") });
    }

    fn wasTuned(self: *Shield, ucc: objc.Object) ?bool {
        const n = objc.msg(?objc.Object, self.tuned, "objectForKey:", .{ucc}) orelse return null;
        return objc.msg(objc.BOOL, n, "boolValue", .{});
    }

    fn setTuned(self: *Shield, ucc: objc.Object, on: bool) void {
        objc.msg(void, self.tuned, "setObject:forKey:", .{ objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{on}), ucc });
    }

    /// Before each page: on or off for the site the tab is heading to.
    pub fn tune(self: *Shield, ucc: objc.Object, host: ?[]const u8) void {
        const list = self.list orelse return;
        const want = self.enabled and !self.isPaused(host);
        if (self.wasTuned(ucc) == want) return;
        self.setTuned(ucc, want);
        objc.msg(void, ucc, "removeContentRuleList:", .{list});
        if (want) objc.msg(void, ucc, "addContentRuleList:", .{list});
    }

    /// Every tab asks for it; whoever asks before it is ready is remembered.
    pub fn protect(self: *Shield, ucc: objc.Object) void {
        if (self.list) |list| {
            if (!self.enabled) return;
            objc.msg(void, ucc, "addContentRuleList:", .{list});
            self.setTuned(ucc, true);
        } else self.waiting.append(self.gpa, objc.retain(ucc)) catch objc.release(ucc);
    }

    /// Switched on or off for every page already open.
    pub fn apply(self: *Shield, ucc: objc.Object) void {
        const list = self.list orelse return;
        objc.msg(void, ucc, "removeContentRuleList:", .{list});
        self.setTuned(ucc, self.enabled);
        if (self.enabled) objc.msg(void, ucc, "addContentRuleList:", .{list});
    }

    fn adopt(self: *Shield, ready: objc.Object) void {
        if (self.list) |old| objc.release(old);
        self.list = objc.retain(ready);
        for (self.waiting.items) |ucc| {
            if (self.enabled) {
                objc.msg(void, ucc, "addContentRuleList:", .{ready});
                self.setTuned(ucc, true);
            }
            objc.release(ucc);
        }
        self.waiting.clearRetainingCapacity();
    }

    fn ruleStore(self: *const Shield) ?objc.Object {
        const cls = objc.class("WKContentRuleListStore");
        const root = self.root orelse return objc.msg(?objc.Object, cls, "defaultStore", .{});
        const path = std.fs.path.join(self.gpa, &.{ root, "ContentRules" }) catch return null;
        defer self.gpa.free(path);
        const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:isDirectory:", .{ objc.nsString(path), objc.YES });
        return objc.msg(?objc.Object, cls, "storeWithURL:", .{url});
    }

    /// `compile()`: looked up by the rules' hash, compiled when missing,
    /// and every older list let go.
    pub fn compile(self: *Shield) void {
        if (self.list != null) return;
        self.setTrouble(null);
        const pool = objc.Pool.push();
        defer pool.pop();
        const rules = rulesJson(self.gpa) catch return self.setTrouble("Couldn't build the block list");
        defer self.gpa.free(rules);
        const store = self.ruleStore() orelse return self.setTrouble("WebKit has nowhere to compile it");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(rules, &digest, .{});
        const name: [11 + 64]u8 = ("kea-shield-" ++ std.fmt.bytesToHex(digest, .lower)).*;
        const ns_name = objc.nsString(&name);
        const ask = ca.create(Ask) catch return;
        ask.* = .{ .shield = self, .store = objc.retain(store), .name = objc.retain(ns_name), .rules = objc.retain(objc.nsString(rules)) };
        var found = ListBlock.init(ask, lookedUp);
        objc.msg(void, store, "lookUpContentRuleListForIdentifier:completionHandler:", .{ ns_name, @as(*anyopaque, @ptrCast(&found)) });
        const sweep = ca.create(Ask) catch return;
        sweep.* = .{ .shield = self, .store = objc.retain(store), .name = objc.retain(ns_name), .rules = null };
        var ids = IdsBlock.init(sweep, listed);
        objc.msg(void, store, "getAvailableContentRuleListIdentifiers:", .{@as(*anyopaque, @ptrCast(&ids))});
    }
};

const Ask = struct {
    shield: *Shield,
    store: objc.Object,
    name: objc.Object,
    rules: ?objc.Object,

    fn done(self: *Ask) void {
        objc.release(self.store);
        objc.release(self.name);
        if (self.rules) |r| objc.release(r);
        ca.destroy(self);
    }
};
const ListBlock = objc.Block(Ask, &.{ ?objc.Object, ?objc.Object });
const IdsBlock = objc.Block(Ask, &.{?objc.Object});
const Nothing = struct {};
const ErrBlock = objc.Block(Nothing, &.{?objc.Object});
var nothing: Nothing = .{};

fn lookedUp(ask: *Ask, found: ?objc.Object, _: ?objc.Object) void {
    if (!live.contains(ask.shield)) return ask.done();
    if (found) |list| {
        ask.shield.adopt(list);
        return ask.done();
    }
    var block = ListBlock.init(ask, compiled);
    objc.msg(void, ask.store, "compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:", .{ ask.name, ask.rules.?, @as(*anyopaque, @ptrCast(&block)) });
}

fn compiled(ask: *Ask, list: ?objc.Object, err: ?objc.Object) void {
    defer ask.done();
    if (!live.contains(ask.shield)) return;
    const s = ask.shield;
    const got = list orelse {
        const said = if (err) |e| objc.fromNSString(objc.msg(?objc.Object, e, "localizedDescription", .{})) else "";
        s.setTrouble(if (said.len > 0) said else "Compiling the block list failed");
        for (s.waiting.items) |ucc| objc.release(ucc);
        s.waiting.clearRetainingCapacity();
        return;
    };
    s.adopt(got);
}

fn listed(ask: *Ask, ids: ?objc.Object) void {
    defer ask.done();
    const list = ids orelse return;
    const keep = objc.fromNSString(ask.name);
    const n = objc.msg(objc.NSUInteger, list, "count", .{});
    for (0..n) |i| {
        const id = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
        const s = objc.fromNSString(id);
        if (!std.mem.startsWith(u8, s, "kea-shield") or std.mem.eql(u8, s, keep)) continue;
        var block = ErrBlock.init(&nothing, ignore);
        objc.msg(void, ask.store, "removeContentRuleListForIdentifier:completionHandler:", .{ id, @as(*anyopaque, @ptrCast(&block)) });
    }
}

fn ignore(_: *Nothing, _: ?objc.Object) void {}

fn controllerOf(wv: objc.Object) objc.Object {
    return objc.msg(objc.Object, objc.msg(objc.Object, wv, "configuration", .{}), "userContentController", .{});
}

/// `prefs.$shielded`: every window's open pages switched, and said so.
pub fn shieldedChanged(kea: *Kea) void {
    const on = kea.prefs.shielded;
    kea.shield.enabled = on;
    for (kea.browsers.items) |b| {
        for (b.tabs.items) |t| if (t.web) |wv| kea.shield.apply(controllerOf(wv));
        b.announce(if (on) "Ads and trackers blocked" else "Blocking off — reload to see the difference");
    }
}

test "shield rules are sorted JSON with every domain" {
    const gpa = std.testing.allocator;
    const out = try rulesJson(gpa);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "[{\"action\":{\"type\":\"block\"},\"trigger\":{\"load-type\":[\"third-party\"],\"url-filter\":\"^https?://([^/]+\\\\.)?doubleclick\\\\.net\"}}"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"if-domain\":[\"*cnn.com\"]") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(unwanted.len + 1 + slots_by_site.len, parsed.value.array.items.len);
}
