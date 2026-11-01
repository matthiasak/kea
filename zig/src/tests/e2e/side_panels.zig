//! P8.8: the bookmarks popped into a window of their own (`PanelWindow`):
//! a titled panel off every screen in a test run, and closing it by its
//! button hides the sidebar.
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "popped bookmarks window is hidden and closing it hides the sidebar", .run = poppedMarks },
    .{ .name = "web side panel hosts a page and Open in a Tab keeps it", .run = webSidePanel },
};

fn poppedMarks(h: *Harness) !void {
    const b = try h.start();
    const k = h.kea.?;
    b.prefs.set("bookmarks_sidebar", true);
    app.side_panels.togglePopped(b, .bookmarks);
    h.frame();
    const m = k.marks_window orelse return h.fail("no bookmarks window", .{});
    const w = m.window orelse return h.fail("a record without a window", .{});
    const ns = w.nswindow;
    const f = objc.msg(objc.CGRect, ns, "frame", .{});
    try h.expect(!objc.msg(objc.BOOL, ns, "isVisible", .{}) and f.origin.x < -10000, "visible or on screen at {d},{d}", .{ f.origin.x, f.origin.y });
    try h.expect(f.size.width == 280 and f.size.height == 560, "frame {d}x{d}, want 280x560", .{ f.size.width, f.size.height });
    // Its close button, as `windowWillClose` hears it.
    objc.msg(void, ns, "performClose:", .{@as(?objc.Object, null)});
    // The browsers' redraw it asked for runs (a surface with a tick due outlives `quit`).
    h.pump(0.05);
    try h.expect(k.marks_window == null, "the record outlived its window", .{});
    try h.expect(!b.prefs.bookmarks_sidebar, "closing the window left the sidebar asked for", .{});
}

fn webSidePanel(h: *Harness) !void {
    const b = try h.start();
    const before = b.tabs.items.len;
    app.side_panels.openWebPanel(b, "kea-test://site/page?title=SideWeb&body=Hello");
    h.frame();
    const pt = b.web_panel_tab orelse return h.fail("no web_panel_tab", .{});
    try h.expect(b.stage_host.?.holds(pt.web.?), "stage_host does not hold web_panel_tab", .{});
    app.side_panels.keepWebPanelAsTab(b);
    h.frame();
    try h.expect(b.web_panel_tab == null, "web_panel_tab still open after keepWebPanelAsTab", .{});
    try h.expect(b.tabs.items.len == before + 1, "tabs count {d}, want {d}", .{ b.tabs.items.len, before + 1 });
}
