//! `PasswordsPanel` (Passwords.swift): every password kept, by site. A
//! password is never shown until you have proved you are you, and never for
//! longer than it takes to read it. A sheet (`chrome/sheet.zig`, `managing`).
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const app_name = @import("../app/kea.zig").app_name;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const plate = @import("../chrome/controls_plate.zig");
const controls = @import("../chrome/controls.zig");
const mark = @import("../chrome/mark.zig");
const sheet = @import("../chrome/sheet.zig");
const disclose = @import("../chrome/disclose.zig");
const json = @import("../data/json.zig");
const objc = @import("nanoui").objc;
const bp = @import("browser_passwords.zig");
const vault = @import("vault.zig");
const Kept = vault.Kept;

/// Long enough to read or type across, and not a minute more.
const shown_for: u64 = 15;

/// The one password on screen, and the only place its secret is held.
const Shown = struct {
    gpa: std.mem.Allocator,
    host: []u8,
    user: []u8,
    secret: []u8,
    /// Which showing it is, so a late timer leaves a newer one be.
    gen: u32,

    fn free(s: Shown) void {
        std.crypto.secureZero(u8, s.secret);
        s.gpa.free(s.secret);
        s.gpa.free(s.host);
        s.gpa.free(s.user);
    }

    fn is(s: Shown, k: Kept) bool {
        return std.mem.eql(u8, s.host, k.host) and std.mem.eql(u8, s.user, k.user);
    }
};

pub const State = struct {
    /// The site opened (`open`), on gpa.
    open: ?[]u8 = null,
    adding: bool = false,
    /// The Hunt has had its focus (`onAppear { hunting = true }`).
    focused: bool = false,
    /// The Add form's site field has had its focus.
    add_focused: bool = false,
    site: ui.TextBuffer = .{},
    user: ui.TextBuffer = .{},
    password: ui.TextBuffer = .{},
    shown: ?Shown = null,
    gen: u32 = 0,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.open) |o| gpa.free(o);
        s.open = null;
        s.site.deinit();
        s.user.deinit();
        wipeBuffer(&s.password);
        s.password.deinit();
        s.conceal();
    }

    /// Hidden again, and the secret with it.
    fn conceal(s: *State) void {
        if (s.shown) |sh| sh.free();
        s.shown = null;
    }

    fn closeAdd(s: *State) void {
        s.adding = false;
        s.add_focused = false;
        s.site.clear();
        s.user.clear();
        wipeBuffer(&s.password);
        s.password.clear();
    }
};

const add_id: u64 = 0x6b65_612e_6164_6421;

const Act = union(enum) { none, toggle: []const u8, show: Kept, hide, copy: Kept, forget: Kept };

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.passwords.panel;
    var pl = plate.plate(c, p, "Passwords", 620);
    if (pl.closed) sheet.close(b, .managing);
    ui.column(c, .{ .width = .fill, .gap = 14 });
    ui.row(c, .{ .width = .fill, .gap = 10, .align_items = .center });
    _ = plate.huntFocus(c, p, &b.passwords.hunting, "Search sites and accounts", !st.focused);
    st.focused = true;
    if (controls.pill(c, p, if (st.adding) "Cancel" else "Add", .{ .filled = !st.adding }).clicked) {
        if (st.adding) st.closeAdd() else st.adding = true;
    }
    ui.end(c);
    // Fades in and out (`.transition(.opacity)`), what is below settling.
    if (disclose.begin(c, add_id, st.adding, motion.settle)) {
        plate.cardBox(c, p);
        addForm(b, c, p, st.adding);
        ui.end(c);
        disclose.end(c);
    }
    const sites = bp.shownSites(b, c.alloc()) catch &.{};
    var act: Act = .none;
    if (sites.len == 0) {
        plate.cardBox(c, p);
        plate.nothing(c, p, if (b.passwords.saved.len == 0)
            "No passwords tucked away yet. Sign in somewhere and say yes, or bring yours in below."
        else
            "Nothing matches. The kea checked under every rock.");
        ui.end(c);
    } else {
        ui.column(c, .{ .scroll = true, .width = .fill, .max_height = 400, .scroll_bar = false, .padding = .{ .bottom = 2 } });
        plate.cardBox(c, p);
        for (sites, 0..) |s, n| {
            ui.key(c, s.host);
            if (n > 0) plate.rule(c, p, 14);
            const a = site(b, c, p, s);
            if (a != .none) act = a;
        }
        ui.end(c);
        ui.end(c);
    }
    // Filtered out of view: it lets its secret go (`onDisappear`).
    if (st.shown) |sh| if (!drawn(sites, st.open, sh)) st.conceal();
    ui.end(c);
    pl.foot(c, p);
    foot(b, c, p);
    pl.end(c);
    do(b, act);
}

