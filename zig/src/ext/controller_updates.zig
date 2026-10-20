//! Updates (Extensions.swift 923-993): once a day the store is asked
//! whether anything installed from it has a newer version; if so it is
//! fetched, checked and swapped in. One that asks for more than it was
//! installed with is asked about first.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const controller = @import("controller.zig");
const Extensions = controller.Extensions;
const json = @import("../data/json.zig");
const crx = @import("crx.zig");
const files = @import("files.zig");
const fence = @import("controller_fence.zig");
const asking = @import("controller_asking.zig");
const load_ops = @import("controller_load.zig");
const install_ops = @import("controller_install.zig");
const Job = install_ops.Job;
const urlsession = @import("../sys/urlsession.zig");

const checked_key = "extensions.checked";

/// `checkForUpdates()`: at most once every 20 hours.
pub fn checkForUpdates(self: *Extensions) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const defaults = self.kea.store.defaults;
    const now = objc.msg(objc.Object, objc.class("NSDate"), "date", .{});
    if (objc.msg(?objc.Object, defaults, "objectForKey:", .{objc.nsString(checked_key)})) |last| {
        if (objc.msg(objc.BOOL, last, "isKindOfClass:", .{objc.class("NSDate")}) and
            objc.msg(f64, now, "timeIntervalSinceDate:", .{last}) <= 60 * 60 * 20) return;
    }
    objc.msg(void, defaults, "setObject:forKey:", .{ now, objc.nsString(checked_key) });
    for (self.installed.items) |r| if (r.fromStore) update(self, r);
}

fn update(self: *Extensions, item: controller.Installed) void {
    const j = Job.make(self, .update, item.id) catch return;
    j.original = json.clone(self.gpa, item) catch return j.finish();
    load_ops.offMain(Job, j, ask, asked);
}

/// Off the main thread: the store's answer, a newer version or none.
fn ask(j: *Job) void {
    const r = j.original.?;
    const url = std.fmt.allocPrint(j.gpa, "https://clients2.google.com/service/update2/crx?response=updatecheck&prodversion=" ++ crx.chrome_version ++ "&acceptformat=crx3&x=id%3D{s}%26v%3D{s}%26uc", .{ r.id, r.version }) catch return;
    defer j.gpa.free(url);
    const pool = objc.Pool.push();
    defer pool.pop();
    const session = objc.msg(objc.Object, objc.class("NSURLSession"), "sharedSession", .{});
    const got = (urlsession.send(j.gpa, session, "GET", url, &.{}, null) catch return) orelse return;
    defer j.gpa.free(got.body);
    const version = offered(got.body) orelse return;
    if (std.mem.eql(u8, version, r.version)) return;
    j.version = j.gpa.dupe(u8, version) catch null;
}

fn word(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The version `<updatecheck status="ok" version="…">` offers. Read across
/// the whole reply, the first version="" is the XML declaration's.
pub fn offered(xml: []const u8) ?[]const u8 {
    var from: usize = 0;
    const check = while (std.mem.indexOfPos(u8, xml, from, "<updatecheck")) |at| {
        const after = at + "<updatecheck".len;
        from = after;
        if (after < xml.len and word(xml[after])) continue;
        const end = std.mem.indexOfScalarPos(u8, xml, after, '>') orelse return null;
        break xml[at .. end + 1];
    } else return null;
    if (std.mem.indexOf(u8, check, "status=\"ok\"") == null) return null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, check, i, "version=\"")) |at| {
        i = at + 1;
        if (at > 0 and word(check[at - 1])) continue;
        const start = at + "version=\"".len;
        const end = std.mem.indexOfScalarPos(u8, check, start, '"') orelse return null;
        if (end == start) return null;
        return check[start..end];
    }
    return null;
}

