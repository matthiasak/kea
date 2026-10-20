//! What the field thinks you mean (Omnibox.swift `list`, `Row`, `SiteIcon`,
//! `SiteChip`, `SiteOfferRow`): places you have been with their titles, the
//! well-known ones without, a search when it can't be a place, the site a
//! Tab away. It hangs below the field and never moves it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const omni = @import("../model/omni.zig");
const SearchSite = @import("../data/site_search.zig").SearchSite;
const address = @import("../model/address.zig");
const Palette = @import("../design/palette.zig").Palette;
const card = @import("../design/card.zig");
const motion = @import("../design/motion.zig");
const controls = @import("controls.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// What a click in the list asked for, done once it is drawn.
pub const Click = union(enum) { lock, offer: usize };

const list_id: u64 = std.hash.Wyhash.hash(0, "kea.omnibox.list");

/// The list, its top `y` (the field's 50 and 8 of air below it), `w` wide.
pub fn list(b: *Browser, c: *ui.Context, p: *const Palette, x: f32, y: f32, w: f32) ?Click {
    const o = &b.omni;
    const shown = o.offers.len > 0 or o.site_offer != null;
    // Its coming and going, briefly (`Motion.quick`), anchored to its top.
    // ponytail: a leaving list has no rows left to draw, so it simply goes.
    const v = motion.quickTo(c, list_id, 0, if (shown) 1 else 0);
    if (!shown) return null;
    ui.key(c, "kea.omnibox.list");
    ui.column(c, .{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = px(w),
        .padding = .all(6),
        .radius = 14,
        .background = p.ground,
        .border = p.hairline,
        .shadow = card.swiftShadow(0.07, 20, 6),
        .scale = 0.98 + 0.02 * v,
        .scale_anchor = .{ .x = 0.5, .y = 0 },
        .opacity = v,
    });
    defer ui.end(c);
    var click: ?Click = null;
    if (o.site_offer) |site| {
        ui.key(c, "omni-site-offer");
        if (siteOfferRow(b, c, p, site).clicked) click = .lock;
    }
    for (o.offers, 0..) |offer, i| {
        ui.key(c, c.print("omni-row-{d}", .{i}));
        const picked = o.picked == i;
        const landing = o.picked == null and o.landing == i;
        if (row(b, c, p, offer, picked, landing).clicked) click = .{ .offer = i };
    }
    return click;
}

const Row = struct { index: u32, it: ui.Interaction };

/// A row's box: 12×9 of air; picked by the arrow keys, its sunset; else
/// the pointer's quieter grey; else, where Return goes, a fainter sunset.
fn rowBox(c: *ui.Context, p: *const Palette, picked: bool, landing: bool) Row {
    const i = c.open(.{ .direction = .row, .gap = 10, .padding = .xy(12, 9), .width = .fill, .radius = 9, .align_items = .center, .control = true }, null);
    const it = c.interact(i, .{});
    const h = motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = if (picked) p.sunset.alpha(0.12) else if (it.hovered or !landing) p.hover.alpha(h) else p.sunset.alpha(0.06);
    return .{ .index = i, .it = it };
}

fn row(b: *Browser, c: *ui.Context, p: *const Palette, offer: omni.Offer, picked: bool, landing: bool) ui.Interaction {
    const r = rowBox(c, p, picked, landing);
    defer c.end();
    c.addA11y(r.index, .row, offer.key, offer.title, picked, true);
    switch (offer.kind) {
        // The engine's own icon when this Mac has it; the glass until then.
        .search => if (b.kea.favicons.icon(offer.url)) |ic| {
            if (!ui.image(c, .{ .key = ic.key, .bytes = ic.png, .max_width = 14, .max_height = 14, .radius = 3, .scale = 0.5 }))
                ui.icon(c, "magnifyingglass", .{ .size = 10, .weight = .medium, .color = p.muted });
        } else ui.icon(c, "magnifyingglass", .{ .size = 10, .weight = .medium, .color = p.muted }),
        // Already open: naming it takes you back to it.
        .open => {
            _ = c.open(.{ .padding = .xy(2, 0) }, null);
            _ = c.leaf(.{ .width = px(5), .height = px(5), .radius = 2.5, .background = p.ink.alpha(0.55) }, .none, null);
            c.end();
        },
        .command => ui.icon(c, "command", .{ .size = 10, .weight = .medium, .color = p.muted }),
        .visited, .known => {},
    }
    // The row reads without the www; the key keeps it.
    ui.text(c, address.withoutWWW(offer.key), .{ .size = 13, .color = p.ink, .truncate = true });
    if (offer.title.len > 0) ui.text(c, offer.title, .{ .size = 12, .color = p.muted, .truncate = true });
    ui.spacer(c);
    return r.it;
}

/// A site's icon when this Mac has it, or a glass.
fn siteIcon(b: *Browser, c: *ui.Context, p: *const Palette, site: SearchSite) void {
    const host = site.host[0 .. std.mem.indexOfScalar(u8, site.host, '/') orelse site.host.len];
    if (b.kea.favicons.cached(host)) |k| {
        if (ui.image(c, .{ .key = k.name, .bytes = k.png, .max_width = 14, .max_height = 14, .radius = 3, .scale = 0.5 })) return;
    }
    ui.icon(c, "magnifyingglass", .{ .size = 10, .weight = .medium, .color = p.muted, .frame = 14 });
}

/// "Search Reddit", first in the list, with the key that takes it.
fn siteOfferRow(b: *Browser, c: *ui.Context, p: *const Palette, site: SearchSite) ui.Interaction {
    const r = rowBox(c, p, false, false);
    defer c.end();
    const label = c.print("Search {s}", .{site.name});
    c.addA11y(r.index, .row, c.print("{s}, press Tab", .{label}), "", false, true);
    siteIcon(b, c, p, site);
    ui.text(c, label, .{ .size = 13, .color = p.ink, .truncate = true });
    ui.spacer(c);
    controls.keyCap(c, p, "Tab");
    return r.it;
}

/// The site Tab put in the field: its icon and name before what is typed.
/// It arrives scaled from .9 at its leading edge and fading in, on
/// `Motion.quick`. ponytail: it leaves at once (the chip is gone with it).
pub fn siteChip(b: *Browser, c: *ui.Context, p: *const Palette, site: SearchSite) void {
    const i = c.open(.{ .direction = .row, .gap = 6, .padding = .xy(8, 0), .height = px(22), .radius = 7, .background = p.wash, .align_items = .center }, "omni-site-chip");
    defer c.end();
    // New this frame (not drawn last frame): from nothing, as split_stage's panes.
    const id = c.node(i).id;
    if (c.rects.get(id) == null) _ = ui.tween(c, id, 0x6368, 0, 0, .linear);
    const t = ui.tween(c, id, 0x6368, 1, motion.quick_duration, motion.quick_curve);
    c.node(i).style.scale = 0.9 + 0.1 * t;
    c.node(i).style.scale_anchor = .{ .x = 0, .y = 0.5 };
    c.node(i).style.opacity = t;
    c.addA11y(i, .image, c.print("Searching {s}", .{site.name}), "", false, false);
    siteIcon(b, c, p, site);
    ui.text(c, site.name, .{ .size = 13, .weight = .medium, .color = p.ink });
}