fn drawn(sites: []const bp.SiteRow, open: ?[]const u8, sh: Shown) bool {
    const o = open orelse return false;
    if (!std.mem.eql(u8, o, sh.host)) return false;
    for (sites) |s| if (std.mem.eql(u8, s.host, o)) for (s.logins) |k| if (sh.is(k)) return true;
    return false;
}

fn do(b: *Browser, act: Act) void {
    const st = &b.passwords.panel;
    switch (act) {
        .none => {},
        .toggle => |host| {
            const was = if (st.open) |o| std.mem.eql(u8, o, host) else false;
            if (st.open) |o| b.gpa.free(o);
            st.open = if (was) null else b.gpa.dupe(u8, host) catch null;
            // Rows that go out of view let their secret go (`onDisappear`).
            if (st.shown != null) st.conceal();
        },
        .show => |k| reveal(b, k),
        .hide => st.conceal(),
        .copy => |k| bp.copy(b, k),
        .forget => |k| {
            if (st.shown) |sh| if (sh.is(k)) st.conceal();
            bp.forget(b, k);
        },
    }
}

/// `Site`: a site, and under it its accounts once opened.
fn site(b: *Browser, c: *ui.Context, p: *const Palette, s: bp.SiteRow) Act {
    const st = &b.passwords.panel;
    const open = if (st.open) |o| std.mem.eql(u8, o, s.host) else false;
    var act: Act = .none;
    ui.column(c, .{ .width = .fill });
    defer ui.end(c);
    const i = c.open(.{ .direction = .row, .gap = 10, .width = .fill, .padding = .xy(14, 10), .align_items = .center }, null);
    const it = c.interact(i, .{});
    c.addA11y(i, .button, s.host, if (open) "open" else "", open, true);
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = if (open) p.wash.alpha(0.6) else p.hover.alpha(h);
    const icon = b.kea.favicons.cached(s.host);
    mark.mark(c, p, if (icon) |ic| .{ .key = ic.name, .png = ic.png } else null, mark.initial(c, s.host), 16, false);
    ui.text(c, s.host, .{ .size = 13, .color = p.ink, .truncate = true });
    if (s.logins.len > 1) {
        ui.text(c, c.print("{d} accounts", .{s.logins.len}), .{ .size = 11.5, .color = p.muted });
    } else if (s.logins.len == 1 and s.logins[0].user.len > 0 and !open) {
        ui.text(c, s.logins[0].user, .{ .size = 11.5, .color = p.muted, .truncate_middle = true });
    }
    ui.spacer(c);
    _ = c.leaf(.{ .min_width = 8, .width = .{ .px = 8 } }, .none, null);
    // A quarter turn as it opens, on the panel's `settle`.
    const turn = motion.settleTo(c, it.id, 1, if (open) 1 else 0);
    ui.icon(c, "chevron.right", .{ .size = 9, .weight = .semibold, .color = p.muted, .rotation = turn * std.math.pi / 2.0 });
    c.end();
    if (it.clicked) act = .{ .toggle = s.host };
    if (disclose.begin(c, it.id +% 1, open, motion.settle)) {
        ui.column(c, .{ .width = .fill, .padding = .{ .left = 30, .right = 6, .top = 4, .bottom = 4 } });
        for (s.logins) |k| {
            ui.key(c, k.user);
            const a = account(b, c, p, k);
            if (a != .none and open) act = a;
        }
        ui.end(c);
        disclose.end(c);
    }
    return act;
}

