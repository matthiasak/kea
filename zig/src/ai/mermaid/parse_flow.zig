//! Flowchart parser: node references (`A[label]`, `B{...}`, `C & D`) joined
//! by link operators (`-->`, `-.->`, `==>`, `-- text -->`, `-->|text|`).
//! Positions are byte offsets; every special character is ASCII, so stepping
//! bytes visits the same characters Swift's `[Character]` scan does.
const std = @import("std");
const m = @import("mermaid.zig");
const text = @import("text.zig");
const lg = @import("layout_graph.zig");

const Ref = struct { id: []const u8, lines: ?text.Lines, shape: ?m.Shape };
const Op = struct { dashed: bool, thick: bool, head: m.Head, label: ?[]const u8 };

pub fn parseFlowchart(a: std.mem.Allocator, stmts: []const []const u8, default_dir: []const u8, kind: []const u8) !?m.Diagram {
    var dir = default_dir;
    var g: lg.Graph = .{};
    const ascii = std.ascii;

    for (stmts) |stmt| {
        if (ascii.eqlIgnoreCase(stmt, "end") or ascii.startsWithIgnoreCase(stmt, "subgraph ") or ascii.eqlIgnoreCase(stmt, "subgraph") or
            ascii.startsWithIgnoreCase(stmt, "classdef ") or ascii.startsWithIgnoreCase(stmt, "class ") or
            ascii.startsWithIgnoreCase(stmt, "style ") or ascii.startsWithIgnoreCase(stmt, "linkstyle ") or
            ascii.startsWithIgnoreCase(stmt, "click ")) continue;
        if (ascii.startsWithIgnoreCase(stmt, "direction ")) {
            const parts = try text.words(a, stmt);
            if (parts.len > 1) dir = text.normalizeDir(parts[1]);
            continue;
        }
        var pos: usize = 0;
        const first = try parseRefGroup(a, stmt, &pos) orelse continue;
        var left = try ensureAll(a, &g, first) orelse return null;
        var steps: usize = 0;
        while (pos < stmt.len and steps < 256) {
            steps += 1;
            skipSpaces(stmt, &pos);
            if (pos >= stmt.len) break;
            const op = try parseOp(a, stmt, &pos) orelse break;
            skipSpaces(stmt, &pos);
            const right_group = try parseRefGroup(a, stmt, &pos) orelse break;
            const right = try ensureAll(a, &g, right_group) orelse return null;
            for (left) |l| for (right) |r| {
                if (g.edges.items.len >= m.max_edges) return null;
                try g.edges.append(a, .{ .from = l, .to = r, .dashed = op.dashed, .thick = op.thick, .head = op.head, .label = op.label });
            };
            left = right;
        }
    }

    if (g.nodes.items.len == 0) return null;
    return lg.layoutGraph(a, g.nodes.items, g.edges.items, dir, kind);
}

/// Node indices for `refs`, null past the node cap.
fn ensureAll(a: std.mem.Allocator, g: *lg.Graph, refs: []const Ref) !?[]usize {
    const out = try a.alloc(usize, refs.len);
    for (refs, out) |r, *o| o.* = try ensureNode(a, g, r) orelse return null;
    return out;
}

fn ensureNode(a: std.mem.Allocator, g: *lg.Graph, r: Ref) !?usize {
    if (g.index.get(r.id)) |existing| {
        const node = &g.nodes.items[existing];
        if (!node.explicit) if (r.lines) |lines| if (r.shape) |shape| {
            node.lines = lines;
            node.shape = shape;
            node.explicit = true;
        };
        return existing;
    }
    return g.add(a, .{
        .id = r.id,
        .lines = r.lines orelse try a.dupe([]const u8, &.{r.id}),
        .shape = r.shape orelse .rect,
        .titled = false,
        .explicit = r.lines != null,
    });
}

fn skipSpaces(s: []const u8, pos: *usize) void {
    while (pos.* < s.len) {
        const n = text.wsLen(s, pos.*);
        if (n == 0) return;
        pos.* += n;
    }
}

fn parseRefGroup(a: std.mem.Allocator, s: []const u8, pos: *usize) !?[]Ref {
    skipSpaces(s, pos);
    const first = try parseSingleRef(a, s, pos) orelse return null;
    var group: std.ArrayList(Ref) = .empty;
    try group.append(a, first);
    var steps: usize = 0;
    while (pos.* < s.len and steps < 64) {
        steps += 1;
        const saved = pos.*;
        skipSpaces(s, pos);
        if (pos.* >= s.len or s[pos.*] != '&') {
            pos.* = saved;
            break;
        }
        pos.* += 1;
        skipSpaces(s, pos);
        const next = try parseSingleRef(a, s, pos) orelse {
            pos.* = saved;
            break;
        };
        try group.append(a, next);
    }
    return group.items;
}

