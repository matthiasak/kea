//! Menus where nanoui handles them itself (Linux, Windows, Android), from the same
//! templates: kept for their accelerators, which keys reach before the
//! view does ("CmdOrCtrl" is Ctrl there), and their items' state. Native
//! menu bars are not built yet.
const std = @import("std");
const menu_types = @import("menu_types.zig");
const ui = @import("ui/ui.zig");

pub const Kind = menu_types.Kind;
pub const Role = menu_types.Role;
pub const Click = menu_types.Click(Item);
pub const MenuItem = menu_types.MenuItem(Item);
pub const parseAccelerator = menu_types.parseAccelerator;

pub const Item = struct {
    menu: *Menu,
    id: []const u8,
    label: []u8,
    kind: Kind,
    checked: bool,
    disabled: bool,
    click: ?Click,
    role: ?Role,
    accel: menu_types.Accelerator,

    pub fn setChecked(self: *Item, on: bool) void {
        self.checked = on;
    }

    pub fn setEnabled(self: *Item, on: bool) void {
        self.disabled = !on;
    }

    pub fn setAccelerator(self: *Item, accel: []const u8) void {
        self.accel = parseAccelerator(accel);
    }
};

pub const Menu = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,

    pub fn create(gpa: std.mem.Allocator, template: []const MenuItem) !*Menu {
        const m = try gpa.create(Menu);
        m.* = .{ .gpa = gpa };
        errdefer m.destroy();
        try m.add(template, "");
        return m;
    }

    fn add(m: *Menu, template: []const MenuItem, prefix: []const u8) !void {
        for (template) |t| {
            if (t.is_separator or t.hidden) continue;
            const full = if (prefix.len > 0 and t.label.len > 0)
                try std.fmt.allocPrint(m.gpa, "{s} \u{203A} {s}", .{ prefix, t.label })
            else
                try m.gpa.dupe(u8, t.label);
            if (t.submenu) |sub| {
                defer m.gpa.free(full);
                try m.add(sub, full);
                continue;
            }
            errdefer m.gpa.free(full);
            try m.items.append(m.gpa, .{
                .menu = m,
                .id = t.id,
                .label = full,
                .kind = t.kind,
                .checked = t.checked,
                .disabled = t.disabled,
                .click = t.click,
                .role = t.role,
                .accel = parseAccelerator(t.accelerator),
            });
        }
    }

    pub fn destroy(m: *Menu) void {
        for (m.items.items) |it| m.gpa.free(it.label);
        m.items.deinit(m.gpa);
        m.gpa.destroy(m);
    }

    pub fn item(m: *Menu, id: []const u8) ?*Item {
        for (m.items.items) |*it| if (std.mem.eql(u8, it.id, id)) return it;
        return null;
    }

    /// The item whose accelerator is this key combination, if one is.
    pub fn match(m: *Menu, sc: ui.Shortcut) ?*Item {
        for (m.items.items) |*it| {
            const a = it.accel;
            if (a.key == 0 or it.disabled) continue;
            // Cmd (CmdOrCtrl) and Ctrl are both Ctrl on Linux.
            const ctrl = a.mods & (menu_types.mod_cmd | menu_types.mod_ctrl) != 0;
            const shift = a.mods & menu_types.mod_shift != 0;
            const alt = a.mods & menu_types.mod_alt != 0;
            if (a.key == sc.key and ctrl == sc.ctrl and shift == sc.shift and alt == sc.alt) return it;
        }
        return null;
    }

    /// Runs an item as a click would.
    pub fn activate(it: *Item) void {
        switch (it.kind) {
            .checkbox => it.checked = !it.checked,
            .radio => it.checked = true,
            .normal => {},
        }
        if (it.click) |c| c.func(c.ctx, it);
    }

    /// Context/popup trigger on platforms without AppKit NSMenu.
    pub fn popup(m: *Menu, view: anytype, x: f32, y: f32) void {
        if (comptime @import("builtin").os.tag == .ios) {
            @import("ios/dialog.zig").popupMenu(m, view, x, y);
        }
    }
};
