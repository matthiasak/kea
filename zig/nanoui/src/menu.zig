//! Menus built from templates of `MenuItem`, used as the menu bar, context
//! menus and the menus of tray icons, after mygo's.
//!
//!     try app.setMenu(&.{
//!         .{ .role = .app_menu },
//!         .{ .label = "File", .submenu = &.{
//!             .{ .label = "New", .accelerator = "CmdOrCtrl+N", .click = .of(&state, State.new) },
//!             .separator,
//!             .{ .role = .close },
//!         } },
//!         .{ .role = .edit_menu },
//!         .{ .role = .window_menu },
//!     });
const std = @import("std");
const objc = @import("objc.zig");

const menu_types = @import("menu_types.zig");
pub const Kind = menu_types.Kind;
pub const Role = menu_types.Role;
pub const Click = menu_types.Click(Item);
pub const MenuItem = menu_types.MenuItem(Item);

/// An item of a built menu: its state, changeable while the menu shows.
pub const Item = struct {
    menu: *Menu,
    ns: objc.Object,
    id: []const u8,
    kind: Kind,
    checked: bool,
    click: ?Click,
    /// The radio group: items [group_start, group_end) of the menu's list.
    group_start: u32 = 0,
    group_end: u32 = 0,

    pub fn setChecked(it: *Item, on: bool) void {
        if (on and it.kind == .radio) {
            for (it.menu.items.items[it.group_start..it.group_end]) |*other| other.applyChecked(false);
        }
        it.applyChecked(on);
    }

    fn applyChecked(it: *Item, on: bool) void {
        it.checked = on;
        objc.msg(void, it.ns, "setState:", .{@as(objc.NSInteger, @intFromBool(on))});
    }

    pub fn setEnabled(it: *Item, on: bool) void {
        objc.msg(void, it.ns, "setEnabled:", .{on});
    }

    pub fn setLabel(it: *Item, label: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, it.ns, "setTitle:", .{objc.nsString(label)});
    }
};

