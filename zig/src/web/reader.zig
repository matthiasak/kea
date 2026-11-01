//! Reading mode (Reader.swift, `Tab.toggleReader`, `Browser.toggleReader`):
//! the piece of the page carrying the most prose, and nothing arranged
//! around it. Leaving it reloads: putting the old markup back would give a
//! page that looks right and does nothing.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Tab = @import("tab.zig").Tab;
const Browser = @import("../model/browser.zig").Browser;

const prefs_mod = @import("../data/prefs.zig");
const markdown_html = @import("../ai/markdown_html.zig");
const scripts = @import("tab_scripts.zig");
/// `Reader.script`, run in the page's own world; answers "read" or "none".
const script = @embedFile("js/reader.js");

/// ⇧⌘R.
pub fn toggleReader(b: *Browser) void {
    const t = b.activeTab() orelse return;
    toggle(t);
}

/// `Tab.toggleReader`: says "Nothing to read on this page" when it can't.
pub fn toggle(t: *Tab) void {
    if (t.isBlank()) return nothing(t);
    if (t.reader) {
        t.reader = false;
        t.reload(false);
        return;
    }
    t.evaluate(script, .page, answered, 0);
}

fn answered(t: *Tab, value: ?objc.Object, _: ?objc.Object, _: usize) void {
    const ans = if (value) |v|
        if (objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) objc.fromNSString(v) else ""
    else
        "";
    if (std.mem.startsWith(u8, ans, "md:")) {
        return renderMarkdown(t, ans[3..]);
    }
    if (std.mem.startsWith(u8, ans, "mdurl:")) {
        var js: std.ArrayList(u8) = .empty;
        defer js.deinit(t.gpa);
        js.appendSlice(t.gpa, "fetch(`") catch return nothing(t);
        scripts.escapeInto(&js, t.gpa, ans[6..]) catch return nothing(t);
        js.appendSlice(t.gpa, "`).then(r=>r.ok?r.text():'').then(m=>window.webkit.messageHandlers.keaReader.postMessage(m?'md:'+m:'mderr'),()=>window.webkit.messageHandlers.keaReader.postMessage('mderr'))") catch return nothing(t);
        t.evaluate(js.items, .page, null, 0);
        return;
    }
    if (!std.mem.eql(u8, ans, "read")) return nothing(t);
    t.reader = true;
    apply(t);
    t.changed(.state);
}

pub fn handleMessage(t: *Tab, msg: []const u8) void {
    if (std.mem.startsWith(u8, msg, "md:")) {
        renderMarkdown(t, msg[3..]);
        return;
    }
    // The Markdown twin didn't come: read the HTML page instead.
    if (std.mem.eql(u8, msg, "mderr")) {
        t.evaluate("window.__keaSkipMdLink=true;", .page, null, 0);
        t.evaluate(script, .page, answered, 0);
        return;
    }
    if (std.meta.stringToEnum(prefs_mod.ReaderTheme, msg)) |th| {
        t.kea.prefs.set("reader_theme", th);
        restyleAll(t.kea);
    }
}

fn renderMarkdown(t: *Tab, md_text: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const body_html = markdown_html.html(a, md_text) catch return nothing(t);
    var js: std.ArrayList(u8) = .empty;
    js.appendSlice(a, "(function(){window.__keaMarkdownArticle=true;document.body.innerHTML='<article>' + `") catch return;
    scripts.escapeInto(&js, a, body_html) catch return;
    js.appendSlice(a, "` + '</article>';})()") catch return;
    t.evaluate(js.items, .page, null, 0);
    t.evaluate(script, .page, mdApplied, 0);
}

fn mdApplied(t: *Tab, _: ?objc.Object, _: ?objc.Object, _: usize) void {
    t.evaluate("var f=document.querySelector('#kea-reader .kea-from');if(f)f.textContent+=' · markdown';", .page, null, 0);
    t.reader = true;
    apply(t);
    t.changed(.state);
}

fn apply(t: *Tab) void {
    const p = &t.kea.prefs;
    const em: u32 = switch (p.reader_width) {
        .narrow => 32,
        .medium => 38,
        .wide => 46,
    };
    const size: u32 = @intFromFloat(@round(std.math.clamp(p.reader_size, 14, 26)));
    var buf: [512]u8 = undefined;
    const js = std.fmt.bufPrint(
        &buf,
        "document.documentElement.dataset.krTheme='{s}';document.documentElement.style.setProperty('--kr-size','{d}px');document.documentElement.style.setProperty('--kr-width','{d}em');var tb=document.getElementById('kea-reader-theme');if(tb)tb.querySelectorAll('button').forEach(b=>b.dataset.active=b.dataset.theme==='{s}'?'true':'false');",
        .{ @tagName(p.reader_theme), size, em, @tagName(p.reader_theme) },
    ) catch return;
    t.evaluate(js, .page, null, 0);
}

pub fn restyleAll(kea: *@import("../app/kea.zig").Kea) void {
    for (kea.browsers.items) |w| {
        const parked = w.parkedTabs(w.gpa) catch continue;
        defer w.gpa.free(parked);
        for ([_][]const *Tab{ w.tabs.items, parked }) |list| for (list) |t| {
            if (t.reader and t.web != null) apply(t);
        };
    }
}

fn nothing(t: *Tab) void {
    if (t.browser) |b| b.announce("Nothing to read on this page");
}
