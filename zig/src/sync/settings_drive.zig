//! Settings › Sync's newer rows (settings_page.zig): Google Drive's account
//! and folder (one Kea made: browsed to or made), what the chosen place holds and
//! what to do about it — other files, a store already there, damage — and
//! how this Mac unlocks: a passphrase or its account key.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const frame = @import("../chrome/settings/frame.zig");
const disclose = @import("../chrome/disclose.zig");
const motion = @import("../design/motion.zig");
const ring = @import("../chrome/ring.zig");
const keyring = @import("keyring.zig");
const gdrive = @import("gdrive.zig");
const Vault = @import("../passwords/vault.zig").Vault;
const page = @import("settings_page.zig");
const Sync = @import("sync.zig").Sync;
const State = page.State;
const field = page.field;
/// Built with Kea's own OAuth client (`-Dgdrive-client-id`): nothing to set up.
const built_in = @import("kea_options").gdrive_client_id.len > 0;

pub fn drive(b: *Browser, c: *ui.Context, p: *const Palette, s: *State, sync: *Sync) void {
    frame.rule(c, p);
    if (sync.drive_refresh != null) {
        plate.line(c, p, "Google Account", if (sync.drive_email.len > 0) sync.drive_email else "Signed in");
        if (controls.pill(c, p, "Disconnect", .{}).clicked) sync.disconnectDrive();
    } else if (sync.drive_signing_in) {
        plate.line(c, p, "Google Account", "Waiting for Google sign-in in your browser…");
        ring.ring(c, 12);
        if (controls.pill(c, p, "Cancel", .{}).clicked) sync.cancelDriveSignIn();
    } else {
        plate.line(c, p, "Google Account", "Sign in once. Kea sees only the folders it makes in your Drive");
        ui.row(c, .{ .gap = 6, .align_items = .center });
        if (!built_in and controls.pill(c, p, "OAuth Client…", .{}).clicked) {
            s.show_oauth_client = !s.show_oauth_client;
            if (s.show_oauth_client) s.drive_client_id.set(sync.drive_client_id);
        }
        if (controls.pill(c, p, "Sign In…", .{ .filled = true }).clicked) if (sync.startDriveSignIn(b)) |why| {
            s.show_oauth_client = true;
            b.announce(why);
        };
        ui.end(c);
    }
    ui.end(c);
    if (disclose.begin(c, 0x6b65_612e_6764_6331, !built_in and s.show_oauth_client and sync.drive_refresh == null, motion.settle)) {
        defer disclose.end(c);
        frame.rule(c, p);
        plate.line(c, p, "Client ID", "A Google Cloud “Desktop app” OAuth client with the Drive API on");
        ui.row(c, .{ .gap = 6, .align_items = .center });
        const typed = field(c, p, &s.drive_client_id, "Google Desktop OAuth Client ID", 200, false).submitted;
        if (controls.pill(c, p, "Save", .{}).clicked or typed) {
            sync.setDriveClientId(s.drive_client_id.text());
            s.show_oauth_client = false;
        }
        ui.end(c);
        ui.end(c);
    }
    if (sync.drive_refresh == null) return;
    frame.rule(c, p);
    plate.line(c, p, "Drive folder", if (sync.drive_folder_path.len > 0) sync.drive_folder_path else "None chosen");
    ui.row(c, .{ .gap = 6, .align_items = .center });
    if (controls.pill(c, p, "Use ‘Kea Sync’", .{}).clicked) sync.useKeaSyncFolder(b);
    if (controls.pill(c, p, "Browse…", .{}).clicked) {
        s.browsing_drive = !s.browsing_drive;
        if (s.browsing_drive) sync.browseDrive("root", "My Drive");
    }
    ui.end(c);
    ui.end(c);
    if (disclose.begin(c, 0x6b65_612e_6764_6232, s.browsing_drive, motion.settle)) {
        defer disclose.end(c);
        browser(b, c, p, s, sync);
    }
}

