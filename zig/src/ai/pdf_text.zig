//! A PDF's words for the model: PDFKit reads the document a tab shows (its
//! main resource, or the file itself) into "[Page N]" text, its web links,
//! and up to 8 sections — the outline's, else headings found in the text,
//! else runs of pages.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const url = @import("../data/url.zig");
const Tab = @import("../web/tab.zig").Tab;
const page_text = @import("page_text.zig");
const sse = @import("client_sse.zig");

pub const Section = struct { heading: []const u8, page: usize, excerpt: []const u8 };
pub const ParsedPdf = struct { title: []const u8, text: []const u8, links: []const []const u8, sections: []const Section, pages: usize };

const max_pages = 200;
const max_links = 400;
const max_sections = 8;
const excerpt_len = 1600;

pub fn isPdfUrl(u: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(u, "data:application/pdf")) return true;
    const p = url.Parts.parse(u) orelse return false;
    return std.ascii.endsWithIgnoreCase(p.path, ".pdf");
}

pub fn isPdfWebView(wv: objc.Object) bool {
    if (objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_isDisplayingPDF")}) and objc.msg(objc.BOOL, wv, "_isDisplayingPDF", .{})) return true;
    if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_MIMEType")})) return false;
    const mime = objc.fromNSString(objc.msg(?objc.Object, wv, "_MIMEType", .{}));
    return std.ascii.eqlIgnoreCase(mime, "application/pdf") or std.ascii.eqlIgnoreCase(mime, "text/pdf");
}

pub fn isPdfTab(t: *const Tab) bool {
    return (if (t.web) |wv| isPdfWebView(wv) else false) or isPdfUrl(t.url());
}

pub fn parseData(a: std.mem.Allocator, nsdata: objc.Object, fallback_title: []const u8) ?ParsedPdf {
    const doc = objc.msg(?objc.Object, objc.alloc("PDFDocument"), "initWithData:", .{nsdata}) orelse return null;
    defer objc.release(doc);
    return parseDoc(a, doc, fallback_title) catch null;
}

pub fn parseBytes(a: std.mem.Allocator, bytes: []const u8, fallback_title: []const u8) ?ParsedPdf {
    const pool = objc.Pool.push();
    defer pool.pop();
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ bytes.ptr, @as(objc.NSUInteger, bytes.len) });
    return parseData(a, data, fallback_title);
}

pub fn parseFileUrl(a: std.mem.Allocator, file_url_str: []const u8, fallback_title: []const u8) ?ParsedPdf {
    const pool = objc.Pool.push();
    defer pool.pop();
    const s = objc.nsString(file_url_str);
    const u = (if (std.ascii.startsWithIgnoreCase(file_url_str, "file://"))
        objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{s})
    else
        objc.msg(?objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{s})) orelse return null;
    const doc = objc.msg(?objc.Object, objc.alloc("PDFDocument"), "initWithURL:", .{u}) orelse return null;
    defer objc.release(doc);
    return parseDoc(a, doc, fallback_title) catch null;
}

/// Where a page's words sit in the text.
const Span = struct { page: usize, start: usize, end: usize };

