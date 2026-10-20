//! chrome.downloads (ExtensionShims.swift 3539-3588, `downloadPage` 4202-4208).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ans = @import("answer.zig");
const Browser = @import("../../model/browser.zig").Browser;
const asking = @import("../controller_asking.zig");
const asked = @import("../downloads.zig");
const keeping = @import("../../web/downloads_keep.zig");
const files = @import("../../web/downloads.zig");

const Value = ans.Value;

pub fn run(c: *ans.Call) ans.Error!?ans.Out {
    const api = c.api;
    if (!std.mem.startsWith(u8, api, "downloads.")) return null;
    const b = c.browser;
    const kept = b.kea.loot.kept;
    if (eql(api, "downloads.download")) {
        const spec = c.first();
        const url = ans.str(ans.field(spec, "url")) orelse return c.fail("No url to download", .{});
        const pool = objc.Pool.push();
        defer pool.pop();
        const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse
            return c.fail("No url to download", .{});
        const web = downloadPage(b) orelse return c.fail("No page to download through", .{});
        asked.ask(b, url, c.id, ans.str(ans.field(spec, "filename"))) catch return error.OutOfMemory;
        const s = try c.a.create(Started);
        s.* = .{ .b = b, .web = web, .p = c.pending };
        const request = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{nsurl});
        var done = objc.Block(Started, &.{objc.Object}).init(s, Started.began);
        objc.msg(void, web, "startDownloadUsingRequest:completionHandler:", .{ request, &done });
        return .later;
    }
    if (eql(api, "downloads.search")) {
        const pool = objc.Pool.push();
        defer pool.pop();
        const iso = objc.msg(objc.Object, objc.class("NSISO8601DateFormatter"), "new", .{});
        defer objc.release(iso);
        var out: std.json.Array = .init(c.a);
        for (kept, 0..) |k, i| {
            const date = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceReferenceDate:", .{k.date});
            const start = try c.a.dupe(u8, objc.fromNSString(objc.msg(objc.Object, iso, "stringFromDate:", .{date})));
            // Loot.swift:16 `url`: the file's own URL.
            const fileurl = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(k.path)});
            const file = try c.a.dupe(u8, objc.fromNSString(objc.msg(objc.Object, fileurl, "absoluteString", .{})));
            try out.append(try c.of(.{
                .id = i + 1, .url = file, .finalUrl = file, .filename = k.path, .state = "complete",
                .exists = files.exists(k.path), .startTime = start, .mime = "",
            }));
        }
        return .{ .value = .{ .array = out } };
    }
    if (eql(api, "downloads.open") or eql(api, "downloads.show")) {
        const index = ans.int(c.first()) orelse return ans.none;
        if (index < 1 or index > kept.len) return ans.none;
        const keep = kept[@intCast(index - 1)];
        if (eql(api, "downloads.open")) {
            if (!c.allowed("downloads.open")) return c.fail("The extension never asked for \u{201C}downloads.open\u{201D}", .{});
            if (!asking.justUsed(c.owner, c.id)) return c.fail("downloads.open() may only be called in response to a user gesture.", .{});
            if (!asked.owns(c.id, keep.path)) return c.fail("Only a download this extension started can be opened by it", .{});
            open(keep.path);
        } else keeping.reveal(keep.path);
        return ans.none;
    }
    if (eql(api, "downloads.showDefaultFolder")) {
        open(b.kea.prefs.downloads);
        return ans.none;
    }
    if (eql(api, "downloads.erase")) return .{ .value = .{ .array = .init(c.a) } };
    inline for (.{ "downloads.pause", "downloads.resume", "downloads.cancel", "downloads.removeFile", "downloads.getFileIcon" }) |n|
        if (eql(api, n)) return c.fail("{s} isn't available in " ++ ans.app_name ++ " yet", .{api});
    return null;
}

/// `downloadPage`: the tab in front, then the rest; never a private one.
fn downloadPage(b: *Browser) ?objc.Object {
    if (b.activeTab()) |t| if (!t.shy) if (t.web) |w| return w;
    for (b.tabs.items) |t| if (!t.shy) if (t.web) |w| return w;
    return null;
}

const Started = struct {
    b: *Browser,
    web: objc.Object,
    p: *ans.Pending,

    fn began(s: *Started, download: objc.Object) void {
        keeping.keep(s.b, download, s.web);
        s.p.value(.{ .integer = @intCast(s.b.kea.loot.kept.len + 1) });
    }
};

/// `Loot.open`: the file (or folder), in the app that opens it.
fn open(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    _ = objc.msg(objc.BOOL, objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}), "openURL:", .{url});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
