//! A pill leaving the strip (`TabPill`'s `.scale(0.9, anchor: .leading)
//! + .opacity`, TabBar.swift:584): the whole pill — its mark, its private
//! eye, its recording dot, its title — shrinking and fading where it
//! stood, whatever took the tab away: closed, private, moved to another
//! window or space. What it showed is kept while it is in the row, since
//! the tab itself is gone by the frame it starts to leave.
const std = @import("std");
const ui = @import("nanoui").ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const mark = @import("mark.zig");
const tab_width = @import("tab_width.zig");
const motion = @import("../design/motion.zig");
const presence = @import("presence.zig").presence;

fn px(v: f32) ui.Length {
    return .{ .px = v };
}

/// What a pill showed, owned: its label, its address and a pin's letter
/// in one buffer, copied again only when they change.
pub const Snap = struct {
    buf: []u8 = &.{},
    label_len: usize = 0,
    url_len: usize = 0,
    mono: [4]u8 = undefined,
    mono_len: u8 = 0,
    pinned: bool = false,
    blank: bool = false,
    asleep: bool = false,
    shy: bool = false,
    recording: bool = false,

    pub fn label(s: *const Snap) []const u8 {
        return s.buf[0..s.label_len];
    }

    pub fn url(s: *const Snap) []const u8 {
        return s.buf[s.label_len..][0..s.url_len];
    }

    pub fn letter(s: *const Snap) []const u8 {
        return s.buf[s.label_len + s.url_len ..];
    }

    /// Up to date with `t` as the pill draws it.
    pub fn take(s: *Snap, gpa: std.mem.Allocator, b: *const Browser, t: *const Tab) void {
        s.pinned = t.pin != null and b.editing_tab != t.id;
        s.blank = t.isBlank();
        s.asleep = t.asleep();
        s.shy = t.shy;
        s.recording = t.recording;
        const m = t.monogram(&s.mono);
        // `monogram` answers "•" from outside the buffer.
        if (m.ptr != @as([*]const u8, &s.mono)) @memcpy(s.mono[0..m.len], m);
        s.mono_len = @intCast(m.len);
        const parts = [_][]const u8{ t.label(), t.url(), t.pin orelse "" };
        if (std.mem.eql(u8, s.label(), parts[0]) and std.mem.eql(u8, s.url(), parts[1]) and std.mem.eql(u8, s.letter(), parts[2])) return;
        const buf = std.mem.concat(gpa, u8, &parts) catch return;
        gpa.free(s.buf);
        s.buf = buf;
        s.label_len = parts[0].len;
        s.url_len = parts[1].len;
    }

    pub fn deinit(s: *Snap, gpa: std.mem.Allocator) void {
        gpa.free(s.buf);
        s.* = .{};
    }
};

/// The leaving pill at `x` (run points), `w` wide, `v` of the way still here.
pub fn draw(b: *Browser, c: *ui.Context, p: *const Palette, s: *const Snap, x: f32, w: f32, v: f32, each: f32) void {
    const o = std.math.clamp(v, 0, 1);
    var style: ui.Style = .{
        .absolute = true,
        .direction = .row,
        .offset = .{ .x = x, .y = (metrics.strip - 28) / 2 },
        .width = px(w),
        .height = px(28),
        .radius = 9,
        .align_items = .center,
        .opacity = o,
        .scale = 0.9 + 0.1 * v,
        .scale_anchor = .{ .x = 0, .y = 0.5 },
    };
    const compact = !s.pinned and !tab_width.titled(each);
    if (s.pinned) {
        style.padding = .xy(7, 6);
        style.background = p.wash.alpha(0.55);
    } else if (compact) {
        style.justify = .center;
    } else {
        style.padding = .{ .left = 11, .right = 7 };
        style.gap = 6;
    }
    _ = c.open(style, null);
    defer c.end();
    const icon: ?mark.Icon = if (b.prefs.glyph == .icons) b.kea.favicons.icon(s.url()) else null;
    if (s.pinned) {
        _ = c.open(.{ .width = px(16), .height = px(16), .align_items = .center, .justify = .center }, null);
        defer c.end();
        if (icon) |ic| return mark.mark(c, p, ic, s.letter(), 16, s.asleep);
        return ui.text(c, s.letter(), .{ .size = 12, .weight = .medium, .color = p.muted.alpha(if (s.asleep) 0.45 else 1) });
    }
    const mono = s.mono[0..s.mono_len];
    if (compact) return mark.mark(c, p, icon, mono, 15, s.asleep);
    if (b.prefs.glyph == .icons and !s.blank) mark.mark(c, p, icon, mono, 15, false);
    if (s.shy) ui.icon(c, "eye.slash", .{ .size = 9, .color = p.muted.alpha(0.7) });
    if (s.recording) ui.icon(c, "record.circle", .{ .size = 10, .color = p.muted.alpha(0.8) });
    ui.text(c, s.label(), .{ .size = 12.5, .color = p.muted, .truncate = true });
}

