//! P8.8: the side panels (SidePanels.swift) — carried by the header,
//! let out over the page, sized by their edge, popped into a window.
const std = @import("std");
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

const gpa = std.testing.allocator;
const t = std.testing;

/// The bookmarks open in their column, in the strip's layout (on the right).
fn openMarks(f: *Fixture) !void {
    try f.init(gpa, .{ .sidebar = false });
    f.kea.prefs.set("bookmarks_sidebar", true);
    f.tester.settle(1);
}

/// A point on the header's title, in the column on the right: the title
/// may be cut short at 232 points, so found by the Manage pill's line.
fn header(f: *Fixture) !struct { x: f32, y: f32 } {
    const m = f.tester.findText("Manage") orelse return error.NoHeader;
    return .{ .x = 1440 - f.kea.prefs.marks_width + 18, .y = m.y + m.h / 2 };
}

test "side panel header drag past midpoint flips side" {
    var f: Fixture = undefined;
    try openMarks(&f);
    defer f.deinit();
    try t.expect(!app.side_panels.panelOnLeft(f.browser, .bookmarks));
    try t.expectApproxEqAbs(@as(f32, 0), f.holes()[0].x, 0.5);
    const h = try header(&f);
    // Not past the middle: it stays.
    f.tester.drag(h.x, h.y, 800, h.y);
    try t.expect(!app.side_panels.panelOnLeft(f.browser, .bookmarks));
    f.tester.drag(h.x, h.y, 200, h.y);
    try t.expect(f.kea.prefs.marks_side.? == .left);
    f.tester.settle(1);
    // The page now starts past the panel.
    try t.expectApproxEqAbs(f.kea.prefs.marks_width, f.holes()[0].x, 0.5);
}

test "side panel header double-click lets it out at most 760 wide" {
    var f: Fixture = undefined;
    try openMarks(&f);
    defer f.deinit();
    const h = try header(&f);
    f.tester.doubleClick(h.x, h.y);
    try t.expectEqual(@as(?app.side_panels.SidePanel, .bookmarks), f.browser.expanded_panel);
    f.tester.settle(1);
    // Out of its column: the page has the window's width under it.
    try t.expectApproxEqAbs(@as(f32, 1440), f.holes()[0].w, 0.5);
    // Its content at most 760 wide, centred over the page.
    const title = f.tester.findText("Bookmarks").?;
    try t.expectApproxEqAbs(@as(f32, (1440 - 760) / 2 + 12), title.x, 1);
    // Esc puts it back.
    _ = f.press("\x1b", 53, .{});
    try t.expect(f.browser.expanded_panel == null);
}

test "side panel edge drag clamps to its range" {
    var f: Fixture = undefined;
    try openMarks(&f);
    defer f.deinit();
    const edge = 1440 - f.kea.prefs.marks_width + 4;
    f.tester.drag(edge, 400, edge - 500, 400);
    try t.expectEqual(@as(f32, 440), f.kea.prefs.marks_width);
    f.tester.settle(1);
    const wide = 1440 - 440 + 4;
    f.tester.drag(wide, 400, wide + 600, 400);
    try t.expectEqual(@as(f32, 176), f.kea.prefs.marks_width);
    // VoiceOver's increment: ten points wider (`accessibilityPerformIncrement`).
    f.tester.settle(1);
    const item = for (f.tester.ctx.a11y_items.items) |a| {
        if (std.mem.eql(u8, a.label, "Column width")) break a;
    } else return error.NoEdge;
    f.tester.ctx.a11yStep(item.id, 1);
    f.tester.frame();
    try t.expectEqual(@as(f32, 186), f.kea.prefs.marks_width);
}

test "popped bookmarks opens second window" {
    var f: Fixture = undefined;
    try openMarks(&f);
    defer f.deinit();
    try t.expect(f.kea.marks_window == null);
    app.side_panels.togglePopped(f.browser, .bookmarks);
    f.tester.settle(1);
    const w = f.kea.marks_window orelse return error.NoWindow;
    try t.expectEqual(app.side_panels.SidePanel.bookmarks, w.panel);
    // Out of the column: the page has its width back.
    try t.expectApproxEqAbs(@as(f32, 1440), f.holes()[0].w, 0.5);
    app.side_panels.togglePopped(f.browser, .bookmarks);
    f.tester.settle(1);
    try t.expect(f.kea.marks_window == null);
    try t.expectApproxEqAbs(@as(f32, 1440 - f.kea.prefs.marks_width), f.holes()[0].w, 0.5);
}