fn parseDoc(a: std.mem.Allocator, doc: objc.Object, fallback_title: []const u8) !?ParsedPdf {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (objc.msg(objc.BOOL, doc, "isLocked", .{})) return null;
    const count = objc.msg(objc.NSUInteger, doc, "pageCount", .{});
    if (count == 0) return null;

    var title: []const u8 = "";
    if (objc.msg(?objc.Object, doc, "documentAttributes", .{})) |attrs| {
        const v = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("Title")});
        if (v) |s| if (objc.msg(objc.BOOL, s, "isKindOfClass:", .{objc.class("NSString")})) {
            title = std.mem.trim(u8, sse.prefix(objc.fromNSString(s), 300), " \t\r\n");
        };
    }
    title = try a.dupe(u8, if (title.len > 0) title else fallback_title);

    var text: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var links: std.ArrayList([]const u8) = .empty;
    for (0..@min(count, max_pages)) |i| {
        const pg = objc.msg(?objc.Object, doc, "pageAtIndex:", .{@as(objc.NSUInteger, i)}) orelse continue;
        const words = std.mem.trim(u8, objc.fromNSString(objc.msg(?objc.Object, pg, "string", .{})), " \t\r\n");
        if (words.len > 0) {
            try text.print(a, "[Page {d}]\n", .{i + 1});
            try spans.append(a, .{ .page = i + 1, .start = text.items.len, .end = text.items.len + words.len });
            try text.appendSlice(a, words);
            try text.appendSlice(a, "\n\n");
        }
        const anns = objc.msg(?objc.Object, pg, "annotations", .{}) orelse continue;
        for (0..objc.msg(objc.NSUInteger, anns, "count", .{})) |k| {
            if (links.items.len >= max_links) break;
            const link = annotationUrl(objc.msg(objc.Object, anns, "objectAtIndex:", .{k})) orelse continue;
            if (std.ascii.startsWithIgnoreCase(link, "http://") or std.ascii.startsWithIgnoreCase(link, "https://"))
                try links.append(a, try a.dupe(u8, link));
        }
    }
    if (spans.items.len == 0) return null;
    const all = text.items;
    var sections: std.ArrayList(Section) = .empty;
    try outlineSections(a, doc, all, spans.items, &sections);
    if (sections.items.len < 2) {
        sections.clearRetainingCapacity();
        try headingSections(a, all, spans.items, &sections);
    }
    if (sections.items.len < 2) {
        sections.clearRetainingCapacity();
        try pageSections(a, all, spans.items, &sections);
    }
    return .{ .title = title, .text = all, .links = links.items, .sections = sections.items, .pages = count };
}

/// A link annotation's address: its `URL`, else its URL action's.
fn annotationUrl(ann: objc.Object) ?[]const u8 {
    if (objc.msg(objc.BOOL, ann, "respondsToSelector:", .{objc.sel("URL")}))
        if (objc.msg(?objc.Object, ann, "URL", .{})) |u| return objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
    if (!objc.msg(objc.BOOL, ann, "respondsToSelector:", .{objc.sel("action")})) return null;
    const act = objc.msg(?objc.Object, ann, "action", .{}) orelse return null;
    if (!objc.msg(objc.BOOL, act, "respondsToSelector:", .{objc.sel("URL")})) return null;
    const u = objc.msg(?objc.Object, act, "URL", .{}) orelse return null;
    return objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
}

/// Section `i` of `starts` runs to the next start (or the text's end).
fn excerptAt(all: []const u8, starts: []const usize, i: usize) []const u8 {
    const end = if (i + 1 < starts.len and starts[i + 1] > starts[i]) starts[i + 1] else all.len;
    return std.mem.trim(u8, sse.prefix(all[starts[i]..end], excerpt_len), " \t\r\n");
}

fn finish(a: std.mem.Allocator, all: []const u8, heads: []const Section, starts: []const usize, out: *std.ArrayList(Section)) !void {
    for (heads, 0..) |h, i| try out.append(a, .{ .heading = h.heading, .page = h.page, .excerpt = excerptAt(all, starts, i) });
}

