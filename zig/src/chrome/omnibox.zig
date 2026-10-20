//! The address field (Omnibox.swift): one field over the page's part of the
//! window, raised over a page by ⌘L or ⌘K and standing on its own on a tab
//! with nowhere to be yet; the list of what it thinks you mean below it
//! (`omnibox_list.zig`), a kea fact under it on a blank tab. What is typed
//! past the caret is the rest of an address, selected, so typing on replaces
//! it and Return takes it (`AddressField`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("../model/browser.zig").Browser;
const Tab = @import("../web/tab.zig").Tab;
const Palette = @import("../design/palette.zig").Palette;
const metrics = @import("../design/metrics.zig");
const motion = @import("../design/motion.zig");
const card = @import("../design/card.zig");
const controls = @import("controls.zig");
const omnibox_list = @import("omnibox_list.zig");
const kea_fact = @import("kea_fact.zig");
const kea_flight = @import("kea_flight.zig");

const px = struct {
    fn v(n: f32) ui.Length {
        return .{ .px = n };
    }
}.v;

/// The field's own height: 22 of text and 14 of air above and below.
pub const field_height: f32 = 22 + 14 * 2;

const base_id: u64 = std.hash.Wyhash.hash(0, "kea.omnibox");
const field_id: u64 = std.hash.Wyhash.hash(0, "kea.omnibox.field");

/// What the view keeps from one frame to the next, on its `Browser`.
pub const State = struct {
    /// The field's text, and the last value pushed into it from the model
    /// (`Coordinator.synced`): only a change other than typing is applied.
    field: ui.TextBuffer = .{},
    synced: std.ArrayList(u8) = .empty,
    /// The `focus_request` last answered.
    answered: u32 = 0,
    /// Showing last frame, raised over a page, and the text field's id.
    shown: bool = false,
    over: bool = false,
    text_id: u64 = 0,
    /// Each showing's own appearing.
    gen: u32 = 0,
    /// Refusals seen; the red edge they leave until the next keystroke.
    refusals: u32 = 0,
    refused: bool = false,
    shakes: u32 = 0,
    typed_seen: u64 = 0,
    active_seen: u64 = 0,
    last_completed_hash: u64 = 0,

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        st.field.deinit();
        st.synced.deinit(gpa);
    }
};

pub const Options = struct {
    /// Sized to a pane of a split rather than to the window.
    fitted: bool = false,
    /// A kea fact under the field on a blank page; a pair's blank page
    /// lists the open tabs there instead (`OpenTabs`).
    facts: bool = true,
};

/// The field over `area`, the page's part of the window.
pub fn view(b: *Browser, c: *ui.Context, p: *const Palette, area: ui.Rect, opts: Options) void {
    const st = &b.omnibox;
    const showing = b.fieldShowing() and !b.welcoming;
    notice(b, st, showing);
    if (showing) st.over = if (b.activeTab()) |t| !t.isBlank() else false;
    const v = arrival(c, st, showing) orelse {
        st.shown = false;
        st.text_id = 0;
        return;
    };
    defer st.shown = showing;
    if (showing) keys(b, c, st);

    const w = if (opts.fitted) @min(metrics.field_width, @max(0, area.w - 28)) else metrics.field_width;
    const x = (area.w - w) / 2;
    // Lifted a little above centre (`padding(.bottom, 60)`).
    const y = (area.h - field_height - 60) / 2;
    // The whole of it arrives at .97 and grows to size (`settle`), and goes
    // the same way (`quick`).
    ui.key(c, "kea.omnibox");
    ui.column(c, .{
        .absolute = true,
        .offset = .{ .x = area.x, .y = area.y - 10 * (1 - v) },
        .width = px(area.w),
        .height = px(area.h),
        .scale = 0.94 + 0.06 * v,
        .opacity = std.math.clamp(v, 0, 1),
        .group = true,
    });
    defer ui.end(c);
    if (st.over) {
        scrim(b, c, p, area);
    } else if (!b.kea.opts.headless) {
        kea_flight.newTabArt(c, .{ .w = area.w, .h = area.h }, y);
    }
    field(b, c, p, st, x, y, w, showing);
    if (!st.over and opts.facts and b.prefs.kea_facts) kea_fact.view(b, c, p, .{ .w = area.w, .h = area.h }, y, 1);
    if (omnibox_list.list(b, c, p, x, y + field_height + 8, w)) |click| switch (click) {
        .lock => _ = b.lockSiteOffer(),
        .offer => |i| if (i < b.omni.offers.len) b.takeOffer(b.omni.offers[i]),
    };
}

