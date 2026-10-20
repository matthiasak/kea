//! One browser to bring things over from, whichever family it belongs to
//! (`ImportSource` in Import.swift): a Chromium browser or a Mozilla one,
//! in one vocabulary, with what both give back — `Place`, `Found`,
//! `Preview` — and the off-main reading the panel does through GCD, its
//! results delivered on the main thread.
//!
//! Everything that reads takes an arena `a`: what comes back lives there,
//! and so does whatever it took to read it. Everything takes a `Base`, the
//! folder browsers keep their data in (`Chromium.base`): a test run's own
//! `<root>/Import`, never a real browser's.
const std = @import("std");
const objc = @import("nanoui").objc;
const json = @import("../data/json.zig");
const Parts = @import("../data/url.zig").Parts;
const Bookmark = @import("../data/bookmarks.zig").Bookmark;
const vault = @import("../passwords/vault.zig");
const dispatch = @import("../sys/dispatch.zig");
const files = @import("files.zig");
pub const chromium = @import("chromium.zig");
pub const firefox = @import("firefox.zig");
pub const arc = @import("arc.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Where browsers keep their data, and whether this is a test run: a test
/// run reads made-up profiles and a made-up browser's key from files, and
/// never the keychain.
pub const Base = struct {
    path: []const u8,
    testing: bool = false,

    /// `~/Library/Application Support`, or `<root>/Import` when the app has
    /// a folder of its own (`kea.opts.root`, tests). On `a`.
    pub fn of(a: std.mem.Allocator, root: ?[]const u8) !Base {
        if (root) |r| return .{ .path = try std.fs.path.join(a, &.{ r, "Import" }), .testing = true };
        return .{ .path = try std.fs.path.join(a, &.{ home(), "Library/Application Support" }) };
    }
};

pub fn home() []const u8 {
    return if (getenv("HOME")) |h| std.mem.span(h) else "/tmp";
}

/// A page another browser has been to.
pub const Place = struct {
    url: []const u8,
    title: []const u8,
    count: i64,
    last: json.SwiftDate,
};

pub const Trouble = error{
    /// The browser's key wasn't given (Chromium).
    NoPassphrase,
    Unreadable,
    /// A primary password is set, so the key can't be read here (Mozilla).
    PrimaryPassword,
};

pub const Found = struct {
    logins: []vault.Login,
    /// Sites the other browser was told never to ask about.
    never: []const []const u8,
    /// Passwords left behind for having no site to go with.
    skipped: usize = 0,
};

/// What there is to bring, counted before anything is: never a key asked
/// for, never a password decrypted.
pub const Preview = struct {
    bookmarks: usize = 0,
    places: usize = 0,
    passwords: usize = 0,
    /// Chrome Web Store ids, for a Chromium browser.
    extensions: []const []const u8 = &.{},
};

/// The bookmarks, and whether every profile asked for read cleanly.
pub const BookmarkRead = struct { nodes: []Bookmark, complete: bool };

pub const Profile = struct {
    /// The folder's name, which is what the readers go by.
    id: []const u8,
    /// What the browser calls it, or the folder's own name.
    name: []const u8,
};

pub const Source = union(enum) {
    chromium: chromium.Source,
    mozilla: firefox.Source,

    /// "chromium-Chrome", "mozilla-Firefox". On `a`.
    pub fn id(s: Source, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}-{s}", .{ @tagName(s), s.name() });
    }

    pub fn name(s: Source) []const u8 {
        return switch (s) {
            inline else => |b| b.name,
        };
    }

    pub fn bookmarkRead(s: Source, a: std.mem.Allocator, base: Base, profile: ?[]const u8) !BookmarkRead {
        return switch (s) {
            .chromium => |b| chromium.bookmarkRead(a, base, b, profile),
            .mozilla => |b| firefox.bookmarkRead(a, base, b, profile),
        };
    }

    pub fn places(s: Source, a: std.mem.Allocator, base: Base, profile: ?[]const u8, limit: usize) ![]Place {
        return switch (s) {
            .chromium => |b| chromium.places(a, base, b, profile, limit),
            .mozilla => |b| firefox.places(a, base, b, profile, limit),
        };
    }

    /// Host → icon bytes, for the given pages (at most 400 hosts).
    pub fn icons(s: Source, a: std.mem.Allocator, base: Base, profile: ?[]const u8, urls: []const []const u8) !Icons {
        return switch (s) {
            .chromium => |b| chromium.icons(a, base, b, profile, urls, 400),
            .mozilla => |b| firefox.icons(a, base, b, profile, urls, 400),
        };
    }

    /// The passwords: for a Chromium browser, the one moment macOS asks
    /// for the key. Off the main thread (see `offMain`).
    pub fn read(s: Source, a: std.mem.Allocator, base: Base, profile: ?[]const u8) !Found {
        return switch (s) {
            .chromium => |b| chromium.read(a, base, b, profile),
            .mozilla => |b| firefox.read(a, base, b, profile),
        };
    }

    /// Whether its passwords are behind a key macOS asks about.
    pub fn asksForKey(s: Source) bool {
        return s == .chromium;
    }

    /// Every profile, by the name the browser gives it. A browser's own
    /// Guest and System profiles aren't anybody's, and aren't offered.
    pub fn profiles(s: Source, a: std.mem.Allocator, base: Base) ![]Profile {
        var out: std.ArrayList(Profile) = .empty;
        switch (s) {
            .chromium => |b| {
                const state = try b.localState(a, base);
                const root = try b.root(a, base);
                var ids: std.ArrayList([]const u8) = .empty;
                for (try b.profiles(a, base)) |folder| {
                    const n = std.fs.path.basename(folder);
                    if (std.mem.eql(u8, n, "Guest Profile") or std.mem.eql(u8, n, "System Profile")) continue;
                    try ids.append(a, n);
                }
                std.mem.sort([]const u8, ids.items, {}, struct {
                    fn less(_: void, x: []const u8, y: []const u8) bool {
                        return naturalOrder(x, y) == .lt;
                    }
                }.less);
                for (ids.items) |n| try out.append(a, .{
                    .id = n,
                    .name = state.names.get(n) orelse if (std.mem.eql(u8, n, std.fs.path.basename(root))) b.name else n,
                });
            },
            .mozilla => |b| {
                const ini = try b.ini(a, base);
                var seen: std.StringHashMapUnmanaged(void) = .empty;
                for (try b.files(a, base)) |file| {
                    const n = std.fs.path.basename(std.fs.path.dirname(file) orelse continue);
                    if ((try seen.getOrPut(a, n)).found_existing) continue;
                    try out.append(a, .{ .id = n, .name = ini.names.get(n) orelse n });
                }
            },
        }
        return out.items;
    }

    /// The profile used most recently, which is the one brought in unless
    /// another is chosen: what the browser says it used last, or else the
    /// profile whose files changed last.
    pub fn usual(s: Source, a: std.mem.Allocator, base: Base) !?[]const u8 {
        const list = try s.profiles(a, base);
        const has = struct {
            fn has(l: []const Profile, wanted: []const u8) bool {
                for (l) |p| if (std.mem.eql(u8, p.id, wanted)) return true;
                return false;
            }
        }.has;
        switch (s) {
            .chromium => |b| {
                const state = try b.localState(a, base);
                for (state.last) |last| if (has(list, last)) return last;
                var best: ?[]const u8 = null;
                var latest = -std.math.inf(f64);
                for (try b.profiles(a, base)) |folder| {
                    const n = std.fs.path.basename(folder);
                    if (!has(list, n)) continue;
                    var touched = -std.math.inf(f64);
                    for ([_][]const u8{ "History", "Bookmarks", "Login Data" }) |f| {
                        touched = @max(touched, files.modified(try files.join(a, folder, f)));
                    }
                    if (best == null or touched > latest) {
                        best = n;
                        latest = touched;
                    }
                }
                return best;
            },
            .mozilla => |b| {
                if ((try b.ini(a, base)).usual) |u| if (has(list, u)) return u;
                // The files come newest first.
                return if (list.len > 0) list[0].id else null;
            },
        }
    }

    pub fn preview(s: Source, a: std.mem.Allocator, base: Base, profile: ?[]const u8) !Preview {
        return switch (s) {
            .chromium => |b| chromium.preview(a, base, b, profile, 3000),
            .mozilla => |b| firefox.preview(a, base, b, profile, 3000),
        };
    }

    /// Arc's spaces and pins, null for any other browser.
    pub fn arcSidebar(s: Source, a: std.mem.Allocator, base: Base, profile: ?[]const u8) !?arc.Sidebar {
        if (s != .chromium or !std.mem.eql(u8, s.chromium.name, "Arc")) return null;
        return arc.sidebar(a, base, profile);
    }

    pub fn arcCounts(s: Source, a: std.mem.Allocator, base: Base, profile: ?[]const u8) !?arc.Counts {
        const side = try s.arcSidebar(a, base, profile) orelse return null;
        return side.counts();
    }
};

