//! Tray icons: items in the menu bar's status area, with a menu, a title,
//! or an SF Symbol as their icon.
const std = @import("std");
const objc = @import("objc.zig");
const menu_mod = @import("menu.zig");

pub const Options = struct {
    /// Text shown in the menu bar.
    title: []const u8 = "",
    /// The name of an SF Symbol ("star.fill"), drawn as a template image
    /// that follows the menu bar's appearance.
    symbol: []const u8 = "",
    tooltip: []const u8 = "",
    menu: []const menu_mod.MenuItem = &.{},
};

pub const Tray = struct {
    gpa: std.mem.Allocator,
    item: objc.Object,
    menu: ?*menu_mod.Menu = null,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, opts: Options) !*Tray {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        const bar = objc.msg(objc.Object, objc.class("NSStatusBar"), "systemStatusBar", .{});
        // NSVariableStatusItemLength is -1.
        const item = objc.retain(objc.msg(objc.Object, bar, "statusItemWithLength:", .{@as(f64, -1)}));
        self.* = .{ .gpa = gpa, .item = item };
        self.setTitle(opts.title);
        if (opts.symbol.len > 0) self.setSymbol(opts.symbol);
        if (opts.tooltip.len > 0) {
            const button = objc.msg(objc.Object, item, "button", .{});
            objc.msg(void, button, "setToolTip:", .{objc.nsString(opts.tooltip)});
        }
        if (opts.menu.len > 0) try self.setMenu(app_name, opts.menu);
        return self;
    }

    pub fn destroy(self: *Tray) void {
        const bar = objc.msg(objc.Object, objc.class("NSStatusBar"), "systemStatusBar", .{});
        objc.msg(void, bar, "removeStatusItem:", .{self.item});
        objc.release(self.item);
        if (self.menu) |m| m.destroy();
        self.gpa.destroy(self);
    }

    pub fn setTitle(self: *Tray, title: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        objc.msg(void, button, "setTitle:", .{objc.nsString(title)});
    }

    pub fn setSymbol(self: *Tray, name: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const button = objc.msg(objc.Object, self.item, "button", .{});
        const img = objc.msg(?objc.Object, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{
            objc.nsString(name), @as(?objc.Object, null),
        }) orelse return;
        objc.msg(void, img, "setTemplate:", .{objc.YES});
        objc.msg(void, button, "setImage:", .{img});
    }

    pub fn setMenu(self: *Tray, app_name: []const u8, template: []const menu_mod.MenuItem) !void {
        const m = try menu_mod.Menu.create(self.gpa, app_name, template);
        if (self.menu) |old| old.destroy();
        self.menu = m;
        objc.msg(void, self.item, "setMenu:", .{m.ns});
    }
};
