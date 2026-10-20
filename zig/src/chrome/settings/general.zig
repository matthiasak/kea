//! Settings › General (Settings.swift:174-393): the default browser, Bring
//! things over, the engine, site shortcuts, appearance, zoom and the page
//! switches, in Swift's order and words. The bench switch isn't here
//! (Bench.swift isn't ported).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const MenuItem = nanoui.MenuItem;
const Browser = @import("../../model/browser.zig").Browser;
const Kea = @import("../../app/kea.zig").Kea;
const app_name = @import("../../app/kea.zig").app_name;
const Palette = @import("../../design/palette.zig").Palette;
const prefs_mod = @import("../../data/prefs.zig");
const Engine = prefs_mod.Engine;
const Look = prefs_mod.Look;
const Keyword = prefs_mod.Keyword;
const keywords = @import("../../data/keywords.zig");
const engine = @import("../../model/engine.zig");
const Uuid = @import("../../data/json.zig").Uuid;
const links = @import("../../app/links.zig");
const controls = @import("../controls.zig");
const plate = @import("../controls_plate.zig");
const tab_menu = @import("../tab_menu.zig");
const frame = @import("frame.zig");
const tab_scripts = @import("../../web/tab_scripts.zig");
const tab_state = @import("../../web/tab_state.zig");
const frame_rate = @import("../../web/frame_rate.zig");

/// A site shortcut being written, kept out of the prefs until it's saved.
const Draft = struct {
    word: ui.TextBuffer = .{},
    template: ui.TextBuffer = .{},
};

pub const State = struct {
    /// `Links.isDefault`, asked as the page first shows.
    is_default: ?bool = null,
    custom: ui.TextBuffer = .{},
    custom_shown: bool = false,
    draft: ?Draft = null,

    pub fn deinit(s: *State, _: std.mem.Allocator) void {
        s.custom.deinit();
        s.dropDraft();
    }

    fn dropDraft(s: *State) void {
        if (s.draft) |*d| {
            d.word.deinit();
            d.template.deinit();
        }
        s.draft = null;
    }
};

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.settings.general;
    const prefs = b.prefs;
    plate.cardBox(c, p);
    defer ui.end(c);

    const is_default = s.is_default orelse blk: {
        // Never asked of a headless test run's Mac.
        const v = if (b.kea.opts.headless) false else links.isDefault();
        s.is_default = v;
        break :blk v;
    };
    plate.line(c, p, "Open links from other apps", if (is_default) app_name ++ " is the default browser on this Mac" else "Mail, Slack and the rest still send links elsewhere");
    if (is_default) {
        ui.icon(c, "checkmark", .{ .size = 12, .weight = .medium, .frame = 24, .color = p.ink });
    } else if (controls.pill(c, p, "Make default", .{ .filled = true }).clicked) becomeDefault(b);
    ui.end(c);
    frame.rule(c, p);
    // Coming from another browser, now or any time later: the same sheet as
    // File › Bring Things Over… and the Welcome's.
    plate.line(c, p, "Bring things over", "Bookmarks, history, passwords and extensions from another browser on this Mac, or from a file it exported");
    if (controls.pill(c, p, "Bring Things Over…", .{}).clicked) @import("../sheet.zig").show(b, .bringing);
    ui.end(c);
    frame.rule(c, p);

    searchWith(b, c, p);
    frame.rule(c, p);
    siteShortcuts(b, c, p);
    frame.rule(c, p);

    plate.line(c, p, "Appearance", "Light, dark, or whatever the Mac is doing — pages follow it too");
    var look: usize = @intFromEnum(prefs.look);
    if (controls.segmented(c, p, &.{ "Light", "Dark", "System" }, &look, false)) prefs.set("look", @enumFromInt(look));
    ui.end(c);
    frame.rule(c, p);

    plate.line(c, p, "Page zoom", "Where every site starts. ⌘+ and ⌘− are still remembered for each site.");
    var zoom = prefs.page_zoom;
    if (controls.steps(c, p, &zooms, &zoom, 1, percent)) {
        prefs.set("page_zoom", zoom);
        zoomChanged(b.kea);
    }
    ui.end(c);
    frame.rule(c, p);

    _ = frame.prefLine(b, c, p, "autocorrect", "Correct spelling as you type", "macOS's autocorrect inside pages — the one that capitalises for you");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "peeks_links", "Peek at a link with a shift-click", "Its page opens in a panel over the one you're reading. Escape puts it away; the other button keeps it as a tab");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "little_links", "Open links from other apps in a small window", "To read and close, or keep with Open in " ++ app_name ++ " (⌘O)");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "command_bar", "Address bar commands", "A word like \"settings\" or \"new tab\", typed alone in the address field, goes there instead of searching for it");
    frame.rule(c, p);
    if (frame.prefLine(b, c, p, "shows_links", "Show where links go", "Point at a link and its address shows at the bottom of the page"))
        for (b.kea.browsers.items) |w| tab_scripts.showsLinksChanged(w);
    frame.rule(c, p);
    if (frame.prefLine(b, c, p, "auto_scroll", "Scroll with the middle button", "Click the wheel on a page, then move the mouse up or down to scroll, as on Windows. Click again to stop"))
        for (b.kea.browsers.items) |w| tab_scripts.autoScrollChanged(w);
    frame.rule(c, p);
    if (frame.switchLine(c, p, "Pages at 120 Hz", "Animations and scrolling in pages at up to 120 frames a second on a screen that can, instead of 60 as in Safari. Uses more battery. Open tabs follow when reloaded", prefs.fast_pages))
        frame_rate.setFast(b.kea, !prefs.fast_pages);
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "holds_history", "Hold a swipe to pick from history", "Swipe back or forward and keep your fingers down: the pages that way appear, and moving up or down picks one to go to");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "float_flicks", "Flick the floating video to a corner", "Two fingers on it send it to the corner or edge they point at, instead of pushing it along; a strong swipe at the side of the screen it is against tucks it in there, a sliver left to bring it back by. Dragging still puts it anywhere");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "waits_for_play", "Videos wait for a click", "Videos don't start by themselves, even without sound; they play when you press play. Tabs already open follow once closed and opened again, or after they've slept");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "floats_on_leave", "Float the video when you switch tabs", "A video playing on YouTube and the like comes out into its floating window when you go to another tab, and back when you return. ⇧⌘P still floats one by hand");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "floats_away", "Float the video when you switch apps", "A video playing on the site you're on comes out into its floating window as another app comes to the front, and goes back into its tab when you return");
    frame.rule(c, p);
    _ = frame.prefLine(b, c, p, "kea_facts", "Kea facts on new tabs", "One fact about the bird under the address field, a new one each day");
}

