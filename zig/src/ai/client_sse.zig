//! Reading what a provider sends back (AIClient.swift, "reading"): the
//! answer as server-sent events, a line at a time, each event's text for
//! each way of writing, an error sent inside the stream, and what an error's
//! body says with any key taken out. `AIError`'s words are Swift's, verbatim.
const std = @import("std");
const regex = @import("regex.zig");
const Wire = @import("ai.zig").Wire;

/// `AIError`. Strings are borrowed for as long as the call that hands it on.
pub const Failure = union(enum) {
    no_key,
    refused_host,
    http: struct { status: i64, said: []const u8 },
    unreadable,
    @"unreachable": []const u8,

    /// `errorDescription`, on `a`.
    pub fn describe(f: Failure, a: std.mem.Allocator) ![]u8 {
        return switch (f) {
            .no_key => a.dupe(u8, "No key is kept for this provider."),
            .refused_host => a.dupe(u8, "That address isn't the provider's."),
            .http => |h| if (h.said.len == 0)
                std.fmt.allocPrint(a, "The provider answered {d}.", .{h.status})
            else
                std.fmt.allocPrint(a, "{s} ({d})", .{ h.said, h.status }),
            .unreadable => a.dupe(u8, "The provider's answer couldn't be read."),
            .@"unreachable" => |why| a.dupe(u8, why),
        };
    }
};

/// What a line said: keep reading, the answer is whole, or it failed.
pub const Said = union(enum) { more, done, failed: Failure };

