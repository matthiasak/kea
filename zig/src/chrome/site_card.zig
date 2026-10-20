//! The site card (SiteCard.swift): what a click on the tab you are on shows
//! under its address, in the column and the strip alike — whether the
//! connection is private, and the few things that belong to the page (copy
//! its address, print it, its zoom, whether it may play sound by itself,
//! whether its videos float out). Right-click › Site Information… opens the
//! same, by beginning the same edit. It goes as soon as you type, when the
//! address is left, or when one of its lines is used. Drawn as the system
//! draws a menu (`design/menu.zig`), as `Overlay.site_card`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const menu = @import("../design/menu.zig");
const card = @import("../design/card.zig");
const overlays = @import("overlays.zig");
const controls = @import("controls.zig");
const config = @import("../web/config.zig");
const float = @import("../web/float.zig");
const Parts = @import("../data/url.zig").Parts;
const dispatch = @import("../sys/dispatch.zig");
const cg = @import("../sys/cg.zig");
const palette = @import("../design/palette.zig");
const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// What the card keeps between frames (`Browser.site_card`): the edit it
/// follows and its own `@State`.
pub const State = struct {
    /// The address as the edit began with it (hashed): the card is about
    /// that page, and goes once something else is typed.
    original: ?u64 = null,
    /// The tab being edited.
    tab: u64 = 0,
    /// One step in: the connection, said in full.
    deeper: bool = false,
    /// Whether this Mac trusts the certificate; null until asked.
    certified: ?bool = null,
    /// Play Sound by Itself as the card opened, and now.
    sound_was: bool = false,
    sound: bool = false,
    /// Don't Float Videos Here.
    ground: bool = false,
    /// Where the card was last laid out in the browser window, or null when
    /// the native child NSPanel is up; `panel_size` is the panel's fitted size.
    rect: ?ui.Rect = null,
    panel_size: ?ui.Size = null,
};

/// A press on the card is only a click: the address being edited under
/// it stays (its window never takes the keys, in Swift).
pub fn under(b: *const Browser, point: ui.Point) bool {
    if (!shown(b)) return false;
    const r = b.site_card.rect orelse return false;
    return r.contains(point);
}

// MARK: when

/// `SiteCardPanel.follow`, once a frame after the strip and the column
/// have drawn the edit's field: up when an address edit begins in a tab
/// with a page, down when it ends or something else is typed.
pub fn follow(b: *Browser) void {
    const st = &b.site_card;
    const t = edited(b) orelse {
        st.original = null;
        return hide(b);
    };
    const draft = std.hash.Wyhash.hash(0, b.tab_draft.text());
    if (st.original == null or st.tab != t.id) {
        show(b, t, draft);
    } else if (draft != st.original.?) {
        // Typing somewhere else: the card was about the page you are on.
        hide(b);
    }
    if (shown(b)) b.overlay_anchor = b.tab_field_rect;
}

/// The tab whose address is being edited in the tab itself, with a page.
fn edited(b: *Browser) ?*Tab {
    const id = b.editing_tab orelse return null;
    if (b.renaming_tab) return null;
    const t = b.tabById(id) orelse return null;
    return if (t.isBlank()) null else t;
}

fn show(b: *Browser, t: *Tab, draft: u64) void {
    const host = webHost(t);
    const plays = if (host) |h| config.autoplayAllowed(&b.kea.store, h) else false;
    b.site_card = .{
        .original = draft,
        .tab = t.id,
        .sound_was = plays,
        .sound = plays,
        .ground = if (host) |h| float.groundedHolds(&b.kea.store, h) else false,
    };
    b.overlay = .{ .site_card = t.id };
    b.overlay_anchor = b.tab_field_rect;
    certify(t);
    openPanel(b, t);
}

fn shown(b: *const Browser) bool {
    const o = b.overlay orelse return false;
    return o == .site_card;
}

fn hide(b: *Browser) void {
    closePanel(b);
    if (shown(b)) b.overlay = null;
}

/// The app stepped away: the card goes, the edit stays.
pub fn resign(b: *Browser) void {
    if (!shown(b)) return;
    hide(b);
    b.redraw();
}

/// The card's own `close`: the card goes, and the edit with it.
fn close(b: *Browser) void {
    hide(b);
    b.cancelTabEdit();
}