/// `Preferences.zooms`: every 5% from 50% to 300%.
const zooms = blk: {
    var out: [51]f64 = undefined;
    for (&out, 0..) |*z, i| z.* = @as(f64, @floatFromInt(50 + 5 * i)) / 100;
    break :blk out;
};

fn percent(c: *ui.Context, v: f64) []const u8 {
    return c.print("{d}%", .{@as(i64, @intFromFloat(@round(v * 100)))});
}

/// `prefs.$pageZoom`: every open page without a size of its own takes it.
fn zoomChanged(kea: *Kea) void {
    for (kea.browsers.items) |w| {
        const parked = w.parkedTabs(w.gpa) catch continue;
        defer w.gpa.free(parked);
        for ([_][]const *@import("../../web/tab.zig").Tab{ w.tabs.items, parked }) |list| for (list) |t| {
            if (t.web != null) tab_state.applyRememberedZoom(t);
        };
    }
}

// MARK: the default browser

const Asked = struct { kea: *Kea, window: Uuid };

fn becomeDefault(b: *Browser) void {
    const a = std.heap.c_allocator.create(Asked) catch return;
    a.* = .{ .kea = b.kea, .window = b.record_id };
    links.becomeDefault(a, answered);
}

fn answered(ctx: ?*anyopaque, worked: bool) void {
    const a: *Asked = @ptrCast(@alignCast(ctx.?));
    defer std.heap.c_allocator.destroy(a);
    for (a.kea.browsers.items) |b| if (b.record_id.eql(a.window)) {
        const now = links.isDefault();
        b.settings.general.is_default = now;
        b.announce(if (worked and now) "Links now open here" else "macOS didn't change it");
        b.redraw();
    };
}

