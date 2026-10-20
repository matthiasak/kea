//! The first time (`WelcomePanel`, Welcome.swift): four short pages over
//! the whole window — what this is, what to bring over, how to hold it, and
//! whether links from other apps come here — each sliding in 40 points and
//! fading under `Motion.glide`, at most 520 wide, every one skippable.
//! Shown until `welcomed`; again from the menu (`welcoming`).
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Kea = @import("../app/kea.zig").Kea;
const app_name = @import("../app/kea.zig").app_name;
const Uuid = @import("../data/json.zig").Uuid;
const Palette = @import("../design/palette.zig").Palette;
const motion = @import("../design/motion.zig");
const links = @import("../app/links.zig");
const controls = @import("controls.zig");
const presence = @import("presence.zig");
const kea_flight = @import("kea_flight.zig");
const ring = @import("ring.zig");
const importing = @import("../import/bring.zig");

pub const State = struct {
    page: u8 = 0,
    /// The last move was on, not back: what comes in comes from the right.
    forward: bool = true,
    /// `Links.isDefault`, asked as the panel first shows.
    is_default: ?bool = null,
    asked: bool = false,
    /// Drawn last frame: a panel shown again begins at its first page.
    shown: bool = false,
};

const pages = 4;
const panel_id: u64 = std.hash.Wyhash.hash(0, "kea.welcome");

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.welcome;
    if (b.welcoming and !s.shown) {
        s.* = .{};
        // What is on this Mac is looked for again.
        importing.closeWelcome(b);
    }
    s.shown = b.welcoming;
    // There as the window opens (no fade in); out under `Motion.settle`.
    const t = presence.presenceFrom(c, panel_id, if (b.welcoming) 1 else 0, b.welcoming, motion.settle, null) orelse return;
    const root = c.open(.{ .absolute = true, .width = .fill, .height = .fill, .padding = .all(40), .align_items = .center, .background = p.ground, .opacity = std.math.clamp(t, 0, 1) }, "kea.welcome");
    defer c.end();
    // Leaving, it is only a picture: the window under it has the pointer.
    if (b.welcoming) {
        _ = c.interact(root, .{});
        c.cursor = .arrow;
    }
    ui.spacer(c);
    const holder = c.open(.{ .width = .fill, .max_width = 520 }, null);
    const room = c.rects.get(c.node(holder).id);
    for (0..pages) |n| {
        const i: u8 = @intCast(n);
        const at = presence.presence(c, panel_id +% 1 +% n, i == s.page, motion.glide, null) orelse continue;
        // In from the side it moves toward, out to the other.
        const from: f32 = if (s.forward) 40 else -40;
        const x = if (i == s.page) (1 - at) * from else (1 - at) * -from;
        const page = c.open(.{ .width = .fill, .absolute = i != s.page, .offset = .{ .x = x }, .opacity = std.math.clamp(at, 0, 1) }, c.print("welcome.{d}", .{n}));
        // A page leaving stands centred where the pages stand, as in a ZStack.
        if (i != s.page) if (room) |r| if (c.rects.get(c.node(page).id)) |own| {
            c.node(page).style.offset.y = (r.h - own.h) / 2;
        };
        switch (i) {
            0 => welcome(c, p),
            1 => bring(b, c, p),
            2 => hold(b, c, p),
            else => linksPage(b, c, p),
        }
        c.end();
    }
    c.end();
    ui.spacer(c);
    foot(b, c, p);
}

// MARK: the pages

/// Lines of `str` wrapped at `width`, each centred (`multilineTextAlignment(.center)`).
fn centred(c: *ui.Context, str: []const u8, style: ui.TextStyle, width: f32, spacing: f32) void {
    const wrapped = c.text.wrap(str, style, width);
    const lines = c.alloc().dupe(@TypeOf(wrapped[0]), wrapped) catch return;
    ui.column(c, .{ .gap = spacing, .align_items = .center, .max_width = width });
    for (lines) |l| ui.text(c, str[l.start..l.end], style);
    ui.end(c);
}

fn welcome(c: *ui.Context, p: *const Palette) void {
    ui.column(c, .{ .gap = 22, .width = .fill, .align_items = .center });
    defer ui.end(c);
    if (!kea_flight.view(c, 320, 180, 14)) kea_flight.appIcon(c, 72);
    ui.column(c, .{ .gap = 10, .align_items = .center });
    ui.text(c, app_name, .{ .size = 34, .weight = .medium, .color = p.ink });
    centred(c, "A small, cheeky browser with nothing in the way. Named after New Zealand's alpine parrot: curious, quick, and hard to keep out of anything.", .{ .size = 14.5, .color = p.muted }, 400, 3);
    ui.end(c);
}