// ponytail: the site card uses a separate native child NSPanel backed by NSVisualEffectView
// (material = .popover, blendingMode = .behindWindow, continuous corner radius 14) so it can
// extend outside a narrow browser window and float above the WKWebView stage hole with real
// macOS vibrancy; headless/hidden test runs fall back to the in-window overlay pass.
const Panel = struct {
    tab_serial: u64,
    window: *nanoui.Window,
    glass: objc.Object,
};

var live_panel: ?*Panel = null;

extern "c" const kCACornerCurveContinuous: objc.Object;

fn panelBrowser(p: *const Panel) ?*Browser {
    const t = Tab.alive(p.tab_serial) orelse return null;
    const b = t.browser orelse return null;
    return if (b.site_card.tab == t.id and shown(b)) b else null;
}

fn openPanel(b: *Browser, t: *Tab) void {
    closePanel(null);
    if (b.kea.opts.hidden or b.kea.opts.root != null) return;
    const parent = b.window orelse return;
    const app = b.kea.ui_app orelse return;
    const p = std.heap.c_allocator.create(Panel) catch return;
    p.* = .{ .tab_serial = t.serial, .window = undefined, .glass = undefined };
    p.window = app.newWindow(.{
        .width = 260,
        .height = 200,
        .resizable = false,
        .title_bar = .hidden,
        .visible = false,
        .non_activating = true,
        .kind = .panel,
        .on_close = .{ .ctx = p, .func = panelClosed },
        .content = .{ .view = ui.View.init(p, panelView) },
    }) catch return std.heap.c_allocator.destroy(p);
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns = p.window.nswindow;
    const s = p.window.surface.?;
    const bounds = objc.msg(objc.CGRect, s.nsview, "bounds", .{});
    const glass = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{bounds});
    objc.msg(void, glass, "setMaterial:", .{@as(objc.NSInteger, 5)}); // .menu
    objc.msg(void, glass, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // .behindWindow
    objc.msg(void, glass, "setState:", .{@as(objc.NSInteger, 1)}); // .active
    objc.msg(void, glass, "setWantsLayer:", .{objc.YES});
    if (objc.msg(?objc.Object, glass, "layer", .{})) |layer| {
        objc.msg(void, layer, "setCornerRadius:", .{@as(f64, 14)});
        objc.msg(void, layer, "setCornerCurve:", .{kCACornerCurveContinuous});
        objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    }
    s.attachBackdrop(glass);
    objc.release(glass);
    p.glass = glass;
    objc.msg(void, ns, "setStyleMask:", .{@as(objc.NSUInteger, 1 << 7)}); // borderless nonactivatingPanel
    objc.msg(void, ns, "setOpaque:", .{objc.NO});
    objc.msg(void, ns, "setBackgroundColor:", .{objc.msg(objc.Object, objc.class("NSColor"), "clearColor", .{})});
    objc.msg(void, ns, "setHasShadow:", .{objc.YES});
    objc.msg(void, ns, "setBecomesKeyOnlyIfNeeded:", .{objc.YES});
    objc.msg(void, ns, "setHidesOnDeactivate:", .{objc.YES});
    live_panel = p;
    b.site_card.rect = null;
    s.frame();
    placePanel(p, b);
    objc.msg(void, parent.nswindow, "addChildWindow:ordered:", .{ ns, @as(objc.NSInteger, 1) });
}

fn closePanel(for_b: ?*Browser) void {
    const p = live_panel orelse return;
    if (for_b) |b| if (panelBrowser(p)) |owner| if (owner != b) return;
    live_panel = null;
    p.tab_serial = 0;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns = p.window.nswindow;
    if (objc.msg(?objc.Object, ns, "parentWindow", .{})) |pw| objc.msg(void, pw, "removeChildWindow:", .{ns});
    objc.msg(void, ns, "orderOut:", .{@as(?objc.Object, null)});
    objc.dispatchMain(p, closePanelLater);
}

fn closePanelLater(ctx: ?*anyopaque) callconv(.c) void {
    const p: *Panel = @ptrCast(@alignCast(ctx orelse return));
    p.window.close();
}

fn panelClosed(ctx: *anyopaque, _: *nanoui.Window) void {
    const p: *Panel = @ptrCast(@alignCast(ctx));
    if (live_panel == p) live_panel = null;
    std.heap.c_allocator.destroy(p);
}

