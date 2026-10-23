//! A site's own icon (`Favicons`, Icons.swift): the page is asked what it
//! declares (`js/favicons.js`), the best of those is fetched once through an
//! ephemeral session and kept as a 64 pt PNG in `<folder>/icons/<key>.png`.
//! Pictures are decoded off the main thread; arrivals come back through
//! `objc.dispatchMain` and redraw every window (`Kea.iconsChanged`).
//! Headless tabs (no webview) never ask.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const disk = @import("../data/disk.zig");
const Parts = @import("../data/url.zig").Parts;
const mark = @import("../chrome/mark.zig");
const Icon = mark.Icon;
pub const Mono = mark.Mono;
const decode = @import("favicons_decode.zig");
pub const square = decode.square;
pub const kinds = decode.kinds;
const Kea = @import("../app/kea.zig").Kea;
const Tab = @import("tab.zig").Tab;
const probe = @embedFile("js/favicons.js");
/// `IconRelay`: a page that changes its icon says so, at most every 2 s, top page only.
pub const relay_script = @embedFile("js/icon_relay.js");
const relay_name = "keaIcon";

/// Fetches and decodes cross threads: everything here is on the C heap.
const a = std.heap.c_allocator;
const Set = std.StringHashMapUnmanaged(void);

/// An icon in memory: `name` is its `ui.image` key, new for each picture
/// so a changed icon is decoded again.
pub const Kept = struct { png: []u8, name: []u8, mono: Mono = .none, fresh: bool = false };

