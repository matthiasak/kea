//! P5's web engine: KVO keeps the tab in step with its page, JS questions
//! are answered and the page goes on, links that ask for a window or come
//! with ⌘ open tabs, zoom is kept per site, one load is one visit, and a
//! tab put to sleep comes back when picked.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const app = @import("kea");
const Case = @import("main.zig").Case;
const Harness = @import("main.zig").Harness;

pub const cases = [_]Case{
    .{ .name = "title KVO follows document.title", .run = titleFollows },
    .{ .name = "pushState updates URL", .run = pushState },
    .{ .name = "progress reaches 1 and loading false", .run = progressDone },
    .{ .name = "alert is answered and JS resumes", .run = alertAnswered },
    .{ .name = "prompt returns typed text", .run = promptTyped },
    .{ .name = "target=_blank opens a foreground tab", .run = blankTarget },
    .{ .name = "cmd-click opens background tab", .run = cmdClick },
    .{ .name = "zoom per host persists", .run = zoomPersists },
    .{ .name = "one visit per load", .run = oneVisit },
    .{ .name = "sleeping tab wakes on select", .run = sleepWakes },
};

fn finished(t: *app.Tab) bool {
    const wv = t.web orelse return false;
    return !t.loading and !objc.msg(objc.BOOL, wv, "isLoading", .{}) and objc.msg(f64, wv, "estimatedProgress", .{}) >= 1;
}

pub fn open(h: *Harness, b: *app.Browser, url: []const u8) !*app.Tab {
    const t = b.open(url, .{ .foreground = true });
    h.waitFor(t, finished, 10, url) catch
        return h.fail("{s}: url '{s}', loading {}, failure '{s}'", .{ url, t.url(), t.loading, t.failure orelse "" });
    return t;
}

// MARK: JavaScript, answered

var said: [256]u8 = undefined;
var said_len: ?usize = null;

fn heard(_: *app.Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const text = if (value) |v| objc.fromNSString(objc.msg(?objc.Object, v, "description", .{})) else "null";
    const n = @min(text.len, said.len);
    @memcpy(said[0..n], text[0..n]);
    said_len = n;
}

fn answered(_: *const u8) bool {
    return said_len != null;
}

/// What `js` comes to in the page, as text.
pub fn eval(h: *Harness, t: *app.Tab, js: []const u8) ![]const u8 {
    said_len = null;
    t.evaluate(js, .page, heard, 0);
    const dummy: u8 = 0;
    try h.waitFor(&dummy, answered, 5, js);
    return said[0..said_len.?];
}

// MARK: KVO

fn changedTitle(t: *app.Tab) bool {
    return std.mem.eql(u8, t.title(), "Changed");
}

fn titleFollows(h: *Harness) !void {
    const b = try h.start();
    const t = try open(h, b, "kea-test://site/page?title=Before");
    _ = try eval(h, t, "document.title = 'Changed'");
    h.waitFor(t, changedTitle, 2, "the title") catch return h.fail("title is '{s}'", .{t.title()});
}

fn pushed(t: *app.Tab) bool {
    return std.mem.endsWith(u8, t.url(), "/pushed");
}

fn pushState(h: *Harness) !void {
    const b = try h.start();
    const t = try open(h, b, "kea-test://site/page?title=Push");
    _ = try eval(h, t, "history.pushState({}, '', '/pushed'); 'ok'");
    h.waitFor(t, pushed, 2, "the pushed address") catch return h.fail("url is '{s}'", .{t.url()});
}

fn helloTitled(t: *app.Tab) bool {
    return std.mem.eql(u8, t.page_title, "Hello Fixture");
}

fn progressDone(h: *Harness) !void {
    const b = try h.start();
    const t = try open(h, b, "kea-test://site/f/hello.html");
    try h.expect(!t.loading and !t.isBlank(), "loading {}", .{t.loading});
    // WebKit tells the title in its own turn, which may come after the load
    // ends (a loaded machine shows it).
    h.waitFor(t, helloTitled, 5, "the title") catch return h.fail("title '{s}'", .{t.title()});
}

// MARK: questions

fn asking(t: *app.Tab) bool {
    return t.question() != null;
}