const Opener = struct { open: []const u8, closers: []const []const u8, shape: m.Shape };
const openers = [_]Opener{
    .{ .open = "((", .closers = &.{"))"}, .shape = .circle },
    .{ .open = "([", .closers = &.{"])"}, .shape = .stadium },
    .{ .open = "[[", .closers = &.{"]]"}, .shape = .rect },
    .{ .open = "[(", .closers = &.{")]"}, .shape = .rect },
    .{ .open = "{{", .closers = &.{"}}"}, .shape = .hexagon },
    .{ .open = "[/", .closers = &.{ "/]", "\\]" }, .shape = .rect },
    .{ .open = "[\\", .closers = &.{ "\\]", "/]" }, .shape = .rect },
    .{ .open = "[", .closers = &.{"]"}, .shape = .rect },
    .{ .open = "(", .closers = &.{")"}, .shape = .round },
    .{ .open = "{", .closers = &.{"}"}, .shape = .diamond },
    .{ .open = ">", .closers = &.{"]"}, .shape = .rect },
};

fn parseSingleRef(a: std.mem.Allocator, s: []const u8, pos: *usize) !?Ref {
    skipSpaces(s, pos);
    const start = pos.*;
    while (pos.* < s.len) {
        const ch = s[pos.*];
        if (ch == '-' and pos.* + 1 < s.len and (s[pos.* + 1] == '-' or s[pos.* + 1] == '.' or s[pos.* + 1] == '>')) break;
        const c = text.cpAt(s, pos.*);
        if (text.isAlnum(c.cp) or ch == '_' or (ch == '-' and pos.* > start)) pos.* += c.len else break;
    }
    if (pos.* == start) return null;
    const id = s[start..pos.*];
    if (pos.* >= s.len) return .{ .id = id, .lines = null, .shape = null };

    for (openers) |o| {
        if (!std.mem.startsWith(u8, s[pos.*..], o.open)) continue;
        pos.* += o.open.len;
        const text_start = pos.*;
        var in_quotes = false;
        var found: ?usize = null;
        var closer_len: usize = 0;
        scan: while (pos.* < s.len) : (pos.* += 1) {
            if (s[pos.*] == '"') {
                in_quotes = !in_quotes;
                continue;
            }
            if (!in_quotes) for (o.closers) |c| if (std.mem.startsWith(u8, s[pos.*..], c)) {
                found = pos.*;
                closer_len = c.len;
                break :scan;
            };
        }
        const raw = if (found) |end| s[text_start..end] else s[text_start..];
        pos.* = if (found) |end| end + closer_len else s.len;
        return .{ .id = id, .lines = try text.cleanLabel(a, raw), .shape = o.shape };
    }
    return .{ .id = id, .lines = null, .shape = null };
}

fn parseOp(a: std.mem.Allocator, s: []const u8, pos: *usize) !?Op {
    skipSpaces(s, pos);
    const saved = pos.*;
    if (pos.* >= s.len) return null;
    if (s[pos.*] == '<') pos.* += 1;
    const run_start = pos.*;
    while (pos.* < s.len and (s[pos.*] == '-' or s[pos.*] == '=' or s[pos.*] == '.')) pos.* += 1;
    if (pos.* - run_start < 2) {
        pos.* = saved;
        return null;
    }
    const first_run = s[run_start..pos.*];
    var close_token: []const u8 = "";
    var has_arrow = false;
    var head: m.Head = .none;
    if (pos.* < s.len and s[pos.*] == '>') {
        has_arrow = true;
        head = .arrow;
        pos.* += 1;
    } else if (pos.* < s.len and (s[pos.*] == 'x' or s[pos.*] == 'o')) {
        const next = pos.* + 1;
        if (next >= s.len or (!text.isAlnum(text.cpAt(s, next).cp) and s[next] != '_')) {
            head = if (s[pos.*] == 'x') .cross else .circle;
            pos.* += 1;
        }
    }

    var label: ?[]const u8 = null;

    // Inline label form: `-- text -->`, `== text ==>`, `-. text .->`
    const eql = std.mem.eql;
    if (!has_arrow and head == .none and (eql(u8, first_run, "--") or eql(u8, first_run, "==") or eql(u8, first_run, "-.")) and
        pos.* < s.len and text.wsLen(s, pos.*) > 0)
    {
        const after_first = pos.*;
        const closes = [_][]const u8{ "-.->", "-->", "---", "==>", "===", ".->", "-.-" };
        var scan = pos.*;
        found: while (scan < s.len) : (scan += 1) {
            for (closes) |c| if (std.mem.startsWith(u8, s[scan..], c)) {
                const raw = text.trim(s[after_first..scan]);
                if (raw.len > 0) label = try text.cleanJoined(a, raw);
                close_token = c;
                if (std.mem.endsWith(u8, c, ">")) head = .arrow;
                pos.* = scan + c.len;
                break :found;
            };
        }
    }

    // Pipe label form: `-->|label|`
    skipSpaces(s, pos);
    if (pos.* < s.len and s[pos.*] == '|') {
        pos.* += 1;
        const l_start = pos.*;
        while (pos.* < s.len and s[pos.*] != '|') pos.* += 1;
        const raw = text.trim(s[l_start..pos.*]);
        if (raw.len > 0) label = try text.cleanJoined(a, raw);
        if (pos.* < s.len and s[pos.*] == '|') pos.* += 1;
    }

    const has = std.mem.indexOfScalar;
    return .{
        .dashed = has(u8, first_run, '.') != null or has(u8, close_token, '.') != null,
        .thick = has(u8, first_run, '=') != null or has(u8, close_token, '=') != null,
        .head = head,
        .label = label,
    };
}
