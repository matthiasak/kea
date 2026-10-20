//! Where passwords live (Vault.swift): the macOS keychain, as internet
//! passwords keyed by site and account under KeaZig's own label. A run with
//! its own folder (`kea.opts.root`, tests) never touches the keychain or
//! asks the Mac who you are: writes report saved, reads find nothing, and
//! proving succeeds (plan P10.2).
const std = @import("std");
const objc = @import("nanoui").objc;
const kc = @import("../sys/keychain_internet.zig");
const Store = @import("../data/store.zig").Store;
const reg = @import("../data/registrable.zig");
const url = @import("../data/url.zig");
const app = @import("../app/kea.zig");
const csv = @import("vault_csv.zig");

/// What every item of ours is tagged with (Swift's `label`, by the app-name rule).
pub const label = "Kea";
const never_key = "passwords.never";

/// A name and password, with its secret: only for filling in and saving.
pub const Login = struct {
    host: []u8,
    user: []u8,
    password: []u8,
    /// When it last signed in, as unix seconds (the item's comment).
    used: ?f64 = null,
    /// Kept from a page sent over plain http: only offered on such a page.
    clear: bool = false,

    pub fn deinit(self: Login, gpa: std.mem.Allocator) void {
        gpa.free(self.host);
        gpa.free(self.user);
        gpa.free(self.password);
    }

    pub fn clone(self: Login, gpa: std.mem.Allocator) !Login {
        const h = try gpa.dupe(u8, self.host);
        errdefer gpa.free(h);
        const u = try gpa.dupe(u8, self.user);
        errdefer gpa.free(u);
        return .{ .host = h, .user = u, .password = try gpa.dupe(u8, self.password), .used = self.used, .clear = self.clear };
    }

    /// Swift's synthesized `==`.
    pub fn eql(a: Login, b: Login) bool {
        return std.mem.eql(u8, a.host, b.host) and std.mem.eql(u8, a.user, b.user) and
            std.mem.eql(u8, a.password, b.password) and std.meta.eql(a.used, b.used) and a.clear == b.clear;
    }
};

/// One item as a list needs it, without the secret (`Kept`).
pub const Kept = struct {
    host: []u8,
    user: []u8,
    used: ?f64 = null,
    clear: bool = false,

    pub fn deinit(self: Kept, gpa: std.mem.Allocator) void {
        gpa.free(self.host);
        gpa.free(self.user);
    }
};

pub fn freeLogins(gpa: std.mem.Allocator, list: []Login) void {
    for (list) |l| l.deinit(gpa);
    gpa.free(list);
}

pub fn freeKept(gpa: std.mem.Allocator, list: []Kept) void {
    for (list) |k| k.deinit(gpa);
    gpa.free(list);
}

pub const Taken = csv.Taken;
pub const Progress = csv.Progress;
pub const parseCsv = csv.parse;
pub const freeRows = csv.freeRows;

