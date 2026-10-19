//! The pieces every panel is made of (Plate.swift): the plate with its
//! title and cross, hairline cards with rules between lines, the line, the
//! caption, the field for narrowing a list, the empty text and the small
//! text action.
const ui = @import("nanoui").ui;
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const controls = @import("controls.zig");

/// An open plate: build its content, then `foot` (optional), then `end`.
pub const Plate = struct {
    /// The cross was pressed.
    closed: bool,
    footed: bool = false,

    /// Ends the content and opens the foot, below a hairline.
    pub fn foot(pl: *Plate, c: *ui.Context, p: *const Palette) void {
        c.end();
        pl.footed = true;
        _ = c.leaf(.{ .height = .{ .px = 18 } }, .none, null);
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = p.hairline }, .none, null);
        _ = c.open(.{ .direction = .row, .width = .fill, .padding = .xy(22, 14), .align_items = .center }, null);
    }

    pub fn end(pl: Plate, c: *ui.Context) void {
        c.end();
        if (!pl.footed) _ = c.leaf(.{ .height = .{ .px = 20 } }, .none, null);
        c.end();
    }
};

/// `Plate`: a rounded card with a title, a cross ("Done   esc"), whatever
/// the panel is about (opened here, padded 22 either side) and an optional
/// foot. Width 560 unless the panel says.
pub fn plate(c: *ui.Context, p: *const Palette, title: []const u8, width: f32) Plate {
    _ = c.open(.{
        .width = .{ .px = width },
        .radius = 16,
        .clip = true,
        .background = p.ground,
        .border = p.hairline,
        .shadow = card.swiftShadow(0.16, 34, 12),
    }, null);
    ui.row(c, .{ .gap = 10, .width = .fill, .padding = .{ .left = 22, .right = 22, .top = 18, .bottom = 14 }, .align_items = .center });
    ui.text(c, title, .{ .size = 17, .weight = .semibold, .color = p.ink, .truncate = true });
    ui.spacer(c);
    const closed = controls.door(c, p, "xmark", .{ .help = "Done   esc" }).clicked;
    ui.end(c);
    // The content, then (in `foot`) a hairline 18 below it.
    _ = c.open(.{ .width = .fill, .padding = .{ .left = 22, .right = 22 } }, null);
    return .{ .closed = closed };
}

/// `Card`: lines in one hairline box; close with `ui.end`.
pub fn cardBox(c: *ui.Context, p: *const Palette) void {
    _ = c.open(.{ .width = .fill, .radius = 11, .clip = true, .background = p.ground, .border = p.hairline }, null);
}

/// `Rule`: the hairline between two lines of a card, inset like the text.
pub fn rule(c: *ui.Context, p: *const Palette, inset: f32) void {
    ui.row(c, .{ .width = .fill, .padding = .{ .left = inset } });
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = p.hairline }, .none, null);
    ui.end(c);
}

/// `Line`: what it is on the left (and a detail under it), the control the
/// caller adds next on the right; close with `ui.end`.
pub fn line(c: *ui.Context, p: *const Palette, title: []const u8, detail: ?[]const u8) void {
    ui.row(c, .{ .gap = 16, .width = .fill, .padding = .xy(14, 11), .align_items = .center });
    ui.column(c, .{ .gap = 3, .grow = 1, .min_width = 0 });
    ui.text(c, title, .{ .size = 13, .color = p.ink });
    if (detail) |d| ui.text(c, d, .{ .size = 11.5, .color = p.muted, .wrap = true, .max_lines = 3 });
    ui.end(c);
    // `Spacer(minLength: 8)`: at least 16 + 8 + 16 before the control.
    _ = c.leaf(.{ .min_width = 8, .width = .{ .px = 8 } }, .none, null);
}

/// `Caption`: a small heading over a card.
pub fn caption(c: *ui.Context, p: *const Palette, str: []const u8) void {
    ui.row(c, .{ .padding = .{ .left = 2 } });
    ui.text(c, str, .{ .size = 11.5, .weight = .medium, .color = p.muted });
    ui.end(c);
}

/// `Hunt`: the field for narrowing a list, with a cross to empty it.
pub fn hunt(c: *ui.Context, p: *const Palette, buf: *ui.TextBuffer, prompt: []const u8) ui.TextFieldResult {
    return huntFocus(c, p, buf, prompt, false);
}

/// `Hunt` with `.focused($hunting)` set: the field takes the keys now.
pub fn huntFocus(c: *ui.Context, p: *const Palette, buf: *ui.TextBuffer, prompt: []const u8, focus: bool) ui.TextFieldResult {
    ui.row(c, .{ .gap = 8, .width = .fill, .padding = .xy(12, 8), .radius = 10, .background = p.wash, .align_items = .center });
    defer ui.end(c);
    ui.icon(c, "magnifyingglass", .{ .size = 11, .weight = .medium, .color = p.muted });
    ui.column(c, .{ .grow = 1 });
    if (buf.text().len == 0)
        _ = c.leaf(.{ .absolute = true, .offset = .{ .y = 2 } }, .{ .text = .{ .str = prompt, .style = .{ .size = 13 }, .color = p.muted.alpha(0.7) } }, null);
    if (focus) ui.focusNext(c, false);
    const r = ui.textField(c, buf, .{ .bare = true, .size = 13, .width = .fill });
    ui.end(c);
    if (buf.text().len > 0) {
        const i = c.open(.{ .control = true }, null);
        const it = c.interact(i, .{});
        c.addA11y(i, .button, "Clear", "", false, true);
        ui.icon(c, "xmark.circle.fill", .{ .size = 11, .color = p.faint });
        c.end();
        if (it.clicked) {
            buf.clear();
            c.changed = true;
        }
    }
    return r;
}

/// `Nothing`: what a panel says when its list is empty.
pub fn nothing(c: *ui.Context, p: *const Palette, str: []const u8) void {
    ui.column(c, .{ .width = .fill, .padding = .xy(14, 18) });
    ui.text(c, str, .{ .size = 13, .color = p.muted, .wrap = true });
    ui.end(c);
}

/// `Quick`: a small text action inside a row (Show, Copy, Remove).
pub fn quick(c: *ui.Context, p: *const Palette, title: []const u8, tint: ?ui.Color) ui.Interaction {
    const i = c.open(.{ .padding = .xy(8, 4), .radius = controls.capsule, .background = p.wash, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .button, title, "", false, true);
    ui.text(c, title, .{ .size = 11.5, .color = tint orelse p.ink });
    return it;
}
