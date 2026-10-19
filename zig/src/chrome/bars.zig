//! Everything that rises from the bottom edge to say one thing (App.swift
//! `bars`): the announcement — a line that says one thing and leaves, and
//! shows a file just saved in the Finder — a page asking for the camera,
//! the microphone, where you are or to send notifications (`captureAsking`,
//! answering the decision WebKit is holding), and the hint while the
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

/// `move(edge: .bottom)`: how far below its place a bar starts and ends.
const rise: f32 = 60;

/// The veiling hint's words.
pub const veil_hint = "Click anything to hide it   ⌘Z undo   esc done";

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const now = ui.clock.now();
    const live = b.announcement != null and now < b.announced_until;
    if (live) c.frameIn(@floatCast(b.announced_until - now + 0.01));
    ui.column(c, .{ .absolute = true, .width = .fill, .height = .fill, .direction = .column, .justify = .end, .align_items = .center, .gap = 8, .padding = .{ .bottom = 30 } });
    defer ui.end(c);
    if (b.announcement) |text| {
        if (presence.presence(c, id_said, live, motion.settle, null)) |t| announcement(b, c, p, text, t) else b.hush();
    }
    if (b.asking) |asking| if (presence.presence(c, id_ask, true, motion.settle, null)) |t| captureAsking(b, c, p, asking, t);
    if (presence.presence(c, id_veil, b.veiling, motion.settle, null)) |t| hint(c, p, veil_hint, t);
}

fn arriving(t: f32) ui.Style {
    return .{ .offset = .{ .y = (1 - t) * rise }, .opacity = std.math.clamp(t, 0, 1) };
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
    var s = capsule(p, 0.12, 20, 6);
    s.gap = 12;
    s.padding = .{ .left = 16, .right = 10, .top = 9, .bottom = 9 };
    const r = arriving(t);
    s.offset = r.offset;
    s.opacity = r.opacity;
    const i = c.open(s, "kea.capture-ask");
    defer c.end();
    _ = c.interact(i, .{});
    const eql = std.mem.eql;
    const icon = if (eql(u8, wants, "location")) "location" else if (eql(u8, wants, "microphone")) "mic" else if (eql(u8, wants, "notifications")) "bell" else "video";
    ui.icon(c, icon, .{ .size = 11, .weight = .medium, .color = p.muted });
    const said = if (eql(u8, wants, "location"))
        c.print("{s} wants to know your location", .{a.host})
    else if (eql(u8, wants, "notifications"))
        c.print("{s} wants to send you notifications", .{a.host})
    else
        c.print("{s} wants to use your {s}", .{ a.host, wants });
    ui.text(c, said, .{ .size = 12.5, .color = p.ink });
    // Allow, on ink: the thing asked for.
    const allow = c.open(.{ .padding = .xy(11, 5), .radius = controls.capsule, .background = p.ink, .control = true }, "kea.capture-allow");
    const allow_it = c.interact(allow, .{});
    // Read before any answer: answering frees the question.
    const once = asking.once();
    const keeps = asking.keeps();
    const allow_label = if (once) "Allow once" else "Allow";
    c.addA11y(allow, .button, allow_label, "", false, true);
    ui.text(c, allow_label, .{ .size = 12, .color = p.ground });
    c.end();
    const always = once and keeps and plain(c, "Always allow", p.ink);
    const deny = plain(c, "Don't allow", p.muted);
    if (allow_it.clicked) dialogs.answerBar(b, true, !once) else if (always) dialogs.answerBar(b, true, true) else if (deny) dialogs.answerBar(b, false, true);
}

fn knockout(s: ui.Shadow) ui.Shadow {
    var k = s;
    k.knockout = true;
    return k;
}

/// A plain text button; true when pressed.
fn plain(c: *ui.Context, label: []const u8, color: ui.Color) bool {
    const i = c.open(.{ .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, label, "", false, true);
    ui.text(c, label, .{ .size = 12, .color = color });
    return it.clicked;
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
    }, "kea.hint");
    defer c.end();
    ui.text(c, text, .{ .size = 11.5, .color = p.ground.alpha(0.92) });
}