test "web side panel leaves non-overlapping stage holes and debug HUD captures clicks" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    app.side_panels.openWebPanel(f.browser, "https://example.com");
    f.tester.settle(1);
    const hs = f.holes();
    try t.expectEqual(@as(usize, 2), hs.len);
    try t.expect(hs[0].x + hs[0].w <= hs[1].x + 0.5);
    try t.expect(!f.tester.ctx.hitAt(.{ .x = hs[1].x + hs[1].w * 0.5, .y = hs[1].y + hs[1].h * 0.5 }));
    try t.expect(f.tester.ctx.inStageHoleAt(.{ .x = hs[1].x + hs[1].w * 0.5, .y = hs[1].y + hs[1].h * 0.5 }));

    app.commands.named("view.debugHud").?.run(f.browser);
    f.tester.settle(0.2);
    try t.expect(f.browser.debug_hud.shown);
    try t.expect(f.tester.ctx.hitAt(.{ .x = f.tester.size.w - 100, .y = 70 }));
    try f.tester.clickText("Copy");
    f.tester.settle(0.1);
    try t.expect(std.mem.indexOf(u8, f.tester.clipboard.items, "build ") != null);

    f.kea.prefs.set("sidebar", true);
    f.tester.settle(0.6);
    const hs_card = f.holes();
    try t.expectEqual(@as(usize, 2), hs_card.len);
    try t.expect(!f.tester.ctx.hitAt(.{ .x = hs_card[1].x + hs_card[1].w * 0.5, .y = hs_card[1].y + hs_card[1].h * 0.5 }));
    try t.expect(f.tester.ctx.inStageHoleAt(.{ .x = hs_card[1].x + hs_card[1].w * 0.5, .y = hs_card[1].y + hs_card[1].h * 0.5 }));
}

test "card mode side panels keep stage hole math and frame-1 expanded chat layout" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    const a = f.browser.openChat().?;
    a.listing = true;
    app.side_panels.toggleExpanded(f.browser, .chat);
    f.tester.frame();
    const sc = f.tester.findText("Search chats") orelse return error.MissingSearchChats;
    const comp = f.tester.findText("Ask, or type / or @…") orelse return error.MissingComposer;
    try t.expect(sc.x + sc.w < comp.x);
    try t.expect(f.holes().len >= 1);
    const h = f.holes()[0];
    try t.expect(h.w > 0 and h.h > 0 and h.x + h.w <= f.tester.size.w + 0.5);
}

test "bookmarks bar horizontal scroll keeps outer frame and bottom hairline anchored" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    for (0..16) |i| {
        var ubuf: [64]u8 = undefined;
        var tbuf: [32]u8 = undefined;
        const u = try std.fmt.bufPrint(&ubuf, "https://example.com/{d}", .{i});
        const title = try std.fmt.bufPrint(&tbuf, "Bookmark {d}", .{i});
        _ = f.kea.bookmarks.add(u, title);
    }
    f.kea.prefs.set("bookmarks_bar", true);
    f.tester.settle(0.6);
    const nodes = f.tester.ctx.nodes.items;
    const bar_idx = for (nodes, 0..) |n, idx| {
        if (n.style.scroll_x and n.rect.y < 80 and @abs(n.rect.h - 30) < 0.5) break idx;
    } else return error.MissingBookmarksBar;
    const bar_id = nodes[bar_idx].id;
    f.tester.ctx.setScroll(bar_id, .x, 120);
    f.tester.frame();
    const nodes2 = f.tester.ctx.nodes.items;
    const bar_idx2 = for (nodes2, 0..) |n, idx| {
        if (n.id == bar_id) break idx;
    } else return error.MissingBookmarksBarAfterScroll;
    const bn2 = nodes2[bar_idx2];
    const fr = nodes2[bn2.parent].rect;
    try t.expectApproxEqAbs(@as(f32, 0), fr.x, 0.5);
    try t.expectApproxEqAbs(f.tester.size.w, fr.w, 0.5);
    try t.expect(f.tester.ctx.scroll_x.get(bar_id).? > 0);
    try t.expect(bn2.next < nodes2.len);
    const ln = nodes2[bn2.next].rect;
    try t.expectApproxEqAbs(@as(f32, 1), ln.h, 0.5);
    try t.expectApproxEqAbs(@as(f32, 0), ln.x, 0.5);
    try t.expectApproxEqAbs(f.tester.size.w, ln.w, 0.5);
}