fn placePanel(p: *Panel, b: *Browser) void {
    const parent = b.window orelse return;
    const ps = parent.surface orelse return;
    const sz = b.site_card.panel_size orelse return;
    const f = b.tab_field_rect;
    const in_win = objc.msg(objc.CGRect, ps.nsview, "convertRect:toView:", .{
        objc.CGRect{ .origin = .{ .x = f.x, .y = f.y }, .size = .{ .width = f.w, .height = f.h } }, @as(?objc.Object, null),
    });
    const spot = objc.msg(objc.CGRect, parent.nswindow, "convertRectToScreen:", .{in_win});
    var x = spot.origin.x - 12;
    var y = spot.origin.y - 12 - sz.h;
    if (objc.msg(?objc.Object, parent.nswindow, "screen", .{})) |scr| {
        const vf = objc.msg(objc.CGRect, scr, "visibleFrame", .{});
        x = @min(@max(x, vf.origin.x + 8), vf.origin.x + vf.size.width - sz.w - 8);
        if (y < vf.origin.y + 8) y = @min(spot.origin.y + spot.size.height + 12, vf.origin.y + vf.size.height - sz.h - 8);
    }
    objc.msg(void, p.window.nswindow, "setFrame:display:", .{
        objc.CGRect{ .origin = .{ .x = x, .y = y }, .size = .{ .width = sz.w, .height = sz.h } }, objc.YES,
    });
}

fn panelView(p: *Panel, c: *ui.Context) void {
    c.hand_cursor = false;
    const b = panelBrowser(p) orelse return;
    const t = b.tabById(b.site_card.tab) orelse return;
    const dark = c.theme.dark;
    const pal = palette.get(dark);
    const box = c.open(.{ .radius = 14, .border = menu.edge(dark), .border_width = 0.5, .padding = .{ .top = menu.pad, .bottom = menu.pad }, .min_width = 180 }, "kea.site_card.panel");
    defer c.end();
    b.site_card.rect = null;
    if (c.rects.get(c.node(box).id)) |r| b.site_card.panel_size = .{ .w = r.w, .h = r.h };
    if (b.site_card.deeper) if (safety(t, b.site_card.certified)) |s| return security(b, c, t, s, dark);
    front(b, c, pal, t, dark);
}

// MARK: the page

/// `pageAddress`: the page on screen, else where it is going.
fn pageAddress(t: *const Tab) ?[]const u8 {
    return t.committed orelse t.address;
}

/// The host of an http or https page.
fn webHost(t: *const Tab) ?[]const u8 {
    const p = Parts.parse(pageAddress(t) orelse return null) orelse return null;
    if (!p.isWeb()) return null;
    return p.hostName();
}

/// `SiteCard.site`: the host without its www.; a file is "File"; a page
/// with no host is named by its scheme.
pub fn site(url: []const u8) []const u8 {
    const p = Parts.parse(url) orelse return url;
    if (p.hostName()) |host| return if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
    if (p.schemeIs("file")) return "File";
    return p.scheme orelse url;
}

const Safety = struct {
    title: []const u8,
    detail: []const u8,
    /// The certificate the page came with, for an https page.
    trust: ?*anyopaque,
};

/// `safety`: what there is to say about the connection.
fn safety(t: *const Tab, certified: ?bool) ?Safety {
    const p = Parts.parse(pageAddress(t) orelse return null) orelse return null;
    if (p.schemeIs("https")) {
        const trust = serverTrust(t);
        // Only a certificate this Mac refused and you let through anyway
        // gets this far untrusted.
        if (certified == false) return .{
            .title = "Connection is not secure",
            .detail = "This site's certificate isn't trusted by this Mac. Someone could be reading what you send.",
            .trust = trust,
        };
        if (t.web) |wv| if (!objc.msg(objc.BOOL, wv, "hasOnlySecureContent", .{})) return .{
            .title = "Parts of this page are not secure",
            .detail = "The page came privately, but some of what it shows was fetched over plain http, where anyone on the network could read or change it.",
            .trust = trust,
        };
        return .{
            .title = "Connection is secure",
            .detail = "Your information (for example, passwords or credit card numbers) is private when it is sent to this site.",
            .trust = trust,
        };
    }
    if (p.schemeIs("http")) return .{
        .title = "Connection is not secure",
        .detail = "Don't enter passwords or credit card numbers here: anything sent to this site can be read on the way.",
        .trust = null,
    };
    return null;
}