// MARK: the engine

fn searchDetail(c: *ui.Context, b: *Browser) []const u8 {
    const prefs = b.prefs;
    if (prefs.engine != .custom) return "Where words that aren't an address go";
    if (!engine.accepts(prefs.custom_engine)) return "An http or https address with %s where the words go. Until then, Google";
    const name = prefs.engine.name(c.alloc(), prefs.custom_engine) catch return "";
    return c.print("Words go to {s}", .{name});
}

fn searchWith(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.settings.general;
    plate.line(c, p, "Search with", searchDetail(c, b));
    // The `.menu` picker: its title and the up-down chevrons; its menu on a press.
    const i = c.open(.{ .direction = .row, .gap = 6, .padding = .xy(8, 3), .radius = 6, .background = p.ground, .border = p.hairline, .align_items = .center, .control = true }, null);
    const it = c.interact(i, .{});
    c.addA11y(i, .menu_button, "Search with", b.prefs.engine.title(), false, true);
    if (it.hovered) c.node(i).style.background = p.hover;
    ui.text(c, b.prefs.engine.title(), .{ .size = 13, .color = p.ink });
    ui.icon(c, "chevron.up.chevron.down", .{ .size = 9, .weight = .semibold, .color = p.muted });
    c.end();
    if (it.clicked) if (it.rect) |r| tab_menu.later(b, .{ .x = r.x, .y = r.y + r.h + 4 }, 0, engines);
    ui.end(c);
    if (b.prefs.engine != .custom) {
        s.custom_shown = false;
        return;
    }
    if (!s.custom_shown) {
        s.custom.set(b.prefs.custom_engine);
        s.custom_shown = true;
    }
    ui.column(c, .{ .width = .fill, .padding = .{ .left = 14, .right = 14, .bottom = 11 } });
    ui.column(c, .{ .width = .fill, .padding = .xy(10, 7), .radius = 9, .background = p.wash });
    if (s.custom.text().len == 0)
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 10, .y = 7 } }, .{ .text = .{ .str = "https://example.com/search?q=%s", .style = .{ .size = 12.5 }, .color = p.muted.alpha(0.8) } }, null);
    if (ui.textField(c, &s.custom, .{ .bare = true, .size = 12.5, .width = .fill, .caret_color = p.ink, .selection_color = p.ink.alpha(0.12) }).changed)
        b.prefs.set("custom_engine", s.custom.text());
    ui.end(c);
    ui.end(c);
}

const Pick = struct {
    b: *Browser,
    engine: Engine,
    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        self.b.prefs.set("engine", self.engine);
        self.b.redraw();
    }
};

