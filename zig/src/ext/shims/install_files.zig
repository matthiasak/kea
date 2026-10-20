//! The file side of the shims (ExtensionShims.swift 160-200, 4121-4200):
//! reading, writing, walking an extension's folder without leaving it, and
//! the files WebKit's scripting API is pointed at. libc, like data/disk.zig.
const std = @import("std");
const install = @import("install.zig");

const A = std.mem.Allocator;
const Value = std.json.Value;

const c = struct {
    const FILE = opaque {};
    extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    extern "c" fn fclose(stream: *FILE) c_int;
    extern "c" fn fwrite(ptr: [*]const u8, size: usize, nitems: usize, stream: *FILE) usize;
    extern "c" fn fread(ptr: [*]u8, size: usize, nitems: usize, stream: *FILE) usize;
    extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
    extern "c" fn opendir(path: [*:0]const u8) ?*std.c.DIR;
    extern "c" fn readdir(dir: *std.c.DIR) ?*std.c.dirent;
    extern "c" fn closedir(dir: *std.c.DIR) c_int;
    extern "c" fn realpath(path: [*:0]const u8, out: ?[*]u8) ?[*:0]u8;
    extern "c" fn free(p: ?*anyopaque) void;
    extern "c" fn stat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
    extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
    extern "c" fn time(t: ?*i64) i64;
};

/// What `scriptingFile` refuses with (Swift's `Unsupported(what:)`).
pub const invalid_script = "Invalid script function or arguments";

/// The whole file on `a`, or null.
pub fn read(a: A, path: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    defer a.free(z);
    const f = c.fopen(z, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, f);
        out.appendSlice(a, chunk[0..n]) catch {
            out.deinit(a);
            return null;
        };
        if (n < chunk.len) break;
    }
    return out.toOwnedSlice(a) catch null;
}

/// `write(to:atomically:)`: `<path>.kea-tmp` renamed over `path`.
pub fn write(a: A, path: []const u8, bytes: []const u8) !void {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.kea-tmp", .{path}, 0);
    defer a.free(tmp);
    const f = c.fopen(tmp, "wb") orelse return error.WriteFailed;
    const wrote = bytes.len == 0 or c.fwrite(bytes.ptr, 1, bytes.len, f) == bytes.len;
    if (c.fclose(f) != 0 or !wrote or c.rename(tmp, z) != 0) {
        _ = c.unlink(tmp);
        return error.WriteFailed;
    }
}

pub fn remove(a: A, path: []const u8) void {
    const z = a.dupeSentinel(u8, path, 0) catch return;
    defer a.free(z);
    _ = c.unlink(z);
}

fn lstatOf(a: A, path: []const u8) ?std.c.Stat {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    defer a.free(z);
    var st: std.c.Stat = undefined;
    return if (c.lstat(z, &st) == 0) st else null;
}

fn isLink(a: A, path: []const u8) bool {
    const st = lstatOf(a, path) orelse return false;
    return st.mode & std.c.S.IFMT == std.c.S.IFLNK;
}

/// `resolvingSymlinksInPath`, or null when the path isn't there.
fn resolved(a: A, path: []const u8) ?[]u8 {
    const z = a.dupeSentinel(u8, path, 0) catch return null;
    defer a.free(z);
    const p = c.realpath(z, null) orelse return null;
    defer c.free(p);
    return a.dupe(u8, std.mem.span(p)) catch null;
}

fn under(path: []const u8, root: []const u8) bool {
    return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
}

/// `folder/name` standardized (`..` and `.` resolved as text), the name's
/// leading and trailing `/` dropped.
fn standardized(a: A, name: []const u8, folder: []const u8) ![]u8 {
    return std.fs.path.resolveAllocPosix(a, &.{ folder, std.mem.trim(u8, name, "/") });
}

/// One thing in an extension's folder (`FileManager.enumerator`): links are
/// listed, never followed into.
pub const Entry = struct { path: []u8, dir: bool, link: bool };

