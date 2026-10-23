//! What of a page goes to the model, and how it is framed (AIPage.swift).
//!
//! The page's words, read in Kea's own world where the page's scripts can't
//! reach, and only the ones a person reading could see. In the prompt it is
//! fenced between markers made afresh for each request, so the page can't
//! close the fence itself, and called what it is: text from the website, to
//! be read and never obeyed. The answer is checked for addresses, phone
//! numbers and emails the page never had.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const json = @import("../data/json.zig");
const url = @import("../data/url.zig");
const config = @import("../web/config.zig");
const Tab = @import("../web/tab.zig").Tab;
const regex = @import("regex.zig");
const sse = @import("client_sse.zig");

pub const script = @embedFile("js/page.js");

/// About 6,000 tokens: the start and the end of a longer page.
pub const limit = 24_000;

pub const Read = struct {
    title: []const u8,
    url: ?[]const u8,
    text: []const u8,
    /// The web addresses of the page's visible links, for the check.
    links: []const []const u8,
    /// Too long: the start and the end are kept.
    cut: bool,
    /// It has words addressed to an AI: the answer may have been steered.
    addressed: bool = false,
};

/// A page read, on the reader's allocator; null when there was nothing to read.
pub const Then = *const fn (ctx: *anyopaque, read: ?Read) void;

const Job = struct { a: std.mem.Allocator, address: ?[]const u8, ctx: *anyopaque, then: Then };
const EvalBlock = objc.Block(Job, &.{ ?objc.Object, ?objc.Object });

/// The page on screen in `t`, read onto `a`; `then` always comes, on the
/// main thread, even when the tab goes meanwhile.
pub fn read(t: *Tab, a: std.mem.Allocator, ctx: *anyopaque, then: Then) void {
    const wv = t.web orelse return then(ctx, null);
    const j = std.heap.c_allocator.create(Job) catch return then(ctx, null);
    j.* = .{ .a = a, .address = if (t.address) |s| a.dupe(u8, s) catch null else null, .ctx = ctx, .then = then };
    const pool = objc.Pool.push();
    defer pool.pop();
    var block = EvalBlock.init(j, evaluated);
    objc.msg(void, wv, "evaluateJavaScript:inFrame:inContentWorld:completionHandler:", .{ objc.nsString(script), @as(?objc.Object, null), config.world(), @as(*anyopaque, @ptrCast(&block)) });
}

fn stringIn(dict: objc.Object, key: []const u8) ?[]const u8 {
    const v = objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)}) orelse return null;
    if (!objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")})) return null;
    return objc.fromNSString(v);
}

fn evaluated(j: *Job, value: ?objc.Object, _: ?objc.Object) void {
    const ctx = j.ctx;
    const then = j.then;
    const r = found(j, value);
    std.heap.c_allocator.destroy(j);
    then(ctx, r);
}

fn found(j: *Job, value: ?objc.Object) ?Read {
    const dict = value orelse return null;
    if (!objc.msg(objc.BOOL, dict, "isKindOfClass:", .{objc.class("NSDictionary")})) return null;
    const text = stringIn(dict, "text") orelse return null;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;
    const a = j.a;
    const title = a.dupe(u8, sse.prefix(stringIn(dict, "title") orelse "", 300)) catch return null;
    var links: std.ArrayList([]const u8) = .empty;
    if (objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString("links")})) |list| {
        if (objc.msg(objc.BOOL, list, "isKindOfClass:", .{objc.class("NSArray")})) {
            const n = @min(objc.msg(objc.NSUInteger, list, "count", .{}), 400);
            for (0..n) |i| {
                const s = objc.msg(objc.Object, list, "objectAtIndex:", .{i});
                if (!objc.msg(objc.BOOL, s, "isKindOfClass:", .{objc.class("NSString")})) continue;
                links.append(a, a.dupe(u8, objc.fromNSString(s)) catch return null) catch return null;
            }
        }
    }
    return shaped(a, title, j.address, a.dupe(u8, text) catch return null, links.items, limit) catch null;
}