/// Its progress: springing in on `settle` each time it is raised, easing
/// out on `quick`; null once gone.
fn arrival(c: *ui.Context, st: *State, showing: bool) ?f32 {
    if (showing and !st.shown) st.gen +%= 1;
    const salt = st.gen *% 2;
    if (showing) {
        // The way out, at 1 while in, so it eases from there.
        _ = ui.tween(c, base_id, salt +% 1, 1, 0, .linear);
        return ui.springFrom(c, base_id, salt, 0, 1, motion.bounce);
    }
    const v = ui.tween(c, base_id, salt +% 1, 0, motion.quick_duration, motion.quick_curve);
    return if (v <= 0) null else v;
}

/// What changed since the last frame: a refusal (red and a shake), typing
/// (the red goes), the field or the tab in front gone (the keys go back).
fn notice(b: *Browser, st: *State, showing: bool) void {
    const typed = std.hash.Wyhash.hash(0, b.omni.typed.items);
    if (typed != st.typed_seen) {
        st.typed_seen = typed;
        st.refused = false;
    }
    if (b.refusals != st.refusals) {
        st.refusals = b.refusals;
        if (showing and b.editing_tab == null) {
            st.refused = true;
            st.shakes +%= 1;
        }
    }
    const active = b.active_id;
    if ((st.shown and !showing) or active != st.active_seen) handBack(b, showing);
    st.active_seen = active;
}

/// The keyboard back to the page once the field is done with it, a turn
/// later (`handBack`): typing would otherwise go nowhere.
pub fn giveKeys(b: *Browser) void {
    if (b.fieldShowing() or b.editing_tab != null) return;
    const t = b.activeTab() orelse return;
    objc.dispatchMain(@ptrFromInt(t.serial), giveKeysNow);
}

fn handBack(b: *Browser, showing: bool) void {
    if (!showing) giveKeys(b);
}

fn giveKeysNow(ctx: ?*anyopaque) callconv(.c) void {
    applyKeys(ctx, true);
}

fn giveKeysRetry(ctx: ?*anyopaque) callconv(.c) void {
    applyKeys(ctx, false);
}

fn applyKeys(ctx: ?*anyopaque, retry: bool) void {
    const t = Tab.alive(@intFromPtr(ctx)) orelse return;
    const b = t.browser orelse return;
    if (b.fieldShowing() or b.editing_tab != null) return;
    const wv = t.web orelse return;
    const window = objc.msg(?objc.Object, wv, "window", .{}) orelse {
        if (retry) objc.dispatchAfter(50 * std.time.ns_per_ms, ctx, giveKeysRetry);
        return;
    };
    if (objc.msg(?objc.Object, window, "firstResponder", .{})) |r| {
        if (r == wv or (objc.msg(objc.BOOL, r, "isKindOfClass:", .{objc.class("NSView")}) and objc.msg(objc.BOOL, r, "isDescendantOf:", .{wv}))) return;
    }
    _ = objc.msg(objc.BOOL, window, "makeFirstResponder:", .{wv});
}

fn offered(c: *ui.Context, want: ui.Shortcut) bool {
    const s = c.input.shortcut orelse return false;
    return s.key == want.key and s.cmd == want.cmd and s.ctrl == want.ctrl and s.alt == want.alt and s.shift == want.shift;
}

