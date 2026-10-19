//! P8.4-P8.6, P8.10 snapshot states: History, Downloads, the find bar and
//! the bars.
const app = @import("kea");
const Fixture = @import("ui/fixture.zig").Fixture;

/// History over a few days.
pub fn history(f: *Fixture) void {
    const now = app.json.now();
    const today = app.when.startOfDay(now);
    f.kea.history.take("https://github.com/", "GitHub", 4, now);
    f.kea.history.take("https://kea.example/flight", "How keas fly", 1, @max(today + 1, now - 600));
    f.kea.history.take("https://en.wikipedia.org/wiki/Kea", "Kea — Wikipedia", 2, today - 3600);
    f.kea.history.take("https://news.example/", "", 1, today - 3 * 86400);
    app.sheet.show(f.browser, .recalling);
}

/// Downloads: one coming in, one kept.
pub fn downloads(f: *Fixture) void {
    f.kea.loot.add(.{ .name = "kea-field-guide.pdf", .from = "kea.example", .path = "/nonexistent/kea-field-guide.pdf", .date = app.json.now() - 7200 });
    const e = app.downloads.Entry.create(f.kea.gpa, "snow-photos.zip", null, null);
    e.fraction = 0.42;
    e.completed_bytes = 42 * 1024 * 1024;
    e.total_bytes = 100 * 1024 * 1024;
    f.kea.fetches.entries.append(f.kea.gpa, e) catch e.destroy();
    app.sheet.show(f.browser, .hoarding);
}

/// The find bar, "3 of 17".
pub fn find(f: *Fixture) void {
    const b = f.browser;
    b.select(b.tabs.items[b.tabs.items.len - 1]);
    app.page_find.openFind(b);
    b.find_bar.field.set("kea");
    b.finder.needle = b.gpa.dupe(u8, "kea") catch return;
    b.finder.result = .{ .count = 17, .index = 3, .found = true };
}

/// The bars: a saved file, a page asking for the camera, the veiling hint.
pub fn bars(f: *Fixture) void {
    const b = f.browser;
    b.select(b.tabs.items[b.tabs.items.len - 1]);
    b.announceFile("Saved kea.png", "/tmp/kea.png");
    const tab = b.activeTab() orelse return;
    const a = app.dialogs.make(tab, .capture, "kea.example", "camera", null) orelse return;
    app.dialogs.bar(tab, a);
    b.veiling = true;
}