fn serverTrust(t: *const Tab) ?*anyopaque {
    const wv = t.web orelse return null;
    return @ptrCast(objc.msg(?objc.Object, wv, "serverTrust", .{}));
}

extern "c" fn SecTrustEvaluateWithError(trust: *anyopaque, err: ?*?*anyopaque) bool;
extern "c" fn CFRetain(object: *anyopaque) *anyopaque;

/// `certify`: whether this Mac trusts the certificate, asked off the main
/// thread (the answer can need a revocation check).
const Certify = struct {
    serial: u64,
    trust: *anyopaque,
    ok: bool = false,

    fn ask(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Certify = @ptrCast(@alignCast(ctx.?));
        self.ok = SecTrustEvaluateWithError(self.trust, null);
        cg.CFRelease(self.trust);
        objc.dispatchMain(self, answered);
    }

    fn answered(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Certify = @ptrCast(@alignCast(ctx.?));
        defer std.heap.c_allocator.destroy(self);
        const t = Tab.alive(self.serial) orelse return;
        const b = t.browser orelse return;
        if (b.site_card.tab != t.id) return;
        b.site_card.certified = self.ok;
        b.redraw();
    }
};

fn certify(t: *Tab) void {
    const trust = serverTrust(t) orelse return;
    const job = std.heap.c_allocator.create(Certify) catch return;
    job.* = .{ .serial = t.serial, .trust = CFRetain(trust) };
    dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), job, Certify.ask);
}

/// The card goes first, then the thing is done, a turn later: a print
/// panel or a sheet coming up under a card on its way out lands behind it.
fn after(b: *Browser, t: *Tab, comptime act: fn (*Tab) void) void {
    close(b);
    const Later = struct {
        fn fire(ctx: ?*anyopaque) callconv(.c) void {
            act(Tab.alive(@intFromPtr(ctx)) orelse return);
        }
    };
    objc.dispatchMain(@ptrFromInt(t.serial), Later.fire);
}

fn printPage(t: *Tab) void {
    if (t.browser) |b| b.printPage();
}

/// The system's own certificate sheet, over the window. Never in tests.
fn showCertificate(t: *Tab) void {
    const b = t.browser orelse return;
    if (b.kea.opts.root != null or b.kea.opts.hidden) return;
    const w = b.window orelse return;
    const trust = serverTrust(t) orelse return;
    const panel = objc.msg(objc.Object, objc.class("SFCertificatePanel"), "sharedCertificatePanel", .{});
    objc.msg(void, panel, "beginSheetForWindow:modalDelegate:didEndSelector:contextInfo:trust:showGroup:", .{
        w.nswindow, @as(?objc.Object, null), @as(?objc.SEL, null), @as(?*anyopaque, null), trust, objc.NO,
    });
}

// MARK: the card

/// The open card, from the window's overlay pass.
pub fn overlay(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const st = &b.site_card;
    const t = b.tabById(st.tab) orelse {
        hide(b);
        return;
    };
    if (live_panel) |lp| if (panelBrowser(lp) == b) {
        st.rect = null;
        if (c.input.pressed and !b.tab_field_rect.contains(c.input.mouse)) return hide(b);
        if (lp.window.surface) |s| s.frame();
        if (live_panel == lp) placePanel(lp, b);
        return;
    };
    // It never takes the keys: the address stays in the tab being edited,
    // the caret where it was, and a click on the card is only a click.
    const focus = c.focus;
    defer c.focus = focus;
    const dark = c.theme.dark;
    // Under the address, lined up with the tab's own edge, 12 in from it.
    const r = b.overlay_anchor;
    const anchor: ui.Rect = .{ .x = r.x - 12, .y = r.y, .w = r.w + 12, .h = r.h };
    const style: ui.Style = .{
        .background = p.ground,
        .radius = menu.corner,
        .border = menu.edge(dark),
        .border_width = 0.5,
        .clip = true,
        // ponytail: a fixed shadow; Swift's NSPanel takes the system's window shadow.
        .shadow = card.swiftShadow(0.22, 12, 6),
        .padding = .{ .top = menu.pad, .bottom = menu.pad },
        .min_width = 180,
    };
    st.rect = c.rects.get(c.peekId(overlays.key));
    if (!overlays.begin(c, &b.overlay, anchor, style, .{ .gap = 12 })) return;
    defer ui.end(c);
    // ponytail: the step in swaps at once; Swift fades it on Motion.quick.
    if (st.deeper) if (safety(t, st.certified)) |s| return security(b, c, t, s, dark);
    front(b, c, p, t, dark);
}

