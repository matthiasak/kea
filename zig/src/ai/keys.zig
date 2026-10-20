//! The keys (`AIKeys` in AI.swift): in the keychain, or fetched when a
//! request needs one from a variable or a command the user named.
//!
//! A signed release keeps them in the data protection keychain, under the
//! app's own access group; a copy built from source keeps them in the login
//! keychain instead. Either way this Mac only, never synced, and each kept
//! for its provider's host (account "provider@host"). Test runs keep theirs
//! in memory, for the run: they never reach the keychain.
//!
//! A key is read the moment a request needs it and let go with the request:
//! never in the settings file, a log line or an error.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Store = @import("../data/store.zig").Store;
const keychain = @import("../sys/keychain.zig");
const ai = @import("ai.zig");
const app_name = "KeaZig";

pub const service = "app.kea.browser.ai";
/// Kept by account ("provider@host"): were a provider's host to change, the
/// variable or command is no longer used for it, so a key never goes to a new host.
pub const sources_key = "ai.keySources";

pub const Saved = enum { kept, failed };

/// Where a key comes from. Strings are the caller's (see `source`).
pub const Source = union(enum) { keychain, environment: []const u8, command: []const u8 };

/// A key, or none; owned by the receiver, who frees it with `gpa`.
pub const Then = *const fn (ctx: *anyopaque, key: ?[]u8) void;