fn heading(c: *ui.Context, p: *const Palette, title: []const u8, line: []const u8) void {
    ui.column(c, .{ .gap = 8, .width = .fill });
    ui.text(c, title, .{ .size = 26, .weight = .medium, .color = p.ink });
    ui.text(c, line, .{ .size = 14, .color = p.muted, .wrap = true, .leading = 1.12 });
    ui.end(c);
}

fn bring(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.column(c, .{ .gap = 22, .width = .fill });
    defer ui.end(c);
    heading(c, p, "Bring things over.", "Passwords go into your keychain, bookmarks into the menu, and history means the address field already knows where you go. Nothing in the other browser changes.");
    if (importing.welcomeSession(b)) |s| found(c, p, s);
    // Safari, a browser on another Mac, one this can't read: what it
    // exported, bookmarks, passwords or Safari's own ZIP.
    if (controls.pill(c, p, "From a file another browser exported…", .{}).clicked) b.importFile();
}

/// The browsers found, what to bring of the chosen one, and Bring them in.
fn found(c: *ui.Context, p: *const Palette, s: *importing.Session) void {
    if (s.found.len == 0) {
        ui.column(c, .{ .width = .fill });
        if (s.unreadable.len == 0) ui.text(c, "No other browser found on this Mac — nothing to bring.", .{ .size = 13, .color = p.muted, .wrap = true });
        for (s.unreadable) |l| ui.text(c, l, .{ .size = 13, .color = p.muted, .wrap = true });
        ui.end(c);
        return;
    }
    ui.column(c, .{ .gap = 14, .width = .fill });
    if (s.found.len > 1) {
        const names = c.alloc().alloc([]const u8, s.found.len) catch return ui.end(c);
        for (names, s.found) |*n, src| n.* = src.name();
        _ = controls.segmented(c, p, names, &s.choice, false);
    } else ui.text(c, c.print("From {s}", .{s.found[0].name()}), .{ .size = 13, .color = p.muted });
    choice(c, p, "Passwords", "macOS will ask once for that browser's keychain key", &s.wants_passwords);
    choice(c, p, "Bookmarks", "Folders and all, behind the bookmark button", &s.wants_bookmarks);
    choice(c, p, "History", "The last few thousand places, for finishing addresses", &s.wants_history);
    ui.end(c);
    ui.row(c, .{ .gap = 12, .align_items = .center });
    defer ui.end(c);
    const enabled = !s.bringing and s.welcome_said == null and (s.wants_passwords or s.wants_history or s.wants_bookmarks);
    ui.column(c, .{ .opacity = if (enabled) 1 else 0.5 });
    if (big(c, p, if (s.bringing) "Bringing…" else "Bring them in", true) and enabled) importing.bringAll(s);
    ui.end(c);
    const bring_a = motion.quickTo(c, panel_id, 23, if (s.bringing) 1 else 0);
    if (bring_a > 0.001) {
        ui.column(c, .{ .opacity = bring_a });
        ring.ring(c, 10);
        ui.end(c);
    }
    const said_a = motion.quickTo(c, panel_id, 20, if (s.welcome_said != null) 1 else 0);
    if (s.welcome_said) |said| if (said_a > 0.001) {
        ui.column(c, .{ .opacity = said_a });
        ui.text(c, said, .{ .size = 13, .color = p.muted });
        ui.end(c);
    };
}

/// `Choice`: what it is, a word about it, and its switch.
fn choice(c: *ui.Context, p: *const Palette, title: []const u8, detail: []const u8, on: *bool) void {
    ui.row(c, .{ .gap = 12, .width = .fill, .align_items = .center });
    defer ui.end(c);
    ui.column(c, .{ .gap = 2, .grow = 1, .min_width = 0 });
    ui.text(c, title, .{ .size = 13.5, .color = p.ink });
    ui.text(c, detail, .{ .size = 11.5, .color = p.muted });
    ui.end(c);
    _ = controls.switch_(c, p, on, title);
}

