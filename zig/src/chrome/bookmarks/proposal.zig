//! Organize with AI (AIBookmarks.swift 130-238): `organizeBookmarks`, an
//! instruction asked for and the list sent; `applyBookmarkProposal`; and
//! `BookmarkProposalView`, the proposal drawn in place of the manager's list.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Browser = @import("../../model/browser.zig").Browser;
const Kea = @import("../../app/kea.zig").Kea;
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const Bookmarks = bm.Bookmarks;
const Uuid = @import("../../data/json.zig").Uuid;
const Palette = @import("../../design/palette.zig").Palette;
const organize = @import("../../ai/organize.zig");
const ubi = @import("../../ai/ubi_chat.zig");
const appkit = @import("../../sys/appkit.zig");
const controls = @import("../controls.zig");
const plate = @import("../controls_plate.zig");
const ring = @import("../ring.zig");
const sheet = @import("../sheet.zig");
const outline = @import("outline.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// Organize with AI…, from the manager: an instruction asked for, then the
/// list sent. A window that isn't on screen (headless tests) is asked
/// nothing; they call `send`.
pub fn organizeBookmarks(b: *Browser) void {
    if (b.marks_ui.picks.organizing != null) return;
    const ready = ubi.ready(b.kea.ai, b) orelse return sheet.close(b, .bookmarking);
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (organize.refusal(a, b.bookmarks.roots, ready.provider) catch return) |says| return b.announce(says);
    if (b.kea.opts.headless) return;
    const count = Bookmarks.count(b.bookmarks.roots);
    const detail = organize.notice(a, b.kea.ai, ready.provider, count) catch return;
    const asked = std.heap.c_allocator.create(Asked) catch return;
    asked.* = .{ .kea = b.kea, .record = b.record_id };
    const window = if (b.window) |w| w.nswindow else null;
    appkit.ask(window, .{ .title = "Organize with AI", .detail = detail, .field = .{ .placeholder = organize.standing }, .confirm = "Organize" }, asked, Asked.done);
}

const Asked = struct {
    kea: *Kea,
    record: Uuid,

    fn done(self: *Asked, answer: appkit.Answer) void {
        defer std.heap.c_allocator.destroy(self);
        if (!answer.ok) return;
        for (self.kea.browsers.items) |b| if (b.record_id.eql(self.record)) return send(b, answer.text);
    }
};

/// The list sent with `typed` (empty: the standing instruction); "Asking …"
/// until the answer comes.
pub fn send(b: *Browser, typed: []const u8) void {
    const picks = &b.marks_ui.picks;
    if (picks.organizing != null) return;
    const ready = ubi.ready(b.kea.ai, b) orelse return;
    picks.dropProposal();
    picks.organizing = std.fmt.allocPrint(b.gpa, "Asking {s}\u{2026}", .{ready.provider.name}) catch return;
    organize.ask(b.kea.ai, b.bookmarks.roots, typed, ready.provider, ready.model, b, answered, &picks.organize_task);
    b.redraw();
}

fn answered(raw: *anyopaque, out: organize.Outcome) void {
    const b: *Browser = @ptrCast(@alignCast(raw));
    const picks = &b.marks_ui.picks;
    if (picks.organizing) |s| b.gpa.free(s);
    picks.organizing = null;
    switch (out) {
        .proposal => |p| picks.proposal = p,
        .says => |s| b.announce(s),
    }
    b.redraw();
}

/// The proposal applied: one change, undone with ⌘Z — unless the list
/// changed since it was asked.
pub fn apply(b: *Browser) void {
    const p = b.marks_ui.picks.proposal orelse return;
    b.marks_ui.picks.proposal = null;
    defer p.destroy();
    b.announce(organize.appliedSays(organize.apply(b.bookmarks, p)));
    b.redraw();
}

/// The "Asking …" row, with Stop.
pub fn asking(b: *Browser, c: *ui.Context, p: *const Palette, says: []const u8) void {
    ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
    defer ui.end(c);
    ring.ring(c, 16);
    ui.text(c, says, .{ .size = 12, .color = p.muted });
    ui.spacer(c);
    if (plate.quick(c, p, "Stop", null).clicked) press(b, .stop);
}

/// `BookmarkProposalView`: the list it would make, with what it would remove.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, proposal: *const organize.Proposal) void {
    ui.column(c, .{ .width = .fill, .gap = 10 });
    defer ui.end(c);
    const n = if (Bookmarks.folders(c.alloc(), proposal.tree)) |all| all.len else |_| 0;
    const removed = if (proposal.removed.len == 0) "" else c.print(" \u{00B7} {d} to remove", .{proposal.removed.len});
    const left = if (proposal.left_out == 0) "" else c.print(" \u{00B7} {d} left at the end", .{proposal.left_out});
    ui.text(c, c.print("{d} bookmarks in {d} folder{s}{s}{s}", .{ Bookmarks.count(proposal.tree), n, if (n == 1) "" else "s", removed, left }), .{ .size = 12, .color = p.muted });

    plate.cardBox(c, p);
    _ = c.open(.{ .width = .fill, .max_height = 360, .scroll = true, .direction = .column, .scroll_bar = false }, "bm.proposal.tree");
    ui.column(c, .{ .width = .fill, .gap = 1, .padding = .xy(6, 6) });
    rows(b, c, p, proposal.tree, 0);
    ui.end(c);
    c.end();
    ui.end(c);

    if (proposal.removed.len > 0) {
        ui.text(c, "To remove", .{ .size = 11.5, .color = p.muted });
        plate.cardBox(c, p);
        _ = c.open(.{ .width = .fill, .max_height = 120, .scroll = true, .direction = .column, .scroll_bar = false }, "bm.proposal.removed");
        ui.column(c, .{ .width = .fill, .gap = 1, .padding = .xy(6, 6) });
        for (proposal.removed) |node| {
            ui.column(c, .{ .width = .fill, .padding = .xy(10, 4) });
            ui.richText(c, node.title, &.{.{ .start = 0, .end = @intCast(node.title.len), .strike = true }}, .{ .size = 12.5, .color = p.ink, .truncate = true });
            ui.end(c);
        }
        ui.end(c);
        c.end();
        ui.end(c);
    }

    ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
    ui.text(c, c.print("AI \u{2014} may be wrong \u{00B7} {s}", .{proposal.place}), .{ .size = 11, .color = p.muted, .truncate = true });
    ui.spacer(c);
    if (controls.pill(c, p, "Discard", .{}).clicked) press(b, .discard);
    if (controls.pill(c, p, "Apply", .{ .filled = true }).clicked) press(b, .apply);
    ui.end(c);
}

