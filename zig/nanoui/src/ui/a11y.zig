//! Accessibility (`NSAccessibility`): turns the frame's interactive boxes
//! into `NSAccessibilityElement` children of `NanoUIView` for VoiceOver
//! and automated accessibility queries, and posts spoken announcements.
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Surface = @import("surface.zig").Surface;

pub const ElementPayload = struct {
    surface: *Surface,
    id: u64,
    role: ctx_mod.A11yRole,
    label: [128]u8 = undefined,
    label_len: usize = 0,
    value: [128]u8 = undefined,
    value_len: usize = 0,
    selected: bool = false,
    enabled: bool = true,
};

pub const methods = [_]objc.Method{
    .{ .name = "isAccessibilityElement", .imp = &viewIsElement, .types = "c@:" },
    .{ .name = "accessibilityRole", .imp = &viewRole, .types = "@@:" },
    .{ .name = "accessibilityChildren", .imp = &viewChildren, .types = "@@:" },
};

fn viewIsElement(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.NO;
}

fn viewRole(_: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    return objc.nsString("AXGroup");
}

fn elementClass() objc.Class {
    return objc.defineClass(.{
        .name = "NanoUIA11yElement",
        .superclass = "NSAccessibilityElement",
        .methods = &.{
            .{ .name = "dealloc", .imp = &elemDealloc, .types = "v@:" },
            .{ .name = "isAccessibilityElement", .imp = &elemYes, .types = "c@:" },
            .{ .name = "isAccessibilityEnabled", .imp = &elemEnabled, .types = "c@:" },
            .{ .name = "isAccessibilitySelected", .imp = &elemSelected, .types = "c@:" },
            .{ .name = "accessibilityParent", .imp = &elemParent, .types = "@@:" },
            .{ .name = "accessibilityRole", .imp = &elemRole, .types = "@@:" },
            .{ .name = "accessibilitySubrole", .imp = &elemSubrole, .types = "@@:" },
            .{ .name = "accessibilityLabel", .imp = &elemLabel, .types = "@@:" },
            .{ .name = "accessibilityValue", .imp = &elemValue, .types = "@@:" },
            .{ .name = "accessibilityFrame", .imp = &elemFrame, .types = "{CGRect={CGPoint=dd}{CGSize=dd}}@:" },
            .{ .name = "accessibilityPerformPress", .imp = &elemPress, .types = "c@:" },
        },
    });
}

fn viewChildren(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const s = objc.getZig(Surface, obj) orelse return objc.msg(objc.Object, objc.class("NSArray"), "array", .{});
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "arrayWithCapacity:", .{@as(objc.NSUInteger, s.ctx.a11y_items.items.len)});
    const cls = elementClass();
    for (s.ctx.a11y_items.items) |it| {
        const p = s.gpa.create(ElementPayload) catch continue;
        p.* = .{ .surface = s, .id = it.id, .role = it.role, .selected = it.selected, .enabled = it.enabled };
        p.label_len = @min(it.label.len, p.label.len);
        @memcpy(p.label[0..p.label_len], it.label[0..p.label_len]);
        p.value_len = @min(it.value.len, p.value.len);
        @memcpy(p.value[0..p.value_len], it.value[0..p.value_len]);

        const el = objc.msg(objc.Object, cls, "new", .{});
        objc.setZig(el, p);
        objc.msg(void, arr, "addObject:", .{el});
        objc.release(el);
    }
    return arr;
}

fn payloadOf(obj: objc.Object) ?*ElementPayload {
    return objc.getZig(ElementPayload, obj);
}

fn elemDealloc(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    if (payloadOf(obj)) |p| {
        objc.setZig(obj, null);
        p.surface.gpa.destroy(p);
    }
    objc.msgSuper(void, obj, objc.class("NSAccessibilityElement"), "dealloc", .{});
}

fn elemYes(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn elemEnabled(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    return if (p.enabled) objc.YES else objc.NO;
}

fn elemSelected(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    return if (p.selected) objc.YES else objc.NO;
}

fn elemParent(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const p = payloadOf(obj) orelse return null;
    return p.surface.nsview;
}

fn elemRole(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const p = payloadOf(obj) orelse return objc.nsString("AXUnknown");
    return objc.nsString(switch (p.role) {
        .button => "AXButton",
        .tab, .radio_button => "AXRadioButton",
        .text_field => "AXTextField",
        .splitter => "AXSplitter",
        .checkbox, .switch_toggle => "AXCheckBox",
        .group => "AXGroup",
        .static_text => "AXStaticText",
    });
}

fn elemSubrole(obj: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const p = payloadOf(obj) orelse return null;
    return switch (p.role) {
        .switch_toggle => objc.nsString("AXSwitch"),
        .tab => objc.nsString("AXTabButton"),
        else => null,
    };
}

fn elemLabel(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const p = payloadOf(obj) orelse return objc.nsString("");
    return objc.nsString(p.label[0..p.label_len]);
}

fn elemValue(obj: objc.Object, _: objc.SEL) callconv(.c) objc.Object {
    const p = payloadOf(obj) orelse return objc.nsString("");
    if (p.value_len > 0) return objc.nsString(p.value[0..p.value_len]);
    return switch (p.role) {
        .checkbox, .switch_toggle, .tab, .radio_button => objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{if (p.selected) objc.YES else objc.NO}),
        else => objc.nsString(""),
    };
}

fn elemFrame(obj: objc.Object, _: objc.SEL) callconv(.c) objc.CGRect {
    const p = payloadOf(obj) orelse return .{};
    const r = p.surface.ctx.rects.get(p.id) orelse return .{};
    const local: objc.CGRect = .{
        .origin = .{ .x = r.x, .y = r.y },
        .size = .{ .width = r.w, .height = r.h },
    };
    const in_win = objc.msg(objc.CGRect, p.surface.nsview, "convertRect:toView:", .{ local, @as(?objc.Object, null) });
    return objc.msg(objc.CGRect, p.surface.window.nswindow, "convertRectToScreen:", .{in_win});
}

fn elemPress(obj: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    const p = payloadOf(obj) orelse return objc.NO;
    const r = p.surface.ctx.rects.get(p.id) orelse return objc.NO;
    const s = p.surface;
    s.ctx.input.mouse = .{ .x = r.x + r.w * 0.5, .y = r.y + r.h * 0.5 };
    s.ctx.updateHot();
    s.ctx.input.click_count = 1;
    s.ctx.pointerDown();
    s.frame();
    s.ctx.pointerUp();
    s.frame();
    return objc.YES;
}

/// Posts a high-priority VoiceOver announcement (`NSAccessibilityAnnouncementRequestedNotification`).
pub fn announce(target: objc.Object, message: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const keys = [_]objc.Object{
        objc.nsString("NSAccessibilityAnnouncementKey"),
        objc.nsString("NSAccessibilityPriorityKey"),
    };
    const prio = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithInteger:", .{@as(objc.NSInteger, 90)});
    const values = [_]objc.Object{
        objc.nsString(message),
        prio,
    };
    const info = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{
        &values, &keys, @as(objc.NSUInteger, 2),
    });
    objc.NSAccessibilityPostNotificationWithUserInfo(target, objc.nsString("NSAccessibilityAnnouncementRequestedNotification"), info);
}
