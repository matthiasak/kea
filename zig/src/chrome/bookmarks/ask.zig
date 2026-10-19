//! The questions the bookmarks ask (`Ask.name`, `Ask.sure`, `Ask.bookmark`
//! in Spaces.swift; `askNewFolder`, `askGroup`, `askRemove` in
//! Bookmarks.swift), as sheets on the window. A window that isn't on
//! screen (headless tests) is asked nothing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Browser = @import("../../model/browser.zig").Browser;
const Kea = @import("../../app/kea.zig").Kea;
const bm = @import("../../data/bookmarks.zig");
const Bookmark = bm.Bookmark;
const Bookmarks = bm.Bookmarks;
const Uuid = @import("../../data/json.zig").Uuid;
const address = @import("../../model/address.zig");
const appkit = @import("../../sys/appkit.zig");
const state = @import("state.zig");
const actions = @import("actions.zig");

const Kind = enum { new_folder, card_folder, group, remove, rename_folder, rename_bookmark, edit, open_many, duplicates };

const Asked = struct {
    kea: *Kea,
    record: Uuid,
    kind: Kind,
    /// What it is about (c_allocator).
    ids: []Uuid,
    /// The folder a new one goes in; a list whose folders open to show it.
    parent: ?Uuid = null,
    list: ?state.List = null,
    new_window: bool = false,
    fields: [2]?objc.Object = .{ null, null },
    alert: ?objc.Object = null,

    fn browser(self: *Asked) ?*Browser {
        for (self.kea.browsers.items) |b| if (b.record_id.eql(self.record)) return b;
        return null;
    }

    fn free(self: *Asked) void {
        for (self.fields) |f| if (f) |o| objc.release(o);
        if (self.alert) |o| objc.release(o);
        std.heap.c_allocator.free(self.ids);
        std.heap.c_allocator.destroy(self);
    }

    fn done(self: *Asked, a: appkit.Answer) void {
        defer self.free();
        const b = self.browser() orelse return;
        defer b.redraw();
        if (!a.ok) return;
        const marks = b.bookmarks;
        switch (self.kind) {
            .new_folder, .card_folder => {
                if (a.text.len == 0) return;
                const made = Bookmark.folder(a.text, @constCast(&[_]Bookmark{}));
                marks.insert(made, if (self.kind == .card_folder) null else self.parent, null);
                if (self.kind == .card_folder) {
                    if (self.ids.len > 0) marks.move(self.ids[0..1], made.id, null);
                } else if (self.list) |l| if (self.parent) |p| b.marks_ui.expanded(l).put(b.gpa, p);
            },
            .group => {
                if (a.text.len == 0) return;
                const made = marks.group(self.ids, a.text) orelse return;
                if (self.list) |l| openTo(b, l, made);
            },
            .rename_folder => if (a.text.len > 0) marks.update(self.ids[0], a.text, null),
            .rename_bookmark => marks.update(self.ids[0], a.text, null),
            .remove, .duplicates => marks.remove(self.ids),
            .open_many => {
                var arena = std.heap.ArenaAllocator.init(b.gpa);
                defer arena.deinit();
                actions.openNow(b, actions.nodesOf(arena.allocator(), marks, self.ids), self.new_window);
            },
            .edit => {},
        }
    }

    /// `Ask.bookmark`: Save, with the name and address as typed; either
    /// left empty is left as it was.
    fn edited(self: *Asked, response: objc.NSInteger) void {
        defer self.free();
        const b = self.browser() orelse return;
        if (response != 1000) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        const name = text(self.fields[0].?);
        const typed = text(self.fields[1].?);
        const url = address.url(b.gpa, typed) catch null;
        defer if (url) |u| b.gpa.free(u);
        if (typed.len > 0 and url == null) nanoui.shell.beep();
        b.bookmarks.update(self.ids[0], if (name.len == 0) null else name, url);
        b.redraw();
    }
};

