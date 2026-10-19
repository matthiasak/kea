//! Dialogs' options and answers, the same on every platform.
const std = @import("std");

pub const OpenOptions = struct {
    title: []const u8 = "",
    /// The button's label ("Open" by default).
    button: []const u8 = "",
    message: []const u8 = "",
    directory: []const u8 = "",
    files: bool = true,
    directories: bool = false,
    multiple: bool = false,
    /// File name extensions allowed, without dots: `&.{ "png", "jpg" }`.
    extensions: []const []const u8 = &.{},
    show_hidden: bool = false,
};

pub const SaveOptions = struct {
    title: []const u8 = "",
    button: []const u8 = "",
    message: []const u8 = "",
    directory: []const u8 = "",
    /// The file name the panel starts with.
    name: []const u8 = "",
    extensions: []const []const u8 = &.{},
    show_hidden: bool = false,
    create_directories: bool = true,
};

pub const MessageKind = enum { info, warning, critical };

pub const MessageOptions = struct {
    title: []const u8,
    detail: []const u8 = "",
    kind: MessageKind = .info,
    /// Button labels, the first the default; "OK" when empty.
    buttons: []const []const u8 = &.{},
    /// A checkbox under the detail ("Don't ask again"), off when empty.
    checkbox: []const u8 = "",
};

pub const MessageResult = struct {
    /// The index of the button pressed.
    button: usize,
    checked: bool = false,
};

pub fn freePaths(gpa: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}