/// A stream's lines, split as `bytes.lines` splits them, read as events.
pub const Reader = struct {
    /// Owns the pending line and the event name; each event is read on a
    /// scratch arena over it.
    a: std.mem.Allocator,
    /// Where a failure's words go (usually the stream's arena).
    keep: std.mem.Allocator,
    wire: Wire,
    /// Taken out of anything an error says.
    key: ?[]const u8,
    line: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,
    /// The CR of a CRLF split across two pieces.
    after_cr: bool = false,

    pub fn deinit(r: *Reader) void {
        r.line.deinit(r.a);
        r.event.deinit(r.a);
    }

    /// `bytes` read; each piece of text to `piece(ctx, text)`.
    pub fn feed(r: *Reader, bytes: []const u8, ctx: *anyopaque, piece: *const fn (*anyopaque, []const u8) void) Said {
        for (bytes) |ch| {
            if (r.after_cr) {
                r.after_cr = false;
                if (ch == '\n') continue;
            }
            if (ch == '\n' or ch == '\r') {
                r.after_cr = ch == '\r';
                const out = r.take(ctx, piece);
                r.line.clearRetainingCapacity();
                if (out != .more) return out;
                continue;
            }
            r.line.append(r.a, ch) catch return .{ .failed = .unreadable };
        }
        return .more;
    }

    /// The stream ended: its last line, unended, read too.
    pub fn finish(r: *Reader, ctx: *anyopaque, piece: *const fn (*anyopaque, []const u8) void) Said {
        if (r.line.items.len == 0) return .done;
        const out = r.take(ctx, piece);
        r.line.clearRetainingCapacity();
        return if (out == .more) .done else out;
    }

    fn take(r: *Reader, ctx: *anyopaque, piece: *const fn (*anyopaque, []const u8) void) Said {
        const line = r.line.items;
        if (std.mem.startsWith(u8, line, "event:")) {
            r.event.clearRetainingCapacity();
            r.event.appendSlice(r.a, std.mem.trim(u8, line[6..], " \t")) catch {};
            return .more;
        }
        if (!std.mem.startsWith(u8, line, "data:")) return .more;
        const data = std.mem.trim(u8, line[5..], " \t");
        if (std.mem.eql(u8, data, "[DONE]")) return .done;
        var arena: std.heap.ArenaAllocator = .init(r.a);
        defer arena.deinit();
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{}) catch return .more;
        if (value != .object) return .more;
        if (failure(r.keep, value, r.event.items, r.key)) |f| return .{ .failed = f };
        if (pieceOf(arena.allocator(), r.wire, value)) |text| if (text.len > 0) piece(ctx, text);
        return .more;
    }
};

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn string(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn first(v: ?std.json.Value) ?std.json.Value {
    const x = v orelse return null;
    if (x != .array or x.array.items.len == 0) return null;
    return x.array.items[0];
}

/// The text in one event, for each way of writing; on `a` for Gemini's joined parts.
pub fn pieceOf(a: std.mem.Allocator, wire: Wire, v: std.json.Value) ?[]const u8 {
    switch (wire) {
        .openAI => {
            const choice = first(field(v, "choices")) orelse return null;
            return string(field(field(choice, "delta") orelse return null, "content"));
        },
        .anthropic => {
            if (!std.mem.eql(u8, string(field(v, "type")) orelse "", "content_block_delta")) return null;
            const delta = field(v, "delta") orelse return null;
            if (delta != .object or !std.mem.eql(u8, string(field(delta, "type")) orelse "", "text_delta")) return null;
            return string(field(delta, "text"));
        },
        .gemini => {
            var out: std.ArrayList(u8) = .empty;
            const candidate = first(field(v, "candidates")) orelse return "";
            const parts = field(field(candidate, "content") orelse return "", "parts") orelse return "";
            if (parts != .array) return "";
            // A model that thinks marks those parts; only the answer is shown.
            for (parts.array.items) |p| {
                if (field(p, "thought")) |t| if (t == .bool and t.bool) continue;
                out.appendSlice(a, string(field(p, "text")) orelse continue) catch return null;
            }
            return out.items;
        },
    }
}

/// An error sent inside the stream, as Anthropic and OpenRouter do; its
/// words on `a`.
pub fn failure(a: std.mem.Allocator, v: std.json.Value, event: []const u8, key: ?[]const u8) ?Failure {
    const err = field(v, "error");
    if (!(std.mem.eql(u8, event, "error") or std.mem.eql(u8, string(field(v, "type")) orelse "", "error") or err != null)) return null;
    const words = string(if (err) |e| field(e, "message") else null) orelse string(err) orelse "";
    const code: i64 = blk: {
        const c = (if (err) |e| field(e, "code") else null) orelse break :blk 500;
        break :blk switch (c) {
            .integer => |i| i,
            .float => |f| if (@floor(f) == f and @abs(f) < 1e15) @intFromFloat(f) else 500,
            else => 500,
        };
    };
    return .{ .http = .{ .status = code, .said = scrub(a, prefix(words, 300), key) catch "" } };
}

/// What an error's body says, in a line, with any key taken out; on `a`.
pub fn said(a: std.mem.Allocator, body: []const u8, key: ?[]const u8) []const u8 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return "";
    var message: []const u8 = "";
    switch (v) {
        .object => {
            const err = field(v, "error");
            message = string(if (err) |e| field(e, "message") else null) orelse string(err) orelse string(field(v, "message")) orelse "";
        },
        .array => if (first(v)) |f| if (field(f, "error")) |e| if (e == .object) {
            message = string(field(e, "message")) orelse "";
        },
        else => {},
    }
    return scrub(a, prefix(message, 300), key) catch "";
}

/// Any key out of a text: the one sent, and anything shaped like one; on `a`.
pub fn scrub(a: std.mem.Allocator, text: []const u8, key: ?[]const u8) ![]u8 {
    var out = try a.dupe(u8, text);
    if (key) |k| if ((std.unicode.utf8CountCodepoints(k) catch k.len) >= 8) {
        // A quoted part of it, as "sk-abc…wxyz" is.
        for ([_][]const u8{ k, prefix(k, 8), suffixOf(k, 4) }) |part| {
            const next = try std.mem.replaceOwned(u8, a, out, part, "••••");
            a.free(out);
            out = next;
        }
    };
    for ([_][]const u8{ "sk-[A-Za-z0-9_\\-*.]{6,}", "AIza[A-Za-z0-9_\\-]{10,}", "AQ\\.[A-Za-z0-9_\\-]{10,}", "gsk_[A-Za-z0-9]{10,}" }) |shape| {
        const next = try regex.replace(a, out, shape, "••••");
        a.free(out);
        out = next;
    }
    return out;
}

/// The first `n` characters (code points), as `String.prefix(n)`.
// ponytail: code points, not grapheme clusters.
pub fn prefix(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var left = n;
    while (i < s.len and left > 0) : (left -= 1) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    return s[0..@min(i, s.len)];
}

fn suffixOf(s: []const u8, n: usize) []const u8 {
    return @import("keys.zig").suffix(s, n);
}
