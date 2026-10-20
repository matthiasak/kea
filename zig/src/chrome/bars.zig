//! Everything that rises from the bottom edge to say one thing (App.swift
//! `bars`): the announcement — a line that says one thing and leaves, and
//! shows a file just saved in the Finder — a page asking for the camera,
//! the microphone, where you are or to send notifications (`captureAsking`,
//! answering the decision WebKit is holding), the offer to keep a password
//! a page just sent (`keepAsking`), the offer to add the Chrome Web Store
//! page's extension (`StoreOffer`, ext/ui.zig), and the hint while the
//! pointer is picking things to hide (`veiling`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const presence = @import("presence.zig");
const dialogs = @import("../web/dialogs.zig");
const keep_ops = @import("../web/downloads_keep.zig");

const id_said: u64 = std.hash.Wyhash.hash(0, "kea.bar.announcement");
const id_ask: u64 = std.hash.Wyhash.hash(0, "kea.bar.asking");
const id_veil: u64 = std.hash.Wyhash.hash(0, "kea.bar.veiling");
const id_keep: u64 = std.hash.Wyhash.hash(0, "kea.bar.keep-asking");
const id_store: u64 = std.hash.Wyhash.hash(0, "kea.bar.store-offer");
const ext_ui = @import("../ext/ui.zig");

/// `move(edge: .bottom)`: how far below its place a bar starts and ends.
const rise: f32 = 60;

/// The veiling hint's words.
pub const veil_hint = "Click anything to hide it   ⌘Z undo   esc done";

// MARK: Browser's announcements (`announce`, `announce(_:file:)`)

pub fn announce(b: *Browser, msg: []const u8) void {
    announceFile(b, msg, null);
}

/// `announce(_:file:)`: a line about a file stays long enough to be
/// clicked; VoiceOver hears it too.
pub fn announceFile(b: *Browser, msg: []const u8, file: ?[]const u8) void {
    const text = b.gpa.dupe(u8, msg) catch return;
    const copy = if (file) |f| b.gpa.dupe(u8, f) catch null else null;
    hush(b);
    b.announcement = text;
    b.announced_file = copy;
    b.announced_until = ui.clock.now() + @as(f64, if (file == null) 1.7 else 4);
    if (b.window) |w| nanoui.a11y.announce(w.nswindow, msg);
    b.redraw();
}

/// The window going: its announcement and the bars it kept.
pub fn release(b: *Browser) void {
    hush(b);
    b.bars.deinit(b.gpa);
}

/// The announcement gone, and its file.
pub fn hush(b: *Browser) void {
    if (b.announcement) |old| b.gpa.free(old);
    if (b.announced_file) |old| b.gpa.free(old);
    b.announcement = null;
    b.announced_file = null;
}

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const now = ui.clock.now();
    const live = b.announcement != null and now < b.announced_until;
    if (live) c.frameIn(@floatCast(b.announced_until - now + 0.01));
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .direction = .column, .justify = .end, .align_items = .center, .gap = 8, .padding = .{ .bottom = 30 } });
    defer ui.end(c);
    if (b.announcement) |text| {
        if (presence.presence(c, id_said, live, motion.bounce, motion.settle)) |t| announcement(b, c, p, text, t) else b.hush();
    }
    // A question answered (or its tab gone) leaves as it was last drawn.
    if (presence.presence(c, id_ask, b.asking != null, motion.bounce, motion.settle)) |t| {
        if (b.asking) |asking| captureAsking(b, c, p, asking, t) else _ = question(c, p, b.bars.ask, t, false);
    } else b.bars.ask.forget(b.gpa);
    if (presence.presence(c, id_keep, b.passwords.offering != null, motion.bounce, motion.settle)) |t| {
        if (b.passwords.offering) |offer| keepAsking(b, c, p, offer, t) else _ = question(c, p, b.bars.keep, t, false);
    } else b.bars.keep.forget(b.gpa);
    // Swift changes what the store bar watches outside any animation, so it
    // comes and goes at once (its transition never plays).
    if (ext_ui.offered(b)) |id| ext_ui.storeOffer(b, c, p, id, 1);
    if (presence.presence(c, id_veil, b.veiling, motion.bounce, motion.settle)) |t| hint(c, p, veil_hint, t);
}