/// Where you are in My Drive, the folders Kea made there, and a new one.
fn browser(b: *Browser, c: *ui.Context, p: *const Palette, s: *State, sync: *Sync) void {
    ui.column(c, .{ .width = .fill, .gap = 8, .padding = .{ .left = 14, .right = 14, .bottom = 11 } });
    defer ui.end(c);
    // Going somewhere lets go of the crumbs and folders drawn here: what
    // is drawn is the frame's copy, and the step is taken after.
    const fa = c.alloc();
    var back: ?usize = null;
    var into: ?gdrive.FolderEntry = null;
    ui.row(c, .{ .gap = 4, .width = .fill, .align_items = .center });
    if (plate.quick(c, p, "My Drive", null).clicked) back = 0;
    for (sync.browse.crumbs.items, 0..) |crumb, i| {
        ui.text(c, "›", .{ .size = 11.5, .color = p.faint });
        ui.key(c, crumb.id);
        if (plate.quick(c, p, fa.dupe(u8, crumb.name) catch "", null).clicked) back = i + 1;
    }
    _ = c.leaf(.{ .grow = 1 }, .none, null);
    if (controls.pill(c, p, "Select Current Folder", .{ .filled = true }).clicked) {
        sync.selectDriveFolder();
        s.browsing_drive = false;
    }
    ui.end(c);
    ui.scroll(c, .{ .width = .fill, .max_height = 150, .radius = 8, .background = p.wash, .scroll_bar = false });
    if (sync.browse.entries.len == 0) plate.nothing(c, p, if (sync.browse.loading) "Loading…" else "No folders made by Kea here");
    for (sync.browse.entries) |entry| {
        const e: gdrive.FolderEntry = .{ .id = fa.dupe(u8, entry.id) catch "", .name = fa.dupe(u8, entry.name) catch "", .can_write = entry.can_write };
        ui.key(c, e.id);
        const i = c.open(.{ .width = .fill, .padding = .xy(10, 6), .gap = 8, .direction = .row, .align_items = .center, .control = e.can_write }, null);
        const it = c.interact(i, .{});
        c.addA11y(i, .button, e.name, "", false, e.can_write);
        ui.icon(c, "folder", .{ .size = 12, .color = if (e.can_write) p.ink else p.faint });
        ui.text(c, e.name, .{ .size = 12.5, .color = if (e.can_write) p.ink else p.faint, .truncate = .ellipsis });
        if (!e.can_write) ui.text(c, "Read-only", .{ .size = 11, .color = p.faint });
        c.end();
        if (it.clicked and e.can_write) into = e;
    }
    ui.end(c);
    if (back) |depth| sync.browseDriveBack(depth);
    if (into) |e| sync.browseDrive(e.id, e.name);
    ui.row(c, .{ .gap = 6, .width = .fill, .align_items = .center });
    const made = field(c, p, &s.drive_new_folder, "New folder name", 150, false).submitted;
    if (controls.pill(c, p, "Create", .{}).clicked or made) {
        sync.createDriveFolder(s.drive_new_folder.text(), b);
        s.drive_new_folder.clear();
    }
    ui.end(c);
}

/// A tinted box of words (and a note in red under them) and its actions;
/// close with `endAlert`.
fn alertBox(c: *ui.Context, p: *const Palette, icon: []const u8, tint: ui.Color, text: []const u8, note: ?[]const u8) void {
    ui.column(c, .{ .width = .fill, .padding = .{ .left = 14, .right = 14, .bottom = 11 } });
    ui.column(c, .{ .width = .fill, .gap = 8, .padding = .xy(12, 10), .radius = 9, .background = tint.alpha(0.08), .border = tint.alpha(0.25) });
    ui.row(c, .{ .gap = 8, .width = .fill });
    ui.icon(c, icon, .{ .size = 12, .weight = .medium, .color = tint });
    ui.text(c, text, .{ .size = 12, .color = p.ink, .wrap = true, .max_lines = 4 });
    ui.end(c);
    if (note) |n| ui.text(c, n, .{ .size = 11.5, .color = p.red, .wrap = true });
    ui.row(c, .{ .gap = 6, .align_items = .center });
}

fn endAlert(c: *ui.Context) void {
    ui.end(c);
    ui.end(c);
    ui.end(c);
}

