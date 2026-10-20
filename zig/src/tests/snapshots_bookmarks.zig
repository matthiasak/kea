//! P8.7 snapshot states: the bookmarks manager and the bookmarks bar.
const Fixture = @import("ui/fixture.zig").Fixture;
const app = @import("kea");
const Bookmark = app.bookmarks_data.Bookmark;

/// A few sites and a folder of two, the folder open.
fn keep(f: *Fixture) void {
    const b = f.browser;
    _ = b.bookmarks.add("https://ziglang.org/", "Zig");
    _ = b.bookmarks.add("https://news.ycombinator.com/", "Hacker News");
    var kids = [_]Bookmark{
        .{ .id = .random(), .title = "Apple Developer", .url = "https://developer.apple.com/" },
        .{ .id = .random(), .title = "", .url = "https://example.com/docs" },
    };
    b.bookmarks.insert(Bookmark.folder("Reading", &kids), null, null);
    _ = b.bookmarks.add("https://github.com/", "GitHub");
}

/// The manager up, the folder open, a site picked.
pub fn manager(f: *Fixture) void {
    keep(f);
    const b = f.browser;
    app.sheet.show(b, .bookmarking);
    f.tester.frame();
    b.marks_ui.picks.expanded.put(b.gpa, b.bookmarks.roots[2].id);
    b.marks_ui.picks.ids.put(b.gpa, b.bookmarks.roots[0].id);
}

/// The bookmarks bar under the strip.
pub fn bar(f: *Fixture) void {
    keep(f);
    f.browser.prefs.set("bookmarks_bar", true);
}

/// P9: the manager showing Organize with AI's proposal.
pub fn organize(f: *Fixture) void {
    keep(f);
    const b = f.browser;
    @import("ui/organize.zig").ready(b);
    app.sheet.show(b, .bookmarking);
    f.tester.frame();
    app.bookmarks_proposal.send(b, "");
}