/// Over `limit` characters: its start and end kept. On `a`.
pub fn shaped(a: std.mem.Allocator, title: []const u8, address: ?[]const u8, text: []const u8, links: []const []const u8, most: usize) !Read {
    var r: Read = .{ .title = title, .url = address, .text = text, .links = links, .cut = false };
    if ((std.unicode.utf8CountCodepoints(text) catch text.len) > most) {
        const head = sse.prefix(text, most * 2 / 3);
        const tail = @import("keys.zig").suffix(text, most / 3);
        r.text = try std.mem.concat(a, u8, &.{ head, "\n\n[…]\n\n", tail });
        r.cut = true;
    }
    const both = try std.mem.concat(a, u8, &.{ title, "\n", r.text });
    defer a.free(both);
    r.addressed = addressesAI(both);
    return r;
}

const ai_patterns = [_][]const u8{
    "(?i)\\b(ignore|disregard|forget)\\b.{0,20}\\b(previous|prior|above|earlier|all)\\b.{0,20}\\b(instructions?|prompts?|rules)\\b",
    "(?im)^\\s*(system|assistant)\\s*:",
    "(?im)^\\s*(system|assistant)\\s*$",
    "(?i)<\\|?(im_start|im_end|system)\\|?>",
    "(?i)\\b(you are|act as) (now )?(an? )?(ai|assistant|language model|llm|chatbot)\\b",
    "(?i)\\b(ai|assistant|model|llm)s?\\b.{0,30}\\b(must|should) (tell|say|add|include|output)\\b",
};

const AiRegexes = [ai_patterns.len]regex.Regex;
var ai_regex_cache: ?*AiRegexes = null;

fn cachedAiRegexes() ?*const AiRegexes {
    if (@atomicLoad(?*AiRegexes, &ai_regex_cache, .acquire)) |c| return c;
    const fresh = std.heap.c_allocator.create(AiRegexes) catch return null;
    for (&ai_patterns, 0..) |p, i| {
        fresh[i] = regex.Regex.init(p) orelse {
            for (fresh[0..i]) |r| r.deinit();
            std.heap.c_allocator.destroy(fresh);
            return null;
        };
    }
    if (@cmpxchgStrong(?*AiRegexes, &ai_regex_cache, null, fresh, .acq_rel, .acquire)) |existing| {
        for (fresh) |r| r.deinit();
        std.heap.c_allocator.destroy(fresh);
        return existing;
    }
    return fresh;
}

/// Words a page writes for a model rather than for you.
pub fn addressesAI(text: []const u8) bool {
    const list = cachedAiRegexes() orelse return false;
    for (list) |r| if (r.contains(text)) return true;
    return false;
}

// MARK: - the prompt

/// One page for the prompt, between the request's markers: its title and
/// address (without query, fragment or user: a sign-in link's token stays
/// out) and its words, any look-alike of the marker taken out. On `a`.
pub fn fenced(a: std.mem.Allocator, r: Read, fence: []const u8) ![]u8 {
    const open = try std.fmt.allocPrint(a, "<{s}>", .{fence});
    const close = try std.fmt.allocPrint(a, "</{s}>", .{fence});
    var address: []const u8 = "unknown";
    if (r.url) |u| if (url.Parts.parse(u)) |parts| {
        var p = parts;
        p.query = null;
        p.fragment = null;
        p.user = null;
        p.password = null;
        address = sse.prefix(try p.string(a), 300);
    };
    return std.fmt.allocPrint(a, "{s}\nPage title: {s}\nPage address: {s}{s}\n\n{s}\n{s}", .{
        open,
        try unfenced(a, r.title, open, close),
        address,
        if (r.cut) "\n(The page is long: its middle was left out.)" else "",
        try unfenced(a, r.text, open, close),
        close,
    });
}

fn unfenced(a: std.mem.Allocator, text: []const u8, open: []const u8, close: []const u8) ![]u8 {
    const once = try std.mem.replaceOwned(u8, a, text, open, "");
    return std.mem.replaceOwned(u8, a, once, close, "");
}

/// A marker no page could have guessed: "page-" and 16 lowercase hex digits.
pub fn newFence(buf: *[21]u8) []const u8 {
    const id = json.Uuid.random().string();
    @memcpy(buf[0..5], "page-");
    var n: usize = 5;
    for (id) |ch| {
        if (ch == '-') continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    return buf[0..n];
}

test {
    _ = @import("page_strays.zig");
}
