//! The site a host belongs to (`Registrable.swift`): the label just above
//! its public suffix. `registrable` asks macOS's own list, as `Vault` does.
const std = @import("std");
const objc = @import("nanoui").objc;
const url_mod = @import("url.zig");

pub const IsSuffix = *const fn (name: []const u8) bool;

/// `Registrable.domain(of:isSuffix:)`, on `gpa`.
pub fn domain(gpa: std.mem.Allocator, host: []const u8, is_suffix: ?IsSuffix) ![]u8 {
    const lowered = try url_mod.lower(gpa, host);
    defer gpa.free(lowered);
    const name = std.mem.trim(u8, lowered, ".");
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, name, '.');
    while (it.next()) |l| try labels.append(gpa, l);
    const address = std.mem.indexOfScalar(u8, name, ':') != null or for (labels.items) |l| {
        if (!allDigits(l)) break false;
    } else true;
    const test_suffix = is_suffix orelse return gpa.dupe(u8, name);
    if (address or labels.items.len <= 1 or test_suffix(name)) return gpa.dupe(u8, name);
    var count = labels.items.len - 1;
    while (count >= 1) : (count -= 1) {
        const suffix = try std.mem.join(gpa, ".", labels.items[labels.items.len - count ..]);
        defer gpa.free(suffix);
        if (test_suffix(suffix)) return std.mem.join(gpa, ".", labels.items[labels.items.len - count - 1 ..]);
    }
    return gpa.dupe(u8, name);
}

fn allDigits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

const CFSuffix = *const fn (objc.Object) callconv(.c) bool;
var cf_suffix: ?CFSuffix = null;
var looked = false;

/// WebKit's own public-suffix test (`_CFHostIsDomainTopLevel`, private to
/// CFNetwork), or null when this macOS lacks it. Main thread.
pub fn publicSuffix() ?IsSuffix {
    if (!looked) {
        looked = true;
        const lib = std.c.dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", .{ .NOW = true });
        if (std.c.dlsym(lib, "_CFHostIsDomainTopLevel")) |sym| cf_suffix = @ptrCast(@alignCast(sym));
    }
    return if (cf_suffix != null) isPublicSuffix else null;
}

fn isPublicSuffix(name: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    return cf_suffix.?(objc.nsString(name));
}

/// `Vault.registrable`, on `gpa`.
pub fn registrable(gpa: std.mem.Allocator, host: []const u8) ![]u8 {
    return domain(gpa, host, publicSuffix());
}

fn testSuffix(name: []const u8) bool {
    for ([_][]const u8{ "com", "uk", "co.uk", "github.io" }) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

fn expectDomain(host: []const u8, is_suffix: ?IsSuffix, want: []const u8) !void {
    const got = try domain(std.testing.allocator, host, is_suffix);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "registrable domain is the site above a suffix" {
    try expectDomain("accounts.example.com", testSuffix, "example.com");
    try expectDomain("www.bbc.co.uk", testSuffix, "bbc.co.uk");
    try expectDomain("bbc.co.uk", testSuffix, "bbc.co.uk");
}

test "registrable domain never spans tenants of a suffix" {
    try expectDomain("alice.github.io", testSuffix, "alice.github.io");
    try expectDomain("bob.github.io", testSuffix, "bob.github.io");
    try expectDomain("github.io", testSuffix, "github.io");
}

test "registrable domain leaves addresses whole" {
    try expectDomain("192.168.1.10", testSuffix, "192.168.1.10");
    try expectDomain("[::1]", testSuffix, "[::1]");
}

test "registrable domain without a suffix list is the host" {
    try expectDomain("accounts.example.com", null, "accounts.example.com");
    try expectDomain(".Accounts.Example.COM.", null, "accounts.example.com");
}

test "registrable asks macOS's suffix list" {
    const got = try registrable(std.testing.allocator, "mail.google.com");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(if (publicSuffix() != null) "google.com" else "mail.google.com", got);
}

test {
    std.testing.refAllDecls(@This());
}