pub const Vault = struct {
    gpa: std.mem.Allocator,
    store: *const Store,
    /// Never the keychain, never LocalAuthentication.
    guarded: bool,

    pub fn of(kea: *app.Kea) Vault {
        return .{ .gpa = kea.gpa, .store = &kea.store, .guarded = kea.opts.root != null };
    }

    // MARK: reading

    /// What is kept for a host, exactly (`logins(for:)`).
    pub fn logins(v: Vault, host_name: []const u8) ![]Login {
        const rows = try v.list(host_name);
        defer freeKept(v.gpa, rows);
        return v.withSecrets(rows, null);
    }

    /// The host first, then anything sharing its registrable domain, newest
    /// use first (`logins(matching:)`).
    pub fn loginsMatching(v: Vault, host_name: []const u8) ![]Login {
        const exact = try v.logins(host_name);
        defer v.gpa.free(exact);
        const rows = try v.list(null);
        defer freeKept(v.gpa, rows);
        const wider = try v.withSecrets(rows, host_name);
        defer v.gpa.free(wider);
        const out = try std.mem.concat(v.gpa, Login, &.{ exact, wider });
        std.sort.block(Login, out, {}, struct {
            fn newer(_: void, a: Login, b: Login) bool {
                return (a.used orelse -std.math.inf(f64)) > (b.used orelse -std.math.inf(f64));
            }
        }.newer);
        return out;
    }

    /// Everything this app holds, without secrets, by host then user (`all()`).
    pub fn all(v: Vault) ![]Kept {
        const rows = try v.list(null);
        std.sort.block(Kept, rows, {}, struct {
            fn before(_: void, a: Kept, b: Kept) bool {
                const by_host = std.mem.order(u8, a.host, b.host);
                return if (by_host == .eq) std.mem.lessThan(u8, a.user, b.user) else by_host == .lt;
            }
        }.before);
        return rows;
    }

    /// One item's secret, read when a password is shown or copied (`secret(of:)`).
    pub fn secretOf(v: Vault, kept: Kept) ?[]u8 {
        return v.secret(kept.host, kept.user);
    }

    fn secret(v: Vault, host_name: []const u8, user: []const u8) ?[]u8 {
        if (v.guarded) return null;
        const pool = objc.Pool.push();
        defer pool.pop();
        var status: i32 = 0;
        const out = kc.secret(v.gpa, label, host_name, user, &status);
        if (out == null and status != kc.item_not_found) std.log.warn("Vault: keychain read failed ({d})", .{status});
        return out;
    }

    /// The items' attributes, narrowed to a server when given (`rows(where:)`).
    fn list(v: Vault, server: ?[]const u8) ![]Kept {
        if (v.guarded) return &.{};
        const Collect = struct {
            gpa: std.mem.Allocator,
            out: std.ArrayList(Kept) = .empty,
            failed: bool = false,
            fn each(c: *@This(), row: kc.Row) void {
                const h = row.server orelse return;
                const kept = Kept{
                    .host = c.gpa.dupe(u8, h) catch return fail(c),
                    .user = c.gpa.dupe(u8, row.account) catch return fail(c),
                    .used = if (row.comment) |text| std.fmt.parseFloat(f64, text) catch null else null,
                    .clear = row.clear,
                };
                c.out.append(c.gpa, kept) catch {
                    kept.deinit(c.gpa);
                    fail(c);
                };
            }
            fn fail(c: *@This()) void {
                c.failed = true;
            }
        };
        var c: Collect = .{ .gpa = v.gpa };
        const pool = objc.Pool.push();
        defer pool.pop();
        const status = kc.rows(label, server, &c, Collect.each);
        if (status != kc.success) std.log.warn("Vault: keychain list failed ({d})", .{status});
        if (c.failed) {
            for (c.out.items) |k| k.deinit(v.gpa);
            c.out.deinit(v.gpa);
            return error.OutOfMemory;
        }
        return c.out.toOwnedSlice(v.gpa);
    }

    /// `login(from:)` for each row, with its secret; rows without one are
    /// dropped. With `wider_than`, only other hosts of its site (`wider`).
    fn withSecrets(v: Vault, rows: []const Kept, wider_than: ?[]const u8) ![]Login {
        var out: std.ArrayList(Login) = .empty;
        errdefer {
            for (out.items) |l| l.deinit(v.gpa);
            out.deinit(v.gpa);
        }
        for (rows) |r| {
            if (wider_than) |h| if (!try sameSite(v.gpa, h, r.host, reg.publicSuffix())) continue;
            const password = v.secret(r.host, r.user) orelse continue;
            errdefer v.gpa.free(password);
            const h = try v.gpa.dupe(u8, r.host);
            errdefer v.gpa.free(h);
            const u = try v.gpa.dupe(u8, r.user);
            errdefer v.gpa.free(u);
            try out.append(v.gpa, .{ .host = h, .user = u, .password = password, .used = r.used, .clear = r.clear });
        }
        return out.toOwnedSlice(v.gpa);
    }

    // MARK: writing

    /// Updated if ours is there, else added. Whether it was kept.
    pub fn save(v: Vault, host_name: []const u8, user: []const u8, password: []const u8, used: ?f64, clear: bool) bool {
        if (host_name.len == 0 or password.len == 0) return false;
        if (v.guarded) return true;
        const pool = objc.Pool.push();
        defer pool.pop();
        var buf: [64]u8 = undefined;
        const comment = if (used) |u| swiftDouble(&buf, u) else null;
        return kc.save(label, host_name, user, password, comment, clear);
    }

    /// It was just used to sign in (`touch`): lists put it first from now on.
    pub fn touch(v: Vault, login: Login, now_unix: f64) void {
        _ = v.save(login.host, login.user, login.password, now_unix, login.clear);
    }

    pub fn forget(v: Vault, host_name: []const u8, user: []const u8) void {
        if (v.guarded) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        kc.forget(label, host_name, user);
    }

    pub const takeCsv = csv.take;

    // MARK: sites that asked not to be asked

    /// `never`, on `gpa` (sorted as written).
    pub fn never(v: Vault) ![][]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |s| v.gpa.free(s);
            out.deinit(v.gpa);
        }
        const array = objc.msg(?objc.Object, v.store.defaults, "stringArrayForKey:", .{objc.nsString(never_key)}) orelse return out.toOwnedSlice(v.gpa);
        for (0..objc.msg(objc.NSUInteger, array, "count", .{})) |i| {
            const s = objc.fromNSString(objc.msg(objc.Object, array, "objectAtIndex:", .{@as(objc.NSUInteger, i)}));
            try out.append(v.gpa, try v.gpa.dupe(u8, s));
        }
        return out.toOwnedSlice(v.gpa);
    }

    /// `never = …`: the set written sorted, without repeats.
    pub fn setNever(v: Vault, hosts: []const []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const set = objc.msg(objc.Object, objc.class("NSMutableSet"), "set", .{});
        for (hosts) |h| objc.msg(void, set, "addObject:", .{objc.nsString(h)});
        const sorted = objc.msg(objc.Object, objc.msg(objc.Object, set, "allObjects", .{}), "sortedArrayUsingSelector:", .{objc.sel("compare:")});
        objc.msg(void, v.store.defaults, "setObject:forKey:", .{ sorted, objc.nsString(never_key) });
    }

    pub fn addNever(v: Vault, host_name: []const u8) void {
        const list_now = v.never() catch return;
        defer freeStrings(v.gpa, list_now);
        const more = std.mem.concat(v.gpa, []const u8, &.{ @as([]const []const u8, @ptrCast(list_now)), &.{host_name} }) catch return;
        defer v.gpa.free(more);
        v.setNever(more);
    }

    pub fn isNever(v: Vault, host_name: []const u8) bool {
        const list_now = v.never() catch return false;
        defer freeStrings(v.gpa, list_now);
        const site = registrable(v.gpa, host_name) catch return false;
        defer v.gpa.free(site);
        for (list_now) |h| if (std.mem.eql(u8, h, host_name) or std.mem.eql(u8, h, site)) return true;
        return false;
    }

    // MARK: showing one

    /// Touch ID, the watch, or the account password; `done(ctx, ok)` on the
    /// main thread. A Mac with no way to ask has nothing to prove (`prove`).
    pub fn prove(v: Vault, reason: []const u8, ctx: *anyopaque, done: *const fn (*anyopaque, bool) void) void {
        if (v.guarded) return done(ctx, true);
        const pool = objc.Pool.push();
        defer pool.pop();
        const la = objc.msg(objc.Object, objc.alloc("LAContext"), "init", .{});
        if (!objc.msg(objc.BOOL, la, "canEvaluatePolicy:error:", .{ device_owner, @as(?*anyopaque, null) })) {
            objc.release(la);
            return done(ctx, true);
        }
        const p = std.heap.c_allocator.create(Proof) catch {
            objc.release(la);
            return done(ctx, false);
        };
        p.* = .{ .ctx = ctx, .done = done, .la = la };
        var block = ProofBlock.init(p, replied);
        objc.msg(void, la, "evaluatePolicy:localizedReason:reply:", .{ device_owner, objc.nsString(reason), @as(*anyopaque, @ptrCast(&block)) });
    }
};

