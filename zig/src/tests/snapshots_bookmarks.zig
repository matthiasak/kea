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

/// P17: flat categorized bookmarks in 1D neighbor order with bar and sidebar.
pub fn categories(f: *Fixture) void {
    const b = f.browser;
    const items = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "https://arxiv.org/", "arXiv", "AI & ML" },
        .{ "https://huggingface.co/", "Hugging Face", "AI & ML" },
        .{ "https://semianalysis.com/", "SemiAnalysis", "EE & Chips" },
        .{ "https://digikey.com/", "DigiKey", "EE & Chips" },
        .{ "https://examine.com/", "Examine", "Health" },
        .{ "https://pubmed.ncbi.nlm.nih.gov/", "PubMed Peptides", "Peptides" },
        .{ "https://zillow.com/", "Zillow", "Housing" },
    };
    for (items) |it| {
        const id = b.bookmarks.add(it[0], it[1]).?;
        app.bookmarks_category.setCategory(b.bookmarks, id, it[2]);
    }
    b.prefs.set("bookmarks_bar", true);
    b.prefs.set("bookmarks_sidebar", true);
}

fn organizeCategoriesStream(_: ?*anyopaque, _: *app.ai_core.Ai, _: app.ai_client.Ask, sink: app.ai_client.Sink) ?app.ai_client.Handle {
    sink.piece(sink.ctx, "{\"groups\":[{\"category\":\"AI & ML\",\"items\":[1,2]},{\"category\":\"EE & Chips\",\"items\":[3,4]},{\"category\":\"Health & Supplements\",\"items\":[5]}],\"remove\":[]}");
    sink.done(sink.ctx, null);
    return null;
}

/// P17: Organize with AI proposal showing flat category preview headers.
pub fn organizeCategories(f: *Fixture) void {
    const b = f.browser;
    _ = b.bookmarks.add("https://arxiv.org/", "arXiv");
    _ = b.bookmarks.add("https://huggingface.co/", "Hugging Face");
    _ = b.bookmarks.add("https://semianalysis.com/", "SemiAnalysis");
    _ = b.bookmarks.add("https://digikey.com/", "DigiKey");
    _ = b.bookmarks.add("https://examine.com/", "Examine");
    @import("ui/organize.zig").ready(b);
    b.kea.ai.client = .{ .ctx = null, .stream = organizeCategoriesStream };
    app.sheet.show(b, .bookmarking);
    f.tester.frame();
    app.bookmarks_proposal.send(b, "");
}
