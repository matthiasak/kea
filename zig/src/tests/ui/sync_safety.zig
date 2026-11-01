//! Settings › Sync when the chosen place already holds something: another
//! app's files (a "Kea Sync" folder made inside), or a Kea store (joined,
//! or archived and replaced — and when replacing fails, nothing lost).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

fn clickControl(f: *Fixture, role: ui.A11yRole, label: []const u8) !void {
    const c = &f.tester.ctx;
    for (c.a11y_items.items) |item| if (item.role == role and std.mem.eql(u8, item.label, label)) {
        const r = c.rects.get(item.id) orelse return error.NoControl;
        f.tester.click(r.x + r.w / 2, r.y + r.h / 2);
        f.tester.frame();
        return;
    };
    return error.NoControl;
}

fn writeFile(path: []const u8, text: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.BOOL, objc.nsString(text), "writeToFile:atomically:encoding:error:", .{ objc.nsString(path), objc.YES, @as(objc.NSUInteger, 4), @as(?*anyopaque, null) });
}

fn exists(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    return objc.msg(objc.BOOL, fm, "fileExistsAtPath:", .{objc.nsString(path)});
}

fn openSync(f: *Fixture) !void {
    app.settings.open(f.browser, .sync);
    f.tester.settle(1);
    try clickControl(f, .radio_button, "Folder");
    f.tester.settle(1);
}

test "a folder with other files: a Kea Sync folder made inside it" {
    var a: Fixture = undefined;
    try a.init(gpa, .{ .sidebar = true });
    defer a.deinit();
    const dir = try std.fmt.allocPrint(gpa, "{s}/Documents", .{a.temp.folder});
    defer gpa.free(dir);
    app.disk.makePath(gpa, dir);
    const notes = try std.fmt.allocPrint(gpa, "{s}/notes.txt", .{dir});
    defer gpa.free(notes);
    writeFile(notes, "mine");

    try openSync(&a);
    a.kea.sync.chooseFolder(dir);
    a.tester.frame();
    try t.expect(a.tester.containsText("This folder already contains 1 item(s)"));
    try clickControl(&a, .button, "Create ‘Kea Sync’ Subfolder");
    a.tester.settle(1);
    try t.expect(a.tester.containsText("/Documents/Kea Sync"));
    try t.expect(!a.tester.containsText("already contains"));
    try t.expect(exists(notes));
}

extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;

test "a store already there: replacing it fails safely, then archives it" {
    var a: Fixture = undefined;
    try a.init(gpa, .{ .sidebar = true });
    defer a.deinit();
    var b: Fixture = undefined;
    try b.init(gpa, .{ .sidebar = true });
    defer b.deinit();
    const shared = try std.fmt.allocPrint(gpa, "{s}/shared", .{a.temp.folder});
    defer gpa.free(shared);
    app.disk.makePath(gpa, shared);
    b.kea.sync.chooseFolder(shared);
    try t.expect(b.kea.sync.use("correct horse", null) == null);
    try t.expect(b.kea.sync.ready);

    try openSync(&a);
    a.kea.sync.chooseFolder(shared);
    a.tester.frame();
    try t.expect(a.tester.containsText("Existing Kea sync store found (1 Mac(s))"));

    // B's head can't be moved: the red banner, and B's store as it was.
    const heads = try std.fmt.allocPrintSentinel(gpa, "{s}/kea/v2/heads", .{shared}, 0);
    defer gpa.free(heads);
    a.browser.settings.sync.passphrase.set("new horse");
    try clickControl(&a, .button, "Overwrite Store…");
    _ = chmod(heads, 0o555);
    try clickControl(&a, .button, "Archive & Overwrite");
    _ = chmod(heads, 0o755);
    try t.expect(!a.kea.sync.ready);
    try t.expect(a.tester.containsText("previous store was restored. Nothing was lost"));
    try clickControl(&a, .button, "Dismiss");
    try t.expect(!a.tester.containsText("Nothing was lost"));
    b.kea.sync.syncNow();
    try t.expect(b.kea.sync.ready);

    // Again, with nothing in the way: archived, and A's store in its place.
    a.browser.settings.sync.passphrase.set("new horse");
    try clickControl(&a, .button, "Overwrite Store…");
    try clickControl(&a, .button, "Archive & Overwrite");
    try t.expect(a.kea.sync.ready);
    try t.expect(a.tester.containsText("Synced"));
    const archive = try std.fmt.allocPrint(gpa, "{s}/kea/quarantine", .{shared});
    defer gpa.free(archive);
    try t.expect(exists(archive));
    b.kea.sync.syncNow();
    try t.expect(!b.kea.sync.ready);
}
