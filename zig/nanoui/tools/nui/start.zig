//! `nui start NAME`: a new nanoui app that builds. `zig init --minimal`
//! makes build.zig.zon (its name and fingerprint), nanoui joins it as a
//! dependency (fetched by tag and pinned by hash, or a local checkout's
//! path), the templates fill in the rest, and `zig build` proves it
//! compiles.
const std = @import("std");
const cli = @import("main.zig");

pub const Options = struct {
    name: []const u8,
    dir: ?[]const u8 = null,
    /// A git ref of nanoui to fetch (a tag, a commit).
    ref: []const u8,
    /// A local nanoui checkout instead.
    local: ?[]const u8 = null,
    build: bool = true,
};

const templates = [_]struct { path: []const u8, text: []const u8 }{
    .{ .path = "build.zig", .text = @embedFile("template/build.zig.in") },
    .{ .path = "src/main.zig", .text = @embedFile("template/main.zig.in") },
    .{ .path = "src/app.zig", .text = @embedFile("template/app.zig.in") },
    .{ .path = "src/tests.zig", .text = @embedFile("template/tests.zig.in") },
    .{ .path = "AGENTS.md", .text = @embedFile("template/AGENTS.md.in") },
    .{ .path = ".gitignore", .text = @embedFile("template/gitignore.in") },
};

/// A name a folder and a Zig package can both have.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphabetic(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

/// "my-app" as a title: "My App".
pub fn title(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try a.dupe(u8, name);
    var start = true;
    for (out) |*ch| {
        if (ch.* == '-' or ch.* == '_') {
            ch.* = ' ';
            start = true;
        } else {
            if (start) ch.* = std.ascii.toUpper(ch.*);
            start = false;
        }
    }
    return out;
}

/// `text` with {{name}} and {{title}} filled in.
pub fn fill(a: std.mem.Allocator, text: []const u8, name: []const u8, app_title: []const u8) ![]const u8 {
    const once = try std.mem.replaceOwned(u8, a, text, "{{name}}", name);
    return std.mem.replaceOwned(u8, a, once, "{{title}}", app_title);
}

/// build.zig.zon's package name (`.name = .my_app`): the program's name.
pub fn zonName(zon: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, zon, ".name = .") orelse return null;
    const rest = zon[at + ".name = .".len ..];
    const end = std.mem.indexOfAny(u8, rest, ",\n ") orelse return null;
    return rest[0..end];
}

/// build.zig.zon with nanoui as a path dependency and the app's paths.
pub fn withLocal(a: std.mem.Allocator, zon: []const u8, path: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (path) |ch| {
        if (ch == '\\' or ch == '"') try escaped.append(a, '\\');
        try escaped.append(a, ch);
    }
    const deps = try std.fmt.allocPrint(a, "    .dependencies = .{{\n        .nanoui = .{{ .path = \"{s}\" }},\n    }},\n    .paths = .{{ \"build.zig\", \"build.zig.zon\", \"src\" }},", .{escaped.items});
    return std.mem.replaceOwned(u8, a, zon, "    .paths = .{\"\"},", deps);
}

pub fn run(a: std.mem.Allocator, io: std.Io, out: *cli.Out, o: Options) !void {
    if (!validName(o.name)) return out.fail("not a name an app can have: {s}", .{o.name}, "use letters, digits, - and _, starting with a letter (my-app)");
    const dir = o.dir orelse o.name;
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, dir, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close(io);
        var it = d.iterate();
        if (try it.next(io) != null) return out.fail("{s} exists and isn't empty", .{dir}, "choose another name, or --dir PATH");
    } else |_| {}
    try cwd.createDirPath(io, dir);
    out.step("made {s}/", .{dir});

    if (!try cli.zig(a, io, &.{ "init", "--minimal" }, dir, .silent)) return out.fail("zig init failed in {s}", .{dir}, "run `nui doctor`");
    const zon_path = try std.fs.path.join(a, &.{ dir, "build.zig.zon" });
    var zon: []const u8 = try cwd.readFileAlloc(io, zon_path, a, .limited(1 << 16));
    const name = zonName(zon) orelse return out.fail("build.zig.zon has no name", .{}, null);

    if (o.local) |local| {
        // Zig wants it relative to the app's folder.
        const abs = try cwd.realPathFileAlloc(io, local, a);
        const app_abs = try cwd.realPathFileAlloc(io, dir, a);
        const rel = try std.fs.path.relativeAlloc(a, app_abs, null, app_abs, abs);
        zon = try withLocal(a, zon, rel);
        try cwd.writeFile(io, .{ .sub_path = zon_path, .data = zon });
        out.step("nanoui from {s}", .{abs});
    } else {
        zon = try withLocal(a, zon, "");
        // The paths line, without a dependency yet: zig fetch adds it.
        zon = try std.mem.replaceOwned(u8, a, zon, "    .dependencies = .{\n        .nanoui = .{ .path = \"\" },\n    },\n", "");
        try cwd.writeFile(io, .{ .sub_path = zon_path, .data = zon });
        const url = try std.fmt.allocPrint(a, "git+https://github.com/justrach/nanoui#{s}", .{o.ref});
        if (!try cli.zig(a, io, &.{ "fetch", "--save=nanoui", url }, dir, .quiet))
            return out.fail("couldn't fetch nanoui {s}", .{o.ref}, "check the network, or use --local PATH to a nanoui checkout");
        out.step("nanoui {s}, pinned", .{o.ref});
    }

    const app_title = try title(a, o.name);
    try cwd.createDirPath(io, try std.fs.path.join(a, &.{ dir, "src" }));
    for (templates) |t| {
        const path = try std.fs.path.join(a, &.{ dir, t.path });
        try cwd.writeFile(io, .{ .sub_path = path, .data = try fill(a, t.text, name, app_title) });
    }
    out.step("wrote build.zig, src/main.zig, src/app.zig, src/tests.zig, AGENTS.md", .{});

    if (o.build) {
        out.step("building…", .{});
        if (!try cli.zig(a, io, &.{"build"}, dir, if (out.json) .quiet else .shown)) return out.fail("{s} doesn't build", .{dir}, "the compiler's errors are above");
        out.step("it builds", .{});
    }
    out.done(.{ .name = name, .dir = dir, .built = o.build }, &.{
        try std.fmt.allocPrint(a, "cd {s}", .{dir}),
        "nui test",
        "nui snapshot --out shot.png",
        "nui run",
    });
}

test "names, titles, templates and build.zig.zon" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(validName("my-app") and validName("Notes_2"));
    try std.testing.expect(!validName("2fast") and !validName("a b") and !validName("../x") and !validName(""));
    try std.testing.expectEqualStrings("My App", try title(a, "my-app"));
    try std.testing.expectEqualStrings("exe my_app, My App", try fill(a, "exe {{name}}, {{title}}", "my_app", "My App"));
    const zon =
        \\.{
        \\    .name = .my_app,
        \\    .version = "0.0.1",
        \\    .minimum_zig_version = "0.17.0",
        \\    .paths = .{""},
        \\    .fingerprint = 0x542b89b0eb57ea7f,
        \\}
    ;
    try std.testing.expectEqualStrings("my_app", zonName(zon).?);
    const local = try withLocal(a, zon, "C:\\code\\nanoui");
    try std.testing.expect(std.mem.indexOf(u8, local, ".nanoui = .{ .path = \"C:\\\\code\\\\nanoui\" }") != null);
    try std.testing.expect(std.mem.indexOf(u8, local, ".paths = .{ \"build.zig\", \"build.zig.zon\", \"src\" }") != null);
    for (templates) |t| try std.testing.expect(t.text.len > 0);
}