pub const Icons = std.StringArrayHashMapUnmanaged([]const u8);

/// Every browser on this Mac with something to read: Chromium's, then Mozilla's.
pub fn installed(a: std.mem.Allocator, base: Base) ![]Source {
    var out: std.ArrayList(Source) = .empty;
    for (chromium.known) |b| if ((try b.profiles(a, base)).len > 0) try out.append(a, .{ .chromium = b });
    for (firefox.known) |b| if ((try b.files(a, base)).len > 0) try out.append(a, .{ .mozilla = b });
    return out.items;
}

/// Whether Safari is on this Mac: its data is kept from other apps, so the
/// sheet says how to export it instead.
pub fn safari() bool {
    return files.exists("/Applications/Safari.app");
}

// MARK: - off the main thread

/// `work(job)` on a global user-initiated queue, then `done(ctx, result)` on
/// the main thread. The result and everything it points at live in its
/// `arena`; the receiver calls `deinit` on it when finished with it.
pub fn Job(comptime In: type, comptime Out: type) type {
    return struct {
        const Self = @This();
        arena: std.heap.ArenaAllocator,
        input: In,
        output: anyerror!Out = error.Unreadable,
        work: *const fn (a: std.mem.Allocator, input: In) anyerror!Out,
        ctx: ?*anyopaque,
        done: *const fn (ctx: ?*anyopaque, job: *Self) void,

        pub fn start(
            gpa: std.mem.Allocator,
            input: In,
            work: *const fn (a: std.mem.Allocator, input: In) anyerror!Out,
            ctx: ?*anyopaque,
            done: *const fn (ctx: ?*anyopaque, job: *Self) void,
        ) !void {
            const job = try gpa.create(Self);
            job.* = .{ .arena = .init(gpa), .input = input, .work = work, .ctx = ctx, .done = done };
            dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), job, run);
        }

        fn run(raw: ?*anyopaque) callconv(.c) void {
            const job: *Self = @ptrCast(@alignCast(raw.?));
            {
                const pool = objc.Pool.push();
                defer pool.pop();
                job.output = job.work(job.arena.allocator(), job.input);
            }
            objc.dispatchMain(job, deliver);
        }

        fn deliver(raw: ?*anyopaque) callconv(.c) void {
            const job: *Self = @ptrCast(@alignCast(raw.?));
            job.done(job.ctx, job);
        }

        pub fn deinit(job: *Self) void {
            const gpa = job.arena.child_allocator;
            job.arena.deinit();
            gpa.destroy(job);
        }
    };
}

