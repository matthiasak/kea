//! `DownloadsPanel` (Recall.swift 248-481): what is coming in now, and
//! what you have kept — a line to open, show in the Finder or forget; the
//! files stay where they are. A sheet (`chrome/sheet.zig`, `hoarding`),
//! over every window's downloads (`kea.fetches`) and `downloads.json`
//! (`kea.loot`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Palette = @import("../design/palette.zig").Palette;
const plate = @import("controls_plate.zig");
const controls = @import("controls.zig");
const motion = @import("../design/motion.zig");
const sheet = @import("sheet.zig");
const when = @import("when.zig");
const downloads = @import("../web/downloads.zig");
const keep_ops = @import("../web/downloads_keep.zig");
const Entry = downloads.Entry;
const Keep = @import("../data/loot.zig").Keep;

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// ⇧⌘J: Downloads… (`hoarding.toggle()`).
pub fn toggle(b: *Browser) void {
    sheet.toggle(b, .hoarding);
}

/// What a line asked for, done once the lists are drawn: each can change
/// the very list being drawn.
const Act = union(enum) {
    none,
    pause: u64,
    resume_: u64,
    retry: u64,
    cancel: u64,
    open: []const u8,
    reveal: []const u8,
    forget: []const u8,
    forget_all,
};

pub fn view(b: *Browser, c: *ui.Context, p: *const Palette) void {
    const fetches = &b.kea.fetches;
    const kept = b.kea.loot.kept;
    var act: Act = .none;
    var pl = plate.plate(c, p, "Downloads", 560);
    if (pl.closed) sheet.close(b, .hoarding);
    if (fetches.entries.items.len == 0 and kept.len == 0) {
        plate.cardBox(c, p);
        plate.nothing(c, p, "Nothing downloaded yet. The nest is empty.");
        ui.end(c);
    } else {
        ui.scroll(c, .{ .width = .fill, .max_height = 420, .gap = 10, .scroll_bar = false, .padding = .{ .bottom = 2 } });
        if (fetches.entries.items.len > 0) {
            ui.column(c, .{ .width = .fill, .gap = 6 });
            plate.caption(c, p, "Current downloads");
            plate.cardBox(c, p);
            for (fetches.entries.items, 0..) |e, n| {
                if (n > 0) plate.rule(c, p, 14);
                ui.key(c, c.print("fetch-{d}", .{e.id}));
                const a = fetchRow(c, p, e);
                if (a != .none) act = a;
            }
            ui.end(c);
            ui.end(c);
        }
        if (kept.len > 0) {
            ui.column(c, .{ .width = .fill, .gap = 6 });
            plate.caption(c, p, "Completed");
            plate.cardBox(c, p);
            for (kept, 0..) |k, n| {
                if (n > 0) plate.rule(c, p, 14);
                ui.key(c, k.path);
                const a = keptRow(c, p, k);
                if (a != .none) act = a;
            }
            ui.end(c);
            ui.end(c);
        }
        ui.end(c);
    }
    pl.foot(c, p);
    const said = if (kept.len == 0) c.print("Files land in {s}", .{std.fs.path.basename(keep_ops.downloadsFolder(b))}) else "Clearing the list leaves the files where they are";
    ui.text(c, said, .{ .size = 12, .color = p.muted });
    ui.spacer(c);
    if (kept.len > 0 and controls.pill(c, p, "Clear list", .{}).clicked) act = .forget_all;
    pl.end(c);
    perform(b, act);
}

fn perform(b: *Browser, act: Act) void {
    const fetches = &b.kea.fetches;
    switch (act) {
        .none => return,
        .pause => |id| if (fetches.entryById(id)) |e| keep_ops.pauseDownload(b, e),
        .resume_ => |id| if (fetches.entryById(id)) |e| keep_ops.resumeDownload(b, e),
        .retry => |id| if (fetches.entryById(id)) |e| keep_ops.retryDownload(b, e),
        .cancel => |id| if (fetches.entryById(id)) |e| keep_ops.cancelDownload(b, e),
        .open => |path| open(path),
        .reveal => |path| keep_ops.reveal(path),
        .forget => |path| {
            // The path lives in the list being replaced.
            const copy = b.gpa.dupe(u8, path) catch return;
            defer b.gpa.free(copy);
            b.kea.loot.forget(copy);
        },
        .forget_all => b.kea.loot.forgetAll(),
    }
    b.redraw();
}

/// `Loot.open`: the file, in the app that opens it.
fn open(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    _ = objc.msg(objc.BOOL, objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{url});
}

/// `ByteCountFormatter.string(fromByteCount:countStyle: .file)`.
fn byteCount(c: *ui.Context, n: i64) []const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = objc.msg(?objc.Object, objc.class("NSByteCountFormatter"), "stringFromByteCount:countStyle:", .{ n, @as(objc.NSInteger, 0) });
    return c.alloc().dupe(u8, objc.fromNSString(s)) catch "";
}

fn bytes(c: *ui.Context, e: *const Entry) []const u8 {
    const received = byteCount(c, e.completed_bytes);
    if (e.total_bytes <= 0) return c.print("{s} downloaded", .{received});
    return c.print("{s} of {s}", .{ received, byteCount(c, e.total_bytes) });
}

fn stateLabel(e: *const Entry) []const u8 {
    return switch (e.state) {
        .downloading => "Downloading",
        .pausing => "Pausing…",
        .paused => "Paused",
        .resuming => "Resuming…",
        .failed => "Failed",
    };
}