/// `Account`: the name, the password as dots, and the three things to do
/// with it. Show asks the Mac who you are first.
fn account(b: *Browser, c: *ui.Context, p: *const Palette, k: Kept) Act {
    const st = &b.passwords.panel;
    const shown: ?[]const u8 = if (st.shown) |sh| (if (sh.is(k)) sh.secret else null) else null;
    const i = c.open(.{ .direction = .row, .gap = 10, .width = .fill, .padding = .xy(10, 7), .radius = 8, .align_items = .center }, null);
    defer c.end();
    const it = c.interact(i, .{});
    const name = if (k.user.len == 0) "No username" else k.user;
    c.addA11y(i, .row, name, k.host, false, true);
    c.node(i).style.background = p.hover.alpha(motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0));
    ui.column(c, .{ .min_width = 120 });
    ui.text(c, name, .{ .size = 12, .color = if (k.user.len == 0) p.faint else p.ink, .truncate_middle = true });
    ui.end(c);
    // Ten dots whatever it is: a count that changed with it told anyone
    // looking over a shoulder how long it was.
    if (shown) |secret| {
        // Selectable, to be copied a piece at a time (`.textSelection(.enabled)`).
        ui.column(c, .{ .selectable = true, .min_width = 0 });
        ui.text(c, secret, .{ .size = 12.5, .mono = true, .color = p.ink, .truncate = true });
        ui.end(c);
    } else
        ui.text(c, "••••••••••", .{ .size = 10, .mono = true, .color = p.muted });
    ui.spacer(c);
    _ = c.leaf(.{ .min_width = 8, .width = .{ .px = 8 } }, .none, null);
    if (!it.hovered and shown == null) return .none;
    var act: Act = .none;
    if (plate.quick(c, p, if (shown != null) "Hide" else "Show", null).clicked)
        act = if (shown != null) .hide else .{ .show = k };
    if (plate.quick(c, p, "Copy", null).clicked) act = .{ .copy = k };
    if (plate.quick(c, p, "Remove", p.red.alpha(0.75)).clicked) act = .{ .forget = k };
    return act;
}

// MARK: showing one

const Proving = struct { kea: *Kea, record: json.Uuid, host: []u8, user: []u8 };

/// `reveal()`: proved first; the secret read after, not before.
fn reveal(b: *Browser, k: Kept) void {
    const gpa = std.heap.c_allocator;
    const host = gpa.dupe(u8, k.host) catch return;
    const user = gpa.dupe(u8, k.user) catch return gpa.free(host);
    const pr = gpa.create(Proving) catch {
        gpa.free(host);
        return gpa.free(user);
    };
    pr.* = .{ .kea = b.kea, .record = b.record_id, .host = host, .user = user };
    const reason = std.fmt.allocPrint(b.gpa, "show the password for {s}", .{k.host}) catch return proved(pr, false);
    defer b.gpa.free(reason);
    vault.Vault.of(b.kea).prove(reason, pr, provedAny);
}

fn provedAny(ctx: *anyopaque, ok: bool) void {
    proved(@ptrCast(@alignCast(ctx)), ok);
}

fn proved(pr: *Proving, ok: bool) void {
    const gpa = std.heap.c_allocator;
    defer {
        gpa.free(pr.host);
        gpa.free(pr.user);
        gpa.destroy(pr);
    }
    if (!ok) return;
    const b = for (pr.kea.browsers.items) |x| {
        if (x.record_id.eql(pr.record)) break x;
    } else return;
    if (!b.managing) return;
    const kg = pr.kea.gpa;
    const secret = vault.Vault.of(pr.kea).secretOf(.{ .host = pr.host, .user = pr.user }) orelse return;
    const host = kg.dupe(u8, pr.host) catch return wipe(kg, secret);
    const user = kg.dupe(u8, pr.user) catch {
        kg.free(host);
        return wipe(kg, secret);
    };
    const st = &b.passwords.panel;
    st.conceal();
    st.gen +%= 1;
    st.shown = .{ .gpa = kg, .host = host, .user = user, .secret = secret, .gen = st.gen };
    b.redraw();
    // Long enough to read or type across, and not a minute more — even with the sheet closed.
    const t = std.heap.c_allocator.create(Hiding) catch return;
    t.* = .{ .kea = pr.kea, .record = pr.record, .gen = st.gen };
    objc.dispatchAfter(shown_for * std.time.ns_per_s, t, hide);
}