/// What the panel finds when it opens (`ImportPanel.look`): every browser,
/// its profiles and the one used last, and the browsers that are on this Mac
/// with nothing where their data should be.
pub const Look = struct {
    sources: []Source,
    profiles: []const []Profile,
    usual: []const ?[]const u8,
    /// "Chrome is on this Mac, but nothing of it was found in ~/…".
    unreadable: []const []const u8,
};

pub const LookJob = Job(Base, Look);

pub fn look(gpa: std.mem.Allocator, base: Base, ctx: ?*anyopaque, done: *const fn (?*anyopaque, *LookJob) void) !void {
    try LookJob.start(gpa, base, lookWork, ctx, done);
}

/// The same, here and now (the Welcome's page reads it as it is drawn).
pub fn lookWork(a: std.mem.Allocator, base: Base) !Look {
    const found = try installed(a, base);
    const profiles = try a.alloc([]Profile, found.len);
    const most = try a.alloc(?[]const u8, found.len);
    for (found, profiles, most) |s, *p, *u| {
        p.* = try s.profiles(a, base);
        u.* = try s.usual(a, base);
    }
    var missing: std.ArrayList([]const u8) = .empty;
    for (try chromium.unreadable(a, base)) |m| {
        try missing.append(a, try std.fmt.allocPrint(a, "{s} is on this Mac, but nothing of it was found in {s}.", .{ m.source.name, m.looked }));
    }
    return .{ .sources = found, .profiles = profiles, .usual = most, .unreadable = missing.items };
}

