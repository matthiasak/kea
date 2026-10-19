//! State and class diagram parsers; both lay out through `layoutGraph`.
const std = @import("std");
const m = @import("mermaid.zig");
const text = @import("text.zig");
const lg = @import("layout_graph.zig");
const regex = @import("../regex.zig");

const ascii = std.ascii;
const mem = std.mem;

pub fn parseState(a: mem.Allocator, stmts: []const []const u8) !?m.Diagram {
    var dir: []const u8 = "TD";
    var g: lg.Graph = .{};
    var in_note = false;

    for (stmts) |stmt| {
        const t = text.trim(stmt);
        if (in_note) {
            if (ascii.endsWithIgnoreCase(t, "end note")) in_note = false;
            continue;
        }
        if (ascii.startsWithIgnoreCase(t, "note ")) {
            if (mem.indexOfScalar(u8, t, ':') == null) in_note = true;
            continue;
        }
        if (mem.eql(u8, t, "}") or ascii.eqlIgnoreCase(t, "end")) continue;
        if (ascii.startsWithIgnoreCase(t, "direction ")) {
            const parts = try text.words(a, t);
            if (parts.len > 1) dir = text.normalizeDir(parts[1]);
            continue;
        }
        if (ascii.startsWithIgnoreCase(t, "state ")) {
            if (ascii.endsWithIgnoreCase(t, "<<choice>>")) {
                const parts = try text.words(a, t);
                if (parts.len >= 2) _ = try ensureState(a, &g, parts[1], &.{}, .diamond);
                continue;
            }
            if (ascii.findIgnoreCase(t, " as ")) |as| {
                // Swift traps on `state as X` (range start past its end); read no description.
                const desc = if (as >= 6) t[6..as] else "";
                var rest = text.trim(t[as + 4 ..]);
                if (mem.endsWith(u8, rest, "{")) rest = text.trim(rest[0 .. rest.len - 1]);
                if (rest.len > 0) _ = try ensureState(a, &g, rest, try text.cleanLabel(a, desc), .round);
            }
            continue;
        }
        if (mem.indexOf(u8, t, "-->")) |arrow| {
            const left_raw = text.trim(t[0..arrow]);
            const right_part = text.trim(t[arrow + 3 ..]);
            var right_raw = right_part;
            var label: ?[]const u8 = null;
            if (mem.indexOfScalar(u8, right_part, ':')) |colon| {
                right_raw = text.trim(right_part[0..colon]);
                const lbl = text.trim(right_part[colon + 1 ..]);
                if (lbl.len > 0) label = try text.cleanJoined(a, lbl);
            }
            if (left_raw.len == 0 or right_raw.len == 0) continue;
            const left_star = mem.eql(u8, left_raw, "[*]");
            const right_star = mem.eql(u8, right_raw, "[*]");
            const u = try ensureState(a, &g, if (left_star) "[*]start" else left_raw, null, if (left_star) .start else null) orelse return null;
            const v = try ensureState(a, &g, if (right_star) "[*]end" else right_raw, null, if (right_star) .end else null) orelse return null;
            if (g.edges.items.len >= m.max_edges) return null;
            try g.edges.append(a, .{ .from = u, .to = v, .dashed = false, .thick = false, .head = .arrow, .label = label });
            continue;
        }
        if (mem.indexOfScalar(u8, t, ':')) |colon| {
            const name = text.trim(t[0..colon]);
            const desc = text.trim(t[colon + 1 ..]);
            if (name.len > 0 and desc.len > 0) {
                _ = try ensureState(a, &g, name, try mem.concat(a, []const u8, &.{ &.{name}, try text.cleanLabel(a, desc) }), .round);
            }
        }
    }

    if (g.nodes.items.len == 0) return null;
    return lg.layoutGraph(a, g.nodes.items, g.edges.items, dir, "state");
}

fn ensureState(a: mem.Allocator, g: *lg.Graph, id: []const u8, lines: ?text.Lines, shape: ?m.Shape) !?usize {
    if (g.index.get(id)) |idx| {
        if (lines) |l| g.nodes.items[idx].lines = l;
        if (shape) |s| g.nodes.items[idx].shape = s;
        return idx;
    }
    const pseudo = if (shape) |s| s == .start or s == .end else false;
    return g.add(a, .{
        .id = id,
        .lines = lines orelse if (pseudo) &.{} else try a.dupe([]const u8, &.{id}),
        .shape = shape orelse .round,
        .titled = false,
        .explicit = lines != null,
    });
}

const Rel = struct { tok: []const u8, head_on_left: bool, dashed: bool, head: m.Head };
const rel_tokens = [_]Rel{
    .{ .tok = "<|--", .head_on_left = true, .dashed = false, .head = .arrow },
    .{ .tok = "--|>", .head_on_left = false, .dashed = false, .head = .arrow },
    .{ .tok = "<|..", .head_on_left = true, .dashed = true, .head = .arrow },
    .{ .tok = "..|>", .head_on_left = false, .dashed = true, .head = .arrow },
    .{ .tok = "*--", .head_on_left = true, .dashed = false, .head = .arrow },
    .{ .tok = "--*", .head_on_left = false, .dashed = false, .head = .arrow },
    .{ .tok = "o--", .head_on_left = true, .dashed = false, .head = .circle },
    .{ .tok = "--o", .head_on_left = false, .dashed = false, .head = .circle },
    .{ .tok = "<--", .head_on_left = true, .dashed = false, .head = .arrow },
    .{ .tok = "-->", .head_on_left = false, .dashed = false, .head = .arrow },
    .{ .tok = "<..", .head_on_left = true, .dashed = true, .head = .arrow },
    .{ .tok = "..>", .head_on_left = false, .dashed = true, .head = .arrow },
    .{ .tok = "--", .head_on_left = false, .dashed = false, .head = .none },
    .{ .tok = "..", .head_on_left = false, .dashed = true, .head = .none },
};

