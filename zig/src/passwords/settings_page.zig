//! Settings › Passwords (Settings.swift `passwords`, `savingDetail`): the
//! keychain list, saving, filling, passkeys, the sites never asked, and
//! bringing yours in.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const app_name = @import("../app/kea.zig").app_name;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const frame = @import("../chrome/settings/frame.zig");
const sheet = @import("../chrome/sheet.zig");
const vault = @import("vault.zig");
const passkeys = @import("passkeys.zig");
const apple = @import("apple.zig");
const ring = @import("../chrome/ring.zig");
const Extensions = @import("../ext/controller.zig").Extensions;
const buttons = @import("../ext/controller_buttons.zig");

fn appleCard(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const e = b.kea.ext orelse return;
    const id = Extensions.apple_passwords_id;
    plate.cardBox(c, p);
    defer ui.end(c);
    if (!apple.available()) {
        plate.line(c, p, "Apple Passwords", "Needs iCloud Keychain on this Mac");
        ui.end(c);
        return;
    }
    if (!b.prefs.passkeys_possible) {
        plate.line(c, p, "Apple Passwords", "Needs an Apple entitlement this build doesn't have: macOS won't start Apple's helper for it");
        ui.end(c);
        return;
    }
    const row = e.row(id);
    const busy = if (e.busy) |bid| std.mem.eql(u8, bid, id) else false;
    const detail = if (row == null)
        "Fill and save with the passwords in Apple's Passwords app, using Apple's own extension"
    else if (row.?.enabled)
        "On: Apple's key fills sign-in boxes. Kea's list steps aside."
    else
        "Installed, turned off";
    plate.line(c, p, "Apple Passwords", detail);
    if (busy) {
        ring.ring(c, 12);
    } else if (row == null) {
        if (controls.pill(c, p, "Use Apple Passwords", .{}).clicked) apple.setUp(b);
    } else if (!row.?.enabled) {
        if (controls.pill(c, p, "Turn On", .{}).clicked) e.setEnabled(id, true);
    } else {
        if (controls.pill(c, p, "Pair…", .{}).clicked) buttons.press(e, id);
    }
    ui.end(c);
    frame.rule(c, p);
    plate.line(c, p, "Move Kea's passwords", "Write a CSV for Passwords › File › Import Passwords…");
    if (controls.pill(c, p, "Move…", .{}).clicked) apple.move(b);
    ui.end(c);
}

/// Says so when a password manager extension has taken the saving over.
fn savingDetail(b: *Browser, c: *ui.Context) []const u8 {
    if (b.kea.ext) |x| if (x.passwordSavingTakenBy()) |name|
        return c.print("{s} does the saving — it asked " ++ app_name ++ " not to offer", .{name});
    return "Asked once per site, never again for a site you refuse";
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    appleCard(b, c, p);
    plate.cardBox(c, p);
    plate.line(c, p, "Your passwords", "In the macOS keychain, shown with Touch ID");
    if (controls.pill(c, p, "Open…", .{}).clicked) {
        sheet.close(b, .tuning);
        sheet.show(b, .managing);
    }
    ui.end(c);
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "saves_passwords", "Offer to save passwords", savingDetail(b, c));
    frame.rule(c, p);
    const fill_detail = if (if (b.kea.ext) |x| x.usesApple() else false)
        "Apple Passwords does the filling while it's on."
    else
        "Click a sign-in box and the accounts kept for the site hang from it";
    _ = frame.prefLine(b, c, p, "fills_passwords", "Fill in sign-ins", fill_detail);
    frame.rule(c, p);
    const detail = if (!b.prefs.passkeys_possible)
        "Needs an Apple entitlement this build doesn't have — off keeps sites to the password"
    else if (passkeys.access() == .denied)
        "macOS was told no — System Settings › Privacy & Security › Passkeys Access for Web Browsers"
    else
        "Touch ID or an iCloud passkey, on sites that offer one";
    if (frame.prefLine(b, c, p, "passkeys", "Offer passkeys", detail))
        @import("form_relay.zig").passkeysChanged(b.kea);
    const v = vault.Vault.of(b.kea);
    const never: []const []u8 = v.never() catch &.{};
    defer {
        for (never) |h| v.gpa.free(h);
        v.gpa.free(never);
    }
    if (never.len > 0) {
        frame.rule(c, p);
        plate.line(c, p, "Sites never asked", c.print("{d} sites told to stop offering", .{never.len}));
        if (controls.pill(c, p, "Forget", .{}).clicked) {
            v.setNever(&.{});
            b.announce("Every site can ask again");
        }
        ui.end(c);
    }
    ui.end(c);

    plate.cardBox(c, p);
    plate.line(c, p, "Bring yours in", "From another browser on this Mac, or a CSV exported from the Mac's Passwords app — nothing leaves it");
    ui.row(c, .{ .gap = 8 });
    if (comptime @hasField(Browser, "bringing_in")) {
        if (controls.pill(c, p, "Import…", .{}).clicked) {
            sheet.close(b, .tuning);
            b.bringing_in = "";
        }
    }
    if (comptime @hasDecl(Browser, "importFile")) {
        if (controls.pill(c, p, "File…", .{}).clicked) b.importFile();
    }
    ui.end(c);
    ui.end(c);
    ui.end(c);
}