fn text(field: objc.Object) []const u8 {
    return std.mem.trim(u8, objc.fromNSString(objc.msg(objc.Object, field, "stringValue", .{})), " \t\r\n");
}

/// The folders down to `id` open, and `id` itself.
pub fn openTo(b: *Browser, list: state.List, id: Uuid) void {
    const open = b.marks_ui.expanded(list);
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    if (b.bookmarks.pathTo(arena.allocator(), id) catch null) |path| for (path) |n| open.put(b.gpa, n.id);
    open.put(b.gpa, id);
}

fn make(b: *Browser, kind: Kind, ids: []const Uuid) ?*Asked {
    if (b.kea.opts.headless) return null;
    const a = std.heap.c_allocator.create(Asked) catch return null;
    const owned = std.heap.c_allocator.dupe(Uuid, ids) catch {
        std.heap.c_allocator.destroy(a);
        return null;
    };
    a.* = .{ .kea = b.kea, .record = b.record_id, .kind = kind, .ids = owned };
    return a;
}

fn window(b: *Browser) ?objc.Object {
    return if (b.window) |w| w.nswindow else null;
}

fn idsOf(nodes: []const Bookmark, out: []Uuid) []Uuid {
    for (nodes, out) |n, *o| o.* = n.id;
    return out[0..nodes.len];
}

/// A folder of your own inside `parent` (the top level for null), its name
/// asked for; the list it was asked from opens to it.
pub fn newFolder(b: *Browser, parent: ?Uuid, list: ?state.List) void {
    const a = make(b, .new_folder, &.{}) orelse return;
    a.parent = parent;
    a.list = list;
    appkit.ask(window(b), .{ .title = "New Folder", .field = .{ .placeholder = "Folder name" }, .confirm = "Make" }, a, Asked.done);
}

/// The card's New Folder…: made at the top level, the card's bookmark in it.
pub fn cardFolder(b: *Browser, id: Uuid) void {
    const a = make(b, .card_folder, &.{id}) orelse return;
    appkit.ask(window(b), .{ .title = "New Folder", .field = .{ .placeholder = "Name" }, .confirm = "Create" }, a, Asked.done);
}

/// `nodes` moved into a folder named by the user, where the first was.
pub fn group(b: *Browser, ids: []const Uuid, list: ?state.List) void {
    const a = make(b, .group, ids) orelse return;
    a.list = list;
    appkit.ask(window(b), .{ .title = "New Folder with Selection", .field = .{ .placeholder = "Folder name" }, .confirm = "Make" }, a, Asked.done);
}

/// `askRemove`: a folder with bookmarks in it asks first, since they all go
/// with it; anything else goes at once.
pub fn remove(b: *Browser, nodes: []const Bookmark) void {
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const ids = idsOf(nodes, ar.alloc(Uuid, nodes.len) catch return);
    var full: usize = 0;
    var inside: usize = 0;
    for (nodes) |n| if (n.isFolder() and n.kids().len > 0) {
        full += 1;
        inside += Bookmarks.count(n.children.?);
    };
    if (full == 0) {
        b.bookmarks.remove(ids);
        return b.redraw();
    }
    const them = if (full == 1) "it" else "them";
    const detail = switch (inside) {
        0 => std.fmt.allocPrint(ar, "The empty folders in {s} go too.", .{them}),
        1 => std.fmt.allocPrint(ar, "The bookmark in {s} goes too.", .{them}),
        else => std.fmt.allocPrint(ar, "The {d} bookmarks in {s} go too.", .{ inside, them }),
    } catch return;
    const title = (if (nodes.len == 1)
        std.fmt.allocPrint(ar, "Remove \u{201C}{s}\u{201D}?", .{nodes[0].title})
    else
        std.fmt.allocPrint(ar, "Remove {d} items?", .{nodes.len})) catch return;
    const a = make(b, .remove, ids) orelse return;
    appkit.ask(window(b), .{ .title = title, .detail = detail, .confirm = "Remove", .destructive = true }, a, Asked.done);
}

