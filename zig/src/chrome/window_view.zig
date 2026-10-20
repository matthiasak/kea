//! The window (`ContentView`, App.swift:404-776): the ground, one stage for
//! the page beside the column or under the strip, the bookmarks bar, and
//! what goes over them in Swift's order — Fold, bars, Peek, the field,
//! panels and sheets, the tab switcher, the import's progress — then the
//! one open overlay. Every hole box is left unpainted, its ancestors too:
//! the strip, column, bars and panels paint themselves beside the stage.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const palette = @import("../design/palette.zig");
const Palette = palette.Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");
const room_mod = @import("room.zig");
const Room = room_mod.Room;
const presence = @import("presence.zig");
const bars = @import("bars.zig");
const hidden_panel = @import("hidden_panel.zig");
const side_panels = @import("side_panels.zig");
const side_bar = @import("side_bar.zig");
const fold = @import("fold.zig");
const space_swipe = @import("space_swipe.zig");
const spaces_view = @import("spaces_view.zig");
const groups_view = @import("groups_view.zig");
const tab_bar = @import("tab_bar.zig");
const overlays = @import("overlays.zig");
const controls = @import("controls.zig");
const page_layers = @import("page_layers.zig");
const site_card = @import("site_card.zig");
const bookmark_door = @import("bookmarks/door.zig");
const split_stage = @import("split_stage.zig");
const omnibox = @import("omnibox.zig");
const peek = @import("peek.zig");
const tab_switcher_view = @import("tab_switcher_view.zig");
const sheet = @import("sheet.zig");
const slot_view = @import("../ext/slot_view.zig");
const welcome = @import("welcome.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

const slide_id: u64 = std.hash.Wyhash.hash(0, "kea.room.slide");
const strip_id: u64 = std.hash.Wyhash.hash(0, "kea.room.strip");
const bar_id: u64 = std.hash.Wyhash.hash(0, "kea.room.bar");

pub fn view(b: *Browser, c: *ui.Context) void {
    // Kea's controls keep the arrow, as AppKit's plain buttons do.
    c.hand_cursor = false;
    // An extension's popup window: the page and its site, as a small window shows one.
    if (b.ext.popup != null) return @import("../web/little.zig").popupView(b, c);
    const p = palette.get(c.theme.dark);
    // The strip and the column say where the window is dragged from.
    c.title_bar_height = 0;
    // The bookmarks manager's start and end; its keys are the key monitor's.
    @import("bookmarks/manager.zig").frame(b);
    // The address typed into a tab, done with: the next takes the keys again.
    if (b.editing_tab == null) b.tab_field.claimed = null;
    space_swipe.frame(b, c);
    groups_view.beginFrame(b);
    // The panels' own windows follow the prefs, before anything is laid out.
    @import("popped.zig").followBookmarks(b.kea);
    @import("../model/browser_chat.zig").followChatWindow(b);

    const r = room(b, c);
    applyGround(b, p, r);
    const chrome = r.chrome();
    const roomed = b.room.roomed(chrome, c.time, c.reduce_motion);
    if (b.room.due) |d| c.frameIn(@floatCast(@max(0, d - c.time)));
    // A page taking the screen or giving it back swaps the chrome on a
    // short ease-out (`fullscreenTab?.id`), else it slides on Motion.glide.
    const swapping = b.room.immersion(r.fullscreen, c.time);
    const still = b.room.still *% 2;
    const glided: ui.Size = .{ .w = motion.glideTo(c, slide_id, still, chrome.w), .h = motion.glideTo(c, slide_id, still + 1, chrome.h) };
    const swapped: ui.Size = .{ .w = swapTo(c, slide_id, 0, chrome.w), .h = swapTo(c, slide_id, 1, chrome.h) };
    const slide = if (swapping) swapped else glided;

    drawStageRow(b, c, p, r, roomed, slide);

    // The column, from the window's top: the lights sit in its own corner.
    // Placed by its own side, so a column leaving the right goes out on the right.
    const right = r.sideOnRight();
    if (r.sidebar() or slide.w > chrome.w + 0.5) {
        const on_right = b.prefs.side_position == .right;
        const x = if (on_right) c.size.w - slide.w else slide.w - b.prefs.side_width;
        side_bar.sideBar(b, c, p, r.cards(), x);
    }
    drawStrip(b, c, p, !b.prefs.sidebar and !r.folded and !r.fullscreen, swapping);
    drawBookmarksBar(b, c, p, r, swapping);
    // On the page, as Swift's `Page` overlay: under the fold, bars and sheets.
    @import("../passwords/accounts_view.zig").view(b, c, p);
    if (!r.fullscreen) fold.view(b, c, p);
    bars.view(b, c, p);
    // Over the page only: the column, the strip and the bookmarks bar stay uncovered.
    peek.view(b, c, p, .{ .x = if (right) 0 else chrome.w, .y = chrome.h, .w = c.size.w - chrome.w, .h = c.size.h - chrome.h });

    // Over everything, in App.swift's order. Fold, bars, Peek, panels and
    // sheets, the tab switcher and the import's card come with their phases.
    // The field is centred on the page, not on the window: the column of
    // tabs is not what it stands over.
    const lead: f32 = if (r.sidebar() and !right) b.prefs.side_width else 0;
    const trail: f32 = if (r.sidebar() and right) b.prefs.side_width else 0;
    // With Split View on, each page has its own, fitted (chrome/split_stage.zig).
    if (!b.prefs.split_view) omnibox.view(b, c, p, .{ .x = lead, .y = 0, .w = c.size.w - lead - trail, .h = c.size.h }, .{});
    site_card.follow(b);
    sheet.view(b, c, p);
    welcome.view(b, c, p);
    // No dimming for this one: the page stays in view while it offers to put things back.
    hidden_panel.view(b, c, p);
    tab_switcher_view.view(b, c, p);
    @import("../import/progress.zig").view(b, c, p);
    drawOverlay(b, c, p);
}

/// This frame's window, as ContentView reads it.
fn room(b: *Browser, c: *ui.Context) Room {
    const prefs = b.prefs;
    return .{
        .sidebar_pref = prefs.sidebar,
        .folded = b.folded,
        .fullscreen = fullscreenTab(b) != null,
        .side_right = prefs.side_position == .right,
        .side_width = prefs.side_width,
        .bar_pref = prefs.bookmarks_bar,
        .has_bookmarks = b.bookmarks.roots.len > 0,
        .marks_asked = prefs.bookmarks_sidebar,
        .marks_popped = prefs.marks_popped,
        .marks_expanded = b.expanded_panel == .bookmarks,
        .chat_asked = b.assisting != null,
        .chat_expanded = b.expanded_panel == .chat,
        .chat_popped = prefs.chat_popped,
        .chat_width_pref = prefs.chat_width,
        .marks_width_pref = prefs.marks_width,
        .window_width = c.size.w,
    };
}

/// `fullscreenTab`: either page of the pair on screen may have given
/// itself to WebKit's full screen window; else the page with the keys.
pub fn fullscreenTab(b: *Browser) ?*Tab {
    if (b.activeSplit()) |s| for (b.tabs.items) |t| if (s.contains(t.id) and t.immersed) return t;
    const a = b.activeTab() orelse return null;
    return if (a.immersed) a else null;
}

/// `.easeOut(duration: 0.12)`, the chrome's swap as a page takes the screen.
fn swapTo(c: *ui.Context, id: u64, salt: u32, target: f32) f32 {
    return ui.tween(c, id, 0x7377_6170 +% salt, target, @floatCast(@import("room.zig").State.swap), .ease_out);
}

/// Progress 0…1 of the strip or the bookmarks bar coming and going: on
/// Motion.glide, or the 0.12 s swap while a page takes the screen; null
/// once gone.
fn arrival(b: *Browser, c: *ui.Context, id: u64, shown: bool, swapping: bool) ?f32 {
    const target: f32 = if (shown) 1 else 0;
    const swapped = swapTo(c, id, 2, target);
    // Keyed by the room's swaps: after a swap it starts where it rests.
    const glided = presence.presenceFrom(c, id ^ b.room.swaps, target, shown, motion.glide, motion.glide);
    return if (swapping) (if (swapped > 0) swapped else null) else glided;
}

/// `TabBar`, coming and going with `.move(edge: .top)` and opacity.
fn drawStrip(b: *Browser, c: *ui.Context, p: *const Palette, shown: bool, swapping: bool) void {
    const t = arrival(b, c, strip_id, shown, swapping) orelse return;
    _ = c.open(.{
        .absolute = true,
        .width = .fill,
        .height = px(metrics.strip),
        .offset = .{ .y = -(1 - t) * metrics.strip },
        .opacity = std.math.clamp(t, 0, 1),
    }, "kea.strip.move");
    defer c.end();
    tab_bar.tabBar(b, c, p);
}

/// The window's ground (`ContentView.window_`'s first layer): black under
/// a page filling the screen, the card's ground beside the column, the
/// page's own otherwise. Given to the NSWindow only when it changes.
fn applyGround(b: *Browser, p: *const Palette, r: Room) void {
    const g = if (r.fullscreen) ui.Color.black else if (r.cards()) p.frame else p.ground;
    if (b.applied_ground) |a| if (std.meta.eql(a, g)) return;
    b.applied_ground = g;
    const w = b.window orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const color = objc.msg(objc.Object, objc.class("NSColor"), "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, g.r), @as(f64, g.g), @as(f64, g.b), @as(f64, g.a),
    });
    objc.msg(void, w.nswindow, "setBackgroundColor:", .{color});
}

