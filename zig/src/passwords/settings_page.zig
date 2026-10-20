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

/// Says so when a password manager extension has taken the saving over.
fn savingDetail(b: *Browser, c: *ui.Context) []const u8 {
    if (b.kea.ext) |x| if (x.passwordSavingTakenBy()) |name|
        return c.print("{s} does the saving — it asked " ++ app_name ++ " not to offer", .{name});
    return "Asked once per site, never again for a site you refuse";
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
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
    _ = frame.prefLine(b, c, p, "fills_passwords", "Fill in sign-ins", "Click a sign-in box and the accounts kept for the site hang from it");
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