pub const Menu = struct {
    gpa: std.mem.Allocator,
    ns: objc.Object,
    target: objc.Object,
    items: std.ArrayList(Item) = .empty,
    /// The window menu, for `NSApp.windowsMenu`.
    windows_menu: ?objc.Object = null,

    pub fn create(gpa: std.mem.Allocator, app_name: []const u8, template: []const MenuItem) !*Menu {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try gpa.create(Menu);
        errdefer gpa.destroy(self);
        const target_class = objc.defineClass(.{
            .name = "NanoUIMenuTarget",
            .methods = &.{.{ .name = "itemClicked:", .imp = &itemClicked, .types = "v@:@" }},
        });
        const target = objc.msg(objc.Object, target_class, "new", .{});
        objc.setZig(target, self);
        self.* = .{ .gpa = gpa, .ns = objc.new("NSMenu"), .target = target };
        // Items keep pointers into the list: size it first.
        try self.items.ensureTotalCapacity(gpa, countItems(template, app_name));
        try self.build(self.ns, app_name, template);
        objc.msg(void, self.ns, "setAutoenablesItems:", .{objc.NO});
        return self;
    }

    pub fn destroy(self: *Menu) void {
        objc.setZig(self.target, null);
        objc.release(self.target);
        objc.release(self.ns);
        self.items.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The item whose template had `id`.
    pub fn item(self: *Menu, id: []const u8) ?*Item {
        for (self.items.items) |*it| if (std.mem.eql(u8, it.id, id)) return it;
        return null;
    }

    /// Shows the menu as a context menu at `x`, `y` (points, top left) of
    /// `view`, until the user picks an item or dismisses it.
    pub fn popup(self: *Menu, view: objc.Object, x: f64, y: f64) void {
        const flipped = objc.msg(objc.BOOL, view, "isFlipped", .{});
        const h = objc.msg(objc.CGRect, view, "bounds", .{}).size.height;
        const at: objc.CGPoint = .{ .x = x, .y = if (flipped) y else h - y };
        _ = objc.msg(objc.BOOL, self.ns, "popUpMenuPositioningItem:atLocation:inView:", .{ @as(?objc.Object, null), at, view });
    }

    fn build(self: *Menu, menu: objc.Object, app_name: []const u8, template: []const MenuItem) error{OutOfMemory}!void {
        var group_start: ?u32 = null;
        for (template) |t| {
            if (t.role) |r| if (expand(r)) |items| {
                const sub = t.submenu orelse items;
                try self.addSubmenu(menu, app_name, if (t.label.len > 0) t.label else wholeMenuTitle(r, app_name), sub);
                if (r == .window_menu) self.windows_menu = objc.msg(objc.Object, objc.msg(objc.Object, objc.msg(objc.Object, menu, "itemArray", .{}), "lastObject", .{}), "submenu", .{});
                group_start = null;
                continue;
            };
            if (t.is_separator) {
                objc.msg(void, menu, "addItem:", .{objc.msg(objc.Object, objc.class("NSMenuItem"), "separatorItem", .{})});
                group_start = null;
                continue;
            }
            if (t.hidden) continue;
            if (t.submenu) |sub| {
                try self.addSubmenu(menu, app_name, t.label, sub);
                group_start = null;
                continue;
            }
            const index: u32 = @intCast(self.items.items.len);
            const ns = makeItem(t, app_name);
            objc.msg(void, menu, "addItem:", .{ns});
            objc.release(ns);
            if (t.role == null or t.click != null) {
                objc.msg(void, ns, "setTarget:", .{self.target});
                objc.msg(void, ns, "setAction:", .{objc.sel("itemClicked:")});
            }
            objc.msg(void, ns, "setTag:", .{@as(objc.NSInteger, index)});
            if (t.kind == .radio) {
                if (group_start == null) group_start = index;
            } else group_start = null;
            self.items.appendAssumeCapacity(.{ .menu = self, .ns = ns, .id = t.id, .kind = t.kind, .checked = t.checked, .click = t.click });
            const it = &self.items.items[index];
            if (t.kind == .radio) {
                const gs = group_start.?;
                for (self.items.items[gs .. index + 1]) |*member| {
                    member.group_start = gs;
                    member.group_end = index + 1;
                }
            }
            it.applyChecked(t.checked);
        }
    }

    fn addSubmenu(self: *Menu, menu: objc.Object, app_name: []const u8, title: []const u8, template: []const MenuItem) error{OutOfMemory}!void {
        const holder = objc.new("NSMenuItem");
        defer objc.release(holder);
        objc.msg(void, holder, "setTitle:", .{objc.nsString(title)});
        const sub = objc.msg(objc.Object, objc.alloc("NSMenu"), "initWithTitle:", .{objc.nsString(title)});
        defer objc.release(sub);
        objc.msg(void, sub, "setAutoenablesItems:", .{objc.NO});
        try self.build(sub, app_name, template);
        objc.msg(void, holder, "setSubmenu:", .{sub});
        objc.msg(void, menu, "addItem:", .{holder});
    }
};

fn countItems(template: []const MenuItem, app_name: []const u8) usize {
    var n: usize = 0;
    for (template) |t| {
        if (t.role) |r| if (expand(r)) |items| {
            n += countItems(t.submenu orelse items, app_name);
            continue;
        };
        if (t.submenu) |sub| n += countItems(sub, app_name) else n += 1;
    }
    return n;
}

/// The items of a whole-menu role.
fn expand(r: Role) ?[]const MenuItem {
    return switch (r) {
        .app_menu => &.{ .{ .role = .about }, .separator, .{ .role = .hide }, .{ .role = .hide_others }, .{ .role = .unhide }, .separator, .{ .role = .quit } },
        .edit_menu => &.{ .{ .role = .undo }, .{ .role = .redo }, .separator, .{ .role = .cut }, .{ .role = .copy }, .{ .role = .paste }, .{ .role = .select_all } },
        .view_menu => &.{.{ .role = .toggle_full_screen }},
        .window_menu => &.{ .{ .role = .minimize }, .{ .role = .zoom }, .separator, .{ .role = .front }, .separator, .{ .role = .close } },
        else => null,
    };
}

fn wholeMenuTitle(r: Role, app_name: []const u8) []const u8 {
    return switch (r) {
        .app_menu => app_name,
        .edit_menu => "Edit",
        .view_menu => "View",
        else => "Window",
    };
}

const RoleInfo = struct { label: []const u8, action: [:0]const u8, accel: []const u8 = "" };

fn roleInfo(r: Role) RoleInfo {
    return switch (r) {
        .about => .{ .label = "About {s}", .action = "orderFrontStandardAboutPanel:" },
        .hide => .{ .label = "Hide {s}", .action = "hide:", .accel = "Cmd+H" },
        .hide_others => .{ .label = "Hide Others", .action = "hideOtherApplications:", .accel = "Cmd+Alt+H" },
        .unhide => .{ .label = "Show All", .action = "unhideAllApplications:" },
        .quit => .{ .label = "Quit {s}", .action = "terminate:", .accel = "Cmd+Q" },
        .undo => .{ .label = "Undo", .action = "undo:", .accel = "Cmd+Z" },
        .redo => .{ .label = "Redo", .action = "redo:", .accel = "Cmd+Shift+Z" },
        .cut => .{ .label = "Cut", .action = "cut:", .accel = "Cmd+X" },
        .copy => .{ .label = "Copy", .action = "copy:", .accel = "Cmd+C" },
        .paste => .{ .label = "Paste", .action = "paste:", .accel = "Cmd+V" },
        .delete => .{ .label = "Delete", .action = "delete:" },
        .select_all => .{ .label = "Select All", .action = "selectAll:", .accel = "Cmd+A" },
        .minimize => .{ .label = "Minimize", .action = "performMiniaturize:", .accel = "Cmd+M" },
        .zoom => .{ .label = "Zoom", .action = "performZoom:" },
        .close => .{ .label = "Close Window", .action = "performClose:", .accel = "Cmd+W" },
        .toggle_full_screen => .{ .label = "Enter Full Screen", .action = "toggleFullScreen:", .accel = "Cmd+Ctrl+F" },
        .front => .{ .label = "Bring All to Front", .action = "arrangeInFront:" },
        else => .{ .label = "", .action = "noop:" },
    };
}

fn makeItem(t: MenuItem, app_name: []const u8) objc.Object {
    var buf: [256]u8 = undefined;
    var label = t.label;
    var accel = t.accelerator;
    var action: [:0]const u8 = "itemClicked:";
    if (t.role) |r| {
        const info = roleInfo(r);
        if (label.len == 0) label = if (std.mem.indexOf(u8, info.label, "{s}")) |i|
            std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ info.label[0..i], app_name, info.label[i + 3 ..] }) catch info.label
        else
            info.label;
        if (accel.len == 0) accel = info.accel;
        action = info.action;
    }
    const parsed = parseAccelerator(accel);
    var key_buf: [8]u8 = undefined;
    const key = parsed.keyString(&key_buf);
    const ns = objc.msg(objc.Object, objc.alloc("NSMenuItem"), "initWithTitle:action:keyEquivalent:", .{
        objc.nsString(label), objc.sel(action), objc.nsString(key),
    });
    if (key.len > 0) objc.msg(void, ns, "setKeyEquivalentModifierMask:", .{parsed.mods});
    if (t.disabled) objc.msg(void, ns, "setEnabled:", .{objc.NO});
    if (t.tooltip.len > 0) objc.msg(void, ns, "setToolTip:", .{objc.nsString(t.tooltip)});
    return ns;
}

pub const Accelerator = menu_types.Accelerator;
pub const mod_shift = menu_types.mod_shift;
pub const mod_ctrl = menu_types.mod_ctrl;
pub const mod_alt = menu_types.mod_alt;
pub const mod_cmd = menu_types.mod_cmd;
pub const parseAccelerator = menu_types.parseAccelerator;

fn itemClicked(self_obj: objc.Object, _: objc.SEL, sender: objc.Object) callconv(.c) void {
    const menu = objc.getZig(Menu, self_obj) orelse return;
    const tag: usize = @intCast(objc.msg(objc.NSInteger, sender, "tag", .{}));
    if (tag >= menu.items.items.len) return;
    const it = &menu.items.items[tag];
    switch (it.kind) {
        .checkbox => it.setChecked(!it.checked),
        .radio => it.setChecked(true),
        .normal => {},
    }
    if (it.click) |c| c.func(c.ctx, it);
}