/// The panels on their sides and the stage between them, inside the room
/// the chrome leaves, slid as the chrome slides.
fn drawStageRow(b: *Browser, c: *ui.Context, p: *const Palette, r: Room, roomed: ui.Size, slide: ui.Size) void {
    const right = r.sideOnRight();
    const far = r.farGap();
    const pad: ui.Edges = .{
        .left = if (right) far else roomed.w,
        .right = if (right) roomed.w else far,
        .top = roomed.h,
        .bottom = far,
    };
    ui.row(c, .{
        .absolute = true,
        .width = .fill,
        .height = .fill,
        .padding = pad,
        .offset = .{ .x = if (right) 0 else slide.w - roomed.w, .y = slide.h - roomed.h },
    });
    defer ui.end(c);
    side_panels.beside(b, c, p, r, true);
    // The stage's own size, from what is beside it, so the pages are laid
    // out in this frame for this window, never the last one's.
    const beside: f32 = (if (r.chatShown()) r.chatWidth() else 0) + (if (r.marksShown()) r.marksWidth() else 0);
    drawStage(b, c, p, r, .{ .w = @max(0, c.size.w - pad.left - pad.right - beside), .h = @max(0, c.size.h - pad.top - pad.bottom) });
    side_panels.beside(b, c, p, r, false);
}