/// What the chosen place holds, and what can be done about it.
pub fn alerts(b: *Browser, c: *ui.Context, p: *const Palette, s: *State, sync: *Sync) void {
    if (sync.warning_error.len > 0) {
        frame.rule(c, p);
        alertBox(c, p, "exclamationmark.triangle", p.red, c.print("{s} Nothing was lost: the store that was there is still in place.", .{sync.warning_error}), null);
        if (controls.pill(c, p, "Dismiss", .{}).clicked) sync.setWarning("");
        if (controls.pill(c, p, "Retry", .{}).clicked) overwrite(b, s, sync);
        endAlert(c);
    }
    switch (sync.location) {
        .non_empty_unrelated => |n| blk: {
            const id = sync.storeIdentity();
            defer sync.gpa.free(id);
            if (std.mem.eql(u8, id, sync.allow_non_empty_for) or sync.ready) break :blk;
            frame.rule(c, p);
            alertBox(c, p, "exclamationmark.triangle", p.sunset, c.print("This folder already contains {d} item(s) (e.g. ‘{s}’). Sync files go in a “kea” folder beside them.", .{ n.count, n.sample }), null);
            if (controls.pill(c, p, "Create ‘Kea Sync’ Subfolder", .{ .filled = true }).clicked) sync.createSubfolderAndUse(b);
            if (controls.pill(c, p, "Sync Here Anyway", .{}).clicked) sync.confirmUseNonEmpty(b);
            endAlert(c);
        },
        .existing_v2, .existing_v1 => blk: {
            if (sync.ready) break :blk;
            const macs = switch (sync.location) {
                .existing_v2 => |e| e.device_count,
                .existing_v1 => |e| e.device_count,
                else => 0,
            };
            frame.rule(c, p);
            const note = "Overwriting archives the existing store under kea/quarantine/ and replaces it with this Mac's data.";
            alertBox(c, p, "info.circle", p.ink, c.print("Existing Kea sync store found ({d} Mac(s)). Unlock below to join and merge, or replace it.", .{macs}), if (s.confirming_overwrite) note else null);
            if (!s.confirming_overwrite) {
                if (controls.pill(c, p, "Overwrite Store…", .{}).clicked) s.confirming_overwrite = true;
            } else {
                if (controls.pill(c, p, "Archive & Overwrite", .{ .tint = p.red }).clicked) overwrite(b, s, sync);
                if (controls.pill(c, p, "Cancel", .{}).clicked) s.confirming_overwrite = false;
            }
            endAlert(c);
        },
        .corrupted_store => |e| {
            frame.rule(c, p);
            alertBox(c, p, "exclamationmark.triangle", p.red, c.print("{s} ({d} commit(s), {d} pack(s)).", .{ e.reason, e.commit_count, e.pack_count }), null);
            if (controls.pill(c, p, "Attempt DAG Salvage", .{}).clicked) say(b, sync.salvageStore(s.passphrase.text(), b));
            if (controls.pill(c, p, "Archive & Reset Store", .{ .tint = p.red }).clicked) overwrite(b, s, sync);
            if (e.quarantine_count > 0) if (controls.pill(c, p, "Restore Quarantined", .{}).clicked) sync.restoreQuarantined(b);
            endAlert(c);
        },
        else => {},
    }
    if (sync.damaged_note.len > 0 and sync.ready) {
        frame.rule(c, p);
        alertBox(c, p, "bandage", p.muted, sync.damaged_note, null);
        if (controls.pill(c, p, "Repair Store", .{}).clicked) sync.repairStore(b);
        endAlert(c);
    }
}

fn say(b: *Browser, said: ?[]const u8) void {
    if (said) |x| b.announce(x);
}

fn overwrite(b: *Browser, s: *State, sync: *Sync) void {
    s.confirming_overwrite = false;
    say(b, sync.overwriteExistingStore(s.passphrase.text(), b));
    s.passphrase.clear();
}

/// "••••" and the account key's last four characters, or what will happen.
fn keyHint(c: *ui.Context, s: *State, sync: *Sync) []const u8 {
    if (!s.ak_checked) {
        s.ak_checked = true;
        s.ak_hint = if (sync.knownAccountKey()) |ak| keyring.encodePortableKey(ak)[55..59].* else null;
    }
    const h = s.ak_hint orelse return "Ready to create in Keychain";
    return c.print("Account key ••••{s}", .{&h});
}

