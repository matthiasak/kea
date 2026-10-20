//! What the "Bring things over" sheet and the Welcome's page know and do
//! (ImportPanel.swift `look`, `count`, `bring`; Welcome.swift `bringAll`):
//! every browser on this Mac with its profiles, what each holds, counted off
//! the main thread from its files alone, and then the bringing — passwords
//! off the main thread (the one moment macOS may ask for a key), bookmarks
//! at once, history read off the main thread, Arc's spaces and pins.
//!
//! A `Session` is one appearance of the sheet (or the Welcome's page): its
//! jobs land in it, and it outlives its window until the last has.
const std = @import("std");
const objc = @import("nanoui").objc;
const Browser = @import("../model/browser.zig").Browser;
const sources = @import("sources.zig");
const record = @import("record.zig");
const takers = @import("../model/browser_import.zig");
const browser_arc = @import("../model/browser_arc.zig");

/// Jobs cross threads: sessions and what jobs keep are on the C heap.
const heap = std.heap.c_allocator;

/// `Browser.importing`.
pub const State = struct {
    /// The sheet's, while it is up.
    panel: ?*Session = null,
    /// The Welcome's page's.
    welcome: ?*Session = null,
    /// A file being brought in (`fileImport`), its card in the corner.
    file: ?*takers.FileImport = null,
    /// Settings › Extensions asked for the sheet on the extensions alone
    /// (`bringingExtensions`): read once as the sheet's session begins.
    extensions: bool = false,
};

/// The window going: its imports let go of it, and finish on their own.
pub fn deinit(b: *Browser) void {
    takers.forget(b);
    if (b.importing.panel) |s| release(s);
    if (b.importing.welcome) |s| release(s);
    b.importing = .{};
}

/// One line of what came in: a check, or a mark when it didn't.
pub const Said = struct { ok: bool, text: []const u8 };

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    /// Null once its window or its sheet has gone.
    browser: ?*Browser,
    /// Jobs still on their way back.
    pending: usize = 0,
    base: sources.Base = .{ .path = "" },
    /// The browser to start on, by name ("" for the first found).
    wanted: []const u8 = "",
    look_job: ?*sources.LookJob = null,
    looking: bool = true,
    found: []const sources.Source = &.{},
    profiles: []const []sources.Profile = &.{},
    usual: []const ?[]const u8 = &.{},
    unreadable: []const []const u8 = &.{},
    pick: ?usize = null,
    /// By browser: the profile chosen, "" for all of them; null for the usual.
    chosen: []?[]const u8 = &.{},
    /// Counts by `key`, and what each count's job keeps them in.
    previews: std.StringHashMapUnmanaged(sources.Count) = .empty,
    counting: std.StringHashMapUnmanaged(void) = .empty,
    kept_jobs: std.ArrayListUnmanaged(*sources.CountJob) = .empty,

    wants_passwords: bool = true,
    wants_bookmarks: bool = true,
    wants_history: bool = true,
    wants_arc: bool = true,
    wants_extensions: bool = false,
    /// Opened for the extensions: the first browser counted with some is
    /// picked, until you pick one yourself.
    for_extensions: bool = false,
    replace_bookmarks: bool = false,
    bringing: bool = false,
    /// The bring's parts still to come (`DispatchGroup`).
    waiting: usize = 0,
    said: [5]?Said = @splat(null),
    brought: bool = false,
    marks_landed: bool = false,
    /// The Welcome's: its lines as they land, then the one line it says.
    welcome: bool = false,
    lines: std.ArrayListUnmanaged([]const u8) = .empty,
    welcome_said: ?[]const u8 = null,
    /// The Welcome's Segmented choice.
    choice: usize = 0,

    pub fn alloc(s: *Session) std.mem.Allocator {
        return s.arena.allocator();
    }

    pub fn source(s: *const Session) ?sources.Source {
        const i = s.pick orelse return null;
        return s.found[i];
    }

    /// The profile to read: the one chosen, or the one used most recently;
    /// null for all of them.
    pub fn profileOf(s: *const Session, i: usize) ?[]const u8 {
        const id = s.chosen[i] orelse s.usual[i] orelse "";
        return if (id.len == 0) null else id;
    }

    /// "chromium-Chrome/Default", in `buf`.
    pub fn key(s: *const Session, buf: []u8, i: usize) []const u8 {
        return std.fmt.bufPrint(buf, "{s}-{s}/{s}", .{ @tagName(s.found[i]), s.found[i].name(), s.profileOf(i) orelse "" }) catch "";
    }

    pub fn preview(s: *const Session, i: usize) ?sources.Count {
        var buf: [512]u8 = undefined;
        return s.previews.get(s.key(&buf, i));
    }
};

