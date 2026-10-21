//! Taking in a passwords export (Vault.swift `take(csv:)` and `parse(csv:)`):
//! a CSV as Google Password Manager, Chrome or Dia write it. Read once, put in
//! the keychain; no copy of it is kept.
const std = @import("std");
const vault = @import("vault.zig");

pub const Taken = struct { kept: usize = 0, skipped: usize = 0 };
pub const Login = vault.Login;

/// The import worker's control (`ImportFile.Control`): progress and cancel.
pub const Progress = struct {
    ctx: *anyopaque,
    report: *const fn (ctx: *anyopaque, message: []const u8, completed: usize, total: ?usize) void,
    cancelled: *const fn (ctx: *anyopaque) bool,
};

const reading = "Reading password CSV…";
const saving = "Saving passwords…";

pub fn freeRows(gpa: std.mem.Allocator, rows: []const [][]u8) void {
    for (rows) |row| {
        for (row) |f| gpa.free(f);
        gpa.free(row);
    }
    gpa.free(rows);
}

/// Quoted fields, doubled quotes inside them, and newlines inside those.
/// Rows of nothing but empty fields are dropped. Cancelled → no rows.
pub fn parse(gpa: std.mem.Allocator, text: []const u8, progress: ?Progress) ![][][]u8 {
    var rows: std.ArrayList([][]u8) = .empty;
    errdefer dropAll(gpa, &rows);
    var row: std.ArrayList([]u8) = .empty;
    defer {
        for (row.items) |f| gpa.free(f);
        row.deinit(gpa);
    }
    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(gpa);
    var quoted = false;
    var i: usize = 0;
    var scanned: usize = 0;
    while (i < text.len) : (i += 1) {
        scanned += 1;
        // ponytail: counts bytes where Swift counts Characters; only the progress figure differs.
        if (scanned % 8192 == 0) if (progress) |p| {
            if (p.cancelled(p.ctx)) return cancel(gpa, &rows);
            p.report(p.ctx, reading, scanned, null);
        };
        const c = text[i];
        if (quoted) {
            if (c == '"') {
                if (i + 1 < text.len and text[i + 1] == '"') {
                    try field.append(gpa, '"');
                    i += 1;
                } else quoted = false;
            } else try field.append(gpa, c);
            continue;
        }
        switch (c) {
            '"' => quoted = true,
            ',' => try row.append(gpa, try field.toOwnedSlice(gpa)),
            '\n', '\r' => {
                // "\r\n" is one Character in Swift: one line break.
                if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
                try endRow(gpa, &rows, &row, &field);
            },
            else => try field.append(gpa, c),
        }
    }
    try endRow(gpa, &rows, &row, &field);
    if (progress) |p| {
        if (p.cancelled(p.ctx)) return cancel(gpa, &rows);
        p.report(p.ctx, reading, scanned, null);
    }
    return rows.toOwnedSlice(gpa);
}

fn cancel(gpa: std.mem.Allocator, rows: *std.ArrayList([][]u8)) [][][]u8 {
    dropAll(gpa, rows);
    return &.{};
}

fn dropAll(gpa: std.mem.Allocator, rows: *std.ArrayList([][]u8)) void {
    for (rows.items) |row| {
        for (row) |f| gpa.free(f);
        gpa.free(row);
    }
    rows.deinit(gpa);
    rows.* = .empty;
}

fn endRow(gpa: std.mem.Allocator, rows: *std.ArrayList([][]u8), row: *std.ArrayList([]u8), field: *std.ArrayList(u8)) !void {
    try row.append(gpa, try field.toOwnedSlice(gpa));
    const any = for (row.items) |f| {
        if (f.len > 0) break true;
    } else false;
    if (!any) {
        for (row.items) |f| gpa.free(f);
        row.clearRetainingCapacity();
        return;
    }
    const done = try row.toOwnedSlice(gpa);
    rows.append(gpa, done) catch |e| {
        for (done) |f| gpa.free(f);
        gpa.free(done);
        return e;
    };
}