fn alertAnswered(h: *Harness) !void {
    const b = try h.start();
    const t = try open(h, b, "kea-test://site/f/questions.html#alert");
    try h.waitFor(t, asking, 5, "the alert");
    const q = t.question().?;
    try h.expect(q.kind == .alert and std.mem.eql(u8, q.message, "Hello from the page") and std.mem.eql(u8, q.host, "site"), "asked '{s}' as '{s}'", .{ q.message, q.host });
    t.answerQuestion(true, null);
    try h.expect(t.question() == null, "still asking", .{});
    try evalUntil(h, t, "String(window.done)", "true");
}

/// Asks until `js` comes to `want`: the page goes on a moment after its answer.
pub fn evalUntil(h: *Harness, t: *app.Tab, js: []const u8, want: []const u8) !void {
    const deadline = nanoui.ui.clock.now() + 3;
    while (nanoui.ui.clock.now() < deadline) {
        if (std.mem.eql(u8, try eval(h, t, js), want)) return;
        h.pump(0.1);
    }
    return h.fail("{s} came to '{s}', not '{s}'", .{ js, said[0..said_len.?], want });
}

fn promptTyped(h: *Harness) !void {
    const b = try h.start();
    const t = try open(h, b, "kea-test://site/f/questions.html#prompt");
    try h.waitFor(t, asking, 5, "the prompt");
    const q = t.question().?;
    try h.expect(q.kind == .prompt and std.mem.eql(u8, q.input.text(), "kea"), "prompt default '{s}'", .{q.input.text()});
    t.answerQuestion(true, "typed text");
    try evalUntil(h, t, "String(window.answer)", "typed text");
}

// MARK: links

fn blankTarget(h: *Harness) !void {
    const b = try h.start();
    const from = try open(h, b, "kea-test://site/f/links.html");
    const Ctx = struct { b: *app.Browser, n: usize };
    const want: Ctx = .{ .b = b, .n = b.tabs.items.len + 1 };
    _ = try eval(h, from, "document.getElementById('blank').click(); 'ok'");
    try h.waitFor(want, struct {
        fn f(c: Ctx) bool {
            return c.b.tabs.items.len == c.n;
        }
    }.f, 5, "the new tab");
    const front = b.activeTab().?;
    try h.expect(front != from and front.opener == from.id, "the opened tab isn't in front", .{});
    h.waitFor(front, finished, 5, "the opened page") catch {};
    try h.expect(std.mem.indexOf(u8, front.url(), "title=Opened") != null, "front tab at '{s}'", .{front.url()});
}

/// A left click at `x`, `y` of the view (top left, points), sent to it as
/// AppKit would.
pub fn clickAt(view: objc.Object, x: f64, y: f64, flags: objc.NSUInteger) void {
    const window = objc.msg(?objc.Object, view, "window", .{}) orelse return;
    const at = objc.msg(objc.CGPoint, view, "convertPoint:toView:", .{ objc.CGPoint{ .x = x, .y = y }, @as(?objc.Object, null) });
    const number = objc.msg(objc.NSInteger, window, "windowNumber", .{});
    for ([_]objc.NSUInteger{ 1, 2 }) |kind| {
        const ev = objc.msg(objc.Object, objc.class("NSEvent"), "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            kind, at, flags, @as(f64, 0), number, @as(?objc.Object, null), @as(objc.NSInteger, 0), @as(objc.NSInteger, 1), @as(f32, 1),
        });
        objc.msg(void, view, if (kind == 1) "mouseDown:" else "mouseUp:", .{ev});
    }
}

