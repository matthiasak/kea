//! The menu commands and the key each has unless you give it another
//! (`Command`, Shortcuts.swift:119-237): the same ids, titles, sections,
//! keys, order and actions as the menus. The menus (app/menus.zig) and the
//! key monitor (app/keys.zig) run them.
const std = @import("std");
const app_name = @import("kea.zig").app_name;
const shortcuts = @import("shortcuts.zig");
const KeyCombo = shortcuts.KeyCombo;
const k = shortcuts.combo;
const Browser = @import("../model/browser.zig").Browser;
const browsers = @import("browsers.zig");
const sheet = @import("../chrome/sheet.zig");
const history_panel = @import("../chrome/history_panel.zig");
const downloads_panel = @import("../chrome/downloads_panel.zig");
const hidden_panel = @import("../chrome/hidden_panel.zig");
const side_panels = @import("../chrome/side_panels.zig");
const fold = @import("../chrome/fold.zig");
const page_find = @import("../web/page_find.zig");
const curtain_js = @import("../web/curtain_js.zig");
const inspector = @import("../web/inspector.zig");

pub const Section = enum {
    app,
    file,
    edit,
    view,
    tabs,
    bookmarks,
    history,

    /// The menu it is in (the app's menu is the app's name).
    pub fn title(s: Section) []const u8 {
        return switch (s) {
            .app => app_name,
            .file => "File",
            .edit => "Edit",
            .view => "View",
            .tabs => "Tabs",
            .bookmarks => "Bookmarks",
            .history => "History",
        };
    }
};

pub const Command = struct {
    id: []const u8,
    title: []const u8,
    section: Section,
    default_key: ?KeyCombo,
    run: *const fn (*Browser) void,
};

fn c(id: []const u8, title: []const u8, section: Section, key: ?KeyCombo, run: *const fn (*Browser) void) Command {
    return .{ .id = id, .title = title, .section = section, .default_key = key, .run = run };
}

