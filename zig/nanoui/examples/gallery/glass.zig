//! The gallery's Glass page: Liquid Glass with motion. A toolbar of glass
//! springs in over cards that scroll under it and stagger in; glass tabs
//! whose tinted lens slides; glass buttons that give when pressed and
//! bounce back; a glass menu and glass toasts; and a pane of clear glass
//! floating over it all.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const motion = ui.motion;

pub const Demo = struct {
    taps: u32 = 0,
    tab: usize = 0,
    menu: bool = false,
    menu_at: ?ui.Rect = null,
    toaster: kit.Toaster = undefined,
    ready: bool = false,

    pub fn view(d: *Demo, c: *ui.Context) void {
        if (!d.ready) {
            d.toaster = .{ .gpa = std.heap.page_allocator, .glass = true, .corner = .bottom_right };
            d.ready = true;
        }
        const th = c.theme;
        // The page's width: beside the sidebar, or all of a phone's.
        const compact = @import("phone.zig").compact(c);
        const w = if (compact) c.size.w else c.size.w - 200;
        const page = ui.div(c).grow().hFull().clip();
        defer page.end();
        {
            const content = ui.div(c).column().sizeFull().scrollY().px(28).pt(96).pb(28).gap(14);
            defer content.end();
            const hues = [_]u24{ 0xe8453c, 0xf2a93b, 0x3fae5a, 0x2f6fd0, 0x8e44ad, 0x16a3a3 };
            const labels = [_][]const u8{ "Photos", "Albums", "Search" };
            for (0..18) |i| {
                ui.key(c, c.print("card-{d}-{d}", .{ d.tab, i }));
                // Each tab's cards come in one after another.
                const f = motion.frame(c, .{ .initial = .{ .y = 24, .opacity = 0, .scale = 0.97 }, .delay = motion.stagger(@min(i, 8), 0.04), .transition = .{ .spring = .{} } });
                const card = ui.div(c).row().wFull().h(64).px(18).gap(12).itemsCenter().rounded(16).bg(.hex(hues[(i + d.tab * 2) % hues.len])).motion(f);
                defer card.end();
                ui.icon(c, "photo", .{ .size = 18, .color = .white });
                ui.textf(c, .{ .size = 15, .weight = .semibold, .color = .white }, "{s} under the glass · {d}", .{ labels[d.tab], i + 1 });
            }
        }
        {
            const f = motion.frame(c, .{ .initial = .{ .y = -30, .opacity = 0, .scale = 0.96 }, .transition = .{ .spring = motion.Spring.bouncy } });
            const bar = ui.div(c).absolute().offset(20, 20).w(w - 40).h(60).row().itemsCenter().gap(10).px(10).rounded(30).glass(.{}).motion(f);
            defer bar.end();
            _ = kit.tabs(c, &.{ "Photos", "Albums", "Search" }, &d.tab, .{ .variant = .glass });
            ui.spacer(c);
            if (!compact) ui.label(c, c.print("{d} taps", .{d.taps}));
            const m = kit.iconButton(c, "ellipsis", .{ .glass = true, .pill = true });
            if (m.clicked) d.menu = !d.menu;
            d.menu_at = m.rect;
            if (!compact and kit.button(c, "Tap", .{ .glass = true, .variant = .primary, .pill = true }).clicked) d.taps += 1;
        }
        {
            // A pane of clear glass, floating.
            const float = motion.keyframes(c, .{ .values = &.{ .{ .y = 0 }, .{ .y = -10 }, .{ .y = 0 } }, .duration = 4, .repeat = null });
            const pane = ui.div(c).absolute().offset(w - @as(f32, if (compact) 170 else 180), 150).w(140).h(140).rounded(36).glass(.{ .style = .clear }).itemsCenter().justifyCenter().control().motion(float);
            defer pane.end();
            if (pane.clicked()) d.toaster.push(.{ .status = .info, .title = "Clear glass", .message = "It floats over whatever scrolls under it.", .duration = 3 });
            ui.text(c, "Clear", .{ .size = 15, .weight = .semibold, .color = .white });
        }
        if (kit.menu(c, "glass-menu", &d.menu, d.menu_at, &.{
            .{ .label = "Share", .icon = "square.and.arrow.up" },
            .{ .label = "Favorite", .icon = "heart" },
            .{ .separator = true },
            .{ .label = "Show a toast", .icon = "bell" },
        }, .{ .glass = true, .placement = .bottom_end, .width = 200 })) |i| {
            if (i == 3) d.toaster.push(.{ .status = .success, .title = "On glass", .message = "Toasts can be glass too.", .duration = 3 });
        }
        d.toaster.view(c);
        _ = th;
    }
};
