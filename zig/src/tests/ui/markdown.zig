//! P9: an answer's Markdown (`AnswerView`) on its own, over the fixture's browser.
const std = @import("std");
const t = std.testing;
const ui = @import("nanoui").ui;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;

/// `markdown_view.answer` filling a window, as Ubi Chat's panel draws a turn.
pub const Answer = struct {
    b: *app.Browser,
    text: []const u8,
    o: app.markdown_view.Options = .{},
    st: app.markdown_view.State = .{},

    pub fn build(s: *Answer, c: *ui.Context) void {
        const p = app.palette.get(c.theme.dark);
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(18), .background = p.ground });
        app.markdown_view.answer(s.b, c, p, &s.st, s.text, s.o);
        ui.end(c);
    }

    /// The fixture's window shows this answer from now on.
    pub fn show(s: *Answer, f: *Fixture) void {
        f.tester.view = ui.View.init(s, build);
        f.tester.frame();
    }
};

test "markdown view renders a table and a link that opens a tab on click" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{ .width = 520, .height = 420 });
    defer f.deinit();
    var answer: Answer = .{ .b = f.browser, .text = 
        \\| Bird | Home |
        \\|---|---|
        \\| Kea | Alps |
        \\| Tui | Bush |
        \\
        \\See [Kea](https://example.com/kea) now.
    };
    defer answer.st.deinit(t.allocator);
    answer.show(&f);
    f.tester.settle(1);

    // Each column's cells start at one x, the second clear of the first.
    const bird = f.tester.findText("Bird") orelse return error.NoHeader;
    const home = f.tester.findText("Home") orelse return error.NoHeader;
    for ([_][]const u8{ "Kea", "Tui" }) |s| try t.expectEqual(bird.x, (f.tester.findText(s) orelse return error.NoCell).x);
    for ([_][]const u8{ "Alps", "Bush" }) |s| try t.expectEqual(home.x, (f.tester.findText(s) orelse return error.NoCell).x);
    try t.expect(home.x >= bird.x + bird.w + 14);
    try t.expect(f.tester.findText("Tui").?.y > f.tester.findText("Kea").?.y);

    // The link shows its label; a click beside it opens nothing, on it a tab in front.
    const line = f.tester.findText("See Kea now.") orelse return error.NoLink;
    const tabs = f.browser.tabs.items.len;
    const before = f.tester.text.width("See ", .{ .size = 13 });
    const label = f.tester.text.width("Kea", .{ .size = 13 });
    f.tester.click(line.x + before / 2, line.y + line.h / 2);
    try t.expectEqual(tabs, f.browser.tabs.items.len);
    f.tester.click(line.x + before + label / 2, line.y + line.h / 2);
    try t.expectEqual(tabs + 1, f.browser.tabs.items.len);
    try t.expectEqualStrings("https://example.com/kea", f.browser.activeTab().?.url());
}
