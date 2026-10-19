//! Immediate-mode `nanoui` chrome view (`Browser.view`): renders Sidebar,
//! Top TabBar, BookmarksBar, Split View stage holes + 7 pt `PaneDivider`,
//! the Bookmarks side panel with 9 pt `EdgeHandle` drag strips, floating
//! opaque Omnibox dropdown (with Gaussian shadow), FindBar, and shortcuts.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const panels = @import("panels.zig");
const drawEdgeHandle = panels.drawEdgeHandle;
const drawMarksPanel = panels.drawMarksPanel;
const drawOmniboxOverlay = panels.drawOmniboxOverlay;
const drawFindBar = panels.drawFindBar;

pub const Palette = struct {
    ground: ui.Color,
    frame: ui.Color,
    wash: ui.Color,
    ink: ui.Color,
    muted: ui.Color,
    faint: ui.Color,
    hairline: ui.Color,
    accent: ui.Color,

    pub fn forTheme(dark: bool) Palette {
        return if (dark) .{
            .ground = ui.Color.hex(0x1C1B19),
            .frame = ui.Color.hex(0x141312),
            .wash = ui.Color.hex(0x282623),
            .ink = ui.Color.hex(0xF5F2EB),
            .muted = ui.Color.hex(0xA09A90),
            .faint = ui.Color.hex(0x6E6A63),
            .hairline = ui.Color.hex(0x33302C),
            .accent = ui.Color.hex(0xD97757),
        } else .{
            .ground = ui.Color.hex(0xFAF8F5),
            .frame = ui.Color.hex(0xF1EDE7),
            .wash = ui.Color.hex(0xE6E0D6),
            .ink = ui.Color.hex(0x1C1B19),
            .muted = ui.Color.hex(0x6E6A63),
            .faint = ui.Color.hex(0x9E988E),
            .hairline = ui.Color.hex(0xD8D2C9),
            .accent = ui.Color.hex(0xC96442),
        };
    }
};

pub fn view(b: *Browser, c: *ui.Context) void {
    const pal = Palette.forTheme(c.theme.dark);
    handleShortcuts(b, c);

    // Root column: Top TabBar (when !sidebar), BookmarksBar, and Main Horizontal Row
    ui.column(c, .{ .width = .fill, .height = .fill });
    defer ui.end(c);

    if (!b.prefs.sidebar) {
        drawTopBar(b, c, pal);
    }
    if (b.prefs.shows_bookmarks_bar) {
        drawBookmarksBar(b, c, pal);
    }

    // Main horizontal row: Left panels/sidebar + Center Stage + Right panels/sidebar
    ui.row(c, .{ .width = .fill, .grow = 1 });
    {
        if (b.prefs.sidebar and b.prefs.side_position == .left) {
            drawSideBar(b, c, pal, true);
        }
        if (b.marks_open and !b.prefs.marks_popped and b.prefs.effectiveMarksSide() == .left and !b.marks_expanded) {
            drawMarksPanel(b, c, pal, true);
        }

        // Center Stage (WebKit panes + overlays)
        drawStageArea(b, c, pal);

        if (b.marks_open and !b.prefs.marks_popped and b.prefs.effectiveMarksSide() == .right and !b.marks_expanded) {
            drawMarksPanel(b, c, pal, false);
        }
        if (b.prefs.sidebar and b.prefs.side_position == .right) {
            drawSideBar(b, c, pal, false);
        }
    }
    ui.end(c);
}