pub const Favicons = struct {
    pub const square = decode.square;
    /// Null once the app's state is gone; in-flight fetches then free this.
    kea: ?*Kea,
    folder: []u8,
    memory: std.StringHashMapUnmanaged(Kept) = .empty,
    busy: Set = .empty,
    missing: Set = .empty,
    /// Keys with no file on disk, as far as `known` has looked.
    absent: Set = .empty,
    dark_cache: ?bool = null,
    pending: usize = 0,
    serial: u64 = 0,

    pub fn create(kea: *Kea) !*Favicons {
        const self = try a.create(Favicons);
        self.* = .{ .kea = kea, .folder = try std.fs.path.join(a, &.{ kea.store.folder, "icons" }) };
        return self;
    }

    /// Lets go of every icon; a fetch still on its way frees the rest.
    pub fn deinit(self: *Favicons) void {
        var it = self.memory.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.png);
            a.free(e.value_ptr.name);
        }
        self.memory.deinit(a);
        inline for (.{ &self.busy, &self.missing, &self.absent }) |s| freeSet(s);
        a.free(self.folder);
        self.kea = null;
        if (self.pending == 0) a.destroy(self);
    }

    /// The icon for a page's site, as `Mark` shows it, or null.
    pub fn icon(self: *Favicons, page: []const u8) ?Icon {
        if (std.mem.startsWith(u8, page, "data:") or std.mem.startsWith(u8, page, "about:")) return null;
        var buf: [300]u8 = undefined;
        const k = self.cached(site(&buf, page) orelse return null) orelse return null;
        return .{ .key = k.name, .png = k.png, .mono = k.mono };
    }

    pub fn iconEntry(self: *Favicons, page: []const u8) ?Kept {
        if (std.mem.startsWith(u8, page, "data:") or std.mem.startsWith(u8, page, "about:")) return null;
        var buf: [300]u8 = undefined;
        return self.cached(site(&buf, page) orelse return null);
    }

    pub fn monoOf(self: *Favicons, page: []const u8) Mono {
        return if (self.iconEntry(page)) |k| k.mono else .none;
    }
    /// What is already known, nothing fetched: in the dark, the dark variant
    /// when there is one; `www.` and without count as one site.
    pub fn cached(self: *Favicons, host: []const u8) ?Kept {
        var buf: [304]u8 = undefined;
        if (host.len + 4 > buf.len) return null;
        const lower = std.ascii.lowerString(buf[4..], host);
        if (self.match(lower)) |hit| return hit;
        if (std.mem.startsWith(u8, lower, "www.")) return self.match(lower[4..]);
        @memcpy(buf[0..4], "www.");
        return self.match(buf[0 .. 4 + lower.len]);
    }

    fn match(self: *Favicons, host: []const u8) ?Kept {
        var buf: [310]u8 = undefined;
        if (self.dark()) if (self.known(keyFor(&buf, host, true))) |hit| return hit;
        return self.known(host);
    }

    fn known(self: *Favicons, key: []const u8) ?Kept {
        if (self.memory.get(key)) |hit| return hit;
        // Looked for on disk once, not on every line of every list that shows it.
        if (self.absent.contains(key)) return null;
        const path = self.file(key) orelse return null;
        defer a.free(path);
        const png = disk.read(a, path) orelse {
            putSet(&self.absent, key);
            return null;
        };
        if (!decode.validPng(png)) {
            a.free(png);
            putSet(&self.absent, key);
            return null;
        }
        return self.remember(key, png) orelse {
            a.free(png);
            return null;
        };
    }

    pub fn remember(self: *Favicons, key: []const u8, png: []u8) ?Kept {
        if (self.memory.getPtr(key)) |old| {
            if (std.mem.eql(u8, old.png, png)) {
                a.free(png);
                old.fresh = true;
                if (self.absent.fetchRemove(key)) |kv| a.free(kv.key);
                return old.*;
            }
        }
        if (self.memory.count() > 512) self.trimMemory(self.kea);
        const mono = decode.analyzeMono(png);
        const suffix = switch (mono) {
            .none => "",
            .dark => "@d",
            .light => "@l",
        };
        self.serial += 1;
        const name = std.fmt.allocPrint(a, "icon:{s}#{d}{s}", .{ key, self.serial, suffix }) catch return null;
        const gop = self.memory.getOrPut(a, key) catch {
            a.free(name);
            return null;
        };
        if (gop.found_existing) {
            a.free(gop.value_ptr.png);
            a.free(gop.value_ptr.name);
        } else gop.key_ptr.* = a.dupe(u8, key) catch {
            self.memory.removeByPtr(gop.key_ptr);
            a.free(name);
            return null;
        };
        gop.value_ptr.* = .{ .png = png, .name = name, .mono = mono, .fresh = true };
        if (self.absent.fetchRemove(key)) |kv| a.free(kv.key);
        return gop.value_ptr.*;
    }

    fn file(self: *Favicons, key: []const u8) ?[]u8 {
        return std.fmt.allocPrint(a, "{s}/{s}.png", .{ self.folder, key }) catch null;
    }

    /// Kept on disk less than a week ago.
    fn fresh(self: *Favicons, key: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const path = self.file(key) orelse return false;
        defer a.free(path);
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        const attrs = objc.msg(?objc.Object, fm, "attributesOfItemAtPath:error:", .{ objc.nsString(path), @as(?*anyopaque, null) }) orelse return false;
        const stamp = objc.msg(?objc.Object, attrs, "fileModificationDate", .{}) orelse return false;
        return -objc.msg(f64, stamp, "timeIntervalSinceNow", .{}) < 7 * 86_400;
    }

    /// Whether the chrome is dark right now; a dark variant is kept apart.
    fn dark(self: *Favicons) bool {
        if (self.dark_cache) |d| return d;
        const pool = objc.Pool.push();
        defer pool.pop();
        const app = (self.kea orelse return false).ui_app orelse return false;
        const look = objc.msg(objc.Object, app.nsapp, "effectiveAppearance", .{});
        var names = [_]objc.Object{ objc.nsString("NSAppearanceNameAqua"), objc.nsString("NSAppearanceNameDarkAqua") };
        const list = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObjects:count:", .{ &names, @as(objc.NSUInteger, 2) });
        const best = objc.fromNSString(objc.msg(?objc.Object, look, "bestMatchFromAppearancesWithNames:", .{list}));
        const d = std.mem.eql(u8, best, "NSAppearanceNameDarkAqua");
        self.dark_cache = d;
        return d;
    }

    /// Appearance changed: updates `dark_cache`, clears `missing`, refetches
    /// every non-asleep tab with a web view, and notifies windows.
    pub fn setDark(self: *Favicons, is_dark: bool) void {
        const prev = self.dark_cache orelse {
            self.dark_cache = is_dark;
            return;
        };
        if (prev == is_dark) return;
        self.dark_cache = is_dark;
        freeSet(&self.missing);
        self.missing = .empty;
        if (self.kea) |k| {
            for (k.browsers.items) |b| {
                for (b.tabs.items) |t| {
                    if (t.web != null and !t.loading and !t.asleep()) self.fetch(t, false);
                }
            }
            k.iconsChanged();
        }
    }

    /// Asks the page which icon it wants to be known by, fetches it and keeps
    /// it, unless a fresh one is already on disk, or the page has just
    /// changed its icon (`changed`).
    pub fn fetch(self: *Favicons, tab: *Tab, changed: bool) void {
        const wv = tab.web orelse return;
        const kea = self.kea orelse return;
        const page = tab.url();
        if (std.mem.startsWith(u8, page, "data:") or std.mem.startsWith(u8, page, "about:")) return;
        const p = Parts.parse(page) orelse return;
        // ponytail: `kea-test` counts as the web only under the e2e scheme handler.
        const test_scheme = kea.opts.scheme_handler != null and p.schemeIs("kea-test");
        if (!std.ascii.startsWithIgnoreCase(p.scheme orelse return, "http") and !test_scheme) return;
        var sbuf: [300]u8 = undefined;
        const host = site(&sbuf, page) orelse return;
        const is_dark = self.dark();
        var kbuf: [310]u8 = undefined;
        const key = keyFor(&kbuf, host, is_dark);
        if (!changed and ((if (self.memory.get(key)) |k| k.fresh else false) or (self.fresh(key) and self.known(key) != null))) return;
        if (self.busy.contains(host) or (!changed and self.missing.contains(host))) return;
        const job = Job.create(self, page, host, key, tab.shy, is_dark) catch return;
        putSet(&self.busy, host);
        self.pending += 1;
        const pool = objc.Pool.push();
        defer pool.pop();
        var block = ProbeBlock.init(job, probed);
        objc.msg(void, wv, "evaluateJavaScript:completionHandler:", .{ objc.nsString(probe), @as(*anyopaque, @ptrCast(&block)) });
    }

    fn keep(self: *Favicons, key: []const u8, png: []const u8) void {
        const kea = self.kea orelse return;
        const path = self.file(key) orelse return;
        defer a.free(path);
        const owned = kea.gpa.dupe(u8, png) catch return;
        kea.store.disk.write(path, owned, false);
    }

    /// Another browser's icon for `host` (PNG on the C heap, taken), kept as
    /// if the site had handed it over, unless one is already here (`adopt`).
    pub fn adopt(self: *Favicons, host: []const u8, png: []u8) void {
        var buf: [304]u8 = undefined;
        if (host.len == 0 or host.len > buf.len or self.cached(host) != null) return a.free(png);
        const key = std.ascii.lowerString(&buf, host);
        const kept = self.remember(key, png) orelse return a.free(png);
        self.keep(key, kept.png);
    }

    /// Clear History (`forgetAll`): every icon kept on disk goes, and what
    /// was known missing; the tabs open now keep theirs until they close.
    pub fn forgetAll(self: *Favicons) void {
        const kea = self.kea orelse return;
        // A write still queued would put an icon back after the folder went.
        kea.store.disk.drain();
        const pool = objc.Pool.push();
        defer pool.pop();
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        _ = objc.msg(objc.BOOL, fm, "removeItemAtPath:error:", .{ objc.nsString(self.folder), @as(?*anyopaque, null) });
        inline for (.{ &self.missing, &self.absent }) |s| {
            freeSet(s);
            s.* = .empty;
        }
        self.trimMemory(kea);
        // Extensions' favIconUrl data: URLs go with them (Icons.swift:35).
        if (kea.ext) |e| @import("../ext/shims/answer.zig").forgetIcons(e);
    }

    pub fn trimMemory(self: *Favicons, kea: ?*Kea) void {
        var drop: std.ArrayList([]const u8) = .empty;
        defer drop.deinit(a);
        var it = self.memory.keyIterator();
        while (it.next()) |k| if (!hostInUse(kea, baseHost(k.*))) drop.append(a, k.*) catch break;
        for (drop.items) |k| if (self.memory.fetchRemove(k)) |kv| {
            a.free(kv.key);
            a.free(kv.value.png);
            a.free(kv.value.name);
        };
    }

    fn baseHost(s: []const u8) []const u8 {
        const h = if (std.mem.endsWith(u8, s, "@dark")) s[0 .. s.len - 5] else s;
        return if (std.mem.startsWith(u8, h, "www.")) h[4..] else h;
    }

    fn hostInUse(kea: ?*Kea, want: []const u8) bool {
        const k = kea orelse return false;
        var buf: [300]u8 = undefined;
        for (k.browsers.items) |b| {
            for (b.tabs.items) |t| if (site(&buf, t.url())) |s| if (std.mem.eql(u8, baseHost(s), want)) return true;
            for (b.parked.values()) |row| for (row.tabs.items) |t| if (site(&buf, t.url())) |s| if (std.mem.eql(u8, baseHost(s), want)) return true;
        }
        return false;
    }
};