/// Everything under `folder`, depth first, paths on `a`.
pub fn walk(a: A, folder: []const u8, out: *std.ArrayList(Entry)) !void {
    const z = try a.dupeSentinel(u8, folder, 0);
    defer a.free(z);
    const d = c.opendir(z) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |e| {
        const name = e.name[0..e.namlen];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const path = try std.fs.path.join(a, &.{ folder, name });
        const dir = e.type == std.c.DT.DIR;
        try out.append(a, .{ .path = path, .dir = dir, .link = e.type == std.c.DT.LNK });
        if (dir) try walk(a, path, out);
    }
}

/// `unlink(_:in:)`: a worker that is a link to another file of its own
/// package is made a copy of that file, so it can carry the shim. A link
/// that leads out of the package is left as it is.
pub fn unlink(a: A, name: []const u8, folder: []const u8) void {
    const path = standardized(a, name, folder) catch return;
    defer a.free(path);
    const top = std.fs.path.resolveAllocPosix(a, &.{folder}) catch return;
    defer a.free(top);
    if (!under(path, top) or !isLink(a, path)) return;
    const root = resolved(a, folder) orelse return;
    defer a.free(root);
    const parent = resolved(a, std.fs.path.dirname(path) orelse return) orelse return;
    defer a.free(parent);
    const target = resolved(a, path) orelse return;
    defer a.free(target);
    if (!(std.mem.eql(u8, parent, root) or under(parent, root)) or !under(target, root)) return;
    const st = lstatOf(a, target) orelse return;
    if (st.mode & std.c.S.IFMT != std.c.S.IFREG) return;
    const data = read(a, target) orelse return;
    defer a.free(data);
    remove(a, path);
    write(a, path, data) catch {};
}

/// `inside(_:of:)`: a path a package names, kept inside its folder — no
/// `..` out, not itself a link, and not out through a linked folder on the
/// way. Null when it leaves (or isn't there).
pub fn inside(a: A, name: []const u8, folder: []const u8) !?[]u8 {
    const path = try standardized(a, name, folder);
    const top = try std.fs.path.resolveAllocPosix(a, &.{folder});
    defer a.free(top);
    const ok = blk: {
        if (!under(path, top) or isLink(a, path)) break :blk false;
        const real = resolved(a, path) orelse break :blk false;
        defer a.free(real);
        const root = resolved(a, folder) orelse break :blk false;
        defer a.free(root);
        break :blk under(real, root);
    };
    if (ok) return path;
    a.free(path);
    return null;
}

/// `<folder>/_kea/<prefix><first 8 bytes of SHA-256 of text, hex>.js`,
/// written unless already there; returns the path inside the folder.
fn keaFile(a: A, folder: []const u8, prefix: []const u8, text: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &d, .{});
    const name = try std.fmt.allocPrint(a, "{s}{s}.js", .{ prefix, std.fmt.bytesToHex(d[0..8].*, .lower) });
    defer a.free(name);
    const dir = try std.fs.path.joinZ(a, &.{ folder, "_kea" });
    defer a.free(dir);
    _ = c.mkdir(dir, 0o755);
    const path = try std.fs.path.join(a, &.{ dir, name });
    defer a.free(path);
    if (lstatOf(a, path) == null) try write(a, path, text);
    return std.fmt.allocPrint(a, "_kea/{s}", .{name});
}

