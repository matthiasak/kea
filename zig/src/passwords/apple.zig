//! Apple Passwords (`pejdijmoenmkgeppbflobdenhhabjlaj`, iCloud Passwords):
//! installing Apple's Chrome extension, pinning its toolbar button and opening
//! its pairing popup, and exporting Kea's keychain logins to a temporary CSV
//! for Passwords › File › Import Passwords….
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const Uuid = @import("../data/json.zig").Uuid;
const controller = @import("../ext/controller.zig");
const Extensions = controller.Extensions;
const buttons = @import("../ext/controller_buttons.zig");
const sheet = @import("../chrome/sheet.zig");
const Vault = @import("vault.zig").Vault;
const vault_csv = @import("vault_csv.zig");
const files = @import("../import/files.zig");

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, nbyte: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;

const heap = std.heap.c_allocator;
const manifest_path = "/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json";

pub fn available() bool {
    return access(manifest_path, 0) == 0;
}

const InstallCtx = struct {
    serial: u64,
    record: Uuid,
};

pub fn setUp(b: *Browser) void {
    const e = b.kea.ext orelse return;
    if (e.busy != null) return;
    sheet.close(b, .tuning);
    const ctx = heap.create(InstallCtx) catch return;
    ctx.* = .{ .serial = e.serial, .record = b.record_id };
    e.installId(Extensions.apple_passwords_id, true, ctx, installDone);
}

fn findBrowser(kea: *Kea, record: Uuid) ?*Browser {
    for (kea.browsers.items) |w| if (w.record_id.eql(record)) return w;
    return null;
}

fn installDone(raw: *anyopaque) void {
    const ctx: *InstallCtx = @ptrCast(@alignCast(raw));
    const serial = ctx.serial;
    const record = ctx.record;
    const e = controller.alive(serial) orelse return heap.destroy(ctx);
    const b = findBrowser(e.kea, record) orelse return heap.destroy(ctx);
    if (e.row(Extensions.apple_passwords_id) == null) {
        heap.destroy(ctx);
        b.announce("Apple Passwords wasn't added.");
        return;
    }
    e.setPinned(Extensions.apple_passwords_id, true);
    b.announce("Click Enable, then type the code your Mac shows.");
    objc.dispatchAfter(300 * std.time.ns_per_ms, ctx, pressLater);
}

fn pressLater(raw: ?*anyopaque) callconv(.c) void {
    const ctx: *InstallCtx = @ptrCast(@alignCast(raw.?));
    defer heap.destroy(ctx);
    const e = controller.alive(ctx.serial) orelse return;
    if (findBrowser(e.kea, ctx.record) == null) return;
    buttons.press(e, Extensions.apple_passwords_id);
}

const MoveCtx = struct {
    kea: *Kea,
    record: Uuid,
};

pub fn move(b: *Browser) void {
    const ctx = heap.create(MoveCtx) catch return;
    ctx.* = .{ .kea = b.kea, .record = b.record_id };
    Vault.of(b.kea).prove("move your passwords to Apple Passwords", ctx, provedAny);
}

fn provedAny(raw: *anyopaque, ok: bool) void {
    proved(@ptrCast(@alignCast(raw)), ok);
}

fn proved(ctx: *MoveCtx, ok: bool) void {
    defer heap.destroy(ctx);
    if (!ok) return;
    const kea = ctx.kea;
    const b = findBrowser(kea, ctx.record) orelse return;
    const gpa = kea.gpa;
    const v = Vault.of(kea);
    const kept = v.all() catch return;
    defer @import("vault.zig").freeKept(gpa, kept);
    var logins: std.ArrayList(vault_csv.Login) = .empty;
    defer {
        for (logins.items) |l| {
            std.crypto.secureZero(u8, l.password);
            l.deinit(gpa);
        }
        logins.deinit(gpa);
    }
    for (kept) |row| {
        const secret = v.secretOf(row) orelse continue;
        const h = gpa.dupe(u8, row.host) catch {
            std.crypto.secureZero(u8, secret);
            gpa.free(secret);
            continue;
        };
        const u = gpa.dupe(u8, row.user) catch {
            gpa.free(h);
            std.crypto.secureZero(u8, secret);
            gpa.free(secret);
            continue;
        };
        logins.append(gpa, .{ .host = h, .user = u, .password = secret, .used = row.used, .clear = row.clear }) catch {
            gpa.free(h);
            gpa.free(u);
            std.crypto.secureZero(u8, secret);
            gpa.free(secret);
        };
    }
    const bytes = vault_csv.write(gpa, logins.items) catch return;
    defer {
        std.crypto.secureZero(u8, bytes);
        gpa.free(bytes);
    }
    for (logins.items) |l| std.crypto.secureZero(u8, l.password);
    const folder = files.scratchFolder(gpa) catch return;
    defer gpa.free(folder);
    const folder_z = gpa.dupeSentinel(u8, folder, 0) catch return;
    defer gpa.free(folder_z);
    _ = mkdir(folder_z, 0o700);
    const path = std.fs.path.join(gpa, &.{ folder, "Kea Passwords.csv" }) catch return;
    const path_z = gpa.dupeSentinel(u8, path, 0) catch return gpa.free(path);
    defer gpa.free(path_z);
    const fd = open(path_z, 0x0601, 0o600);
    if (fd < 0) return gpa.free(path);
    _ = write(fd, bytes.ptr, bytes.len);
    _ = close(fd);
    if (kea.moved_csv) |old| {
        kea.store.disk.remove(old);
        gpa.free(old);
    }
    kea.moved_csv = path;
    if (heap.dupeSentinel(u8, path, 0)) |later_z| {
        objc.dispatchAfter(600 * std.time.ns_per_s, later_z.ptr, unlinkLater);
    } else |_| {}
    nanoui.shell.showInFolder(path);
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    if (objc.msg(?objc.Object, ws, "URLForApplicationWithBundleIdentifier:", .{objc.nsString("com.apple.Passwords")})) |u| {
        _ = objc.msg(objc.BOOL, ws, "openURL:", .{u});
    }
    b.announce("In Passwords, choose File › Import Passwords… and pick Kea Passwords.csv.");
}

fn unlinkLater(raw: ?*anyopaque) callconv(.c) void {
    const z: [*:0]u8 = @ptrCast(raw orelse return);
    _ = unlink(z);
    heap.free(std.mem.span(z));
}
