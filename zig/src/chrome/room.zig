//! What the window's chrome takes from the page (`ContentView`,
//! App.swift:528-610 and 960-971): the column and the strip, the card's
//! gaps, the bookmarks bar, the side panels' widths, and the room the page
//! is laid out to leave, which follows the chrome without animating.
const std = @import("std");
const ui = @import("nanoui").ui;
const metrics = @import("../design/metrics.zig");

/// `BookmarksBar.height`.
pub const bar_height: f32 = 30;

/// What the window shows, read from prefs and the browser each frame.
pub const Room = struct {
    sidebar_pref: bool,
    side_right: bool,
    side_width: f32,
    /// The column folded away (Fold.swift).
    folded: bool = false,
    /// A page has the screen (`fullscreenTab != nil`).
    fullscreen: bool = false,
    bar_pref: bool,
    has_bookmarks: bool,
    /// The panels asked for, popped into windows of their own, or let out over the page.
    marks_asked: bool = false,
    marks_popped: bool = false,
    marks_expanded: bool = false,
    chat_asked: bool = false,
    chat_popped: bool = false,
    chat_expanded: bool = false,
    chat_width_pref: f32 = metrics.chat,
    marks_width_pref: f32 = metrics.side,
    /// 0 before the window is measured.
    window_width: f32 = 0,

    /// The page as a card on the window's ground.
    pub fn cards(r: Room) bool {
        return r.sidebar_pref and !r.fullscreen;
    }

    /// The tabs down the side, and not folded away.
    pub fn sidebar(r: Room) bool {
        return r.sidebar_pref and !r.folded and !r.fullscreen;
    }

    pub fn sideOnRight(r: Room) bool {
        return r.sidebar_pref and r.side_right;
    }

    /// The column has its own corner for the lights; the strip needs a band.
    pub fn band(r: Room) f32 {
        if (r.fullscreen) return 0;
        return if (r.sidebar_pref or r.folded) 0 else metrics.strip;
    }

    /// The card's gap on the side away from the column, and along the bottom.
    pub fn farGap(r: Room) f32 {
        return if (r.cards()) metrics.card_gap else 0;
    }

    pub fn barShown(r: Room) bool {
        return r.bar_pref and r.has_bookmarks and !r.folded and !r.fullscreen;
    }

    /// What the column and the strip take from the page.
    pub fn chrome(r: Room) ui.Size {
        const bar: f32 = if (r.barShown()) bar_height else 0;
        if (r.cards()) return .{
            .w = if (r.sidebar()) r.side_width else metrics.card_gap,
            .h = if (r.barShown()) bar else metrics.card_gap,
        };
        return .{ .w = if (r.sidebar()) r.side_width else 0, .h = r.band() + bar };
    }

    pub fn chatColumn(r: Room) bool {
        return r.chat_asked and !r.fullscreen;
    }

    pub fn marksColumn(r: Room) bool {
        return r.marks_asked and !r.fullscreen;
    }

    /// In its column: open, not in a window of its own, not let out over the page.
    pub fn chatShown(r: Room) bool {
        return r.chatColumn() and !r.chat_popped and !r.chat_expanded;
    }

    pub fn marksShown(r: Room) bool {
        return r.marksColumn() and !r.marks_popped and !r.marks_expanded;
    }

    /// What the side panels may take: the window less the column and the narrowest page.
    pub fn panelRoom(r: Room) f32 {
        if (r.window_width == 0) return std.math.inf(f32);
        return @max(0, r.window_width - r.chrome().w - metrics.page_min);
    }

    pub fn chatWidth(r: Room) f32 {
        return @min(r.chat_width_pref, @max(metrics.chat_min, r.panelRoom()));
    }

    pub fn marksWidth(r: Room) f32 {
        const chat: f32 = if (r.chatShown()) r.chatWidth() else 0;
        return @min(r.marks_width_pref, @max(metrics.side_min, r.panelRoom() - chat));
    }
};