/// `scriptingFile(_:arguments:in:)`: a function an extension page sent,
/// written as a file for WebKit's scripting API with its JSON arguments.
/// Old ones over a minute old go. Returns "_kea/script-….js" on `a`;
/// error.Unsupported means `invalid_script`.
pub fn scriptingFile(a: A, function: []const u8, arguments: []const Value, folder: []const u8) ![]u8 {
    // A megabyte of source at most (Security).
    if (function.len == 0 or function.len > 1_000_000) return error.Unsupported;
    const args = install.swiftJson(a, arguments) catch return error.Unsupported;
    defer a.free(args);
    const source = try std.mem.concat(a, u8, &.{ "(", function, ")(...", args, ")\n" });
    defer a.free(source);
    const rel = try keaFile(a, folder, "script-", source);
    errdefer a.free(rel);
    const dir = try std.fs.path.join(a, &.{ folder, "_kea" });
    defer a.free(dir);
    var olds: std.ArrayList(Entry) = .empty;
    defer {
        for (olds.items) |o| a.free(o.path);
        olds.deinit(a);
    }
    const dz = try a.dupeSentinel(u8, dir, 0);
    defer a.free(dz);
    if (c.opendir(dz)) |d| {
        defer _ = c.closedir(d);
        while (c.readdir(d)) |e| {
            const name = e.name[0..e.namlen];
            if (!std.mem.startsWith(u8, name, "script-") or std.mem.eql(u8, name, rel[5..])) continue;
            try olds.append(a, .{ .path = try std.fs.path.join(a, &.{ dir, name }), .dir = false, .link = false });
        }
    }
    const now = c.time(null);
    for (olds.items) |o| {
        const st = lstatOf(a, o.path) orelse continue;
        if (now - st.mtime().sec > 60) remove(a, o.path);
    }
    return rel;
}

const prelude =
    \\  const chrome = (() => {
    \\    const runtime = globalThis.chrome.runtime;
    \\    return { runtime: {
    \\      id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
    \\      sendMessage: (message, ...rest) => runtime.sendMessage({ __keaUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
    \\      connect: (info) => runtime.connect({ ...(info || {}), name: "kea-us:" + ((info && info.name) || "") }),
    \\    } };
    \\  })();
    \\  const browser = chrome;
;

/// `userScriptFile(_:in:)`: a user script (chrome.userScripts registration
/// object) as a file WebKit can inject — its code inline or read from the
/// extension's own files, inside a block that leaves on a page its globs
/// rule out and, for the USER_SCRIPT world, gives it a `chrome` whose
/// messages are marked as a user script's. Returns "_kea/us-….js" on `a`.
pub fn userScriptFile(a: A, script: std.json.ObjectMap, folder: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var code: std.ArrayList(u8) = .empty;
    const sources = script.get("js");
    if (sources != null and sources.? == .array and allObjects(sources.?.array.items)) for (sources.?.array.items) |s| {
        if (s.object.get("code")) |inline_code| if (inline_code == .string) {
            try code.appendSlice(ar, inline_code.string);
            try code.appendSlice(ar, "\n;\n");
            continue;
        };
        const f = s.object.get("file") orelse continue;
        if (f != .string) continue;
        // One of the extension's own files, and nothing outside its folder.
        const path = (try inside(ar, f.string, folder)) orelse continue;
        const text = read(ar, path) orelse continue;
        if (!std.unicode.utf8ValidateSlice(text)) continue;
        try code.appendSlice(ar, text);
        try code.appendSlice(ar, "\n;\n");
    };
    const user_world = if (script.get("world")) |w| !(w == .string and std.mem.eql(u8, w.string, "MAIN")) else true;
    const empty: Value = .{ .array = .init(ar) };
    const in_globs = install.swiftJson(ar, script.get("includeGlobs") orelse empty) catch "[]";
    const out_globs = install.swiftJson(ar, script.get("excludeGlobs") orelse empty) catch "[]";
    const text = try std.mem.concat(ar, u8, &.{
        \\/* Kea: a user script (chrome.userScripts) */
        \\kea_user_script: {
        \\  const __keaHref = location.href;
        \\  const __keaGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
        \\  const __keaIn = 
        , in_globs, ", __keaOut = ", out_globs,
        \\;
        \\  if ((__keaIn.length && !__keaIn.some((g) => __keaGlob(g).test(__keaHref))) || __keaOut.some((g) => __keaGlob(g).test(__keaHref))) break kea_user_script;
        \\
        , if (user_world) prelude else "", "\n", code.items, "\n}",
    });
    return keaFile(a, folder, "us-", text);
}

fn allObjects(items: []const Value) bool {
    for (items) |v| if (v != .object) return false;
    return true;
}
