//! `ImportProgress` (App.swift:1570-1639): a file being brought in, in the
//! background (#380) — its name, how far it has got, and Cancel — in the
//! window's top-trailing corner, over everything else.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const bring = @import("bring.zig");
const takers = @import("../model/browser_import.zig");

const width: f32 = 250;
const pad: f32 = 14;

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const job = b.importing.file orelse return;
    ui.column(c, .{ .absolute = true, .width = .fill, .padding = .all(20), .align_items = .end });
    defer ui.end(c);
    const box = c.open(.{ .width = .{ .px = width }, .gap = 7, .padding = .all(pad), .radius = 12, .background = p.ground, .border = p.hairline, .shadow = card.swiftShadow(0.08, 16, 5) }, "kea.import.progress");
    defer c.end();
    _ = c.interact(box, .{});
    c.addA11y(box, .group, c.print("Importing {s}, {s}", .{ job.filename, job.message }), "", false, true);
    ui.text(c, job.filename, .{ .size = 13, .weight = .medium, .color = p.ink, .truncate = true });
    ui.text(c, job.message, .{ .size = 12, .color = p.muted, .truncate = true });
    const fraction: ?f32 = if (job.total) |t| if (t > 0) @min(1, @as(f32, @floatFromInt(job.completed)) / @as(f32, @floatFromInt(t))) else null else null;
    _ = c.open(.{ .width = .fill, .height = .{ .px = 3 }, .radius = 1.5, .background = p.hairline }, null);
    if (fraction) |f| _ = c.leaf(.{ .width = .{ .px = (width - 2 * pad) * f }, .height = .fill, .radius = 1.5, .background = p.ink.alpha(0.7) }, .none, null);
    c.end();
    ui.row(c, .{ .width = .fill, .align_items = .center });
    if (job.total) |t| if (t > 0) {
        const a = c.alloc();
        ui.text(c, c.print("{s} of {s}", .{ bring.number(a, job.completed), bring.number(a, t) }), .{ .size = 11, .color = p.muted });
    };
    ui.spacer(c);
    const i = c.open(.{ .padding = .{ .left = 10, .right = 10 }, .height = .{ .px = 22 }, .radius = 11, .background = p.ink.alpha(0.07), .justify = .center, .control = true }, null);
    const title = if (job.cancelling) "Cancelling…" else "Cancel";
    c.addA11y(i, .button, title, "", false, !job.cancelling);
    const pressed = c.interact(i, .{}).clicked;
    ui.text(c, title, .{ .size = 12, .color = p.ink });
    c.end();
    ui.end(c);
    if (pressed and !job.cancelling) takers.cancelFileImport(b);
}
