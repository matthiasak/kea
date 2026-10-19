//! Phase 2 C-ABI Bridge (`libkea_nanoui.a`): exposes `kea_chrome_*` functions
//! matching `include/kea_nanoui.h` so `nanoui` GPU chrome can be embedded
//! inside a host `NSWindow` via C ABI.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;

pub const KeaTabItem = extern struct {
    id: u64,
    title: [*:0]const u8,
    url: [*:0]const u8,
    loading: bool,
    pinned: bool,
    muted: bool,
};

pub const KeaChromeSnapshot = extern struct {
    sidebar: bool,
    side_on_right: bool,
    side_width: f32,
    chat_open: bool,
    chat_width: f32,
    marks_open: bool,
    marks_width: f32,
    split_active: bool,
    split_fraction: f32,
    active_tab_id: u64,
    address_text: [*:0]const u8,
    tabs: [*]const KeaTabItem,
    tab_count: usize,
};

pub const KeaChromeCallbacks = extern struct {
    userdata: ?*anyopaque = null,
    on_select_tab: ?*const fn (?*anyopaque, u64) callconv(.c) void = null,
    on_close_tab: ?*const fn (?*anyopaque, u64) callconv(.c) void = null,
    on_new_tab: ?*const fn (?*anyopaque) callconv(.c) void = null,
    on_navigate: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void = null,
    on_resize_panel: ?*const fn (?*anyopaque, c_int, f32) callconv(.c) void = null,
};

pub const KeaChrome = struct {
    nswindow: objc.Object,
    callbacks: KeaChromeCallbacks,
    side_width: f32 = 220,
    chat_width: f32 = 360,
    marks_width: f32 = 260,
    active_tab_id: u64 = 0,
};

var gpa_instance: std.heap.DebugAllocator(.{}) = .init;

export fn kea_chrome_create(nswindow_ptr: ?*anyopaque, callbacks: ?*const KeaChromeCallbacks) ?*KeaChrome {
    const nswindow: objc.Object = @ptrCast(@alignCast(nswindow_ptr orelse return null));
    const gpa = gpa_instance.allocator();
    const self = gpa.create(KeaChrome) catch return null;
    self.* = .{
        .nswindow = nswindow,
        .callbacks = if (callbacks) |cb| cb.* else .{},
    };
    return self;
}

export fn kea_chrome_destroy(chrome: ?*KeaChrome) void {
    const self = chrome orelse return;
    gpa_instance.allocator().destroy(self);
}

export fn kea_chrome_set_state(chrome: ?*KeaChrome, snapshot: ?*const KeaChromeSnapshot) void {
    const self = chrome orelse return;
    const snap = snapshot orelse return;
    self.side_width = snap.side_width;
    self.chat_width = snap.chat_width;
    self.marks_width = snap.marks_width;
    self.active_tab_id = snap.active_tab_id;
}

export fn kea_chrome_request_frame(chrome: ?*KeaChrome) void {
    _ = chrome;
}

export fn kea_chrome_announce(chrome: ?*KeaChrome, message: ?[*:0]const u8) void {
    const self = chrome orelse return;
    const msg = message orelse return;
    nanoui.a11y.announce(self.nswindow, std.mem.span(msg));
}

export fn kea_chrome_stage_view(chrome: ?*KeaChrome) ?*anyopaque {
    const self = chrome orelse return null;
    return @ptrCast(objc.msg(?objc.Object, self.nswindow, "contentView", .{}));
}
