//! A site joining Search a site by itself (SiteSearch.swift `learn`,
//! `OpenSearch`, `SameSiteRedirects`): a site's own https home page names
//! its OpenSearch description; it is fetched from that site only (https,
//! 10 s, 64 KB, no cookies, redirects kept on the site) and its HTML
//! search template adopted. Nothing is fetched for a built-in's site or one
//! already learned.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const url = @import("url.zig");
const registrable = @import("registrable.zig").registrable;
const ss_mod = @import("site_search.zig");
const SiteSearch = ss_mod.SiteSearch;

/// One description on its way.
pub const Job = struct {
    gpa: std.mem.Allocator,
    /// Null once the store has gone.
    ss: ?*SiteSearch,
    host: []u8,
};

/// Asks for `description` as `page`'s search; true when a fetch went out.
pub fn learn(ss: *SiteSearch, page: []const u8, description: []const u8) bool {
    const gpa = ss.gpa;
    const pp = url.Parts.parse(page) orelse return false;
    const dp = url.Parts.parse(description) orelse return false;
    if (!pp.schemeIs("https") or !dp.schemeIs("https")) return false;
    const host = ss_mod.siteHost(gpa, page) orelse return false;
    var keep = false;
    defer if (!keep) gpa.free(host);
    if (!ss_mod.sameSite(gpa, description, host)) return false;
    const mine = registrable(gpa, host) catch return false;
    defer gpa.free(mine);
    for (ss.built_in) |b| {
        const theirs = registrable(gpa, ss_mod.bare(b.host)) catch return false;
        defer gpa.free(theirs);
        if (std.mem.eql(u8, theirs, mine)) return false;
    }
    for (ss.learned) |s| if (std.mem.eql(u8, s.host, host)) return false;

    const pool = objc.Pool.push();
    defer pool.pop();
    const nsurl = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(description)}) orelse return false;
    const job = gpa.create(Job) catch return false;
    ss.inflight.append(gpa, job) catch {
        gpa.destroy(job);
        return false;
    };
    job.* = .{ .gpa = gpa, .ss = ss, .host = host };
    keep = true;
    // NSURLRequestReloadIgnoringLocalCacheData
    const req = objc.msg(objc.Object, objc.class("NSMutableURLRequest"), "requestWithURL:cachePolicy:timeoutInterval:", .{ nsurl, @as(objc.NSUInteger, 1), @as(f64, 10) });
    objc.msg(void, req, "setHTTPShouldHandleCookies:", .{objc.NO});
    const config = objc.msg(objc.Object, objc.class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", .{});
    _ = redirectsClass();
    const redirects = objc.msg(objc.Object, objc.alloc("KeaZigSameSiteRedirects"), "init", .{});
    objc.setZig(redirects, job);
    const main_queue = objc.msg(objc.Object, objc.class("NSOperationQueue"), "mainQueue", .{});
    const session = objc.msg(objc.Object, objc.class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:", .{ config, redirects, main_queue });
    objc.release(redirects);
    var done = objc.Block(Job, &.{ ?objc.Object, ?objc.Object, ?objc.Object }).init(job, arrived);
    const task = objc.msg(objc.Object, session, "dataTaskWithRequest:completionHandler:", .{ req, &done });
    objc.msg(void, task, "resume", .{});
    // Invalidated once its one task is done.
    objc.msg(void, session, "finishTasksAndInvalidate", .{});
    return true;
}

/// On the main queue (the session's delegate queue).
fn arrived(job: *Job, data: ?objc.Object, response: ?objc.Object, _: ?objc.Object) void {
    const gpa = job.gpa;
    defer {
        gpa.free(job.host);
        gpa.destroy(job);
    }
    const ss = job.ss orelse return;
    for (ss.inflight.items, 0..) |j, i| if (j == job) {
        _ = ss.inflight.swapRemove(i);
        break;
    };
    const d = data orelse return;
    const r = response orelse return;
    if (!objc.msg(objc.BOOL, r, "isKindOfClass:", .{objc.class("NSHTTPURLResponse")})) return;
    if (objc.msg(objc.NSInteger, r, "statusCode", .{}) != 200) return;
    const len = objc.msg(objc.NSUInteger, d, "length", .{});
    if (len > 64 * 1024) return;
    const ptr = objc.msg(?[*]const u8, d, "bytes", .{}) orelse return;
    const template = parse(gpa, ptr[0..len]) orelse return;
    defer gpa.free(template);
    ss.adopt(job.host, template);
}

fn redirectsClass() objc.Class {
    return objc.defineClass(.{
        .name = "KeaZigSameSiteRedirects",
        .protocols = &.{"NSURLSessionTaskDelegate"},
        .methods = &.{.{
            .name = "URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:",
            .imp = &willRedirect,
            .types = "v@:@@@@@?",
        }},
    });
}

/// Redirected only within the site it was asked of, over https.
fn willRedirect(obj: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object, _: objc.Object, request: objc.Object, completion: *anyopaque) callconv(.c) void {
    const allowed = blk: {
        const job = objc.getZig(Job, obj) orelse break :blk false;
        const ss = job.ss orelse break :blk false;
        const next = objc.msg(?objc.Object, request, "URL", .{}) orelse break :blk false;
        const address = objc.fromNSString(objc.msg(?objc.Object, next, "absoluteString", .{}));
        const p = url.Parts.parse(address) orelse break :blk false;
        break :blk p.schemeIs("https") and ss_mod.sameSite(ss.gpa, address, job.host);
    };
    const raw: [*]const *const anyopaque = @ptrCast(@alignCast(completion));
    const invoke: *const fn (*anyopaque, ?objc.Object) callconv(.c) void = @ptrCast(@alignCast(raw[2]));
    invoke(completion, if (allowed) request else null);
}

// MARK: OpenSearch

const Reader = struct { gpa: std.mem.Allocator, template: ?[]u8 = null };

/// An OpenSearch description's HTML results address, the words as %s, on
/// `gpa`. Optional parameters (`{name?}`) are left out; any other one
/// refuses the description.
pub fn parse(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    var reader: Reader = .{ .gpa = gpa };
    const ok = blk: {
        const pool = objc.Pool.push();
        defer pool.pop();
        const cls = objc.defineClass(.{
            .name = "KeaZigOpenSearchReader",
            .protocols = &.{"NSXMLParserDelegate"},
            .methods = &.{.{
                .name = "parser:didStartElement:namespaceURI:qualifiedName:attributes:",
                .imp = &didStart,
                .types = "v@:@@@@@",
            }},
        });
        _ = cls;
        const bytes = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ data.ptr, @as(objc.NSUInteger, data.len) });
        const parser = objc.msg(objc.Object, objc.alloc("NSXMLParser"), "initWithData:", .{bytes});
        defer objc.release(parser);
        const delegate = objc.msg(objc.Object, objc.alloc("KeaZigOpenSearchReader"), "init", .{});
        defer objc.release(delegate);
        objc.setZig(delegate, &reader);
        objc.msg(void, parser, "setDelegate:", .{delegate});
        objc.msg(void, parser, "setShouldResolveExternalEntities:", .{objc.NO});
        const parsed = objc.msg(objc.BOOL, parser, "parse", .{});
        objc.msg(void, parser, "setDelegate:", .{@as(?objc.Object, null)});
        break :blk parsed;
    };
    const found = reader.template orelse return null;
    defer gpa.free(found);
    if (!ok) return null;
    const filled = std.mem.replaceOwned(u8, gpa, found, "{searchTerms}", "%s") catch return null;
    defer gpa.free(filled);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < filled.len) : (i += 1) {
        if (filled[i] == '{') {
            if (std.mem.indexOfAnyPos(u8, filled, i + 1, "{}")) |j| {
                if (filled[j] == '}' and filled[j - 1] == '?') {
                    i = j;
                    continue;
                }
            }
        }
        out.append(gpa, filled[i]) catch return null;
    }
    const template = out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
    if (std.mem.indexOfScalar(u8, template, '{') != null or std.mem.count(u8, template, "%s") != 1) {
        gpa.free(template);
        return null;
    }
    return template;
}