fn cmdClick(h: *Harness) !void {
    const b = try h.start();
    const from = try open(h, b, "kea-test://site/f/links.html");
    const count = b.tabs.items.len;
    // ⌘ opens only web addresses beside the tab (Browser.swift:4293): the loopback site's.
    var buf: [400]u8 = undefined;
    const where = try eval(h, from, try std.fmt.bufPrint(&buf, "var a = document.getElementById('plain'); a.href = '{s}/behind'; var r = a.getBoundingClientRect(); (r.left + r.width / 2) + ',' + (r.top + r.height / 2)", .{h.http}));
    var parts = std.mem.splitScalar(u8, where, ',');
    const x = std.fmt.parseFloat(f64, parts.next() orelse "") catch return h.fail("no link at '{s}'", .{where});
    const y = std.fmt.parseFloat(f64, parts.next() orelse "") catch return h.fail("no link at '{s}'", .{where});
    // WebKit takes a link's modifiers from the real event only: a click as
    // AppKit hands it to the view, ⌘ held.
    clickAt(from.web.?, x, y, 1 << 20);
    const Ctx = struct { b: *app.Browser, n: usize };
    try h.waitFor(Ctx{ .b = b, .n = count + 1 }, struct {
        fn f(c: Ctx) bool {
            return c.b.tabs.items.len == c.n;
        }
    }.f, 5, "the background tab");
    try h.expect(b.activeTab().? == from, "the ⌘-clicked tab came to the front", .{});
    try h.expect(std.mem.endsWith(u8, from.url(), "links.html"), "the page itself went to '{s}'", .{from.url()});
    var found = false;
    for (b.tabs.items) |t| if (std.mem.endsWith(u8, t.url(), "/behind")) {
        found = true;
    };
    try h.expect(found, "no tab at the ⌘-clicked link", .{});
}

// MARK: zoom, visits, sleep

fn zoomPersists(h: *Harness) !void {
    const b = try h.start();
    const t = try open(h, b, "kea-test://site/page?title=Zoom");
    h.press("=", 24, true, false); // ⌘+
    h.press("=", 24, true, false);
    const kept = b.store.double("zoom.site") orelse return h.fail("zoom.site not written (zoom {d})", .{t.zoom});
    try h.expect(@abs(kept - 1.21) < 0.01, "zoom.site is {d}", .{kept});
    const again = try open(h, b, "kea-test://site/page?title=Again");
    try h.expect(@abs(again.zoom - 1.21) < 0.01, "the site's next page opened at {d}", .{again.zoom});
    // Back at the usual size, nothing is kept.
    h.press("0", 29, true, false);
    try h.expect(b.store.double("zoom.site") == null, "zoom.site kept at the default size", .{});
}

fn oneVisit(h: *Harness) !void {
    const b = try h.start();
    var buf: [128]u8 = undefined;
    const t = try open(h, b, try std.fmt.bufPrint(&buf, "{s}/once", .{h.http}));
    // A title that lands later renames the visit (the 2 s throttle) and is
    // never a second one.
    _ = try eval(h, t, "document.title = 'Later'; 'ok'");
    h.pump(2.5);
    var count: i64 = 0;
    for (b.history.visits.values()) |e| if (std.mem.endsWith(u8, e.visit.url, "/once")) {
        count = e.visit.count;
        try h.expect(std.mem.eql(u8, e.visit.title, "Later"), "visit titled '{s}'", .{e.visit.title});
    };
    try h.expect(count == 1, "one load counted {d} visits", .{count});
}

fn asleep(t: *app.Tab) bool {
    return t.asleep() and t.web == null;
}

fn awakeAgain(t: *app.Tab) bool {
    return !t.asleep() and t.web != null and finished(t) and std.mem.eql(u8, t.title(), "Sleepy");
}

fn sleepWakes(h: *Harness) !void {
    const b = try h.start();
    b.store.setDouble("sleep.after", 1);
    const sleepy = try open(h, b, "kea-test://site/page?title=Sleepy");
    _ = try open(h, b, "kea-test://site/page?title=Awake");
    try h.expect(b.awake(sleepy) == null, "kept awake: {s}", .{b.awake(sleepy) orelse ""});
    h.pump(1.2);
    b.sleepIdle(null);
    h.waitFor(sleepy, asleep, 5, "the tab to sleep") catch return h.fail("still awake: {s}", .{b.awake(sleepy) orelse "?"});
    try h.expect(std.mem.endsWith(u8, sleepy.pending.?, "title=Sleepy"), "asleep at '{s}'", .{sleepy.pending.?});
    b.select(sleepy);
    h.waitFor(sleepy, awakeAgain, 10, "the tab to wake") catch
        return h.fail("woke to '{s}' '{s}', loading {}", .{ sleepy.url(), sleepy.title(), sleepy.loading });
}