/// `Command.all`, in the menus' order.
pub const all = [_]Command{
    c("app.settings", "Settings…", .app, k(",", .{}), act.settings),
    c("app.welcome", "Welcome…", .app, null, act.welcome),
    c("app.passwords", "Passwords…", .app, k("l", .{ .option = true }), act.passwords),

    c("file.newWindow", "New Window", .file, k("n", .{}), act.newWindow),
    c("file.newTab", "New Tab", .file, k("t", .{}), Browser.newTab),
    c("file.newPrivateTab", "New Private Tab", .file, k("n", .{ .shift = true }), Browser.newShyTab),
    c("file.reopen", "Reopen Closed Tab", .file, k("t", .{ .shift = true }), Browser.reopen),
    c("file.openAddress", "Open Address…", .file, k("l", .{}), Browser.edit),
    c("file.closeTab", "Close Tab", .file, k("w", .{}), Browser.closeFront),
    c("file.import", "Bring Things Over…", .file, null, act.bringIn),
    c("file.share", "Share…", .file, null, Browser.share),
    c("file.print", "Print…", .file, k("p", .{}), Browser.printPage),

    c("edit.find", "Find on Page…", .edit, k("f", .{}), page_find.openFind),
    c("edit.findNext", "Find Next", .edit, k("g", .{}), act.findNext),
    c("edit.findPrevious", "Find Previous", .edit, k("g", .{ .shift = true }), act.findPrevious),

    c("view.sidebar", "Show Tabs in Sidebar", .view, k("s", .{ .shift = true }), act.toggleSidebar),
    c("view.fold", "Hide Sidebar or Tab Bar", .view, k("s", .{}), fold.toggleFold),
    c("view.reload", "Reload Page", .view, k("r", .{}), act.reload),
    c("view.reloadOrigin", "Reload Page From Origin", .view, k("r", .{ .option = true }), act.reloadFromOrigin),
    c("view.stop", "Stop Loading", .view, k(".", .{}), act.stop),
    c("view.reader", "Reading Mode", .view, k("r", .{ .shift = true }), @import("../web/reader.zig").toggleReader),
    c("view.float", "Float Video", .view, k("p", .{ .shift = true }), @import("../web/float.zig").toggle),
    c("view.summarize", "Summarize Page", .view, null, act.summarize),
    c("view.ask", "Ubi Chat", .view, k("y", .{ .shift = true }), act.chat),
    c("view.hide", "Hide Elements…", .view, k("h", .{ .shift = true }), curtain_js.toggleHiding),
    c("view.hidden", "Hidden on This Site…", .view, k("u", .{ .shift = true }), hidden_panel.toggle),
    c("view.zoomIn", "Zoom In", .view, k("+", .{}), act.zoomIn),
    c("view.zoomOut", "Zoom Out", .view, k("-", .{}), act.zoomOut),
    c("view.actualSize", "Actual Size", .view, k("0", .{}), act.actualSize),
    c("view.inspector", "Web Inspector", .view, k("i", .{ .option = true }), inspector.toggleInspector),
    c("view.console", "JavaScript Console", .view, k("j", .{ .option = true }), inspector.showConsole),
    c("view.inspect", "Inspect Element", .view, k("c", .{ .option = true }), inspector.inspectElement),

    c("tabs.back", "Back", .tabs, k("[", .{}), act.back),
    c("tabs.forward", "Forward", .tabs, k("]", .{}), act.forward),
    c("tabs.next", "Next Tab", .tabs, k("]", .{ .shift = true }), act.next),
    c("tabs.previous", "Previous Tab", .tabs, k("[", .{ .shift = true }), act.previous),
    c("tabs.search", "Search Tabs…", .tabs, k("k", .{}), act.search),
    // ⌥⌘N, Chrome's on the Mac: ⌃⌘S is the Mac's own Show Sidebar.
    c("tabs.split", "Split Current Page", .tabs, k("n", .{ .option = true }), act.split),
    c("tabs.focusLeftPane", "Focus Left Page", .tabs, k("left", .{ .control = true }), act.focusLeft),
    c("tabs.focusRightPane", "Focus Right Page", .tabs, k("right", .{ .control = true }), act.focusRight),
    c("tabs.focusOtherPane", "Focus Other Page", .tabs, null, act.focusOther),
    c("tabs.swapSplit", "Swap Pages", .tabs, null, act.swap),
    c("tabs.separateSplit", "Separate Split Tabs", .tabs, null, act.separate),
    c("tabs.rename", "Rename Tab", .tabs, null, act.rename),
    c("tabs.duplicate", "Duplicate Tab", .tabs, k("d", .{}), Browser.duplicate),
    c("tabs.copyAddress", "Copy Address", .tabs, k("c", .{ .shift = true }), Browser.copyAddress),
    c("tabs.copyMarkdown", "Copy as Markdown Link", .tabs, null, Browser.copyMarkdownLink),
    c("tabs.pasteAndGo", "Paste and Go", .tabs, k("v", .{ .shift = true }), Browser.pasteAndGo),
    c("tabs.closeOthers", "Close Other Tabs", .tabs, null, act.closeOthers),
    c("tabs.mute", "Stop Sound in Tab", .tabs, k("m", .{ .shift = true }), Browser.pauseMedia),

    c("bookmarks.add", "Add This Page", .bookmarks, k("b", .{ .shift = true }), Browser.bookmarkCurrent),
    c("bookmarks.show", "Show Bookmarks…", .bookmarks, k("b", .{ .option = true }), act.bookmarking),
    c("bookmarks.bar", "Show Bookmarks Bar", .bookmarks, null, act.bookmarksBar),
    c("bookmarks.sidebar", "Show Bookmarks Sidebar", .bookmarks, k("b", .{ .control = true }), act.bookmarksSidebar),

    c("history.show", "Show History…", .history, k("y", .{}), history_panel.toggle),
    c("history.downloads", "Downloads…", .history, k("j", .{ .shift = true }), downloads_panel.toggle),
    c("history.clearData", "Clear Browsing Data…", .history, k("delete", .{ .shift = true }), history_panel.showClearing),
    c("history.clear", "Clear History", .history, null, Browser.clearHistory),
};

