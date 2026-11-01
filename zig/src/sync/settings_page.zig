//! Settings › Sync (`SyncSettings`, Sync.swift:785-961): where your Macs
//! meet — nowhere, a synced folder, Google Drive or a bucket — how this Mac
//! unlocks the store, what goes across, who else is there, and Handoff.
//! Drive's rows, the place's warnings and the unlock rows: settings_drive.zig.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const app_name = @import("../app/kea.zig").app_name;
const Palette = @import("../design/palette.zig").Palette;
const controls = @import("../chrome/controls.zig");
const plate = @import("../chrome/controls_plate.zig");
const frame = @import("../chrome/settings/frame.zig");
const sync_mod = @import("sync.zig");
const Sync = sync_mod.Sync;
const Place = sync_mod.Place;
const relative = @import("tick.zig").relative;
const more = @import("settings_drive.zig");

/// The page's own fields (`@State`), afresh each time Settings appears.
pub const State = struct {
    endpoint: ui.TextBuffer = .{},
    bucket: ui.TextBuffer = .{},
    access: ui.TextBuffer = .{},
    secret: ui.TextBuffer = .{},
    passphrase: ui.TextBuffer = .{},
    drive_client_id: ui.TextBuffer = .{},
    drive_new_folder: ui.TextBuffer = .{},
    import_key: ui.TextBuffer = .{},
    backup_pass: ui.TextBuffer = .{},
    show_oauth_client: bool = false,
    browsing_drive: bool = false,
    confirming_overwrite: bool = false,
    showing_import_key: bool = false,
    showing_backup_pass: bool = false,
    /// The account key's last four characters, read once from the keychain.
    ak_hint: ?[4]u8 = null,
    ak_checked: bool = false,
    /// `onAppear` filled the bucket's fields from Sync.
    appeared: bool = false,

    pub fn deinit(s: *State) void {
        inline for (.{ "endpoint", "bucket", "access", "secret", "passphrase", "drive_client_id", "drive_new_folder", "import_key", "backup_pass" }) |f| @field(s, f).deinit();
    }
};

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.settings.sync;
    const sync = &b.kea.sync;
    if (!s.appeared) {
        s.appeared = true;
        s.endpoint.set(sync.endpoint);
        s.bucket.set(sync.bucket);
        s.access.set(sync.access);
    }
    where(b, c, p, s, sync);
    kinds(c, p, sync);
    macs(b, c, p, sync);
}

fn where(b: *Browser, c: *ui.Context, p: *const Palette, s: *State, sync: *Sync) void {
    plate.cardBox(c, p);
    defer ui.end(c);
    plate.line(c, p, "Sync through", "Google Drive, a synced folder, or a cloud bucket");
    var at: usize = @backingInt(sync.place);
    if (controls.segmented(c, p, &.{ "Off", "Folder", "Drive", "Bucket" }, &at, false)) sync.setPlace(@fromBackingInt(@intCast(at)));
    ui.end(c);
    switch (sync.place) {
        .off => {},
        .folder => {
            frame.rule(c, p);
            plate.line(c, p, "Folder", if (sync.folder.len == 0) "None chosen" else homeShort(c, sync.folder));
            if (controls.pill(c, p, "Choose…", .{}).clicked) choose(b);
            ui.end(c);
        },
        .drive => more.drive(b, c, p, s, sync),
        .bucket => {
            frame.rule(c, p);
            plate.line(c, p, "Endpoint", "Google Cloud Storage: https://storage.googleapis.com, with an HMAC key");
            _ = field(c, p, &s.endpoint, "https://storage.googleapis.com", 210, false);
            ui.end(c);
            frame.rule(c, p);
            plate.line(c, p, "Bucket", null);
            _ = field(c, p, &s.bucket, "Bucket", 160, false);
            ui.end(c);
            frame.rule(c, p);
            plate.line(c, p, "Access key", null);
            _ = field(c, p, &s.access, "Access key", 160, false);
            ui.end(c);
            frame.rule(c, p);
            plate.line(c, p, "Secret", null);
            ui.row(c, .{ .gap = 6, .align_items = .center });
            const typed = field(c, p, &s.secret, "Secret", 130, true).submitted;
            if (controls.pill(c, p, "Keep", .{}).clicked or typed) keepBucket(b, s, sync);
            ui.end(c);
            ui.end(c);
        },
    }
    if (sync.place != .off) {
        more.alerts(b, c, p, s, sync);
        more.unlock(b, c, p, s, sync);
    }
    frame.rule(c, p);
    plate.line(c, p, "Status", sync.status);
    if (controls.pill(c, p, "Sync Now", .{}).clicked) sync.syncNow();
    ui.end(c);
}

