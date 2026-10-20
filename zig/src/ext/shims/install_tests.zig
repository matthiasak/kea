const std = @import("std");
const install = @import("install.zig");
const files = @import("install_files.zig");

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

test "shim markers present once" {
    const s = install.script;
    for ([_][]const u8{ "// kea:content-skip-begin\n", "// kea:content-skip-end\n", "// kea:content-end\n", "__KEA_EVENTS__", "__KEA_SCRIPTS__" }) |m|
        try std.testing.expectEqual(@as(usize, 1), count(s, m));
    // These two are used at several places in the script, as in Swift.
    try std.testing.expect(count(s, "__KEA_CHROME__") >= 1);
    try std.testing.expect(count(s, "__KEA_VERBOSE__") >= 1);
    try std.testing.expect(std.mem.startsWith(u8, s, "(() => {"));
    try std.testing.expect(std.mem.endsWith(u8, s, "})();"));
    try std.testing.expect(std.mem.endsWith(u8, install.content_script, "    })();\n"));
    try std.testing.expect(count(install.content_script, "// kea:content-skip-begin") == 0);
}

fn tmpPath(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "shim lists events the code mentions" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const js = try std.fs.path.join(gpa, &.{ dir, "bg.js" });
    defer gpa.free(js);
    try files.write(gpa, js, "chrome.tabs.onUpdated.addListener(f); x.runtime.onX; a.b.on_c;");
    const empty = try std.fs.path.join(gpa, &.{ dir, "empty.js" });
    defer gpa.free(empty);
    try files.write(gpa, empty, " \n");
    const s = try install.shim(gpa, dir);
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "[\"tabs.onUpdated\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "[\"-\\/empty.js\",\"\\/bg.js\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "__KEA_") == null);
}

test "prepare rewrites a fixture extension" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const at = struct {
        fn f(d: []const u8, n: []const u8) ![]u8 {
            return std.fs.path.join(std.testing.allocator, &.{ d, n });
        }
    }.f;
    const manifest = try at(dir, "manifest.json");
    defer gpa.free(manifest);
    try files.write(gpa, manifest,
        \\{"manifest_version": 3, "name": "T", "version": "1.0",
        \\ "background": {"service_worker": "bg.js"},
        \\ "content_scripts": [{"matches": ["<all_urls>"], "js": ["c.js"], "world": "MAIN"}]}
    );
    const bg = try at(dir, "bg.js");
    defer gpa.free(bg);
    try files.write(gpa, bg, "chrome.runtime.onInstalled.addListener(() => {});\n");
    const page = try at(dir, "popup.html");
    defer gpa.free(page);
    try files.write(gpa, page, "<html><HEAD lang=x><title>t</title></head></html>");

    try install.prepare(gpa, dir, true);
    const once = files.read(gpa, bg).?;
    defer gpa.free(once);
    try std.testing.expect(std.mem.startsWith(u8, once, install.marker ++ "\n"));
    try std.testing.expect(std.mem.endsWith(u8, once, install.ender ++ "\nchrome.runtime.onInstalled.addListener(() => {});\n"));
    try std.testing.expect(std.mem.indexOf(u8, once, "[\"runtime.onInstalled\"]") != null);
    const html = files.read(gpa, page).?;
    defer gpa.free(html);
    try std.testing.expectEqualStrings("<html><HEAD lang=x><script src=\"/kea-shim.js\"></script><title>t</title></head></html>", html);
    const m1 = files.read(gpa, manifest).?;
    defer gpa.free(m1);
    try std.testing.expect(std.mem.indexOf(u8, m1, "\"nativeMessaging\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, "\"kea-passkeys.js\",\n        \"kea-shim-content.js\",\n        \"c.js\"") != null);
    const added = try at(dir, ".kea-added");
    defer gpa.free(added);
    const a1 = files.read(gpa, added).?;
    defer gpa.free(a1);
    try std.testing.expectEqualStrings("[\"nativeMessaging\"]", a1);

    // Again: the stamp says it's done, nothing changes. Redone without the
    // stamp, the worker's shim now also lists the shim's own files, so
    // compare two redone runs.
    try install.prepare(gpa, dir, false);
    const kept = files.read(gpa, bg).?;
    defer gpa.free(kept);
    try std.testing.expectEqualStrings(once, kept);
    try install.prepare(gpa, dir, true);
    const redone = files.read(gpa, bg).?;
    defer gpa.free(redone);
    try std.testing.expectEqual(@as(usize, 1), count(redone, install.marker));
    try install.prepare(gpa, dir, true);
    const twice = files.read(gpa, bg).?;
    defer gpa.free(twice);
    try std.testing.expectEqualStrings(redone, twice);
    const m2 = files.read(gpa, manifest).?;
    defer gpa.free(m2);
    try std.testing.expectEqualStrings(m1, m2);
    const html2 = files.read(gpa, page).?;
    defer gpa.free(html2);
    try std.testing.expectEqualStrings(html, html2);
}

test "user script and scripting files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(gpa, &tmp);
    defer gpa.free(dir);
    const rel = try install.scriptingFile(gpa, "(a) => a", &.{.{ .string = "x/y" }}, dir);
    defer gpa.free(rel);
    try std.testing.expect(std.mem.startsWith(u8, rel, "_kea/script-"));
    const full = try std.fs.path.join(gpa, &.{ dir, rel });
    defer gpa.free(full);
    const body = files.read(gpa, full).?;
    defer gpa.free(body);
    try std.testing.expectEqualStrings("((a) => a)(...[\"x\\/y\"])\n", body);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"js\":[{\"code\":\"go()\"}],\"world\":\"MAIN\"}", .{});
    defer parsed.deinit();
    const us = try install.userScriptFile(gpa, parsed.value.object, dir);
    defer gpa.free(us);
    const usp = try std.fs.path.join(gpa, &.{ dir, us });
    defer gpa.free(usp);
    const ut = files.read(gpa, usp).?;
    defer gpa.free(ut);
    try std.testing.expect(std.mem.indexOf(u8, ut, "const __keaIn = [], __keaOut = [];\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, ut, "break kea_user_script;\n\ngo()\n;\n\n}"));
}