fn press(b: *Browser, what: @FieldType(@import("state.zig").Picks, "pressed")) void {
    b.marks_ui.picks.pressed = what;
    b.redraw();
}

/// What was pressed last frame, done before this one draws.
pub fn frame(b: *Browser) void {
    const picks = &b.marks_ui.picks;
    const what = picks.pressed;
    picks.pressed = .none;
    switch (what) {
        .none => {},
        .apply => apply(b),
        .discard => picks.dropProposal(),
        .stop => picks.reset(b.gpa),
    }
}

fn rows(b: *Browser, c: *ui.Context, p: *const Palette, nodes: []const Bookmark, depth: usize) void {
    for (nodes) |*node| {
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center, .padding = .{ .left = @as(f32, @floatFromInt(depth)) * 18 + 10, .top = 4, .bottom = 4 } });
        if (node.isFolder()) {
            _ = c.open(.{ .width = px(15), .align_items = .center, .justify = .center }, null);
            ui.icon(c, "folder.fill", .{ .size = 10, .color = p.muted });
            c.end();
            ui.text(c, node.title, .{ .size = 12.5, .weight = .medium, .color = p.ink, .truncate = true });
        } else {
            outline.siteMark(b, c, p, node, 15);
            ui.text(c, node.title, .{ .size = 12.5, .color = p.ink, .truncate = true });
        }
        ui.end(c);
        if (node.isFolder()) rows(b, c, p, node.kids(), depth + 1);
    }
}
