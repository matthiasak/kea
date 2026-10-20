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
const chip_id: u64 = std.hash.Wyhash.hash(0, "kea.omnibox.chip");

fn copyUtf8(dst: []u8, src: []const u8) u8 {
    var n = @min(src.len, dst.len);
    while (n < src.len and n > 0 and (src[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

const SavedSite = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    host_buf: [64]u8 = undefined,
    host_len: u8 = 0,

    fn set(self: *SavedSite, s: SearchSite) void {
        self.name_len = copyUtf8(&self.name_buf, s.name);
        self.host_len = copyUtf8(&self.host_buf, s.host);
    }

    fn site(self: *const SavedSite) SearchSite {
        return .{
            .name = self.name_buf[0..self.name_len],
            .host = self.host_buf[0..self.host_len],
            .template = "",
        };
    }
};

const SavedRow = struct {
    key_buf: [160]u8 = undefined,
    key_len: u8 = 0,
    title_buf: [160]u8 = undefined,
    title_len: u8 = 0,
    url_buf: [160]u8 = undefined,
    url_len: u8 = 0,
    kind: omni.Offer.Kind = .visited,
    picked: bool = false,
    landing: bool = false,

    fn set(self: *SavedRow, o: omni.Offer, picked: bool, landing: bool) void {
        self.key_len = copyUtf8(&self.key_buf, o.key);
        self.title_len = copyUtf8(&self.title_buf, o.title);
        self.url_len = copyUtf8(&self.url_buf, o.url);
        self.kind = o.kind;
        self.picked = picked;
        self.landing = landing;
    }

    fn offer(self: *const SavedRow) omni.Offer {
        return .{
            .key = self.key_buf[0..self.key_len],
            .title = self.title_buf[0..self.title_len],
            .url = self.url_buf[0..self.url_len],
            .kind = self.kind,
        };
    }
};

var last_list_browser: ?*const Browser = null;
var last_rows: [10]SavedRow = undefined;
var last_rows_len: usize = 0;
var last_site_offer: SavedSite = .{};
var last_has_site_offer: bool = false;

var last_chip_browser: ?*const Browser = null;
var last_chip: SavedSite = .{};
var last_has_chip: bool = false;

/// The list, its top `y` (the field's 50 and 8 of air below it), `w` wide.
pub fn list(b: *Browser, c: *ui.Context, p: *const Palette, x: f32, y: f32, w: f32) ?Click {
    if (last_list_browser != b) {
        last_list_browser = b;
        last_rows_len = 0;
        last_has_site_offer = false;
    }
    const o = &b.omni;
    const shown = o.offers.len > 0 or o.site_offer != null;
    if (shown) {
        if (o.site_offer) |site| {
            last_site_offer.set(site);
            last_has_site_offer = true;
        } else last_has_site_offer = false;
        const n = @min(o.offers.len, last_rows.len);
        for (o.offers[0..n], 0..) |offer, i| {
            last_rows[i].set(offer, o.picked == i, o.picked == null and o.landing == i);
        }
        last_rows_len = n;
    }
    // Its coming and going, briefly (`Motion.quick`), anchored to its top.
    const v = motion.quickTo(c, list_id, 0, if (shown) 1 else 0);
    if (!shown and (v <= 0.001 or (last_rows_len == 0 and !last_has_site_offer))) {
        last_rows_len = 0;
        last_has_site_offer = false;
        return null;
    }
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
    if (!shown) {
        if (last_has_site_offer) {
            ui.key(c, "omni-site-offer");
            _ = siteOfferRow(b, c, p, last_site_offer.site(), false);
        }
        for (last_rows[0..last_rows_len], 0..) |*sr, i| {
            ui.key(c, c.print("omni-row-{d}", .{i}));
            _ = row(b, c, p, sr.offer(), sr.picked, sr.landing, false);
        }
        return null;
    }
    var click: ?Click = null;
    if (o.site_offer) |site| {
        ui.key(c, "omni-site-offer");
        if (siteOfferRow(b, c, p, site, true).clicked) click = .lock;
    }
    for (o.offers, 0..) |offer, i| {
        ui.key(c, c.print("omni-row-{d}", .{i}));
        const picked = o.picked == i;
        const landing = o.picked == null and o.landing == i;
        if (row(b, c, p, offer, picked, landing, true).clicked) click = .{ .offer = i };
    }
    return click;
}

const Row = struct { index: u32, it: ui.Interaction };

/// A row's box: 12×9 of air; picked by the arrow keys, its sunset; else
/// the pointer's quieter grey; else, where Return goes, a fainter sunset.
fn rowBox(c: *ui.Context, p: *const Palette, picked: bool, landing: bool, live: bool) Row {
    const i = c.open(.{ .direction = .row, .gap = 10, .padding = .xy(12, 9), .width = .fill, .radius = 9, .align_items = .center, .control = live }, null);
    const it = if (live) c.interact(i, .{}) else ui.Interaction{ .id = c.node(i).id, .rect = null, .hovered = false, .pressed = false, .clicked = false, .focused = false };
    const h = motion.quickTo(c, c.node(i).id, 0, if (it.hovered) 1 else 0);
    c.node(i).style.background = if (picked) p.sunset.alpha(0.12) else if (it.hovered or !landing) p.hover.alpha(h) else p.sunset.alpha(0.06);
    return .{ .index = i, .it = it };
}

fn row(b: *Browser, c: *ui.Context, p: *const Palette, offer: omni.Offer, picked: bool, landing: bool, live: bool) ui.Interaction {
    const r = rowBox(c, p, picked, landing, live);
    defer c.end();
    if (live) c.addA11y(r.index, .row, offer.key, offer.title, picked, true);
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
fn siteOfferRow(b: *Browser, c: *ui.Context, p: *const Palette, site: SearchSite, live: bool) ui.Interaction {
    const r = rowBox(c, p, false, false, live);
    defer c.end();
    const label = c.print("Search {s}", .{site.name});
    if (live) c.addA11y(r.index, .row, c.print("{s}, press Tab", .{label}), "", false, true);
    siteIcon(b, c, p, site);
    ui.text(c, label, .{ .size = 13, .color = p.ink, .truncate = true });
    ui.spacer(c);
    controls.keyCap(c, p, "Tab");
    return r.it;
}

/// The site Tab put in the field: its icon and name before what is typed.
/// It arrives scaled from .9 at its leading edge and fading in, and leaves
/// the same way, on `Motion.quick`.
pub fn siteChip(b: *Browser, c: *ui.Context, p: *const Palette, maybe_site: ?SearchSite) void {
    if (last_chip_browser != b) {
        last_chip_browser = b;
        last_has_chip = false;
    }
    const shown = maybe_site != null;
    if (shown) {
        if (!last_has_chip and c.rects.get(c.peekId("omni-site-chip")) == null) _ = ui.tween(c, chip_id, 0, 0, 0, .linear);
        last_chip.set(maybe_site.?);
        last_has_chip = true;
    }
    const t = motion.quickTo(c, chip_id, 0, if (shown) 1 else 0);
    if (!shown and (t <= 0.001 or !last_has_chip)) {
        last_has_chip = false;
        return;
    }
    const site = if (maybe_site) |s| s else last_chip.site();
    const i = c.open(.{
        .direction = .row,
        .gap = 6,
        .padding = .xy(8, 0),
        .height = px(22),
        .radius = 7,
        .background = p.wash,
        .align_items = .center,
        .scale = 0.9 + 0.1 * t,
        .scale_anchor = .{ .x = 0, .y = 0.5 },
        .opacity = t,
    }, "omni-site-chip");
    defer c.end();
    if (shown) c.addA11y(i, .image, c.print("Searching {s}", .{site.name}), "", false, false);
    siteIcon(b, c, p, site);
    ui.text(c, site.name, .{ .size = 13, .weight = .medium, .color = p.ink });
}
