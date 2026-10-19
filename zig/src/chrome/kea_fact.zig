//! A few true things about the bird (`KeaArt.facts`), and `KeaFact`: one of
//! them under the address field on a blank tab, gone while anything is typed
//! or offered (Settings › General › Kea facts on new tabs, `kea.facts`).
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");

pub const facts = [_][]const u8{
    "Kea are the world's only alpine parrot.",
    "A group of kea is called a circus.",
    "Kea live in the mountains of New Zealand's South Island.",
    "A kea's play call is so catching that other kea start playing when they hear it.",
    "Under their olive wings, kea hide bright orange-red feathers.",
    "Kea can solve puzzles that need several steps, in the right order.",
    "Kea are famous for taking cars apart: wiper blades and rubber seals are favourites.",
    "The name kea comes from Māori, after the bird's call: 'keee-aa'.",
    "Kea are about 48 cm long and weigh close to a kilogram.",
    "Young kea have a yellow cere and eye-ring that fade as they grow up.",
    "Kea are endangered: only a few thousand are left in the wild.",
    "Kea will slide down snowy roofs, seemingly just for fun.",
    "Kea eat more than 200 kinds of plant, plus insects and grubs.",
    "A kea's long upper beak is a tool for digging, prying and peeling.",
    "Kea were named New Zealand's Bird of the Year in 2017.",
};

/// The same fact all day, a new one tomorrow: today's ordinal day in the
/// era, by the Mac's calendar (`Calendar.current.ordinality(of:in:for:)`).
pub fn fact() []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const calendar = objc.msg(objc.Object, objc.class("NSCalendar"), "currentCalendar", .{});
    const now = objc.msg(objc.Object, objc.class("NSDate"), "date", .{});
    // NSCalendarUnitDay, NSCalendarUnitEra.
    const day = objc.msg(objc.NSUInteger, calendar, "ordinalityOfUnit:inUnit:forDate:", .{ @as(objc.NSUInteger, 16), @as(objc.NSUInteger, 2), now });
    return facts[day % facts.len];
}

/// Under the field whose top is `field_y` in `area` (its 50 points and 18
/// of air), coming and going with it (`opacity`).
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, area: ui.Rect, field_y: f32, opacity: f32) void {
    const o = &b.omni;
    if (o.typed.items.len > 0 or o.offers.len > 0 or o.site_offer != null) return;
    const w = metrics.field_width;
    ui.column(c, .{
        .absolute = true,
        .offset = .{ .x = area.x + (area.w - w) / 2, .y = field_y + 50 + 18 },
        .width = .{ .px = w },
        .align_items = .center,
        .opacity = opacity,
    });
    defer ui.end(c);
    ui.text(c, fact(), .{ .size = 12, .color = p.muted });
}