const Classes = struct {
    a: mem.Allocator,
    g: lg.Graph = .{},

    /// `~T~` generics as `<T>`.
    fn clean(c: *Classes, s: []const u8) ![]const u8 {
        if (mem.indexOfScalar(u8, s, '~') == null) return s;
        return regex.replace(c.a, s, "~([^~]+)~", "<$1>");
    }

    fn ensure(c: *Classes, raw_name: []const u8, title: ?[]const u8) !?usize {
        const name = try c.clean(text.trim(raw_name));
        if (name.len == 0) return null;
        if (c.g.index.get(name)) |idx| {
            if (title) |tt| {
                const node = &c.g.nodes.items[idx];
                const lines = try c.a.dupe([]const u8, node.lines);
                lines[0] = tt;
                node.lines = lines;
            }
            return idx;
        }
        return c.g.add(c.a, .{ .id = name, .lines = try c.a.dupe([]const u8, &.{title orelse name}), .shape = .rect, .titled = true, .explicit = true });
    }

    fn addMember(c: *Classes, cls: []const u8, member: []const u8) !void {
        const mbr = try c.clean(text.trim(member));
        if (mbr.len == 0 or mem.startsWith(u8, mbr, "<<")) return;
        const idx = try c.ensure(cls, null) orelse return;
        const node = &c.g.nodes.items[idx];
        node.lines = try mem.concat(c.a, []const u8, &.{ node.lines, &.{mbr} });
    }
};

pub fn parseClass(a: mem.Allocator, raw_lines: []const []const u8) !?m.Diagram {
    var dir: []const u8 = "TD";
    var c: Classes = .{ .a = a };
    var active: ?[]const u8 = null;

    stmts: for (try text.statements(a, raw_lines)) |line| {
        const t = text.trim(line);
        if (t.len == 0 or mem.startsWith(u8, t, "%%") or ascii.startsWithIgnoreCase(t, "note ") or mem.startsWith(u8, t, "<<")) continue;
        if (active) |cls| {
            if (mem.endsWith(u8, t, "}")) {
                const before = text.trim(t[0 .. t.len - 1]);
                if (before.len > 0) try c.addMember(cls, before);
                active = null;
            } else {
                try c.addMember(cls, t);
            }
            continue;
        }
        if (ascii.startsWithIgnoreCase(t, "direction ")) {
            const parts = try text.words(a, t);
            if (parts.len > 1) dir = text.normalizeDir(parts[1]);
            continue;
        }
        if (ascii.startsWithIgnoreCase(t, "class ")) {
            var rest = text.trim(t[6..]);
            var opens_block = false;
            if (mem.endsWith(u8, rest, "{")) {
                opens_block = true;
                rest = text.trim(rest[0 .. rest.len - 1]);
            }
            var label: ?[]const u8 = null;
            if (mem.indexOfScalar(u8, rest, '[')) |brk| if (mem.lastIndexOfScalar(u8, rest, ']')) |end_brk| if (brk < end_brk) {
                label = try text.cleanJoined(a, rest[brk + 1 .. end_brk]);
                rest = text.trim(rest[0..brk]);
            };
            const cls_name = text.firstWord(rest) orelse rest;
            _ = try c.ensure(cls_name, label) orelse return null;
            if (opens_block) active = cls_name;
            continue;
        }

        for (rel_tokens) |rel| {
            const r = mem.indexOf(u8, t, rel.tok) orelse continue;
            var left = text.trim(t[0..r]);
            var right_full = text.trim(t[r + rel.tok.len ..]);
            var label: ?[]const u8 = null;
            if (mem.indexOfScalar(u8, right_full, ':')) |colon| {
                const lbl = text.trim(right_full[colon + 1 ..]);
                if (lbl.len > 0) label = try text.cleanJoined(a, lbl);
                right_full = text.trim(right_full[0..colon]);
            }
            left = stripCardinality(left, true);
            const right = stripCardinality(right_full, false);
            if (left.len == 0 or right.len == 0) continue;
            const li = try c.ensure(left, null) orelse return null;
            const ri = try c.ensure(right, null) orelse return null;
            if (c.g.edges.items.len >= m.max_edges) return null;
            try c.g.edges.append(a, .{
                .from = if (rel.head_on_left) ri else li,
                .to = if (rel.head_on_left) li else ri,
                .dashed = rel.dashed,
                .thick = false,
                .head = rel.head,
                .label = label,
            });
            continue :stmts;
        }

        if (mem.indexOfScalar(u8, t, ':')) |colon| {
            const cls = text.trim(t[0..colon]);
            const member = text.trim(t[colon + 1 ..]);
            if (cls.len > 0 and member.len > 0) try c.addMember(cls, member);
        }
    }

    if (c.g.nodes.items.len == 0) return null;
    return lg.layoutGraph(a, c.g.nodes.items, c.g.edges.items, dir, "class");
}

/// Drops a quoted multiplicity (`"1"`) next to a relation token.
fn stripCardinality(s: []const u8, trailing: bool) []const u8 {
    const out = text.trim(s);
    if (trailing) {
        if (mem.endsWith(u8, out, "\"")) if (mem.lastIndexOfScalar(u8, out[0 .. out.len - 1], '"')) |first| return text.trim(out[0..first]);
    } else {
        if (mem.startsWith(u8, out, "\"")) if (mem.indexOfScalar(u8, out[1..], '"')) |second| return text.trim(out[second + 2 ..]);
    }
    return out;
}