fn didStart(obj: objc.Object, _: objc.SEL, _: objc.Object, element: objc.Object, _: ?objc.Object, _: ?objc.Object, attrs: objc.Object) callconv(.c) void {
    const r = objc.getZig(Reader, obj) orelse return;
    if (r.template != null) return;
    const name = objc.fromNSString(element);
    const local = name[(if (std.mem.lastIndexOfScalar(u8, name, ':')) |c| c + 1 else 0)..];
    if (!std.mem.eql(u8, local, "Url")) return;
    const kind = objc.fromNSString(objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("type")}));
    const method = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("method")});
    if (!std.ascii.eqlIgnoreCase(kind, "text/html")) return;
    if (method) |m| if (!std.ascii.eqlIgnoreCase(objc.fromNSString(m), "get")) return;
    const template = objc.msg(?objc.Object, attrs, "objectForKey:", .{objc.nsString("template")}) orelse return;
    r.template = r.gpa.dupe(u8, objc.fromNSString(template)) catch null;
}

test "opensearch description gives its html template" {
    const gpa = std.testing.allocator;
    const xml =
        \\<?xml version="1.0"?>
        \\<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
        \\<ShortName>Ex</ShortName>
        \\<Url type="application/x-suggestions+json" template="https://ex.com/s?q={searchTerms}"/>
        \\<Url type="TEXT/HTML" method="GET" template="https://ex.com/search?q={searchTerms}&amp;page={startPage?}&amp;x=1"/>
        \\</OpenSearchDescription>
    ;
    const t = parse(gpa, xml).?;
    defer gpa.free(t);
    try std.testing.expectEqualStrings("https://ex.com/search?q=%s&page=&x=1", t);
    try std.testing.expect(parse(gpa, "<os:Url xmlns:os=\"x\" type=\"text/html\" template=\"https://ex.com/?q={searchTerms}&amp;l={language}\"/>") == null);
    try std.testing.expect(parse(gpa, "<Url type=\"text/html\" method=\"post\" template=\"https://ex.com/?q={searchTerms}\"/>") == null);
    try std.testing.expect(parse(gpa, "<Url type=\"text/html\" template=\"https://ex.com/\"/>") == null);
    try std.testing.expect(parse(gpa, "not xml <") == null);
    const prefixed = parse(gpa, "<os:Url xmlns:os=\"x\" type=\"text/html\" template=\"https://ex.com/?q={searchTerms}\"/>").?;
    defer gpa.free(prefixed);
    try std.testing.expectEqualStrings("https://ex.com/?q=%s", prefixed);
}

test "learn asks nothing of a built-in's site, plain http, or another site" {
    const Temp = @import("../tests/temp.zig").Temp;
    const Store = @import("store.zig").Store;
    const gpa = std.testing.allocator;
    var t = try Temp.init(gpa);
    defer t.deinit(gpa);
    var store = try Store.init(gpa, t.root, t.suite);
    defer store.deinit();
    var ss = SiteSearch.init(gpa, &store);
    defer ss.deinit();
    try std.testing.expect(!learn(&ss, "http://ex.com/", "https://ex.com/os.xml"));
    try std.testing.expect(!learn(&ss, "https://ex.com/", "http://ex.com/os.xml"));
    try std.testing.expect(!learn(&ss, "https://www.github.com/", "https://github.com/os.xml"));
    try std.testing.expect(!learn(&ss, "https://gist.github.com/", "https://gist.github.com/os.xml"));
    try std.testing.expect(!learn(&ss, "https://ex.com/", "https://other.com/os.xml"));
    ss.adopt("ex.com", "https://ex.com/?q=%s");
    try std.testing.expect(!learn(&ss, "https://www.ex.com/", "https://ex.com/os.xml"));
    try std.testing.expectEqual(@as(usize, 0), ss.inflight.items.len);
}