/// What each does (`Command.run`), where it isn't a model call of its own.
const act = struct {
    fn settings(b: *Browser) void {
        sheet.toggle(b, .tuning);
    }
    fn welcome(b: *Browser) void {
        b.welcoming = true;
        b.redraw();
    }
    // Passwords (P10) and Bring Things Over (P11) do something once their panels exist.
    fn passwords(b: *Browser) void {
        if (comptime @hasField(Browser, "managing")) b.managing = true;
        b.redraw();
    }
    fn bringIn(b: *Browser) void {
        if (comptime @hasField(Browser, "bringing_in")) b.bringing_in = "";
        b.redraw();
    }
    fn newWindow(b: *Browser) void {
        _ = browsers.newWindow(b.kea) catch {};
    }
    fn findNext(b: *Browser) void {
        page_find.look(b, true);
    }
    fn findPrevious(b: *Browser) void {
        page_find.look(b, false);
    }
    /// ⇧⌘S. The same tabs, down the side or across the top.
    fn toggleSidebar(b: *Browser) void {
        b.prefs.set("sidebar", !b.prefs.sidebar);
        b.syncStageHost();
        b.redraw();
    }
    fn reload(b: *Browser) void {
        if (b.activeTab()) |t| t.reload(false);
    }
    fn reloadFromOrigin(b: *Browser) void {
        if (b.activeTab()) |t| t.reload(true);
    }
    fn stop(b: *Browser) void {
        if (b.activeTab()) |t| if (t.loading) t.stopLoading();
    }
    // Ubi Chat's (P9), once the Browser has them.
    fn summarize(b: *Browser) void {
        if (comptime @hasDecl(Browser, "summarizePage")) b.summarizePage();
    }
    fn chat(b: *Browser) void {
        if (comptime @hasDecl(Browser, "toggleChat")) b.toggleChat();
    }
    fn zoomIn(b: *Browser) void {
        if (b.activeTab()) |t| t.magnifyBy(1.1);
    }
    fn zoomOut(b: *Browser) void {
        if (b.activeTab()) |t| t.magnifyBy(1.0 / 1.1);
    }
    fn actualSize(b: *Browser) void {
        if (b.activeTab()) |t| t.resetZoom();
    }
    fn back(b: *Browser) void {
        if (b.activeTab()) |t| t.goBack();
    }
    fn forward(b: *Browser) void {
        if (b.activeTab()) |t| t.goForward();
    }
    fn next(b: *Browser) void {
        b.step(1);
    }
    fn previous(b: *Browser) void {
        b.step(-1);
    }
    /// Held down, ⌘K walks the list a step at a time; letting go of ⌘ takes where it stopped.
    fn search(b: *Browser) void {
        if (b.editing and b.omni.offers.len > 0) b.stepSummon() else b.summon();
    }
    fn split(b: *Browser) void {
        if (b.prefs.split_view) b.startSplit();
    }
    fn focusLeft(b: *Browser) void {
        if (b.prefs.split_view) b.focusPaneSide(true);
    }
    fn focusRight(b: *Browser) void {
        if (b.prefs.split_view) b.focusPaneSide(false);
    }
    fn focusOther(b: *Browser) void {
        if (b.prefs.split_view) b.focusOtherPane();
    }
    fn swap(b: *Browser) void {
        if (b.prefs.split_view) b.swapSplit();
    }
    fn separate(b: *Browser) void {
        if (!b.prefs.split_view) return;
        if (b.activeTab()) |t| b.detachSplit(t);
    }
    fn rename(b: *Browser) void {
        if (b.activeTab()) |t| b.beginTabRename(t);
    }
    fn closeOthers(b: *Browser) void {
        if (b.activeTab()) |t| b.closeOthers(t);
    }
    fn bookmarking(b: *Browser) void {
        sheet.toggle(b, .bookmarking);
    }
    fn bookmarksBar(b: *Browser) void {
        b.prefs.set("bookmarks_bar", !b.prefs.bookmarks_bar);
        side_panels.redrawAll(b.kea);
    }
    fn bookmarksSidebar(b: *Browser) void {
        side_panels.toggleBookmarks(b.kea);
    }
};

/// `Command.named`.
pub fn named(id: []const u8) ?*const Command {
    for (&all) |*cmd| if (std.mem.eql(u8, cmd.id, id)) return cmd;
    return null;
}

/// `Command.split`: Split View's, unlisted and their keys the page's while it is off.
pub const split = [_][]const u8{ "tabs.split", "tabs.focusLeftPane", "tabs.focusRightPane", "tabs.focusOtherPane", "tabs.swapSplit", "tabs.separateSplit" };
/// `Command.ai`: the AI add-on's, unlisted while it is off.
pub const ai = [_][]const u8{ "view.summarize", "view.ask" };

pub fn isIn(set: []const []const u8, id: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, id)) return true;
    return false;
}

test "command ids are unique and every default key is usable" {
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
        if (a.default_key) |key| try std.testing.expect(key.isUsable());
    }
    try std.testing.expectEqualStrings("New Tab", named("file.newTab").?.title);
}