fn create(b: *Browser, welcome: bool) ?*Session {
    const s = heap.create(Session) catch return null;
    s.* = .{ .arena = .init(heap), .browser = b, .welcome = welcome };
    s.base = sources.Base.of(s.alloc(), b.kea.opts.root) catch {
        destroy(s);
        return null;
    };
    return s;
}

/// The sheet's session, begun as it appears: what is on this Mac is looked
/// for off the main thread.
pub fn panel(b: *Browser) ?*Session {
    if (b.importing.panel) |s| return s;
    const s = create(b, false) orelse return null;
    s.wanted = s.alloc().dupe(u8, b.bringing_in orelse "") catch "";
    if (b.importing.extensions) {
        b.importing.extensions = false;
        s.for_extensions = true;
        s.wants_extensions = true;
        s.wants_passwords = false;
        s.wants_bookmarks = false;
        s.wants_history = false;
    }
    b.importing.panel = s;
    s.pending += 1;
    sources.look(heap, s.base, s, lookDone) catch {
        s.pending -= 1;
        s.looking = false;
    };
    return s;
}

/// The sheet gone (or come again): its session lets go.
pub fn closePanel(b: *Browser) void {
    if (b.importing.panel) |s| release(s);
    b.importing.panel = null;
}

/// The Welcome's page's: looked for there and then, as Swift's body does.
pub fn welcomeSession(b: *Browser) ?*Session {
    if (b.importing.welcome) |s| return s;
    const s = create(b, true) orelse return null;
    b.importing.welcome = s;
    const look = sources.lookWork(s.alloc(), s.base) catch {
        s.looking = false;
        return s;
    };
    took(s, look);
    return s;
}

pub fn closeWelcome(b: *Browser) void {
    if (b.importing.welcome) |s| release(s);
    b.importing.welcome = null;
}

fn release(s: *Session) void {
    s.browser = null;
    if (s.pending == 0) destroy(s);
}

fn destroy(s: *Session) void {
    if (s.look_job) |j| j.deinit();
    for (s.kept_jobs.items) |j| j.deinit();
    s.kept_jobs.deinit(heap);
    s.arena.deinit();
    heap.destroy(s);
}

/// A job back: the session's window, or null when it has gone (and the
/// session with it, once nothing else is on its way).
fn back(s: *Session) ?*Browser {
    s.pending -= 1;
    if (s.browser) |b| return b;
    if (s.pending == 0) destroy(s);
    return null;
}

fn redraw(s: *Session) void {
    if (s.browser) |b| b.redraw();
}

// MARK: looking and counting

fn lookDone(ctx: ?*anyopaque, job: *sources.LookJob) void {
    const s: *Session = @ptrCast(@alignCast(ctx.?));
    // Kept: what it found lives in it.
    s.look_job = job;
    const b = back(s) orelse return;
    s.looking = false;
    if (job.output) |look| {
        took(s, look);
        for (0..s.found.len) |i| count(s, i);
    } else |_| {}
    b.redraw();
}

fn took(s: *Session, look: sources.Look) void {
    s.looking = false;
    s.found = look.sources;
    s.profiles = look.profiles;
    s.usual = look.usual;
    s.unreadable = look.unreadable;
    s.chosen = s.alloc().alloc(?[]const u8, look.sources.len) catch return;
    @memset(s.chosen, null);
    s.pick = if (look.sources.len == 0) null else 0;
    for (look.sources, 0..) |src, i| if (std.mem.eql(u8, src.name(), s.wanted)) {
        s.pick = i;
        break;
    };
}