/// How this Mac unlocks the store — chosen while it is locked — and, once
/// open, the other way in it can add, on the same row.
pub fn unlock(b: *Browser, c: *ui.Context, p: *const Palette, s: *State, sync: *Sync) void {
    if (!sync.ready) {
        frame.rule(c, p);
        plate.line(c, p, "Unlock with", "Manual passphrase or an Account Key in your Keychain");
        var km: usize = @backingInt(sync.key_mode);
        if (controls.segmented(c, p, &.{ "Passphrase", "Account Key" }, &km, false)) sync.setKeyMode(@fromBackingInt(@intCast(km)));
        ui.end(c);
    }
    frame.rule(c, p);
    switch (sync.key_mode) {
        .password => {
            plate.line(c, p, "Passphrase", "The same on each of your Macs. " ++ @import("../app/kea.zig").app_name ++ " can't recover it.");
            ui.row(c, .{ .gap = 6, .align_items = .center });
            const typed = field(c, p, &s.passphrase, "Passphrase", 140, true).submitted;
            if (controls.pill(c, p, "Use", .{}).clicked or typed) page.applyPassphrase(b, s, sync);
            if (sync.ready and !sync.ring_has_my_account_key) if (controls.pill(c, p, "Add Account Key", .{}).clicked) say(b, sync.enrollBackupAccountKey(b));
            ui.end(c);
            ui.end(c);
        },
        .account_key => {
            plate.line(c, p, "Account Key", keyHint(c, s, sync));
            ui.row(c, .{ .gap = 6, .align_items = .center });
            const matching = switch (sync.location) {
                .existing_v2 => |e| e.has_matching_account_key,
                else => false,
            };
            if (!sync.ready) if (controls.pill(c, p, if (matching) "Join & Merge" else "Use Account Key", .{ .filled = true }).clicked) {
                if (sync.place != .bucket or page.keepBucketIfChanged(b, s, sync)) say(b, sync.useAccountKey(b));
                s.ak_checked = false;
            };
            if (controls.pill(c, p, "Copy Key…", .{}).clicked) copyKey(b);
            if (!sync.ready) if (controls.pill(c, p, "Import Key…", .{}).clicked) {
                s.showing_import_key = !s.showing_import_key;
            };
            if (sync.ready and !sync.ring_has_password) if (controls.pill(c, p, "Add Backup Passphrase…", .{}).clicked) {
                s.showing_backup_pass = !s.showing_backup_pass;
            };
            ui.end(c);
            ui.end(c);
        },
    }
    if (disclose.begin(c, 0x6b65_612e_616b_6931, s.showing_import_key and sync.key_mode == .account_key and !sync.ready, motion.settle)) {
        defer disclose.end(c);
        frame.rule(c, p);
        plate.line(c, p, "Import", "The key from Copy Key… on your other Mac");
        ui.row(c, .{ .gap = 6, .align_items = .center });
        const typed = field(c, p, &s.import_key, "kea-key-v1-…", 200, true).submitted;
        if (controls.pill(c, p, "Import", .{}).clicked or typed) {
            say(b, sync.importAccountKey(s.import_key.text(), b));
            s.import_key.clear();
            s.showing_import_key = false;
            s.ak_checked = false;
        }
        ui.end(c);
        ui.end(c);
    }
    if (disclose.begin(c, 0x6b65_612e_6270_6131, s.showing_backup_pass and sync.ready and !sync.ring_has_password, motion.settle)) {
        defer disclose.end(c);
        frame.rule(c, p);
        plate.line(c, p, "Backup passphrase", "Unlocks this store on a Mac without your account key");
        ui.row(c, .{ .gap = 6, .align_items = .center });
        const typed = field(c, p, &s.backup_pass, "Backup passphrase", 140, true).submitted;
        if (controls.pill(c, p, "Add", .{}).clicked or typed) {
            say(b, sync.enrollBackupPassword(s.backup_pass.text(), b));
            s.backup_pass.clear();
            s.showing_backup_pass = false;
        }
        ui.end(c);
        ui.end(c);
    }
}

const Copying = struct { kea: *Kea, record: @FieldType(Browser, "record_id") };

/// Copy Key…: after Touch ID or your password, the key as text for your other Mac.
fn copyKey(b: *Browser) void {
    const ctx = std.heap.c_allocator.create(Copying) catch return;
    ctx.* = .{ .kea = b.kea, .record = b.record_id };
    Vault.of(b.kea).prove("Copy your Kea Sync account key", ctx, copied);
}

fn copied(raw: *anyopaque, ok: bool) void {
    const ctx: *Copying = @ptrCast(@alignCast(raw));
    defer std.heap.c_allocator.destroy(ctx);
    if (!ok) return;
    const b = for (ctx.kea.browsers.items) |x| {
        if (x.record_id.eql(ctx.record)) break x;
    } else return;
    const ak = ctx.kea.sync.accountKey() orelse return b.announce("The keychain refused the account key");
    var text = keyring.encodePortableKey(ak);
    defer std.crypto.secureZero(u8, &text);
    ctx.kea.writeClipboard(&text);
    b.settings.sync.ak_checked = false;
    b.announce("Account key copied");
}