fn kinds(c: *ui.Context, p: *const Palette, sync: *Sync) void {
    plate.cardBox(c, p);
    defer ui.end(c);
    for (std.enums.values(sync_mod.Kind), 0..) |kind, i| {
        if (i > 0) frame.rule(c, p);
        ui.key(c, @tagName(kind));
        const on = sync.kinds.contains(kind);
        if (frame.switchLine(c, p, kind.title(), null, on)) sync.setKind(kind, !on);
    }
}

fn macs(b: *Browser, c: *ui.Context, p: *const Palette, sync: *Sync) void {
    plate.cardBox(c, p);
    defer ui.end(c);
    plate.line(c, p, "This Mac", sync.name);
    ui.end(c);
    frame.rule(c, p);
    plate.line(c, p, "Your other Macs", otherMacs(c.alloc(), sync.devices) catch "None yet");
    ui.end(c);
    frame.rule(c, p);
    if (frame.switchLine(c, p, "Handoff", "The page in front shows up on your iPhone, iPad and other Macs", b.prefs.handoff)) {
        b.prefs.set("handoff", !b.prefs.handoff);
        for (b.kea.browsers.items) |each| each.handOff();
    }
}

/// `otherMacsLine`: each Mac and when it was last heard from, on `a`.
pub fn otherMacs(a: std.mem.Allocator, devices: []const sync_mod.Device) ![]const u8 {
    if (devices.len == 0) return "None yet";
    var out: std.ArrayList(u8) = .empty;
    for (devices, 0..) |d, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "{s} · {s}", .{ d.name, try relative(a, d.seen) });
    }
    return out.items;
}

/// A plain field on the wash, its prompt in faint (`textField`/`secureField`).
/// The prompt comes after the field, so typing doesn't move the field's id.
pub fn field(c: *ui.Context, p: *const Palette, buf: *ui.TextBuffer, prompt: []const u8, width: f32, secure: bool) ui.TextFieldResult {
    ui.column(c, .{ .width = .{ .px = width + 16 }, .padding = .xy(8, 5), .radius = 7, .background = p.wash });
    defer ui.end(c);
    const r = ui.textField(c, buf, .{ .bare = true, .size = 12, .width = .fill, .password = secure, .caret_color = p.ink, .selection_color = p.ink.alpha(0.12) });
    // VoiceOver names the field by its prompt (drawn here, in faint, not by
    // the field), and never reads a secret out.
    const said = c.a11y_items.items;
    if (said.len > 0 and said[said.len - 1].role == .text_field) {
        said[said.len - 1].label = prompt;
        if (secure) said[said.len - 1].value = "";
    }
    if (buf.text().len == 0)
        _ = c.leaf(.{ .absolute = true, .offset = .{ .y = 2 } }, .{ .text = .{ .str = prompt, .style = .{ .size = 12, .truncate = .ellipsis }, .color = p.faint } }, null);
    return r;
}

/// The path with the home folder written as ~.
fn homeShort(c: *ui.Context, path: []const u8) []const u8 {
    const home = std.mem.span(std.c.getenv("HOME") orelse return path);
    if (home.len == 0) return path;
    return std.mem.replaceOwned(u8, c.alloc(), path, home, "~") catch path;
}