fn handleShortcuts(b: *Browser, c: *ui.Context) void {
    if (c.shortcut(.{ .key = 't', .cmd = true, .shift = true })) {
        b.reopenClosedTab();
    } else if (c.shortcut(.{ .key = 't', .cmd = true })) {
        _ = b.openTab("", true, false);
        b.omni_open = true;
        b.omni_buf.clear();
    } else if (c.shortcut(.{ .key = 'w', .cmd = true })) {
        if (b.activeTab()) |t| b.closeTab(t.id);
    } else if (c.shortcut(.{ .key = 'l', .cmd = true })) {
        b.omni_open = true;
        if (b.activeTab()) |t| b.omni_buf.set(t.url());
    } else if (c.shortcut(.{ .key = 'r', .cmd = true })) {
        if (b.activeTab()) |t| t.reload();
    } else if (c.shortcut(.{ .key = '.', .cmd = true })) {
        if (b.activeTab()) |t| t.stopLoading();
    } else if (c.shortcut(.{ .key = 'f', .cmd = true })) {
        b.find_open = !b.find_open;
    } else if (c.shortcut(.{ .key = 's', .cmd = true, .ctrl = true })) {
        b.prefs.setSidebar(!b.prefs.sidebar);
        b.syncStageHost();
    } else if (c.shortcut(.{ .key = 'b', .cmd = true, .ctrl = true })) {
        b.marks_open = !b.marks_open;
        b.syncStageHost();
    } else if (c.shortcut(.{ .key = 'b', .cmd = true, .shift = true })) {
        b.prefs.shows_bookmarks_bar = !b.prefs.shows_bookmarks_bar;
        b.prefs.setBool("bookmarks.bar", b.prefs.shows_bookmarks_bar);
    } else if (c.shortcut(.{ .key = 'd', .cmd = true })) {
        if (b.activeTab()) |t| {
            const added = b.bookmarks.toggleUrl(t.title(), t.url());
            b.announce(if (added) "Bookmark added" else "Bookmark removed");
        }
    } else if (c.shortcut(.{ .key = '[', .cmd = true })) {
        if (b.activeTab()) |t| t.goBack();
    } else if (c.shortcut(.{ .key = ']', .cmd = true })) {
        if (b.activeTab()) |t| t.goForward();
    } else if (c.shortcut(.{ .key = '\t', .ctrl = true, .shift = true })) {
        b.stepTab(-1);
    } else if (c.shortcut(.{ .key = '\t', .ctrl = true })) {
        b.stepTab(1);
    } else if (c.shortcut(.{ .key = 0x1b })) {
        if (b.omni_open) {
            b.omni_open = false;
            b.omni_chip = null;
        } else if (b.find_open) {
            b.find_open = false;
        } else if (b.activeTab()) |t| {
            if (t.loading) t.stopLoading();
        }
    }
}

fn drawTopBar(b: *Browser, c: *ui.Context, pal: Palette) void {
    ui.row(c, .{
        .width = .fill,
        .height = .{ .px = 42 },
        .background = pal.frame,
        .padding = .{ .left = 78, .right = 10, .top = 5, .bottom = 5 },
        .align_items = .center,
        .gap = 6,
    });
    defer ui.end(c);

    const active = b.activeTab();
    if (ui.button(c, "", .{ .variant = .ghost, .icon = "chevron.left", .size = 13, .disabled = active == null or !active.?.can_go_back }).clicked) {
        if (active) |t| t.goBack();
    }
    if (ui.button(c, "", .{ .variant = .ghost, .icon = "chevron.right", .size = 13, .disabled = active == null or !active.?.can_go_forward }).clicked) {
        if (active) |t| t.goForward();
    }
    const is_loading = active != null and active.?.loading;
    if (ui.button(c, "", .{ .variant = .ghost, .icon = if (is_loading) "xmark" else "arrow.clockwise", .size = 13 }).clicked) {
        if (active) |t| {
            if (t.loading) t.stopLoading() else t.reload();
        }
    }

    // Address pill button in top bar
    const addr_label = if (active) |t| (if (t.url().len > 0) t.url() else t.title()) else "Search or enter address";
    const addr_it = ui.pressable(c, .{
        .direction = .row,
        .width = .{ .px = 320 },
        .height = .{ .px = 30 },
        .padding = .xy(10, 4),
        .radius = 9,
        .background = pal.ground,
        .border = pal.hairline,
        .align_items = .center,
        .gap = 6,
    }, pal.wash);
    c.addA11y(c.stack.items[c.stack.items.len - 1], .button, "Address and search bar", addr_label, false, true);
    if (addr_it.clicked) {
        b.omni_open = true;
        if (active) |t| b.omni_buf.set(t.url());
    }
    ui.icon(c, "magnifyingglass", .{ .size = 12, .color = pal.muted });
    ui.text(c, addr_label, .{ .size = 13, .color = pal.ink });
    ui.end(c);

    // Tab strip pills
    ui.row(c, .{ .grow = 1, .height = .fill, .align_items = .center, .gap = 4 });
    for (b.tabs.items, 0..) |t, idx| {
        ui.key(c, c.print("top-tab-{d}", .{t.id}));
        const selected = t.id == b.active_id or (b.split_right_id != null and t.id == b.split_right_id.?);
        const pill_it = ui.pressable(c, .{
            .direction = .row,
            .width = .{ .px = 150 },
            .height = .{ .px = 30 },
            .padding = .xy(10, 4),
            .radius = 8,
            .background = if (selected) pal.ground else pal.wash.alpha(0.5),
            .shadow = if (selected) .{ .color = .{ .a = 0.08 }, .blur = 4, .y = 1 } else null,
            .align_items = .center,
            .gap = 6,
        }, pal.wash);
        c.addA11y(c.stack.items[c.stack.items.len - 1], .tab, t.title(), "", selected, true);
        if (pill_it.clicked) b.selectTab(t.id);
        ui.textf(c, .{ .size = 12.5, .weight = if (selected) .medium else .regular, .color = pal.ink }, "{s}", .{t.title()});
        ui.spacer(c);
        ui.key(c, c.print("top-close-{d}", .{idx}));
        if (ui.button(c, "", .{ .variant = .ghost, .icon = "xmark", .size = 10 }).clicked) {
            b.closeTab(t.id);
        }
        ui.end(c);
    }
    if (ui.button(c, "", .{ .variant = .ghost, .icon = "plus", .size = 13 }).clicked) {
        _ = b.openTab("", true, false);
    }
    ui.end(c);

    if (ui.button(c, "", .{ .variant = .ghost, .icon = "book", .size = 13 }).clicked) {
        b.marks_open = !b.marks_open;
        b.syncStageHost();
    }
}

