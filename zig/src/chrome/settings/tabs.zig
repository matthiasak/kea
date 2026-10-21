//! Settings › Tabs (Settings.swift:395-473): where the tabs go and how they
//! behave, and — with the tabs across the top — where back, forward and
//! reload sit. The column, the fold and the lights follow the prefs on
//! their next frame (fold.zig's `seen`, room.zig).
const ui = @import("nanoui").ui;
const Browser = @import("../../model/browser.zig").Browser;
const app_name = @import("../../app/kea.zig").app_name;
const Palette = @import("../../design/palette.zig").Palette;
const controls = @import("../controls.zig");
const motion = @import("../../design/motion.zig");
const disclose = @import("../disclose.zig");
const plate = @import("../controls_plate.zig");
const frame = @import("frame.zig");

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    tabs(b, c, p);
    if (disclose.begin(c, 0x6b65_612e_7462_7330, !b.prefs.sidebar, motion.settle)) {
        defer disclose.end(c);
        toolbar(b, c, p);
    }
}

/// With the sidebar they are already beside the window's buttons: nothing to move.
fn toolbar(b: *Browser, c: *ui.Context, p: *const Palette) void {
    plate.cardBox(c, p);
    defer ui.end(c);
    _ = frame.prefLine(b, c, p, "navigation_left", "Back, forward and reload on the left", "Beside the window's buttons, before the tabs");
}

fn tabs(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const prefs = b.prefs;
    const side = @tagName(prefs.side_position);
    plate.cardBox(c, p);
    defer ui.end(c);
    if (frame.prefLine(b, c, p, "sidebar", "Tabs in a sidebar", c.print("Down the {s} instead of across the top. Pull its edge to make it wider; double-click the edge to reset.", .{side})))
        for (b.kea.browsers.items) |w| w.syncStageHost();
    if (disclose.begin(c, 0x6b65_612e_7462_7331, prefs.sidebar, motion.settle)) {
        defer disclose.end(c);
        frame.rule(c, p);
        plate.line(c, p, "Sidebar position", c.print("Tabs down the {s} edge of the window", .{side}));
        var at: usize = @intFromEnum(prefs.side_position);
        if (controls.segmented(c, p, &.{ "Left", "Right" }, &at, false)) prefs.set("side_position", @enumFromInt(at));
        ui.end(c);
        frame.rule(c, p);
        _ = frame.prefLine(b, c, p, "side_hides", "Hide the sidebar until the pointer reaches the edge", c.print("The page takes the whole window; push against its {s} edge for the tabs. ⌘S keeps them out.", .{side}));
    }
    frame.rule(c, p);
    plate.line(c, p, "Tabs show", "Beside the title, and on a pinned square");
    var glyph: usize = @intFromEnum(prefs.glyph);
    if (controls.segmented(c, p, &.{ "Letters", "Site icons" }, &glyph, false)) prefs.set("glyph", @enumFromInt(glyph));
    ui.end(c);
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "bookmarks_bar", "Show the bookmarks bar", "Your bookmarks in a row above the page, folders opening as menus. It folds away with the tabs");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "shows_reading", "Show how far you've read", "The tab you're on fills with grey as you scroll down the page");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "sleeps_tabs", "Sleep tabs you aren't using", "After a while unseen they come back where you left them. Pinned tabs stay awake until memory runs critically short; sound, calls and anything typed always do.");
    if (disclose.begin(c, 0x6b65_612e_7462_7333, prefs.sleeps_tabs, motion.settle)) {
        defer disclose.end(c);
        frame.rule(c, p);
        plate.line(c, p, "Sleep after", "How long an unseen tab waits before sleeping");
        const mins = [_]f64{ 5, 10, 30, 60 };
        var idx: usize = for (mins, 0..) |m, i| {
            if (@abs(prefs.sleep_minutes - m) < 0.5) break i;
        } else 1;
        if (controls.segmented(c, p, &.{ "5 min", "10 min", "30 min", "1 hour" }, &idx, false)) prefs.set("sleep_minutes", mins[idx]);
        ui.end(c);
    }
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "lazy_tabs", "Load background tabs when you go to them", "A link opened behind the page, with ⌘-click or the middle button, or a batch of links from another app, waits until you go to its tab. ⇧⌘-click still takes you there at once.");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "searches_sites", "Search a site from the address field", "Type the start of a site's name, like red or yout, then Tab, and what you type next searches that site. Sites you visit that offer a search join the list.");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "starts_fresh", "Start with a fresh window", "Each time " ++ app_name ++ " opens, your pinned tabs are there and last time's other tabs aren't.");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "uses_spaces", "Spaces", "Separate sets of tabs, signed in where the others are or starting afresh, switched with ⌃1–⌃9, two fingers sideways over the column, or the space's icon. Mission Control's own ⌃1–⌃9, if you turned them on, take those keys first.");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "uses_tab_groups", "Tab groups", "Named sections in the sidebar. Right-click a tab to start a group; click its heading to hide or show its tabs.");
    if (disclose.begin(c, 0x6b65_612e_7462_7332, prefs.sidebar, motion.settle)) {
        defer disclose.end(c);
        frame.rule(c, p);
        _ = frame.prefLine(b, c, p, "lists_pins", "Pinned rows", "As in Arc: pins as squares for the sites you live in, pins as rows under them for pages you keep, and a line over the rest with Clear. Right-click a tab to pin it as a row.");
    }
    frame.rule(c, p);
    if (frame.prefLine(b, c, p, "split_view", "Split View", "Show two tabs side by side. Drag a tab onto a page to pair them."))
        for (b.kea.browsers.items) |w| w.splitViewChanged(prefs.split_view);
}