fn outlineSections(a: std.mem.Allocator, doc: objc.Object, all: []const u8, spans: []const Span, out: *std.ArrayList(Section)) !void {
    var root = objc.msg(?objc.Object, doc, "outlineRoot", .{}) orelse return;
    if (objc.msg(objc.NSUInteger, root, "numberOfChildren", .{}) == 1) {
        const only = objc.msg(objc.Object, root, "childAtIndex:", .{@as(objc.NSUInteger, 0)});
        if (objc.msg(objc.NSUInteger, only, "numberOfChildren", .{}) > 0) root = only;
    }
    var heads: std.ArrayList(Section) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    const n = objc.msg(objc.NSUInteger, root, "numberOfChildren", .{});
    for (0..n) |i| {
        if (heads.items.len >= max_sections) break;
        const item = objc.msg(objc.Object, root, "childAtIndex:", .{@as(objc.NSUInteger, i)});
        const label = std.mem.trim(u8, objc.fromNSString(objc.msg(?objc.Object, item, "label", .{})), " \t\r\n");
        const dest = objc.msg(?objc.Object, item, "destination", .{}) orelse continue;
        const pg = objc.msg(?objc.Object, dest, "page", .{}) orelse continue;
        const page = objc.msg(objc.NSUInteger, doc, "indexForPage:", .{pg}) + 1;
        const span = for (spans) |s| {
            if (s.page >= page) break s;
        } else continue;
        var from = span.start;
        if (span.page == page and label.len > 0)
            if (std.mem.indexOf(u8, all[span.start..span.end], label)) |at| {
                from += at;
            };
        try heads.append(a, .{ .heading = try a.dupe(u8, sse.prefix(label, 120)), .page = page, .excerpt = "" });
        try starts.append(a, from);
    }
    try finish(a, all, heads.items, starts.items, out);
}

const named = [_][]const u8{ "Abstract", "Introduction", "Background", "Related Work", "Method", "Methods", "Architecture", "Implementation", "Experiments", "Results", "Evaluation", "Discussion", "Conclusion", "Conclusions", "Appendix", "References" };

/// A line that reads like a paper's heading: a named one ("Abstract",
/// "Abstract: …"), or numbered ("1 Introduction", "2.1 Setup", "II. Methods").
pub fn isHeading(line: []const u8) bool {
    if (line.len < 3 or line.len > 80) return false;
    for (named) |w| if (std.ascii.startsWithIgnoreCase(line, w) and
        (line.len == w.len or line[w.len] == ':' or line[w.len] == '.')) return true;
    var i: usize = 0;
    while (i < line.len and (std.ascii.isDigit(line[i]) or (i > 0 and line[i] == '.'))) i += 1;
    if (i == 0) {
        while (i < line.len and std.mem.indexOfScalar(u8, "IVX", line[i]) != null) i += 1;
    }
    if (i == 0 or i > 6) return false;
    if (i < line.len and line[i] == '.') i += 1;
    if (i + 1 >= line.len or line[i] != ' ') return false;
    return std.ascii.isUpper(line[i + 1]);
}

fn headingSections(a: std.mem.Allocator, all: []const u8, spans: []const Span, out: *std.ArrayList(Section)) !void {
    var heads: std.ArrayList(Section) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    for (spans) |s| {
        var off = s.start;
        var it = std.mem.splitScalar(u8, all[s.start..s.end], '\n');
        while (it.next()) |raw| : (off += raw.len + 1) {
            if (heads.items.len >= max_sections) break;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!isHeading(line)) continue;
            try heads.append(a, .{ .heading = line, .page = s.page, .excerpt = "" });
            try starts.append(a, off);
        }
    }
    try finish(a, all, heads.items, starts.items, out);
}

fn pageSections(a: std.mem.Allocator, all: []const u8, spans: []const Span, out: *std.ArrayList(Section)) !void {
    const per = (spans.len + 5) / 6;
    var heads: std.ArrayList(Section) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < spans.len) : (i += per) {
        const last = spans[@min(i + per, spans.len) - 1].page;
        const first = spans[i].page;
        const heading = if (first == last) try std.fmt.allocPrint(a, "Page {d}", .{first}) else try std.fmt.allocPrint(a, "Pages {d}–{d}", .{ first, last });
        try heads.append(a, .{ .heading = heading, .page = first, .excerpt = "" });
        try starts.append(a, spans[i].start);
    }
    try finish(a, all, heads.items, starts.items, out);
}