const Hiding = struct { kea: *Kea, record: json.Uuid, gen: u32 };

fn hide(ctx: ?*anyopaque) callconv(.c) void {
    const t: *Hiding = @ptrCast(@alignCast(ctx.?));
    defer std.heap.c_allocator.destroy(t);
    const b = for (t.kea.browsers.items) |x| {
        if (x.record_id.eql(t.record)) break x;
    } else return;
    const st = &b.passwords.panel;
    const sh = st.shown orelse return;
    if (sh.gen != t.gen) return;
    st.conceal();
    b.redraw();
}

/// TextBuffer frees without zeroing: a typed password goes first.
fn wipeBuffer(buf: *ui.TextBuffer) void {
    std.crypto.secureZero(u8, buf.buf.allocatedSlice());
}

fn wipe(gpa: std.mem.Allocator, secret: []u8) void {
    std.crypto.secureZero(u8, secret);
    gpa.free(secret);
}

// MARK: typing one in

/// `AddForm`: the site, the name, the password, and Save.
/// A form still fading out (`live` false) neither takes focus nor saves.
fn addForm(b: *Browser, c: *ui.Context, p: *const Palette, live: bool) void {
    const st = &b.passwords.panel;
    ui.column(c, .{ .width = .fill, .gap = 8, .padding = .all(14) });
    defer ui.end(c);
    ui.row(c, .{ .width = .fill, .gap = 8 });
    _ = field(c, p, &st.site, "Site", false, live and !st.add_focused);
    if (live) st.add_focused = true;
    _ = field(c, p, &st.user, "Username", false, false);
    ui.end(c);
    ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
    const submitted = field(c, p, &st.password, "Password", true, false).submitted;
    const host = vault.host(c.alloc(), st.site.text()) catch "";
    const ready = host.len > 0 and st.password.text().len > 0;
    ui.column(c, .{ .opacity = if (ready) 1 else 0.4 });
    const saved = controls.pill(c, p, "Save", .{ .filled = true }).clicked;
    ui.end(c);
    ui.end(c);
    if ((saved or submitted) and ready and live) {
        bp.keepTyped(b, host, std.mem.trim(u8, st.user.text(), " "), st.password.text());
        st.closeAdd();
    }
}

fn field(c: *ui.Context, p: *const Palette, buf: *ui.TextBuffer, name: []const u8, secret: bool, focus: bool) ui.TextFieldResult {
    ui.column(c, .{ .grow = 1, .padding = .xy(10, 7), .radius = 9, .background = p.wash });
    defer ui.end(c);
    if (focus) ui.focusNext(c, false);
    const r = ui.textField(c, buf, .{ .bare = true, .size = 12.5, .width = .fill, .password = secret });
    // After the field, so the field's id stays put as the first key lands.
    if (buf.text().len == 0)
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 10, .y = 9 } }, .{ .text = .{ .str = name, .style = .{ .size = 12.5 }, .color = p.ink.alpha(0.3) } }, null);
    return r;
}

// MARK: the foot

fn foot(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.column(c, .{ .width = .fill, .gap = 10 });
    defer ui.end(c);
    ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
    ui.text(c, "Bring in from", .{ .size = 12, .color = p.muted });
    // Which browser, which profile and what of it: the sheet.
    if (comptime @hasField(Browser, "bringing_in")) {
        if (controls.pill(c, p, "Bring in…", .{}).clicked) {
            b.managing = false;
            b.bringing_in = "";
        }
    }
    if (comptime @hasDecl(Browser, "importFile")) {
        if (controls.pill(c, p, "File…", .{}).clicked) b.importFile();
    }
    ui.spacer(c);
    const n = b.passwords.saved.len;
    ui.text(c, if (n == 1) "1 password" else c.print("{d} passwords", .{n}), .{ .size = 12, .color = p.muted });
    ui.end(c);
    ui.text(c, "macOS asks once for that browser's keychain key. Nothing is changed there; everything lands in your own keychain, under " ++ app_name ++ ".", .{ .size = 11.5, .color = p.muted, .wrap = true });
}