fn front(b: *Browser, c: *ui.Context, p: *const Palette, t: *Tab, dark: bool) void {
    const st = &b.site_card;
    if (pageAddress(t)) |url| header(c, site(url), dark);
    if (safety(t, st.certified)) |s| {
        if (row(c, s.title, "", true, dark)) {
            st.deeper = true;
            c.changed = true;
        }
    }
    if (row(c, "Copy Address", "⇧⌘C", false, dark)) {
        close(b);
        b.copyAddress();
    }
    separator(c, dark);
    if (row(c, "Print…", "⌘P", false, dark)) after(b, t, printPage);
    zoom(b, c, t, dark);
    const host = webHost(t) orelse return;
    if (t.shy) return;
    // Not with Settings › Videos wait for a click, which lets no site.
    if (!b.prefs.waits_for_play) sound(b, c, p, host, dark);
    if ((b.prefs.floats_on_leave or b.prefs.floats_away) and float.playersKnow(pageAddress(t).?)) {
        _ = line(c, "Don't Float Videos Here", dark);
        defer c.end();
        if (controls.switch_(c, p, &st.ground, "Don't Float Videos Here")) float.setGrounded(&b.kea.store, st.ground, host);
    }
}

/// The page's size, remembered for the site, as a menu puts a control on
/// one of its lines: the steps at its end, the number back to the usual.
fn zoom(b: *Browser, c: *ui.Context, t: *Tab, dark: bool) void {
    _ = c.open(.{ .direction = .row, .width = .fill, .height = px(menu.row), .align_items = .center, .padding = .{ .left = menu.text, .right = menu.inset + 4 } }, null);
    defer c.end();
    ui.text(c, "Zoom", .{ .size = menu.font, .color = menu.label(dark) });
    _ = c.leaf(.{ .grow = 1, .min_width = 24 }, .none, null);
    const active = b.activeTab();
    if (step(c, "minus", "Zoom Out   ⌘-", dark)) if (active) |a| a.magnifyBy(1.0 / 1.1);
    const i = c.open(.{ .width = px(44), .height = px(menu.row), .align_items = .center, .justify = .center, .control = true }, null);
    const it = c.interact(i, .{});
    c.help(i, "Actual Size   ⌘0");
    c.addA11y(i, .button, "Actual Size", "", false, true);
    ui.text(c, c.print("{d}%", .{@as(i64, @intFromFloat(@round(t.zoom * 100)))}), .{ .size = menu.font, .color = menu.secondary(dark), .tabular = true });
    c.end();
    if (it.clicked) if (active) |a| a.resetZoom();
    if (step(c, "plus", "Zoom In   ⌘+", dark)) if (active) |a| a.magnifyBy(1.1);
}

/// Whether the site may play sound by itself. WebKit takes it as a page
/// loads, so a page already open stays as it came, and the line says so.
fn sound(b: *Browser, c: *ui.Context, p: *const Palette, host: []const u8, dark: bool) void {
    const st = &b.site_card;
    _ = line(c, "Play Sound by Itself", dark);
    defer c.end();
    if (st.sound != st.sound_was) {
        _ = c.open(.{ .padding = .{ .right = 8 } }, null);
        ui.text(c, "from the next page", .{ .size = 11, .color = menu.secondary(dark) });
        c.end();
    }
    if (controls.switch_(c, p, &st.sound, "Play Sound by Itself")) config.setAutoplay(&b.kea.store, st.sound, host);
}

/// A line holding a title and, at its end, a switch; the caller ends it.
fn line(c: *ui.Context, title: []const u8, dark: bool) u32 {
    const i = c.open(.{ .direction = .row, .width = .fill, .height = px(menu.row), .align_items = .center, .padding = .{ .left = menu.text, .right = menu.trailing } }, null);
    ui.text(c, title, .{ .size = menu.font, .color = menu.label(dark) });
    _ = c.leaf(.{ .grow = 1, .min_width = 24 }, .none, null);
    return i;
}

// MARK: one step in