const Asked = struct { s: *Session, key: []const u8 };

/// What a browser holds in the profile chosen for it, unless counted already.
pub fn count(s: *Session, i: usize) void {
    var buf: [512]u8 = undefined;
    const lookup = s.key(&buf, i);
    if (s.previews.contains(lookup) or s.counting.contains(lookup)) return;
    const k = s.alloc().dupe(u8, lookup) catch return;
    const asked = s.alloc().create(Asked) catch return;
    asked.* = .{ .s = s, .key = k };
    s.counting.put(s.alloc(), k, {}) catch return;
    s.pending += 1;
    sources.count(heap, .{ .base = s.base, .source = s.found[i], .profile = s.profileOf(i) }, asked, countDone) catch {
        s.pending -= 1;
        _ = s.counting.remove(k);
    };
}

fn countDone(ctx: ?*anyopaque, job: *sources.CountJob) void {
    const asked: *Asked = @ptrCast(@alignCast(ctx.?));
    const s = asked.s;
    s.kept_jobs.append(heap, job) catch {
        job.deinit();
        _ = back(s);
        return;
    };
    const b = back(s) orelse return;
    _ = s.counting.remove(asked.key);
    if (job.output) |got| s.previews.put(s.alloc(), asked.key, got) catch {} else |_| {}
    b.redraw();
}

// MARK: bringing

const PlacesJob = sources.Job(sources.CountIn, []sources.Place);

fn placesWork(a: std.mem.Allocator, in: sources.CountIn) ![]sources.Place {
    return in.source.places(a, in.base, in.profile, 3000);
}

/// `bring(from:)`: every kind asked for and there to bring; what came in is
/// said once every part has landed.
pub fn bring(s: *Session) void {
    const b = s.browser orelse return;
    const i = s.pick orelse return;
    const src = s.found[i];
    const profile = s.profileOf(i);
    // A kind it has none of isn't read at all: no keychain question for a
    // browser with no passwords.
    const pv = s.preview(i);
    const none = struct {
        fn none(p: ?sources.Count, comptime field: []const u8) bool {
            return if (p) |c| @field(c.preview, field) == 0 else false;
        }
    }.none;
    s.marks_landed = false;
    s.said = @splat(null);
    s.brought = false;
    s.bringing = true;
    s.waiting = 1;
    const in: sources.CountIn = .{ .base = s.base, .source = src, .profile = profile };
    if (s.wants_passwords and !none(pv, "passwords")) passwords(s, in);
    if (s.wants_bookmarks and !none(pv, "bookmarks")) {
        const t = takers.takeBookmarks(b, src, profile, s.replace_bookmarks);
        s.marks_landed = t.added + t.already > 0;
        s.said[1] = marksSaid(s, src.name(), t);
    }
    if (s.wants_history and !none(pv, "places")) places(s, in);
    if (s.wants_arc) if (pv) |c| if (c.arc != null) arcs(s, b, src, profile);
    if (s.wants_extensions) extensions(s, b, i);
    landed(s);
}

/// The Welcome's `bringAll`: the chosen browser's most recent profile,
/// without asking.
pub fn bringAll(s: *Session) void {
    const b = s.browser orelse return;
    if (s.found.len == 0) return;
    const i = @min(s.choice, s.found.len - 1);
    const src = s.found[i];
    const profile = s.usual[i];
    s.bringing = true;
    s.lines = .empty;
    s.waiting = 1;
    const in: sources.CountIn = .{ .base = s.base, .source = src, .profile = profile };
    if (s.wants_passwords) passwords(s, in);
    if (s.wants_bookmarks) line(s, "{d} bookmarks", .{takers.takeBookmarks(b, src, profile, false).added});
    if (s.wants_history) places(s, in);
    landed(s);
}

fn line(s: *Session, comptime f: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(s.alloc(), f, args) catch return;
    s.lines.append(s.alloc(), text) catch {};
}