fn drawBookmarksBar(b: *Browser, c: *ui.Context, pal: Palette) void {
    ui.row(c, .{
        .width = .fill,
        .height = .{ .px = 28 },
        .background = pal.frame,
        .padding = .xy(12, 2),
        .align_items = .center,
        .gap = 6,
    });
    defer ui.end(c);
    for (b.bookmarks.items.items, 0..) |bm, idx| {
        ui.key(c, c.print("bm-bar-{d}", .{idx}));
        if (ui.button(c, bm.title, .{ .variant = .ghost, .size = 12, .icon = "bookmark" }).clicked) {
            if (bm.url) |u| b.goUrl(u);
        }
    }
}

fn drawSideBar(b: *Browser, c: *ui.Context, pal: Palette, on_left: bool) void {
    if (!on_left) drawEdgeHandle(b, c, pal, &b.prefs.side_width, 176, 360, 220, false, "sidebar");

    ui.column(c, .{
        .width = .{ .px = b.prefs.side_width },
        .height = .fill,
        .background = pal.frame,
        .padding = .{ .top = if (on_left) 38 else 10, .left = 8, .right = 8, .bottom = 10 },
        .gap = 6,
    });
    {
        const active = b.activeTab();
        ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 4 });
        if (ui.button(c, "", .{ .variant = .ghost, .icon = "chevron.left", .size = 12, .disabled = active == null or !active.?.can_go_back }).clicked) {
            if (active) |t| t.goBack();
        }
        if (ui.button(c, "", .{ .variant = .ghost, .icon = "chevron.right", .size = 12, .disabled = active == null or !active.?.can_go_forward }).clicked) {
            if (active) |t| t.goForward();
        }
        ui.spacer(c);
        const loading = active != null and active.?.loading;
        if (ui.button(c, "", .{ .variant = .ghost, .icon = if (loading) "xmark" else "arrow.clockwise", .size = 12 }).clicked) {
            if (active) |t| {
                if (t.loading) t.stopLoading() else t.reload();
            }
        }
        ui.end(c);

        const addr_label = if (active) |t| (if (t.url().len > 0) t.url() else t.title()) else "Search or enter address";
        if (ui.button(c, addr_label, .{ .width = .fill, .variant = .secondary, .icon = "magnifyingglass", .size = 12.5 }).clicked) {
            b.omni_open = true;
            if (active) |t| b.omni_buf.set(t.url());
        }

        ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 2 });
        for (b.tabs.items, 0..) |t, idx| {
            ui.key(c, c.print("side-tab-{d}", .{t.id}));
            const selected = t.id == b.active_id or (b.split_right_id != null and t.id == b.split_right_id.?);
            const row_it = ui.pressable(c, .{
                .direction = .row,
                .width = .fill,
                .height = .{ .px = 30 },
                .padding = .xy(8, 5),
                .radius = 8,
                .background = if (selected) pal.ground else null,
                .shadow = if (selected) .{ .color = .{ .a = 0.08 }, .blur = 4, .y = 1 } else null,
                .align_items = .center,
                .gap = 8,
            }, pal.wash);
            c.addA11y(c.stack.items[c.stack.items.len - 1], .tab, t.title(), "", selected, true);
            if (row_it.clicked) b.selectTab(t.id);
            ui.icon(c, "globe", .{ .size = 12.5, .color = if (selected) pal.ink else pal.muted });
            ui.textf(c, .{ .size = 13, .weight = if (selected) .medium else .regular, .color = pal.ink }, "{s}", .{t.title()});
            ui.spacer(c);
            ui.key(c, c.print("side-close-{d}", .{idx}));
            if (ui.button(c, "", .{ .variant = .ghost, .icon = "xmark", .size = 10 }).clicked) {
                b.closeTab(t.id);
            }
            ui.end(c);
        }
        if (ui.button(c, "New Tab", .{ .width = .fill, .variant = .ghost, .icon = "plus", .size = 12.5 }).clicked) {
            _ = b.openTab("", true, false);
        }
        ui.end(c);

        // SideFoot
        ui.row(c, .{ .width = .fill, .height = .{ .px = 28 }, .align_items = .center, .gap = 6 });
        if (ui.button(c, "", .{ .variant = .ghost, .icon = "book", .size = 13 }).clicked) {
            b.marks_open = !b.marks_open;
            b.syncStageHost();
        }
        ui.spacer(c);
        ui.end(c);
    }
    ui.end(c);

    if (on_left) drawEdgeHandle(b, c, pal, &b.prefs.side_width, 176, 360, 220, true, "sidebar");
}
fn drawStageArea(b: *Browser, c: *ui.Context, pal: Palette) void {
    const split_tab = if (b.prefs.split_view and b.split_right_id != null) b.tabById(b.split_right_id.?) else null;
    const framed = b.prefs.sidebar or b.marks_open or split_tab != null;
    const pad: f32 = if (framed) 6 else 0;

    ui.column(c, .{
        .grow = 1,
        .height = .fill,
        .padding = .all(pad),
        .background = if (framed) pal.frame else null,
    });
    defer ui.end(c);

    if (b.find_open) drawFindBar(b, c, pal);

    ui.row(c, .{ .width = .fill, .grow = 1 });
    {
        const left_tab = b.tabById(b.active_id);
        drawPaneBox(b, c, pal, left_tab, "stage-left", if (split_tab != null) b.split_fraction else 1.0, true);

        if (split_tab) |rt| {
            // 7 pt PaneDivider
            const div_idx = c.open(.{ .width = .{ .px = 7 }, .height = .fill, .align_items = .center, .justify = .center }, "split-divider");
            const div_it = c.interact(div_idx, .{});
            c.addA11y(div_idx, .splitter, "Split View divider", "", false, true);
            if (div_it.hovered or div_it.pressed) c.cursor = .resize_left_right;
            if (div_it.double_clicked) {
                b.evenSplit();
            } else if (div_it.pressed) {
                const total_w = @max(100, b.left_pane_frame.w + b.right_pane_frame.w);
                const rel_x = c.input.mouse.x - b.left_pane_frame.x;
                b.split_fraction = std.math.clamp(rel_x / total_w, 0.2, 0.8);
                c.changed = true;
            }
            _ = c.leaf(.{ .width = .{ .px = 2 }, .height = .{ .px = 36 }, .radius = 1, .background = pal.muted }, .none, null);
            c.end();

            drawPaneBox(b, c, pal, rt, "stage-right", 1.0 - b.split_fraction, false);
        }
    }
    ui.end(c);
}