/// A question bar as drawn: what it says and its answers, the first on ink.
pub const Question = struct {
    key: []const u8 = "",
    icon: ?[]const u8 = null,
    said: []const u8 = "",
    /// `keepAsking`'s line is cut to fit; the camera's is not.
    cut: bool = false,
    shadow_alpha: f32 = 0.12,
    right: f32 = 10,
    yes: []const u8 = "",
    yes_key: []const u8 = "",
    /// The plain answers after it, each in ink or muted.
    rest: [2]?Plain = .{ null, null },

    pub const Plain = struct { label: []const u8, ink: bool };

    /// Kept after its question is gone, `said` owned on gpa; the labels
    /// and keys are constants.
    fn keep(q: *Question, gpa: std.mem.Allocator, now: Question) void {
        if (std.mem.eql(u8, q.said, now.said) and std.mem.eql(u8, q.yes, now.yes)) return;
        const said = gpa.dupe(u8, now.said) catch return;
        q.forget(gpa);
        q.* = now;
        q.said = said;
    }

    pub fn forget(q: *Question, gpa: std.mem.Allocator) void {
        if (q.said.len > 0) gpa.free(q.said);
        q.* = .{};
    }
};

/// The bars kept for leaving (`Browser.bars`).
pub const State = struct {
    ask: Question = .{},
    keep: Question = .{},

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.ask.forget(gpa);
        s.keep.forget(gpa);
    }
};

/// Draws `q`; live, which answer was pressed (0 the one on ink), else a
/// picture that takes no clicks.
fn question(c: *ui.Context, p: *const Palette, q: Question, t: f32, live: bool) ?usize {
    var s = capsule(p, q.shadow_alpha, 20, 6);
    s.gap = 12;
    s.padding = .{ .left = 16, .right = q.right, .top = 9, .bottom = 9 };
    const r = arriving(t);
    s.offset = r.offset;
    s.opacity = r.opacity;
    s.scale = r.scale;
    s.group = r.group;
    const i = c.open(s, q.key);
    defer c.end();
    if (live) _ = c.interact(i, .{});
    if (q.icon) |icon| ui.icon(c, icon, .{ .size = 11, .weight = .medium, .color = p.muted });
    ui.text(c, q.said, .{ .size = 12.5, .color = p.ink, .truncate = q.cut });
    const yes = c.open(.{ .padding = .xy(11, 5), .radius = controls.capsule, .background = p.ink, .control = true }, q.yes_key);
    const pressed = live and c.interact(yes, .{}).clicked;
    if (live) c.addA11y(yes, .button, q.yes, "", false, true);
    ui.text(c, q.yes, .{ .size = 12, .color = p.ground });
    c.end();
    var answer: ?usize = if (pressed) 0 else null;
    for (q.rest, 1..) |maybe, n| if (maybe) |o| {
        if (plain(c, o.label, if (o.ink) p.ink else p.muted, live) and answer == null) answer = n;
    };
    return answer;
}

fn arriving(t: f32) ui.Style {
    const a = std.math.clamp(t, 0, 1);
    return .{ .offset = .{ .y = (1 - t) * rise }, .opacity = a, .scale = 0.9 + 0.1 * a, .group = true };
}

fn capsule(p: *const Palette, shadow_alpha: f32, radius: f32, y: f32) ui.Style {
    var s: ui.Style = .{ .direction = .row, .align_items = .center, .radius = controls.capsule, .background = p.ground, .border = p.hairline };
    s.shadow = card.swiftShadow(shadow_alpha, radius, y);
    s.shadow.?.knockout = true;
    return s;
}

/// The announcement; with a file, "Show in Finder" beside it and the
/// line shows the file when pressed.
fn announcement(b: *Browser, c: *ui.Context, p: *const Palette, text: []const u8, t: f32) void {
    var s = capsule(p, 0.10, 18, 6);
    s.gap = 8;
    s.padding = .xy(15, 9);
    const a = arriving(t);
    s.offset = a.offset;
    s.opacity = a.opacity;
    s.scale = a.scale;
    s.group = a.group;
    s.control = b.announced_file != null;
    const i = c.open(s, "kea.announcement");
    defer c.end();
    const it = c.interact(i, .{});
    ui.text(c, text, .{ .size = 12, .color = p.ink });
    if (b.announced_file) |file| {
        ui.text(c, "Show in Finder", .{ .size = 12, .color = p.muted });
        if (it.clicked) keep_ops.reveal(file);
    }
}

