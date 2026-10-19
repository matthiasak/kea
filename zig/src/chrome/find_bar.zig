//! `FindBar` (Find.swift): looking for a word on the page. A pill in the
//! page's top trailing corner, the same white and hairline as everything
//! else that floats, on `web/page_find.zig`: "3 of 17" as the page counted
//! it (red on a miss), ▲▼, Match case and Whole words under ⋯, and gone
//! the moment it isn't wanted. A pane narrower than 290 keeps Return and
//! ⇧Return instead of the arrows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");
const presence = @import("presence.zig");
const tab_menu = @import("tab_menu.zig");
const find = @import("../web/page_find.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// `Browser.find_bar`: the field's typing, and a second try at the keys.
pub const State = struct {
    field: ui.TextBuffer = .{},
    /// Focus was asked for last frame: if the field didn't take it, once more.
    refocus: bool = false,

    pub fn deinit(st: *State) void {
        st.field.deinit();
    }
};

/// `narrow` and `fieldWidth`: the room of the pane it is over, in Split View.
pub fn fieldWidth(available: ?f32) f32 {
    const w = available orelse return 150;
    return @max(40, @min(160, w - @as(f32, if (narrow(available)) 80 else 130)));
}

pub fn narrow(available: ?f32) bool {
    return if (available) |w| w < 290 else false;
}

const bar_id: u64 = std.hash.Wyhash.hash(0, "kea.find-bar");

/// Over the focused page: call inside that page's box. `available`: the
/// pane's width in Split View, null for the one page.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, available: ?f32) void {
    const f = &b.finder;
    const t = presence.presence(c, bar_id, f.finding, motion.settle, null) orelse return;
    const tight = narrow(available);
    ui.row(c, .{
        .absolute = true,
        .width = .fill,
        .justify = .end,
        .padding = .{ .top = 12, .right = 14 },
        .offset = .{ .y = -(1 - t) * 44 },
        .opacity = std.math.clamp(t, 0, 1),
    });
    defer ui.end(c);
    const missed = motion.quickTo(c, bar_id, 1, if (f.missed) 1 else 0);
    var shadow = card.swiftShadow(0.10, 18, 5);
    shadow.knockout = true;
    const i = c.open(.{
        .direction = .row,
        .gap = 6,
        .padding = .{ .left = if (tight) 10 else 16, .right = if (tight) 6 else 8, .top = 8, .bottom = 8 },
        .radius = controls.capsule,
        .background = p.ground,
        .border = p.hairline.mix(p.red.alpha(0.35), missed),
        .shadow = shadow,
        .align_items = .center,
    }, "find-bar");
    defer c.end();
    _ = c.interact(i, .{});
    // Drawn while leaving too, so the bar fades out at its own width.
    field(b, c, p, available);
    var buf: [48]u8 = undefined;
    if (find.status(b, &buf)) |status| {
        const said = c.print("{s}", .{status});
        const s = c.leaf(.{}, .{ .text = .{ .str = said, .style = .{ .size = 10, .weight = .medium, .tabular = true }, .color = if (f.missed) p.red.alpha(0.8) else p.muted } }, null);
        c.addA11y(s, .static_text, said, "", false, false);
    }
    if (!tight) {
        if (step(c, p, "chevron.up", "Previous match", "Find the previous match.")) find.look(b, false);
        if (step(c, p, "chevron.down", "Next match", "Find the next match.")) find.look(b, true);
    }
    options(b, c, p);
    if (step(c, p, "xmark", "Close Find on Page", "Close the find field and clear its selection.")) find.closeFind(b);
}

/// The field, given the keys when ⌘F asks (`findFocus`), with what was
/// looked for selected — and once more a moment later if it didn't take.
fn field(b: *Browser, c: *ui.Context, p: *const Palette, available: ?f32) void {
    const f = &b.finder;
    const st = &b.find_bar;
    ui.column(c, .{ .width = px(fieldWidth(available)) });
    defer ui.end(c);
    const asked = f.focus != f.shown_focus;
    if (asked) {
        f.shown_focus = f.focus;
        st.field.set(f.needle);
    }
    if (st.field.text().len == 0)
        _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = "Find on page", .style = .{ .size = 12.5 }, .color = p.ink.alpha(0.3) } }, null);
    const again = st.refocus;
    st.refocus = false;
    if (asked or again) ui.focusNext(c, asked);
    const r = ui.textField(c, &st.field, .{ .bare = true, .size = 12.5, .width = .fill, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
    if (asked and !r.focused) st.refocus = true;
    if (asked) c.frameIn(0);
    if (!f.finding) return;
    if (r.changed) find.setNeedle(b, st.field.text());
    if (r.submitted) find.look(b, !c.input.shift);
}

/// One of the bar's 24-point buttons; true when pressed.
fn step(c: *ui.Context, p: *const Palette, icon: []const u8, label: []const u8, help: []const u8) bool {
    const i = c.open(.{ .width = px(24), .height = px(24), .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, help);
    c.addA11y(i, .button, label, "", false, true);
    ui.icon(c, icon, .{ .size = 9, .weight = .semibold, .color = p.muted });
    return it.clicked;
}

/// ⋯: Match case and Whole words, ink while either is on.
fn options(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const f = &b.finder;
    const i = c.open(.{ .width = px(24), .height = px(24), .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, "Search options");
    c.addA11y(i, .menu_button, "Search options", "", false, true);
    ui.icon(c, "ellipsis", .{ .size = 10, .weight = .semibold, .color = if (f.match_case or f.whole_words) p.ink else p.muted });
    if (it.clicked) {
        const r = it.rect orelse return;
        tab_menu.later(b, .{ .x = r.x, .y = r.y + r.h }, 0, menuItems);
    }
}

const Pick = struct {
    b: *Browser,
    words: bool,

    fn fire(self: *Pick, _: *nanoui.menu.Item) void {
        const f = &self.b.finder;
        if (self.words) find.setWholeWords(self.b, !f.whole_words) else find.setMatchCase(self.b, !f.match_case);
        self.b.redraw();
    }
};

/// The ⋯ menu; Whole words is off for a PDF, which WebKit finds itself.
pub fn menuItems(arena: std.mem.Allocator, b: *Browser, _: u64) anyerror![]const nanoui.MenuItem {
    const f = &b.finder;
    const case = try arena.create(Pick);
    case.* = .{ .b = b, .words = false };
    const words = try arena.create(Pick);
    words.* = .{ .b = b, .words = true };
    const pdf = if (f.result) |r| r.native_fallback else false;
    const out = try arena.alloc(nanoui.MenuItem, 2);
    out[0] = .{ .label = "Match case", .kind = .checkbox, .checked = f.match_case, .tooltip = "Match uppercase and lowercase letters exactly.", .click = .of(case, Pick.fire) };
    out[1] = .{ .label = "Whole words", .kind = .checkbox, .checked = f.whole_words, .disabled = pdf and !f.whole_words, .tooltip = "Match complete words. This option is unavailable for PDF pages.", .click = .of(words, Pick.fire) };
    return out;
}