/// The keys the field answers: ↓ ↑ walk the list, ⌘Return opens aside (⇧
/// in front), Tab takes the site offered or walks on (`ContentView.take`).
fn keys(b: *Browser, c: *ui.Context, st: *State) void {
    if (st.text_id != 0 and c.focus == st.text_id) {
        if (c.shortcut(.{ .key = ui.Shortcut.down })) {
            b.walk(1);
        } else if (c.shortcut(.{ .key = ui.Shortcut.up })) {
            b.walk(-1);
        } else for ([_]u21{ '\r', 3 }) |enter| {
            const front = c.shortcut(.{ .key = enter, .cmd = true, .shift = true });
            if (front or c.shortcut(.{ .key = enter, .cmd = true })) {
                b.submit(true, front);
                break;
            }
        }
    }
    if (b.editing_tab != null) return;
    if (offered(c, .{ .key = '\t' })) {
        if (b.lockSiteOffer()) {
            _ = c.shortcut(.{ .key = '\t' });
        } else if (b.omni.offers.len > 0) {
            _ = c.shortcut(.{ .key = '\t' });
            b.walk(1);
        }
    } else for ([_]u21{ '\t', 0x19 }) |back| {
        // ⇧Tab names itself the back-tab character.
        if (offered(c, .{ .key = back, .shift = true }) and b.omni.offers.len > 0) {
            _ = c.shortcut(.{ .key = back, .shift = true });
            b.walk(-1);
            break;
        }
    }
}

/// The page is still there, just out of the way; a press puts the field away.
fn scrim(b: *Browser, c: *ui.Context, p: *const Palette, area: ui.Rect) void {
    const i = c.open(.{ .absolute = true, .width = px(area.w), .height = px(area.h), .background = p.ground.alpha(0.74) }, "kea.omnibox.scrim");
    const it = c.interact(i, .{});
    c.end();
    if (it.clicked) b.dismiss();
}

/// A slow, almost invisible breath under the field: a soft shape of ink,
/// from .97 to 1.03 and .65 to full, 2.6 s each way, eased; still under
/// Reduce Motion. Thirty frames a second are plenty for something this slow.
fn breath(c: *ui.Context, p: *const Palette, w: f32) void {
    _ = c.leaf(.{
        .absolute = true,
        .width = px(w),
        .height = px(field_height),
        .radius = 26,
        .shadow = .{ .color = p.ink.alpha(0.07), .blur = 2 * 26 },
        .pulse = if (c.reduce_motion) null else .{ .period = 5.2, .scale_amp = 0.03, .alpha_low = 0.65 },
        .opacity = 1,
    }, .none, null);
}

fn setSynced(b: *Browser, st: *State, s: []const u8) void {
    st.synced.clearRetainingCapacity();
    st.synced.appendSlice(b.gpa, s) catch @panic("OOM");
}

fn completedHash(b: *Browser) u64 {
    var h = std.hash.Wyhash.init(1);
    h.update(b.omni.typed.items);
    h.update(&.{0});
    if (b.omni.ending) |e| h.update(e);
    h.update(&.{0});
    if (b.omni.picked) |p| {
        h.update(std.mem.asBytes(&p));
        if (p < b.omni.offers.len) h.update(b.omni.offers[p].key);
    } else h.update(&.{0xff});
    return h.final();
}

fn hasCommand(c: *ui.Context, cmd: ui.Command) bool {
    for (c.input.ops) |op| if (op == .command and op.command == cmd) return true;
    return false;
}

