//! The address field as the most basic command line (`AddressCommands.swift`):
//! a handful of words that mean "go here in the app". Only ever the whole of
//! what was typed, so a search that merely starts with one still searches.
//! Off by default (Settings › General › Address bar commands, `commandbar`).
//! Not the menus' commands (P8's `app/commands.zig`): these are words, not keys.
const std = @import("std");
const Browser = @import("browser.zig").Browser;

pub const Command = enum {
    settings,
    new_tab,
    new_private_tab,
    new_space,
    bookmarks,
    history,
    downloads,
    passwords,
    toggle_sidebar,

    /// What you'd type to reach it. The first is what the list shows.
    pub fn aliases(self: Command) []const []const u8 {
        return switch (self) {
            .settings => &.{ "settings", "preferences" },
            .new_tab => &.{"new tab"},
            .new_private_tab => &.{ "new private tab", "private tab" },
            .new_space => &.{"new space"},
            .bookmarks => &.{"bookmarks"},
            .history => &.{"history"},
            .downloads => &.{"downloads"},
            .passwords => &.{"passwords"},
            .toggle_sidebar => &.{ "toggle sidebar", "sidebar" },
        };
    }

    /// `aliases[0].localizedCapitalized`.
    pub fn title(self: Command) []const u8 {
        return switch (self) {
            .settings => "Settings",
            .new_tab => "New Tab",
            .new_private_tab => "New Private Tab",
            .new_space => "New Space",
            .bookmarks => "Bookmarks",
            .history => "History",
            .downloads => "Downloads",
            .passwords => "Passwords",
            .toggle_sidebar => "Toggle Sidebar",
        };
    }

    /// Some only mean something once the feature behind them is on — and,
    /// here, once the panel it opens has been ported (P8's sheets, P10's
    /// passwords): until then the word is not offered rather than doing nothing.
    pub fn available(self: Command, b: *const Browser) bool {
        return switch (self) {
            .new_space => b.prefs.uses_spaces,
            .settings => @hasField(Browser, "tuning"),
            .bookmarks => @hasField(Browser, "bookmarking"),
            .history => @hasField(Browser, "recalling"),
            .downloads => @hasField(Browser, "hoarding"),
            .passwords => @hasField(Browser, "managing"),
            else => true,
        };
    }

    pub fn run(self: Command, b: *Browser) void {
        switch (self) {
            .settings => if (comptime @hasField(Browser, "tuning")) {
                b.tuning = true;
            },
            .new_tab => b.newTab(),
            .new_private_tab => b.newShyTab(),
            .new_space => b.making_space = true,
            .bookmarks => if (comptime @hasField(Browser, "bookmarking")) {
                b.bookmarking = true;
            },
            .history => if (comptime @hasField(Browser, "recalling")) {
                b.recalling = true;
            },
            .downloads => if (comptime @hasField(Browser, "hoarding")) {
                b.hoarding = true;
            },
            .passwords => if (comptime @hasField(Browser, "managing")) {
                b.managing = true;
            },
            .toggle_sidebar => {
                b.prefs.set("sidebar", !b.prefs.sidebar);
                b.syncStageHost();
            },
        }
        b.redraw();
    }
};

/// The command whose words are all that was typed, if any: never a prefix
/// or a near miss, so "settings for gmail" or "sett" still searches.
pub fn matching(typed: []const u8, b: *const Browser) ?Command {
    var buf: [32]u8 = undefined;
    const needle = std.mem.trim(u8, typed, " \t");
    // Longer than every alias: nothing to match.
    if (needle.len > buf.len) return null;
    const low = std.ascii.lowerString(&buf, needle);
    for (std.enums.values(Command)) |cmd| {
        if (!cmd.available(b)) continue;
        for (cmd.aliases()) |a| if (std.mem.eql(u8, a, low)) return cmd;
    }
    return null;
}