fn asked(j: *Job) void {
    const self = controller.alive(j.serial) orelse return j.finish();
    if (j.version == null) return j.finish();
    j.staged = install_ops.stagingFolder(self, j.id) catch return j.finish();
    crx.fetch(self.gpa, j.id, j, install_ops.fetched);
}

/// Fetched, checked, unpacked and shimmed: read, and asked about if it
/// wants more.
pub fn unpacked(j: *Job) void {
    load_ops.openExtension(Job, j, j.staged.?, opened);
}

fn opened(j: *Job) void {
    const self = controller.alive(j.serial) orelse return j.finish();
    const found = j.found orelse return j.fail(j.why orelse "");
    const current = self.row(j.id) orelse return j.finish();
    if (!current.fromStore or !std.mem.eql(u8, current.version, j.original.?.version)) return j.finish();
    // The row as it is now: what is compared once the question is answered.
    const now = json.clone(self.gpa, current.*) catch return j.finish();
    controller.freeRow(self.gpa, j.original.?);
    j.original = now;
    const pool = objc.Pool.push();
    defer pool.pop();
    // Everything it could do, sites included, against what it was allowed.
    j.wants = fence.grants(self.gpa, found, j.staged.?) catch return j.finish();
    if (install_ops.isSubset(@ptrCast(j.wants.?), now.permissions)) return answered(j, true);
    const name = std.fmt.allocPrint(self.gpa, "An update to {s}", .{now.name}) catch return j.finish();
    defer self.gpa.free(name);
    const wants = fence.describe(self.gpa, found, j.staged.?) catch return j.finish();
    defer fence.freeAll(self.gpa, wants);
    const icon = objc.msg(?objc.Object, found, "iconForSize:", .{objc.CGSize{ .width = 64, .height = 64 }});
    asking.askInstall(self, name, @ptrCast(wants), icon, j, answeredAsk);
}

fn answeredAsk(p: *anyopaque, yes: bool) void {
    answered(@ptrCast(@alignCast(p)), yes);
}

fn samePermissions(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn answered(j: *Job, yes: bool) void {
    const self = controller.alive(j.serial) orelse return j.finish();
    if (!yes) return j.finish();
    const gpa = self.gpa;
    const before = j.original.?;
    const r = self.row(j.id) orelse return j.finish();
    if (!r.fromStore or !std.mem.eql(u8, r.version, before.version) or !samePermissions(r.permissions, before.permissions)) return j.finish();
    files.replace(j.staged.?, j.target) catch |e| {
        const why = files.describe(gpa, e, j.target) catch return j.finish();
        defer gpa.free(why);
        return j.fail(why);
    };
    load_ops.unload(self, j.id);
    self.clearErrors(j.id);
    load_ops.workersChanged(self);
    const row = self.row(j.id) orelse return j.finish();
    const pool = objc.Pool.push();
    defer pool.pop();
    const version = load_ops.text(j.found.?, "version") orelse j.version.?;
    if (gpa.dupe(u8, version)) |v| {
        gpa.free(row.version);
        row.version = v;
    } else |_| {}
    for (row.permissions) |x| gpa.free(x);
    gpa.free(row.permissions);
    // `grants` is sorted already (`wants.sorted()`).
    row.permissions = @ptrCast(j.wants.?);
    j.wants = null;
    self.save();
    if (row.enabled) load_ops.load(self, j.id, null, null);
    j.finish();
}

test "the update check reads the updatecheck element alone" {
    const yes =
        \\<?xml version="1.0" encoding="UTF-8"?><gupdate protocol="2.0"><app appid="x" status="ok"><updatecheck codebase="https://x/y.crx" status="ok" version="1.2.3"/></app></gupdate>
    ;
    try std.testing.expectEqualStrings("1.2.3", offered(yes).?);
    const no =
        \\<?xml version="1.0" encoding="UTF-8"?><gupdate protocol="2.0"><app appid="x" status="ok"><updatecheck status="noupdate"/></app></gupdate>
    ;
    try std.testing.expect(offered(no) == null);
}