fn engines(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const MenuItem {
    const all = std.enums.values(Engine);
    const out = try arena.alloc(MenuItem, all.len);
    for (all, out) |e, *item| {
        const pick = try arena.create(Pick);
        pick.* = .{ .b = b, .engine = e };
        item.* = .{ .label = e.title(), .checked = b.prefs.engine == e, .click = .of(pick, Pick.fire) };
    }
    return out;
}

// MARK: site shortcuts

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Checked when it's saved, not as it's typed: null when it may be.
fn draftProblem(c: *ui.Context, b: *Browser, d: *const Draft) ?[]const u8 {
    return (keywords.problem(c.alloc(), d.word.text(), d.template.text(), b.prefs.keywords) catch return "") orelse null;
}

fn keywordDetail(c: *ui.Context, b: *Browser) []const u8 {
    const d = if (b.settings.general.draft) |*d| d else return "A word before your search goes straight to that site, whatever engine you've picked — \"yt cats\" to YouTube";
    if (d.word.text().len == 0 and d.template.text().len == 0) return "A word, then the site's search address with %s where the words go";
    if (draftProblem(c, b, d)) |problem| return problem;
    const k: Keyword = .{ .id = Uuid.first, .keyword = d.word.text(), .template = d.template.text() };
    return c.print("{s} will search {s}", .{ trim(d.word.text()), k.name(c.alloc()) catch "" });
}

fn saveDraft(c: *ui.Context, b: *Browser) void {
    const s = &b.settings.general;
    const d = if (s.draft) |*d| d else return;
    if (draftProblem(c, b, d) != null) return;
    const old = b.prefs.keywords;
    const list = c.alloc().alloc(Keyword, old.len + 1) catch return;
    @memcpy(list[0..old.len], old);
    list[old.len] = .{ .id = Uuid.random(), .keyword = trim(d.word.text()), .template = trim(d.template.text()) };
    b.prefs.setKeywords(list);
    s.dropDraft();
}

fn siteShortcuts(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const s = &b.settings.general;
    plate.line(c, p, "Site shortcuts", keywordDetail(c, b));
    if (s.draft == null) {
        if (controls.pill(c, p, "Add", .{}).clicked) s.draft = .{};
    } else {
        ui.row(c, .{ .gap = 6, .align_items = .center });
        if (controls.pill(c, p, "Cancel", .{}).clicked) s.dropDraft();
        if (s.draft) |*d| {
            const ok = draftProblem(c, b, d) == null;
            ui.column(c, .{ .opacity = if (ok) 1 else 0.4 });
            if (controls.pill(c, p, "Save", .{ .filled = true }).clicked and ok) saveDraft(c, b);
            ui.end(c);
        }
        ui.end(c);
    }
    ui.end(c);

    if (s.draft) |*d| {
        ui.column(c, .{ .width = .fill, .padding = .{ .left = 14, .right = 14, .bottom = 6 } });
        ui.row(c, .{ .gap = 8, .width = .fill, .padding = .xy(10, 7), .radius = 9, .background = p.wash, .align_items = .center });
        _ = field(c, p, &d.word, "yt", .{ .px = 50 });
        ui.text(c, "→", .{ .size = 12.5, .color = p.muted });
        if (field(c, p, &d.template, "https://www.youtube.com/results?search_query=%s", .fill).submitted) saveDraft(c, b);
        ui.end(c);
        ui.end(c);
    }

    var gone: ?Uuid = null;
    for (b.prefs.keywords) |k| {
        ui.key(c, c.print("kw.{f}", .{k.id}));
        ui.column(c, .{ .width = .fill, .padding = .{ .left = 14, .right = 14, .bottom = 6 } });
        ui.row(c, .{ .gap = 8, .width = .fill, .padding = .xy(10, 7), .radius = 9, .background = p.wash, .align_items = .center });
        ui.column(c, .{ .width = .{ .px = 50 } });
        ui.text(c, k.keyword, .{ .size = 12.5, .color = p.ink, .truncate = true });
        ui.end(c);
        ui.text(c, "→", .{ .size = 12.5, .color = p.muted });
        ui.column(c, .{ .grow = 1, .min_width = 0 });
        // ponytail: cut at the end, not the middle (`truncationMode(.middle)`).
        ui.text(c, k.template, .{ .size = 12.5, .color = p.ink, .truncate = true });
        ui.end(c);
        const i = c.open(.{ .control = true }, null);
        if (c.interact(i, .{}).clicked) gone = k.id;
        c.addA11y(i, .button, "Remove", "", false, true);
        ui.icon(c, "xmark.circle.fill", .{ .size = 12.5, .color = p.faint });
        c.end();
        ui.end(c);
        ui.end(c);
    }
    if (gone) |id| {
        const old = b.prefs.keywords;
        const list = c.alloc().alloc(Keyword, old.len) catch return;
        var n: usize = 0;
        for (old) |k| if (!k.id.eql(id)) {
            list[n] = k;
            n += 1;
        };
        b.prefs.setKeywords(list[0..n]);
    }
}

/// A plain field over the wash, its placeholder in muted.
fn field(c: *ui.Context, p: *const Palette, buf: *ui.TextBuffer, placeholder: []const u8, width: ui.Length) ui.TextFieldResult {
    ui.column(c, .{ .width = width, .grow = if (width == .fill) 1 else 0 });
    defer ui.end(c);
    if (buf.text().len == 0)
        _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = placeholder, .style = .{ .size = 12.5, .truncate = true }, .color = p.muted.alpha(0.7) } }, null);
    return ui.textField(c, buf, .{ .bare = true, .size = 12.5, .width = .fill, .caret_color = p.ink, .selection_color = p.ink.alpha(0.12) });
}