fn passwords(s: *Session, in: sources.CountIn) void {
    s.waiting += 1;
    s.pending += 1;
    sources.readPasswords(heap, in, s, passwordsDone) catch {
        s.waiting -= 1;
        s.pending -= 1;
    };
}

fn passwordsDone(ctx: ?*anyopaque, job: *sources.ReadJob) void {
    const s: *Session = @ptrCast(@alignCast(ctx.?));
    defer job.deinit();
    const b = back(s) orelse return;
    const name = job.input.source.name();
    const a = s.alloc();
    if (job.output) |found| {
        const kept = takers.keepFound(b, found);
        record.note(b.gpa, b.store, name, .{ .passwords = @intCast(kept) }) catch {};
        if (s.welcome) {
            line(s, "{d} passwords", .{kept});
        } else {
            const skipped = if (found.skipped > 0) std.fmt.allocPrint(a, " ({s} skipped: no address)", .{number(a, found.skipped)}) catch "" else "";
            s.said[0] = .{ .ok = true, .text = std.fmt.allocPrint(a, "{s}{s}", .{ counted(a, kept, "password"), skipped }) catch "" };
        }
    } else |err| {
        if (s.welcome) {
            if (err == error.NoPassphrase) line(s, "passwords: macOS didn't hand over the key — allow it and try again", .{})
            else if (err == error.PrimaryPassword) line(s, "passwords: {s} has a primary password — export them from it and bring in the CSV", .{name})
            else line(s, "passwords: nothing readable", .{});
        } else {
            const text = if (err == error.NoPassphrase)
                std.fmt.allocPrint(a, "macOS didn't hand over {s}'s key — allow it and try again", .{name})
            else if (err == error.PrimaryPassword)
                std.fmt.allocPrint(a, "{s} has a primary password: export your passwords from it and bring in the CSV file", .{name})
            else
                std.fmt.allocPrint(a, "No passwords readable in {s}", .{name});
            s.said[0] = .{ .ok = false, .text = text catch "" };
        }
    }
    landed(s);
}

fn places(s: *Session, in: sources.CountIn) void {
    s.waiting += 1;
    s.pending += 1;
    PlacesJob.start(heap, in, placesWork, s, placesDone) catch {
        s.waiting -= 1;
        s.pending -= 1;
    };
}

fn placesDone(ctx: ?*anyopaque, job: *PlacesJob) void {
    const s: *Session = @ptrCast(@alignCast(ctx.?));
    defer job.deinit();
    const b = back(s) orelse return;
    const list = job.output catch &.{};
    const n = takers.takePlaces(b, job.input.source.name(), list);
    if (s.welcome) line(s, "{d} places", .{n}) else s.said[2] = .{ .ok = true, .text = std.fmt.allocPrint(s.alloc(), "{s} places", .{number(s.alloc(), n)}) catch "" };
    landed(s);
}

fn arcs(s: *Session, b: *Browser, src: sources.Source, profile: ?[]const u8) void {
    var scratch: std.heap.ArenaAllocator = .init(heap);
    defer scratch.deinit();
    const side = (src.arcSidebar(scratch.allocator(), s.base, profile) catch return) orelse return;
    const t = browser_arc.takeArc(b, side, src, profile);
    record.note(b.gpa, b.store, src.name(), .{ .spaces = @intCast(t.spaces), .pinned = @intCast(t.pins + t.tabs) }) catch {};
    const a = s.alloc();
    s.said[4] = .{ .ok = true, .text = if (t.spaces + t.pins + t.tabs == 0)
        "Arc's spaces and pins were all here already"
    else
        std.fmt.allocPrint(a, "{s}, {s}, {s}", .{ counted(a, t.spaces, "new space"), counted(a, t.pins, "pin"), counted(a, t.tabs, "pinned tab") }) catch "" };
}

/// `fresh(source)`: the store extensions it has that aren't here already
/// (on `a`); none below macOS 15.4.
pub fn fresh(s: *Session, a: std.mem.Allocator, i: usize) []const []const u8 {
    const b = s.browser orelse return &.{};
    const e = b.kea.ext orelse return &.{};
    const pv = s.preview(i) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (pv.preview.extensions) |id| if (e.row(id) == null) out.append(a, id) catch {};
    return out.items;
}