fn field(b: *Browser, c: *ui.Context, p: *const Palette, st: *State, x: f32, y: f32, w: f32, showing: bool) void {
    const shake = controls.shake(c, field_id, st.shakes);
    const red = motion.settleTo(c, field_id, 1, if (st.refused) 1 else 0);
    _ = c.open(.{ .absolute = true, .offset = .{ .x = x + shake, .y = y }, .width = px(w), .height = px(field_height) }, "kea.omnibox.field");
    defer c.end();
    // The field's shadow, cast by its shape alone; the breath; then the field.
    _ = c.leaf(.{ .absolute = true, .width = px(w), .height = px(field_height), .radius = 14, .background = p.ground, .shadow = card.swiftShadow(0.06, 24, 8) }, .none, null);
    breath(c, p, w);
    const box = c.open(.{
        .direction = .row,
        .gap = 8,
        .width = px(w),
        .height = px(field_height),
        .padding = .xy(22, 14),
        .radius = 14,
        .background = p.ground,
        .border = p.hairline.mix(p.red.alpha(0.35), red),
        .align_items = .center,
    }, null);
    defer c.end();
    const air = c.interact(box, .{});
    omnibox_list.siteChip(b, c, p, b.site_chip);
    _ = c.open(.{ .grow = 1, .height = px(22), .align_items = .center }, "kea.omnibox.text.box");
    defer c.end();
    const buf = &st.field;

    // Only what something other than typing changed is pushed in: ⌘L's
    // address, a walk through the list, a submit clearing it.
    const typed = b.omni.typed.items;
    const chash = completedHash(b);
    if (chash != st.last_completed_hash) {
        st.last_completed_hash = chash;
        const want = b.omni.completed(c.alloc());
        if (!std.mem.eql(u8, want, st.synced.items)) {
            setSynced(b, st, want);
            buf.set(want);
            buf.want_selection = .{ typed.len, want.len };
        }
    }
    if (buf.text().len == 0) _ = c.leaf(.{ .absolute = true }, .{ .text = .{ .str = "Enter a web address", .style = .{ .size = 15.5 }, .color = p.ink.alpha(0.3) } }, null);
    // The same field whatever came before it (the placeholder, the chip).
    ui.key(c, "kea.omnibox.text");
    // Asked for, or just raised: a draft come back to its blank tab is
    // carried on with the caret after it; an address ⌘L raises is selected.
    if (showing and (st.answered != b.focus_request or !st.shown)) {
        st.answered = b.focus_request;
        const draft = !st.over and typed.len > 0;
        ui.focusNext(c, !draft);
        if (draft) buf.want_selection = .{ typed.len, st.synced.items.len };
    }
    const text_id = c.peekId(null);
    // A press on the field's air leaves the keys in it.
    if (air.pressed and c.input.pressed) c.focus = text_id;
    const focused = c.focus == text_id;
    // A backspace has to be allowed to take a letter off: the ending is not
    // put back on that keystroke.
    var deleting = false;
    if (focused) {
        for ([_]ui.Command{ .delete_backward, .delete_forward, .delete_word_backward, .delete_word_forward }) |cmd| deleting = deleting or hasCommand(c, cmd);
        if (c.input.key) |k| deleting = deleting or k == .backspace or k == .delete;
        // ⌫ on an empty field takes the site out of it.
        if (b.site_chip != null and buf.text().len == 0 and (hasCommand(c, .delete_backward) or c.input.key == .backspace)) b.setChip(null);
        // ⌥⌫ over an offered ending lets go of it and takes the last word typed.
        if (b.omni.ending != null and hasCommand(c, .delete_word_backward)) if (c.edits.get(text_id)) |e| {
            if (e.caret != e.anchor and @max(e.caret, e.anchor) == buf.text().len) {
                buf.set(typed);
                buf.want_caret = typed.len;
            }
        };
    }
    st.text_id = text_id;
    const res = ui.textField(c, buf, .{ .bare = true, .size = 15.5, .width = .fill, .selection_color = p.ink.alpha(0.12), .caret_color = p.ink });
    if (focused and c.focus == 0 and showing and (c.input.key == .escape or hasCommand(c, .cancel))) c.focus = text_id;
    if (res.changed) typedChanged(b, c, st, deleting);
    if (res.submitted and showing) b.submit(false, false);
}

/// `controlTextDidChange`: what is typed is the model's, and the rest of
/// the best match goes after it, selected.
fn typedChanged(b: *Browser, c: *ui.Context, st: *State, deleting: bool) void {
    const a = c.alloc();
    const text = a.dupe(u8, st.field.text()) catch return;
    b.setTyped(text);
    if (!deleting) if (b.omni.ending) |ending| {
        const whole = std.mem.concat(a, u8, &.{ text, ending }) catch return;
        st.field.set(whole);
        setSynced(b, st, whole);
        st.last_completed_hash = completedHash(b);
        st.field.want_selection = .{ text.len, whole.len };
        return;
    };
    if (deleting) b.stopCompleting();
    setSynced(b, st, b.omni.completed(a));
    st.last_completed_hash = completedHash(b);
}