fn freeSet(s: *Set) void {
    var it = s.keyIterator();
    while (it.next()) |k| a.free(k.*);
    s.deinit(a);
}

fn putSet(s: *Set, key: []const u8) void {
    if (s.contains(key)) return;
    const owned = a.dupe(u8, key) catch return;
    s.put(a, owned, {}) catch a.free(owned);
}

fn removeSet(s: *Set, key: []const u8) void {
    if (s.fetchRemove(key)) |kv| a.free(kv.key);
}

/// The name an icon is kept under: the site, `@dark` for a dark variant.
fn keyFor(buf: []u8, host: []const u8, is_dark: bool) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ host, if (is_dark) "@dark" else "" }) catch host;
}

/// Which site an address is, for its icon: its host, and its port when it
/// names one other than the scheme's own (localhost:3000 and :4321 differ).
pub fn site(buf: []u8, page: []const u8) ?[]const u8 {
    const p = Parts.parse(page) orelse return null;
    const host = p.hostName() orelse return null;
    if (host.len + 7 > buf.len) return null;
    const lower = std.ascii.lowerString(buf, host);
    const port = std.fmt.parseInt(u16, p.port orelse return lower, 10) catch return lower;
    if ((p.schemeIs("http") and port == 80) or (p.schemeIs("https") and port == 443)) return lower;
    const tail = std.fmt.bufPrint(buf[lower.len..], ":{d}", .{port}) catch return lower;
    return buf[0 .. lower.len + tail.len];
}