fn icon(e: *const Entry) []const u8 {
    return switch (e.state) {
        .downloading, .pausing, .resuming => "arrow.down.circle",
        .paused => "pause.circle",
        .failed => "exclamationmark.circle",
    };
}

/// `FetchRow`: what is coming, how far, and what can be done to it.
fn fetchRow(c: *ui.Context, p: *const Palette, e: *Entry) Act {
    ui.row(c, .{ .gap = 12, .width = .fill, .padding = .xy(14, 10), .align_items = .start });
    defer ui.end(c);
    ui.column(c, .{ .width = px(18), .align_items = .center, .padding = .{ .top = 1 } });
    ui.icon(c, icon(e), .{ .size = 14, .color = p.muted });
    ui.end(c);
    ui.column(c, .{ .gap = 4, .grow = 1, .min_width = 0 });
    ui.text(c, e.label(), .{ .size = 13, .color = p.ink, .truncate = true });
    ui.row(c, .{ .gap = 7, .align_items = .center, .width = .fill });
    if (e.fraction) |fraction| {
        // Grey, as the ring in the chrome is.
        ui.row(c, .{ .width = px(68), .height = px(3), .radius = controls.capsule, .background = p.hairline });
        _ = c.leaf(.{ .width = px(68 * @as(f32, @floatCast(std.math.clamp(fraction, 0, 1)))), .height = .fill, .radius = controls.capsule, .background = p.ink.alpha(0.6) }, .none, null);
        ui.end(c);
    }
    ui.column(c, .{ .grow = 1, .min_width = 0 });
    ui.text(c, c.print("{s} · {s}", .{ stateLabel(e), bytes(c, e) }), .{ .size = 11.5, .color = p.muted, .tabular = true, .truncate = true });
    ui.end(c);
    ui.end(c);
    if (e.state == .failed) {
        _ = c.open(.{ .width = .fill, .selectable = true }, null);
        ui.text(c, e.error_description orelse "The download failed.", .{ .size = 11.5, .color = p.muted, .wrap = true });
        c.end();
    }
    ui.end(c);
    _ = c.leaf(.{ .min_width = 4, .width = px(4) }, .none, null);
    ui.row(c, .{ .gap = 4, .align_items = .center });
    defer ui.end(c);
    const id = e.id;
    switch (e.state) {
        .downloading => {
            if (e.canPause() and plate.quick(c, p, "Pause", null).clicked) return .{ .pause = id };
            if (plate.quick(c, p, "Cancel", null).clicked) return .{ .cancel = id };
        },
        .pausing, .resuming => {
            _ = plate.quick(c, p, stateLabel(e), p.ink.alpha(0.4));
            if (plate.quick(c, p, "Cancel", null).clicked) return .{ .cancel = id };
        },
        .paused => {
            if (e.canResume()) {
                if (plate.quick(c, p, "Resume", null).clicked) return .{ .resume_ = id };
            } else if (e.canRetry()) {
                if (retry(c, p)) return .{ .retry = id };
            }
            if (plate.quick(c, p, "Remove", null).clicked) return .{ .cancel = id };
        },
        .failed => {
            if (e.canResume() and plate.quick(c, p, "Resume", null).clicked) return .{ .resume_ = id };
            if (e.canRetry() and retry(c, p)) return .{ .retry = id };
            if (plate.quick(c, p, "Remove", null).clicked) return .{ .cancel = id };
        },
    }
    return .none;
}

fn retry(c: *ui.Context, p: *const Palette) bool {
    // The help on a box around it: shown for the button, which is inside.
    const w = c.open(.{}, null);
    defer c.end();
    c.help(w, "Start the download again from the beginning");
    return plate.quick(c, p, "Retry", null).clicked;
}

/// `KeptRow`: a file kept, faint once it has gone from where it landed.
fn keptRow(c: *ui.Context, p: *const Palette, k: Keep) Act {
    const there = downloads.exists(k.path);
    const i = c.open(.{ .direction = .row, .gap = 12, .width = .fill, .padding = .xy(14, 9), .align_items = .center }, null);
    defer c.end();
    const it = c.interact(i, .{});
    c.addA11y(i, .row, k.name, "", false, true);
    c.node(i).style.background = p.hover.alpha(motion.quickTo(c, it.id, 0, if (it.hovered) 1 else 0));
    ui.column(c, .{ .width = px(18), .align_items = .center });
    ui.icon(c, if (there) "doc" else "doc.badge.ellipsis", .{ .size = 13, .color = if (there) p.muted else p.faint });
    ui.end(c);
    ui.column(c, .{ .gap = 2, .grow = 1, .min_width = 0 });
    ui.text(c, k.name, .{ .size = 13, .color = if (there) p.ink else p.faint, .truncate = true });
    const ago = when.said(c.alloc(), k.date);
    ui.text(c, if (k.from.len == 0) ago else c.print("{s} · {s}", .{ k.from, ago }), .{ .size = 11.5, .color = p.muted, .truncate = true });
    ui.end(c);
    _ = c.leaf(.{ .min_width = 8, .width = px(8) }, .none, null);
    if (it.hovered) {
        if (there and plate.quick(c, p, "Show in Finder", null).clicked) return .{ .reveal = k.path };
        if (plate.quick(c, p, "Remove", p.red.alpha(0.75)).clicked) return .{ .forget = k.path };
    }
    return if (it.clicked and there) .{ .open = k.path } else .none;
}
