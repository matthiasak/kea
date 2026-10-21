//! Ubi Chat's four tools (`search_tabs`, `search_history`, `search_bookmarks`,
//! `read_tab`): schema definitions and execution against the browser's open
//! tabs, history and bookmarks. Private tabs are never searched or read.
const std = @import("std");
const Browser = @import("../model/browser.zig").Browser;
const json = @import("../data/json.zig");
const ubi = @import("ubi_chat.zig");
const page = @import("page_text.zig");
const sse = @import("client_sse.zig");
const A = std.mem.Allocator;

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    param: []const u8,
    param_description: []const u8,
};

pub const specs = [_]Spec{
    .{
        .name = "search_tabs",
        .description = "Search open browser tabs by title or URL.",
        .param = "query",
        .param_description = "Words to match in the tab title or URL.",
    },
    .{
        .name = "search_history",
        .description = "Search browsing history by title or URL.",
        .param = "query",
        .param_description = "Words to match in the history title or URL.",
    },
    .{
        .name = "search_bookmarks",
        .description = "Search saved bookmarks by title or URL.",
        .param = "query",
        .param_description = "Words to match in the bookmark title or URL.",
    },
    .{
        .name = "read_tab",
        .description = "Read the visible text of an open tab by its exact URL.",
        .param = "url",
        .param_description = "The exact URL of the open tab to read.",
    },
};

pub const Result = struct {
    text: []const u8,
    said: []const u8,
    read: ?page.Read = null,
};

pub const Done = *const fn (ctx: *anyopaque, result: Result) void;

const Hit = struct {
    title: []const u8,
    url: []const u8,
};

fn argString(a: A, args_json: []const u8, key: []const u8) []const u8 {
    const val = std.json.parseFromSliceLeaky(std.json.Value, a, args_json, .{}) catch return "";
    if (val != .object) return "";
    const field = val.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}

pub fn run(b: *Browser, a: A, name: []const u8, args_json: []const u8, ctx: *anyopaque, done: Done) void {
    if (std.mem.eql(u8, name, "read_tab")) {
        const target = std.mem.trim(u8, argString(a, args_json, "url"), " \t\r\n");
        const said = if (target.len == 0) "Read tab" else std.fmt.allocPrint(a, "Read {s}", .{target}) catch "Read tab";
        const tab = (if (target.len > 0) ubi.openTab(b.kea, target) else null) orelse {
            return done(ctx, .{ .text = "That page isn't open in a tab.", .said = said });
        };
        const Job = struct {
            a: A,
            said: []const u8,
            ctx: *anyopaque,
            done: Done,
            fn finished(raw: *anyopaque, got: ?page.Read) void {
                const j: *@This() = @ptrCast(@alignCast(raw));
                const ctx_inner = j.ctx;
                const done_inner = j.done;
                const said_inner = j.said;
                const alloc = j.a;
                std.heap.c_allocator.destroy(j);
                const r = got orelse return done_inner(ctx_inner, .{ .text = "That page isn't open in a tab.", .said = said_inner });
                const body = alloc.dupe(u8, sse.prefix(r.text, 8000)) catch r.text;
                done_inner(ctx_inner, .{ .text = body, .said = said_inner, .read = r });
            }
        };
        const j = std.heap.c_allocator.create(Job) catch return done(ctx, .{ .text = "That page isn't open in a tab.", .said = said });
        j.* = .{ .a = a, .said = said, .ctx = ctx, .done = done };
        return page.read(tab, a, j, Job.finished);
    }

    const raw_q = std.mem.trim(u8, argString(a, args_json, "query"), " \t\r\n");
    const q_lower = std.ascii.allocLowerString(a, raw_q) catch "";
    const source: ubi.Source = if (std.mem.eql(u8, name, "search_tabs"))
        .tab
    else if (std.mem.eql(u8, name, "search_bookmarks"))
        .bookmark
    else
        .history;
    const noun = switch (source) {
        .tab => "tabs",
        .bookmark => "bookmarks",
        else => "history",
    };
    const said = if (raw_q.len == 0)
        (std.fmt.allocPrint(a, "Searched {s}", .{noun}) catch "Searched")
    else
        (std.fmt.allocPrint(a, "Searched {s} for \u{201C}{s}\u{201D}", .{ noun, raw_q }) catch "Searched");

    const suggestions = if (source == .bookmark and q_lower.len == 0) blk: {
        var list: std.ArrayList(ubi.Suggestion) = .empty;
        for (b.kea.bookmarks.matches(a, "") catch &.{}) |hit| {
            const u = hit.node.url orelse continue;
            if (list.items.len >= 10) break;
            list.append(a, .{ .source = .bookmark, .title = hit.node.label(a) catch "", .detail = u, .url = u }) catch break;
        }
        break :blk list.items;
    } else ubi.pages(a, q_lower, &.{source}, b, &.{}) catch &.{};

    var hits: std.ArrayList(Hit) = .empty;
    for (suggestions) |s| {
        if (hits.items.len >= 10) break;
        hits.append(a, .{ .title = s.title, .url = s.url orelse s.detail }) catch break;
    }
    const text = json.encode(a, hits.items) catch "[]";
    done(ctx, .{ .text = text, .said = said });
}
