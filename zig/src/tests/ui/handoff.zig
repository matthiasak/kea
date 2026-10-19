//! P5.7: the page in front offered to other devices (Sharing.swift `handOff`).
const std = @import("std");
const objc = @import("nanoui").objc;
const app = @import("kea");
const Fixture = @import("fixture.zig").Fixture;
const t = std.testing;

fn activityUrl(a: objc.Object) []const u8 {
    return objc.fromNSString(objc.msg(?objc.Object, objc.msg(?objc.Object, a, "webpageURL", .{}) orelse return "", "absoluteString", .{}));
}

test "handoff activity carries the active tab URL" {
    var f: Fixture = undefined;
    try f.init(t.allocator, .{});
    defer f.deinit();
    const b = f.browser;
    const pool = objc.Pool.push();
    defer pool.pop();

    const tab = b.open("https://example.com/kea?x=1", .{ .foreground = true });
    tab.setTitle("Example");
    const a = app.handoff.activity(b) orelse return error.NoActivity;
    try t.expectEqualStrings("https://example.com/kea?x=1", activityUrl(a));
    try t.expectEqualStrings("Example", objc.fromNSString(objc.msg(?objc.Object, a, "title", .{})));
    try t.expectEqualStrings("NSUserActivityTypeBrowsingWeb", objc.fromNSString(objc.msg(?objc.Object, a, "activityType", .{})));

    // Another tab in front: the same activity follows it.
    _ = b.open("https://example.org/", .{ .foreground = true });
    try t.expect(app.handoff.activity(b).? == a);
    try t.expectEqualStrings("https://example.org/", activityUrl(a));

    // Never a private tab, nor a page that isn't the web's.
    b.newShyTab();
    try t.expect(app.handoff.activity(b) == null);
    try t.expect(b.handoff_activity == null);
    _ = b.open("about:blank", .{ .foreground = true });
    try t.expect(app.handoff.activity(b) == null);

    // Off in Settings: nothing is offered.
    b.select(tab);
    try t.expect(app.handoff.activity(b) != null);
    b.prefs.set("handoff", false);
    try t.expect(app.handoff.activity(b) == null);
}