fn hold(b: *Browser, c: *ui.Context, p: *const Palette) void {
    ui.column(c, .{ .gap = 22, .width = .fill });
    defer ui.end(c);
    heading(c, p, "Two ways to hold it.", "Titles across the top, or down the side. The grey slides to the tab you pick either way, and you can change your mind with ⇧⌘S.");
    ui.row(c, .{ .gap = 12, .width = .fill });
    if (way(c, p, "Tab strip", false, !b.prefs.sidebar)) setSidebar(b, false);
    if (way(c, p, "Sidebar", true, b.prefs.sidebar)) setSidebar(b, true);
    ui.end(c);
    ui.row(c, .{ .gap = 12, .align_items = .center });
    ui.text(c, "Tabs wear", .{ .size = 13, .color = p.muted });
    var glyph: usize = @intFromEnum(b.prefs.glyph);
    if (controls.segmented(c, p, &.{ "Letters", "Site icons" }, &glyph, false)) b.prefs.set("glyph", @enumFromInt(glyph));
    ui.end(c);
}

fn setSidebar(b: *Browser, on: bool) void {
    if (b.prefs.sidebar == on) return;
    b.prefs.set("sidebar", on);
    for (b.kea.browsers.items) |w| w.syncStageHost();
}

/// `Way`: one of the two, as a small drawing of the window.
fn way(c: *ui.Context, p: *const Palette, title: []const u8, sidebar: bool, chosen: bool) bool {
    const i = c.open(.{ .gap = 10, .grow = 1, .padding = .all(10), .radius = 14, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .radio_button, title, "", chosen, true);
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    const o = motion.settleTo(c, it.id, 1, if (chosen) 1 else 0);
    const s = &c.node(i).style;
    s.background = p.hover.alpha(h * (1 - o)).mix(p.wash, o);
    s.border = p.hairline.mix(p.ink.alpha(0.35), o);
    _ = c.open(.{ .direction = .row, .width = .fill, .height = .{ .px = 110 }, .radius = 8, .clip = true, .background = p.ground, .border = p.hairline }, null);
    if (sidebar) {
        ui.column(c, .{ .gap = 4, .padding = .all(8), .width = .{ .px = 62 } });
        dots(c, p, 4);
        for (0..4) |n| _ = c.leaf(.{ .width = .fill, .height = .{ .px = 8 }, .radius = 3, .background = if (n == 0) p.wash else p.hover }, .none, null);
        ui.end(c);
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = p.hairline }, .none, null);
    } else {
        ui.row(c, .{ .gap = 3, .padding = .all(8), .align_items = .center });
        ui.row(c, .{ .padding = .{ .right = 6 } });
        dots(c, p, 0);
        ui.end(c);
        for (0..4) |n| _ = c.leaf(.{ .width = .{ .px = 30 }, .height = .{ .px = 8 }, .radius = 3, .background = if (n == 0) p.wash else p.hover }, .none, null);
        ui.end(c);
    }
    c.end();
    ui.text(c, title, .{ .size = 13, .weight = if (chosen) .medium else .regular, .color = if (chosen) p.ink else p.muted });
    return it.clicked;
}

/// The window's three buttons, drawn small.
fn dots(c: *ui.Context, p: *const Palette, below: f32) void {
    ui.row(c, .{ .gap = 3, .padding = .{ .bottom = below } });
    for (0..3) |_| _ = c.leaf(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 2.5, .background = p.faint }, .none, null);
    ui.end(c);
}

const keys = [_][2][]const u8{
    .{ "⌘T", "A new tab. Type a place, or words to search." },
    .{ "⌘K", "Every open tab, by name." },
    .{ "⌘,", "Settings, including passwords." },
    .{ "⌃1", "Spaces: separate tabs and sign-ins. Turn them on in Settings › Tabs." },
    .{ "⌥⌘N", "Split a page in two; ⌃⌘← and ⌃⌘→ go from one page to the other. Turn Split View on in Settings › Tabs." },
    .{ "⌘O", "Links from other apps can open in a small window. Settings › General." },
    .{ "⌘,", "AI summaries and Ubi Chat — choose where it runs in Settings › AI." },
};