/// The stage: one page, or a pair's two (chrome/split_stage.zig), each a
/// card in the card's mode; and the panel let out over it.
fn drawStage(b: *Browser, c: *ui.Context, p: *const Palette, r: Room, size: ui.Size) void {
    _ = c.open(.{ .grow = 1, .height = .fill }, "kea.stage");
    defer c.end();
    split_stage.view(b, c, p, r, size);
    side_panels.letOut(b, c, p, r);
}

/// `BookmarksBar`: under the strip, or beside the column's top on the
/// card's ground, no wider than the card; coming and going with opacity,
/// a leaving bar where it last stood.
fn drawBookmarksBar(b: *Browser, c: *ui.Context, p: *const Palette, r: Room, swapping: bool) void {
    const t = arrival(b, c, bar_id, r.barShown(), swapping) orelse return;
    const at = &b.room.bar;
    if (r.barShown()) {
        const right = r.sideOnRight();
        const lead = if (right) r.farGap() else r.chrome().w;
        const trail = if (right) r.chrome().w else r.farGap();
        at.* = .{ .x = lead, .y = r.band(), .w = c.size.w - lead - trail, .cards = r.cards() };
    }
    _ = c.open(.{ .absolute = true, .width = .fill, .height = .fill, .offset = .{ .y = (t - 1) * room_mod.bar_height }, .opacity = std.math.clamp(t, 0, 1) }, "kea.bar.fade");
    defer c.end();
    @import("bookmarks/bar.zig").view(b, c, p, at.x, at.y, at.w, at.cards);
}

/// The one overlay open over the window, last so it takes the clicks
/// over it (`chrome/overlays.zig`). What each shows comes with the phase
/// that opens it.
fn drawOverlay(b: *Browser, c: *ui.Context, p: *const Palette) void {
    if (b.overlay) |o| if (o == .site_card) return site_card.overlay(b, c, p);
    const marks = if (b.overlay) |o| o == .bookmarks_dropdown or o == .bookmark_card else false;
    const extensions = if (b.overlay) |o| o == .extension_menu else false;
    const place: overlays.Place = if (marks) bookmark_door.place(b) else if (extensions) slot_view.place(b) else .{};
    // `popoverGround(card:)`: the popover window's system shadow, as the site card's.
    const style: ui.Style = .{ .background = p.ground, .radius = 14, .border = p.hairline, .clip = true, .shadow = card.swiftShadow(0.22, 12, 6) };
    if (!overlays.begin(c, &b.overlay, b.overlay_anchor, style, place)) return;
    switch (b.overlay.?) {
        .space_icons => spaces_view.iconsPopover(b, c, p),
        .bookmarks_dropdown, .bookmark_card => bookmark_door.overlay(b, c, p),
        .extension_menu => slot_view.menu(b, c, p),
        else => {},
    }
    ui.end(c);
}