test "devtools HUD drags, collapses to compact mode, and snaps to corner" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = true });
    defer f.deinit();
    app.debug_hud.toggle(f.browser);
    f.tester.settle(0.4);
    const tr = f.tester.findText("Perf & DevTools") orelse return error.MissingHead;
    f.tester.drag(tr.x + 10, tr.y + tr.h * 0.5, 220, 160);
    try t.expect(f.browser.debug_hud.pos_x != null);
    try t.expect(f.browser.debug_hud.pos_y != null);
    f.tester.settle(0.3);
    const tr2 = f.tester.findText("Perf & DevTools") orelse return error.MissingHeadAfterDrag;
    f.tester.doubleClick(tr2.x + 10, tr2.y + tr2.h * 0.5);
    f.tester.frame();
    try t.expect(f.browser.debug_hud.compact);
    try t.expect(f.tester.hasText("Perf"));
    const snap = for (f.tester.ctx.a11y_items.items) |item| {
        if (std.mem.eql(u8, item.label, "Snap to Top Left")) break item;
    } else return error.MissingSnapDoor;
    const sr = f.tester.ctx.rects.get(snap.id) orelse return error.MissingSnapRect;
    f.tester.click(sr.x + sr.w * 0.5, sr.y + sr.h * 0.5);
    f.tester.settle(0.4);
    try t.expect(f.browser.debug_hud.pos_x == null);
    try t.expect(f.browser.debug_hud.left_corner);
}

test "bookmarks bar renders shaded category capsules and preserves horizontal scroll" {
    var f: Fixture = undefined;
    try f.init(gpa, .{ .sidebar = false });
    defer f.deinit();
    const cats = [_][]const u8{ "AI & ML", "EE & Chips", "Shopping", "Deals" };
    for (cats, 0..) |cat, ci| {
        for (0..6) |bi| {
            var ubuf: [64]u8 = undefined;
            var tbuf: [32]u8 = undefined;
            const u = try std.fmt.bufPrint(&ubuf, "https://example.com/{d}/{d}", .{ ci, bi });
            const title = try std.fmt.bufPrint(&tbuf, "Site {d}-{d}", .{ ci, bi });
            const id = f.kea.bookmarks.add(u, title).?;
            app.bookmarks_category.setCategory(&f.kea.bookmarks, id, cat);
        }
    }
    f.kea.prefs.set("bookmarks_bar", true);
    f.tester.settle(0.6);
    try t.expect(f.tester.hasText("AI & ML"));
    try t.expect(f.tester.hasText("EE & Chips"));
    const nodes = f.tester.ctx.nodes.items;
    var capsules: usize = 0;
    for (nodes) |n| {
        if (n.style.background != null and n.style.border != null and @abs(n.rect.h - 24) < 1.0 and n.rect.y < 80) {
            capsules += 1;
        }
    }
    try t.expect(capsules >= 2);
    const bar_idx = for (nodes, 0..) |n, idx| {
        if (n.style.scroll_x and n.rect.y < 80 and @abs(n.rect.h - 30) < 0.5) break idx;
    } else return error.MissingBookmarksBar;
    const bar_id = nodes[bar_idx].id;
    f.tester.ctx.setScroll(bar_id, .x, 90);
    f.tester.frame();
    const nodes2 = f.tester.ctx.nodes.items;
    const bar_idx2 = for (nodes2, 0..) |n, idx| {
        if (n.id == bar_id) break idx;
    } else return error.MissingBookmarksBarAfterScroll;
    const fr = nodes2[nodes2[bar_idx2].parent].rect;
    try t.expectApproxEqAbs(@as(f32, 0), fr.x, 0.5);
    try t.expectApproxEqAbs(f.tester.size.w, fr.w, 0.5);
    try t.expect(f.tester.ctx.scroll_x.get(bar_id).? > 0);
}