/// `LAPolicyDeviceOwnerAuthentication`.
const device_owner: objc.NSInteger = 2;

const Proof = struct { ctx: *anyopaque, done: *const fn (*anyopaque, bool) void, la: objc.Object, ok: bool = false };
const ProofBlock = objc.Block(Proof, &.{ objc.BOOL, ?objc.Object });

/// On LocalAuthentication's queue: the answer goes to the main thread.
fn replied(p: *Proof, ok: objc.BOOL, _: ?objc.Object) void {
    p.ok = ok;
    objc.dispatchMain(p, proven);
}

fn proven(ctx: ?*anyopaque) callconv(.c) void {
    const p: *Proof = @ptrCast(@alignCast(ctx.?));
    defer {
        objc.release(p.la);
        std.heap.c_allocator.destroy(p);
    }
    p.done(p.ctx, p.ok);
}

fn freeStrings(gpa: std.mem.Allocator, list: [][]u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

/// Swift's `String(Double)`: shortest round trip, ".0" on a whole number.
pub fn swiftDouble(buf: []u8, value: f64) []const u8 {
    const text = std.fmt.bufPrint(buf, "{d}", .{value}) catch return "0.0";
    if (std.mem.indexOfAny(u8, text, ".einf") != null or text.len + 2 > buf.len) return text;
    buf[text.len] = '.';
    buf[text.len + 1] = '0';
    return buf[0 .. text.len + 2];
}

// MARK: the site behind a host

/// example.com for www.example.com and accounts.example.com; bbc.co.uk
/// stays bbc.co.uk (`Vault.registrable`).
pub const registrable = reg.registrable;

/// `logins(matching:)`'s wider rule: `other` is another host of `host`'s
/// site, by `is_suffix`'s public-suffix list (`reg.publicSuffix()` for macOS's).
pub fn sameSite(gpa: std.mem.Allocator, host_name: []const u8, other: []const u8, is_suffix: ?reg.IsSuffix) !bool {
    if (std.mem.eql(u8, other, host_name)) return false;
    const domain = try reg.domain(gpa, host_name, is_suffix);
    defer gpa.free(domain);
    const site = try reg.domain(gpa, other, is_suffix);
    defer gpa.free(site);
    return std.mem.eql(u8, site, domain);
}

/// A website's host from an export's address: http(s) only, lowercased,
/// without "www." (`host(of:)`); empty when it isn't a website's.
pub fn host(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const value = std.mem.trim(u8, text, " \t");
    const full = if (std.mem.indexOf(u8, value, "://") == null) try std.fmt.allocPrint(gpa, "https://{s}", .{value}) else try gpa.dupe(u8, value);
    defer gpa.free(full);
    const parts = url.Parts.parse(full) orelse return gpa.dupe(u8, "");
    if (!parts.isWeb()) return gpa.dupe(u8, "");
    const name = parts.hostName() orelse return gpa.dupe(u8, "");
    const lowered = try url.lower(gpa, name);
    if (!std.mem.startsWith(u8, lowered, "www.")) return lowered;
    defer gpa.free(lowered);
    return gpa.dupe(u8, lowered[4..]);
}