// MARK: - reading a tab's PDF

pub const ParsedThen = *const fn (ctx: *anyopaque, parsed: ?ParsedPdf) void;

const Job = struct {
    wv: objc.Object,
    a: std.mem.Allocator,
    address: ?[]const u8,
    title: []const u8,
    ctx: *anyopaque,
    then: union(enum) { parsed: ParsedThen, read: page_text.Then },
};
const DataBlock = objc.Block(Job, &.{ ?objc.Object, ?objc.Object });

/// Main-resource bytes of a PDF WKWebView (file:// fallback), parsed onto `a`; `then` always called once on the main thread.
pub fn readParsed(wv: objc.Object, a: std.mem.Allocator, address: ?[]const u8, fallback_title: []const u8, ctx: *anyopaque, then: ParsedThen) void {
    start(wv, a, address, fallback_title, ctx, .{ .parsed = then });
}

/// page_text adapter: false if `t` is not a PDF tab; else reads it and calls `then` with a page_text.Read.
pub fn readTab(t: *Tab, a: std.mem.Allocator, address: ?[]const u8, ctx: *anyopaque, then: page_text.Then) bool {
    const wv = t.web orelse return false;
    if (!isPdfTab(t)) return false;
    readWebViewPdf(wv, a, address, t.label(), ctx, then);
    return true;
}

pub fn readWebViewPdf(wv: objc.Object, a: std.mem.Allocator, address: ?[]const u8, fallback_title: []const u8, ctx: *anyopaque, then: page_text.Then) void {
    start(wv, a, address, fallback_title, ctx, .{ .read = then });
}

fn start(wv: objc.Object, a: std.mem.Allocator, address: ?[]const u8, fallback_title: []const u8, ctx: *anyopaque, then: @FieldType(Job, "then")) void {
    const j = std.heap.c_allocator.create(Job) catch return deliver(a, address, ctx, then, null);
    j.* = .{
        .wv = objc.retain(wv),
        .a = a,
        .address = if (address) |s| a.dupe(u8, s) catch null else null,
        .title = a.dupe(u8, fallback_title) catch "PDF",
        .ctx = ctx,
        .then = then,
    };
    if (!objc.msg(objc.BOOL, wv, "respondsToSelector:", .{objc.sel("_getMainResourceDataWithCompletionHandler:")}))
        return gotData(j, null, null);
    var block = DataBlock.init(j, gotData);
    objc.msg(void, wv, "_getMainResourceDataWithCompletionHandler:", .{@as(*anyopaque, @ptrCast(&block))});
}

fn gotData(j: *Job, data: ?objc.Object, _: ?objc.Object) void {
    var parsed: ?ParsedPdf = null;
    if (data) |d| if (objc.msg(objc.NSUInteger, d, "length", .{}) > 0) {
        parsed = parseData(j.a, d, j.title);
    };
    if (parsed == null) if (j.address) |s| if (std.ascii.startsWithIgnoreCase(s, "file://")) {
        parsed = parseFileUrl(j.a, s, j.title);
    };
    const job = j.*;
    objc.release(j.wv);
    std.heap.c_allocator.destroy(j);
    deliver(job.a, job.address, job.ctx, job.then, parsed);
}

fn deliver(a: std.mem.Allocator, address: ?[]const u8, ctx: *anyopaque, then: @FieldType(Job, "then"), parsed: ?ParsedPdf) void {
    switch (then) {
        .parsed => |f| f(ctx, parsed),
        .read => |f| {
            const p = parsed orelse return f(ctx, null);
            f(ctx, page_text.shaped(a, p.title, address, p.text, p.links, page_text.limit) catch null);
        },
    }
}

// MARK: - a tiny PDF, for tests