fn keepBucket(b: *Browser, s: *State, sync: *Sync) void {
    const sec = if (s.secret.text().len > 0) s.secret.text() else (sync.secret orelse "");
    if (sync.useBucket(s.endpoint.text(), s.bucket.text(), s.access.text(), sec)) |err| b.announce(err) else s.secret.clear();
}

/// The bucket's fields, kept first when they changed. Whether to go on.
pub fn keepBucketIfChanged(b: *Browser, s: *State, sync: *Sync) bool {
    const sec = if (s.secret.text().len > 0) s.secret.text() else (sync.secret orelse "");
    if (s.secret.text().len > 0 or !std.mem.eql(u8, s.endpoint.text(), sync.endpoint) or !std.mem.eql(u8, s.bucket.text(), sync.bucket) or !std.mem.eql(u8, s.access.text(), sync.access)) {
        if (sync.useBucket(s.endpoint.text(), s.bucket.text(), s.access.text(), sec)) |err| {
            b.announce(err);
            return false;
        }
        s.secret.clear();
    }
    return true;
}

pub fn applyPassphrase(b: *Browser, s: *State, sync: *Sync) void {
    if (sync.place == .bucket and !keepBucketIfChanged(b, s, sync)) return;
    // `use` keeps its own copy; the field empties at once.
    const said = sync.use(s.passphrase.text(), b);
    s.passphrase.clear();
    if (said) |err| b.announce(err);
}

/// `choose`: a folder, in iCloud Drive when there is one, asked modally
/// (`runModal`) after this frame. Never in a test run.
fn choose(b: *Browser) void {
    if (b.kea.opts.root != null or b.window == null) return;
    objc.dispatchMain(b.kea, chooseLater);
}

fn chooseLater(ctx: ?*anyopaque) callconv(.c) void {
    const kea: *Kea = @ptrCast(@alignCast(ctx.?));
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = objc.msg(objc.Object, objc.class("NSOpenPanel"), "openPanel", .{});
    objc.msg(void, panel, "setCanChooseDirectories:", .{objc.YES});
    objc.msg(void, panel, "setCanChooseFiles:", .{objc.NO});
    objc.msg(void, panel, "setCanCreateDirectories:", .{objc.YES});
    const home = NSHomeDirectory();
    const cloud_storage = objc.msg(objc.Object, home, "stringByAppendingPathComponent:", .{objc.nsString("Library/CloudStorage")});
    const icloud = objc.msg(objc.Object, home, "stringByAppendingPathComponent:", .{objc.nsString("Library/Mobile Documents/com~apple~CloudDocs")});
    var is_dir: objc.BOOL = objc.NO;
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const start = if (kea.sync.folder.len > 0 and objc.msg(objc.BOOL, fm, "fileExistsAtPath:isDirectory:", .{ objc.nsString(kea.sync.folder), &is_dir }) and is_dir)
        objc.nsString(kea.sync.folder)
    else if (objc.msg(objc.BOOL, fm, "fileExistsAtPath:isDirectory:", .{ cloud_storage, &is_dir }) and is_dir)
        cloud_storage
    else if (objc.msg(objc.BOOL, fm, "fileExistsAtPath:isDirectory:", .{ icloud, &is_dir }) and is_dir)
        icloud
    else
        home;
    objc.msg(void, panel, "setDirectoryURL:", .{objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{start})});
    objc.msg(void, panel, "setPrompt:", .{objc.nsString("Sync here")});
    // NSModalResponseOK
    if (objc.msg(objc.NSInteger, panel, "runModal", .{}) != 1) return;
    const url = objc.msg(?objc.Object, panel, "URL", .{}) orelse return;
    kea.sync.chooseFolder(objc.fromNSString(objc.msg(objc.Object, url, "path", .{})));
}

extern "c" fn NSHomeDirectory() objc.Object;