pub const Scheme = enum { any, light, dark };

/// What a `media` attribute says about the colour scheme, if anything.
pub fn media(value: []const u8) Scheme {
    var buf: [256]u8 = undefined;
    const text = std.ascii.lowerString(&buf, value[0..@min(value.len, buf.len)]);
    if (std.mem.indexOf(u8, text, "prefers-color-scheme") == null) return .any;
    if (std.mem.indexOf(u8, text, "dark") != null) return .dark;
    if (std.mem.indexOf(u8, text, "light") != null) return .light;
    return .any;
}

/// One `<link rel=…icon…>` as the probe reports it.
pub const Declared = struct { href: []const u8 = "", rel: []const u8 = "", sizes: []const u8 = "", type: []const u8 = "", media: []const u8 = "" };

/// Best first (`Favicons.rank`): a crisp 32–64 px icon, then the touch icon,
/// then the root's `/favicon.ico`; the other scheme's icons never; each
/// address once. Owned by `gpa`, strings included.
// ponytail: hrefs are taken as absolute (the probe reports `link.href`); data:
// icons are fetched too, which Swift skips, so a fixture page can declare one.
pub fn rank(gpa: std.mem.Allocator, declared: []const Declared, page: []const u8, is_dark: bool) ![][]u8 {
    const Scored = struct { url: []const u8, score: i32 };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(gpa);
    for (declared) |entry| {
        const u = Parts.parse(entry.href) orelse continue;
        const scheme = u.scheme orelse continue;
        if (!std.ascii.startsWithIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "data")) continue;
        const sch = media(entry.media);
        if (sch == (if (is_dark) Scheme.light else Scheme.dark)) continue;
        var score: i32 = if (std.mem.indexOf(u8, entry.rel, "apple-touch") != null) 40 else 25;
        var px: ?i64 = null;
        var sizes = std.mem.tokenizeScalar(u8, entry.sizes, ' ');
        while (sizes.next()) |s| {
            var parts = std.mem.tokenizeScalar(u8, s, 'x');
            const n = std.fmt.parseInt(i64, parts.next() orelse continue, 10) catch continue;
            px = @max(px orelse n, n);
        }
        if (px) |n| score = if (n < 24) 10 else if (n < 48) 45 else if (n < 128) 50 else if (n < 260) 42 else 20;
        if (std.mem.eql(u8, entry.sizes, "any") or std.mem.indexOf(u8, entry.type, "svg") != null or svgPath(u.path)) score = 35;
        if (sch != .any) score += 40;
        try scored.append(gpa, .{ .url = entry.href, .score = score });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn more(_: void, l: Scored, r: Scored) bool {
            return l.score > r.score;
        }
    }.more);
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    for (scored.items) |s| try appendOnce(gpa, &list, try gpa.dupe(u8, s.url));
    // The same site's root, its port included.
    if (Parts.parse(page)) |p| if (p.hostName() != null) {
        var root = p;
        root.path = "/favicon.ico";
        root.query = null;
        root.fragment = null;
        try appendOnce(gpa, &list, try root.string(gpa));
    };
    return list.toOwnedSlice(gpa);
}