/// One browser's counts for one profile (null: all of them), and Arc's
/// spaces and pins when it is Arc.
pub const Count = struct { preview: Preview, arc: ?arc.Counts };
pub const CountIn = struct { base: Base, source: Source, profile: ?[]const u8 };
pub const CountJob = Job(CountIn, Count);

/// `input`'s slices must outlive the job (keep them in the panel's state).
pub fn count(gpa: std.mem.Allocator, input: CountIn, ctx: ?*anyopaque, done: *const fn (?*anyopaque, *CountJob) void) !void {
    try CountJob.start(gpa, input, countWork, ctx, done);
}

fn countWork(a: std.mem.Allocator, in: CountIn) !Count {
    return .{
        .preview = try in.source.preview(a, in.base, in.profile),
        .arc = try in.source.arcCounts(a, in.base, in.profile),
    };
}

/// The passwords read off the main thread (the keychain prompt waits there).
pub const ReadJob = Job(CountIn, Found);

pub fn readPasswords(gpa: std.mem.Allocator, input: CountIn, ctx: ?*anyopaque, done: *const fn (?*anyopaque, *ReadJob) void) !void {
    try ReadJob.start(gpa, input, readWork, ctx, done);
}

fn readWork(a: std.mem.Allocator, in: CountIn) !Found {
    return in.source.read(a, in.base, in.profile);
}

// MARK: - what every reader shares

pub const Value = std.json.Value;

/// A JSON file's top value, or null when it won't read.
pub fn readJson(a: std.mem.Allocator, path: []const u8) ?Value {
    const bytes = @import("../data/disk.zig").read(a, path) orelse return null;
    return parseJson(a, bytes);
}

pub fn parseJson(a: std.mem.Allocator, bytes: []const u8) ?Value {
    const parsed = json.decode(Value, a, bytes) catch return null;
    return parsed.value;
}

/// `v[key]` when `v` is an object.
pub fn field(v: ?Value, key: []const u8) ?Value {
    const o = v orelse return null;
    return if (o == .object) o.object.get(key) else null;
}

pub fn text(v: ?Value) ?[]const u8 {
    const s = v orelse return null;
    return if (s == .string) s.string else null;
}

pub fn items(v: ?Value) []Value {
    const s = v orelse return &.{};
    return if (s == .array) s.array.items else &.{};
}

/// `URL(string:)` with a scheme of exactly `http` or `https`.
pub fn isWeb(address: []const u8) bool {
    const p = Parts.parse(address) orelse return false;
    const s = p.scheme orelse return false;
    return std.mem.eql(u8, s, "http") or std.mem.eql(u8, s, "https");
}

/// Newest first, then the first `limit`.
pub fn newest(list: []Place, limit: usize) []Place {
    std.mem.sort(Place, list, {}, struct {
        fn later(_: void, x: Place, y: Place) bool {
            return x.last > y.last;
        }
    }.later);
    return list[0..@min(limit, list.len)];
}

/// `localizedStandardCompare`, as far as profile folders need it: case
/// aside, and runs of digits by their value ("Profile 2" before "Profile 10").
pub fn naturalOrder(x: []const u8, y: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        if (std.ascii.isDigit(x[i]) and std.ascii.isDigit(y[j])) {
            const si = i;
            const sj = j;
            while (i < x.len and std.ascii.isDigit(x[i])) i += 1;
            while (j < y.len and std.ascii.isDigit(y[j])) j += 1;
            const nx = std.mem.trimStart(u8, x[si..i], "0");
            const ny = std.mem.trimStart(u8, y[sj..j], "0");
            const o = if (nx.len != ny.len) std.math.order(nx.len, ny.len) else std.mem.order(u8, nx, ny);
            if (o != .eq) return o;
            continue;
        }
        const o = std.math.order(std.ascii.toLower(x[i]), std.ascii.toLower(y[j]));
        if (o != .eq) return o;
        i += 1;
        j += 1;
    }
    return std.math.order(x.len - i, y.len - j);
}