/// The room the page is laid out to leave (`room`, `make(room:after:)`):
/// chrome going away gives it at once; chrome arriving slides over the
/// page at its old size, which gives the room up 0.42 s later.
pub const State = struct {
    room: ?ui.Size = null,
    chrome: ui.Size = .{},
    /// When the arriving chrome's room is taken (`c.time`).
    due: ?f64 = null,
    /// Bumped when the chrome changes without coming or going (a column
    /// dragged wider): the slide's spring starts over at its target.
    still: u32 = 0,
    /// A page has the screen, as of the last frame, and until when the
    /// chrome is swapping for it (`.easeOut(duration: 0.12)`); bumped at
    /// each swap, so what comes and goes starts again where it rests.
    immersed: bool = false,
    swap_until: f64 = 0,
    swaps: u32 = 0,
    /// Where the bookmarks bar last stood, for its leaving fade.
    bar: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, cards: bool = false } = .{},

    pub const give_up: f64 = 0.42;
    pub const swap: f64 = 0.12;

    /// Whether the chrome is swapping for a page taking the screen or
    /// giving it back; a change starts the glide over at its target.
    pub fn immersion(s: *State, on: bool, time: f64) bool {
        if (on != s.immersed) {
            s.immersed = on;
            s.swap_until = time + swap;
            s.still +%= 1;
            s.swaps +%= 1;
        }
        return time < s.swap_until;
    }

    /// This frame's room for `chrome`, at `time`.
    pub fn roomed(s: *State, chrome: ui.Size, time: f64, reduced: bool) ui.Size {
        if (s.room == null) {
            s.room = chrome;
            s.chrome = chrome;
        } else if (chrome.w != s.chrome.w or chrome.h != s.chrome.h) {
            s.make(chrome, s.chrome, time, reduced);
            s.chrome = chrome;
        }
        if (s.due) |d| if (time >= d) {
            s.room = s.chrome;
            s.due = null;
        };
        return s.room.?;
    }

    fn make(s: *State, new: ui.Size, old: ui.Size, time: f64, reduced: bool) void {
        const floor = metrics.card_gap;
        const arriving = [2]bool{ old.w <= floor and new.w > floor, old.h <= floor and new.h > floor };
        const leaving = [2]bool{ old.w > floor and new.w <= floor, old.h > floor and new.h <= floor };
        var at = s.room.?;
        if (!arriving[0]) at.w = new.w;
        if (!arriving[1]) at.h = new.h;
        s.room = if (reduced) new else at;
        s.due = if (!reduced and (arriving[0] or arriving[1])) time + give_up else null;
        if (!(arriving[0] or arriving[1] or leaving[0] or leaving[1])) s.still +%= 1;
    }
};

test "chrome follows App.swift" {
    const t = std.testing;
    const strip: Room = .{ .sidebar_pref = false, .side_right = false, .side_width = 232, .bar_pref = false, .has_bookmarks = false };
    try t.expectEqual(ui.Size{ .w = 0, .h = 52 }, strip.chrome());
    var bar = strip;
    bar.bar_pref = true;
    bar.has_bookmarks = true;
    try t.expectEqual(ui.Size{ .w = 0, .h = 82 }, bar.chrome());
    var side = strip;
    side.sidebar_pref = true;
    try t.expectEqual(ui.Size{ .w = 232, .h = 8 }, side.chrome());
    try t.expectEqual(@as(f32, 8), side.farGap());
    side.folded = true;
    try t.expectEqual(ui.Size{ .w = 8, .h = 8 }, side.chrome());
    // 1440 wide, column 232: 888 for the panels, the page keeps 320.
    side.folded = false;
    side.window_width = 1440;
    side.marks_asked = true;
    side.marks_width_pref = 440;
    try t.expectEqual(@as(f32, 440), side.marksWidth());
    side.window_width = 700;
    try t.expectEqual(@as(f32, 176), side.marksWidth());
}

test "room arriving waits 0.42 s, leaving is at once" {
    const t = std.testing;
    var s: State = .{};
    _ = s.roomed(.{ .w = 0, .h = 52 }, 0, false);
    // The column arrives: the page keeps its width until the slide is over.
    try t.expectEqual(ui.Size{ .w = 0, .h = 8 }, s.roomed(.{ .w = 232, .h = 8 }, 1, false));
    try t.expectEqual(ui.Size{ .w = 0, .h = 8 }, s.roomed(.{ .w = 232, .h = 8 }, 1.4, false));
    try t.expectEqual(ui.Size{ .w = 232, .h = 8 }, s.roomed(.{ .w = 232, .h = 8 }, 1.43, false));
    // Dragged wider: followed as it goes.
    try t.expectEqual(ui.Size{ .w = 250, .h = 8 }, s.roomed(.{ .w = 250, .h = 8 }, 2, false));
    // The column leaves at once; the strip arriving slides over the page first.
    try t.expectEqual(ui.Size{ .w = 0, .h = 8 }, s.roomed(.{ .w = 0, .h = 52 }, 3, false));
    try t.expectEqual(ui.Size{ .w = 0, .h = 52 }, s.roomed(.{ .w = 0, .h = 52 }, 3.43, false));
    // Reduce Motion: arriving is at once too.
    try t.expectEqual(ui.Size{ .w = 232, .h = 8 }, s.roomed(.{ .w = 232, .h = 8 }, 4, true));
}