/// A name of your own for a bookmark or a folder. An empty one changes
/// nothing for a folder; a bookmark left without one is its icon alone on
/// the bar.
pub fn rename(b: *Browser, node: Bookmark) void {
    if (node.isFolder()) {
        const a = make(b, .rename_folder, &.{node.id}) orelse return;
        return appkit.ask(window(b), .{ .title = "Rename Folder", .field = .{ .placeholder = node.title, .initial = node.title }, .confirm = "Rename" }, a, Asked.done);
    }
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const a = make(b, .rename_bookmark, &.{node.id}) orelse return;
    appkit.ask(window(b), .{
        .title = "Rename Bookmark",
        .detail = "Without a name, the bookmarks bar shows its icon alone.",
        .field = .{ .placeholder = node.label(arena.allocator()) catch node.title, .initial = node.title },
        .confirm = "Rename",
    }, a, Asked.done);
}

/// `Ask.bookmark`: a bookmark's name and address, in one sheet.
pub fn edit(b: *Browser, node: Bookmark) void {
    const a = make(b, .edit, &.{node.id}) orelse return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const alert = objc.new("NSAlert");
    objc.msg(void, alert, "setMessageText:", .{objc.nsString("Edit Bookmark")});
    const box = objc.msg(objc.Object, objc.alloc("NSView"), "initWithFrame:", .{objc.CGRect{ .size = .{ .width = 260, .height = 56 } }});
    defer objc.release(box);
    const lines = [2]struct { y: f64, placeholder: []const u8, value: []const u8 }{
        .{ .y = 32, .placeholder = "Name", .value = node.title },
        .{ .y = 0, .placeholder = "Address", .value = node.url orelse "" },
    };
    for (lines, 0..) |l, i| {
        const f = objc.msg(objc.Object, objc.alloc("NSTextField"), "initWithFrame:", .{objc.CGRect{ .origin = .{ .y = l.y }, .size = .{ .width = 260, .height = 24 } }});
        objc.msg(void, f, "setPlaceholderString:", .{objc.nsString(l.placeholder)});
        objc.msg(void, f, "setStringValue:", .{objc.nsString(l.value)});
        objc.msg(void, box, "addSubview:", .{f});
        a.fields[i] = f;
    }
    objc.msg(void, alert, "setAccessoryView:", .{box});
    _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString("Save")});
    _ = objc.msg(objc.Object, alert, "addButtonWithTitle:", .{objc.nsString("Cancel")});
    objc.msg(void, objc.msg(objc.Object, alert, "window", .{}), "setInitialFirstResponder:", .{a.fields[0].?});
    a.alert = alert;
    appkit.beginSheet(alert, window(b), a, Asked.edited);
}

/// More than 20 pages ask before they open.
pub fn openMany(b: *Browser, nodes: []const Bookmark, pages: usize, new_window: bool) void {
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const a = make(b, .open_many, idsOf(nodes, ar.alloc(Uuid, nodes.len) catch return)) orelse return;
    a.new_window = new_window;
    const title = std.fmt.allocPrint(ar, "Open {d} pages?", .{pages}) catch return a.free();
    appkit.ask(window(b), .{ .title = title, .detail = "Each in a tab of its own.", .confirm = "Open", .destructive = true }, a, Asked.done);
}

/// Remove Duplicates…: the first of each address stays.
pub fn duplicates(b: *Browser) void {
    var arena = std.heap.ArenaAllocator.init(b.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const extra = b.bookmarks.duplicates(ar) catch return;
    if (extra.len == 0) return b.announce("No duplicates");
    const title = std.fmt.allocPrint(ar, "Remove {d} duplicate{s}?", .{ extra.len, if (extra.len == 1) "" else "s" }) catch return;
    const a = make(b, .duplicates, extra) orelse return;
    appkit.ask(window(b), .{ .title = title, .detail = "The first of each address stays where it is.", .confirm = "Remove", .destructive = true }, a, Asked.done);
}