fn column(header: []const []u8, names: []const []const u8) ?usize {
    for (header, 0..) |h, i| for (names) |n| if (std.ascii.eqlIgnoreCase(h, n)) return i;
    return null;
}

/// `take(csv:)` / `take(csv:control:)`: each row's site, name and password
/// saved; what was kept and what was skipped.
pub fn take(v: vault.Vault, text: []const u8, progress: ?Progress) !Taken {
    if (progress) |p| {
        if (p.cancelled(p.ctx)) return .{};
        p.report(p.ctx, reading, 0, null);
    }
    const rows = try parse(v.gpa, text, progress);
    defer freeRows(v.gpa, rows);
    if (rows.len == 0) return .{};
    if (progress) |p| if (p.cancelled(p.ctx)) return .{};
    const header = rows[0];
    const body = rows[1..];
    const url_at = column(header, &.{ "url", "login_uri", "website", "site" });
    const user_at = column(header, &.{ "username", "login_username", "user", "email" });
    const pass_at = column(header, &.{ "password", "login_password" });
    if (url_at == null or user_at == null or pass_at == null) return .{ .skipped = body.len };
    const widest = @max(url_at.?, @max(user_at.?, pass_at.?));
    var out: Taken = .{};
    if (progress) |p| p.report(p.ctx, saving, 0, body.len);
    for (body, 0..) |row, index| {
        if (progress) |p| if (p.cancelled(p.ctx)) break;
        defer if (progress) |p| if ((index + 1) % 25 == 0 or index + 1 == body.len) p.report(p.ctx, saving, index + 1, body.len);
        if (row.len <= widest) {
            out.skipped += 1;
            continue;
        }
        const site = try vault.host(v.gpa, row[url_at.?]);
        defer v.gpa.free(site);
        const password = row[pass_at.?];
        if (site.len == 0 or password.len == 0) {
            out.skipped += 1;
            continue;
        }
        const clear = std.ascii.startsWithIgnoreCase(std.mem.trim(u8, row[url_at.?], " \t"), "http://");
        if (v.save(site, row[user_at.?], password, null, clear)) out.kept += 1 else out.skipped += 1;
    }
    return out;
}

fn writeField(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    if (std.mem.indexOfAny(u8, s, ",\"\r\n") == null) return out.appendSlice(gpa, s);
    try out.append(gpa, '"');
    for (s) |c| {
        if (c == '"') try out.append(gpa, '"');
        try out.append(gpa, c);
    }
    try out.append(gpa, '"');
}

pub fn write(gpa: std.mem.Allocator, logins: []const Login) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "Title,URL,Username,Password,Notes,OTPAuth\n");
    for (logins) |l| {
        const url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (l.clear) "http://" else "https://", l.host });
        defer gpa.free(url);
        try writeField(&out, gpa, l.host);
        try out.append(gpa, ',');
        try writeField(&out, gpa, url);
        try out.append(gpa, ',');
        try writeField(&out, gpa, l.user);
        try out.append(gpa, ',');
        try writeField(&out, gpa, l.password);
        try out.appendSlice(gpa, ",,\n");
    }
    return out.toOwnedSlice(gpa);
}

test "write and parse round trip with comma, quote and newline" {
    const gpa = std.testing.allocator;
    const logins = [_]Login{.{
        .host = @constCast("kea.example"),
        .user = @constCast("kea, \"bird\"\nline"),
        .password = @constCast("sec,ret\"1\r\n2"),
        .clear = true,
    }};
    const csv = try write(gpa, &logins);
    defer gpa.free(csv);
    const rows = try parse(gpa, csv, null);
    defer freeRows(gpa, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("Title", rows[0][0]);
    try std.testing.expectEqualStrings("kea.example", rows[1][0]);
    try std.testing.expectEqualStrings("http://kea.example", rows[1][1]);
    try std.testing.expectEqualStrings("kea, \"bird\"\nline", rows[1][2]);
    try std.testing.expectEqualStrings("sec,ret\"1\r\n2", rows[1][3]);
}