/// A pill gone from the row, where it stood, with what it showed.
pub const Leaving = struct { id: u64, x: f32, w: f32, snap: Snap };

fn has(seen: anytype, id: u64) bool {
    for (seen) |s| if (s.id == id) return true;
    return false;
}

/// Tab `t` drawn in the row this frame: what its pill shows, kept.
pub fn keep(b: *Browser, t: *const Tab) void {
    const g = b.strip.snaps.getOrPut(b.gpa, t.id) catch return;
    if (!g.found_existing) g.value_ptr.* = .{};
    g.value_ptr.take(b.gpa, b, t);
}

/// Pills drawn last frame and not this one start leaving; those leaving
/// are drawn until they are gone.
pub fn leave(b: *Browser, c: *ui.Context, p: *const Palette, last: anytype, each: f32) void {
    const st = &b.strip;
    for (last) |s| {
        if (has(st.seen.items, s.id)) continue;
        const kv = st.snaps.fetchRemove(s.id) orelse continue;
        st.leaving.append(b.gpa, .{ .id = s.id, .x = s.x, .w = s.w, .snap = kv.value }) catch {
            var gone = kv.value;
            gone.deinit(b.gpa);
        };
    }
    prune(b);
    var k: usize = 0;
    for (st.leaving.items) |*l| {
        const v = presence(c, @import("tab_bar.zig").pillId(l.id), false, motion.settle, null) orelse {
            l.snap.deinit(b.gpa);
            continue;
        };
        st.leaving.items[k] = l.*;
        k += 1;
        const kept = &st.leaving.items[k - 1];
        draw(b, c, p, &kept.snap, kept.x, kept.w, v, each);
    }
    st.leaving.shrinkRetainingCapacity(k);
}

/// A row put in wholesale: nothing leaves; what is not in it is forgotten.
pub fn clear(b: *Browser) void {
    for (b.strip.leaving.items) |*l| l.snap.deinit(b.gpa);
    b.strip.leaving.clearRetainingCapacity();
    prune(b);
}

/// Forgets what tabs no longer drawn showed.
fn prune(b: *Browser) void {
    const st = &b.strip;
    if (st.snaps.count() <= st.seen.items.len) return;
    var it = st.snaps.iterator();
    while (it.next()) |e| if (!has(st.seen.items, e.key_ptr.*)) {
        e.value_ptr.deinit(b.gpa);
        st.snaps.removeByPtr(e.key_ptr);
    };
}

pub fn deinit(b_strip: anytype, gpa: std.mem.Allocator) void {
    for (b_strip.leaving.items) |*l| l.snap.deinit(gpa);
    b_strip.leaving.deinit(gpa);
    var it = b_strip.snaps.valueIterator();
    while (it.next()) |s| s.deinit(gpa);
    b_strip.snaps.deinit(gpa);
}