fn drawPaneBox(b: *Browser, c: *ui.Context, pal: Palette, tab_opt: ?*Tab, key_name: []const u8, grow_weight: f32, is_left: bool) void {
    const idx = c.open(.{
        .grow = @max(0.1, grow_weight),
        .height = .fill,
        .radius = 10,
        .padding = .all(16),
        .align_items = .center,
    }, key_name);
    defer c.end();

    if (!b.marks_expanded) {
        c.addStageHoleNode(idx);
    }

    // Floating opaque Omnibox card (with Gaussian shadow, never .glass over the page)
    if (is_left and b.omni_open) {
        drawOmniboxOverlay(b, c, pal);
    }

    if (tab_opt) |t| {
        if (t.failure()) |err_msg| {
            const card_it = ui.pressable(c, .{
                .direction = .column,
                .width = .{ .px = 380 },
                .padding = .all(20),
                .radius = 12,
                .background = pal.ground,
                .border = pal.hairline,
                .shadow = .{ .color = .{ .a = 0.16 }, .blur = 24, .y = 6 },
                .align_items = .center,
                .gap = 10,
            }, null);
            _ = card_it;
            ui.text(c, err_msg, .{ .size = 14, .color = pal.ink, .wrap = true });
            if (ui.button(c, "Try again", .{ .variant = .secondary, .icon = "arrow.clockwise", .size = 12.5 }).clicked) {
                t.reload();
            }
            ui.end(c);
        } else if (t.question) |*q| {
            const q_it = ui.pressable(c, .{
                .direction = .column,
                .width = .{ .px = 340 },
                .padding = .all(16),
                .radius = 12,
                .background = pal.ground,
                .border = pal.hairline,
                .shadow = .{ .color = .{ .a = 0.18 }, .blur = 24, .y = 6 },
                .gap = 10,
            }, null);
            _ = q_it;
            ui.text(c, q.text(), .{ .size = 13.5, .color = pal.ink, .wrap = true });
            if (q.kind == .prompt) {
                _ = ui.textField(c, &q.input_buf, .{ .width = .fill });
            }
            ui.row(c, .{ .width = .fill, .justify = .end, .gap = 8 });
            if (q.kind != .alert) {
                if (ui.button(c, "Cancel", .{ .variant = .secondary, .size = 12.5 }).clicked) t.answerDialog(false, null);
            }
            if (ui.button(c, "OK", .{ .variant = .primary, .size = 12.5 }).clicked) t.answerDialog(true, null);
            ui.end(c);
            ui.end(c);
        }
    }
}