fn security(b: *Browser, c: *ui.Context, t: *Tab, s: Safety, dark: bool) void {
    const st = &b.site_card;
    if (pageAddress(t)) |url| header(c, site(url), dark);
    _ = c.open(.{ .height = px(menu.row), .justify = .center, .padding = .{ .left = menu.text } }, null);
    ui.text(c, s.title, .{ .size = menu.font, .color = menu.label(dark) });
    c.end();
    _ = c.open(.{ .padding = .{ .left = menu.text, .right = menu.trailing, .bottom = 6 } }, null);
    _ = c.open(.{ .width = px(230) }, null);
    ui.text(c, s.detail, .{ .size = 11, .color = menu.secondary(dark), .wrap = true });
    c.end();
    c.end();
    separator(c, dark);
    if (s.trust != null) {
        if (row(c, if (st.certified == false) "Show Certificate (Not Valid)…" else "Show Certificate…", "", false, dark)) after(b, t, showCertificate);
    }
    if (row(c, "Back", "", false, dark)) {
        st.deeper = false;
        c.changed = true;
    }
}

// MARK: drawn as a menu draws

/// One line, as a menu item draws it: the accent behind it and white
/// letters under the pointer; one that opens more ends in a chevron.
/// True when clicked.
fn row(c: *ui.Context, title: []const u8, keys: []const u8, submenu: bool, dark: bool) bool {
    const outer = c.open(.{ .width = .fill, .padding = .{ .left = menu.inset, .right = menu.inset }, .control = true }, null);
    defer c.end();
    const it = c.interact(outer, .{});
    c.addA11y(outer, .button, title, "", false, true);
    const lit = it.hovered;
    _ = c.open(.{
        .direction = .row,
        .width = .fill,
        .height = px(menu.row),
        .align_items = .center,
        .padding = .{ .left = menu.text - menu.inset, .right = menu.trailing - menu.inset },
        .radius = menu.highlight,
        .background = if (lit) menu.selection(dark) else null,
    }, null);
    defer c.end();
    const ink = if (lit) ui.Color.white else menu.label(dark);
    const soft = if (lit) ui.Color.white else menu.secondary(dark);
    ui.text(c, title, .{ .size = menu.font, .color = ink });
    _ = c.leaf(.{ .grow = 1, .min_width = if (keys.len == 0) 24 else 26 }, .none, null);
    if (keys.len > 0) ui.text(c, keys, .{ .size = menu.font, .color = soft });
    if (submenu) ui.icon(c, "chevron.right", .{ .size = 10, .weight = .semibold, .color = soft });
    return it.clicked;
}

/// The site's name over the lines, as a menu's section header.
fn header(c: *ui.Context, title: []const u8, dark: bool) void {
    _ = c.open(.{ .height = px(menu.row), .justify = .center, .padding = .{ .left = menu.text, .right = menu.trailing } }, null);
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = menu.secondary(dark), .truncate = true });
    c.end();
}

/// A menu's separator: a hairline in its own band.
fn separator(c: *ui.Context, dark: bool) void {
    _ = c.open(.{ .width = .fill, .height = px(menu.separator), .justify = .center, .padding = .{ .left = menu.rule, .right = menu.rule } }, null);
    _ = c.leaf(.{ .width = .fill, .height = px(1), .background = menu.separatorColor(dark) }, .none, null);
    c.end();
}

/// A step of the zoom: the symbol alone, on the accent under the pointer.
fn step(c: *ui.Context, symbol: []const u8, help: []const u8, dark: bool) bool {
    const i = c.open(.{ .width = px(22), .height = px(18), .radius = 5, .align_items = .center, .justify = .center, .control = true }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.help(i, help);
    c.addA11y(i, .button, help[0 .. std.mem.indexOf(u8, help, "   ") orelse help.len], "", false, true);
    if (it.hovered) c.node(i).style.background = menu.selection(dark);
    ui.icon(c, symbol, .{ .size = 11, .weight = .semibold, .color = if (it.hovered) ui.Color.white else menu.label(dark) });
    return it.clicked;
}

test "site names a page as a person says it" {
    const t = std.testing;
    try t.expectEqualStrings("example.com", site("https://www.example.com/a"));
    try t.expectEqualStrings("kea.app", site("http://kea.app"));
    try t.expectEqualStrings("File", site("file:///Users/kea/a.html"));
    try t.expectEqualStrings("about", site("about:blank"));
}
