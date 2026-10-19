//! The graph model shared by flowchart, state and class diagrams, and its
//! layered layout: DFS back edges, longest-path ranks, four barycenter
//! sweeps, then coordinates (Swift `layoutGraph` and `clipPoint`).
const std = @import("std");
const m = @import("mermaid.zig");
const text = @import("text.zig");

pub const NodeSpec = struct {
    id: []const u8,
    lines: []const []const u8,
    shape: m.Shape,
    titled: bool,
    explicit: bool,
};

pub const EdgeSpec = struct {
    from: usize,
    to: usize,
    dashed: bool,
    thick: bool,
    head: m.Head,
    label: ?[]const u8,
};

/// Nodes in appearance order, their ids, and edges.
pub const Graph = struct {
    nodes: std.ArrayList(NodeSpec) = .empty,
    index: std.StringHashMapUnmanaged(usize) = .empty,
    edges: std.ArrayList(EdgeSpec) = .empty,

    /// Appends a node unless the cap is reached (null).
    pub fn add(g: *Graph, a: std.mem.Allocator, node: NodeSpec) !?usize {
        if (g.nodes.items.len >= m.max_nodes) return null;
        const idx = g.nodes.items.len;
        try g.index.put(a, node.id, idx);
        try g.nodes.append(a, node);
        return idx;
    }
};

const Size = struct { w: f64, h: f64 };

fn nodeSize(node: NodeSpec) Size {
    if (node.shape == .start or node.shape == .end) return .{ .w = 14, .h = 14 };
    if (node.titled) {
        const title_w = text.textWidth(if (node.lines.len > 0) node.lines[0] else "", true, 12);
        const member_w = if (node.lines.len > 1) text.maxWidth(node.lines[1..], false, 12) else 0;
        const members = node.lines.len -| 1;
        return .{
            .w = @max(48, @max(title_w, member_w) + 20),
            .h = @floatFromInt(22 + 15 * members + @as(usize, if (members > 0) 10 else 0)),
        };
    }
    var w = @max(48, text.maxWidth(node.lines, false, 12) + 24);
    var h = @max(36, @as(f64, @floatFromInt(16 * @max(1, node.lines.len) + 16)));
    switch (node.shape) {
        .circle => {
            const d = @max(w, h);
            w = d;
            h = d;
        },
        .diamond => {
            w += 28;
            h += 20;
        },
        .hexagon => w += 20,
        else => {},
    }
    return .{ .w = w, .h = h };
}

const Scored = struct { node: usize, avg: f64, cur: usize };

fn scoredLess(_: void, l: Scored, r: Scored) bool {
    if (@abs(l.avg - r.avg) > 1e-6) return l.avg < r.avg;
    return l.cur < r.cur;
}