/// A valid PDF whose page `i` shows `pages[i]`'s lines in Helvetica, its
/// first page linking to `link`. Lines must not hold `(`, `)` or `\`.
pub fn tinyPdf(a: std.mem.Allocator, pages: []const []const []const u8, link: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var offs: std.ArrayList(usize) = .empty;
    const n = pages.len;
    // Objects: 1 catalog, 2 pages, 3 font, then page and content per page, then the link.
    const annot = 4 + 2 * n;
    try out.appendSlice(a, "%PDF-1.4\n");
    try offs.append(a, out.items.len);
    try out.appendSlice(a, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
    try offs.append(a, out.items.len);
    try out.appendSlice(a, "2 0 obj\n<< /Type /Pages /Kids [");
    for (0..n) |i| try out.print(a, " {d} 0 R", .{4 + 2 * i});
    try out.print(a, " ] /Count {d} >>\nendobj\n", .{n});
    try offs.append(a, out.items.len);
    try out.appendSlice(a, "3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n");
    for (pages, 0..) |lines, i| {
        try offs.append(a, out.items.len);
        try out.print(a, "{d} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {d} 0 R", .{ 4 + 2 * i, 5 + 2 * i });
        if (i == 0 and link != null) try out.print(a, " /Annots [{d} 0 R]", .{annot});
        try out.appendSlice(a, " >>\nendobj\n");
        var content: std.ArrayList(u8) = .empty;
        for (lines, 0..) |line, k| try content.print(a, "BT /F1 12 Tf 72 {d} Td ({s}) Tj ET\n", .{ 720 - 24 * k, line });
        try offs.append(a, out.items.len);
        try out.print(a, "{d} 0 obj\n<< /Length {d} >>\nstream\n{s}endstream\nendobj\n", .{ 5 + 2 * i, content.items.len, content.items });
    }
    if (link) |l| {
        try offs.append(a, out.items.len);
        try out.print(a, "{d} 0 obj\n<< /Type /Annot /Subtype /Link /Rect [72 600 300 620] /Border [0 0 0] /A << /Type /Action /S /URI /URI ({s}) >> >>\nendobj\n", .{ annot, l });
    }
    const xref = out.items.len;
    try out.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{offs.items.len + 1});
    for (offs.items) |o| try out.print(a, "{d:0>10} 00000 n \n", .{o});
    try out.print(a, "trailer\n<< /Size {d} /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ offs.items.len + 1, xref });
    return out.toOwnedSlice(a);
}

test "parseBytes reads pages, links and sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try tinyPdf(a, &.{
        &.{ "Abstract", "Kea are alpine parrots.", "1 Introduction", "Feathers keep them warm." },
        &.{ "2 Quantum Kea Equations", "E equals kea squared." },
    }, "https://example.com/ref");
    const p = parseBytes(a, bytes, "Fallback") orelse return error.NotParsed;
    try std.testing.expectEqual(@as(usize, 2), p.pages);
    try std.testing.expectEqualStrings("Fallback", p.title);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "[Page 1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "[Page 2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "Quantum Kea") != null);
    try std.testing.expectEqual(@as(usize, 1), p.links.len);
    try std.testing.expectEqualStrings("https://example.com/ref", p.links[0]);
    try std.testing.expect(p.sections.len >= 2);
    try std.testing.expectEqual(@as(usize, 2), p.sections[p.sections.len - 1].page);
}

test "isHeading and isPdfUrl" {
    try std.testing.expect(isHeading("1 Introduction"));
    try std.testing.expect(isHeading("2.1 Setup"));
    try std.testing.expect(isHeading("II. Methods"));
    try std.testing.expect(isHeading("Abstract: Alpine Kea Thermodynamics"));
    try std.testing.expect(!isHeading("2 kea went home"));
    try std.testing.expect(!isHeading("Abstracting things"));
    try std.testing.expect(isPdfUrl("https://arxiv.org/pdf/1.PDF"));
    try std.testing.expect(isPdfUrl("file:///tmp/a.pdf"));
    try std.testing.expect(!isPdfUrl("https://example.com/a.html"));
}
