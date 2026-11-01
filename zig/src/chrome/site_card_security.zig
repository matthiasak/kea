//! The connection's safety and certificate check for `site_card.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const menu = @import("../design/menu.zig");
const Parts = @import("../data/url.zig").Parts;
const dispatch = @import("../sys/dispatch.zig");
const cg = @import("../sys/cg.zig");
const site_card = @import("site_card.zig");
const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

pub const Safety = struct {
    title: []const u8,
    detail: []const u8,
    /// The certificate the page came with, for an https page.
    trust: ?*anyopaque,
};

/// `safety`: what there is to say about the connection.
pub fn safety(t: *const Tab, certified: ?bool) ?Safety {
    const p = Parts.parse(site_card.pageAddress(t) orelse return null) orelse return null;
    if (p.schemeIs("https")) {
        const trust = serverTrust(t);
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

pub fn serverTrust(t: *const Tab) ?*anyopaque {
    const wv = t.web orelse return null;
    return @ptrCast(objc.msg(?objc.Object, wv, "serverTrust", .{}));
}

extern "c" fn SecTrustEvaluateWithError(trust: *anyopaque, err: ?*?*anyopaque) bool;
extern "c" fn CFRetain(object: *anyopaque) *anyopaque;

const Certify = struct {
    serial: u64,
    trust: *anyopaque,
    ok: bool = false,

    fn ask(ctx: ?*anyopaque) callconv(.c) void {
        const pool = objc.Pool.push();
        defer pool.pop();
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

pub fn certify(t: *Tab) void {
    const trust = serverTrust(t) orelse return;
    const job = std.heap.c_allocator.create(Certify) catch return;
    job.* = .{ .serial = t.serial, .trust = CFRetain(trust) };
    dispatch.dispatch_async_f(dispatch.dispatch_get_global_queue(dispatch.qos_user_initiated, 0), job, Certify.ask);
}

/// The system's own certificate sheet, over the window. Never in tests.
pub fn showCertificate(t: *Tab) void {
    const b = t.browser orelse return;
    if (b.kea.opts.root != null or b.kea.opts.hidden) return;
    const w = b.window orelse return;
    const trust = serverTrust(t) orelse return;
    const panel = objc.msg(objc.Object, objc.class("SFCertificatePanel"), "sharedCertificatePanel", .{});
    objc.msg(void, panel, "beginSheetForWindow:modalDelegate:didEndSelector:contextInfo:trust:showGroup:", .{
        w.nswindow, @as(?objc.Object, null), @as(?objc.SEL, null), @as(?*anyopaque, null), trust, objc.NO,
    });
}

pub fn security(b: *Browser, c: *ui.Context, t: *Tab, s: Safety, dark: bool) void {
    const st = &b.site_card;
    if (site_card.pageAddress(t)) |url| site_card.header(c, site_card.site(url), dark);
    _ = c.open(.{ .height = px(menu.row), .justify = .center, .padding = .{ .left = menu.text } }, null);
    ui.text(c, s.title, .{ .size = menu.font, .color = menu.label(dark) });
    c.end();
    _ = c.open(.{ .padding = .{ .left = menu.text, .right = menu.trailing, .bottom = 6 } }, null);
    _ = c.open(.{ .width = px(230) }, null);
    ui.text(c, s.detail, .{ .size = 11, .color = menu.secondary(dark), .wrap = true });
    c.end();
    c.end();
    site_card.separator(c, dark);
    if (s.trust != null) {
        if (site_card.row(c, if (st.certified == false) "Show Certificate (Not Valid)…" else "Show Certificate…", "", false, dark)) site_card.after(b, t, showCertificate);
    }
    if (site_card.row(c, "Back", "", false, dark)) {
        st.deeper = false;
        c.changed = true;
    }
}