pub fn layoutGraph(a: std.mem.Allocator, nodes: []const NodeSpec, edges: []const EdgeSpec, dir: []const u8, kind: []const u8) !?m.Diagram {
    const n = nodes.len;
    if (n == 0 or n > m.max_nodes or edges.len > m.max_edges) return null;

    // 1. Node sizes
    const sizes = try a.alloc(Size, n);
    for (nodes, sizes) |node, *s| s.* = nodeSize(node);

    // 2. Back edges via DFS in appearance order
    const Adj = struct { ei: usize, to: usize };
    const adj = try a.alloc(std.ArrayList(Adj), n);
    for (adj) |*l| l.* = .empty;
    for (edges, 0..) |e, ei| if (e.from != e.to) try adj[e.from].append(a, .{ .ei = ei, .to = e.to });
    const state = try a.alloc(u8, n); // 0 unvisited, 1 on stack, 2 done
    @memset(state, 0);
    const back = try a.alloc(bool, edges.len);
    @memset(back, false);
    const Frame = struct { u: usize, next: usize };
    var stack: std.ArrayList(Frame) = .empty;
    for (0..n) |start| {
        if (state[start] != 0) continue;
        try stack.append(a, .{ .u = start, .next = 0 });
        state[start] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const u = top.u;
            if (top.next < adj[u].items.len) {
                const step = adj[u].items[top.next];
                top.next += 1;
                if (state[step.to] == 1) {
                    back[step.ei] = true;
                } else if (state[step.to] == 0) {
                    state[step.to] = 1;
                    try stack.append(a, .{ .u = step.to, .next = 0 });
                }
            } else {
                state[u] = 2;
                _ = stack.pop();
            }
        }
    }

    // 3. Ranks via longest-path in Kahn topological order
    const dag_out = try a.alloc(std.ArrayList(usize), n);
    for (dag_out) |*l| l.* = .empty;
    const indeg = try a.alloc(usize, n);
    @memset(indeg, 0);
    for (edges, 0..) |e, ei| if (e.from != e.to and !back[ei]) {
        try dag_out[e.from].append(a, e.to);
        indeg[e.to] += 1;
    };
    const ranks = try a.alloc(usize, n);
    @memset(ranks, 0);
    var ready: std.ArrayList(usize) = .empty;
    for (0..n) |u| if (indeg[u] == 0) try ready.append(a, u);
    var visited: usize = 0;
    while (ready.items.len > 0) {
        std.mem.sort(usize, ready.items, {}, std.sort.asc(usize));
        const u = ready.orderedRemove(0);
        visited += 1;
        for (dag_out[u].items) |v| {
            if (ranks[u] + 1 > ranks[v]) ranks[v] = ranks[u] + 1;
            indeg[v] -= 1;
            if (indeg[v] == 0) try ready.append(a, v);
        }
    }
    if (visited < n) for (0..n) |u| if (indeg[u] > 0) {
        ranks[u] = 0;
    };

    const max_rank = std.mem.max(usize, ranks);
    const layers = try a.alloc([]usize, max_rank + 1);
    {
        var lists = try a.alloc(std.ArrayList(usize), max_rank + 1);
        for (lists) |*l| l.* = .empty;
        for (0..n) |u| try lists[ranks[u]].append(a, u);
        for (layers, lists) |*l, list| l.* = list.items;
    }

    // 4. Order within rank: 4 barycenter sweeps (down, up, down, up)
    const pos_in_prev = try a.alloc(?usize, n);
    if (max_rank >= 1) for (0..4) |sweep| {
        const downward = sweep % 2 == 0;
        for (0..max_rank) |k| {
            const r = if (downward) k + 1 else max_rank - 1 - k;
            const prev = if (downward) r - 1 else r + 1;
            @memset(pos_in_prev, null);
            for (layers[prev], 0..) |node, p| pos_in_prev[node] = p;
            const scored = try a.alloc(Scored, layers[r].len);
            for (layers[r], scored, 0..) |u, *s, cur| {
                var sum: usize = 0;
                var count: usize = 0;
                for (edges, 0..) |e, ei| if (e.from != e.to and !back[ei]) {
                    if (e.from == u) if (pos_in_prev[e.to]) |p| {
                        sum += p;
                        count += 1;
                    };
                    if (e.to == u) if (pos_in_prev[e.from]) |p| {
                        sum += p;
                        count += 1;
                    };
                };
                const avg: f64 = if (count == 0) @floatFromInt(cur) else @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count));
                s.* = .{ .node = u, .avg = avg, .cur = cur };
            }
            std.mem.sort(Scored, scored, {}, scoredLess);
            for (layers[r], scored) |*u, s| u.* = s.node;
        }
    };

    // 5. Coordinates
    const horizontal = std.mem.eql(u8, dir, "LR") or std.mem.eql(u8, dir, "RL");
    if (std.mem.eql(u8, dir, "BT") or std.mem.eql(u8, dir, "RL")) std.mem.reverse([]usize, layers);
    const num_layers = layers.len;
    const layer_of = try a.alloc(usize, n);
    for (layers, 0..) |layer, li| for (layer) |u| {
        layer_of[u] = li;
    };
    const thickness = try a.alloc(f64, num_layers);
    const span = try a.alloc(f64, num_layers);
    const node_gap: f64 = if (horizontal) 20 else 28;
    for (layers, thickness, span) |layer, *th, *sp| {
        th.* = 0;
        var total: f64 = 0;
        for (layer) |u| {
            th.* = @max(th.*, if (horizontal) sizes[u].w else sizes[u].h);
            total += if (horizontal) sizes[u].h else sizes[u].w;
        }
        sp.* = total + @as(f64, @floatFromInt(layer.len -| 1)) * node_gap;
    }
    const max_span = std.mem.max(f64, span);
    const gap_after = try a.alloc(f64, num_layers - 1);
    @memset(gap_after, if (horizontal) 70 else 50);
    for (edges) |e| {
        if (e.from == e.to) continue;
        const lbl = e.label orelse continue;
        if (lbl.len == 0) continue;
        const l1 = @min(layer_of[e.from], layer_of[e.to]);
        const l2 = @max(layer_of[e.from], layer_of[e.to]);
        const lw = text.textWidth(lbl, false, 11);
        for (l1..l2) |g| if (g < gap_after.len) {
            gap_after[g] = @max(gap_after[g], if (horizontal) lw + 30 else 66);
        };
    }

    const margin: f64 = 8;
    const layer_start = try a.alloc(f64, num_layers);
    layer_start[0] = margin;
    for (1..num_layers) |li| layer_start[li] = layer_start[li - 1] + thickness[li - 1] + gap_after[li - 1];

    const rects = try a.alloc(m.Rect, n);
    for (layers, 0..) |layer, li| {
        var cursor = margin + (max_span - span[li]) / 2;
        for (layer) |u| {
            const sz = sizes[u];
            if (horizontal) {
                rects[u] = .{ .x = layer_start[li] + (thickness[li] - sz.w) / 2, .y = cursor, .w = sz.w, .h = sz.h };
                cursor += sz.h + node_gap;
            } else {
                rects[u] = .{ .x = cursor, .y = layer_start[li] + (thickness[li] - sz.h) / 2, .w = sz.w, .h = sz.h };
                cursor += sz.w + node_gap;
            }
        }
    }

    // 6. Build Items (edges then nodes)
    const items = try a.alloc(m.Item, edges.len + n);
    var max_x: f64 = 0;
    var max_y: f64 = 0;
    for (rects) |r| {
        max_x = @max(max_x, r.x + r.w);
        max_y = @max(max_y, r.y + r.h);
    }
    for (edges, items[0..edges.len]) |e, *item| {
        var points: []m.Point = undefined;
        if (e.from == e.to) {
            const r = rects[e.from];
            const mx = r.x + r.w;
            const my = r.y + r.h / 2;
            points = try a.dupe(m.Point, &.{ .{ .x = mx, .y = my - 6 }, .{ .x = mx + 22, .y = my - 6 }, .{ .x = mx + 22, .y = my + 6 }, .{ .x = mx, .y = my + 6 } });
            max_x = @max(max_x, mx + 28);
        } else {
            const rf = rects[e.from];
            const rt = rects[e.to];
            const cf: m.Point = .{ .x = rf.x + rf.w / 2, .y = rf.y + rf.h / 2 };
            const ct: m.Point = .{ .x = rt.x + rt.w / 2, .y = rt.y + rt.h / 2 };
            points = try a.dupe(m.Point, &.{ clipPoint(cf, ct, rf, nodes[e.from].shape), clipPoint(ct, cf, rt, nodes[e.to].shape) });
        }
        item.* = .{ .edge = .{ .points = points, .dashed = e.dashed, .thick = e.thick, .head = e.head, .label = e.label } };
    }
    for (nodes, rects, items[edges.len..]) |node, r, *item| {
        item.* = .{ .node = .{ .rect = r, .shape = node.shape, .lines = node.lines, .titled = node.titled } };
    }

    return .{ .kind = kind, .width = @ceil(max_x + margin), .height = @ceil(max_y + margin), .items = items, .nodes = n, .edges = edges.len };
}

/// Where the segment from `center` toward `target` leaves `rect` drawn as `shape`.
fn clipPoint(center: m.Point, target: m.Point, rect: m.Rect, shape: m.Shape) m.Point {
    const dx = target.x - center.x;
    const dy = target.y - center.y;
    const dist = std.math.hypot(dx, dy);
    if (!(dist > 1e-4)) return center;
    const hw = @max(1, rect.w / 2);
    const hh = @max(1, rect.h / 2);
    const t: f64 = switch (shape) {
        .circle, .start, .end => {
            const r = @min(hw, hh);
            return .{ .x = center.x + dx / dist * r, .y = center.y + dy / dist * r };
        },
        .diamond => blk: {
            const denom = @abs(dx) / hw + @abs(dy) / hh;
            break :blk if (denom > 1e-5) 1.0 / denom else 0;
        },
        else => @min(
            if (@abs(dx) > 1e-5) hw / @abs(dx) else std.math.floatMax(f64),
            if (@abs(dy) > 1e-5) hh / @abs(dy) else std.math.floatMax(f64),
        ),
    };
    return .{ .x = center.x + dx * t, .y = center.y + dy * t };
}