pub const Keys = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    testing: bool,
    /// A test run's, by account, gone when it quits.
    rehearsal: std.StringHashMapUnmanaged([]u8) = .empty,
    /// Whether this copy has the access group the data protection keychain needs.
    protected: ?bool = null,

    pub fn deinit(self: *Keys) void {
        self.clearRehearsal();
        self.rehearsal.deinit(self.gpa);
    }

    fn clearRehearsal(self: *Keys) void {
        var it = self.rehearsal.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.rehearsal.clearRetainingCapacity();
    }

    fn isProtected(self: *Keys) bool {
        if (self.testing) return true;
        if (self.protected == null) self.protected = keychain.protectedAllowed(service);
        return self.protected.?;
    }

    /// "provider@host", on `a`.
    pub fn account(_: *Keys, a: std.mem.Allocator, m: *const ai.Ai, p: ai.Provider) ![]u8 {
        const h = try m.host(a, p);
        defer a.free(h);
        return std.fmt.allocPrint(a, "{s}@{s}", .{ p.id, h });
    }

    fn query(self: *Keys, acct: []const u8) keychain.Query {
        return .{ .service = service, .account = acct, .protected = self.isProtected() };
    }

    pub fn save(self: *Keys, m: *const ai.Ai, typed: []const u8, p: ai.Provider) Saved {
        const k = std.mem.trim(u8, typed, " \t\r\n");
        if (k.len == 0 or !p.takesKey()) return .failed;
        self.setSource(m, .keychain, p);
        const acct = self.account(self.gpa, m, p) catch return .failed;
        if (self.testing) {
            const value = self.gpa.dupe(u8, k) catch {
                self.gpa.free(acct);
                return .failed;
            };
            const e = self.rehearsal.getOrPut(self.gpa, acct) catch {
                self.gpa.free(acct);
                self.gpa.free(value);
                return .failed;
            };
            if (e.found_existing) {
                self.gpa.free(acct);
                self.gpa.free(e.value_ptr.*);
            }
            e.value_ptr.* = value;
            return .kept;
        }
        defer self.gpa.free(acct);
        const q = self.query(acct);
        keychain.delete(q);
        const label = std.fmt.allocPrint(self.gpa, "{s} — {s} key", .{ app_name, p.name }) catch return .failed;
        defer self.gpa.free(label);
        const protected = self.isProtected();
        // The last four, to tell keys apart in Settings without reading one.
        const kept = keychain.save(q, k, .{
            .accessible = if (protected) .when_unlocked_this_device_only else .when_unlocked,
            .synchronizable = if (protected) false else null,
            .label = label,
            .comment = suffix(k, 4),
        });
        return if (kept) .kept else .failed;
    }

    // MARK: where a key comes from

    /// Where `p`'s key comes from; strings on `a`.
    pub fn source(self: *Keys, a: std.mem.Allocator, m: *const ai.Ai, p: ai.Provider) Source {
        const acct = self.account(self.gpa, m, p) catch return .keychain;
        defer self.gpa.free(acct);
        const pool = objc.Pool.push();
        defer pool.pop();
        const dict = objc.msg(?objc.Object, self.store.defaults, "dictionaryForKey:", .{objc.nsString(sources_key)}) orelse return .keychain;
        const saved = objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(acct)}) orelse return .keychain;
        if (!objc.msg(objc.BOOL, saved, "isKindOfClass:", .{objc.class("NSString")})) return .keychain;
        const text = objc.fromNSString(saved);
        if (std.mem.startsWith(u8, text, "env:")) return .{ .environment = a.dupe(u8, text[4..]) catch return .keychain };
        if (std.mem.startsWith(u8, text, "cmd:")) return .{ .command = a.dupe(u8, text[4..]) catch return .keychain };
        return .keychain;
    }

    /// `.keychain` removes the entry. A name that isn't a variable's, or an
    /// empty command, is ignored.
    pub fn setSource(self: *Keys, m: *const ai.Ai, s: Source, p: ai.Provider) void {
        const acct = self.account(self.gpa, m, p) catch return;
        defer self.gpa.free(acct);
        const pool = objc.Pool.push();
        defer pool.pop();
        const all = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});
        if (objc.msg(?objc.Object, self.store.defaults, "dictionaryForKey:", .{objc.nsString(sources_key)})) |d| {
            // Only the [String: String] entries, as `as? [String: String]` reads them.
            const keys = objc.msg(objc.Object, d, "allKeys", .{});
            for (0..objc.msg(objc.NSUInteger, keys, "count", .{})) |i| {
                const k = objc.msg(objc.Object, keys, "objectAtIndex:", .{i});
                const v = objc.msg(objc.Object, d, "objectForKey:", .{k});
                if (objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) objc.msg(void, all, "setObject:forKey:", .{ v, k });
            }
        }
        const k = objc.nsString(acct);
        switch (s) {
            .keychain => objc.msg(void, all, "removeObjectForKey:", .{k}),
            .environment => |name| {
                if (!isVariableName(name)) return;
                const v = std.mem.concat(self.gpa, u8, &.{ "env:", name }) catch return;
                defer self.gpa.free(v);
                objc.msg(void, all, "setObject:forKey:", .{ objc.nsString(v), k });
            },
            .command => |command| {
                if (command.len == 0) return;
                const v = std.mem.concat(self.gpa, u8, &.{ "cmd:", command }) catch return;
                defer self.gpa.free(v);
                objc.msg(void, all, "setObject:forKey:", .{ objc.nsString(v), k });
            },
        }
        objc.msg(void, self.store.defaults, "setObject:forKey:", .{ all, objc.nsString(sources_key) });
    }

    /// The key, for the request about to go out, to `then` on the main
    /// thread — at once from the keychain or the environment, after a shell
    /// when a variable isn't set here or a command names it.
    pub fn key(self: *Keys, m: *const ai.Ai, p: ai.Provider, ctx: *anyopaque, then: Then) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        switch (self.source(arena.allocator(), m, p)) {
            .keychain => then(ctx, self.keychainKey(m, p)),
            .environment => |name| {
                // An app started from the Dock has none of the shell's variables: ask a shell.
                const z = arena.allocator().dupeSentinel(u8, name, 0) catch return then(ctx, null);
                if (std.c.getenv(z)) |v| if (std.mem.span(v).len > 0) return then(ctx, self.gpa.dupe(u8, std.mem.span(v)) catch null);
                const command = std.fmt.allocPrint(arena.allocator(), "printenv {s}", .{name}) catch return then(ctx, null);
                @import("shell.zig").run(self.gpa, command, ctx, then);
            },
            .command => |command| @import("shell.zig").run(self.gpa, command, ctx, then),
        }
    }

    fn keychainKey(self: *Keys, m: *const ai.Ai, p: ai.Provider) ?[]u8 {
        const acct = self.account(self.gpa, m, p) catch return null;
        defer self.gpa.free(acct);
        if (self.testing) return if (self.rehearsal.get(acct)) |k| self.gpa.dupe(u8, k) catch null else null;
        const data = keychain.load(self.gpa, self.query(acct)) orelse return null;
        if (!std.unicode.utf8ValidateSlice(data)) {
            self.gpa.free(data);
            return null;
        }
        return data;
    }

    /// "••••1a2b" for one that is kept, without reading the key itself;
    /// where it comes from otherwise. Never runs anything. On `a`.
    pub fn hint(self: *Keys, a: std.mem.Allocator, m: *const ai.Ai, p: ai.Provider) ?[]const u8 {
        switch (self.source(a, m, p)) {
            .environment => |name| return std.mem.concat(a, u8, &.{ "$", name }) catch null,
            .command => return "from a command",
            .keychain => {},
        }
        const acct = self.account(self.gpa, m, p) catch return null;
        defer self.gpa.free(acct);
        if (self.testing) {
            const k = self.rehearsal.get(acct) orelse return null;
            return std.mem.concat(a, u8, &.{ "••••", suffix(k, 4) }) catch null;
        }
        const c = keychain.comment(self.gpa, self.query(acct)) orelse return null;
        defer self.gpa.free(c);
        return std.mem.concat(a, u8, &.{ "••••", c }) catch null;
    }

    pub fn forget(self: *Keys, m: *const ai.Ai, p: ai.Provider) void {
        self.setSource(m, .keychain, p);
        const acct = self.account(self.gpa, m, p) catch return;
        defer self.gpa.free(acct);
        if (self.testing) {
            if (self.rehearsal.fetchRemove(acct)) |e| {
                self.gpa.free(e.key);
                self.gpa.free(e.value);
            }
            return;
        }
        keychain.delete(self.query(acct));
    }

    pub fn forgetAll(self: *Keys) void {
        self.store.remove(sources_key);
        self.clearRehearsal();
        if (!self.testing) keychain.delete(.{ .service = service, .protected = self.isProtected() });
    }
};

pub fn isVariableName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

/// The last `n` characters (code points), as `String.suffix(n)`.
// ponytail: code points, not grapheme clusters; keys are ASCII.
pub fn suffix(s: []const u8, n: usize) []const u8 {
    var i = s.len;
    var left = n;
    while (i > 0 and left > 0) {
        i -= 1;
        while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
        left -= 1;
    }
    return s[i..];
}
