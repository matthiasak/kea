//! Ubi Chat in a window (AIAssist.swift:517-528, SidePanels.swift:241-262):
//! the column opened and put away, and its window of its own when popped.
const std = @import("std");
const Browser = @import("browser.zig").Browser;
const Assistant = @import("../ai/assistant.zig").Assistant;
const ubi = @import("../ai/ubi_chat.zig");
const popped = @import("../chrome/popped.zig");

/// View › Ubi Chat: the column, opened or put away.
pub fn toggleChat(b: *Browser) void {
    if (b.assisting != null) closeAssistant(b) else _ = openChat(b);
}

pub fn openChat(b: *Browser) ?*Assistant {
    if (b.assisting) |a| return a;
    const shy = if (b.activeTab()) |t| ubi.isPrivatePage(t) else false;
    b.assisting = Assistant.create(b.kea.ai, b, shy) catch return null;
    b.redraw();
    return b.assisting;
}

pub fn summarizePage(b: *Browser) void {
    if (openChat(b)) |a| a.summarize();
}

pub fn closeAssistant(b: *Browser) void {
    const a = b.assisting orelse return;
    b.assisting = null;
    a.destroy();
    if (b.expanded_panel == .chat) b.expanded_panel = null;
    b.chat.reset(b.gpa);
    b.redraw();
}

/// `readyAI`'s Settings › AI (`settingsPage = .ai; tuning = true`).
pub fn openAISettings(b: *Browser) void {
    @import("../chrome/settings/frame.zig").open(b, .ai);
}

/// `placeChatWindow(open && popped)`: Ubi Chat's own window follows the
/// chat being open and popped out. At the top of the browser's frame only,
/// as `popped.followBookmarks`.
pub fn followChatWindow(b: *Browser) void {
    const want = b.assisting != null and b.prefs.chat_popped;
    if (want == (b.chat.window != null)) return;
    if (want) {
        b.chat.window = popped.open(b.kea, .chat, b);
    } else {
        const w = b.chat.window.?;
        b.chat.window = null;
        w.close();
    }
}

/// The window going: the chat and its own window with it.
pub fn deinit(b: *Browser) void {
    if (b.chat.window) |w| {
        b.chat.window = null;
        w.close();
    }
    if (b.assisting) |a| a.destroy();
    b.assisting = null;
    b.chat.deinit(b.gpa);
}