/// `captureAsking`: the site, in its own words, and the answers.
fn captureAsking(b: *Browser, c: *ui.Context, p: *const Palette, asking: dialogs.Asking, t: f32) void {
    const a = asking.ask;
    const wants = a.message;
    const eql = std.mem.eql;
    // Read before any answer: answering frees the question.
    const once = asking.once();
    const keeps = asking.keeps();
    const q: Question = .{
        .key = "kea.capture-ask",
        .icon = if (eql(u8, wants, "location")) "location" else if (eql(u8, wants, "microphone")) "mic" else if (eql(u8, wants, "notifications")) "bell" else "video",
        .said = if (eql(u8, wants, "location"))
            c.print("{s} wants to know your location", .{a.host})
        else if (eql(u8, wants, "notifications"))
            c.print("{s} wants to send you notifications", .{a.host})
        else
            c.print("{s} wants to use your {s}", .{ a.host, wants }),
        .yes = if (once) "Allow once" else "Allow",
        .yes_key = "kea.capture-allow",
        .rest = .{ if (once and keeps) .{ .label = "Always allow", .ink = true } else null, .{ .label = "Don't allow", .ink = false } },
    };
    b.bars.ask.keep(b.gpa, q);
    const answer = question(c, p, q, t, true) orelse return;
    switch (answer) {
        0 => dialogs.answerBar(b, true, !once),
        1 => dialogs.answerBar(b, true, true),
        else => dialogs.answerBar(b, false, true),
    }
}

/// `keepAsking`: offered once, answered once. The password is never shown
/// back to you.
fn keepAsking(b: *Browser, c: *ui.Context, p: *const Palette, offer: @import("../passwords/forms.zig").Offer, t: f32) void {
    const login = offer.login;
    const q: Question = .{
        .key = "kea.keep-asking",
        .said = if (offer.changed)
            c.print("Update the password for {s} on {s}?", .{ login.user, login.host })
        else if (login.user.len == 0)
            c.print("Save this password for {s}?", .{login.host})
        else
            c.print("Save the password for {s} on {s}?", .{ login.user, login.host }),
        .cut = true,
        .right = 12,
        .yes = if (offer.changed) "Update" else "Save",
        .yes_key = "kea.keep-save",
        .rest = .{ .{ .label = "Not now", .ink = false }, if (!offer.changed) .{ .label = "Never here", .ink = false } else null },
    };
    b.bars.keep.keep(b.gpa, q);
    // Answered last: each answer frees the offer drawn above.
    const keeping = @import("../passwords/browser_passwords.zig");
    switch (question(c, p, q, t, true) orelse return) {
        0 => keeping.keepOffer(b),
        1 => keeping.dropOffer(b),
        else => keeping.neverOffer(b),
    }
}

fn knockout(s: ui.Shadow) ui.Shadow {
    var k = s;
    k.knockout = true;
    return k;
}

/// A plain text button; true when pressed (live).
fn plain(c: *ui.Context, label: []const u8, color: ui.Color, live: bool) bool {
    const i = c.open(.{ .control = true }, null);
    defer c.end();
    ui.text(c, label, .{ .size = 12, .color = color });
    if (!live) return false;
    c.addA11y(i, .button, label, "", false, true);
    return c.interact(i, .{}).clicked;
}

/// `hint`: a dark pill that says how a mode works.
fn hint(c: *ui.Context, p: *const Palette, text: []const u8, t: f32) void {
    const a = arriving(t);
    _ = c.open(.{
        .padding = .xy(15, 9),
        .radius = controls.capsule,
        .background = p.ink.alpha(0.92),
        .shadow = knockout(card.swiftShadow(0.18, 18, 6)),
        .offset = a.offset,
        .opacity = a.opacity,
        .scale = a.scale,
        .group = a.group,
    }, "kea.hint");
    defer c.end();
    ui.text(c, text, .{ .size = 11.5, .color = p.ground.alpha(0.92) });
}