fn linksPage(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.welcome;
    ui.column(c, .{ .gap = 22, .width = .fill });
    defer ui.end(c);
    heading(c, p, "Links from other apps.", "A click in Mail, in Slack, in a PDF — macOS sends it to whichever browser is the default. It can be this one.");
    const is_default = s.is_default orelse blk: {
        const v = if (b.kea.opts.headless) false else links.isDefault();
        s.is_default = v;
        break :blk v;
    };
    ui.row(c, .{ .gap = 12, .align_items = .center });
    const def_a = motion.quickTo(c, panel_id, 21, if (is_default) 1 else 0);
    const ask_a = motion.quickTo(c, panel_id, 22, if (!is_default) 1 else 0);
    if (def_a > 0.001) {
        ui.row(c, .{ .gap = 8, .align_items = .center, .absolute = !is_default, .opacity = def_a });
        ui.icon(c, "checkmark", .{ .size = 11, .weight = .medium, .color = p.ink });
        ui.text(c, app_name ++ " is the default browser", .{ .size = 13, .color = p.ink });
        ui.end(c);
    }
    if (ask_a > 0.001) {
        ui.row(c, .{ .gap = 12, .align_items = .center, .absolute = is_default, .opacity = ask_a });
        if (big(c, p, "Make " ++ app_name ++ " the default", true) and !is_default) {
            s.asked = true;
            if (std.heap.c_allocator.create(Asked)) |a| {
                a.* = .{ .kea = b.kea, .window = b.record_id };
                links.becomeDefault(a, answered);
            } else |_| {}
        }
        if (s.asked) ui.text(c, "macOS asks in its own dialog", .{ .size = 13, .color = p.muted });
        ui.end(c);
    }
    ui.end(c);

    ui.column(c, .{ .gap = 8 });
    ui.row(c, .{ .padding = .{ .top = 6 } });
    ui.text(c, "A FEW THINGS WORTH KNOWING", .{ .size = 11, .weight = .medium, .color = p.muted, .tracking = 0.6 });
    ui.end(c);
    for (keys) |k| {
        ui.row(c, .{ .gap = 10, .align_items = .center });
        ui.row(c, .{ .min_width = 44, .justify = .center });
        ui.row(c, .{ .padding = .xy(7, 3), .radius = 6, .background = p.wash });
        ui.text(c, k[0], .{ .size = 12, .weight = .medium, .color = p.ink, .rounded = true });
        ui.end(c);
        ui.end(c);
        ui.text(c, k[1], .{ .size = 13, .color = p.muted });
        ui.end(c);
    }
    ui.end(c);
}

const Asked = struct { kea: *Kea, window: Uuid };

fn answered(ctx: ?*anyopaque, _: bool) void {
    const a: *Asked = @ptrCast(@alignCast(ctx.?));
    defer std.heap.c_allocator.destroy(a);
    for (a.kea.browsers.items) |b| if (b.record_id.eql(a.window)) {
        b.welcome.is_default = links.isDefault();
        b.redraw();
    };
}

// MARK: the bottom edge

fn foot(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.welcome;
    ui.row(c, .{ .gap = 14, .width = .fill, .max_width = 520, .align_items = .center });
    defer ui.end(c);
    ui.row(c, .{ .gap = 6 });
    for (0..pages) |n| {
        const lit = motion.quickTo(c, panel_id, @intCast(10 + n), if (n == s.page) 1 else 0);
        _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = p.faint.alpha(0.6).mix(p.sunset, lit) }, .none, null);
    }
    ui.end(c);
    ui.spacer(c);
    if (s.page > 0 and plain(c, p, "Back")) {
        s.forward = false;
        s.page -= 1;
    }
    if (s.page < pages - 1 and plain(c, p, "Skip")) return finish(b);
    const last = s.page == pages - 1;
    // The default action: Return presses it.
    if (big(c, p, if (last) "Start browsing" else "Continue", true) or (b.welcoming and c.shortcut(.{ .key = ui.Shortcut.enter }))) {
        if (last) return finish(b);
        s.forward = true;
        s.page += 1;
    }
}

fn finish(b: *Browser) void {
    b.prefs.set("welcomed", true);
    b.welcoming = false;
    b.redraw();
}

fn plain(c: *ui.Context, p: *const Palette, title: []const u8) bool {
    const i = c.open(.{ .control = true }, null);
    defer c.end();
    c.addA11y(i, .button, title, "", false, true);
    ui.text(c, title, .{ .size = 13, .color = p.muted });
    return c.interact(i, .{}).clicked;
}

/// `Big`: the welcome's own larger capsule.
fn big(c: *ui.Context, p: *const Palette, title: []const u8, filled: bool) bool {
    const i = c.open(.{ .padding = .xy(16, 9), .radius = controls.capsule, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, title, "", false, true);
    c.node(i).style.background = if (filled) p.sunset else if (it.hovered) p.hover else p.wash;
    ui.text(c, title, .{ .size = 13, .weight = .medium, .color = if (filled) p.ground else p.ink });
    return it.clicked;
}
