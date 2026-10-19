//! Clean-room Mermaid parser and layout for Ubi Chat, a port of
//! Sources/Kea/Mermaid.swift (everything before `DiagramView`). Pure and
//! deterministic: every sort breaks ties by input index, and any input past
//! the size caps yields null (the caller shows highlighted source instead).
const std = @import("std");
const text = @import("text.zig");
const flow = @import("parse_flow.zig");
const misc = @import("parse_misc.zig");
const seq = @import("seq.zig");
const pie = @import("pie.zig");

pub const Shape = enum { rect, round, stadium, circle, diamond, hexagon, start, end };
pub const Head = enum { none, arrow, cross, circle };
pub const Point = struct { x: f64, y: f64 };
pub const Rect = struct { x: f64, y: f64, w: f64, h: f64 };
pub const Item = union(enum) {
    node: struct { rect: Rect, shape: Shape, lines: []const []const u8, titled: bool },
    edge: struct { points: []const Point, dashed: bool, thick: bool, head: Head, label: ?[]const u8 },
    text: struct { str: []const u8, at: Point, bold: bool, muted: bool },
    note: struct { rect: Rect, lines: []const []const u8 },
    wedge: struct { center: Point, radius: f64, from: f64, to: f64, color: i64 },
    swatch: struct { rect: Rect, color: i64 },
};
pub const Diagram = struct {
    kind: []const u8,
    width: f64,
    height: f64,
    items: []const Item,
    nodes: usize,
    edges: usize,
};

pub const max_chars = 20_000;
pub const max_nodes = 150;
pub const max_edges = 300;
pub const max_participants = 20;
pub const max_sequence_rows = 200;

/// The laid-out diagram for `source`, or null where Swift returns nil
/// (unknown header, nothing to draw, past a cap). Everything on `arena`
/// (a caller-owned ArenaAllocator's allocator).
pub fn diagram(arena: std.mem.Allocator, source: []const u8) ?Diagram {
    return build(arena, source) catch null;
}

fn build(a: std.mem.Allocator, source: []const u8) !?Diagram {
    // ponytail: Swift counts grapheme clusters; this counts code points (CRLF
    // as one), so text heavy in combining marks or emoji hits the cap sooner.
    if (source.len > max_chars) {
        const cps = std.unicode.utf8CountCodepoints(source) catch source.len;
        if (cps - std.mem.count(u8, source, "\r\n") > max_chars) return null;
    }
    const lf = try std.mem.replaceOwned(u8, a, try std.mem.replaceOwned(u8, a, source, "\r\n", "\n"), "\r", "\n");
    var raw: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, lf, '\n');
    while (it.next()) |l| try raw.append(a, l);
    const lines = raw.items;

    var idx: usize = 0;
    while (idx < lines.len) {
        const t = text.trim(lines[idx]);
        if (t.len == 0 or std.mem.startsWith(u8, t, "%%")) {
            idx += 1;
            continue;
        }
        if (std.mem.eql(u8, t, "---")) {
            idx += 1;
            while (idx < lines.len and !std.mem.eql(u8, text.trim(lines[idx]), "---")) idx += 1;
            if (idx < lines.len) idx += 1;
            continue;
        }
        break;
    }
    if (idx >= lines.len) return null;
    const header = text.trim(lines[idx]);
    const body = lines[idx + 1 ..];
    const first = text.firstWord(header) orelse "";
    const eql = std.mem.eql;

    if (eql(u8, first, "flowchart") or eql(u8, first, "graph")) {
        const parts = try text.words(a, header);
        const dir = if (parts.len > 1) text.normalizeDir(parts[1]) else "TD";
        return flow.parseFlowchart(a, try text.statements(a, body), dir, "flowchart");
    }
    if (eql(u8, first, "sequenceDiagram")) return seq.parseSequence(a, try text.statements(a, body));
    if (eql(u8, first, "pie")) return pie.parsePie(a, header, try text.statements(a, body));
    if (eql(u8, first, "stateDiagram") or eql(u8, first, "stateDiagram-v2")) return misc.parseState(a, try text.statements(a, body));
    if (eql(u8, first, "classDiagram") or eql(u8, first, "classDiagram-v2")) return misc.parseClass(a, body);
    return null;
}

test {
    _ = text;
    _ = @import("mermaid_test.zig");
}