fn appendOnce(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), s: []u8) !void {
    for (list.items) |have| if (std.mem.eql(u8, have, s)) return gpa.free(s);
    errdefer gpa.free(s);
    try list.append(gpa, s);
}

fn svgPath(path: []const u8) bool {
    const last = path[if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| i + 1 else 0 ..];
    const dot = std.mem.lastIndexOfScalar(u8, last, '.') orelse return false;
    return dot > 0 and std.ascii.eqlIgnoreCase(last[dot + 1 ..], "svg");
}

pub fn freeList(gpa: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

// MARK: the relay

/// Registers `keaIcon` on a tab's controller (`tab_scripts.arm` injects `relay_script`).
pub fn install(ucc: objc.Object, handler: objc.Object) void {
    objc.msg(void, ucc, "addScriptMessageHandler:contentWorld:name:", .{ handler, @import("config.zig").world(), objc.nsString(relay_name) });
}

pub fn uninstall(ucc: objc.Object) void {
    objc.msg(void, ucc, "removeScriptMessageHandlerForName:contentWorld:", .{ objc.nsString(relay_name), @import("config.zig").world() });
}

/// Whether `message` is the relay's; if so the icon is asked for again,
/// from the top page of the tab's own view only.
pub fn relayed(tab: *Tab, message: objc.Object) bool {
    if (!std.mem.eql(u8, objc.fromNSString(objc.msg(?objc.Object, message, "name", .{})), relay_name)) return false;
    const frame = objc.msg(objc.Object, message, "frameInfo", .{});
    if (!objc.msg(objc.BOOL, frame, "isMainFrame", .{})) return true;
    if (objc.msg(?objc.Object, message, "webView", .{}) != tab.web) return true;
    if (tab.favicons) |f| f.fetch(tab, true);
    return true;
}

// MARK: fetching

/// One site's icon on its way: probe → candidates in order → decoded → landed.
const Job = struct {
    owner: *Favicons,
    page: []u8,
    host: []u8,
    key: []u8,
    shy: bool,
    dark: bool,
    candidates: [][]u8 = &.{},
    next: usize = 0,
    png: ?[]u8 = null,

    fn create(owner: *Favicons, page: []const u8, host: []const u8, key: []const u8, shy: bool, is_dark: bool) !*Job {
        const job = try a.create(Job);
        errdefer a.destroy(job);
        const page_d = try a.dupe(u8, page);
        errdefer a.free(page_d);
        const host_d = try a.dupe(u8, host);
        errdefer a.free(host_d);
        job.* = .{ .owner = owner, .page = page_d, .host = host_d, .key = try a.dupe(u8, key), .shy = shy, .dark = is_dark };
        return job;
    }

    fn destroy(job: *Job) void {
        freeList(a, job.candidates);
        if (job.png) |p| a.free(p);
        a.free(job.page);
        a.free(job.host);
        a.free(job.key);
        a.destroy(job);
    }
};

const ProbeBlock = objc.Block(Job, &.{ ?objc.Object, ?objc.Object });
const FetchBlock = objc.Block(Job, &.{ ?objc.Object, ?objc.Object, ?objc.Object });

/// The probe's answer, on the main thread.
fn probed(job: *Job, answer: ?objc.Object, _: ?objc.Object) void {
    if (job.owner.kea == null) return landed(job);
    var declared: std.ArrayList(Declared) = .empty;
    defer declared.deinit(a);
    if (answer) |list| if (objc.msg(objc.BOOL, list, "isKindOfClass:", .{objc.class("NSArray")})) {
        for (0..objc.msg(objc.NSUInteger, list, "count", .{})) |i| {
            const d = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
            if (!objc.msg(objc.BOOL, d, "isKindOfClass:", .{objc.class("NSDictionary")})) continue;
            declared.append(a, .{
                .href = field(d, "href") orelse continue,
                .rel = field(d, "rel") orelse "",
                .sizes = field(d, "sizes") orelse "",
                .type = field(d, "type") orelse "",
                .media = field(d, "media") orelse "",
            }) catch break;
        }
    };
    job.candidates = rank(a, declared.items, job.page, job.dark) catch &.{};
    step(job);
}

fn field(d: objc.Object, name: []const u8) ?[]const u8 {
    const v = objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString(name)}) orelse return null;
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) return null;
    return objc.fromNSString(v);
}