/// Each from the store, fresh and checked, one question at a time.
fn extensions(s: *Session, b: *Browser, i: usize) void {
    const ids = fresh(s, s.alloc(), i);
    if (ids.len == 0) return;
    const e = b.kea.ext orelse return;
    s.said[3] = .{ .ok = true, .text = if (ids.len == 1) "1 extension to confirm" else std.fmt.allocPrint(s.alloc(), "{s} extensions to confirm", .{number(s.alloc(), ids.len)}) catch "" };
    const chain = heap.create(Chain) catch return;
    chain.* = .{ .serial = e.serial };
    for (ids) |id| chain.ids.append(heap, heap.dupe(u8, id) catch continue) catch {};
    chain.step();
}

/// `for id in extensions { await install(id:) }`.
const Chain = struct {
    serial: u64,
    ids: std.ArrayList([]u8) = .empty,
    next: usize = 0,

    fn step(self: *Chain) void {
        const e = @import("../ext/controller.zig").alive(self.serial);
        if (e == null or self.next >= self.ids.items.len) {
            for (self.ids.items) |id| heap.free(id);
            self.ids.deinit(heap);
            return heap.destroy(self);
        }
        const id = self.ids.items[self.next];
        self.next += 1;
        e.?.installId(id, true, self, done);
    }

    fn done(p: *anyopaque) void {
        const self: *Chain = @ptrCast(@alignCast(p));
        self.step();
    }
};

/// One part of the bring has landed; the last says what came in.
fn landed(s: *Session) void {
    s.waiting -= 1;
    if (s.waiting > 0) return;
    s.bringing = false;
    if (s.welcome) {
        s.welcome_said = std.mem.join(s.alloc(), " · ", s.lines.items) catch "";
        if (s.browser) |b| takers.relist(b);
    } else s.brought = true;
    redraw(s);
}

fn marksSaid(s: *Session, name: []const u8, t: takers.Marks) Said {
    const a = s.alloc();
    const text = if (t.kept)
        std.fmt.allocPrint(a, "Couldn't read all of {s}'s bookmarks: what came from it before was kept, {s} new", .{ name, number(a, t.added) })
    else if (t.added == 0 and t.already == 0)
        std.fmt.allocPrint(a, "No bookmarks in {s}", .{name})
    else if (t.already == 0)
        std.fmt.allocPrint(a, "{s} bookmarks", .{number(a, t.added)})
    else
        std.fmt.allocPrint(a, "{s} new bookmarks, {s} already here", .{ number(a, t.added), number(a, t.already) });
    return .{ .ok = !t.kept, .text = text catch "" };
}

// MARK: words

/// `n.formatted()`: "1,204", in the Mac's own way. On `a`.
pub fn number(a: std.mem.Allocator, n: usize) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithUnsignedInteger:", .{@as(objc.NSUInteger, n)});
    // NSNumberFormatterDecimalStyle.
    const text = objc.msg(?objc.Object, objc.class("NSNumberFormatter"), "localizedStringFromNumber:numberStyle:", .{ ns, @as(objc.NSUInteger, 1) });
    return a.dupe(u8, objc.fromNSString(text)) catch "";
}

/// "1 bookmark", "1,204 bookmarks".
pub fn counted(a: std.mem.Allocator, n: usize, one: []const u8) []const u8 {
    if (n == 1) return std.fmt.allocPrint(a, "1 {s}", .{one}) catch "";
    return std.fmt.allocPrint(a, "{s} {s}s", .{ number(a, n), one }) catch "";
}

/// `ListFormatter.localizedString(byJoining:)`: "a, b and c".
pub fn listed(a: std.mem.Allocator, parts: []const []const u8) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const list = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (parts) |p| objc.msg(void, list, "addObject:", .{objc.nsString(p)});
    const text = objc.msg(?objc.Object, objc.class("NSListFormatter"), "localizedStringByJoiningStrings:", .{list});
    return a.dupe(u8, objc.fromNSString(text)) catch "";
}