/// Built on the main thread at the first fetch, then only read.
var session_obj: ?objc.Object = null;

fn session() objc.Object {
    if (session_obj) |s| return s;
    const config = objc.msg(objc.Object, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
    objc.msg(void, config, "setTimeoutIntervalForRequest:", .{@as(f64, 8)});
    const s = objc.retain(objc.msg(objc.Object, objc.class("NSURLSession"), "sessionWithConfiguration:", .{config}));
    session_obj = s;
    return s;
}

/// The next candidate, or the end of the list. Any thread.
fn step(job: *Job) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    while (job.next < job.candidates.len) {
        const u = job.candidates[job.next];
        job.next += 1;
        const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(u)}) orelse continue;
        var block = FetchBlock.init(job, downloaded);
        const task = objc.msg(objc.Object, session(), "dataTaskWithURL:completionHandler:", .{ nsurl, @as(*anyopaque, @ptrCast(&block)) });
        objc.msg(void, task, "resume", .{});
        return;
    }
    objc.dispatchMain(job, landedMain);
}

/// A candidate's bytes, on the session's queue: decoded right here.
fn downloaded(job: *Job, data: ?objc.Object, response: ?objc.Object, _: ?objc.Object) void {
    if (data) |d| if (ok(response)) {
        const n = objc.msg(objc.NSUInteger, d, "length", .{});
        if (n > 60 and n < 2_000_000) if (square(a, objc.msg([*]const u8, d, "bytes", .{})[0..n])) |png| {
            job.png = png;
            return objc.dispatchMain(job, landedMain);
        };
    };
    step(job);
}

fn ok(response: ?objc.Object) bool {
    const r = response orelse return true;
    if (!objc.msg(objc.BOOL, r, "isKindOfClass:", .{objc.class("NSHTTPURLResponse")})) return true;
    const status = objc.msg(objc.NSInteger, r, "statusCode", .{});
    return status >= 200 and status < 300;
}

fn landedMain(ctx: ?*anyopaque) callconv(.c) void {
    landed(@ptrCast(@alignCast(ctx.?)));
}

/// The end of a fetch, on the main thread: kept and shown, or not asked
/// again this session (a quiet browser doesn't hammer a site for an icon).
fn landed(job: *Job) void {
    defer job.destroy();
    const f = job.owner;
    f.pending -= 1;
    const kea = f.kea orelse {
        if (f.pending == 0) a.destroy(f);
        return;
    };
    removeSet(&f.busy, job.host);
    const scheme_changed = job.dark != f.dark();
    if (job.png) |png| {
        job.png = null;
        if (f.remember(job.key, png)) |kept| {
            if (!job.shy) f.keep(job.key, kept.png);
            kea.iconsChanged();
        } else a.free(png);
    } else if (!scheme_changed) {
        putSet(&f.missing, job.host);
    }
    if (scheme_changed) {
        for (kea.browsers.items) |b| {
            for (b.tabs.items) |t| {
                if (t.web == null or t.loading or t.asleep()) continue;
                var sbuf: [300]u8 = undefined;
                const th = site(&sbuf, t.url()) orelse continue;
                if (std.mem.eql(u8, th, job.host)) f.fetch(t, false);
            }
        }
    }
}

test {
    _ = @import("favicons_tests.zig");
}
